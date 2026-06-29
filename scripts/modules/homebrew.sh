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
    require_supported_os
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

    # shellcheck disable=SC2016  # $() is intentionally evaluated later by run_eval
    local install_cmd='NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

    log "Installing Homebrew for Linux as $user"
    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        run_eval "sudo -H -u $user bash -lc '$install_cmd'"
    else
        run_eval "$install_cmd"
    fi
}

main "$@"
