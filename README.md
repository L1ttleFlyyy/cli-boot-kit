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

Review the tracked SSH public-key allowlist before running the SSH module:

```bash
$EDITOR config/authorized_keys
# one public key per line
```

This repository is private, and `config/authorized_keys` is intentionally
tracked. These are public keys, not private key material. The SSH module uses
the file only to seed a host that does not already have
`~/.ssh/authorized_keys`; existing host keys are never overwritten or merged.
The installed target file is written with mode `600`, regardless of the source
file's repository permissions.

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
invoked `sudo`. Which optional modules run (fail2ban / Tailscale /
Podman-Quadlet / router sysctl) is declared in the profile — there are no
interactive toggles.
The runner shows numbered steps, runs `verify.sh` at the end, and only prompts
before reboot. Set `NO_COLOR=1` for plain output.

## Deployment runbook

Specifics learned from real deploys (arm-oci, beelink):

- **Don't lock yourself out.** `ssh-hardening` restarts SSH. Before applying to a
  remote host, open a **second SSH session** and keep it open — restarting
  `ssh.socket` (Ubuntu) / `sshd` (Fedora) does not drop established connections,
  but keep a safety line. Afterwards, confirm a **fresh** `ssh -p 60022` login
  works before closing everything. To revert SSH:
  `sudo rm /etc/ssh/sshd_config.d/10-cli-boot-kit.conf` and restart the SSH unit.
- **Policy-routed hosts need `TAILSCALE_NETDEV`.** If the default route goes
  through a tunnel (e.g. Cloudflare WARP → `warp0`), auto-detection picks the
  wrong interface for the UDP GRO service. Find the physical NIC and pin it in
  the host profile:
  ```bash
  ip -o route get 8.8.8.8      # what auto-detect would pick
  ls /sys/class/net/           # physical NIC is usually enp*/ens*
  ```
  (See `arm-oci.env` → `enp0s6`, `beelink.env` → `enp2s0`.)
- **chezmoi overwrites to the declared state.** bootstrap runs
  `chezmoi init <repo> --apply --force`. If the host has local edits to managed
  dotfiles you want to keep, run `chezmoi diff` and resolve them first.
- **Reboot.** The final `dnf/apt upgrade` may pull a new kernel; reboot when
  convenient (`sudo systemctl reboot`).
- **Expect a green verify.** After a real apply, `verify.sh <profile>` should be
  all `[PASS]`. Running it *before* deploy naturally shows `[FAIL]`s (env-check).

## Profiles & config

A profile is the single source of truth for a host. `config/defaults.env` and
`config/ssh.env` only provide fallback baselines beneath the profile.

| File | Purpose |
| --- | --- |
| `profiles/<name>.env` | **Per-host target state**: timezone, `SSH_PORT`, shell, chezmoi repo, trusted tailnet CIDR, dev-tool + optional-module toggles. Required argument to every script. |
| `profiles/ubuntu-gen.env` | Generic Ubuntu 24.04 baseline (from arm-oci). |
| `profiles/fedora-gen.env` | Generic Fedora 44 baseline. Copy this for a new Fedora host. |
| `profiles/beelink.env` | Host-specific example: a customized Fedora box (WARP policy routing forces `TAILSCALE_NETDEV=enp2s0`). Do not inherit for fresh hosts. |
| `profiles/arm-oci.env` | Host-specific example: Ubuntu on OCI, WARP forces `TAILSCALE_NETDEV=enp0s6`. Do not inherit for fresh hosts. |
| `config/defaults.env` | Fallback defaults beneath the profile. |
| `config/ssh.env` | Fallback `SSH_PORT` (default `60022`). |
| `config/authorized_keys` | Tracked SSH public-key allowlist. Used only to seed hosts without an existing `~/.ssh/authorized_keys`; existing host keys are never overwritten. |
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

`esp-mirror-sync.sh` is the one exception: a host-specific, Fedora-only tool for
mirroring a second ESP. It is **not** profile-driven and **not** wired into
`bootstrap.sh`; it keeps its own CLI and `config/esp-mirror-sync.env`, and is run
manually on the host that has the second ESP:

```bash
sudo ./scripts/modules/esp-mirror-sync.sh --dry-run
```

See `docs/esp-mirror-sync.md`.

Recommended order and platform behavior:

