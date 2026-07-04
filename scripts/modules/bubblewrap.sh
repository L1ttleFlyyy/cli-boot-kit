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

# Homebrew pulls in its own bubblewrap (a gcc/binutils dependency installed by
# brew-bundle) whose symlink shadows /usr/bin/bwrap on the user's login-shell
# PATH. AppArmor attaches profiles by resolved executable path, so that binary
# must be listed in the attachment too or it stays userns-restricted.
BREW_BWRAP_LINK="/home/linuxbrew/.linuxbrew/bin/bwrap"
BREW_BWRAP_GLOB="home/linuxbrew/.linuxbrew/Cellar/bubblewrap/*/bin/bwrap"

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
        return 0
    fi

    # Test every bwrap the user can reach, not just the one first on this
    # script's PATH: the brew copy resolves first in login shells.
    local bin
    for bin in /usr/bin/bwrap "$BREW_BWRAP_LINK"; do
        [ -x "$bin" ] || continue
        if bwrap_works_for "$user" "$bin"; then
            success "bwrap user namespace sandbox works for $user ($bin)"
        else
            die "bwrap verification failed for $user ($bin); check AppArmor unprivileged userns restriction"
        fi
    done
}

bwrap_works_for() {
    local user="$1"
    local bin="$2"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" "$bin" --unshare-user --uid 0 --gid 0 --ro-bind / / true
    else
        "$bin" --unshare-user --uid 0 --gid 0 --ro-bind / / true
    fi
}

install_apparmor_profile() {
    if [ "$DRY_RUN" = "yes" ]; then
        run install -m 0644 "$PROFILE_SRC" "$PROFILE_DST"
        show_command_text "extend attachment to /{usr/bin/bwrap,${BREW_BWRAP_GLOB}}"
        run apparmor_parser -r "$PROFILE_DST"
        return 0
    fi

    if [ ! -r "$PROFILE_SRC" ]; then
        warn "AppArmor profile $PROFILE_SRC not found; skipping (verify bwrap below)"
        return 0
    fi

    log "Loading AppArmor profile bwrap-userns-restrict"
    install -m 0644 "$PROFILE_SRC" "$PROFILE_DST"
    extend_attachment_for_brew
    if command -v apparmor_parser >/dev/null 2>&1; then
        apparmor_parser -r "$PROFILE_DST"
    else
        warn "apparmor_parser not available; profile installed but not loaded"
    fi
}

# Rewrite the stock single-path attachment into an alternation covering the
# Homebrew Cellar copy. Operates on our freshly installed copy every run, so
# it stays idempotent; if the stock attachment line ever changes shape, warn
# instead of loading a profile we did not extend.
extend_attachment_for_brew() {
    if grep -q '^profile bwrap /usr/bin/bwrap ' "$PROFILE_DST"; then
        sed -i "s|^profile bwrap /usr/bin/bwrap |profile bwrap /{usr/bin/bwrap,${BREW_BWRAP_GLOB}} |" "$PROFILE_DST"
    else
        warn "unexpected attachment line in $PROFILE_DST; Homebrew bwrap will stay userns-restricted"
    fi
}

main "$@"
