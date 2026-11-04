#!/usr/bin/env python3
"""Generate isolated ucode fixtures; never copy a live router's config."""
import argparse
from pathlib import Path
import re
import shutil

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
        ws = ws.replace('time() + 120', 'time() + 2')
        for filename in ('fake-command.uc', 'rollback.uc'):
            text = (PROJECT / 'tests' / filename).read_text().replace('/tmp/mihomo-mini-faults', remote)
            (dest / filename).write_text(text)
        core = dest / 'core'
        core.write_text('#!/bin/sh\n# OLD\necho "Mihomo Meta v9.0.0 linux arm64"\nexit 0\n')
        core.chmod(0o755)
    (dest / 'modules/mihomo-mini.uc').write_text(source)
    shutil.copy(PROJECT / 'root/usr/share/ucode/mihomo-mini-contract.uc', dest / 'modules')
    shutil.copy(PROJECT / 'tests/fixtures/config.yaml', dest / 'config.yaml')
    (dest / 'worker.uc').write_text(ws)
    wrapper = dest / 'worker'
    wrapper.write_text(f'#!/bin/sh\nexec /usr/bin/ucode -L {remote}/modules {remote}/worker.uc "$@"\n')
    wrapper.chmod(0o755)
shutil.copy(PROJECT / 'tests/backend.uc', args.out / 'basic/backend.uc')
print('Prepared synthetic backend and fault-injection fixtures.')
