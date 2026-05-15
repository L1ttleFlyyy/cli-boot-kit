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

require_fedora() {
    if [ ! -r /etc/os-release ]; then
        die "cannot read /etc/os-release"
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    if [ "${ID:-}" != "fedora" ]; then
        die "this setup targets Fedora; detected ID=${ID:-unknown}"
    fi
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

    if [ -t 0 ]; then
        printf '\a' >&2
    fi

    printf '%s?%s %s %s ' "$COLOR_BOLD" "$COLOR_RESET" "$prompt" "$suffix"
    read -r answer
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
