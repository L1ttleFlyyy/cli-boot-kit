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
    echo "Usage: router-sysctl.sh [--dry-run]"
    exit 0
fi

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_command sysctl

    local target="/etc/sysctl.d/90-router-local.conf"

    log "Writing optional router sysctl settings"
    if [ "$DRY_RUN" = "yes" ]; then
        show_command write "$target"
    else
        cat > "$target" <<'EOF'
# Managed by fedora-server-setup/scripts/modules/router-sysctl.sh
# Optional router-oriented settings. Keep separate from Tailscale exit-node
# forwarding so they can be enabled only on hosts that need them.
net.ipv6.conf.all.accept_ra = 2
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
EOF
    fi

    run sysctl --system
}

main "$@"
