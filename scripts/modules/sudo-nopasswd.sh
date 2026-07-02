#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: sudo-nopasswd.sh <profile> [--dry-run]"
    echo
    echo "Grants passwordless sudo to the target login user via a validated"
    echo "/etc/sudoers.d drop-in. Intended to pair with setting a login password"
    echo "(for Cockpit / console PAM auth) so that gaining a password does not"
    echo "reintroduce sudo prompts."
    echo
    echo "SECURITY MODEL: the security boundary is the firewall, not the"
    echo "password. Cockpit is tailnet-only (9090 never public) and SSH is"
    echo "key-only (PasswordAuthentication no), so the login password only serves"
    echo "PAM and passwordless sudo does not widen the attack surface. Off by"
    echo "default (SUDO_NOPASSWD=yes to enable) only to keep it an explicit"
    echo "per-host choice, not because reachability warrants a password prompt."
}

parse_runtime_args "$@"

DROPIN=/etc/sudoers.d/99-cli-boot-kit-nopasswd
# Leading dot => sudo's includedir skips it, so a half-written temp is never
# loaded; validated with `visudo -cf` before it is installed under the real name.
DROPIN_TMP=/etc/sudoers.d/.99-cli-boot-kit-nopasswd.tmp

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    require_command visudo
    load_profile "$PROFILE"

    local user
    user="$(target_user)"
    if [ "$user" = "root" ]; then
        die "target user resolved to root; run via sudo from the target login user"
    fi

    log "Writing passwordless-sudo drop-in for $user"
    write_file "$DROPIN_TMP" <<EOF
# Managed by cli-boot-kit/scripts/modules/sudo-nopasswd.sh
# Passwordless sudo for the target login user. Paired with a real password
# (set via \`passwd\` for Cockpit/console PAM login) so that gaining a password
# does not reintroduce sudo prompts. Ordered after 90-cloud-init-users to stay
# authoritative even if cloud-init rewrites its own drop-in.
${user} ALL=(ALL) NOPASSWD:ALL
EOF

    log "Validating drop-in before activating it"
    run visudo -cf "$DROPIN_TMP"
    run install -m 0440 -o root -g root "$DROPIN_TMP" "$DROPIN"
    run rm -f "$DROPIN_TMP"

    log "Validating the full sudoers configuration"
    run visudo -c
}

main "$@"
