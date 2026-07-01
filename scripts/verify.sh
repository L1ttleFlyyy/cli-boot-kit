#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: verify.sh <profile>"
    echo
    echo "Read-only check of this host against the profile's declared target"
    echo "state. Usable before deploy (env-check) or after (acceptance). Exits"
    echo "non-zero if any check fails."
}

parse_runtime_args "$@"

# Make brew-installed tools discoverable in the target user's login shell.
# shellcheck disable=SC2016  # expansion deferred to the target login shell
BREW_PRELUDE='[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"; '

PASS_N=0
FAIL_N=0
SKIP_N=0

section() {
    printf '\n%s== %s ==%s\n' "$COLOR_BOLD" "$*" "$COLOR_RESET"
}

pass() {
    PASS_N=$((PASS_N + 1))
    printf '  %s[PASS]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

fail() {
    FAIL_N=$((FAIL_N + 1))
    printf '  %s[FAIL]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$1"
}

skip() {
    SKIP_N=$((SKIP_N + 1))
    printf '  %s[SKIP]%s %s%s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1" "${2:+ — $2}"
}

# check_cmd LABEL CMD...  — pass if the command succeeds quietly.
check_cmd() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label"
    fi
}

# as_user USER CMD  — run CMD in the target user's login shell (with brew on PATH).
as_user() {
    local user="$1"
    local cmd="$2"
    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" bash -lc "${BREW_PRELUDE}${cmd}" >/dev/null 2>&1
    else
        bash -lc "${BREW_PRELUDE}${cmd}" >/dev/null 2>&1
    fi
}

is_root() {
    [ "${EUID}" -eq 0 ]
}

ssh_active() {
    if ssh_socket_activated; then
        return 0
    fi
    systemctl is-active --quiet "$(ssh_unit)"
}

