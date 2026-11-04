#!/bin/sh
# Transactional installer for the LuCI application only. POSIX sh / BusyBox ash.
set -eu
umask 077

TARGET_ROOT=''
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
STORE="$TARGET_ROOT/etc/mihomo-mini"
APP_TMP="$TARGET_ROOT/tmp/mihomo-mini"
MODE=install
YES=0
RESTORE=''
STAGE=''
BACKUP=''
MUTATING=0
COMMITTED=0
SHARED_LOCK=0
STALE_SHARED=0
RED='' GREEN='' CYAN='' BOLD='' RESET=''
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
    RED=$(printf '\033[31m'); GREEN=$(printf '\033[32m')
    CYAN=$(printf '\033[36m'); BOLD=$(printf '\033[1m'); RESET=$(printf '\033[0m')
fi

say() { printf '%s\n' "$*"; }
ok() { printf '  %sOK%s  %s\n' "$GREEN" "$RESET" "$*"; }
fail() { printf '\n  %sERROR%s  %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
step() { printf '\n%s[%s/5] %s%s\n' "$CYAN" "$1" "$2" "$RESET"; }
usage() {
    cat <<'EOF'
Mihomo Mini installer

  sh install.sh                 Review and install/update the LuCI application
  sh install.sh --check         Run preflight checks without installing
  sh install.sh --yes           Install without the interactive confirmation
  sh install.sh --uninstall     Remove managed application files only
  sh install.sh --restore DIR   Restore application files from a local backup
  sh install.sh --help          Show this help

Options: --yes / -y may also accompany --uninstall or --restore.
NO_COLOR disables ANSI colors. Non-interactive changes require --yes.
The installer never downloads a core, starts Mihomo, or changes networking.
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes|-y) YES=1 ;;
        --check) [ "$MODE" = install ] || fail 'Choose one operation.'; MODE=check ;;
        --uninstall) [ "$MODE" = install ] || fail 'Choose one operation.'; MODE=uninstall ;;
        --restore)
            [ "$MODE" = install ] || fail 'Choose one operation.'
            [ "$#" -ge 2 ] || fail '--restore requires a backup directory.'
            MODE=restore; RESTORE=$2; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)." ;;
    esac
    shift
done

