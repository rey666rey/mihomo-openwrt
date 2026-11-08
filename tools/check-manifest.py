#!/usr/bin/env python3
"""Verify or regenerate the application payload checksums (no router access)."""
import argparse
import hashlib
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--write', action='store_true', help='regenerate SHA256SUMS')
args = parser.parse_args()
entries = []
for line in (BASE / 'install.files').read_text().splitlines():
    if not line.strip() or line.startswith('#'):
        continue
    mode, source, destination = line.split()
    assert mode in ('600', '644', '700', '755'), mode
    assert source.startswith(('root/', 'htdocs/')), source
    assert '..' not in Path(source).parts and not Path(source).is_absolute()
    assert not (BASE / source).is_symlink(), source
    entries.append(f'{hashlib.sha256((BASE / source).read_bytes()).hexdigest()}  {source}\n')
expected = ''.join(sorted(entries, key=lambda line: line.split()[1]))
if args.write:
    (BASE / 'SHA256SUMS').write_text(expected)
    print(f'Updated SHA256SUMS for {len(entries)} application files.')
else:
    assert (BASE / 'SHA256SUMS').read_text() == expected, 'Run python3 tools/check-manifest.py --write'
    print('Payload manifest and SHA256SUMS match.')
