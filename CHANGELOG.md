# Changelog

## Router changes after 0.2.0

- Serve LAN clients through a separate dnsmasq on port 1056. Local names use the system resolver. External A queries normally receive fake IPs and Mihomo routes connections under the existing service rules.
- Use the fixed `🌐 Web Stable` selector for ordinary encrypted DNS, `Whoer.net` for its domain policy and direct HTTPS for direct lookups and proxy-server bootstrap.
- Check client fake-IP answers and system DNS separately. Service startup now checks the controller and TProxy table. Config application and DNS activation retain their proxy probes.

## 0.2.0 — 2026-11-05

- Add an opt-in DNS protection tab, explicit HTTPS resolver/VPN-group selection and scoped diagnostics.
- Generate protected redir-host DNS with encrypted direct VPN-server bootstrap and verify all group/provider branches against direct exits.
- Add a separate fail-closed DNS firewall guard and watcher; preserve local dnsmasq records, LTE and monitoring without DHCP/Wi-Fi reloads.
- Integrate config/core transitions, emergency direct mode, cold boot intent and installer removal/recovery.
- Add isolated DNS state and worker-rollback tests; document browser DoH, IPv6 and bootstrap boundaries.

## 0.1.2 — 2026-11-04

- Fix core-update storage checks on compressed flash: retain the existing core with hard links when supported, stage writes in bounded batches and measure actual free space after write-back.
- Preserve a flash reserve during staging; stop/restart the service only after preparation and hash checks succeed. Partial writes and low-space failures leave the active service untouched.
- Replace redundant old-core RAM copies with an already retained rollback inode; check actual available RAM and gzip extraction size before allocation.
- Keep the previous persistent backup until the new core passes readiness. Extend isolated failure tests for storage exhaustion and the copy fallback.

## 0.1.1 — 2026-11-04

- Use explicit installer conditionals compatible with both the local ShellCheck version and Ubuntu's CI version. Runtime checks and rollback behavior are unchanged.

## 0.1.0 — 2026-11-04

Initial public source release.

- LuCI control page, guarded YAML editor, manual stable ARM64 core updates and diagnostics.
- Separate core, TProxy and autostart controls; direct-internet action.
- Restricted ucode RPC, serialized background jobs, config/core backups and recovery paths.
- English shell installer with preflight, fixed payload hashes, snapshots, rollback, uninstall and recovery.
- Russian and English documentation, compatibility contract, contributor/security guidance and host-side CI.

Reference integration: OpenWrt 25.12.2 on Linux ARM64 with the existing `mihomo-safe-run` deployment. Prebuilt APK/IPK packages are not part of this release.
