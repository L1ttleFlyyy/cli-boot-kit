#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: setup-tailscale-exit-node.sh <profile> [--dry-run]"
    echo
    echo "Configures Linux networking for a Tailscale exit node. Reads"
    echo "TAILSCALE_NETDEV (empty => auto-detect) and ADVERTISE_EXIT_NODE from"
    echo "the profile. Default is apply; pass --dry-run to preview."
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

    local advertise netdev
    advertise="${ADVERTISE_EXIT_NODE:-no}"
    netdev="${TAILSCALE_NETDEV:-}"
    if [ -z "$netdev" ]; then
        require_command ip
        netdev="$(detect_default_netdev)"
    fi
    [ -n "$netdev" ] || die "could not determine egress interface; set TAILSCALE_NETDEV in the profile"

    info "Egress interface: $netdev"
    info "Advertise exit node: $advertise"

    log "Writing exit-node forwarding sysctl"
    write_file /etc/sysctl.d/99-tailscale-exit-node.conf <<'EOF'
# Managed by cli-boot-kit/scripts/setup-tailscale-exit-node.sh
# Required when this host advertises itself as a Tailscale exit node.
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

    if [ "$advertise" = "yes" ]; then
        require_command tailscale
        run tailscale set --advertise-exit-node
    else
        info "ADVERTISE_EXIT_NODE != yes; not advertising as an exit node."
    fi
}

main "$@"
