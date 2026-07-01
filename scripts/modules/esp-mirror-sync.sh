#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=scripts/modules
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

DRY_RUN="no"
SYNC_NOW="yes"
ENABLE_PATH="yes"
ENABLE_SHUTDOWN_HOOK="no"

usage() {
    cat <<'USAGE'
Usage: esp-mirror-sync.sh [--dry-run] [--no-sync-now] [--no-enable] [--with-shutdown-hook]

Install an idempotent ESP mirror sync helper for this host. Host-specific and
Fedora-only; intentionally NOT profile-driven and NOT wired into bootstrap.sh —
this is the one module that keeps its own CLI and config/esp-mirror-sync.env.
Run it manually on the host that has a second ESP.

Options:
  --dry-run              Print actions without applying changes.
  --no-sync-now          Install units, but skip the initial sync.
  --no-enable            Install files without enabling esp-mirror-sync.path.
  --with-shutdown-hook   Also enable a best-effort pre-shutdown sync service.
  -h, --help             Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN="yes"
            ;;
        --no-sync-now)
            SYNC_NOW="no"
            ;;
        --no-enable)
            ENABLE_PATH="no"
            ;;
        --with-shutdown-hook)
            ENABLE_SHUTDOWN_HOOK="yes"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
    shift
done

install_file() {
    local mode="$1"
    local source="$2"
    local target="$3"

    if [ "$DRY_RUN" = "yes" ]; then
        show_command install -m "$mode" "$source" "$target"
    else
        install -m "$mode" "$source" "$target"
    fi
}

main() {
    if [ "$DRY_RUN" != "yes" ]; then
        require_root
    fi
    # Host-specific tool: dual-ESP mirroring on a Fedora box (uses dnf). This is
    # intentionally NOT part of the profile-driven bootstrap; run it manually on
    # the host that has the second ESP. See docs/esp-mirror-sync.md.
    is_fedora || die "esp-mirror-sync is host-specific and Fedora-only (uses dnf); OS is ${OS_ID:-unknown}"
    require_command install
    require_command systemctl
    require_command dnf

    local root module_dir
    root="$(repo_root)"
    module_dir="$root/scripts/modules/esp-mirror-sync"

    log "Installing runtime dependencies"
    run dnf install -y rsync util-linux coreutils

    log "Installing ESP mirror config and runtime helper"
    install_file 0644 "$root/config/esp-mirror-sync.env" /etc/esp-mirror-sync.conf
    install_file 0755 "$module_dir/esp-mirror-sync.runtime.sh" /usr/local/sbin/esp-mirror-sync

    log "Installing systemd units"
    install_file 0644 "$module_dir/esp-mirror-sync.service" /etc/systemd/system/esp-mirror-sync.service
    install_file 0644 "$module_dir/esp-mirror-sync.path" /etc/systemd/system/esp-mirror-sync.path
    install_file 0644 "$module_dir/esp-mirror-sync-before-shutdown.service" \
        /etc/systemd/system/esp-mirror-sync-before-shutdown.service

    run systemctl daemon-reload

    if [ "$ENABLE_PATH" = "yes" ]; then
        run systemctl enable --now esp-mirror-sync.path
    else
        warn "esp-mirror-sync.path installed but not enabled"
    fi

    if [ "$ENABLE_SHUTDOWN_HOOK" = "yes" ]; then
        run systemctl enable esp-mirror-sync-before-shutdown.service
    else
        warn "pre-shutdown sync service installed but not enabled"
    fi

    if [ "$SYNC_NOW" = "yes" ]; then
        run systemctl start esp-mirror-sync.service
    else
        warn "initial sync skipped; run: sudo systemctl start esp-mirror-sync.service"
    fi

    success "ESP mirror sync installed"
}

main "$@"
