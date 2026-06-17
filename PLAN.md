# cli-boot-kit Plan

`cli-boot-kit` 的目标是把一台新的 Linux 服务器收敛到可重复、可审计的 CLI-first 工作环境。它来自早期的一次性 `setup_server.sh`，下一阶段要升级成以配置文件为入口的声明式部署模板。

当前参考状态：

- `beelink`: Fedora 44 Server, x86_64, 当前本机。
- `arm-oci`: Ubuntu 24.04 LTS, arm64, 可视为 Ubuntu 目标状态的大致参考。

这两个主机都不是应该原样复制的最终答案。Fedora 侧已经有 Podman Quadlet 版 AdGuard Home，但本机 resolver 接管状态可能被 rollback 过；Ubuntu 侧 SSH、Tailscale、Homebrew、Codex/bubblewrap 状态有参考价值，但 AdGuard Home 是 root 直接安装到 `/opt/AdGuardHome` 并监听 `*:53`，这不符合本模板的目标。

## Principles

- 继续维持声明式部署：配置声明目标状态，脚本负责收敛和验证。
- 模块必须可重复运行；重复 apply 不应产生重复配置或破坏现有 state。
- Fedora 和 Ubuntu 共用同一个高层配置模型，平台差异放到 OS abstraction。
- 默认值保守，host-specific 细节必须显式声明。
- 不把当前机器的偶然状态写成通用规则。
- 不把 LAN/tailnet 之外的公网暴露视为 trusted。

## Configuration Shape

第一阶段使用 shell-safe `.env` 配置，避免引入额外 parser。复杂文件继续独立管理，例如 `authorized_keys`、`Brewfile`、AdGuard Home config template。

建议目录：

```text
config/
  defaults.env
  hosts/
    beelink.env
    arm-oci.env
  authorized_keys.example
  authorized_keys
```

核心变量草案：

```sh
HOSTNAME=
TARGET_USER=
TIMEZONE=

SSH_PORT=60022
SSH_DISABLE_ROOT_LOGIN=yes
SSH_DISABLE_PASSWORD_LOGIN=yes

INSTALL_HOMEBREW=yes
BREWFILE=Brewfile
CHEZMOI_REPO=l1ttleflyyy
DEFAULT_SHELL=zsh

INSTALL_CODEX=yes
INSTALL_CLAUDE=yes
INSTALL_BUBBLEWRAP=yes

INSTALL_TAILSCALE=no
TAILSCALE_LEAVE_UNAUTHED=yes

ENABLE_ROUTER_EXIT_NODE_PROFILE=yes
ROUTER_NETDEV=

INSTALL_PODMAN_QUADLET=no
INSTALL_FIREWALL=yes
INSTALL_FAIL2BAN=yes
TRUSTED_LAN_CIDRS=
TRUSTED_TAILNET_CIDR=100.64.0.0/10

INSTALL_ADGUARDHOME=no
ADGUARD_WEB_BIND=0.0.0.0
ADGUARD_WEB_PORT=3000
ADGUARD_DNS_BIND=0.0.0.0
ADGUARD_ROUTE_HOST_DNS=yes
ADGUARD_DNS_PACKET_FORWARDING=yes
```

## Module Plan

### `lib/config.sh`

Responsibilities:

- Load `config/defaults.env`.
- Load optional `config/hosts/<name>.env`.
- Validate required variables.
- Normalize booleans.
- Provide `config_bool`, `config_value`, and `config_path` helpers.

### `lib/os.sh`

Responsibilities:

- Detect `ID`, `ID_LIKE`, and version from `/etc/os-release`.
- Expose platform predicates: `is_fedora`, `is_ubuntu`, `has_selinux`, `selinux_enforcing`.
- Provide package helpers:
  - Fedora: `dnf install -y`.
  - Ubuntu: `apt-get update`, `apt-get install -y`.
- Provide firewall helpers:
  - Fedora: `firewalld` when active.
  - Ubuntu: `ufw`.
- Provide service name helpers where distro names differ.

SELinux should not be a prerequisite. If runtime detects SELinux enforcing, modules apply SELinux-specific handling where required. If SELinux is permissive or disabled, they skip those steps.

### `identity`

Responsibilities:

