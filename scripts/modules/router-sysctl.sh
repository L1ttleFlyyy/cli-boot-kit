#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: router-sysctl.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    load_profile "$PROFILE"
    require_command sysctl

    local target="/etc/sysctl.d/90-router-local.conf"

    log "Writing optional router sysctl settings"
    write_file "$target" <<'EOF'
# Managed by cli-boot-kit/scripts/modules/router-sysctl.sh
# Optional router-oriented settings. Keep separate from Tailscale exit-node
# forwarding so they can be enabled only on hosts that need them.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv6.conf.all.accept_ra = 2
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
EOF

    run sysctl --system
}

main "$@"
