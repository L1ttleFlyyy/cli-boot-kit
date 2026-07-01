#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: setup-tailscale-exit-node.sh <profile> [--dry-run]"
    echo
    echo "Installs the OS-level networking an exit node needs: IP forwarding"
    echo "sysctl + a UDP GRO optimization service. Reads TAILSCALE_NETDEV"
    echo "(empty => auto-detect) from the profile. This does NOT touch Tailscale"
    echo "account state: 'tailscale up' and --advertise-exit-node stay manual."
    echo "Default is apply; pass --dry-run to preview."
}

parse_runtime_args "$@"

detect_default_netdev() {
    ip -o route get 8.8.8.8 | awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev") {
                print $(i + 1)
                exit
            }
        }
    }'
}

verify_forwarding() {
    local ipv4_forward ipv6_forward
    ipv4_forward="$(sysctl -n net.ipv4.ip_forward)"
    ipv6_forward="$(sysctl -n net.ipv6.conf.all.forwarding)"
    if [ "$ipv4_forward" != "1" ] || [ "$ipv6_forward" != "1" ]; then
        die "forwarding verification failed: ip_forward=$ipv4_forward all.forwarding=$ipv6_forward"
    fi
}

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    load_profile "$PROFILE"
    require_command awk
    require_command sysctl

    local netdev
    netdev="${TAILSCALE_NETDEV:-}"
    if [ -z "$netdev" ]; then
        require_command ip
        netdev="$(detect_default_netdev)"
    fi
    [ -n "$netdev" ] || die "could not determine egress interface; set TAILSCALE_NETDEV in the profile"

    info "Egress interface: $netdev"

    log "Writing exit-node forwarding sysctl"
    write_file /etc/sysctl.d/99-tailscale-exit-node.conf <<'EOF'
# Managed by cli-boot-kit/scripts/setup-tailscale-exit-node.sh
# IP forwarding an exit node / subnet router needs. Registration and
# --advertise-exit-node are intentionally left to a manual `tailscale up`.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    run sysctl --system
    if [ "$DRY_RUN" != "yes" ]; then
        verify_forwarding
    fi

    log "Writing Tailscale network optimization service"
    write_file /etc/systemd/system/tailscale-network-optimize.service <<EOF
[Unit]
Description=Tailscale exit node network optimization
Documentation=https://tailscale.com/docs/reference/best-practices/performance
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -K ${netdev} rx-udp-gro-forwarding on rx-gro-list off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now tailscale-network-optimize.service

    info "Services installed. Register and advertise manually, e.g.:"
    info "  sudo tailscale up --advertise-exit-node"
}

main "$@"
