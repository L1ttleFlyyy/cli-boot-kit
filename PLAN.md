# cli-boot-kit Plan & Status

`cli-boot-kit` 把一台新的 Linux 服务器收敛到可重复、可审计的 CLI-first 工作环境。
来自早期一次性的 `setup_server.sh`，现已升级为以配置文件为入口、跨 Fedora 与
Debian/Ubuntu 的模块化部署。

参考主机（均非"应原样复制"的最终答案，仅作目标状态参考）：

- `beelink`: Fedora 44 Server, x86_64。Podman Quadlet 工具链参考态（容器 workload 本身在独立 repo）。
- `arm-oci`: Ubuntu 24.04 LTS, arm64。SSH/Tailscale/Homebrew/Codex/bubblewrap 的黄金参考态。

## Principles

- **声明式：一台机器 = 一个 `profiles/<name>.env`。** profile 是该主机目标态的
  唯一入口；脚本负责收敛与验证，不在脚本里写死可配置值。
- **统一调用约定：所有脚本签名为 `<profile> [--dry-run]`，profile 为必需位置参数**，
  必须显式声明（不靠 env prefix 或交互猜测）。
- **可选模块由 profile 开关声明、不靠交互**（`INSTALL_TAILSCALE` /
  `INSTALL_PODMAN_QUADLET` / `APPLY_ROUTER_SYSCTL`）。
- `config/defaults.env` + `config/ssh.env` 仅作 profile 之下的 fallback 基线。
- **部署前/后用 `verify.sh <profile>` 按 profile 核对**；bootstrap 末尾自动跑一次。
- 模块必须可重复运行；重复 apply 收敛到 profile 目标态，不产生重复配置或破坏现有 state
  （如 `authorized_keys` 已存在则不覆盖）。
- Fedora 与 Ubuntu 共用同一高层模型，平台差异收敛到 `lib/os.sh`。
- 默认保守，host-specific 细节必须显式声明；不把当前机器的偶然状态写成通用规则。
- LAN/tailnet 之外的公网一律不可信。
- dry-run 必须与 apply 一致：所有动作经 `run` / `run_eval` / `write_file`，
  打印的命令/文件内容即真实执行的命令/内容。

## Configuration

shell-safe `.env`，避免引入额外 parser。分层加载：`config/defaults.env` →
`config/ssh.env` →（覆盖层）`profiles/<name>.env`，由 `lib/common.sh` 的
`load_profile` 统一收敛。

- `profiles/<name>.env`：**每台主机的目标态**（timezone、`SSH_PORT`、shell、
  chezmoi repo、trusted tailnet CIDR、dev-tool 与可选模块开关）。所有脚本必需参数。
  参考：`ubuntu-gen`（arm-oci）、`fedora-gen`（beelink）。
- `config/defaults.env` / `config/ssh.env`：fallback 基线。
- `config/authorized_keys`：SSH 公钥 allowlist，随 private repo 版本管理；主机已存在则不覆盖。
- `Brewfile`：跨平台 CLI 工具。

## Module Status

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| `profiles/*.env` | ✅ | 每主机目标态；`ubuntu-gen` / `fedora-gen` 两个参考 profile。 |
| `lib/os.sh` | ✅ | OS 探测 + pkg/firewall/ssh-socket/selinux helpers。 |
| `lib/common.sh` | ✅ | 日志、`run`/`run_eval`/`write_file`、`load_profile`/`parse_runtime_args`、`require_supported_os`。 |
| `verify.sh` | ✅ | 按 profile 只读核对，分组 PASS/FAIL/SKIP + 汇总；bootstrap 末尾自动跑。 |
| identity（timezone） | ✅ | `bootstrap.sh` 内联 `timedatectl set-timezone`，profile 驱动。 |
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
| `esp-mirror-sync.sh` | ✅ host-specific（例外） | 双 ESP 镜像，Fedora-only；**刻意不进 profile/bootstrap 流程**，保留自有 CLI + `config/esp-mirror-sync.env`，手动在有第二 ESP 的主机上跑。非 Fedora 优雅 `die`。 |
| `podman-quadlet.sh` | ✅ | 仅装 Podman + Quadlet 工具链；建 `/etc/containers/systemd` + `daemon-reload`。不部署任何具体 workload。 |

Brewfile 不纳管（由专用模块/官方 installer 负责）：`bubblewrap`、`codex`、
`claude-code`。Homebrew cask 仅 macOS，会让 Linux 上 `brew bundle` 报错。

## Implementation Phases

