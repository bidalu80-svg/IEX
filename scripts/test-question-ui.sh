#!/bin/bash
set -euo pipefail

# Bound simulator boot, compile and capture together, including hung children.
if [ "${ZE_QUESTION_UI_CHILD:-}" != "1" ]; then
  exec python3 - "$0" <<'PY'
import json, os, pathlib, signal, subprocess, sys
evidence = pathlib.Path('question-ui-evidence')
evidence.mkdir(exist_ok=True)
child = subprocess.Popen(['bash', sys.argv[1]], env={**os.environ, 'ZE_QUESTION_UI_CHILD': '1'}, start_new_session=True)
try:
    code = child.wait(timeout=175)
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
    (evidence / 'question-ui-result.json').write_text(json.dumps({'success': False, 'error': 'UI harness exceeded 175 seconds'}))
    code = 124
if code and not (evidence / 'question-ui-result.json').exists():
    (evidence / 'question-ui-result.json').write_text(json.dumps({'success': False, 'error': 'Harness setup or compile failed; see workflow log', 'exitCode': code}))
sys.exit(code)
PY
fi

APP="$RUNNER_TEMP/ZeQuestionHarness.app"
GENERATED="$RUNNER_TEMP/QuestionUIProduction.swift"
mkdir -p "$APP" question-ui-evidence
python3 scripts/extract-question-ui.py "$GENERATED"
cp "$RUNNER_TEMP/QuestionUIProduction.sources.json" question-ui-evidence/
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  "$GENERATED" -o "$APP/ZeQuestionHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.question-harness</string>
<key>CFBundleExecutable</key><string>ZeQuestionHarness</string>
<key>CFBundleName</key><string>ZeQuestionHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
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
    cp "$CONTAINER/Documents/"*.png question-ui-evidence/ 2>/dev/null || true
    cp "$CONTAINER/Documents/question-ui-result.json" question-ui-evidence/ 2>/dev/null || true
  fi
  xcrun simctl terminate "$DEVICE" com.ze.question-harness >/dev/null 2>&1 || true
}
trap collect EXIT
xcrun simctl install "$DEVICE" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.question-harness data)
# Remove evidence from an earlier run of this harness, never app/user data.
python3 - "$CONTAINER/Documents" <<'PY'
import pathlib, sys
for p in pathlib.Path(sys.argv[1]).glob('question-*'):
    if p.is_file() and p.suffix in ('.png', '.json'): p.unlink()
PY
xcrun simctl launch "$DEVICE" com.ze.question-harness
for attempt in $(seq 1 40); do
  if [ -f "$CONTAINER/Documents/question-ui-result.json" ]; then break; fi
  sleep 1
done
collect
python3 - <<'PY'
import json, pathlib
p = pathlib.Path('question-ui-evidence/question-ui-result.json')
assert p.is_file(), 'Simulator did not produce question-ui-result.json'
result = json.loads(p.read_text())
print(json.dumps(result, indent=2))
assert result['success'], result
assert len(result['screenshots']) >= 6, result
for shot in result['screenshots']:
    image = p.parent / shot['file']
    assert image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), image
PY
