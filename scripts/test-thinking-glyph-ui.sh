#!/usr/bin/env bash
set -euo pipefail
thinking_app="$RUNNER_TEMP/ZeThinkingGlyphHarness.app"
thinking_source="$RUNNER_TEMP/ThinkingGlyphProduction.swift"
mkdir -p "$thinking_app" thinking-glyph-evidence
python3 scripts/extract-thinking-glyph.py "$thinking_source"
cp "${thinking_source%.swift}.sources.json" thinking-glyph-evidence/
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  "$thinking_source" -o "$thinking_app/ZeThinkingGlyphHarness"
cat > "$thinking_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.thinking-glyph-harness</string>
<key>CFBundleExecutable</key><string>ZeThinkingGlyphHarness</string>
<key>CFBundleName</key><string>ZeThinkingGlyphHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$thinking_app"
thinking_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$thinking_device" || true
xcrun simctl bootstatus "$thinking_device" -b
xcrun simctl install "$thinking_device" "$thinking_app"
thinking_container=$(xcrun simctl get_app_container "$thinking_device" com.ze.thinking-glyph-harness data)
collect_thinking() {
  cp "$thinking_container/Documents/"thinking-glyph-* thinking-glyph-evidence/ 2>/dev/null || true
  xcrun simctl terminate "$thinking_device" com.ze.thinking-glyph-harness >/dev/null 2>&1 || true
}
trap collect_thinking EXIT
rm -f "$thinking_container/Documents/thinking-glyph-result.json"
xcrun simctl launch "$thinking_device" com.ze.thinking-glyph-harness
for thinking_attempt in $(seq 1 30); do
  if [ -f "$thinking_container/Documents/thinking-glyph-result.json" ]; then break; fi
  sleep 1
done
collect_thinking
python3 - <<'PY'
import json,pathlib
root=pathlib.Path('thinking-glyph-evidence')
result=json.loads((root/'thinking-glyph-result.json').read_text())
print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['success'],result
assert len(result['screenshots'])==2,result
for name in result['screenshots']:
    assert (root/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),name
PY
