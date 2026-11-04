# Changelog

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
