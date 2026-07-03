#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
    echo "Usage: cockpit.sh <profile> [--dry-run]"
    echo
    echo "Installs the Cockpit web console and enables cockpit.socket. On"
    echo "Debian/Ubuntu it pulls Cockpit from the distro's backports pocket"
    echo "(newer than the release pocket). Fedora ships Cockpit by default, so"
    echo "this module is a no-op there."
    echo
    echo "No firewall rule is opened: Cockpit listens on tcp/9090, which stays"
    echo "unreachable from the public interface (ufw default-deny) and reachable"
    echo "only over the tailnet, whose traffic Tailscale's own ts-input chain"
    echo "accepts ahead of ufw."
}

parse_runtime_args "$@"

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    load_profile "$PROFILE"

    if is_fedora; then
        info "Fedora ships Cockpit by default; nothing to install."
        return 0
    fi

    if ! is_debian_like; then
        warn "Cockpit module only handles Debian/Ubuntu; skipping on ${OS_ID:-unknown}."
        return 0
    fi

    # Ubuntu/Debian keep Cockpit in the backports pocket (e.g. noble-backports),
    # which ships a much newer release than the base pocket. The pocket is
    # enabled by default on Ubuntu; read VERSION_CODENAME from os-release to
    # target it explicitly, matching the official install instructions.
    local codename=""
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    fi
    if [ -z "$codename" ]; then
        die "cannot determine VERSION_CODENAME from /etc/os-release; needed for the backports pocket"
    fi

    # cockpit-podman is the container UI; install it only when this host also
    # runs the Podman/Quadlet toolchain, so the plugin tracks whether there is
    # anything for it to manage. We do NOT install cockpit-pcp: the Metrics/PCP
    # integration moved into cockpit-bridge as of Cockpit 236+, which now
    # Conflicts with the obsolete standalone package. (For long-term history
    # graphs, install the `pcp` daemon separately.)
    local pkgs=(cockpit)
    local with_podman="no"
    if [ "${INSTALL_PODMAN_QUADLET:-no}" = "yes" ]; then
        pkgs+=(cockpit-podman)
        with_podman="yes"
    fi

    log "Installing Cockpit (${pkgs[*]}) from ${codename}-backports"
    pkg_refresh
    run env DEBIAN_FRONTEND=noninteractive \
        apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" \
        install -y -t "${codename}-backports" "${pkgs[@]}"

    run systemctl enable --now cockpit.socket

    if [ "$with_podman" = "yes" ]; then
        # cockpit-podman talks to the rootful Podman API socket; enable it so the
        # container UI works on first load instead of needing the "Start podman"
        # button. Guard on the unit existing (podman may not be installed yet in
        # a standalone run).
        if [ "$DRY_RUN" = "yes" ] || systemctl list-unit-files podman.socket >/dev/null 2>&1; then
            run systemctl enable --now podman.socket
        else
            warn "podman.socket unit not found; start Podman from the Cockpit UI, or run podman-quadlet.sh first."
        fi
    fi

    info "Cockpit listening on tcp/9090; reach it over the tailnet (no public firewall rule added)."
}

main "$@"
