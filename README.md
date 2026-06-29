# cli-boot-kit

Reusable, modular bootstrap for converging a fresh Linux server to a
repeatable CLI-first environment. Supports **Fedora** and **Debian/Ubuntu**
from the same high-level flow; platform differences live in the OS abstraction
(`scripts/lib/os.sh`).

Each module is idempotent and supports `--dry-run`, so you can preview every
command before applying. The historical single-shot scripts are archived under
`docs/archive/`.

## Before you start (cloud hosts)

The SSH module moves the daemon to port `60022`. On a cloud instance, **open
`60022/tcp` in the provider security group (and keep `22` until you confirm the
new port works)** before running the bootstrap, or you can lock yourself out.

Create your SSH key list first (otherwise the SSH module prompts for keys):

```bash
cp config/authorized_keys.example config/authorized_keys
# edit config/authorized_keys, one public key per line
```

The real `config/authorized_keys` is gitignored so access lists are never
published.

## Bootstrap a new server

Preview the full flow (safe, no changes):

```bash
sudo ./scripts/bootstrap.sh --dry-run
```

Run the interactive bootstrap:

```bash
sudo ./scripts/bootstrap.sh
```

If this host should advertise itself as a Tailscale exit node:

```bash
sudo ./scripts/bootstrap.sh --netdev eth0 --advertise-exit-node
```

Run via `sudo` from the **target login user** (e.g. the cloud image's default
`ubuntu`). The bootstrap does not create users; it configures whichever user
invoked `sudo`. The runner shows numbered steps, prompts before optional
Tailscale/router steps and reboot, and rings the terminal bell before prompts.
Set `NO_COLOR=1` for plain output.

## Config

| File | Purpose |
| --- | --- |
| `config/defaults.env` | Timezone, chezmoi repo, trusted tailnet CIDR, dev-tool toggles. |
| `config/ssh.env` | `SSH_PORT` (default `60022`). |
| `config/authorized_keys` | SSH public keys (gitignored; created from the example). |
| `Brewfile` | Cross-platform CLI tools installed via Homebrew. |

## Modules

Every module runs standalone with `--dry-run`:

```bash
sudo ./scripts/modules/base-packages.sh --dry-run
sudo ./scripts/modules/ssh-hardening.sh --dry-run
sudo ./scripts/modules/firewall.sh --dry-run
sudo ./scripts/modules/fail2ban.sh --dry-run
sudo ./scripts/modules/homebrew.sh --dry-run
sudo ./scripts/modules/brew-bundle.sh --dry-run
sudo ./scripts/modules/chezmoi.sh --dry-run
sudo ./scripts/modules/zsh.sh --dry-run
sudo ./scripts/modules/bubblewrap.sh --dry-run
sudo ./scripts/modules/developer-tools.sh --dry-run
sudo ./scripts/modules/tailscale.sh --dry-run --netdev eth0
sudo ./scripts/modules/router-sysctl.sh --dry-run
sudo ./scripts/modules/esp-mirror-sync.sh --dry-run
```

Recommended order and platform behavior:

| Module | Fedora | Debian/Ubuntu | Notes |
| --- | --- | --- | --- |
| `base-packages.sh` | dnf, `procps-ng gcc gcc-c++ make` | apt, `procps build-essential` | Run first. |
| `ssh-hardening.sh` | SELinux `ssh_port_t`, firewalld, restart `sshd` | no SELinux, ufw rule, restart `ssh.socket` | Reads `ssh.env` + `authorized_keys`. |
| `firewall.sh` | firewalld baseline | ufw default-deny, allow `SSH_PORT` then enable | Allows SSH before enabling to avoid lockout. |
| `fail2ban.sh` | `fail2ban-firewalld`, firewalld action | `banaction = ufw` | sshd jail on `SSH_PORT`; ignores tailnet. |
| `homebrew.sh` | Linuxbrew as target user | same | After base packages. |
| `brew-bundle.sh` | `Brewfile` | same | After Homebrew. |
| `chezmoi.sh` | dnf `chezmoi` if missing | official installer / Homebrew | Applies `CHEZMOI_REPO`. |
| `zsh.sh` | sets login shell | same | After dotfiles. |
| `bubblewrap.sh` | dnf `bubblewrap` | apt + AppArmor `bwrap-userns-restrict` | Verifies `bwrap`. Codex sandbox dep. |
| `developer-tools.sh` | official installers | same | Claude Code + Codex into `~/.local`. |
| `tailscale.sh` | official installer + `ethtool` | same | Optional. Installs but leaves node unauthenticated. |
| `router-sysctl.sh` | sysctl (bbr/fq/...) | same | Optional, independent. |
| `esp-mirror-sync.sh` | dual-ESP mirror | dual-ESP mirror | Optional, host-specific. See `docs/esp-mirror-sync.md`. |

## Tailscale exit node

Apply only the exit-node networking module:

```bash
sudo ./scripts/setup-tailscale-exit-node.sh --apply --netdev eth0 --advertise-exit-node
```

After advertising, approve the exit node in the Tailscale admin console
(Machines → this host → route settings → enable "Use as exit node").

Tailscale registration (`tailscale up`) is intentionally manual and outside the
bootstrap.

## Verify

```bash
sshd -t
ss -lntp | grep ':60022'
sudo ufw status verbose        # Debian/Ubuntu
sudo firewall-cmd --list-all   # Fedora
sudo fail2ban-client status sshd
brew bundle check --file Brewfile
chezmoi doctor
bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / true
claude --version && codex --version
systemctl status --no-pager tailscale-network-optimize.service
tailscale status
```

## References

- Homebrew on Linux: https://docs.brew.sh/Homebrew-on-Linux
- Homebrew Bundle: https://docs.brew.sh/Brew-Bundle-and-Brewfile
- Claude Code install: https://code.claude.com/docs/en/setup
- Codex CLI: https://github.com/openai/codex
- Tailscale performance: https://tailscale.com/docs/reference/best-practices/performance
- Tailscale exit node: https://tailscale.com/docs/features/exit-nodes/how-to/setup
