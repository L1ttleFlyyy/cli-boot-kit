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
    run ufw default allow routed

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

    log "Enabling firewalld"
    run systemctl enable --now firewalld

    log "Allowing SSH port $ssh_port/tcp"
    firewall_allow_port "$ssh_port" tcp
    run firewall-cmd --list-all
}

main "$@"
