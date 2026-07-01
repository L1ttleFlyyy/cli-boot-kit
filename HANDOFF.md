# HANDOFF — 剩余工作

> `cli-boot-kit` 已在 **arm-oci**（Ubuntu 24.04, arm64）与 **beelink**（Fedora 44,
> x86_64）双平台验证：`bootstrap` + `verify` 全绿（各 32/0）。背景、用法、部署 runbook
> 见 `README.md`。

## esp-mirror-sync — 已验证 ✅（beelink, 2026-07-01）

全仓唯一 host-specific（Fedora-only、不进 profile/bootstrap 流程、保留自有 CLI +
`config/esp-mirror-sync.env`）的双-ESP 镜像工具已在 beelink 实测通过：

- 已装文件（`/etc/esp-mirror-sync.conf`、`/usr/local/sbin/esp-mirror-sync`、3 个
  systemd unit）与 repo 版本**逐字节一致**；`config/esp-mirror-sync.env` 的 UUID 与
  硬件吻合（primary `A861-ECC8`=nvme0n1p1，mirror `A79D-4E05`=nvme1n1p1，各在独立
  NVMe 上，均 768M vfat）。
- `esp-mirror-sync status/check/sync/check` 全绿：设备映射正确；`sync` 走完
  mount(rw)→`rsync --delete`→umount 全链路（幂等，0 变更），结束后镜像**未残留挂载**
  （cleanup trap 生效）；`check` 报 `mirror matches primary ESP`（exit 0）。
- `esp-mirror-sync.path` enabled + active(waiting)，watch `/boot/efi/EFI{,/BOOT,/fedora}`；
  其 `.service` 的 `ExecStart` 即 `esp-mirror-sync sync`（已证可用），故触发链路成立。

细节见 `docs/esp-mirror-sync.md`。

> 尚未做的小项（非阻塞）：物理改动 `/boot/efi/EFI` 触发 `.path`→`.service` 的端到端
> 观测。等价的 `esp-mirror-sync sync` 已直接实证；如需完全闭环，可在 ESP 变更后
> `journalctl -u esp-mirror-sync.service -b` 看一次真实触发。

## 已落定的决策（原 Open Questions）

均已拍板并写入 `README.md` 的 Conventions：

- **Homebrew 恒装**，不设 `INSTALL_HOMEBREW` 开关——CLI 基线在每台机器上都装。
- **Ubuntu 假定 `systemd-networkd`** 为前置条件，内核不代管网络栈选择。

## 参考

- 部署 runbook / profile 说明 / 各模块行为：`README.md`
- ESP 镜像细节：`docs/esp-mirror-sync.md`