- Set hostname.
- Set timezone.
- Ensure target user exists when configured.
- Ensure target user has sudo access.
- Optionally enable passwordless sudo.

Ubuntu cloud images often start with an `ubuntu` user; Fedora local installs may start with a different user. User creation must be controlled by config, not hard-coded.

### `ssh`

Responsibilities:

- Install OpenSSH server.
- Install `authorized_keys`.
- Write SSH hardening drop-in.
- Validate with `sshd -t`.
- Enable and restart SSH service.
- Open configured SSH port in firewall.
- On SELinux enforcing Fedora, add or modify `ssh_port_t` for non-standard ports.

Target hardening:

```text
Port 60022
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
UsePAM yes
```

### `base-packages`

Responsibilities:

- Install common system packages needed by the rest of the bootstrap.
- Fedora package set starts from: `git zsh curl file procps-ng gcc gcc-c++ make`.
- Ubuntu package set starts from: `git zsh curl file procps build-essential`.
- Install firewall/fail2ban packages only when their modules are enabled.

### `firewall`

Responsibilities:

- Fedora: manage firewalld only when it is active or explicitly enabled.
- Ubuntu: manage ufw.
- Default deny inbound, allow outbound.
- Public internet may reach only the configured SSH port, normally `60022/tcp`.
- LAN and tailnet are trusted scopes; non-SSH service ports are reachable only from those scopes.
- Do not add per-service public exceptions for AdGuard Home, Podman services, or local tools.
- Keep the firewall model fail-closed: if trusted LAN/tailnet sources are not configured, only public SSH is exposed.

Trust model:

- LAN is trusted.
- Tailnet is trusted.
- Public internet is not trusted.

Final target:

- Public zone/interface: allow only `SSH_PORT/tcp`.
- Trusted LAN CIDRs and tailnet CIDR/interface: allow all local service ports.
- AdGuard Home Web UI binds `0.0.0.0:3000`; no explicit `3000/tcp` rule is needed because the zone policy already decides who can reach it.
- AdGuard Home DNS binds `0.0.0.0:53`; public DNS is blocked, trusted LAN/tailnet DNS is allowed or forwarded by packet filter rules.

### `fail2ban`

Responsibilities:

- Default-enabled when `INSTALL_FIREWALL=yes`.
- Enable SSH jail.
- Monitor the configured SSH port, normally `60022`.
- Ubuntu target uses `banaction = ufw`.
- Fedora target uses firewalld integration, not raw legacy iptables actions.
- Ignore loopback and explicitly configured trusted CIDRs, such as tailnet CIDR.
- Verify that bans produce effective firewall rules, not just Fail2ban log entries.

Fedora/firewalld research note:

- Fedora packages `fail2ban-firewalld` separately as "Firewalld support for Fail2Ban" and describes firewalld as Fedora's default firewall service: <https://packages.fedoraproject.org/pkgs/fail2ban/fail2ban-firewalld/>.
- Upstream Fail2ban ships `firewallcmd-*` actions, including `firewallcmd-ipset` and `firewallcmd-rich-rules`: <https://github.com/fail2ban/fail2ban/tree/master/config/action.d>.
- Preferred Fedora target is therefore `fail2ban` + `fail2ban-firewalld` + a `firewallcmd` action, with verification through `fail2ban-client status sshd` and `firewall-cmd` output. This is better aligned with Fedora than forcing iptables actions into a firewalld/nftables host.

### `homebrew`

Responsibilities:

- Install Linuxbrew for target user.
- Run `brew bundle` with the configured Brewfile.
- Keep Homebrew focused on cross-platform CLI tools.

Required Brewfile contents:

```ruby
brew "gcc"
brew "btop"
brew "chezmoi"
brew "dust"
brew "eza"
brew "fd"
brew "fzf"
brew "gh"
brew "iperf3"
brew "neovim"
brew "ripgrep"
brew "shellcheck"
brew "tmux"
brew "tmux-mem-cpu-load"
brew "tree-sitter-cli"
brew "uv"
```

Do not manage these through Brewfile:

- `bubblewrap`: install with the OS package manager.
- `codex`: install through the recommended OpenAI path.
- `claude-code`: install through its recommended path.

Other CLI tools, GUI apps, and casks are user-managed and should not be listed in the template config.

