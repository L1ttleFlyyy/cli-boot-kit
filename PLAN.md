# cli-boot-kit Plan & Status

`cli-boot-kit` 把一台新的 Linux 服务器收敛到可重复、可审计的 CLI-first 工作环境。
来自早期一次性的 `setup_server.sh`，现已升级为以配置文件为入口、跨 Fedora 与
Debian/Ubuntu 的模块化部署。

参考主机（均非"应原样复制"的最终答案，仅作目标状态参考）：

- `beelink`: Fedora 44 Server, x86_64。Podman Quadlet 版 AdGuard Home 在此。
- `arm-oci`: Ubuntu 24.04 LTS, arm64。SSH/Tailscale/Homebrew/Codex/bubblewrap
  的黄金参考态；其 root 直装 `/opt/AdGuardHome` 监听 `*:53` 的做法**不**符合本模板目标。

## Principles

- 声明式：配置声明目标状态，脚本负责收敛与验证。
- 模块必须可重复运行；重复 apply 不产生重复配置或破坏现有 state。
- Fedora 与 Ubuntu 共用同一高层模型，平台差异收敛到 `lib/os.sh`。
- 默认保守，host-specific 细节必须显式声明。
- 不把当前机器的偶然状态写成通用规则。
- LAN/tailnet 之外的公网一律不可信。
- dry-run 必须与 apply 一致：所有动作经 `run` / `run_eval` / `write_file`，
  打印的命令/文件内容即真实执行的命令/内容。

## Configuration

第一阶段使用 shell-safe `.env`，避免引入额外 parser。复杂文件独立管理。

- `config/defaults.env`：timezone、chezmoi repo、trusted tailnet CIDR、dev-tool 开关。
- `config/ssh.env`：`SSH_PORT`。
- `config/authorized_keys`：SSH 公钥（gitignored）。
- `Brewfile`：跨平台 CLI 工具。

> 注：原计划的 `lib/config.sh` 收敛为 `lib/common.sh` 的 `load_defaults` +
> 模块按需直接 source，未单独成文件。

## Module Status

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| `lib/os.sh` | ✅ | OS 探测 + pkg/firewall/ssh-socket/selinux helpers。 |
| `lib/common.sh` | ✅ | 日志、`run`/`run_eval`/`write_file`、`load_defaults`、`require_supported_os`。 |
| identity（timezone） | ✅ | `bootstrap.sh` 内联 `timedatectl set-timezone`，config 驱动。 |
| identity（建用户） | ⛔ 不做 | 决策：复用云镜像现有登录用户（如 `ubuntu`），不创建用户。 |
| `ssh-hardening.sh` | ✅ | 端口 60022 + 加固；Fedora 走 SELinux/firewalld，Ubuntu 跳过 SELinux、用 ufw、重启 `ssh.socket`。 |
| `base-packages.sh` | ✅ | Fedora `procps-ng gcc gcc-c++ make`，Ubuntu `procps build-essential`。 |
| `firewall.sh` | ✅ | ufw / firewalld；先放行 `SSH_PORT` 再 enable，防锁死。 |
| `fail2ban.sh` | ✅ | sshd jail；Ubuntu `banaction=ufw`，Fedora `fail2ban-firewalld`；ignore tailnet。 |
| `homebrew.sh` / `brew-bundle.sh` | ✅ | Linuxbrew as 目标用户；`Brewfile` 不含 bubblewrap/codex/claude（见下）。 |
| `chezmoi.sh` | ✅ | config 驱动 `CHEZMOI_REPO`；brew-aware；缺失时官方 installer。 |
| `zsh.sh`（shell） | ✅ | 设登录 shell。 |
| `bubblewrap.sh` | ✅ | apt bubblewrap + Ubuntu 24.04 AppArmor `bwrap-userns-restrict` + `bwrap` 自检。 |
| `developer-tools.sh` | ✅ | Claude Code + Codex 官方 installer，装入 `~/.local`（非 brew/npm）。 |
| `tailscale.sh` | ✅ | 官方 installer + ethtool；装好但不 `tailscale up`（注册手动）。 |
| `router-sysctl.sh` / `setup-tailscale-exit-node.sh` | ✅ | router/exit-node sysctl（含 bbr/fq）+ UDP GRO 优化。 |
| `esp-mirror-sync.sh` | ⚠️ host-specific | 双 ESP 镜像，beelink 专用；尚未纳入跨平台体系（见 TODO 4）。 |
| `podman-quadlet` | ⬜ TODO | 通用容器运行时底座，见下。 |
| `adguardhome` | ⬜ TODO | 基于 Quadlet 部署，见下。 |

Brewfile 不纳管（由专用模块/官方 installer 负责）：`bubblewrap`、`codex`、
`claude-code`。Homebrew cask 仅 macOS，会让 Linux 上 `brew bundle` 报错。

## Implementation Phases

