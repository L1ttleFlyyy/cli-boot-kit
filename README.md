# Fedora Server Setup

Reusable Fedora Server bootstrap scripts for a home server.

The current setup is modular:

- Required: DNF essentials, SSH hardening, Homebrew, Brewfile packages, chezmoi,
  and zsh as the login shell.
- Optional: Tailscale exit-node setup and router-oriented kernel parameters.
- Deferred: broad firewall hardening and fail2ban.

Historical reference from the old Debian/Ubuntu script is archived at:

```text
docs/archive/setup_server.old-debian-ubuntu.sh
```

## Bootstrap A New Fedora Server

Review the full flow:

```bash
sudo ./scripts/bootstrap-fedora-server.sh --dry-run --netdev enp2s0
```

Run the interactive bootstrap:

```bash
sudo ./scripts/bootstrap-fedora-server.sh --netdev enp2s0
```

If this server should advertise itself as a Tailscale exit node:

```bash
sudo ./scripts/bootstrap-fedora-server.sh --netdev enp2s0 --advertise-exit-node
```

The runner shows numbered progress steps, prompts before optional router settings
and rebooting, and rings the terminal bell before interactive prompts when the
terminal supports it. Set `NO_COLOR=1` to force plain-text output.

## Config

SSH defaults live in:

```text
config/ssh.env
config/authorized_keys.example
```

Create `config/authorized_keys` locally before running the SSH module, or let
the module prompt for keys on its first real run. The real file is gitignored so
SSH access lists are not published with the repository.

Homebrew packages live in:

```text
Brewfile
```

## Modules

Each module can be run directly:

```bash
sudo ./scripts/modules/dnf-essentials.sh --dry-run
sudo ./scripts/modules/ssh-hardening.sh --dry-run
sudo ./scripts/modules/homebrew.sh --dry-run
sudo ./scripts/modules/brew-bundle.sh --dry-run
sudo ./scripts/modules/chezmoi.sh --dry-run
sudo ./scripts/modules/zsh.sh --dry-run
sudo ./scripts/modules/tailscale.sh --dry-run --netdev enp2s0
sudo ./scripts/modules/router-sysctl.sh --dry-run
sudo ./scripts/modules/esp-mirror-sync.sh --dry-run
```

Recommended order and dependencies:

| Module | Depends on | Notes |
| --- | --- | --- |
| `dnf-essentials.sh` | Fedora + `dnf` | Run first. Installs `git`, `zsh`, `curl`, `file`, `procps-ng`, `gcc`, `gcc-c++`, and `make`. |
| `ssh-hardening.sh` | `config/ssh.env`, `config/authorized_keys` | Installs its own SSH/SELinux packages, configures SELinux for port `60022`, writes the SSH drop-in, and opens firewalld if active. |
| `homebrew.sh` | `curl`, `bash` | Should run after DNF essentials on a new host. Installs Linuxbrew as the target sudo user. |
| `brew-bundle.sh` | Homebrew, `Brewfile` | Must run after `homebrew.sh`. |
| `chezmoi.sh` | `git`, `chezmoi` | Should run after DNF essentials. Installs `chezmoi` with DNF if missing. |
| `zsh.sh` | `zsh` | Should run after DNF essentials and after chezmoi dotfiles are applied. |
| `tailscale.sh` | `curl`, `dnf`, optional `--netdev` | Optional. Installs Tailscale if missing, installs `ethtool`, enables `tailscaled`, then calls the exit-node setup script. |
| `router-sysctl.sh` | `sysctl` | Optional and independent. Keep separate from Tailscale exit-node forwarding. |
| `esp-mirror-sync.sh` | `/boot/efi`, second ESP UUID | Optional and host-specific. Installs an idempotent ESP mirror sync helper plus a systemd path watcher. See `docs/esp-mirror-sync.md`. |

For a new server, prefer the top-level runner instead of manually composing
modules unless you are debugging a specific step.

## Tailscale Exit Node Networking

Apply only the Tailscale exit-node networking module:

```bash
sudo ./scripts/setup-tailscale-exit-node.sh --apply --netdev enp2s0
```

Also advertise the machine as a Tailscale exit node:

```bash
sudo ./scripts/setup-tailscale-exit-node.sh --apply --netdev enp2s0 --advertise-exit-node
```

After advertising, approve the exit node in the Tailscale admin console:

1. Open the Machines page.
2. Select this machine.
3. Open route settings.
4. Enable "Use as exit node".

## Verify

```bash
sshd -t
ss -lntp | grep ':60022'
semanage port -l | grep ssh_port_t
brew bundle check --file Brewfile
chezmoi doctor
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
systemctl status --no-pager tailscale-network-optimize.service
sudo ethtool -k enp2s0 | grep -E 'rx-udp-gro-forwarding|rx-gro-list'
tailscale status
```

## References

- Homebrew on Linux: https://docs.brew.sh/Homebrew-on-Linux
- Homebrew Bundle: https://docs.brew.sh/Brew-Bundle-and-Brewfile
- Tailscale performance best practices:
  https://tailscale.com/docs/reference/best-practices/performance
- Tailscale exit node setup:
  https://tailscale.com/docs/features/exit-nodes/how-to/setup