### `chezmoi`

Responsibilities:

- Install `chezmoi` through OS packages or Homebrew, depending on platform and availability.
- Apply `chezmoi init "$CHEZMOI_REPO" --apply` as target user.
- `CHEZMOI_REPO` must be config-driven, not hard-coded.

### `shell`

Responsibilities:

- Ensure configured shell is installed.
- Add shell path to `/etc/shells` if missing.
- Change target user's login shell.

### `developer-tools`

Responsibilities:

- Install Codex through the recommended OpenAI install path.
- Install Claude through its recommended install path.
- Keep these out of Homebrew unless a host explicitly overrides the install method.
- Verify binaries and versions.

Codex Linux sandbox dependency belongs to `bubblewrap`, not to the Codex installer.

### `bubblewrap`

Responsibilities:

- Install `bubblewrap` with the OS package manager.
- Verify `bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true`.
- On Ubuntu 24.04, install and load the AppArmor profile:

```sh
apt-get install -y bubblewrap apparmor-profiles apparmor-utils
install -m 0644 \
  /usr/share/apparmor/extra-profiles/bwrap-userns-restrict \
  /etc/apparmor.d/bwrap-userns-restrict
apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict
```

Do not disable Ubuntu's unprivileged user namespace restriction as part of the template. If the profile is unavailable or verification still fails, report it as a manual blocker.

### `tailscale`

Responsibilities:

- Install Tailscale with the official installer or distro package path.
- Enable `tailscaled`.
- Leave the node unauthenticated by default.
- Do not script `tailscale up`, control server selection, or state import. Registration is manual and outside the declarative bootstrap target for now.

### `router-exit-node`

Responsibilities:

- Apply router/exit-node sysctl profile by default.
- Apply Linux UDP GRO forwarding optimization for the default route device or configured `ROUTER_NETDEV`.
- Keep this independent from Tailscale authentication; the host can be ready for exit-node use before the user manually registers Tailscale.

Router/exit-node sysctl target:

