#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

DRY_RUN="no"
ADVERTISE_EXIT_NODE="no"
NETDEV_ARGS=()
EXIT_NODE_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN="yes"
            ;;
        --advertise-exit-node)
            ADVERTISE_EXIT_NODE="yes"
            ;;
        --netdev)
            [ "$#" -ge 2 ] || die "--netdev requires an interface name"
            NETDEV_ARGS+=("--netdev" "$2")
            EXIT_NODE_ARGS+=("--netdev" "$2")
            shift
            ;;
        -h|--help)
            echo "Usage: tailscale.sh [--dry-run] [--netdev IFACE] [--advertise-exit-node]"
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    require_command curl

    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale using official installer"
        run_eval "curl -fsSL https://tailscale.com/install.sh | sh"
    fi

    pkg_install ethtool
    run systemctl enable --now tailscaled

    local root
    root="$(repo_root)"
    local args=("--apply")
    args+=("${EXIT_NODE_ARGS[@]}")
    if [ "$ADVERTISE_EXIT_NODE" = "yes" ]; then
        args+=("--advertise-exit-node")
    fi

    if [ "$DRY_RUN" = "yes" ]; then
        local dry_args=("--dry-run")
        dry_args+=("${NETDEV_ARGS[@]}")
        if [ "$ADVERTISE_EXIT_NODE" = "yes" ]; then
            dry_args+=("--advertise-exit-node")
        fi
        "$root/scripts/setup-tailscale-exit-node.sh" "${dry_args[@]}"
    else
        "$root/scripts/setup-tailscale-exit-node.sh" "${args[@]}"
    fi
}

main "$@"