main() {
    require_supported_os
    load_profile "$PROFILE"

    local user
    user="$(target_user)"

    heading "verify: profile ${PROFILE_NAME} (target user: ${user})"

    section "Profile / environment"
    if [ -r "$PROFILE_PATH" ]; then
        pass "profile readable: $PROFILE_PATH"
    else
        fail "profile readable: $PROFILE_PATH"
    fi
    local var
    for var in SSH_PORT TIMEZONE CHEZMOI_REPO DEFAULT_SHELL; do
        if [ -n "${!var:-}" ]; then
            pass "$var set (${!var})"
        else
            fail "$var is empty"
        fi
    done

    section "OS"
    if is_fedora || is_debian_like; then
        pass "supported OS: ${OS_ID} ${OS_VERSION_ID}"
    else
        fail "unsupported OS: ${OS_ID:-unknown}"
    fi

    section "Base packages"
    local cmd
    for cmd in git zsh curl; do
        check_cmd "$cmd on PATH" command -v "$cmd"
    done

    section "SSH hardening"
    local dropin="/etc/ssh/sshd_config.d/10-cli-boot-kit.conf"
    if [ -f "$dropin" ]; then
        pass "drop-in present: $dropin"
        if grep -qxF "Port ${SSH_PORT}" "$dropin"; then
            pass "drop-in declares Port ${SSH_PORT}"
        else
            fail "drop-in Port does not match SSH_PORT=${SSH_PORT}"
        fi
    else
        fail "drop-in present: $dropin"
    fi
    if ssh_active; then
        pass "ssh service active"
    else
        fail "ssh service active"
    fi
    if command -v ss >/dev/null 2>&1; then
        if ss -H -tln "sport = :${SSH_PORT}" 2>/dev/null | grep -q .; then
            pass "listening on tcp/${SSH_PORT}"
        else
            fail "listening on tcp/${SSH_PORT}"
        fi
    else
        skip "listening on tcp/${SSH_PORT}" "ss not available"
    fi
    if is_root; then
        check_cmd "sshd config valid (sshd -t)" sshd -t
    else
        skip "sshd config valid (sshd -t)" "needs root"
    fi

    section "Firewall"
    case "$(firewall_kind)" in
        ufw)
            if is_root; then
                if ufw status 2>/dev/null | grep -qi "Status: active"; then
                    pass "ufw active"
                else
                    fail "ufw active"
                fi
                if ufw status 2>/dev/null | grep -q "${SSH_PORT}/tcp"; then
                    pass "ufw allows ${SSH_PORT}/tcp"
                else
                    fail "ufw allows ${SSH_PORT}/tcp"
                fi
            else
                skip "ufw status" "needs root"
            fi
            ;;
        firewalld)
            if is_root; then
                check_cmd "firewalld running" firewall-cmd --state
                check_cmd "firewalld allows ${SSH_PORT}/tcp" firewall-cmd --query-port="${SSH_PORT}/tcp"
            else
                skip "firewalld status" "needs root"
            fi
            ;;
        *)
            skip "firewall" "no supported firewall manager"
            ;;
    esac

    section "fail2ban"
    if [ "${INSTALL_FAIL2BAN:-yes}" = "yes" ]; then
        check_cmd "fail2ban service active" systemctl is-active --quiet fail2ban
        if is_root; then
            check_cmd "sshd jail present" fail2ban-client status sshd
        else
            skip "sshd jail present" "needs root"
        fi
    else
        skip "fail2ban" "INSTALL_FAIL2BAN != yes"
    fi

    section "Shell & dotfiles (user: ${user})"
    local login_shell
    login_shell="$(getent passwd "$user" | cut -d: -f7)"
    if [ "$(basename "${login_shell:-}")" = "${DEFAULT_SHELL}" ]; then
        pass "login shell is ${DEFAULT_SHELL} (${login_shell})"
    else
        fail "login shell is ${DEFAULT_SHELL} (found: ${login_shell:-none})"
    fi
    if as_user "$user" "command -v brew"; then
        pass "Homebrew available for ${user}"
    else
        fail "Homebrew available for ${user}"
    fi
    if as_user "$user" "command -v chezmoi"; then
        pass "chezmoi available for ${user}"
    else
        fail "chezmoi available for ${user}"
    fi

    section "Sandbox & developer CLIs"
    check_cmd "bwrap user-namespace sandbox" bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true
    if [ "${INSTALL_CLAUDE:-no}" = "yes" ]; then
        if as_user "$user" "command -v claude"; then
            pass "Claude Code available for ${user}"
        else
            fail "Claude Code available for ${user}"
        fi
    else
        skip "Claude Code" "INSTALL_CLAUDE != yes"
    fi
    if [ "${INSTALL_CODEX:-no}" = "yes" ]; then
        if as_user "$user" "command -v codex"; then
            pass "Codex CLI available for ${user}"
        else
            fail "Codex CLI available for ${user}"
        fi
    else
        skip "Codex CLI" "INSTALL_CODEX != yes"
    fi

    section "Tailscale"
    if [ "${INSTALL_TAILSCALE:-no}" = "yes" ]; then
        check_cmd "tailscale on PATH" command -v tailscale
        check_cmd "tailscaled active" systemctl is-active --quiet tailscaled
        case "$(firewall_kind)" in
            firewalld)
                if is_root; then
                    local ts_zone
                    ts_zone="$(firewalld_zone_for_netdev "${TAILSCALE_NETDEV:-}")"
                    check_cmd "firewalld allows 41641/udp (zone ${ts_zone})" \
                        firewall-cmd --zone="$ts_zone" --query-port=41641/udp
                else
                    skip "firewalld allows 41641/udp" "needs root"
                fi
                ;;
            ufw)
                if is_root; then
                    if ufw status 2>/dev/null | grep -q "41641/udp"; then
                        pass "ufw allows 41641/udp"
                    else
                        fail "ufw allows 41641/udp"
                    fi
                else
                    skip "ufw allows 41641/udp" "needs root"
                fi
                ;;
            *)
                skip "tailscale 41641/udp" "no supported firewall manager"
                ;;
        esac
    else
        skip "tailscale" "INSTALL_TAILSCALE != yes"
    fi

    section "Podman / Quadlet"
    if [ "${INSTALL_PODMAN_QUADLET:-no}" = "yes" ]; then
        check_cmd "podman on PATH" command -v podman
        if [ -x /usr/lib/systemd/system-generators/podman-system-generator ] ||
            [ -x /usr/libexec/systemd/system-generators/podman-system-generator ]; then
            pass "Quadlet generator present"
        else
            fail "Quadlet generator present"
        fi
        if [ -d /etc/containers/systemd ]; then
            pass "/etc/containers/systemd exists"
        else
            fail "/etc/containers/systemd exists"
        fi
    else
        skip "podman-quadlet" "INSTALL_PODMAN_QUADLET != yes"
    fi

    section "Router sysctl"
    if [ "${APPLY_ROUTER_SYSCTL:-no}" = "yes" ]; then
        if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
            pass "tcp_congestion_control = bbr"
        else
            fail "tcp_congestion_control = bbr"
        fi
        if [ "$(sysctl -n net.core.default_qdisc 2>/dev/null)" = "fq" ]; then
            pass "default_qdisc = fq"
        else
            fail "default_qdisc = fq"
        fi
    else
        skip "router-sysctl" "APPLY_ROUTER_SYSCTL != yes"
    fi

    section "Timezone"
    if command -v timedatectl >/dev/null 2>&1; then
        local current_tz
        current_tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
        if [ "$current_tz" = "${TIMEZONE}" ]; then
            pass "timezone is ${TIMEZONE}"
        else
            fail "timezone is ${TIMEZONE} (found: ${current_tz:-unknown})"
        fi
    else
        skip "timezone" "timedatectl not available"
    fi

    printf '\n%s== summary ==%s\n' "$COLOR_BOLD" "$COLOR_RESET"
    printf '  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
        "$COLOR_GREEN" "$PASS_N" "$COLOR_RESET" \
        "$COLOR_RED" "$FAIL_N" "$COLOR_RESET" \
        "$COLOR_YELLOW" "$SKIP_N" "$COLOR_RESET"

    if [ "$FAIL_N" -gt 0 ]; then
        return 1
    fi
    return 0
}

main "$@"
