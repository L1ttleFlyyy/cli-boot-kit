#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

DRY_RUN="no"
ADVERTISE_EXIT_NODE="no"
NETDEV=""
STEP_CURRENT=0
STEP_TOTAL=9

usage() {
    cat <<'USAGE'
Usage: bootstrap-fedora-server.sh [--dry-run] [--netdev IFACE] [--advertise-exit-node]

Interactive Fedora server bootstrap.

Options:
  --dry-run              Print actions without applying changes.
  --netdev IFACE         Pass IFACE to the optional Tailscale exit-node setup.
  --advertise-exit-node  If Tailscale is selected, advertise this host as an exit node.
  -h, --help             Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN="yes"
            ;;
        --netdev)
            [ "$#" -ge 2 ] || die "--netdev requires an interface name"
            NETDEV="$2"
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
            die "unknown argument: $1"
            ;;
    esac
    shift
done

run_module() {
    local module="$1"
    shift

    local args=()
    if [ "$DRY_RUN" = "yes" ]; then
        args+=("--dry-run")
    fi
    args+=("$@")

    next_step "$module"
    "$SCRIPT_DIR/modules/$module" "${args[@]}"
}

next_step() {
    local label="$1"

    STEP_CURRENT=$((STEP_CURRENT + 1))
    printf '\n'
    heading "==> Step ${STEP_CURRENT}/${STEP_TOTAL}: ${label}"
}

skip_step() {
    local label="$1"

    next_step "$label"
    info "Skipped."
}

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_fedora
    require_command dnf

    heading "Fedora server bootstrap"
    info "Target user: $(target_user)"
    if [ "$(target_user)" = "root" ]; then
        die "run this via sudo from the target login user; this bootstrap does not create normal users"
    fi
    if [ "$DRY_RUN" = "yes" ]; then
        info "Mode: dry-run"
    fi

    run_module dnf-essentials.sh
    run_module ssh-hardening.sh
    run_module homebrew.sh
    run_module brew-bundle.sh
    run_module chezmoi.sh
    run_module zsh.sh

    if confirm "Run optional Tailscale setup?" "yes"; then
        local tailscale_args=()
        if [ -n "$NETDEV" ]; then
            tailscale_args+=("--netdev" "$NETDEV")
        fi
        if [ "$ADVERTISE_EXIT_NODE" = "yes" ]; then
            tailscale_args+=("--advertise-exit-node")
        fi
        run_module tailscale.sh "${tailscale_args[@]}"
    else
        skip_step "tailscale.sh"
    fi

    if confirm "Apply optional router kernel parameters?" "no"; then
        run_module router-sysctl.sh
    else
        skip_step "router-sysctl.sh"
    fi

    next_step "system update"
    run dnf upgrade --refresh -y

    if [ "$DRY_RUN" = "yes" ]; then
        success "Dry-run complete; reboot skipped."
    elif confirm "Reboot now?" "yes"; then
        run systemctl reboot
    else
        warn "Reboot skipped. Reboot manually when convenient: sudo systemctl reboot"
    fi
}

main "$@"