- [x] **Phase 1** — 配置层：`config/defaults.env` + `load_defaults`。
- [x] **Phase 2** — 平台抽象：`lib/os.sh`，全仓 `require_supported_os`，统一 pkg/firewall helpers。
- [x] **Phase 3** — 核心 bootstrap：identity(timezone)/ssh/base-packages/homebrew/chezmoi/shell 通用化；拆分 Fedora/Ubuntu 包列表；Brewfile 去除 bubblewrap/codex/claude。
- [x] **Phase 4** — Codex 运行时：`bubblewrap.sh`（含 Ubuntu 24.04 AppArmor）+ `developer-tools.sh`。
- [x] **Phase 5** — Tailscale 与 router profile：跨平台 `tailscale.sh`，默认开启 router/exit-node sysctl + ethtool。
- [x] **Phase 6** — Podman + Quadlet 工具链：`podman-quadlet.sh`（bootstrap 可选步骤，profile 开关默认 yes）。
- [x] **Phase 7** — Profile 化与规范：`profiles/<name>.env` 目标态、统一调用约定
  `<profile> [--dry-run]`、可选模块改 profile 声明开关、新增 `verify.sh`、声明式原则写入规范。

## TODO / Remaining Work

### 1. ~~Fedora 路径实测~~（已完成，见 `FEEDBACK.md`）

在 beelink（Fedora 44, Podman 5.8.3）上实跑 apply，验收 `verify.sh beelink`
`32 passed, 0 failed`。Quadlet generator 实际路径
`/usr/lib/systemd/system-generators/podman-system-generator`（脚本已覆盖）。
SELinux/firewalld/fail2ban-firewalld/chezmoi-dnf 分支均符合预期。

实测暴露并已修复的问题：

- **P1** `chezmoi init --apply` 遇本机 diff 会交互阻塞 → 加 `--force`（声明态为准）。
- **P2** kit 不再管理 Tailscale 账号态：移除 `tailscale set --advertise-exit-node`
  与 `ADVERTISE_EXIT_NODE` 开关；`INSTALL_TAILSCALE` 统管装服务 + forwarding sysctl +
  UDP GRO service，注册/advertise 手动 `tailscale up`。
- **P3** `zsh.sh` 优先 canonical shell 路径（避免切到 `/usr/sbin/zsh`）。
- **P3** `configure_selinux_port` 的 `semanage port -l` 解析 off-by-one（proto 在 `$2`、
  端口在 `$3..NF`）导致检测失效、误报 "Added" → 已修正并区分 already/added/modified。

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

### 4. ~~`esp-mirror-sync` 归属决策~~（已决定）

决策：**保持纯 host-specific 独立工具，不进 profile/bootstrap 通用流程**。它保留自有
CLI（`[--dry-run] [--no-sync-now] [--no-enable] [--with-shutdown-hook]`）与
`config/esp-mirror-sync.env`（存 ESP 设备 UUID），手动在有第二 ESP 的 Fedora 主机
（beelink）上运行。顺带修掉重构遗留的崩溃：`require_fedora`（已删）→ `is_fedora` 守卫。

> 全仓唯一不遵循 `<profile> [--dry-run]` 约定的脚本，作为明确标注的例外。dry-run 实测
> 需在 beelink 上做（arm-oci 无双 ESP 硬件；非 Fedora 会优雅 `die`）。

## Resolved Decisions

- 用户创建：复用现有登录用户，不建用户。
- CN 网络镜像加速（GitHub hosts + homebrew 清华镜像）：丢弃。
- 防火墙 + fail2ban：本轮已迁移（不再 deferred）。
- Codex/Claude 安装路径：官方 installer，非 Homebrew。
- sysctl bbr/fq：补回 `router-sysctl.sh`。
- Tailscale 边界：kit 只装服务（tailscale/ethtool/forwarding sysctl/UDP GRO），
  **不碰账号态**；`tailscale up` 与 advertise 手动。几乎所有 host 都是 exit node，
  故 forwarding + optimize 随 `INSTALL_TAILSCALE` 默认开启。
- chezmoi：bootstrap 用 `--apply --force`，声明态覆盖本机改动。
- Profile 分层：`fedora-gen`/`ubuntu-gen` 是通用基线（新机器从此复制）；`beelink`、
  `arm-oci` 是 host-specific 示例（WARP policy routing 强制 `TAILSCALE_NETDEV`），不被继承。
- `esp-mirror-sync`：保持 host-specific 独立工具，不进通用流程（TODO4 已决）。

## Open Questions

- Homebrew 是否在最小化服务器上为可选（按 host 开关）。
- Ubuntu 是否统一假设 `systemd-networkd`，还是把网络栈选择视为 host-specific。

## Verification Checklist

通用验证见 `README.md` 的 Verify 段。`podman-quadlet` 专项：

- `podman --version` 可用；Quadlet generator 存在
  （`/usr/lib/systemd/system-generators/podman-system-generator` 或 `/usr/libexec/...`）。
- `/etc/containers/systemd` 存在；放入一个测试 `.container` 后 `daemon-reload`
  能生成对应 `.service`。
