#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: bubblewrap.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

PROFILE_SRC="/usr/share/apparmor/extra-profiles/bwrap-userns-restrict"
PROFILE_DST="/etc/apparmor.d/bwrap-userns-restrict"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    load_profile "$PROFILE"

    log "Installing bubblewrap"
    if is_fedora; then
        pkg_install bubblewrap
    else
        # Ubuntu 24.04 restricts unprivileged user namespaces via AppArmor; the
        # bwrap profile ships in apparmor-profiles and must be loaded for Codex
        # sandboxing to work without disabling the namespace restriction.
        pkg_install bubblewrap apparmor-profiles apparmor-utils
        install_apparmor_profile
    fi

    # Verify as the target user, not root: kernel.apparmor_restrict_unprivileged_userns
    # only restricts unprivileged users, so a root check passes even when the
    # AppArmor profile failed to load — and the whole point of this module is
    # unprivileged sandboxing.
    local user
    user="$(target_user)"
    log "Verifying bubblewrap (as $user)"
    if [ "$DRY_RUN" = "yes" ]; then
        show_command bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true
    elif bwrap_works_for "$user"; then
        success "bwrap user namespace sandbox works for $user"
    else
        die "bwrap verification failed for $user; check AppArmor unprivileged userns restriction"
    fi
}

bwrap_works_for() {
    local user="$1"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true
    else
        bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true
    fi
}

install_apparmor_profile() {
    if [ "$DRY_RUN" = "yes" ]; then
        run install -m 0644 "$PROFILE_SRC" "$PROFILE_DST"
        run apparmor_parser -r "$PROFILE_DST"
        return 0
    fi

    if [ ! -r "$PROFILE_SRC" ]; then
        warn "AppArmor profile $PROFILE_SRC not found; skipping (verify bwrap below)"
        return 0
    fi

    log "Loading AppArmor profile bwrap-userns-restrict"
    install -m 0644 "$PROFILE_SRC" "$PROFILE_DST"
    if command -v apparmor_parser >/dev/null 2>&1; then
        apparmor_parser -r "$PROFILE_DST"
    else
        warn "apparmor_parser not available; profile installed but not loaded"
    fi
}

main "$@"
