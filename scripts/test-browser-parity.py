#!/usr/bin/env python3
"""Run pinned-source browser regression suites on macOS, with bounded waits."""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', default='browser-parity-evidence')
args = parser.parse_args()
swift = shutil.which('swift')
if sys.platform != 'darwin' or not swift:
    raise SystemExit('macOS with Swift/WebKit is required; no tests were executed')
output = ROOT / args.output
output.mkdir(parents=True, exist_ok=True)
results = []
for test in sorted((ROOT / 'scripts/browser').glob('*.swift')):
    start = time.monotonic()
    try:
        result = subprocess.run([swift, str(test)], cwd=ROOT, text=True,
                                encoding='utf-8', errors='replace',
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=180)
        status, log = result.returncode, result.stdout
    except subprocess.TimeoutExpired as error:
        status, log = 124, (error.stdout or b'')
        if isinstance(log, bytes):
            log = log.decode('utf-8', errors='replace')
        log += '\nTEST TIMED OUT after 180 seconds\n'
    (output / (test.stem + '.log')).write_text(log, encoding='utf-8')
    print(log, flush=True)
    results.append({'test': test.name, 'exitCode': status,
                    'seconds': round(time.monotonic() - start, 3)})
    (output / 'result.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
raise SystemExit(0 if all(r['exitCode'] == 0 for r in results) else 1)
