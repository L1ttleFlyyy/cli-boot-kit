#!/usr/bin/env bash

repo_root() {
    local source_dir
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf '%s\n' "$source_dir"
}

color_enabled() {
    [ -t 1 ] &&
        [ -z "${NO_COLOR:-}" ] &&
        [ "${TERM:-dumb}" != "dumb" ]
}

if color_enabled; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_BLUE=""
    COLOR_CYAN=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
fi

log() {
    info "$*"
}

heading() {
    printf '%s%s%s\n' "$COLOR_BOLD" "$*" "$COLOR_RESET"
}

info() {
    printf '%sinfo:%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

success() {
    printf '%ssuccess:%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

warn() {
    printf '%swarning:%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"
}

die() {
    printf '%serror:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    exit 1
}

run() {
    show_command "$@"
    if [ "${DRY_RUN:-no}" = "yes" ]; then
        return 0
    else
        "$@"
    fi
}

# run_eval CMD — print CMD, then eval it on a real run. Use for pipelines,
# redirections, or login-shell strings that the argv-form run() cannot express.
# The same string is printed and executed, so dry-run cannot drift from apply.
run_eval() {
    show_command_text "$1"
    if [ "${DRY_RUN:-no}" = "yes" ]; then
        return 0
    fi
    eval "$1"
}

# write_file PATH — write stdin to PATH. Always prints "write PATH"; in dry-run
# it also echoes the content (indented) and writes nothing. The heredoc piped in
# is the single source for both modes, so the preview matches what gets written.
write_file() {
    local path="$1"
    show_command_text "write $path"
    if [ "${DRY_RUN:-no}" = "yes" ]; then
        sed 's/^/    | /'
        return 0
    fi
    cat > "$path"
}

show_command() {
    printf '\n%s+%s' "$COLOR_CYAN" "$COLOR_RESET"
    printf ' %q' "$@"
    printf '\n'
}

show_command_text() {
    printf '\n%s+%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*"
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        die "this command must run as root; use sudo"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

target_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        printf '%s\n' "$SUDO_USER"
    else
        id -un
    fi
}

home_for_user() {
    local user="$1"
    getent passwd "$user" | cut -d: -f6
}

# Files and directories managed by cli-boot-kit that more than one script must
# name (the writer module and verify.sh). Shared here so a rename cannot leave
# the writer and the checker pointing at different paths.
# shellcheck disable=SC2034  # consumed by sourcing scripts
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-cli-boot-kit.conf"
# shellcheck disable=SC2034  # consumed by sourcing scripts
SUDO_NOPASSWD_DROPIN="/etc/sudoers.d/99-cli-boot-kit-nopasswd"

# Every key a profile layer (config/defaults.env, config/ssh.env,
# profiles/<name>.env) is allowed to set. lint_profile_keys rejects anything
# else, so a typo'd toggle (e.g. INSTALL_TAILSCLE=yes) fails fast instead of
# silently no-oping through both bootstrap and verify — they would otherwise
# read the same misspelled variable and agree with each other. Adding a new
# profile key starts by declaring it here.
KNOWN_PROFILE_KEYS=(
    APPLY_ROUTER_SYSCTL
    CHEZMOI_REPO
    DEFAULT_SHELL
    INSTALL_CLAUDE
    INSTALL_COCKPIT
    INSTALL_CODEX
    INSTALL_FAIL2BAN
    INSTALL_PODMAN_QUADLET
    INSTALL_TAILSCALE
    SSH_PORT
    SUDO_NOPASSWD
    TAILSCALE_NETDEV
    TIMEZONE
    TRUSTED_TAILNET_CIDR
)

# lint_profile_keys FILE — die when FILE assigns a variable outside
# KNOWN_PROFILE_KEYS. Profile layers are shell-safe key=value by convention,
# so a line-anchored regex is enough to enumerate the assignments.
lint_profile_keys() {
    local file="$1"
    local key
    while IFS= read -r key; do
        key="${key%=}"
        case " ${KNOWN_PROFILE_KEYS[*]} " in
            *" $key "*) ;;
            *) die "unknown key '$key' in $file; fix the typo or add it to KNOWN_PROFILE_KEYS in scripts/lib/common.sh" ;;
        esac
    done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$file")
}

# Source config/defaults.env into the environment when present.
load_defaults() {
    local root
    root="$(repo_root)"
    if [ -r "$root/config/defaults.env" ]; then
        lint_profile_keys "$root/config/defaults.env"
        # shellcheck disable=SC1091
        . "$root/config/defaults.env"
    fi
}

# load_profile NAME — establish the host's declared target state.
# Layered: config/defaults.env + config/ssh.env provide fallback baselines, then
# profiles/<NAME>.env overlays on top (highest precedence). NAME may be a bare
# profile name (resolved under profiles/) or an explicit path (contains / or .env).
# shellcheck disable=SC2034  # PROFILE_NAME/PROFILE_PATH consumed by callers
load_profile() {
    local name="${1:-}"
    [ -n "$name" ] || die "load_profile: missing profile name"

    local root path
    root="$(repo_root)"

    # Fallback baselines (lowest precedence).
    load_defaults
    if [ -r "$root/config/ssh.env" ]; then
        lint_profile_keys "$root/config/ssh.env"
        # shellcheck disable=SC1091
        . "$root/config/ssh.env"
    fi

    case "$name" in
        */*|*.env) path="$name" ;;
        *) path="$root/profiles/$name.env" ;;
    esac
    [ -r "$path" ] || die "profile not found: $path (expected profiles/<name>.env)"

    # Profile overlay (highest precedence).
    lint_profile_keys "$path"
    # shellcheck disable=SC1090
    . "$path"
    PROFILE_NAME="$name"
    PROFILE_PATH="$path"
}

# parse_runtime_args "$@" — populate PROFILE and DRY_RUN from the uniform
# "<profile> [--dry-run]" CLI shared by every script. The caller must define a
# usage() function for -h/--help.
PROFILE=""
parse_runtime_args() {
    PROFILE=""
    DRY_RUN="no"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run)
                DRY_RUN="yes"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "unknown option: $1 (usage: $(basename "$0") <profile> [--dry-run])"
                ;;
            *)
                if [ -z "$PROFILE" ]; then
                    PROFILE="$1"
                else
                    die "unexpected argument: $1"
                fi
                ;;
        esac
        shift
    done
    [ -n "$PROFILE" ] ||
        die "missing required <profile> argument; e.g. $(basename "$0") ubuntu-gen [--dry-run]"
}

confirm() {
    local prompt="$1"
    local default="${2:-yes}"
    local suffix
    local answer

    if [ "$default" = "yes" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    # Consent needs a terminal. Without one, read hits EOF and would fall
    # through to the default — for "Reboot now?" (default yes) that made a
    # non-interactive bootstrap reboot the host. Answer "no" instead.
    if [ ! -t 0 ]; then
        warn "stdin is not a terminal; answering no: $prompt"
        return 1
    fi
    printf '\a' >&2

    printf '%s?%s %s %s ' "$COLOR_BOLD" "$COLOR_RESET" "$prompt" "$suffix"
    read -r answer || return 1
    case "$answer" in
        y|Y|yes|YES)
            return 0
            ;;
        n|N|no|NO)
            return 1
            ;;
        "")
            [ "$default" = "yes" ]
            ;;
        *)
            return 1
            ;;
    esac
}

# shellcheck source-path=scripts/lib
# shellcheck source=os.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os.sh"
