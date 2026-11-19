#!/usr/bin/env python3
"""Reject a partial, mixed or stale matrix recording before publishing a full artifact."""
import json
from pathlib import Path
import sys


def check(directory):
    root = Path(__file__).resolve().parents[1]
    targets = json.loads((root / 'scripts/aot-targets.json').read_text())
    directory = Path(directory)
    names = {t['id'] for t in targets['images']}
    for suffix in ('S', 'o'):
        found = {p.stem.removeprefix('aot_') for p in directory.glob(f'aot_*.{suffix}') if p.stat().st_size}
        if found != names:
            raise ValueError(f'{suffix}: missing {names - found}, unexpected {found - names}')
    for target in targets['images']:
        ledger = directory / f"RECORDED-{target['id']}.json"
        if json.loads(ledger.read_text()) != target:
            raise ValueError(f"mixed recording identity: {target['id']}")
    if json.loads((directory / 'TARGETS.json').read_text()) != targets:
        raise ValueError('target declarations changed during recording')
    versions = {f"{t['package']}-{t['version']}" for t in targets['images']}
    if set((directory / 'VERSIONS.txt').read_text().splitlines()) != versions:
        raise ValueError('package provenance does not match the exact target set')
    print(f"Complete {len(names)}-image artifact and identity ledgers verified (native code still requires runtime validation)")


if __name__ == '__main__':
    try:
        check(sys.argv[1])
    except (OSError, ValueError, IndexError) as error:
        sys.exit(str(error))
