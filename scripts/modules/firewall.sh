#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: firewall.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    require_command systemctl

    local ssh_port
    load_profile "$PROFILE"
    ssh_port="${SSH_PORT:?SSH_PORT must be set in the profile or config/ssh.env}"

    case "$(firewall_kind)" in
        ufw)
            setup_ufw "$ssh_port"
            ;;
        firewalld)
            setup_firewalld "$ssh_port"
            ;;
        *)
            warn "No supported firewall manager found; skipping firewall setup"
            ;;
    esac
}

setup_ufw() {
    local ssh_port="$1"

    if ! command -v ufw >/dev/null 2>&1; then
        log "Installing ufw"
        pkg_install ufw
    fi

    log "Configuring ufw default policy"
    run ufw default deny incoming
    run ufw default allow outgoing
    # Forwarding policy governs only pass-through packets the kernel routes
    # between interfaces (dst IP is not this host). Userspace relays (SOCKS/HTTP
    # proxies, xray-style VPN servers) terminate locally and re-originate, so
    # they traverse INPUT/OUTPUT, never FORWARD — unaffected by this. The one
    # forwarding consumer, the Tailscale exit node, is accepted by tailscaled's
    # own ts-forward chain ahead of the ufw chains, so deny here fails closed:
    # tailscaled down means the host forwards nothing.
    run ufw default deny routed

    # Allow the SSH port before enabling so we never lock ourselves out.
    log "Allowing SSH port $ssh_port/tcp"
    run ufw allow "${ssh_port}/tcp"

    log "Enabling ufw"
    run ufw --force enable
    run ufw status verbose
}

setup_firewalld() {
    local ssh_port="$1"

    if ! command -v firewall-cmd >/dev/null 2>&1; then
        log "Installing firewalld"
        pkg_install firewalld
    fi

    # Allow SSH in the permanent config BEFORE starting the daemon (same
    # never-lock-ourselves-out order as the ufw path): sshd already listens on
    # $ssh_port from the previous module, and firewalld's default zone only
    # admits the stock ssh service (22). Enabling first would leave new SSH
    # connections blocked if anything fails between enable and allow.
    log "Allowing SSH port $ssh_port/tcp"
    if systemctl is-active --quiet firewalld; then
        firewall_allow_port "$ssh_port" tcp
    else
        run firewall-offline-cmd --add-port="${ssh_port}/tcp"
    fi

    log "Enabling firewalld"
    run systemctl enable --now firewalld
    run firewall-cmd --list-all
}

main "$@"
