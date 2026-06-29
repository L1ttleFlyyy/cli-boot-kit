#!/usr/bin/env bash
# OS abstraction for cli-boot-kit.
#
# Sourced by lib/common.sh. Provides platform detection plus package-manager,
# firewall, and SELinux helpers so modules can stay distro-agnostic. Functions
# here rely on run/show_command/info/die from common.sh, so this file is sourced
# after those are defined.

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
APT_INDEX_UPDATED="no"

os_detect() {
    if [ -n "$OS_ID" ]; then
        return 0
    fi
    if [ ! -r /etc/os-release ]; then
        die "cannot read /etc/os-release"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_ID_LIKE="${ID_LIKE:-}"
    # shellcheck disable=SC2034  # consumed by callers (e.g. bootstrap.sh)
    OS_VERSION_ID="${VERSION_ID:-}"
}

is_fedora() {
    os_detect
    [ "$OS_ID" = "fedora" ]
}

is_ubuntu() {
    os_detect
    [ "$OS_ID" = "ubuntu" ]
}

is_debian_like() {
    os_detect
    case " $OS_ID $OS_ID_LIKE " in
        *" debian "*) return 0 ;;
    esac
    [ "$OS_ID" = "ubuntu" ]
}

require_supported_os() {
    os_detect
    if is_fedora || is_debian_like; then
        return 0
    fi
    die "unsupported OS: ID=${OS_ID:-unknown}; cli-boot-kit targets Fedora and Debian/Ubuntu"
}

pkg_manager() {
    if command -v dnf >/dev/null 2>&1; then
        printf 'dnf\n'
    elif command -v apt-get >/dev/null 2>&1; then
        printf 'apt\n'
    else
        printf 'none\n'
    fi
}

pkg_refresh() {
    case "$(pkg_manager)" in
        apt)
            if [ "$APT_INDEX_UPDATED" != "yes" ]; then
                run apt-get update
                APT_INDEX_UPDATED="yes"
            fi
            ;;
        dnf|none) : ;;
    esac
}

pkg_install() {
    case "$(pkg_manager)" in
        dnf)
            run dnf install -y "$@"
            ;;
        apt)
            pkg_refresh
            run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        *)
            die "no supported package manager (dnf/apt-get) found"
            ;;
    esac
}

system_upgrade() {
    case "$(pkg_manager)" in
        dnf)
            run dnf upgrade --refresh -y
            ;;
        apt)
            pkg_refresh
            run env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
            ;;
        *)
            die "no supported package manager (dnf/apt-get) found"
            ;;
    esac
}

selinux_enforcing() {
    command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
}

has_semanage() {
    command -v semanage >/dev/null 2>&1
}

firewall_kind() {
    if command -v firewall-cmd >/dev/null 2>&1; then
        printf 'firewalld\n'
    elif command -v ufw >/dev/null 2>&1; then
        printf 'ufw\n'
    elif is_fedora; then
        printf 'firewalld\n'
    else
        printf 'ufw\n'
    fi
}

firewalld_active() {
    [ "${DRY_RUN:-no}" = "yes" ] || systemctl is-active --quiet firewalld
}

# firewall_allow_port PORT [PROTO]
firewall_allow_port() {
    local port="$1"
    local proto="${2:-tcp}"

    case "$(firewall_kind)" in
        firewalld)
            if firewalld_active; then
                run firewall-cmd --permanent --add-port="${port}/${proto}"
                run firewall-cmd --reload
            else
                info "firewalld is not active; skipping firewall port ${port}/${proto}"
            fi
            ;;
        ufw)
            run ufw allow "${port}/${proto}"
            ;;
        *)
            info "no supported firewall manager; skipping port ${port}/${proto}"
            ;;
    esac
}

# ssh_unit echoes the unit name used to (re)start the SSH daemon.
ssh_unit() {
    if is_fedora; then
        printf 'sshd\n'
    else
        printf 'ssh\n'
    fi
}

# ssh_socket_activated returns success when sshd is started via ssh.socket
# (Debian/Ubuntu default). In that model the listening port is derived from
# sshd_config by systemd-ssh-generator, and ssh.socket must be reloaded.
ssh_socket_activated() {
    is_debian_like || return 1
    systemctl list-unit-files ssh.socket >/dev/null 2>&1 || return 1
    [ "$(systemctl is-enabled ssh.socket 2>/dev/null)" = "enabled" ] ||
        systemctl is-active --quiet ssh.socket
}
