# HANDOFF — Fedora 路径实测（TODO1）

> 给在 **Fedora 主机（beelink）** 上接手的全新 agent。你没有之前 session 的上下文，
> 本文件自包含。你的任务：**指导用户在 Fedora 上验证 `cli-boot-kit`**，并在结束时
> 产出 `FEEDBACK.md`（格式见末尾）。该 FEEDBACK 会回传给原 Ubuntu session 的 agent。

## 0. 背景

`cli-boot-kit` 是跨平台（Fedora / Debian-Ubuntu）的服务器 bootstrap 工具。整套已在
Ubuntu 24.04 arm64（arm-oci）上 dry-run + shellcheck 全绿，但 **Fedora 分支从未实跑过**。
beelink（Fedora 44 Server, x86_64）是 Fedora 参考主机。本轮目标就是把 Fedora 路径跑通、
校准 profile，并把结果反馈回来。

设计要点（你需要理解，才能判断对错）：

- **声明式**：每台机器 = 一个 `profiles/<name>.env`，是该主机目标态的唯一入口。
- **统一调用约定**：所有脚本签名 `./scripts/xxx.sh <profile> [--dry-run]`，
  profile 是**必需位置参数**。Fedora 用 `fedora-gen`。
- **平台差异**收敛在 `scripts/lib/os.sh`（`is_fedora`/`pkg_install`/`firewall_kind`/
  `ssh_socket_activated`/`has_semanage` 等）。模块按 OS **探测**走分支，不靠 profile。
- **dry-run 无漂移**：所有动作经 `run`/`run_eval`/`write_file`，打印的即真实执行的。
- 配置分层：`config/defaults.env` → `config/ssh.env` →（覆盖）`profiles/<name>.env`。

仓库关键结构：

```
profiles/fedora-gen.env        # 本次要校准的目标态
scripts/bootstrap.sh           # 编排：<profile> [--dry-run]
scripts/verify.sh              # 只读核对：<profile>，分组 PASS/FAIL/SKIP
scripts/lib/{common.sh,os.sh}  # primitives + OS 抽象
scripts/modules/*.sh           # 各模块，统一签名
config/authorized_keys         # tracked SSH public-key allowlist
```

## 1. 前置条件（务必先做，否则会把自己锁在门外）

1. `git pull` 拿到最新 `main`（应包含本 HANDOFF.md）。
2. **SSH 端口会从 22 改到 60022。** 在动手前确认 60022 可达：
   - 若 beelink 在 NAT/防火墙后或有云安全组，先放行 `60022/tcp`，**保留 22 直到确认 60022 能登录**。
   - 当前用的是哪个端口、从哪登录，先记下来。
3. 复核 SSH 公钥列表：
   ```bash
   $EDITOR config/authorized_keys
   # 每行一个公钥，确保包含你当前登录用的 key
   ```
   注意：`config/authorized_keys` 是 private repo 中受版本管理的 public-key allowlist。
   本 kit 已改为 **目标主机的 `~/.ssh/authorized_keys` 已存在则不覆盖**，但主机若还
   没有该文件，实跑会用本 allowlist 初始化；务必确认包含你正在用的 key。源文件
   不必是 `600`，脚本安装到目标主机时会写成 `600`。
4. 通过 `sudo` 从**目标登录用户**运行（不是 root；bootstrap 不建用户，配置的是调用 sudo 的那个用户）。
5. 确认 `shellcheck` 已装（`sudo dnf install -y ShellCheck`），用于静态检查。

## 2. 测试流程（先 dry-run 核对，再决定是否 apply）

### 阶段 A — 静态检查
```bash
shellcheck -x scripts/bootstrap.sh scripts/verify.sh \
  scripts/setup-tailscale-exit-node.sh scripts/lib/*.sh scripts/modules/*.sh
```
期望：CLEAN。有告警就记进 FEEDBACK。

### 阶段 B — 部署前 env-check
```bash
sudo ./scripts/verify.sh fedora-gen
```
期望：能跑、输出分组报告。部署前大量 `[FAIL]` 是正常的（尚未部署）。重点看：
- profile 是否正确加载、`firewall_kind` 是否判定为 **firewalld**、有没有脚本级报错。

### 阶段 C — 全量 dry-run（**核心**，不改系统）
```bash
sudo ./scripts/bootstrap.sh fedora-gen --dry-run 2>&1 | tee /tmp/fedora-dryrun.log
```
逐项核对下面【第 3 节 Fedora 核对清单】。把每条的实际打印片段贴进 FEEDBACK。

也可单独 dry-run 个别模块缩小排查，例如：
```bash
sudo ./scripts/modules/ssh-hardening.sh fedora-gen --dry-run
sudo ./scripts/modules/fail2ban.sh    fedora-gen --dry-run
sudo ./scripts/modules/podman-quadlet.sh fedora-gen --dry-run
```

### 阶段 D — 决定是否实跑 apply
dry-run 全部合理后，**与用户确认**再实跑。beelink 是有用途的主机（跑着 Quadlet 容器等），
apply 会改 SSH 端口、装包、起防火墙/fail2ban、`dnf upgrade`、可能要求 reboot。
- 若用户同意：`sudo ./scripts/bootstrap.sh fedora-gen`（reboot 提示选 No，先验证）。
- 若用户不想动这台生产机：**只做 dry-run + 静态核对**也可接受，在 FEEDBACK 里注明未 apply。

### 阶段 E — 实跑后验收（仅当 D 实跑了）
```bash
sudo ./scripts/verify.sh fedora-gen      # 期望 0 failed（或解释每个 FAIL）
# 另开一个终端，确认 60022 能新建 SSH 连接后，再关掉旧会话
```

## 3. Fedora 核对清单（逐模块，dry-run 输出应体现）

