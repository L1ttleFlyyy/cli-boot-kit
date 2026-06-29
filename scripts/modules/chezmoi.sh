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
    echo "Usage: chezmoi.sh [--dry-run]"
    exit 0
fi

# Make Homebrew available even on a fresh host where the non-interactive
# Homebrew install has not yet added brew to the login PATH (chezmoi is normally
# provided by brew-bundle, which runs before this module).
# shellcheck disable=SC2016  # expansion is deferred to the target login shell
BREW_PRELUDE='[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"; '

# Run a command as the target user through a login shell with Homebrew on PATH.
# Falls back to a direct shell when already running as that user.
user_login_run() {
    local user="$1"
    local cmd="$2"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        run sudo -H -u "$user" bash -lc "${BREW_PRELUDE}${cmd}"
    else
        run bash -lc "${BREW_PRELUDE}${cmd}"
    fi
}

user_has_chezmoi() {
    local user="$1"

    if [ "${EUID}" -eq 0 ] && [ "$user" != "root" ]; then
        sudo -H -u "$user" bash -lc "${BREW_PRELUDE}command -v chezmoi >/dev/null 2>&1"
    else
        bash -lc "${BREW_PRELUDE}command -v chezmoi >/dev/null 2>&1"
    fi
}

main() {
    require_supported_os
    load_defaults

    local user
    local repo
    user="$(target_user)"
    repo="${CHEZMOI_REPO:-l1ttleflyyy}"

    if [ "$DRY_RUN" = "yes" ] || ! user_has_chezmoi "$user"; then
        if [ "$DRY_RUN" != "yes" ]; then
            log "chezmoi not found on PATH; installing"
        fi
        if is_fedora; then
            if [ "$DRY_RUN" != "yes" ]; then
                require_root
            fi
            pkg_install chezmoi
        else
            # Debian/Ubuntu has no reliable chezmoi apt package; use the official
            # installer into the target user's ~/.local/bin. Expansion is
            # intentionally deferred to the target user's login shell.
            # shellcheck disable=SC2016
            user_login_run "$user" 'sh -c "$(curl -fsSL https://get.chezmoi.io)" -- -b "$HOME/.local/bin"'
        fi
    else
        log "chezmoi already installed for $user"
    fi

    log "Applying chezmoi dotfiles ($repo) for $user"
    user_login_run "$user" "chezmoi init $(printf '%q' "$repo") --apply"
}

main "$@"