# No destination outside this list may be modified by the installer.
allowed() {
    case "$1" in
        usr/share/ucode/mihomo-mini.uc|usr/share/ucode/mihomo-mini-contract.uc|\
        usr/share/rpcd/ucode/mihomo-mini|usr/share/rpcd/acl.d/luci-app-mihomo-mini.json|\
        usr/share/luci/menu.d/luci-app-mihomo-mini.json|usr/libexec/mihomo-mini-worker|\
        www/luci-static/resources/view/mihomo-mini/overview.js|\
        www/luci-static/resources/view/mihomo-mini/style.css) return 0 ;;
        *) return 1 ;;
    esac
}
digest() { sha256sum "$1" | awk '{print $1}'; }
file_mode() {
    ucode -D "file_path=$1" -e 'import { stat } from "fs"; let s=stat(file_path); if (!s) exit(1); print(sprintf("%o", s.mode & 0o777));'
}
file_size() { wc -c < "$1" | tr -d ' '; }
lock_is_stale() {
    [ -f "$APP_TMP/lock/owner.json" ] || return 1
    stale_pid=$(jsonfilter -i "$APP_TMP/lock/owner.json" -e '@.pid' 2>/dev/null) || return 1
    case "$stale_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$stale_pid" -gt 1 ] || return 1
    ! kill -0 "$stale_pid" 2>/dev/null
}
no_symlinks() {
    ns_path=$1
    while [ "$ns_path" != / ] && [ -n "$ns_path" ] && [ "$ns_path" != . ]; do
        [ ! -L "$ns_path" ] || fail "Symlink in destination path: $ns_path"
        ns_path=$(dirname "$ns_path")
    done
}
protected_state() {
    for ps_file in etc/config/network etc/config/wireless etc/config/dhcp etc/config/firewall \
        etc/config/mihomo etc/init.d/mihomo etc/mihomo/config.yaml etc/mihomo/tproxy.nft \
        usr/libexec/mihomo-safe-run usr/bin/mihomo; do
        if [ -f "$TARGET_ROOT/$ps_file" ]; then sha256sum "$TARGET_ROOT/$ps_file"; fi
    done
    ubus call service list '{"name":"mihomo"}' > "$STAGE/service.json" || return 1
    # Ignore unrelated procd metadata; preserve running process IDs exactly.
    jsonfilter -i "$STAGE/service.json" -e '@.mihomo.instances.*.pid' || :
}
reload_rpc() {
    "$TARGET_ROOT/etc/init.d/rpcd" reload > "$STAGE/rpcd.log" 2>&1
}
install_one() {
    io_source=$1 io_target=$2 io_mode=$3
    mkdir -p "$(dirname "$io_target")"
    no_symlinks "$io_target"
    cp -p "$io_source" "$io_target.mihomo-mini-new.$$" || return 1
    chmod "$io_mode" "$io_target.mihomo-mini-new.$$" || return 1
    chown 0:0 "$io_target.mihomo-mini-new.$$" || return 1
    [ "$(digest "$io_source")" = "$(digest "$io_target.mihomo-mini-new.$$")" ] || return 1
    mv -f "$io_target.mihomo-mini-new.$$" "$io_target"
}
rollback() {
    say '  Restoring the previous application files...'
    rb_ok=1
    # Delete any partial staged writes before allocating space for recovery.
    while read -r rb_mode _rb_src rb_dst; do
        [ -n "$rb_mode" ] || continue
        rm -f "$TARGET_ROOT/$rb_dst.mihomo-mini-new.$$" || rb_ok=0
    done < "$STAGE/files"
    while read -r rb_dst; do
        [ -n "$rb_dst" ] || continue
        if [ -f "$BACKUP/files/$rb_dst" ]; then
            install_one "$BACKUP/files/$rb_dst" "$TARGET_ROOT/$rb_dst" \
                "$(file_mode "$BACKUP/files/$rb_dst")" || rb_ok=0
        else
            rm -f "$TARGET_ROOT/$rb_dst" || rb_ok=0
        fi
    done < "$BACKUP/changed"
    if [ -f "$BACKUP/installed.before" ]; then
        cp -p "$BACKUP/installed.before" "$STORE/app-installed.sha256" || rb_ok=0
    else
        rm -f "$STORE/app-installed.sha256" || rb_ok=0
    fi
    rm -f "$TARGET_ROOT"/tmp/luci-indexcache.*.json
    reload_rpc || rb_ok=0
    if [ "$rb_ok" = 1 ]; then
        say '  Previous application restored. Mihomo and network settings were not restored or changed.'
    else
        say "  Recovery needs attention. Keep this backup: $BACKUP" >&2
        say "  After fixing the error: sh install.sh --restore '$BACKUP' --yes" >&2
    fi
}
finish() {
    finish_code=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$MUTATING" = 1 ] && [ "$COMMITTED" = 0 ]; then rollback; fi
    if [ "$SHARED_LOCK" = 1 ]; then
        if [ "$COMMITTED" = 1 ]; then
            printf '%s\n' '{"state":"done","message":"Mihomo Mini installer finished. Refresh LuCI to load the installed version."}' > "$APP_TMP/job-installer/result.json"
        else
            printf '%s\n' '{"state":"error","message":"Mihomo Mini installer stopped. Check its terminal output and retained backup."}' > "$APP_TMP/job-installer/result.json"
        fi
        rm -f "$APP_TMP/lock/owner.json"
        rmdir "$APP_TMP/lock"
    fi
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    if [ "$finish_code" -ne 0 ] && [ -n "$BACKUP" ]; then say "  Backup retained: $BACKUP" >&2; fi
    exit "$finish_code"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

VERSION=$(cat "$BASE/VERSION" 2>/dev/null) || fail 'VERSION is missing. Use a complete source checkout.'
case "$VERSION" in ''|*[!0-9.]*) fail 'Invalid VERSION file.' ;; esac
printf '\n%s  MIHOMO MINI%s  /  LuCI\n' "$BOLD" "$RESET"
printf '  Version %s  |  Operation: %s\n' "$VERSION" "$MODE"
say '  Local installation. Your working network stays in place.'

