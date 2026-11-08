#!/usr/bin/env python3
"""Generate isolated ucode fixtures; never copy a live router's config."""
import argparse
from pathlib import Path
import re
import shutil
import base64
import gzip
import hashlib
import json
import os

PROJECT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--remote', required=True)
args = parser.parse_args()
assert re.fullmatch(r'/tmp/mihomo-mini-public-tests\.[A-Za-z0-9]+', args.remote)
shared = (PROJECT / 'root/usr/share/ucode/mihomo-mini.uc').read_text()
worker = (PROJECT / 'root/usr/libexec/mihomo-mini-worker').read_text()

for name in ('basic', 'faults'):
    dest = args.out / name
    (dest / 'modules').mkdir(parents=True, exist_ok=True)
    remote = args.remote + '/' + name
    source = shared.replace("'/tmp/mihomo-mini'", repr(remote + '/jobs'))
    source = source.replace("'/etc/mihomo-mini'", repr(remote + '/store'))
    source = source.replace("'/etc/mihomo/config.yaml'", repr(remote + '/config.yaml'))
    source = source.replace("'/usr/libexec/mihomo-mini-worker'", repr(remote + '/worker'))
    ws = worker
    if name == 'faults':
        source = source.replace("'/usr/bin/mihomo'", repr(remote + '/core'))
        source = source.replace('system(args, timeout || 15000)',
                                "system(['/usr/bin/ucode', " + repr(remote + '/fake-command.uc') + ', ...args], timeout || 15000)')
        start = source.index('export function status()')
        end = source.index('export function enqueue(', start)
        source = source[:start] + """export function status() {
    return {running:true, tproxy:true, autostart:false, version:'v9.0.0', config_hash:hash_config()};
};
""" + source[end:]
        source = source.replace('export function capture(cmd) {', "export function capture(cmd) {\n\tif (index(cmd, 'nft list') == 0) return {code:0, text:''};")
        source = source.replace('export function capture(cmd) {', "export function capture(cmd) {\n"
            "\tif (index(cmd, 'df -Pk') == 0) {\n"
            "\t\tlet free = index(cmd, '/jobs/') >= 0 ? '100000' : (fs.readfile(" + repr(remote + '/free-kib') + ") || '100000');\n"
            "\t\treturn {code:0, text:'Filesystem 1K-blocks Used Available Use% Mounted\\nfixture 200000 1 ' + trim(free) + ' 1% /\\n'};\n\t}\n")
        ws = ws.replace('time() + 120', 'time() + 2')
        # Inject an I/O failure at the flash-write boundary; every target is
        # still in the private fixture directory, never the real core path.
        ws = ws.replace('function copy_flash(source, destination) {',
            'function copy_flash(source, destination) {\n'
            '\tif (fs.access(' + repr(remote + '/fail-copy') + ') && destination == m.CORE + ".mini-new") {\n'
            '\t\tfs.writefile(destination, "partial-write"); die("Injected flash write failure");\n\t}\n')
        for filename in ('fake-command.uc', 'rollback.uc'):
            text = (PROJECT / 'tests' / filename).read_text().replace('/tmp/mihomo-mini-faults', remote)
            (dest / filename).write_text(text)
        core = dest / 'core'
        core.write_text('#!/bin/sh\n# OLD\necho "Mihomo Meta v9.0.0 linux arm64"\nexit 0\n')
        core.chmod(0o755)
        # A valid shell stub with high-entropy comments keeps the compressed
        # fixture above the release parser's real 1 MiB asset-size floor.
        core_bytes = b'#!/bin/sh\n# NEW\necho "Mihomo Meta v9.0.1 linux arm64"\nexit 0\n#' + base64.b64encode(os.urandom(3500000)) + b'\n'
        archive = gzip.compress(core_bytes, mtime=0)
        (dest / 'fixture-core.gz').write_bytes(archive)
        (dest / 'fixture-release.json').write_text(json.dumps({
            'tag_name': 'v9.0.1', 'draft': False, 'prerelease': False,
            'assets': [{'name': 'mihomo-linux-arm64-v9.0.1.gz', 'size': len(archive),
                        'digest': 'sha256:' + hashlib.sha256(archive).hexdigest(),
                        'browser_download_url': 'https://github.com/MetaCubeX/mihomo/releases/download/v9.0.1/mihomo-linux-arm64-v9.0.1.gz'}]}))
    (dest / 'modules/mihomo-mini.uc').write_text(source)
    shutil.copy(PROJECT / 'root/usr/share/ucode/mihomo-mini-contract.uc', dest / 'modules')
    dns = (PROJECT / 'root/usr/share/ucode/mihomo-mini-dns.uc').read_text()
    dns = dns.replace("'/etc/mihomo-mini'", repr(remote + '/store')).replace("'/tmp/mihomo-mini'", repr(remote + '/jobs')).replace("'/etc/mihomo/config.yaml'", repr(remote + '/config.yaml'))
    # These fixtures never arm DNS. A separate suite exercises guard transitions.
    if name == 'faults':
        begin, end = dns.index('export function command('), dns.index('export function read(')
        dns = dns[:begin] + """export function command(args) {
    if (args[0] == '/bin/sh' && args[1] == '-c' && index(args[2], 'nslookup -type=a example.org 127.0.0.1:1056 |') == 0)
        return !fs.access(TMP + '/client-down');
    if (args[0] != '/usr/sbin/nft') die('DNS fixture refused command');
    if (args[1] == '-c') return true;
    if (args[1] == '-f') {
        if (fs.access(TMP + '/fail-dns-rules')) return false;
        if (index(fs.readfile(args[2]), 'table inet mihomo_mini_dns {') >= 0) fs.writefile(TMP + '/dns-table', fs.readfile(args[2])); else fs.unlink(TMP + '/dns-table'); return true;
    }
    if (args[1] == 'delete') { fs.unlink(TMP + '/dns-table'); return true; }
    die('DNS fixture refused nft command');
};
export function capture(cmd) {
    if (index(cmd, '/usr/sbin/nft -j -a') == 0) return {code:0, text:sprintf('%J',{nftables:[{rule:{comment:'mihomo-mini-dns-owned',handle:1}}]})};
    if (index(cmd, '/usr/sbin/nft') == 0) return { code:fs.access(TMP+'/dns-table') ? 0 : 1, text:fs.readfile(TMP+'/dns-table') || '' };
    if (index(cmd, 'awk ') == 0) return { code:0, text:'' };
    die('DNS fixture refused capture');
};
""" + dns[end:]
        begin, end = dns.index('export function graph('), dns.index('function verify_default(')
        dns = dns[:begin] + "export function graph() { return { '🌐 Web Stable':{ type:'Fallback', all:['A'] }, A:{ type:'VLESS' } }; };\n" + dns[end:]
        source = source.replace('export function capture(cmd) {', "export function capture(cmd) {\n\tif (index(cmd, 'nslookup ') == 0) return {code:0, text:''};")
        (dest / 'modules/mihomo-mini.uc').write_text(source)
    (dest / 'modules/mihomo-mini-dns.uc').write_text(dns)
    shutil.copy(PROJECT / 'tests/fixtures/config.yaml', dest / 'config.yaml')
    (dest / 'worker.uc').write_text(ws)
    wrapper = dest / 'worker'
    wrapper.write_text(f'#!/bin/sh\nexec /usr/bin/ucode -L {remote}/modules {remote}/worker.uc "$@"\n')
    wrapper.chmod(0o755)
shutil.copy(PROJECT / 'tests/backend.uc', args.out / 'basic/backend.uc')
print('Prepared synthetic backend and fault-injection fixtures.')
