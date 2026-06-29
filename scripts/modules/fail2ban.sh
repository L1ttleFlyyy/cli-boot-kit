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
    echo "Usage: fail2ban.sh [--dry-run]"
    exit 0
fi

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    require_command systemctl
    load_defaults

    local root
    local ssh_port
    local banaction
    local tailnet
    root="$(repo_root)"
    # shellcheck disable=SC1091
    . "$root/config/ssh.env"
    ssh_port="${SSH_PORT:?SSH_PORT must be set in config/ssh.env}"
    tailnet="${TRUSTED_TAILNET_CIDR:-100.64.0.0/10}"

    log "Installing fail2ban"
    if is_fedora; then
        pkg_install fail2ban fail2ban-firewalld
        banaction="firewallcmd-rich-rules"
    else
        pkg_install fail2ban
        banaction="ufw"
    fi

    log "Writing fail2ban sshd jail (banaction=$banaction)"
    run install -d -m 755 /etc/fail2ban/jail.d
    write_file /etc/fail2ban/jail.d/sshd.local <<EOF
# Managed by cli-boot-kit/scripts/modules/fail2ban.sh
[sshd]
enabled = true
port = ${ssh_port}
filter = sshd[mode=aggressive]
backend = systemd
maxretry = 3
banaction = ${banaction}
bantime = 432000
findtime = 10800
ignoreip = 127.0.0.0/8 ::1 ${tailnet}
EOF

    run systemctl enable fail2ban
    run systemctl restart fail2ban
    if [ "$DRY_RUN" != "yes" ]; then
        sleep 2
        run fail2ban-client status sshd
    fi
}

main "$@"
