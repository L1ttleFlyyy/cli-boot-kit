#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STEP_CURRENT=0
STEP_TOTAL=16

usage() {
    cat <<'USAGE'
Usage: bootstrap.sh <profile> [--dry-run]

Cross-platform (Fedora / Debian-Ubuntu) server bootstrap. The profile
(profiles/<name>.env) declares the host's target state, including which optional
modules to run. Pass --dry-run to preview actions without applying them.
USAGE
}

parse_runtime_args "$@"

run_module() {
    local module="$1"
    shift

    next_step "$module"
    local args=("$PROFILE")
    if [ "$DRY_RUN" = "yes" ]; then
        args+=("--dry-run")
    fi
    args+=("$@")
    "$SCRIPT_DIR/modules/$module" "${args[@]}"
}

next_step() {
    local label="$1"

    STEP_CURRENT=$((STEP_CURRENT + 1))
    printf '\n'
    heading "==> Step ${STEP_CURRENT}/${STEP_TOTAL}: ${label}"
}

skip_step() {
    local label="$1"

    next_step "$label"
    info "Skipped."
}

apply_timezone() {
    next_step "timezone"
    local tz="${TIMEZONE:-}"
    if [ -z "$tz" ]; then
        info "TIMEZONE is empty; skipping timezone management."
        return 0
    fi
    if ! command -v timedatectl >/dev/null 2>&1; then
        warn "timedatectl not available; skipping timezone management."
        return 0
    fi
    log "Setting timezone to $tz"
    run timedatectl set-timezone "$tz"
}

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    require_supported_os
    if [ "$(pkg_manager)" = "none" ]; then
        die "no supported package manager (dnf/apt-get) found"
    fi
    load_profile "$PROFILE"

    heading "cli-boot-kit bootstrap"
    info "Profile: ${PROFILE_NAME} (${PROFILE_PATH})"
    info "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
    info "Target user: $(target_user)"
    if [ "$(target_user)" = "root" ]; then
        die "run this via sudo from the target login user; this bootstrap does not create normal users"
    fi
    if [ "$DRY_RUN" = "yes" ]; then
        info "Mode: dry-run"
    fi

    apply_timezone
    run_module base-packages.sh
    run_module ssh-hardening.sh
    run_module firewall.sh
    run_module fail2ban.sh
    run_module homebrew.sh
    run_module brew-bundle.sh
    run_module chezmoi.sh
    run_module zsh.sh
    run_module bubblewrap.sh
    run_module developer-tools.sh

    if [ "${INSTALL_TAILSCALE:-no}" = "yes" ]; then
        run_module tailscale.sh
    else
        skip_step "tailscale.sh"
    fi

    if [ "${INSTALL_PODMAN_QUADLET:-no}" = "yes" ]; then
        run_module podman-quadlet.sh
    else
        skip_step "podman-quadlet.sh"
    fi

    if [ "${APPLY_ROUTER_SYSCTL:-no}" = "yes" ]; then
        run_module router-sysctl.sh
    else
        skip_step "router-sysctl.sh"
    fi

    next_step "system update"
    system_upgrade

    next_step "verify"
    if [ "$DRY_RUN" = "yes" ]; then
        info "Dry-run: skipping verify.sh. After a real run: scripts/verify.sh $PROFILE"
    else
        "$SCRIPT_DIR/verify.sh" "$PROFILE" ||
            warn "verify.sh reported failures; review the summary above before relying on this host."
    fi

    if [ "$DRY_RUN" = "yes" ]; then
        success "Dry-run complete; reboot skipped."
    elif confirm "Reboot now?" "yes"; then
        run systemctl reboot
    else
        warn "Reboot skipped. Reboot manually when convenient: sudo systemctl reboot"
    fi
}

main "$@"
