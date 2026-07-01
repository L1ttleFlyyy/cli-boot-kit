#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: ssh-hardening.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    require_command systemctl

    local root
    local ssh_port
    local user
    local group
    local user_home
    local keys_file
    root="$(repo_root)"
    keys_file="$root/config/authorized_keys"

    load_profile "$PROFILE"
    ssh_port="${SSH_PORT:?SSH_PORT must be set in the profile or config/ssh.env}"
    user="$(target_user)"
    group="$(id -gn "$user")"
    user_home="$(home_for_user "$user")"
    [ -n "$user_home" ] || die "cannot determine home directory for $user"
    ensure_authorized_keys "$keys_file"

    log "Installing OpenSSH server"
    if is_fedora; then
        pkg_install openssh-server policycoreutils-python-utils
    else
        pkg_install openssh-server
    fi

    log "Installing authorized keys for $user"
    run install -d -m 700 -o "$user" -g "$group" "$user_home/.ssh"
    local authkeys="$user_home/.ssh/authorized_keys"
    if [ -e "$authkeys" ]; then
        info "$authkeys already exists; leaving it untouched (no overwrite/merge)"
    else
        run install -m 600 -o "$user" -g "$group" "$keys_file" "$authkeys"
    fi

    configure_selinux_port "$ssh_port"

    log "Writing OpenSSH hardening drop-in"
    run install -d -m 755 /etc/ssh/sshd_config.d
    write_file /etc/ssh/sshd_config.d/10-cli-boot-kit.conf <<EOF
# Managed by cli-boot-kit/scripts/modules/ssh-hardening.sh
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

    log "Opening SSH port $ssh_port in the firewall"
    firewall_allow_port "$ssh_port" tcp

    log "Validating and restarting SSH"
    run sshd -t
    if ssh_socket_activated; then
        # Debian/Ubuntu: systemd-ssh-generator derives the socket port from the
        # sshd_config Port directive, so reload then restart ssh.socket.
        run systemctl daemon-reload
        run systemctl enable ssh.socket
        run systemctl restart ssh.socket
    else
        run systemctl enable "$(ssh_unit)"
        run systemctl restart "$(ssh_unit)"
    fi
}

configure_selinux_port() {
    local ssh_port="$1"

    if ! is_fedora && ! has_semanage; then
        info "SELinux not in use; skipping ssh_port_t configuration"
        return 0
    fi

    log "Allowing SSH port $ssh_port in SELinux"
    # `semanage port -l` prints: "<type>  <proto>  <port>[, <port>...]", so the
    # proto is field 2 and ports are fields 3..NF (comma-separated).
    if [ "$DRY_RUN" = "yes" ]; then
        run semanage port -a -t ssh_port_t -p tcp "$ssh_port"
    elif semanage port -l |
        awk '$1 == "ssh_port_t" && $2 == "tcp" { for (i = 3; i <= NF; i++) { gsub(/,/, "", $i); print $i } }' |
        grep -qx "$ssh_port"; then
        log "SELinux already allows ssh_port_t tcp/$ssh_port"
    elif semanage port -a -t ssh_port_t -p tcp "$ssh_port" 2>/dev/null; then
        log "Added SELinux ssh_port_t tcp/$ssh_port"
    else
        semanage port -m -t ssh_port_t -p tcp "$ssh_port"
        log "Modified SELinux ssh_port_t tcp/$ssh_port"
    fi
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

    [ -t 0 ] || die "missing config/authorized_keys; add tracked SSH public keys before running non-interactively"

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
