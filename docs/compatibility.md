# Compatibility contract

[English overview](../README.md) · [Обзор на русском](../README.ru.md)

Version 0.1.0 intentionally supports one existing integration. Installing it on an unrelated Mihomo service can make service controls misleading, so the installer rejects recognizable mismatches instead of configuring the network itself.

## Runtime assumptions

| Component | Required behavior |
| --- | --- |
| Architecture | Linux ARM64. The core updater downloads `mihomo-linux-arm64-VERSION.gz`. |
| Service | `/etc/init.d/mihomo`, procd, UCI `mihomo.main`. |
| UCI paths | `conffile=/etc/mihomo/config.yaml`, `workdir=/etc/mihomo`, `user=root`. |
| Safe runner | `/usr/libexec/mihomo-safe-run`: starts the core, checks readiness before interception, removes its own routing rules when stopped or failed. |
| Network scope | Main LAN interception only; router DNS must remain usable without Mihomo. LTE and other policy routes are managed separately. |
| TProxy | `/etc/mihomo/tproxy.nft`, dedicated `inet mihomo_tproxy_safe`, fwmark `0x1/0x1`, priority `100`, table `100`, local default route via `lo`. |
| Controller | `192.168.1.1:9090`, password in the root `secret` field. |
| Local proxy | `127.0.0.1:7890`; TProxy listener `7893`. |
| Dashboard | Existing `ui` directory in `/etc/mihomo`. This repository does not bundle MetaCubeXD. |

The wrapper and TProxy rules are **prerequisites**, not payload files. Review and adapt them separately before using this app on another installation. The installer checks paths, markers and config shape; it is not a formal proof of service or firewall semantics.

## Guarded YAML

These are integration settings, not a complete working proxy configuration:

```yaml
mixed-port: 7890
tproxy-port: 7893
ipv6: false
external-controller: 192.168.1.1:9090
external-ui: ui
# Set a real private value locally. Do not commit it.
secret: replace_with_a_private_value
tun:
  enable: false
dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
```

The `secret` must use 16–128 letters, digits, `_` or `-`, without quotes. The guard accepts plain lower-case root keys and two-space direct children of `tun` / `dns`; it rejects duplicate guarded keys, root merges, tabs and additional TUN options. It allows indentationless lists in `proxies`, `proxy-groups` and `rules`.

This conservative check runs **before** the actual Mihomo YAML validation. It is not a general YAML parser. Valid YAML using a different spelling may be rejected; adapt the contract and tests rather than bypassing it.

## Requirements that remain the operator's responsibility

- WAN connectivity, DNS, certificates, subscription validity and provider health.
- LAN-only access to the controller and LuCI. Do not expose them to WAN merely to make the dashboard accessible.
- Firewall reload handling in the existing service integration.
- IPv6 routing and interception; this version's reference deployment uses IPv4.
- Availability of sites used by the readiness probe. The current wrapper/app probe uses YouTube's `generate_204`; diagnostics also use gstatic and `example.com`.
- An independent path to the router when experimenting with connectivity.

The UI can verify requests originating on the router. It cannot establish that every phone, console, app or policy is working.