step 1 'Preflight'
[ "$(id -u)" = 0 ] || fail 'Run this installer as root on the router.'
[ -f "$TARGET_ROOT/etc/openwrt_release" ] || fail 'This installer requires OpenWrt.'
for cmd in ucode ubus jsonfilter sha256sum awk sed sort cmp df mktemp cp mv chmod chown mkdir rm dirname flock date wc tr grep sleep uname; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command is missing: $cmd"
done
case "$(uname -m)" in aarch64|arm64) : ;; *) fail 'This version supports ARM64 routers only; its core updater targets Linux ARM64.' ;; esac
if [ ! -f "$BASE/install.files" ] || [ ! -f "$BASE/SHA256SUMS" ]; then
    fail 'Payload manifest or checksums are missing.'
fi
no_symlinks "$STORE"
no_symlinks "$APP_TMP"
STAGE=$(mktemp -d "$TARGET_ROOT/tmp/mihomo-mini-install.XXXXXX") || fail 'Cannot create a private staging directory.'
chmod 700 "$STAGE"
awk 'NF && $1 !~ /^#/ {print}' "$BASE/install.files" > "$STAGE/files"
[ "$(wc -l < "$STAGE/files" | tr -d ' ')" = 8 ] || fail 'Expected exactly eight application files.'
while read -r mode src dst extra; do
    [ -z "${extra:-}" ] || fail 'Malformed payload manifest.'
    case "$mode" in 644|755) : ;; *) fail 'Invalid payload permissions.' ;; esac
    allowed "$dst" || fail "Unexpected destination: $dst"
    if [ "$dst" = usr/libexec/mihomo-mini-worker ]; then
        [ "$mode" = 755 ] || fail 'The worker must be executable.'
    else [ "$mode" = 644 ] || fail 'Application data files must use mode 644.'; fi
    case "$src" in root/"$dst"|htdocs/"${dst#www/}") : ;; *) fail 'Source and destination do not match.' ;; esac
    if [ ! -f "$BASE/$src" ] || [ -L "$BASE/$src" ]; then fail "Payload file missing or symlinked: $src"; fi
    no_symlinks "$BASE/$src"
    no_symlinks "$TARGET_ROOT/$dst"
    [ ! -e "$TARGET_ROOT/$dst" ] || [ -f "$TARGET_ROOT/$dst" ] || fail "Destination is not a regular file: $dst"
done < "$STAGE/files"
awk '{print $3}' "$STAGE/files" | sort -u > "$STAGE/destinations"
[ "$(wc -l < "$STAGE/destinations" | tr -d ' ')" = 8 ] || fail 'Duplicate payload destinations.'
# Reconstruct the expected paths before allowing sha256sum to read the manifest.
awk '{print $2}' "$STAGE/files" | sort > "$STAGE/expected"
awk 'NF == 2 {print $2}' "$BASE/SHA256SUMS" | sort > "$STAGE/checksummed"
cmp -s "$STAGE/expected" "$STAGE/checksummed" || fail 'Checksums must cover exactly the payload manifest.'
(cd "$BASE" && sha256sum -c SHA256SUMS > "$STAGE/checksums.log" 2>&1) || fail 'Payload checksum mismatch. Download a fresh copy.'
ok 'Payload checksums and destination paths'

