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
    echo "Usage: base-packages.sh [--dry-run]"
    exit 0
fi

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os

    local packages
    if is_fedora; then
        packages=(git zsh curl file procps-ng gcc gcc-c++ make ca-certificates)
    else
        packages=(git zsh curl file procps build-essential ca-certificates)
    fi

    log "Installing base packages: ${packages[*]}"
    pkg_install "${packages[@]}"
}

main "$@"
