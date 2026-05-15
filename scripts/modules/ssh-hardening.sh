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
    echo "Usage: ssh-hardening.sh [--dry-run]"
    exit 0
fi

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_fedora
    require_command dnf
    require_command systemctl

    local root
    local ssh_port
    local user
    local group
    local user_home
    local keys_file
    root="$(repo_root)"
    keys_file="$root/config/authorized_keys"

    # shellcheck disable=SC1091
    . "$root/config/ssh.env"
    ssh_port="${SSH_PORT:?SSH_PORT must be set in config/ssh.env}"
    user="$(target_user)"
    group="$(id -gn "$user")"
    user_home="$(home_for_user "$user")"
    [ -n "$user_home" ] || die "cannot determine home directory for $user"
    ensure_authorized_keys "$keys_file"

    log "Installing SSH/SELinux helpers"
    run dnf install -y openssh-server policycoreutils-python-utils

    log "Installing authorized keys for $user"
    run install -d -m 700 -o "$user" -g "$group" "$user_home/.ssh"
    run install -m 600 -o "$user" -g "$group" "$keys_file" "$user_home/.ssh/authorized_keys"

    log "Allowing SSH port $ssh_port in SELinux"
    if [ "$DRY_RUN" = "yes" ]; then
        run semanage port -a -t ssh_port_t -p tcp "$ssh_port"
    elif semanage port -l | awk '$1 == "ssh_port_t" && $3 == "tcp" { print $4 }' | tr ',' '\n' | grep -qx "$ssh_port"; then
        log "SELinux already allows ssh_port_t tcp/$ssh_port"
    elif semanage port -a -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null; then
        log "Added SELinux ssh_port_t tcp/$ssh_port"
    else
        semanage port -m -t ssh_port_t -p tcp "$ssh_port"
    fi

    log "Writing OpenSSH hardening drop-in"
    if [ "$DRY_RUN" = "yes" ]; then
        show_command write /etc/ssh/sshd_config.d/10-fedora-server-setup.conf
    else
        install -d -m 755 /etc/ssh/sshd_config.d
        cat > /etc/ssh/sshd_config.d/10-fedora-server-setup.conf <<EOF
# Managed by fedora-server-setup/scripts/modules/ssh-hardening.sh
Port ${ssh_port}
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
UsePAM yes
EOF
    fi

    log "Opening SSH port $ssh_port in firewalld when active"
    if [ "$DRY_RUN" = "yes" ]; then
        run firewall-cmd --permanent --add-port="${ssh_port}/tcp"
        run firewall-cmd --reload
    elif systemctl is-active --quiet firewalld; then
        run firewall-cmd --permanent --add-port="${ssh_port}/tcp"
        run firewall-cmd --reload
    else
        log "firewalld is not active; skipping firewall port update"
    fi

    run sshd -t
    run systemctl enable sshd
    run systemctl restart sshd
}

ensure_authorized_keys() {
    local keys_file="$1"
    local line
    local count=0

    if [ -s "$keys_file" ]; then
        return 0
    fi

    if [ "$DRY_RUN" = "yes" ]; then
        warn "Missing local config/authorized_keys; real run will prompt for SSH public keys."
        return 0
    fi

    [ -t 0 ] || die "missing config/authorized_keys; create it from config/authorized_keys.example before running non-interactively"

    warn "Missing local config/authorized_keys."
    info "Paste one SSH public key per line, then press Enter on an empty line to finish."
    printf '\a' >&2
    umask 077
    : > "$keys_file"

    while IFS= read -r line; do
        [ -n "$line" ] || break
        case "$line" in
            ssh-*|ecdsa-*)
                printf '%s\n' "$line" >> "$keys_file"
                count=$((count + 1))
                ;;
            *)
                rm -f "$keys_file"
                die "invalid SSH public key line; expected ssh-* or ecdsa-*"
                ;;
        esac
    done

    [ "$count" -gt 0 ] || {
        rm -f "$keys_file"
        die "no SSH public keys provided"
    }
    success "Saved $count SSH public key(s) to local config/authorized_keys"
}

main "$@"
