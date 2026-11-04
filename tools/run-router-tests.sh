#!/bin/sh
# Run isolated tests in a private /tmp directory on an explicitly named router.
# Remote variables are intentionally expanded locally after strict validation.
# shellcheck disable=SC2029
set -eu
umask 077
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
[ "$#" -eq 1 ] || { echo 'Usage: sh tools/run-router-tests.sh SSH_HOST' >&2; exit 2; }
host=$1
case "$host" in ''|-*|*[!A-Za-z0-9_.@:-]*) echo 'Use a simple SSH host/alias.' >&2; exit 2 ;; esac
stage=$(mktemp -d)
remote=''
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    [ -z "$remote" ] || ssh "$host" "rm -rf '$remote'" || :
    rm -rf "$stage"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
remote=$(ssh "$host" 'umask 077; mktemp -d /tmp/mihomo-mini-public-tests.XXXXXX')
suffix=${remote#/tmp/mihomo-mini-public-tests.}
case "$suffix" in ''|*[!A-Za-z0-9]*) echo 'Unexpected remote staging path.' >&2; remote=''; exit 1 ;; esac
python3 "$BASE/tools/prepare-router-tests.py" --out "$stage/payload" --remote "$remote"
snapshot='set -e; sha256sum /etc/mihomo/config.yaml /etc/config/mihomo /usr/bin/mihomo /etc/config/network /etc/mihomo/tproxy.nft; ubus call service list '\''{"name":"mihomo"}'\'
ssh "$host" "$snapshot" > "$stage/before"
tar -C "$stage/payload" -cf "$stage/payload.tar" .
ssh "$host" "tar -xf - -C '$remote'" < "$stage/payload.tar"
ssh "$host" "set -e; ucode -L '$remote/basic/modules' '$remote/basic/backend.uc'; ucode -L '$remote/faults/modules' '$remote/faults/rollback.uc'"
ssh "$host" "$snapshot" > "$stage/after"
cmp "$stage/before" "$stage/after"
echo 'PASS: router core/config/network/service state unchanged; temporary fixtures removed on exit.'