- **base-packages**：走 dnf，包名应为 `git zsh curl file procps-ng gcc gcc-c++ make ca-certificates`。
- **ssh-hardening**：
  - 装 `openssh-server policycoreutils-python-utils`。
  - SELinux：`configure_selinux_port` 应执行（`semanage port ... ssh_port_t ... 60022`）；
    确认 `has_semanage` 为真。**实跑时**留意幂等块（已存在端口不应报错）。
  - 写 drop-in `/etc/ssh/sshd_config.d/10-cli-boot-kit.conf`，含 `Port 60022`。
  - firewalld 放行 60022/tcp。
  - 重启路径：Fedora 非 socket-activated，应 `systemctl enable/restart sshd`（**不是** ssh.socket）。
- **firewall**：`firewall_kind` = firewalld；`systemctl enable --now firewalld` + 放行 60022/tcp + `firewall-cmd --list-all`。
- **fail2ban**：装 `fail2ban fail2ban-firewalld`，`banaction=firewallcmd-rich-rules`；
  jail 文件 `port=60022`、`ignoreip` 含 `100.64.0.0/10`。**实跑后**确认 `fail2ban-client status sshd` 正常、规则真的生效。
- **homebrew / brew-bundle**：Linuxbrew 以目标用户安装；`brew bundle` 跑 `Brewfile`。
- **chezmoi**：Fedora 应走 **dnf 安装 chezmoi**（不是官方 installer 分支）；随后 `chezmoi init <repo> --apply`。
- **zsh**：登录 shell 设为 `DEFAULT_SHELL`（zsh）。
- **bubblewrap**：Fedora 装 `bubblewrap`（**不**走 Ubuntu 的 AppArmor 分支）；`bwrap` 自检通过。
- **developer-tools**：Claude Code + Codex 官方 installer 装进 `~/.local`（以目标用户、非 root）。
- **tailscale**（profile `INSTALL_TAILSCALE=yes`）：官方 installer + `ethtool`，委托 `setup-tailscale-exit-node.sh`。
- **podman-quadlet**（`INSTALL_PODMAN_QUADLET=yes`）：**重点**——
  - `dnf install -y podman`；
  - **校验 Quadlet generator 路径**：脚本只查
    `/usr/lib/systemd/system-generators/podman-system-generator` 与
    `/usr/libexec/systemd/system-generators/podman-system-generator`。
    在 beelink 上确认 generator **实际位置**和 `podman --version`（需 ≥ 4.4）。
    若实际路径不在这两者中，记进 FEEDBACK（需要补路径）。
  - 建 `/etc/containers/systemd` + `daemon-reload`。
- **router-sysctl**（`APPLY_ROUTER_SYSCTL=yes`）：写 `/etc/sysctl.d/90-router-local.conf`（bbr/fq 等）。
- **timezone**：bootstrap 首步 `timedatectl set-timezone`，值取自 `fedora-gen.env`。

## 4. `profiles/fedora-gen.env` 待校准项（标了 `# TODO1`）

请根据 beelink 真实情况确认/修正，并在 FEEDBACK 给出建议值：

- `TIMEZONE=America/New_York` —— 确认是否正确。
- `SSH_PORT=60022` —— 确认与安全组/现状一致。
- `TAILSCALE_NETDEV=`（空=自动探测）—— 确认自动探测出的网卡对不对（dry-run 会打印 `Egress interface:`）。
- `ADVERTISE_EXIT_NODE=no` —— beelink 是否应作为 exit node？
- `APPLY_ROUTER_SYSCTL=yes` —— beelink 是否承载 router 角色？
- `INSTALL_PODMAN_QUADLET=yes` —— beelink 跑 Quadlet 容器，应为 yes（确认）。
- `INSTALL_CLAUDE` / `INSTALL_CODEX` / `CHEZMOI_REPO` —— 确认符合预期。

> 注意边界：本 repo 的 `podman-quadlet` **只装工具链，不部署任何容器 workload**
> （AdGuard Home 等容器配置在用户的独立 repo 维护）。不要在本 repo 里加 workload。

## 5. 安全 / 防锁死再强调

- 改 SSH 端口前，**新开一个会话验证 60022 可登录后**再断旧会话。
- firewalld 放行顺序：脚本先放行 60022 再 enable，但请人工复核 dry-run 里的顺序。
- 不确定就停在 dry-run，别 apply。

## 6. 产出 `FEEDBACK.md`（在 repo 根目录，commit 上来）

请生成 `FEEDBACK.md`，包含以下分节：

```markdown
# FEEDBACK — Fedora (beelink) 实测结果

## 环境
- OS / 版本 / 架构（`cat /etc/os-release`、`uname -m`）
- podman 版本、Quadlet generator 实际路径（`which`/`ls` 结果）
- 是否实跑 apply（是/否，未 apply 说明原因）

## 阶段结果
- 阶段 A shellcheck：CLEAN / 告警全文
- 阶段 B/C verify + dry-run：是否符合预期
- 阶段 D/E（若 apply）：每模块实跑结果 + verify 最终 summary

## 逐项核对（对照 HANDOFF 第 3 节）
- 每条：符合 / 不符合（贴关键打印片段）。重点标注 SELinux semanage、
  firewalld、fail2ban-firewalld、Quadlet generator 路径、podman 版本、chezmoi dnf 分支。

## 发现的问题 / Bug
- 现象 + 复现命令 + 期望 vs 实际。能定位到文件/行号更好。

## profile 建议
- fedora-gen.env 各 TODO1 项的建议最终值。

## 给原 agent 的待办
- 需要在 repo 里修什么（脚本/profile/文档），按优先级列。
```

写完 `FEEDBACK.md` 后 `git add FEEDBACK.md && git commit && git push`，告诉用户已完成。
