#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

STEP_CURRENT=0
STEP_TOTAL=0 # derived from STEPS in main()

# Ordered bootstrap steps; STEP_TOTAL is derived from this array, so adding a
# step here is the only change needed. Module entries are "name.sh" (always
# runs) or "name.sh:TOGGLE_VAR:default" (runs when the profile resolves the
# toggle to yes, otherwise shown as a skipped step). "timezone",
# "system-update" and "verify" dispatch to local functions.
STEPS=(
    timezone
    base-packages.sh
    ssh-hardening.sh
    firewall.sh
    "fail2ban.sh:INSTALL_FAIL2BAN:yes"
    homebrew.sh
    brew-bundle.sh
    chezmoi.sh
    zsh.sh
    bubblewrap.sh
    developer-tools.sh
    "sudo-nopasswd.sh:SUDO_NOPASSWD:no"
    "tailscale.sh:INSTALL_TAILSCALE:no"
    "podman-quadlet.sh:INSTALL_PODMAN_QUADLET:no"
    "router-sysctl.sh:APPLY_ROUTER_SYSCTL:no"
    "cockpit.sh:INSTALL_COCKPIT:no"
    system-update
    verify
)

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

run_step() {
    local spec="$1"

    case "$spec" in
        timezone)
            apply_timezone
            ;;
        system-update)
            next_step "system update"
            system_upgrade
            ;;
        verify)
            next_step "verify"
            run_verify
            ;;
        *:*)
            local module="${spec%%:*}" rest="${spec#*:}"
            local toggle_var="${rest%%:*}" default="${rest##*:}"
            if [ "${!toggle_var:-$default}" = "yes" ]; then
                run_module "$module"
            else
                skip_step "$module"
            fi
            ;;
        *)
            run_module "$spec"
            ;;
    esac
}

run_verify() {
    if [ "$DRY_RUN" = "yes" ]; then
        info "Dry-run: skipping verify.sh. After a real run: scripts/verify.sh $PROFILE"
    else
        "$SCRIPT_DIR/verify.sh" "$PROFILE" ||
            warn "verify.sh reported failures; review the summary above before relying on this host."
    fi
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

    # Refresh the apt index once and let the module child processes inherit the
    # done-marker, instead of every module refreshing again in its own process.
    # The whole bootstrap installs from this one index snapshot. No-op on dnf.
    pkg_refresh
    export APT_INDEX_UPDATED

    STEP_TOTAL="${#STEPS[@]}"
    local step
    for step in "${STEPS[@]}"; do
        run_step "$step"
    done

    if [ "$DRY_RUN" = "yes" ]; then
        success "Dry-run complete; reboot skipped."
    elif confirm "Reboot now?" "yes"; then
        run systemctl reboot
    else
        warn "Reboot skipped. Reboot manually when convenient: sudo systemctl reboot"
    fi
}

main "$@"
