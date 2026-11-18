#!/usr/bin/env python3
"""Record only exact OpenMinis guest identities; fail before producing false parity.

Requires the emitting Ze CLI and the pinned benchmark suite staged by
prepare-aot-workloads.sh. Output is isolated from the committed .o directory.
"""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
TARGETS = json.loads((REPO / 'scripts/aot-targets.json').read_text())


def guest_file(root, path):
    path = Path('/' + path.lstrip('/'))
    for _ in range(8):
        host = root / str(path).lstrip('/')
        if not host.is_symlink():
            return host
        target = os.readlink(host)
        path = Path(target) if target.startswith('/') else path.parent / target
    raise ValueError(f'symlink loop: {path}')


def build_id(path):
    data = path.read_bytes()
    if data[:6] != b'\x7fELF\x02\x01' or len(data) < 64:
        raise ValueError(f'not ELF64 LE: {path}')
    off = struct.unpack_from('<Q', data, 32)[0]
    stride, count = struct.unpack_from('<HH', data, 54)
    if stride < 56 or off + stride * count > len(data):
        raise ValueError(f'malformed program headers: {path}')
    for i in range(count):
        ph = off + stride * i
        if struct.unpack_from('<I', data, ph)[0] != 4:
            continue
        start = struct.unpack_from('<Q', data, ph + 8)[0]
        end = start + struct.unpack_from('<Q', data, ph + 32)[0]
        if end > len(data):
            raise ValueError(f'truncated note segment: {path}')
        while start + 12 <= end:
            names, descs, kind = struct.unpack_from('<III', data, start)
            name = start + 12
            desc = name + ((names + 3) & ~3)
            if desc + descs > end:
                raise ValueError(f'truncated note: {path}')
            if kind == 3 and data[name:name + names] == b'GNU\0':
                return data[desc:desc + descs].hex()
            start = desc + ((descs + 3) & ~3)
    return None


def run_guest(ish, root, command, **kwargs):
    env = kwargs.pop('env', dict(os.environ))
    env['ISH_JIT_PIC'] = '1'
    env.pop('ISH_NODE_MODE', None)  # Reference recording uses the default Node mode.
    return subprocess.run([str(ish), '-r', str(root), '/bin/sh', '-c', command],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, **kwargs)


def check_output(result, target, phase):
    text = result.stdout
    if result.returncode or 'FAIL' in text or any(marker not in text for marker in target['ok_markers']):
        raise ValueError(f"{target['id']} {phase} failed (exit {result.returncode}):\n{text[-6000:]}")


def preflight(ish, root):
    # Both existence and exact identity are checked for all 25 inputs, before
    # any recording starts. Package versions alone are insufficient evidence.
    specs = sorted({(t['package'], t['version']) for t in TARGETS['images']})
    for package, version in specs:
        result = run_guest(ish, root, f"apk info -e -v '{package}'", timeout=120)
        if result.returncode or f'{package}-{version}' not in result.stdout.splitlines():
            raise ValueError(f'exact package unavailable: {package}={version}: {result.stdout}')
    deps = run_guest(ish, root, 'apk info -e py3-requests git ripgrep', timeout=120)
    if deps.returncode:
        raise ValueError('training requires py3-requests, git and ripgrep')
    # Ze has no guest /proc/ish/jit. Get the actual emitting ABI from a tiny
    # raw recorder header, before spending hours on any training workload.
    with tempfile.TemporaryDirectory(prefix='ze-aot-abi-') as scratch:
        probe = Path(scratch) / 'abi.jsonl'
        env = dict(os.environ, ISH_JIT_RECORD=str(probe), ISH_JIT_RECORD_MOD='ld-musl')
        result = run_guest(ish, root, ':', env=env, timeout=120)
        if result.returncode or not probe.is_file():
            raise ValueError('could not read the emitting recorder ABI')
        with probe.open() as stream:
            header = json.loads(stream.readline()).get('header', {})
        if header.get('abi') != int(TARGETS['abi'], 16):
            raise ValueError(f"recorder ABI must be {TARGETS['abi']}: {header.get('abi')}")
    for t in TARGETS['images']:
        actual = build_id(guest_file(root, t['path']))
        if actual != t['build_id']:
            raise ValueError(f"{t['id']}: expected ELF {t['build_id']}, got {actual}")
        if not guest_file(root, t['workload']).is_file():
            raise ValueError(f"missing reference workload: {t['workload']}")
    return specs


