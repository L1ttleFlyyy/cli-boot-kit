#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

DRY_RUN="no"
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN="yes"
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: zsh.sh [--dry-run]"
    exit 0
fi

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_command chsh
    require_command zsh

    local shell_path
    local user
    shell_path="$(command -v zsh)"
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