if [ "$MODE" = install ] || [ "$MODE" = check ]; then
    for required in usr/bin/mihomo usr/libexec/mihomo-safe-run etc/init.d/mihomo etc/init.d/rpcd; do
        [ -x "$TARGET_ROOT/$required" ] || fail "Required executable missing: /$required"
    done
    for required in etc/mihomo/config.yaml etc/mihomo/tproxy.nft etc/config/mihomo; do
        [ -s "$TARGET_ROOT/$required" ] || fail "Required integration file missing: /$required"
    done
    for cmd in curl nft ip setsid gzip nslookup uci sync; do
        command -v "$cmd" >/dev/null 2>&1 || fail "Required runtime command missing: $cmd"
    done
    if [ "$(uci -q get mihomo.main.conffile)" = /etc/mihomo/config.yaml ] \
        && [ "$(uci -q get mihomo.main.workdir)" = /etc/mihomo ] \
        && [ "$(uci -q get mihomo.main.user)" = root ]; then :
    else fail 'The Mihomo UCI service paths or user do not match the supported integration.'; fi
    if grep -Fq 'mihomo-safe-run' "$TARGET_ROOT/etc/init.d/mihomo" \
        && grep -Fq 'mihomo_tproxy_safe' "$TARGET_ROOT/usr/libexec/mihomo-safe-run" \
        && grep -Fq 'table inet mihomo_tproxy_safe' "$TARGET_ROOT/etc/mihomo/tproxy.nft"; then :
    else fail 'The safe-run service or TProxy table differs from the supported integration.'; fi
    ucode -L "$BASE/root/usr/share/ucode" -D "config_path=$TARGET_ROOT/etc/mihomo/config.yaml" -e '
        import { readfile } from "fs";
        import { sha256 } from "digest";
        import { connect } from "ubus";
        import { cursor } from "uci";
        import { contract } from "mihomo-mini-contract";
        let e = contract(readfile(config_path));
        if (e != null) exit(1);
    ' > "$STAGE/compatibility.log" 2>&1 || fail 'The existing config or ucode modules do not match the supported integration. See docs/compatibility.md.'
    for unit in root/usr/libexec/mihomo-mini-worker root/usr/share/rpcd/ucode/mihomo-mini; do
        ucode -L "$BASE/root/usr/share/ucode" -c -o "$STAGE/unit.ucb" "$BASE/$unit" \
            > "$STAGE/compile.log" 2>&1 || fail 'ucode compilation failed. Nothing was installed.'
    done
    ok 'Existing Mihomo integration and ucode compilation'
fi
if [ -e "$APP_TMP/lock" ]; then
    if lock_is_stale; then STALE_SHARED=1; ok 'An interrupted operation lock can be reclaimed during installation'
    else fail 'Another Mihomo operation is active. Wait for it to finish, then retry.'; fi
fi
if [ "$MODE" = uninstall ]; then
    [ -f "$STORE/app-installed.sha256" ] || fail 'No managed installation was found. No files will be removed.'
    (cd "$TARGET_ROOT/" && sha256sum -c "$STORE/app-installed.sha256" > "$STAGE/ownership.log" 2>&1) \
        || fail 'Managed files were modified or removed. Reinstall the matching version or restore them before uninstalling.'
fi
if [ "$MODE" = restore ]; then
    no_symlinks "$RESTORE"
    case "$RESTORE" in "$STORE"/install-backup-*) : ;; *) fail 'Restore requires a backup inside /etc/mihomo-mini.' ;; esac
    if [ ! -f "$RESTORE/complete" ] || [ ! -f "$RESTORE/absent" ] || [ ! -f "$RESTORE/original.sha256" ]; then
        fail 'Backup is incomplete. No files were changed.'
    fi
    (cd "$RESTORE/files" && sha256sum -c ../original.sha256 > "$STAGE/backup-check.log" 2>&1) \
        || { [ ! -s "$RESTORE/original.sha256" ] || fail 'Backup checksum mismatch.'; }
    while read -r mode src dst; do
        if [ -f "$RESTORE/files/$dst" ]; then no_symlinks "$RESTORE/files/$dst"
        else grep -Fqx "$dst" "$RESTORE/absent" || fail "Backup does not describe $dst"; fi
    done < "$STAGE/files"
    ok 'Backup contents and checksums'
