# FEEDBACK — Fedora (beelink) 实测结果

## 环境

- OS / 版本 / 架构：Fedora Linux 44 Server Edition, x86_64.
- `podman` 版本：`podman version 5.8.3`.
- Quadlet generator 实际路径：
  - 存在：`/usr/lib/systemd/system-generators/podman-system-generator -> ../../../libexec/podman/quadlet`
  - 不存在：`/usr/libexec/systemd/system-generators/podman-system-generator`
- 是否实跑 apply：是。
- 使用 profile：`beelink`。原因：这台机器已有 Cloudflare WARP policy routing，默认路由探测会得到 `warp0`；profile 显式设置 `TAILSCALE_NETDEV=enp2s0`。

## 阶段结果

- 阶段 A shellcheck：CLEAN。
- 阶段 B 部署前 verify：脚本正常运行，`26 passed, 5 failed, 0 skipped`。部署前 FAIL 符合预期：SSH drop-in、fail2ban jail、router sysctl 尚未由 kit 管理。
- 阶段 C dry-run：符合 Fedora 分支预期，关键路径见下方逐项核对。
- 阶段 D apply：成功。第一次 apply 在 `chezmoi init --apply` 因本机 dotfile diff 触发交互而中断；手动 resolve 后 rerun 成功。
- 阶段 E apply 后验收：`sudo ./scripts/verify.sh beelink` 为 `32 passed, 0 failed, 0 skipped`。

## 逐项核对

- base-packages：符合。dry-run 打印：
  `dnf install -y git zsh curl file procps-ng gcc gcc-c++ make ca-certificates`
- ssh-hardening：符合。
  - `dnf install -y openssh-server policycoreutils-python-utils`
  - 目标用户已有 `/home/lfy/.ssh/authorized_keys`，脚本打印 `leaving it untouched (no overwrite/merge)`。
  - SELinux：apply 后 `ssh_port_t tcp 60022, 22`。
  - drop-in：apply 后 verify PASS，`/etc/ssh/sshd_config.d/10-cli-boot-kit.conf` declares `Port 60022`。
  - firewalld：`firewall-cmd --permanent --add-port=60022/tcp`，apply 后 `yes`。
  - SSH restart：Fedora 走 `systemctl enable sshd` + `systemctl restart sshd`。
- firewall：符合。apply log 中 `firewalld` active，zone 含 `ports: 60022/tcp 41641/udp`。
- fail2ban：符合。安装 `fail2ban fail2ban-firewalld`，jail 使用 `banaction = firewallcmd-rich-rules`、`port = 60022`、`ignoreip = 127.0.0.0/8 ::1 100.64.0.0/10`。apply 后 `fail2ban-client status sshd` 正常。
- homebrew / brew-bundle：符合。以目标用户 `lfy` 运行，`brew bundle complete`。
- chezmoi：Fedora 走已安装 chezmoi 分支，随后对 `l1ttleflyyy` 执行 apply。发现交互阻塞问题，见 Bug。
- zsh：功能通过。apply 后 login shell 一度为 `/usr/sbin/zsh`，verify PASS；路径选择问题已在本轮修复为优先 `/usr/bin/zsh` / `/bin/zsh`。
- bubblewrap：符合。Fedora 安装 `bubblewrap`，`bwrap user namespace sandbox works`。
- developer-tools：符合。Claude Code 与 Codex CLI 已存在，脚本跳过安装。
- tailscale：基本符合。安装/更新 `tailscale` 与 `ethtool`，`tailscaled` active。`beelink` profile 使 egress interface 为 `enp2s0`。
- podman-quadlet：符合。`dnf install -y podman`，Podman 5.8.3，generator 位于脚本检查路径之一，`/etc/containers/systemd` 存在。
- router-sysctl：符合。apply 后 verify PASS：`tcp_congestion_control = bbr`、`default_qdisc = fq`。
- timezone：符合。`America/New_York`。

## 发现的问题 / Bug

- P1：`chezmoi init <repo> --apply` 在已有本机变更时会交互阻塞 bootstrap。
  - 复现：第一次 apply 卡在 `.claude/settings.json has changed since chezmoi last wrote it?`
  - 期望：bootstrap 的 apply 路径 non-interactive，或明确使用 `--force` / fail-fast 策略。
  - 实际：需要人工处理后 rerun。
  - 建议：初始化机器场景可接受 `chezmoi init <repo> --apply --force`，或拆成 profile 开关明确策略。
- P2：`ADVERTISE_EXIT_NODE=no` 时仍写入 exit-node forwarding sysctl 和 `tailscale-network-optimize.service`。
  - 期望：安装 Tailscale、配置 exit-node forwarding、advertise exit node 三者边界清晰。
  - 实际：不 advertise 也会设置 `net.ipv4.ip_forward=1`、`net.ipv6.conf.all.forwarding=1` 并启用 optimize service。
  - 建议：新增独立开关，例如 `CONFIGURE_TAILSCALE_EXIT_NODE_NETWORKING=yes/no`，或仅在 `ADVERTISE_EXIT_NODE=yes` 时执行。
- P3：`zsh.sh` 在 sudo apply 中选择 `/usr/sbin/zsh`，导致从已有 `/bin/zsh` 切换到等价但不常见路径。已在本轮修复。
  - 期望：优先使用 `/etc/shells` 里已有的 matching path，避免无意义 churn。
  - 实际：apply 后 login shell 为 `/usr/sbin/zsh`，verify 通过；修复后 dry-run 显示将收敛为 `/usr/bin/zsh`。
- P3：SELinux port 幂等日志不准确。
  - 现象：apply log 显示 `Port tcp/60022 already defined, modifying instead`，随后脚本打印 `Added SELinux ssh_port_t tcp/60022`。
  - 期望：区分 added 和 modified。
  - 实际：结果正确，日志文案不准。

## profile 建议

- `TIMEZONE=America/New_York`：保持。
- `SSH_PORT=60022`：保持。
- `TAILSCALE_NETDEV=enp2s0`：beelink 必须显式 override。该机器公网流量有 policy route 到 WARP，自动探测会得到 `warp0`。
- `ADVERTISE_EXIT_NODE=no`：保持，当前不 advertise。
- `APPLY_ROUTER_SYSCTL=yes`：保持，apply 后验证通过。
- `INSTALL_PODMAN_QUADLET=yes`：保持，beelink 使用 Quadlet 工具链；本 repo 不部署 workload。
- `INSTALL_CLAUDE=yes` / `INSTALL_CODEX=yes` / `CHEZMOI_REPO=l1ttleflyyy`：保持。

## 给原 agent 的待办

1. 修 `chezmoi.sh` 的 non-interactive 策略，避免已有 diff 时卡住 bootstrap；优先考虑 `--force` 或显式 profile 开关。
2. 拆分 Tailscale 安装与 exit-node networking。`ADVERTISE_EXIT_NODE=no` 时不应默认写 forwarding sysctl，除非 profile 明确要求。
3. 修正 `configure_selinux_port` 的日志，区分 already allowed / added / modified。
4. 文档上区分 `fedora-gen` 通用 Fedora profile 与 `beelink` host-specific profile；后续 Fedora 新机器应从 `fedora-gen` 复制，不继承 beelink 的 WARP override。
