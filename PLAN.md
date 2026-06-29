# cli-boot-kit Plan & Status

`cli-boot-kit` 把一台新的 Linux 服务器收敛到可重复、可审计的 CLI-first 工作环境。
来自早期一次性的 `setup_server.sh`，现已升级为以配置文件为入口、跨 Fedora 与
Debian/Ubuntu 的模块化部署。

参考主机（均非"应原样复制"的最终答案，仅作目标状态参考）：

- `beelink`: Fedora 44 Server, x86_64。Podman Quadlet 工具链参考态（容器 workload 本身在独立 repo）。
- `arm-oci`: Ubuntu 24.04 LTS, arm64。SSH/Tailscale/Homebrew/Codex/bubblewrap 的黄金参考态。

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
| `podman-quadlet.sh` | ✅ | 仅装 Podman + Quadlet 工具链；建 `/etc/containers/systemd` + `daemon-reload`。不部署任何具体 workload。 |

Brewfile 不纳管（由专用模块/官方 installer 负责）：`bubblewrap`、`codex`、
`claude-code`。Homebrew cask 仅 macOS，会让 Linux 上 `brew bundle` 报错。

## Implementation Phases

- [x] **Phase 1** — 配置层：`config/defaults.env` + `load_defaults`。
- [x] **Phase 2** — 平台抽象：`lib/os.sh`，全仓 `require_supported_os`，统一 pkg/firewall helpers。
- [x] **Phase 3** — 核心 bootstrap：identity(timezone)/ssh/base-packages/homebrew/chezmoi/shell 通用化；拆分 Fedora/Ubuntu 包列表；Brewfile 去除 bubblewrap/codex/claude。
- [x] **Phase 4** — Codex 运行时：`bubblewrap.sh`（含 Ubuntu 24.04 AppArmor）+ `developer-tools.sh`。
- [x] **Phase 5** — Tailscale 与 router profile：跨平台 `tailscale.sh`，默认开启 router/exit-node sysctl + ethtool。
- [x] **Phase 6** — Podman + Quadlet 工具链：`podman-quadlet.sh`（bootstrap 内可选步骤，默认 no）。

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

### 3. ~~Podman Quadlet 工具链~~（Phase 6，已完成）

`podman-quadlet.sh` 已实现并接入 bootstrap（可选步骤，默认 no）。范围严格限定为
**工具链**：

- 安装 Podman；校验 systemd Quadlet generator 可用（找不到则报错，提示 podman 版本过低）。
- 确保 `/etc/containers/systemd` 存在；`daemon-reload` 触发 generator。

明确**不**负责的事（边界）：

- 不部署任何具体 workload（AdGuard Home 等）。具体 `*.container` unit 由专用 repo /
  chezmoi 管理，落到 `/etc/containers/systemd` 后自行 `daemon-reload` + `start`。
- 不渲染服务配置、不建服务用户/持久目录、不开 service 专属防火墙端口、不碰宿主 resolver。

> AdGuard Home 容器（镜像、`AdGuardHome.yaml`、`adguardhome.container`、bind/信任模型、
> SELinux `:Z` 卷标等）在独立 repo 维护，不属于本模板范围。

待实测（随 TODO 1 在 beelink 上一并做）：Fedora 上 Quadlet generator 路径与 `podman` 版本。

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

通用验证见 `README.md` 的 Verify 段。`podman-quadlet` 专项：

- `podman --version` 可用；Quadlet generator 存在
  （`/usr/lib/systemd/system-generators/podman-system-generator` 或 `/usr/libexec/...`）。
- `/etc/containers/systemd` 存在；放入一个测试 `.container` 后 `daemon-reload`
  能生成对应 `.service`。
