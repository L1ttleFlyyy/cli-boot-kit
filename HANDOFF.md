# HANDOFF — 剩余工作（在 beelink 上继续）

> `cli-boot-kit` 已在 **arm-oci**（Ubuntu 24.04, arm64）与 **beelink**（Fedora 44,
> x86_64）双平台验证：`bootstrap` + `verify` 全绿（各 32/0）。背景、用法、部署 runbook
> 见 `README.md`。本文件只记录还需在 **beelink** 上收尾的项。

## 1. 验证 `esp-mirror-sync`（host-specific，仅 beelink 有双 ESP）

`esp-mirror-sync` 是全仓唯一不进 profile/bootstrap 流程的 host-specific 工具（Fedora-only，
保留自有 CLI + `config/esp-mirror-sync.env`）。profile 重构曾漏改它、调用了已删除的
`require_fedora` 而崩溃，现已换成 `is_fedora` 守卫。arm-oci 上碰不到双 ESP 硬件，需在
beelink 实测：

```bash
git pull
sudo ./scripts/modules/esp-mirror-sync.sh --dry-run
```

dry-run 预期打印：装 `rsync util-linux coreutils` → 写 `/etc/esp-mirror-sync.conf` →
装 4 个文件（`esp-mirror-sync.{service,path}`、`-before-shutdown.service`、
`runtime.sh`→`/usr/local/sbin/esp-mirror-sync`）→ `daemon-reload` → enable
`esp-mirror-sync.path` → start `esp-mirror-sync.service`。

核对 `config/esp-mirror-sync.env` 的 `PRIMARY_ESP_UUID` / `MIRROR_ESP_UUID` 与 beelink
现状一致后，再决定是否实跑 apply。实跑后确认：

- `systemctl status esp-mirror-sync.path` 为 active；
- 改动 primary ESP 后 `.path` 触发 sync（或手动 `systemctl start esp-mirror-sync.service`）；
- 镜像 ESP 内容与 primary 一致。

有问题把 dry-run/apply 输出贴回来。

## 2. Open Questions（待议，非阻塞）

- Homebrew 在最小化服务器上是否应设为按-host 可选开关（如 `INSTALL_HOMEBREW`）？目前恒装。
- Ubuntu 是否统一假设 `systemd-networkd`，还是把网络栈选择视为 host-specific？

## 参考

- 部署 runbook / profile 说明 / 各模块行为：`README.md`
- ESP 镜像细节：`docs/esp-mirror-sync.md`
