#!/usr/bin/env python3
"""Create DNS fixtures with no route to the real firewall, service or settings."""
import argparse
from pathlib import Path
import re
import shutil

BASE = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', type=Path, required=True)
p.add_argument('--remote', required=True)
a = p.parse_args()
assert re.fullmatch(r'/tmp/mihomo-mini-dns-tests\.[A-Za-z0-9]+', a.remote)
(a.out / 'modules').mkdir(parents=True, exist_ok=True)
s = (BASE / 'root/usr/share/ucode/mihomo-mini-dns.uc').read_text()
s = s.replace("'/etc/mihomo-mini'", repr(a.remote + '/store')).replace("'/tmp/mihomo-mini'", repr(a.remote + '/jobs')).replace("'/etc/mihomo/config.yaml'", repr(a.remote + '/config.yaml'))
start, end = s.index('export function command('), s.index('export function read(')
s = s[:start] + r'''export function command(args) {
    if (args[0] == '/etc/init.d/mihomo' && args[1] == 'enabled') return fs.access(TMP + '/autostart');
    if (args[0] == '/bin/sh' && args[1] == '-c' && index(args[2], 'nslookup -type=a example.org 127.0.0.1:1056 |') == 0)
        return !fs.access(TMP + '/client-down');
    if (args[0] != '/usr/sbin/nft') die('Unexpected test command');
    if (args[1] == '-c') return true;
    if (args[1] == '-f') {
        if (fs.access(TMP + '/fail-apply')) return false;
        if (index(fs.readfile(args[2]), 'table inet mihomo_mini_dns {') >= 0) fs.writefile(TMP + '/table', fs.readfile(args[2])); else fs.unlink(TMP + '/table');
        if (fs.access(TMP + '/race-emergency')) fs.writefile(TMP + '/emergency', '1');
        return true;
    }
    if (args[1] == 'delete') { fs.unlink(TMP + '/table'); return true; }
    die('Unexpected test nft command');
};
export function capture(cmd) {
    if (index(cmd, '/usr/sbin/nft -j -a') == 0) return {code:0, text:sprintf('%J',{nftables:[{rule:{comment:'mihomo-mini-dns-owned',handle:1}}]})};
    if (index(cmd, '/usr/sbin/nft') == 0) return {code: fs.access(TMP + '/table') ? 0 : 1, text: fs.readfile(TMP + '/table') || ''};
    if (index(cmd, 'awk ') == 0) return {code: fs.access(TMP + '/listener-down') ? 1 : 0, text:''};
    if (index(cmd, '/sbin/uci') == 0) return {code:0, text:'1'};
    die('Unexpected test capture');
};
''' + s[end:]
start, end = s.index('export function graph('), s.index('function verify_default(')
s = s[:start] + "export function graph() { return read(TMP + '/graph.json'); };\n" + s[end:]
(a.out / 'modules/mihomo-mini-dns.uc').write_text(s)
shutil.copy(BASE / 'root/usr/share/ucode/mihomo-mini-contract.uc', a.out / 'modules')
shutil.copy(BASE / 'tests/dns.uc', a.out)
shutil.copy(BASE / 'tests/fixtures/config.yaml', a.out / 'config.yaml')
