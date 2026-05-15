#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: setup-tailscale-exit-node.sh [--dry-run] [--apply] [--netdev IFACE] [--advertise-exit-node]

Configures Fedora networking for a Tailscale exit node.

Options:
  --dry-run              Show detected state and planned changes.
  --apply                Write system config and start the optimization service.
  --netdev IFACE         Use IFACE instead of detecting the default egress interface.
  --advertise-exit-node  Run "tailscale set --advertise-exit-node" after apply.
  -h, --help             Show this help.
USAGE
}

MODE="dry-run"
ADVERTISE_EXIT_NODE="no"
NETDEV_OVERRIDE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            MODE="dry-run"
            ;;
        --apply)
            MODE="apply"
            ;;
        --netdev)
            if [ "$#" -lt 2 ]; then
                echo "--netdev requires an interface name." >&2
                exit 2
            fi
            NETDEV_OVERRIDE="$2"
            shift
            ;;
        --advertise-exit-node)
            ADVERTISE_EXIT_NODE="yes"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

require_root_for_apply() {
    if [ "$MODE" = "apply" ] && [ "${EUID}" -ne 0 ]; then
        echo "Apply mode must run as root. Use sudo." >&2
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

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

write_sysctl_config() {
    local target="/etc/sysctl.d/99-tailscale-exit-node.conf"

    cat > "$target" <<'EOF'
# Managed by fedora-server-setup/scripts/setup-tailscale-exit-node.sh
# Required when this host advertises itself as a Tailscale exit node.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    sysctl --system
}

verify_forwarding() {
    local ipv4_forward
    local ipv6_forward

    ipv4_forward="$(sysctl -n net.ipv4.ip_forward)"
    ipv6_forward="$(sysctl -n net.ipv6.conf.all.forwarding)"

    if [ "$ipv4_forward" != "1" ] || [ "$ipv6_forward" != "1" ]; then
        echo "Forwarding verification failed:" >&2
        echo "  net.ipv4.ip_forward = $ipv4_forward" >&2
        echo "  net.ipv6.conf.all.forwarding = $ipv6_forward" >&2
        exit 1
    fi
}

write_systemd_service() {
    local netdev="$1"
    local service="/etc/systemd/system/tailscale-network-optimize.service"

    cat > "$service" <<EOF
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

    systemctl daemon-reload
    systemctl enable --now tailscale-network-optimize.service
}

show_plan() {
    local netdev="$1"

    echo "Mode: $MODE"
    echo "Default egress interface: $netdev"
    echo
    echo "Planned persistent sysctl settings:"
    echo "  /etc/sysctl.d/99-tailscale-exit-node.conf"
    echo "  net.ipv4.ip_forward = 1"
    echo "  net.ipv6.conf.all.forwarding = 1"
    echo
    echo "Planned persistent Tailscale performance service:"
    echo "  /etc/systemd/system/tailscale-network-optimize.service"
    echo "  ethtool -K $netdev rx-udp-gro-forwarding on rx-gro-list off"
    echo

    if [ "$ADVERTISE_EXIT_NODE" = "yes" ]; then
        echo "Will advertise this machine as a Tailscale exit node."
    else
        echo "Will not advertise this machine as an exit node unless --advertise-exit-node is passed."
    fi
}

main() {
    require_root_for_apply
    require_command awk
    require_command sysctl

    local netdev
    if [ -n "$NETDEV_OVERRIDE" ]; then
        netdev="$NETDEV_OVERRIDE"
    else
        require_command ip
        netdev="$(detect_default_netdev)"
    fi
    if [ -z "$netdev" ]; then
        echo "Could not detect default egress interface." >&2
        exit 1
    fi

    show_plan "$netdev"

    if [ "$MODE" = "dry-run" ]; then
        exit 0
    fi

    require_command ethtool
    require_command systemctl
    require_command tailscale

    write_sysctl_config
    verify_forwarding
    write_systemd_service "$netdev"

    if [ "$ADVERTISE_EXIT_NODE" = "yes" ]; then
        tailscale set --advertise-exit-node
    fi

    echo
    echo "Verification:"
    sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
    systemctl --no-pager status tailscale-network-optimize.service
}

main "$@"