fi
if [ "$MODE" = install ] || [ "$MODE" = check ]; then
    while read -r mode src dst; do
        [ -e "$TARGET_ROOT/$dst" ] || continue
        if command -v apk >/dev/null 2>&1 && apk info --who-owns "/$dst" >/dev/null 2>&1; then
            fail "A package owns /$dst. Update it through the package manager."
        fi
        if command -v opkg >/dev/null 2>&1 && [ -n "$(opkg search "/$dst" 2>/dev/null)" ]; then
            fail "A package owns /$dst. Update it through the package manager."
        fi
    done < "$STAGE/files"
fi
payload_bytes=0
while read -r mode src dst; do
    payload_bytes=$((payload_bytes + $(file_size "$BASE/$src")))
    [ ! -f "$TARGET_ROOT/$dst" ] || payload_bytes=$((payload_bytes + $(file_size "$TARGET_ROOT/$dst")))
done < "$STAGE/files"
space_path="$TARGET_ROOT/overlay"
[ -d "$space_path" ] || space_path="$TARGET_ROOT/"
free_kib=$(df -Pk "$space_path" | awk 'END {print $4}')
[ "$free_kib" -ge $((payload_bytes * 3 / 1024 + 2048)) ] || fail 'Not enough writable storage for installation and recovery.'
ok 'Writable storage headroom'
if [ "$MODE" = check ]; then
    say ''; say '  Preflight passed. No application files or services were changed.'; exit 0
fi

step 2 'Review'
say '  Scope: eight LuCI / RPC application files.'
say '  Kept: core binary, YAML config, service, TProxy, DNS, Wi-Fi, LTE and autostart.'
say '  Reloaded: rpcd only. LuCI may need a refresh or a new login.'
if [ "$YES" = 0 ]; then
    [ -t 0 ] || fail 'Non-interactive mode requires --yes after reviewing --check.'
    printf '  Continue with %s? [y/N] ' "$MODE"
    read -r answer
    case "$answer" in y|Y|yes|YES) : ;; *) say '  Cancelled. Nothing was changed.'; exit 0 ;; esac
fi
# Serialize installers and share the same exclusion lock as application jobs.
exec 9> "$TARGET_ROOT/tmp/mihomo-mini-installer.lock"
flock -n 9 || fail 'Another installer is already running.'
mkdir -p "$APP_TMP"
chmod 700 "$APP_TMP"
if [ "$STALE_SHARED" = 1 ] && lock_is_stale; then
    rm -f "$APP_TMP/lock/owner.json"
    rmdir "$APP_TMP/lock" || fail 'The stale lock contains unexpected files; inspect it manually.'
fi
mkdir "$APP_TMP/lock" || fail 'A Mihomo operation started during review. Retry when it finishes.'
SHARED_LOCK=1
mkdir -p "$APP_TMP/job-installer"
printf '{"id":"job-installer","pid":%s,"created":%s}\n' "$$" "$(date +%s)" > "$APP_TMP/lock/owner.json"
printf '%s\n' '{"state":"running","message":"Mihomo Mini installer is updating application files."}' > "$APP_TMP/job-installer/result.json"
protected_state > "$STAGE/protected.before" || fail 'Could not capture the current router state.'