```text
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 15
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

UDP GRO optimization target:

```sh
ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
```

This profile is default-on because most Linux servers in this template are expected to be router or exit-node candidates, and these settings are acceptable before Tailscale is authenticated.

### `podman-quadlet`

Responsibilities:

- Install Podman.
- Verify systemd Quadlet generator availability.
- Ensure `/etc/containers/systemd` exists.
- Install `.container` files.
- Run `systemctl daemon-reload`.
- Enable/restart generated services.

This module provides the generic runtime substrate for services such as AdGuard Home.

### `adguardhome`

Responsibilities:

- Depend on `podman-quadlet`.
- Use system-level Quadlet, not direct `/opt/AdGuardHome` install.
- Use `systemd-sysusers` for service user.
- Use `systemd-tmpfiles` for persistent directories.
- Render `AdGuardHome.yaml` from config.
- Render `/etc/containers/systemd/adguardhome.container`.
- Enable and restart `adguardhome.service`.
- Route host DNS through AdGuard Home by default.
- Expose LAN/tailnet DNS through iptables-compatible packet forwarding/allow rules, not through interface-specific AdGuard Home bind entries.
- Provide verify and rollback scripts.

Container target:

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

If SELinux is enforcing, use appropriate Podman volume labeling such as `:Z`. If SELinux is not enforcing, do not require SELinux state just to deploy the service.

Web UI target:

- Bind `0.0.0.0:3000` by default.
- Rely on the global firewall model: public has only SSH open; LAN and tailnet can reach local service ports.
- Do not add an AdGuard-specific `3000/tcp` public or trusted rule.
- Default no password is acceptable only under this trust model: public `3000/tcp` closed; LAN and tailnet trusted.

DNS bind target:

- Bind `0.0.0.0:53` by default.
- Do not bind explicit LAN, tailnet, or loopback-only addresses in the generic template.
- Do not use `net.ipv4.ip_nonlocal_bind = 1` or `net.ipv6.ip_nonlocal_bind = 1`; those are unsupported target-state dependencies for this template.
- Let firewall and iptables-compatible packet forwarding decide which LAN/tailnet clients can query DNS.
- Do not copy host-specific values such as `192.168.8.8`, `192.168.8.1`, `100.123.123.4`, or `luuumi.vpn` into generic defaults.

Host resolver mode:

- Default enabled.
- Route system DNS through `127.0.0.1`.
- Avoid resolver deadlocks by binding AdGuard Home to `0.0.0.0`, not to interface-specific addresses that may not exist yet.

## Desired End State

### Fedora-like host

- Uses `dnf` package path.
- Uses firewalld when active.
- Uses Fail2ban for public SSH protection through firewalld integration.
- Handles SELinux only when enforcing.
- Supports Podman Quadlet services.
- Installs Tailscale but leaves authentication to the user.
- Applies router/exit-node sysctl and UDP GRO profile by default.
- Supports AdGuard Home through Quadlet.

### Ubuntu-like host

- Uses `apt` package path.
- Uses ufw and Fail2ban for public SSH protection.
- Installs `bubblewrap` through apt.
- Applies Ubuntu 24.04 AppArmor profile fix for Codex sandboxing.
- Installs Tailscale but leaves authentication to the user.
- Applies router/exit-node sysctl and UDP GRO profile by default.
- Migrates AdGuard Home away from direct root `/opt/AdGuardHome` service to Podman Quadlet when enabled.

## Implementation Phases

### Phase 1: Document and configuration layer

- Add this plan.
- Add `config/defaults.env.example`.
- Add host config examples for Fedora and Ubuntu.
- Add `lib/config.sh`.
- Keep current Fedora behavior intact while adding config-driven values.

### Phase 2: Platform abstraction

- Add `lib/os.sh`.
- Replace direct `require_fedora` calls with OS-aware checks.
- Add unified package and firewall helpers.

### Phase 3: Core bootstrap

- Generalize identity, SSH, base packages, Homebrew, chezmoi, and shell modules.
- Split Fedora and Ubuntu package lists.
- Remove `bubblewrap`, `codex`, and `claude-code` from Brewfile.

### Phase 4: Codex runtime support

- Add `bubblewrap` module.
- Add Ubuntu 24.04 AppArmor profile handling.
- Add developer tools module for Codex and Claude installers.

### Phase 5: Tailscale and router profile

- Generalize existing Tailscale module across Fedora and Ubuntu.
- Install and enable `tailscaled`, but leave it unauthenticated.
- Add default-on router/exit-node sysctl profile.
- Add verify output for sysctl and ethtool features.

### Phase 6: Podman Quadlet

- Add generic Podman install and Quadlet apply helpers.
- Verify systemd generator output.

### Phase 7: AdGuard Home

- Port the useful deployment pattern from `dns-server/deploy`.
- Remove LAN/tailnet hard-coding from generic defaults.
- Add host-specific config support for LAN split DNS, tailnet split DNS, and trusted DNS forwarding.
- Add rollback for host resolver changes.

## Verification Checklist

Common:

- `sshd -t`
- SSH listens on configured port.
- Public firewall exposes only configured SSH port.
- Target user shell is configured.
- `brew bundle check` passes for the target Brewfile.
- `chezmoi doctor` has no blocking errors.
- Fail2ban `sshd` jail is active and watching the configured SSH port.

Ubuntu Codex sandbox:

- `bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true`
- AppArmor profile `bwrap` and `unpriv_bwrap` loaded on Ubuntu 24.04.

Tailscale:

- `tailscaled` service active.
- Node remains unauthenticated unless the user has manually registered it.

Router/exit-node profile:

- Target sysctl values are applied.
- `rx-udp-gro-forwarding: on`
- `rx-gro-list: off`

AdGuard Home:

- `adguardhome.service` active.
- Service source is `/etc/containers/systemd/adguardhome.container`.
- Web UI listens on `0.0.0.0:3000`.
- Firewall blocks public `3000/tcp`.
- DNS listens on `0.0.0.0:53`.
- Trusted LAN/tailnet DNS queries are allowed or forwarded by packet filter policy.
- Host resolver uses AdGuard Home by default.
- Rollback restores host resolver path.

## Open Questions

- Whether Codex and Claude installers should be enabled by default or remain explicit feature flags.
- Whether Homebrew should be required on minimal servers or optional per host.
- Whether Ubuntu should standardize on `systemd-networkd` assumptions or treat network manager selection as host-specific.
