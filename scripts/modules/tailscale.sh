#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: tailscale.sh <profile> [--dry-run]"
    echo
    echo "Reads TAILSCALE_NETDEV / ADVERTISE_EXIT_NODE from the profile and"
    echo "delegates exit-node networking to setup-tailscale-exit-node.sh."
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    load_profile "$PROFILE"
    require_command curl

    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale using official installer"
        run_eval "curl -fsSL https://tailscale.com/install.sh | sh"
    fi

    pkg_install ethtool
    run systemctl enable --now tailscaled

    local root
    root="$(repo_root)"
    local exit_node_args=("$PROFILE")
    if [ "$DRY_RUN" = "yes" ]; then
        exit_node_args+=("--dry-run")
    fi
    "$root/scripts/setup-tailscale-exit-node.sh" "${exit_node_args[@]}"
}

main "$@"
