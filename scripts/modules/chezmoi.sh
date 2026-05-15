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
    echo "Usage: chezmoi.sh [--dry-run]"
    exit 0
fi

main() {
    local user
    user="$(target_user)"

    if ! command -v chezmoi >/dev/null 2>&1; then
        if [ "$DRY_RUN" = "yes" ]; then
            show_command dnf install -y chezmoi
            show_command chezmoi init l1ttleflyyy --apply
            return 0
        fi
        require_root
        require_command dnf
        log "Installing chezmoi from Fedora repositories"
        run dnf install -y chezmoi
    fi

    log "Applying chezmoi dotfiles for l1ttleflyyy as $user"
    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        run sudo -u "$user" chezmoi init l1ttleflyyy --apply
    else
        run chezmoi init l1ttleflyyy --apply
    fi
}

main "$@"
