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
    echo "Usage: brew-bundle.sh [--dry-run]"
    exit 0
fi

main() {
    local root
    local user
    root="$(repo_root)"
    user="$(target_user)"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        log "Installing Homebrew packages from Brewfile as $user"
        run_eval "sudo -H -u $user bash -lc 'eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"; brew bundle --file \"$root/Brewfile\"'"
        return 0
    fi

    if ! command -v brew >/dev/null 2>&1; then
        [ -x /home/linuxbrew/.linuxbrew/bin/brew ] || die "brew is not installed; run modules/homebrew.sh first"
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi
    log "Installing Homebrew packages from Brewfile"
    run brew bundle --file "$root/Brewfile"
}

main "$@"
