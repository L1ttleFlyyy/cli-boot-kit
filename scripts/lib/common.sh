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

# Source config/defaults.env into the environment when present.
load_defaults() {
    local root
    root="$(repo_root)"
    if [ -r "$root/config/defaults.env" ]; then
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
        # shellcheck disable=SC1091
        . "$root/config/ssh.env"
    fi

    case "$name" in
        */*|*.env) path="$name" ;;
        *) path="$root/profiles/$name.env" ;;
    esac
    [ -r "$path" ] || die "profile not found: $path (expected profiles/<name>.env)"

    # Profile overlay (highest precedence).
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

# shellcheck source-path=scripts/lib
# shellcheck source=os.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os.sh"
