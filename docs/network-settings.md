# Network Settings

## Tailscale Exit Node Forwarding

Tailscale exit nodes require Linux packet forwarding:

```conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
```

The setup script writes these values to:

```text
/etc/sysctl.d/99-tailscale-exit-node.conf
```

and applies them immediately with:

```bash
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl --system
```

The script also verifies both values are `1` before continuing.

## Tailscale UDP GRO Forwarding Optimization

Tailscale recommends this for Linux exit nodes and subnet routers on recent
kernels:

```bash
ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
```

The setup script detects `NETDEV` from the route to `8.8.8.8` and installs a
systemd oneshot service:

```text
/etc/systemd/system/tailscale-network-optimize.service
```

The service runs after the network is online and after `tailscaled` starts.
This is used instead of `networkd-dispatcher` because Fedora Server normally
uses NetworkManager.

## Settings From The Old Script Not Reused

These were intentionally left out:

- `net.core.default_qdisc=fq` and `net.ipv4.tcp_congestion_control=bbr`
  because this host currently reports only `reno cubic` as available congestion
  controls.
- `net.ipv6.conf.all.accept_ra=2` because it is only needed for specific IPv6
  router/RA setups and should not be set blindly.
- `net.ipv4.tcp_low_latency`, `net.ipv4.tcp_fastopen`, and
  `net.ipv4.tcp_fin_timeout` because they are not required for Tailscale exit
  node operation and can have workload-specific tradeoffs.
