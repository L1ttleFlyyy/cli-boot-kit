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
    echo "Usage: homebrew.sh [--dry-run]"
    exit 0
fi

main() {
    require_fedora
    require_command curl
    require_command bash

    local user
    user="$(target_user)"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        if sudo -H -u "$user" bash -lc 'command -v brew >/dev/null 2>&1 || test -x /home/linuxbrew/.linuxbrew/bin/brew'; then
            log "Homebrew already installed for $user"
            return 0
        fi
    elif command -v brew >/dev/null 2>&1; then
        log "Homebrew already installed: $(command -v brew)"
        return 0
    fi

    log "Installing Homebrew for Linux as $user"
    if [ "$DRY_RUN" = "yes" ]; then
        if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
            show_command_text "sudo -H -u $user bash -lc 'NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"'"
        else
            show_command_text "NONINTERACTIVE=1 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        fi
    elif [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" bash -lc 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    else
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
}

main "$@"
