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

resolve_shell_path() {
    local shell_name="$1"
    local candidate

    for candidate in "/usr/bin/$shell_name" "/bin/$shell_name"; do
        if [ -x "$candidate" ] && grep -qxF "$candidate" /etc/shells; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    command -v "$shell_name"
}

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
    shell_path="$(resolve_shell_path "$shell_name")"
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
