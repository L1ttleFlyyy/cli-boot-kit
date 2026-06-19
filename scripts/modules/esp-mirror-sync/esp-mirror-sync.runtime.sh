#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${ESP_MIRROR_CONFIG:-/etc/esp-mirror-sync.conf}"
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

PRIMARY_ESP="${PRIMARY_ESP:-/boot/efi}"
PRIMARY_ESP_UUID="${PRIMARY_ESP_UUID:-}"
MIRROR_ESP_UUID="${MIRROR_ESP_UUID:-}"
MIRROR_MOUNT="${MIRROR_MOUNT:-/run/esp-mirror-sync/esp2}"
MOUNT_OPTIONS="${MOUNT_OPTIONS:-umask=0077,shortname=winnt}"
LOCK_FILE="${LOCK_FILE:-/run/lock/esp-mirror-sync.lock}"
RSYNC_BIN="${RSYNC_BIN:-/usr/bin/rsync}"

usage() {
    cat <<'USAGE'
Usage: esp-mirror-sync [sync|check|status]

Commands:
  sync    Mirror the mounted primary ESP to the backup ESP. This is the default.
  check   Exit 0 if the mirror matches, 1 if it would change.
  status  Validate configuration and print the current device mapping.
USAGE
}

log() {
    printf 'esp-mirror-sync: %s\n' "$*"
}

die() {
    printf 'esp-mirror-sync: error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

first_line() {
    sed -n '1p'
}

uuid_for_device() {
    blkid -s UUID -o value "$1" 2>/dev/null || true
}

type_for_device() {
    blkid -s TYPE -o value "$1" 2>/dev/null || true
}

source_for_mount() {
    findmnt -rn -T "$PRIMARY_ESP" -o SOURCE 2>/dev/null | first_line || true
}

target_mount_for_uuid() {
    findmnt -rn -S "UUID=$MIRROR_ESP_UUID" -o TARGET 2>/dev/null | first_line || true
}

resolve_uuid_device() {
    local uuid="$1"
    local path="/dev/disk/by-uuid/$uuid"

    [ -e "$path" ] || return 1
    readlink -f "$path"
}

validate_config() {
    [ -n "$PRIMARY_ESP_UUID" ] || die "PRIMARY_ESP_UUID is not set"
    [ -n "$MIRROR_ESP_UUID" ] || die "MIRROR_ESP_UUID is not set"
    [ "$PRIMARY_ESP_UUID" != "$MIRROR_ESP_UUID" ] ||
        die "primary and mirror ESP UUIDs must differ"
}

validate_devices() {
    validate_config
    mountpoint -q "$PRIMARY_ESP" || die "$PRIMARY_ESP is not a mount point"

    PRIMARY_SOURCE="$(source_for_mount)"
    [ -n "$PRIMARY_SOURCE" ] || die "cannot determine source device for $PRIMARY_ESP"
    PRIMARY_DEVICE="$(readlink -f "$PRIMARY_SOURCE")"
    [ -b "$PRIMARY_DEVICE" ] || die "primary ESP source is not a block device: $PRIMARY_SOURCE"

    local primary_uuid
    primary_uuid="$(uuid_for_device "$PRIMARY_DEVICE")"
    [ "$primary_uuid" = "$PRIMARY_ESP_UUID" ] ||
        die "$PRIMARY_ESP is mounted from UUID=$primary_uuid, expected UUID=$PRIMARY_ESP_UUID"

    MIRROR_DEVICE="$(resolve_uuid_device "$MIRROR_ESP_UUID")" ||
        die "cannot find mirror ESP UUID=$MIRROR_ESP_UUID"
    [ -b "$MIRROR_DEVICE" ] || die "mirror ESP is not a block device: $MIRROR_DEVICE"
    [ "$MIRROR_DEVICE" != "$PRIMARY_DEVICE" ] ||
        die "mirror ESP resolves to the same device as the primary ESP"

    local mirror_type
    mirror_type="$(type_for_device "$MIRROR_DEVICE")"
    [ "$mirror_type" = "vfat" ] ||
        die "mirror ESP must be vfat; got TYPE=${mirror_type:-unknown} on $MIRROR_DEVICE"
}

with_lock() {
    require_command flock
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "another sync is already running; skipping"
        exit 0
    fi
}

mount_mirror() {
    local mode="$1"
    local existing_mount
    existing_mount="$(target_mount_for_uuid)"

    MOUNTED_BY_US="no"
    if [ -n "$existing_mount" ]; then
        MIRROR_TARGET="$existing_mount"
        return 0
    fi

    MIRROR_TARGET="$MIRROR_MOUNT"
    mkdir -p "$MIRROR_TARGET"

    local options="$MOUNT_OPTIONS"
    if [ "$mode" = "check" ]; then
        options="ro,$options"
    fi

    mount -t vfat -o "$options" "UUID=$MIRROR_ESP_UUID" "$MIRROR_TARGET"
    MOUNTED_BY_US="yes"
}

cleanup() {
    if [ "${MOUNTED_BY_US:-no}" = "yes" ] && mountpoint -q "${MIRROR_TARGET:-/nonexistent}"; then
        umount "$MIRROR_TARGET"
    fi
}

sync_mirror() {
    validate_devices
    with_lock
    mount_mirror sync
    trap cleanup EXIT

    log "syncing $PRIMARY_ESP/ to UUID=$MIRROR_ESP_UUID at $MIRROR_TARGET"
    "$RSYNC_BIN" \
        -rt \
        --delete \
        --delete-delay \
        --modify-window=1 \
        --human-readable \
        --info=stats2,name1 \
        "$PRIMARY_ESP"/ "$MIRROR_TARGET"/
    sync -f "$MIRROR_TARGET" 2>/dev/null || sync
    log "mirror sync complete"
}

check_mirror() {
    validate_devices
    with_lock
    mount_mirror check
    trap cleanup EXIT

    local changes
    changes="$("$RSYNC_BIN" \
        -rtn \
        --delete \
        --modify-window=1 \
        --out-format='%i %n%L' \
        "$PRIMARY_ESP"/ "$MIRROR_TARGET"/)"

    if [ -n "$changes" ]; then
        printf '%s\n' "$changes"
        die "mirror differs from primary ESP"
    fi

    log "mirror matches primary ESP"
}

status() {
    validate_devices
    local mirror_mount
    mirror_mount="$(target_mount_for_uuid)"

    printf 'primary_mount=%s\n' "$PRIMARY_ESP"
    printf 'primary_uuid=%s\n' "$PRIMARY_ESP_UUID"
    printf 'primary_device=%s\n' "$PRIMARY_DEVICE"
    printf 'mirror_uuid=%s\n' "$MIRROR_ESP_UUID"
    printf 'mirror_device=%s\n' "$MIRROR_DEVICE"
    printf 'mirror_mount=%s\n' "${mirror_mount:-unmounted}"
}

main() {
    require_command blkid
    require_command findmnt
    require_command mount
    require_command mountpoint
    require_command readlink
    require_command "$RSYNC_BIN"
    require_command sed
    require_command sync
    require_command umount

    case "${1:-sync}" in
        sync)
            sync_mirror
            ;;
        check)
            check_mirror
            ;;
        status)
            status
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