step 3 'Backup'
mkdir -p "$STORE"
chmod 700 "$STORE"
BACKUP="$STORE/install-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$BACKUP/files"
: > "$BACKUP/absent"; : > "$BACKUP/original.sha256"; : > "$BACKUP/changed"
while read -r mode src dst; do
    if [ -f "$TARGET_ROOT/$dst" ]; then
        mkdir -p "$BACKUP/files/$(dirname "$dst")"
        cp -p "$TARGET_ROOT/$dst" "$BACKUP/files/$dst"
        printf '%s  %s\n' "$(digest "$BACKUP/files/$dst")" "$dst" >> "$BACKUP/original.sha256"
    else printf '%s\n' "$dst" >> "$BACKUP/absent"; fi
done < "$STAGE/files"
[ ! -f "$STORE/app-installed.sha256" ] || cp -p "$STORE/app-installed.sha256" "$BACKUP/installed.before"
cp "$STAGE/protected.before" "$BACKUP/protected.before"
printf '%s\n' "$VERSION" > "$BACKUP/version"
: > "$BACKUP/complete"
ok "Snapshot saved: $BACKUP"

step 4 'Apply'
MUTATING=1
while read -r mode src dst; do
    printf '%s\n' "$dst" >> "$BACKUP/changed"
    case "$MODE" in
        install) install_one "$BASE/$src" "$TARGET_ROOT/$dst" "$mode" ;;
        uninstall) rm -f "$TARGET_ROOT/$dst" ;;
        restore)
            if [ -f "$RESTORE/files/$dst" ]; then
                install_one "$RESTORE/files/$dst" "$TARGET_ROOT/$dst" "$(file_mode "$RESTORE/files/$dst")"
            else rm -f "$TARGET_ROOT/$dst"; fi ;;
    esac
done < "$STAGE/files"
if [ "$MODE" = install ]; then
    : > "$STAGE/installed.sha256"
    while read -r mode src dst; do printf '%s  %s\n' "$(digest "$TARGET_ROOT/$dst")" "$dst" >> "$STAGE/installed.sha256"; done < "$STAGE/files"
    install_one "$STAGE/installed.sha256" "$STORE/app-installed.sha256" 600
elif [ "$MODE" = restore ] && [ -f "$RESTORE/installed.before" ]; then
    install_one "$RESTORE/installed.before" "$STORE/app-installed.sha256" 600
else rm -f "$STORE/app-installed.sha256"; fi
ok 'Application files updated atomically, one file at a time'

step 5 'Verify'
rm -f "$TARGET_ROOT"/tmp/luci-indexcache.*.json
reload_rpc || fail 'rpcd reload failed. Rolling back the application.'
if [ "$MODE" = install ]; then
    ready=0
    for _attempt in 1 2 3 4 5; do
        if ubus call mihomo-mini status > "$STAGE/status.json" 2>/dev/null \
            && [ "$(jsonfilter -i "$STAGE/status.json" -e '@.ok')" = true ]; then ready=1; break; fi
        sleep 1
    done
    [ "$ready" = 1 ] || fail 'Application RPC did not become ready. Rolling back.'
    (cd "$TARGET_ROOT/" && sha256sum -c "$STORE/app-installed.sha256" > "$STAGE/installed-check.log" 2>&1) \
        || fail 'Installed file verification failed. Rolling back.'
fi
protected_state > "$STAGE/protected.after" || fail 'Could not verify the router state.'
cmp -s "$STAGE/protected.before" "$STAGE/protected.after" \
    || fail 'Protected router state changed during the operation. Rolling back application files only.'
printf '%s\n' "$MODE" > "$BACKUP/succeeded"
COMMITTED=1
ok 'Application verified; Mihomo process and protected router files preserved'
printf '\n  %sDONE%s  %s completed.\n' "$GREEN" "$RESET" "$MODE"
if [ "$MODE" = install ]; then
    say '  Open LuCI > Services > Mihomo.'
    say '  URL: /cgi-bin/luci/admin/services/mihomo-mini'
fi
say "  Recovery backup: $BACKUP"
say '  No Mihomo restart, core update or network reload was performed.'
