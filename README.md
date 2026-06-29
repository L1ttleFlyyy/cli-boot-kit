# cli-boot-kit

Reusable, modular bootstrap for converging a fresh Linux server to a
repeatable CLI-first environment. Supports **Fedora** and **Debian/Ubuntu**
from the same high-level flow; platform differences live in the OS abstraction
(`scripts/lib/os.sh`).

Each host is described by a **profile** (`profiles/<name>.env`) that declares its
target state. Every script takes the profile as a required positional argument
and supports `--dry-run`, so you can preview every command before applying:

```
./scripts/<script>.sh <profile> [--dry-run]
```

Modules converge to the profile's declared state and re-run safely. The
historical single-shot scripts are archived under `docs/archive/`.

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

Pick a profile (or copy one) and preview the full flow (safe, no changes):

```bash
sudo ./scripts/bootstrap.sh ubuntu-gen --dry-run
```

Run the bootstrap:

```bash
sudo ./scripts/bootstrap.sh ubuntu-gen
```

Run via `sudo` from the **target login user** (e.g. the cloud image's default
`ubuntu`). The bootstrap does not create users; it configures whichever user
invoked `sudo`. Which optional modules run (Tailscale / Podman-Quadlet /
router sysctl) and whether the host advertises as an exit node are declared in
the profile — there are no interactive toggles. The runner shows numbered steps,
runs `verify.sh` at the end, and only prompts before reboot. Set `NO_COLOR=1`
for plain output.

## Profiles & config

A profile is the single source of truth for a host. `config/defaults.env` and
`config/ssh.env` only provide fallback baselines beneath the profile.

| File | Purpose |
| --- | --- |
| `profiles/<name>.env` | **Per-host target state**: timezone, `SSH_PORT`, shell, chezmoi repo, trusted tailnet CIDR, dev-tool + optional-module toggles. Required argument to every script. |
| `profiles/ubuntu-gen.env` | Reference Ubuntu 24.04 (arm-oci) profile. |
| `profiles/fedora-gen.env` | Reference Fedora 44 (beelink) profile. |
| `config/defaults.env` | Fallback defaults beneath the profile. |
| `config/ssh.env` | Fallback `SSH_PORT` (default `60022`). |
| `config/authorized_keys` | SSH public keys (gitignored; created from the example). Existing keys on a host are never overwritten. |
| `Brewfile` | Cross-platform CLI tools installed via Homebrew. |

To onboard a new host, copy the closest profile and edit it:

```bash
cp profiles/ubuntu-gen.env profiles/myhost.env
sudo ./scripts/bootstrap.sh myhost --dry-run
```

## Modules

Every module runs standalone with the same `<profile> [--dry-run]` signature:

```bash
sudo ./scripts/modules/base-packages.sh ubuntu-gen --dry-run
sudo ./scripts/modules/ssh-hardening.sh ubuntu-gen --dry-run
sudo ./scripts/modules/firewall.sh ubuntu-gen --dry-run
sudo ./scripts/modules/fail2ban.sh ubuntu-gen --dry-run
sudo ./scripts/modules/homebrew.sh ubuntu-gen --dry-run
sudo ./scripts/modules/brew-bundle.sh ubuntu-gen --dry-run
sudo ./scripts/modules/chezmoi.sh ubuntu-gen --dry-run
sudo ./scripts/modules/zsh.sh ubuntu-gen --dry-run
sudo ./scripts/modules/bubblewrap.sh ubuntu-gen --dry-run
sudo ./scripts/modules/developer-tools.sh ubuntu-gen --dry-run
sudo ./scripts/modules/tailscale.sh ubuntu-gen --dry-run
sudo ./scripts/modules/podman-quadlet.sh ubuntu-gen --dry-run
sudo ./scripts/modules/router-sysctl.sh ubuntu-gen --dry-run
```

`esp-mirror-sync.sh` is host-specific and **not** part of the profile flow; it
keeps its own `config/esp-mirror-sync.env` and is run separately.

Recommended order and platform behavior:

| Module | Fedora | Debian/Ubuntu | Notes |
| --- | --- | --- | --- |
| `base-packages.sh` | dnf, `procps-ng gcc gcc-c++ make` | apt, `procps build-essential` | Run first. |
| `ssh-hardening.sh` | SELinux `ssh_port_t`, firewalld, restart `sshd` | no SELinux, ufw rule, restart `ssh.socket` | Reads `SSH_PORT` from profile + `authorized_keys`. |
| `firewall.sh` | firewalld baseline | ufw default-deny, allow `SSH_PORT` then enable | Allows SSH before enabling to avoid lockout. |
| `fail2ban.sh` | `fail2ban-firewalld`, firewalld action | `banaction = ufw` | sshd jail on `SSH_PORT`; ignores tailnet. |
| `homebrew.sh` | Linuxbrew as target user | same | After base packages. |
| `brew-bundle.sh` | `Brewfile` | same | After Homebrew. |
| `chezmoi.sh` | dnf `chezmoi` if missing | official installer / Homebrew | Applies `CHEZMOI_REPO`. |
| `zsh.sh` | sets login shell | same | After dotfiles. |
| `bubblewrap.sh` | dnf `bubblewrap` | apt + AppArmor `bwrap-userns-restrict` | Verifies `bwrap`. Codex sandbox dep. |
| `developer-tools.sh` | official installers | same | Claude Code + Codex into `~/.local`. |
| `tailscale.sh` | official installer + `ethtool` | same | Optional (`INSTALL_TAILSCALE`). Installs but leaves node unauthenticated. |
| `podman-quadlet.sh` | dnf `podman` + Quadlet | apt `podman` + Quadlet | Optional (`INSTALL_PODMAN_QUADLET`). Toolchain only; deploys no workload. |
| `router-sysctl.sh` | sysctl (bbr/fq/...) | same | Optional (`APPLY_ROUTER_SYSCTL`). |

`esp-mirror-sync.sh` is host-specific and outside the profile flow; see
`docs/esp-mirror-sync.md`.

## Tailscale exit node

`TAILSCALE_NETDEV` (empty = auto-detect) and `ADVERTISE_EXIT_NODE` are declared
in the profile. To apply only the exit-node networking:

```bash
sudo ./scripts/setup-tailscale-exit-node.sh <profile>
```

After advertising, approve the exit node in the Tailscale admin console
(Machines → this host → route settings → enable "Use as exit node").

Tailscale registration (`tailscale up`) is intentionally manual and outside the
bootstrap.

## Verify

`verify.sh` checks a host against its profile and prints a grouped
`[PASS]/[FAIL]/[SKIP]` report with a summary; it exits non-zero on any failure.
Run it **before** deploy (env-check) or **after** (acceptance) — `bootstrap.sh`
also runs it automatically at the end.

```bash
sudo ./scripts/verify.sh ubuntu-gen
```

Checks that need root (ufw/firewalld status, `fail2ban-client`, `sshd -t`) are
reported as `[SKIP]` when run without it.

## References

- Homebrew on Linux: https://docs.brew.sh/Homebrew-on-Linux
- Homebrew Bundle: https://docs.brew.sh/Brew-Bundle-and-Brewfile
- Claude Code install: https://code.claude.com/docs/en/setup
- Codex CLI: https://github.com/openai/codex
- Tailscale performance: https://tailscale.com/docs/reference/best-practices/performance
- Tailscale exit node: https://tailscale.com/docs/features/exit-nodes/how-to/setup
