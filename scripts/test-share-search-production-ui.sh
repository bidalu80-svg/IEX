#!/bin/bash
set -euo pipefail

# Bound simulator boot, compile and capture together, including hung children.
if [ "${ZE_SHARE_SEARCH_PRODUCTION_CHILD:-}" != "1" ]; then
  exec python3 - "$0" <<'PY'
import json, os, pathlib, signal, subprocess, sys
evidence = pathlib.Path('share-search-production-evidence')
evidence.mkdir(exist_ok=True)
child = subprocess.Popen(['bash', sys.argv[1]], env={**os.environ, 'ZE_SHARE_SEARCH_PRODUCTION_CHILD': '1'}, start_new_session=True)
try:
    code = child.wait(timeout=175)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
    (evidence / 'production-ui-result.json').write_text(json.dumps({'success': False, 'error': 'UI harness exceeded 175 seconds'}))
    code = 124
if code and not (evidence / 'production-ui-result.json').exists():
    (evidence / 'production-ui-result.json').write_text(json.dumps({'success': False, 'error': 'Harness setup or compile failed; see workflow log', 'exitCode': code}))
sys.exit(code)
PY
fi

APP="$RUNNER_TEMP/ZeShareSearchProductionHarness.app"
GENERATED="$RUNNER_TEMP/ShareSearchProductionViews.swift"
mkdir -p "$APP" share-search-production-evidence
python3 scripts/extract-share-search-production.py "$GENERATED" "$APP" share-search-production-evidence
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  "$GENERATED" -o "$APP/ZeShareSearchProductionHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.share-search-production-harness</string>
<key>CFBundleExecutable</key><string>ZeShareSearchProductionHarness</string>
<key>CFBundleName</key><string>ZeShareSearchProductionHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); candidates=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in candidates if x["state"]=="Booted"), candidates[0]["udid"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
CONTAINER=""
collect() {
  if [ -n "$CONTAINER" ]; then
    cp "$CONTAINER/Documents/"*.png share-search-production-evidence/ 2>/dev/null || true
    cp "$CONTAINER/Documents/production-ui-result.json" share-search-production-evidence/ 2>/dev/null || true
  fi
  xcrun simctl terminate "$DEVICE" com.ze.share-search-production-harness >/dev/null 2>&1 || true
}
trap collect EXIT
xcrun simctl install "$DEVICE" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.share-search-production-harness data)
# Remove evidence from an earlier run of this harness, never app/user data.
python3 - "$CONTAINER/Documents" <<'PY'
import pathlib, sys
for p in pathlib.Path(sys.argv[1]).glob('production-*'):
    if p.is_file() and p.suffix in ('.png', '.json'): p.unlink()
PY
xcrun simctl launch "$DEVICE" com.ze.share-search-production-harness -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
for attempt in $(seq 1 40); do
  if [ -f "$CONTAINER/Documents/production-ui-result.json" ]; then break; fi
  sleep 1
done
collect
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('share-search-production-evidence/production-ui-result.json')
assert p.is_file(), 'Simulator did not produce production-ui-result.json'
result = json.loads(p.read_text())
print(json.dumps(result, indent=2))
assert result['success'], result
assert len(result['screenshots']) == 20, result
for shot in result['screenshots']:
    image = p.parent / shot['file']
    assert image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), image
PY