def manifest():
    rows = {}
    for line in (REPO / 'scripts/aot-manifest.txt').read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        name, selector, workload, timeout = line.split('|')
        if name in rows or not workload.startswith('@'):
            raise ValueError(f'invalid/duplicate manifest entry: {name}')
        rows[name] = (selector, REPO / workload[1:], int(timeout))
    if set(rows) != {t['id'] for t in TARGETS['images']}:
        raise ValueError('effective manifest must contain exactly the 25 reference targets')
    for t in TARGETS['images']:
        selector, wrapper, _ = rows[t['id']]
        if selector != t['selector'] or not wrapper.is_file():
            raise ValueError(f"invalid selector/workload for {t['id']}")
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ish', type=Path, required=True)
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--out', type=Path, default=REPO / '.aot-new/recorded')
    p.add_argument('--check-only', action='store_true')
    p.add_argument('--only', choices=[t['id'] for t in TARGETS['images']])
    args = p.parse_args()
    ish, root = args.ish.resolve(), args.root.resolve()
    entries = manifest()
    specs = preflight(ish, root)
    if args.check_only:
        print('All 25 exact package/module identities and workload files checked')
        return
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if list(out.glob('*.S')) or list(out.glob('*.o')):
        raise ValueError(f'output must contain no old images: {out}')
    for t in TARGETS['images']:
        if args.only and t['id'] != args.only:
            continue
        _, wrapper, limit = entries[t['id']]
        staged = root / 'tmp' / f"wl-{t['id']}.sh"
        staged.write_bytes(wrapper.read_bytes())
        command = f"/bin/sh '/tmp/wl-{t['id']}.sh'"
        # OpenMinis dry-runs its three locally recorded workloads. Other
        # suite images run once under the recorder (Node can take hours).
        if t['ok_markers']:
            dry = run_guest(ish, root, command, timeout=limit)
            (out / f"{t['id']}.dry.log").write_text(dry.stdout)
            check_output(dry, t, 'dry run')
        rec = out / f"{t['id']}.jsonl"
        env = dict(os.environ, ISH_JIT_PIC='1', ISH_JIT_RECORD=str(rec), ISH_JIT_RECORD_MOD=t['selector'])
        result = run_guest(ish, root, command, env=env, timeout=limit)
        (out / f"{t['id']}.record.log").write_text(result.stdout)
        check_output(result, t, 'recording')
        sys.path.insert(0, str(REPO / 'Vendor/ZeNative/ish/tools/jit_aot'))
        from gen import load_recording
        header, records = load_recording(rec)
        translations = len(records)
        if translations < t['min_translations']:
            raise ValueError(f"{t['id']}: {translations} translations, floor {t['min_translations']}")
        if header.get('abi') != int(TARGETS['abi'], 16):
            raise ValueError(f"{t['id']}: recording ABI does not match {TARGETS['abi']}")
        modules = {r['mod'] for r in records}
        if modules != {t['path']}:
            raise ValueError(f"{t['id']}: expected only {t['path']}, recorded {modules}")
        subprocess.run([sys.executable, str(REPO / 'Vendor/ZeNative/ish/tools/jit_aot/gen.py'),
                        str(rec), str(ish), str(root), str(out / f"aot_{t['id']}.S"),
                        '--name', t['id']], check=True)
        print(f"{t['id']}: {translations} translations", flush=True)
        (out / f"RECORDED-{t['id']}.json").write_text(json.dumps(t, indent=2) + '\n')
    # This is the validated input package set. A per-module ledger prevents a
    # partial matrix artifact being mistaken for the complete recording set.
    (out / 'VERSIONS.txt').write_text(''.join(f'{p}-{v}\n' for p, v in specs))
    (out / 'TARGETS.json').write_text(json.dumps(TARGETS, indent=2) + '\n')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