- [x] **Phase 1** — 配置层：`config/defaults.env` + `load_defaults`。
- [x] **Phase 2** — 平台抽象：`lib/os.sh`，全仓 `require_supported_os`，统一 pkg/firewall helpers。
- [x] **Phase 3** — 核心 bootstrap：identity(timezone)/ssh/base-packages/homebrew/chezmoi/shell 通用化；拆分 Fedora/Ubuntu 包列表；Brewfile 去除 bubblewrap/codex/claude。
- [x] **Phase 4** — Codex 运行时：`bubblewrap.sh`（含 Ubuntu 24.04 AppArmor）+ `developer-tools.sh`。
- [x] **Phase 5** — Tailscale 与 router profile：跨平台 `tailscale.sh`，默认开启 router/exit-node sysctl + ethtool。
- [ ] **Phase 6** — Podman Quadlet（见下）。
- [ ] **Phase 7** — AdGuard Home（见下）。

## TODO / Remaining Work

### 1. Fedora 路径实测

跨平台改造在 Ubuntu（arm-oci）上已 dry-run + shellcheck 验证。Fedora 分支尚未实跑，
需在 beelink 上 `--dry-run` 复核：

- `base-packages` Fedora 包名（`procps-ng`/`gcc-c++`）。
- `ssh-hardening` 的 SELinux `semanage ssh_port_t` 幂等块与 firewalld 放行。
- `firewall.sh` firewalld baseline。
- `fail2ban.sh` 的 `fail2ban-firewalld` + `firewallcmd-rich-rules` 动作是否产生有效 firewall 规则。
- `chezmoi` 走 dnf 分支。

验证后再决定能否放心用于新 Fedora 主机。

### 3. Podman Quadlet + AdGuard Home（Phase 6/7）

#### `podman-quadlet`

- 安装 Podman；校验 systemd Quadlet generator 可用。
- 确保 `/etc/containers/systemd` 存在；安装 `.container`；`daemon-reload`；enable/restart 生成的服务。
- 作为 AdGuard Home 等服务的通用底座。

#### `adguardhome`

- 依赖 `podman-quadlet`；用 system-level Quadlet，**不**直装 `/opt/AdGuardHome`。
- `systemd-sysusers` 建服务用户；`systemd-tmpfiles` 建持久目录。
- 渲染 `AdGuardHome.yaml` 与 `/etc/containers/systemd/adguardhome.container`；enable/restart。
- 默认把宿主 DNS 路由经 AdGuard Home；LAN/tailnet DNS 经 iptables 兼容的 forwarding/allow，
  而非 interface 专属 bind。
- 提供 verify 与 rollback。

容器目标：

```text
Image=docker.io/adguard/adguardhome:latest
Network=host
User=<adguardhome uid>:<adguardhome gid>
Volume=/var/lib/adguardhome/work:/opt/adguardhome/work
Volume=/var/lib/adguardhome/conf:/opt/adguardhome/conf
DropCapability=all
AddCapability=NET_BIND_SERVICE
NoNewPrivileges=true
```

绑定与信任模型：

- Web UI bind `0.0.0.0:3000`，DNS bind `0.0.0.0:53`；不写 LAN/tailnet/loopback 专属地址。
- 依赖全局防火墙模型决定可达性（公网仅 SSH；LAN/tailnet 可达本地服务端口），
  不为 AdGuard 单开 `3000/tcp` 规则。
- 不用 `ip_nonlocal_bind`。
- 不把 host-specific 值（`192.168.8.x`、`100.123.123.4`、`luuumi.vpn` 等）写进通用默认。
- SELinux enforcing 时用 `:Z` 卷标；非 enforcing 不强制依赖 SELinux 状态。

### 4. `esp-mirror-sync` 归属决策

当前是 beelink 双 ESP 专用、host-specific。需决定：纳入跨平台体系（抽象成可配置的
"mirror 第二 ESP"特性），还是保持纯 host-specific、明确标注不进通用流程。

## Resolved Decisions

- 用户创建：复用现有登录用户，不建用户。
- CN 网络镜像加速（GitHub hosts + homebrew 清华镜像）：丢弃。
- 防火墙 + fail2ban：本轮已迁移（不再 deferred）。
- Codex/Claude 安装路径：官方 installer，非 Homebrew。
- sysctl bbr/fq：补回 `router-sysctl.sh`。

## Open Questions

- Homebrew 是否在最小化服务器上为可选（按 host 开关）。
- Ubuntu 是否统一假设 `systemd-networkd`，还是把网络栈选择视为 host-specific。

## Verification Checklist

通用验证见 `README.md` 的 Verify 段。AdGuard Home 专项（待实现后启用）：

- `adguardhome.service` active，来源为 `/etc/containers/systemd/adguardhome.container`。
- Web UI 监听 `0.0.0.0:3000`，公网 `3000/tcp` 被防火墙挡住。
- DNS 监听 `0.0.0.0:53`，trusted LAN/tailnet 查询被放行/转发。
- 宿主 resolver 默认走 AdGuard Home；rollback 可恢复。
