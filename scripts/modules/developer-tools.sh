#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: developer-tools.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

# Both installers write into the target user's ~/.local; they must run as that
# user, never as root.
user_login_run() {
    local user="$1"
    local cmd="$2"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        run sudo -H -u "$user" bash -lc "$cmd"
    else
        run bash -lc "$cmd"
    fi
}

user_has_command() {
    local user="$1"
    local cmd="$2"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" bash -lc "command -v $(printf '%q' "$cmd") >/dev/null 2>&1"
    else
        bash -lc "command -v $(printf '%q' "$cmd") >/dev/null 2>&1"
    fi
}

# install_tool USER NAME BIN INSTALL_CMD
install_tool() {
    local user="$1"
    local name="$2"
    local bin="$3"
    local install_cmd="$4"

    if [ "$DRY_RUN" != "yes" ] && user_has_command "$user" "$bin"; then
        log "$name already installed for $user"
        return 0
    fi

    log "Installing $name for $user"
    user_login_run "$user" "$install_cmd"
}

main() {
    require_supported_os
    require_command curl
    load_profile "$PROFILE"

    local user
    user="$(target_user)"
    [ "$user" != "root" ] || die "developer tools install into a user home; run via sudo from the target login user"

    if [ "${INSTALL_CLAUDE:-yes}" = "yes" ]; then
        install_tool "$user" "Claude Code" claude \
            'curl -fsSL https://claude.ai/install.sh | bash'
    fi

    if [ "${INSTALL_CODEX:-yes}" = "yes" ]; then
        install_tool "$user" "Codex CLI" codex \
            'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
    fi
}

main "$@"
