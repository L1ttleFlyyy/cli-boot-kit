# ESP Mirror Sync

This host has two independent EFI System Partitions:

- Primary ESP: `/boot/efi`, UUID `A861-ECC8`
- Mirror ESP: UUID `A79D-4E05`

Only the primary ESP is registered in UEFI NVRAM. The mirror ESP is kept as a
cold recovery copy, not as an automatic fallback boot path. This preserves the
failure signal if the primary disk or primary ESP stops booting.

## Install

Review the changes:

```bash
sudo ./scripts/modules/esp-mirror-sync.sh --dry-run
```

Install the runtime helper, systemd units, enable the path watcher, and run one
initial sync:

```bash
sudo ./scripts/modules/esp-mirror-sync.sh
```

Optionally also enable a best-effort pre-shutdown sync:

```bash
sudo ./scripts/modules/esp-mirror-sync.sh --with-shutdown-hook
```

## Runtime Commands

```bash
sudo esp-mirror-sync status
sudo esp-mirror-sync check
sudo esp-mirror-sync sync
```

The sync is idempotent. It validates that `/boot/efi` is mounted from the
expected primary ESP UUID, validates that the mirror UUID is a distinct `vfat`
partition, mounts the mirror under `/run/esp-mirror-sync/esp2` only for the
duration of the operation, then mirrors the full ESP with `rsync --delete`.

## systemd Units

- `esp-mirror-sync.path` watches `/boot/efi/EFI`, `/boot/efi/EFI/fedora`, and
  `/boot/efi/EFI/BOOT`.
- `esp-mirror-sync.service` performs the sync.
- `esp-mirror-sync-before-shutdown.service` is installed but only enabled when
  the module is run with `--with-shutdown-hook`.

Useful checks:

```bash
systemctl status esp-mirror-sync.path
journalctl -u esp-mirror-sync.service -b
```
