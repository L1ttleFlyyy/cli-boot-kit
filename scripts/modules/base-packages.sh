#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: base-packages.sh <profile> [--dry-run]"
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    load_profile "$PROFILE"

    local packages
    if is_fedora; then
        packages=(git zsh curl file procps-ng gcc gcc-c++ make ca-certificates glibc-langpack-en)
    else
        packages=(git zsh curl file procps build-essential ca-certificates locales)
    fi

    log "Installing base packages: ${packages[*]}"
    pkg_install "${packages[@]}"

    ensure_en_us_locale
}

# Desktop SSH clients (macOS Terminal/iTerm by default) forward
# LANG/LC_*=en_US.UTF-8, and sshd's stock AcceptEnv accepts them. If the
# locale is not generated server-side, every subprocess in the session warns
# "setlocale: LC_ALL: cannot change locale". Fedora ships it pre-built in
# glibc-langpack-en; Ubuntu minimal images only have C.UTF-8 until generated.
ensure_en_us_locale() {
    if is_fedora; then
        return 0
    fi
    if [ "$DRY_RUN" != "yes" ] && locale -a 2>/dev/null | grep -qix 'en_US.utf8'; then
        log "en_US.UTF-8 locale already generated"
        return 0
    fi
    run locale-gen en_US.UTF-8
}

main "$@"