| Module | Fedora | Debian/Ubuntu | Notes |
| --- | --- | --- | --- |
| `base-packages.sh` | dnf, `procps-ng gcc gcc-c++ make` | apt, `procps build-essential` | Run first. |
| `ssh-hardening.sh` | SELinux `ssh_port_t`, firewalld, restart `sshd` | no SELinux, ufw rule, restart `ssh.socket` | Reads `SSH_PORT` from profile + `authorized_keys`. |
| `firewall.sh` | firewalld baseline | ufw default-deny, allow `SSH_PORT` then enable | Allows SSH before enabling to avoid lockout. |
| `fail2ban.sh` | `fail2ban-firewalld`, firewalld action | `banaction = ufw` | Optional (`INSTALL_FAIL2BAN`, default on). sshd jail on `SSH_PORT`; ignores tailnet. |
| `homebrew.sh` | Linuxbrew as target user | same | After base packages. |
| `brew-bundle.sh` | `Brewfile` | same | After Homebrew. |
| `chezmoi.sh` | dnf `chezmoi` if missing | official installer / Homebrew | Applies `CHEZMOI_REPO`. |
| `zsh.sh` | sets login shell | same | After dotfiles. |
| `bubblewrap.sh` | dnf `bubblewrap` | apt + AppArmor `bwrap-userns-restrict` | Verifies `bwrap`. Codex sandbox dep. |
| `developer-tools.sh` | official installers | same | Claude Code + Codex into `~/.local`. |
| `tailscale.sh` | official installer + `ethtool` | same | Optional (`INSTALL_TAILSCALE`). Installs but leaves node unauthenticated. |
| `podman-quadlet.sh` | dnf `podman` + Quadlet | apt `podman` + Quadlet | Optional (`INSTALL_PODMAN_QUADLET`). Toolchain only; deploys no workload. |
| `router-sysctl.sh` | sysctl (bbr/fq/...) | same | Optional (`APPLY_ROUTER_SYSCTL`). |

## Tailscale exit node

`INSTALL_TAILSCALE=yes` installs tailscale + `ethtool` and, via
`setup-tailscale-exit-node.sh`, the OS-level networking an exit node needs: IP
forwarding sysctl + a UDP GRO optimization service (interface from
`TAILSCALE_NETDEV`, empty = auto-detect). It also opens **inbound UDP 41641**
(Tailscale's default port) so peers can establish direct connections / punch
through NAT instead of relaying via DERP. On `ufw` this is a global
`allow 41641/udp`; on `firewalld` the rule is added to the zone bound to
`TAILSCALE_NETDEV` (falling back to the default zone), since the physical NIC is
not always in the default zone. To apply just that networking:

```bash
sudo ./scripts/setup-tailscale-exit-node.sh <profile>
```

The kit **only installs services** — it never touches Tailscale account state.
Registration and advertising are a manual step (`tailscale up`), e.g.:

```bash
sudo tailscale up --advertise-exit-node
```

Then approve the exit node in the Tailscale admin console (Machines → this host →
route settings → enable "Use as exit node").

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

## Conventions

Durable design rules for anyone extending the kit:

- **Declarative.** A profile is a host's single source of truth; scripts converge
  and verify, they don't hard-code configurable values.
- **Uniform CLI.** Every script is `<profile> [--dry-run]`. `esp-mirror-sync.sh`
  is the one deliberate exception (host-specific, Fedora-only, its own CLI).
- **dry-run == apply.** All actions go through `run` / `run_eval` / `write_file`,
  so what dry-run prints is exactly what apply executes.
- **Idempotent and non-destructive.** Re-running converges to the profile;
  existing `~/.ssh/authorized_keys` is never overwritten.
- **Platform differences live in `lib/os.sh`.** Host-specific values go in a host
  profile, never in the generic baseline.
- **Homebrew is a baseline, not a toggle.** Every host installs Homebrew and the
  `Brewfile`; there is deliberately no `INSTALL_HOMEBREW` switch. Only genuinely
  optional capabilities (Tailscale / Podman / router sysctl / fail2ban) are
  per-host toggles; the CLI baseline is not.
- **Ubuntu networking assumes `systemd-networkd`.** On Debian/Ubuntu hosts the
  kit treats `systemd-networkd` as a precondition rather than managing or
  choosing the network stack itself.

## References

- Homebrew on Linux: https://docs.brew.sh/Homebrew-on-Linux
- Homebrew Bundle: https://docs.brew.sh/Brew-Bundle-and-Brewfile
- Claude Code install: https://code.claude.com/docs/en/setup
- Codex CLI: https://github.com/openai/codex
- Tailscale performance: https://tailscale.com/docs/reference/best-practices/performance
- Tailscale exit node: https://tailscale.com/docs/features/exit-nodes/how-to/setup
