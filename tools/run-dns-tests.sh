#!/bin/sh
# Isolated filesystem and mocked system boundaries. No production DNS changes.
# shellcheck disable=SC2029
set -eu
umask 077
BASE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
[ "$#" = 1 ] || { echo 'Usage: sh tools/run-dns-tests.sh SSH_HOST' >&2; exit 2; }
host=$1
case "$host" in ''|-*|*[!A-Za-z0-9_.@:-]*) echo 'Invalid SSH host' >&2; exit 2 ;; esac
stage=$(mktemp -d)
remote=''
cleanup() {
    code=$?
    trap - EXIT HUP INT TERM
    [ -z "$remote" ] || ssh "$host" "rm -rf '$remote'" || :
    rm -rf "$stage"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
remote=$(ssh "$host" 'umask 077; mktemp -d /tmp/mihomo-mini-dns-tests.XXXXXX')
suffix=${remote#/tmp/mihomo-mini-dns-tests.}
case "$suffix" in ''|*[!A-Za-z0-9]*) remote=''; exit 1 ;; esac
python3 "$BASE/tools/prepare-dns-tests.py" --out "$stage/payload" --remote "$remote"
tar -C "$stage/payload" -cf "$stage/payload.tar" .
ssh "$host" "tar -xf - -C '$remote'; ucode -L '$remote/modules' '$remote/dns.uc'" < "$stage/payload.tar"
