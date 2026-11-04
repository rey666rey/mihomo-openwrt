#!/usr/bin/env python3
"""Check source metadata, relative documentation links and accidental secrets."""
import json
from pathlib import Path
import re

BASE = Path(__file__).resolve().parents[1]
for path in (BASE / 'root').rglob('*.json'):
    json.loads(path.read_text())
for path in BASE.rglob('*.md'):
    if '.git' in path.parts:
        continue
    for link in re.findall(r'\]\(([^\s)#]+)(?:#[^)]*)?\)', path.read_text()):
        if '://' in link or link.startswith(('mailto:', '#')):
            continue
        assert (path.parent / link).exists(), f'Broken link in {path.relative_to(BASE)}: {link}'
for folder in ('root', 'htdocs'):
    for path in (BASE / folder).rglob('*'):
        if not path.is_file():
            continue
        text = path.read_text()
        for pattern in (r'gh[pousr]_[A-Za-z0-9]{20,}', r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
                        r'/Users/[^/\s]+/', r'https?://[^\s"\']+\?(?:[^\s"\']*&)?token='):
            assert not re.search(pattern, text), f'Potential private data: {path.relative_to(BASE)}'
print('JSON, documentation links and application source checks passed.')
