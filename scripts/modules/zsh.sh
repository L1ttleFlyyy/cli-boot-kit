#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: zsh.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    load_profile "$PROFILE"

    local shell_name
    local shell_path
    local user
    shell_name="${DEFAULT_SHELL:-zsh}"
    require_command chsh
    require_command "$shell_name"
    shell_path="$(command -v "$shell_name")"
    user="$(target_user)"

    if ! grep -qxF "$shell_path" /etc/shells; then
        log "Adding $shell_path to /etc/shells"
        if [ "$DRY_RUN" = "yes" ]; then
            show_command append "$shell_path" to /etc/shells
        else
            printf '%s\n' "$shell_path" >> /etc/shells
        fi
    fi

    log "Changing default shell for $user to $shell_path"
    run chsh -s "$shell_path" "$user"
}

main "$@"
