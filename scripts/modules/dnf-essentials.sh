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
    echo "Usage: dnf-essentials.sh [--dry-run]"
    exit 0
fi

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_fedora
    require_command dnf

    local packages=(
        git
        zsh
        curl
        file
        procps-ng
        gcc
        gcc-c++
        make
    )

    log "Installing Fedora essentials: ${packages[*]}"
    run dnf install -y "${packages[@]}"
}

main "$@"
