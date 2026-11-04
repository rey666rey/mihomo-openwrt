# Installation, removal and recovery

[English](../README.md) · [Русский](../README.ru.md)

## Before installation

Use a complete checkout/archive. `install.sh`, `VERSION`, `install.files`, `SHA256SUMS`, `root/` and `htdocs/` must be present together. Run the installer as root on a compatible ARM64 OpenWrt device.

```sh
sh install.sh --check
```

This writes temporary check files in `/tmp`, compiles the application and checks the current integration. It does not install the app, create persistent backups, change UCI or reload rpcd. A successful check is a prerequisite, not a guarantee of internet connectivity.

Do not run the shell installer over package-managed application files. It refuses files owned by apk/opkg. A future packaged installation should be updated and removed through its package manager.

## Installation transaction

The installer accepts exactly the eight destinations in `install.files`. It rejects duplicate destinations, unsupported modes, symlinked payload/destination paths, unexpected paths, incomplete checksums, insufficient storage and incompatible service settings.

After confirmation, it takes an installer lock and the application's operation lock. The backup is stored at:

```text
/etc/mihomo-mini/install-backup-UTC-TIMESTAMP-PID/
```

It contains the previous application files, their hashes, the list of previously absent destinations, the prior managed-file manifest (if any) and protected-state hashes. It does not copy a router's private YAML into the repository or download the core.

New files are written next to their destination, checked, assigned root ownership and explicit modes, then renamed into place. The worker is `0755`; other payload files are `0644`. The store and staging directories are private.

rpcd is reloaded, rather than the network stack. Existing LuCI sessions may need a refresh or a new login. The app clears LuCI's cached menu when its page loads; a subsequent navigation can reveal the newly installed Services entry.

## Recovery

Errors and handled termination signals after mutation starts trigger a best-effort automatic rollback of **application files**. Protected networking, YAML, core and service settings are observed, never restored by the installer. If another operator changes them during installation, verification fails and leaves those external changes intact.

The installer keeps its backup and prints the exact path. To restore manually:

```sh
sh install.sh --restore /etc/mihomo-mini/install-backup-EXACT-NAME
```

Recovery accepts complete local backups under `/etc/mihomo-mini/`, verifies their hashes and uses the same fixed application destinations. It creates a new backup of the current app before restoring. A restore does not recover the Mihomo core or private config; those are separate application operations/backups.

An interrupted operation with a recorded, no-longer-running PID can have its lock reclaimed. A lock without a trustworthy owner is refused. Inspect it rather than deleting a possibly active operation's lock.

Power loss and `SIGKILL` cannot run shell traps. Per-file replacement prevents partial individual files, but a mix of old/new application files is possible. Use the retained complete backup with `--restore` after the device is stable. A backup without the `complete` marker is not accepted.

If recovery itself fails, stop retrying until storage/permissions are corrected. Keep the backup directory. Do not restore networking from an application snapshot; it does not contain a network transaction.

## Remove the application

```sh
sh install.sh --uninstall
```

Uninstall requires a managed-file manifest and unchanged installed hashes. Locally edited or missing files cause a refusal, so custom code is not silently deleted. The operation removes the eight application files and its managed manifest, reloads rpcd and preserves the Mihomo service, core, config and existing backups. It does not turn the proxy off.

Old installations made before this repository's managed installer may not have an ownership manifest. Install the reviewed matching source first to register the eight files, then uninstall if desired.

## Common problems

| Message / symptom | Action |
| --- | --- |
| Unsupported integration | Compare your service/config with [compatibility.md](compatibility.md). Do not bypass the check on a different proxy stack. |
| Missing command/module | Install the matching dependency from your firmware's official package feeds. Never mix kernel modules or feeds from a different firmware release. |
| SHA-256 mismatch | Download the full archive again from the expected repository/tag. Do not edit the manifest merely to silence an unexpected mismatch. |
| Another operation is active | Wait for the current UI task/installer. A known dead owner can be reclaimed on a later install. |
| LuCI menu missing | Open the direct app URL, then refresh/navigate again. Re-login if the old ACL/session cache persists. |
| RPC unavailable | Check `ubus -v list mihomo-mini` locally and rpcd's system log. The installer rolls back a failed activation. |
| Uninstall refuses modified files | Preserve your edits, compare them with the installed version, then deliberately reinstall or recover the matching files. |
| After sysupgrade | Manual files may need reinstallation. This installer does not add broad sysupgrade preservation rules or install itself as an apk/opkg package. |

## Russian notes / Коротко по-русски

- Начните с `sh install.sh --check`. Ошибку совместимости нужно разобраться и исправить, а не обходить.
- Установщик меняет только файлы LuCI/RPC и перечитывает rpcd. Ядро, конфиг и сетевые службы не устанавливает и не перезапускает.
- Для ручного восстановления используйте точный путь копии, который напечатал установщик: `sh install.sh --restore ПУТЬ`.
- Удаление интерфейса не останавливает Mihomo. Если нужен прямой интернет, сначала выберите соответствующее действие в самом приложении.
- При нехватке места или ошибке восстановления сохраните резервную копию и устраните причину, прежде чем повторять операцию.
