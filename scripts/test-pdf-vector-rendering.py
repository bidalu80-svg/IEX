#!/usr/bin/env python3
"""Compile extracted production PDF drawing in a tiny real UIKit simulator app."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', default='pdf-vector-evidence')
parser.add_argument('--extract-only', action='store_true')
args = parser.parse_args()
output = (ROOT / args.output).resolve()
output.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'Views/Chat/SessionExport/ChatExportRenderer.swift').read_text(encoding='utf-8')
start = source.index('    private func drawVector(')
end = source.index('    /// DEBUG aid:', start)
methods = source[start:end].replace('    private func drawVector(', '    func drawVector(', 1)
fixture = (ROOT / 'scripts/PDFVectorRenderingChecks.swift').read_text(encoding='utf-8')
generated = 'import UIKit\nimport PDFKit\nimport CoreText\n@MainActor final class ProductionRenderer {\n' + methods + '}\n' + fixture
swift_file = output / 'PDFVectorHarness.swift'
swift_file.write_text(generated, encoding='utf-8')
(output / 'source.json').write_text(json.dumps({'rendererSHA256': hashlib.sha256(source.encode()).hexdigest(),
    'extractedMethodsSHA256': hashlib.sha256(methods.encode()).hexdigest()}, indent=2), encoding='utf-8')
if args.extract_only:
    print(swift_file)
    raise SystemExit(0)
if sys.platform != 'darwin':
    raise SystemExit('Real UIKit/PDFKit checks require macOS and an iOS simulator; no runtime checks executed')

def run(command, timeout=180):
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, encoding='utf-8', errors='replace', timeout=timeout)
    print(completed.stdout, end='', flush=True)
    with (output / 'commands.log').open('a', encoding='utf-8') as log:
        log.write(' '.join(map(str, command)) + '\n' + completed.stdout + '\n')
    completed.check_returncode()
    return completed.stdout.strip()

sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
architecture = run(['uname', '-m'])
app = output / 'PDFVectorHarness.app'
app.mkdir(exist_ok=True)
bundle = 'com.ze.pdf-vector-harness'
(app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle,
    'CFBundleExecutable': 'PDFVectorHarness', 'CFBundleName': 'PDFVectorHarness',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '16.0',
    'LSRequiresIPhoneOS': True, 'UILaunchScreen': {}}))
run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-sdk', sdk,
     '-target', architecture + '-apple-ios16.0-simulator', str(swift_file),
     '-o', str(app / 'PDFVectorHarness')])
run(['codesign', '--force', '--sign', '-', str(app)])
devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json']))
candidates = [d for runtime, ds in devices['devices'].items() if 'iOS' in runtime
              for d in ds if d['name'].startswith('iPhone')]
device = next((d for d in candidates if d['state'] == 'Booted'), candidates[0])['udid']
subprocess.run(['xcrun', 'simctl', 'boot', device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run(['xcrun', 'simctl', 'bootstatus', device, '-b'])
run(['xcrun', 'simctl', 'install', device, str(app)])
container = pathlib.Path(run(['xcrun', 'simctl', 'get_app_container', device, bundle, 'data']))
result_dir = container / 'Documents/pdf-vector-harness'
marker = result_dir / 'result.json'
marker.unlink(missing_ok=True)
subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
run(['xcrun', 'simctl', 'launch', device, bundle])
for attempt in range(60):
    if marker.exists():
        break
    time.sleep(1)
if result_dir.exists():
    shutil.copytree(result_dir, output / 'runtime', dirs_exist_ok=True)
run(['xcrun', 'simctl', 'terminate', device, bundle])
assert marker.exists(), 'UIKit application did not write PDFKit evidence within 60 seconds'
result = json.loads(marker.read_text())
print(json.dumps(result, ensure_ascii=False, indent=2))
assert result['success'], result
