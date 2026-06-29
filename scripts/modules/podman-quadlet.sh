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
    echo "Usage: podman-quadlet.sh [--dry-run]"
    echo
    echo "Install the Podman + systemd Quadlet toolchain only. This module does"
    echo "NOT deploy any specific workload (e.g. AdGuard Home); per-service"
    echo "*.container units are managed out-of-band (e.g. via chezmoi or a"
    echo "dedicated repo) and dropped into /etc/containers/systemd."
    exit 0
fi

# Known locations for the Quadlet systemd generator across distros/versions.
QUADLET_GENERATORS=(
    /usr/lib/systemd/system-generators/podman-system-generator
    /usr/libexec/systemd/system-generators/podman-system-generator
)

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    require_command systemctl

    log "Installing Podman"
    pkg_install podman

    verify_podman
    verify_quadlet_generator

    log "Ensuring system Quadlet unit directory /etc/containers/systemd"
    run install -d -m 755 /etc/containers/systemd

    # Reload so the Quadlet generator runs and materializes any *.container
    # units already present. Placing/updating unit files is intentionally left
    # to the per-service tooling that owns them.
    log "Reloading systemd to run the Quadlet generator"
    run systemctl daemon-reload

    success "Podman + Quadlet toolchain ready."
    info "Drop *.container units into /etc/containers/systemd, then:"
    info "  sudo systemctl daemon-reload && sudo systemctl start <name>.service"
}

verify_podman() {
    if [ "$DRY_RUN" = "yes" ]; then
        run podman --version
        return 0
    fi
    require_command podman
    log "Installed $(podman --version)"
}

verify_quadlet_generator() {
    local gen
    if [ "$DRY_RUN" = "yes" ]; then
        info "Would verify Quadlet generator in: ${QUADLET_GENERATORS[*]}"
        return 0
    fi
    for gen in "${QUADLET_GENERATORS[@]}"; do
        if [ -x "$gen" ]; then
            log "Found Quadlet generator: $gen"
            return 0
        fi
    done
    die "Quadlet generator not found; podman is too old for Quadlet (need >= 4.4). Checked: ${QUADLET_GENERATORS[*]}"
}

main "$@"
