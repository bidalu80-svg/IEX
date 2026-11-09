#!/usr/bin/env bash
set -euo pipefail
thinking_phase="${1:-all}"
case "$thinking_phase" in
  all|prepare|verify) ;;
  *) echo "Expected all, prepare or verify" >&2; exit 2 ;;
esac
thinking_app="$RUNNER_TEMP/ZeThinkingGlyphHarness.app"
thinking_source="$RUNNER_TEMP/ThinkingGlyphProduction.swift"
if [ "$thinking_phase" != verify ]; then
mkdir -p "$thinking_app" thinking-glyph-evidence
python3 scripts/extract-thinking-glyph.py "$thinking_source"
cp "${thinking_source%.swift}.sources.json" thinking-glyph-evidence/
thinking_atlas="Assets.xcassets/ThinkingCubeAtlas.imageset/thinking-cube-atlas.png"
cp "$thinking_atlas" "$thinking_app/ThinkingCubeAtlas.png"
cp "$thinking_atlas" "$thinking_app/thinking-cube-atlas.png"
python3 - "$thinking_atlas" "${thinking_source%.swift}.sources.json" <<'PYATLAS'
import hashlib, json, pathlib, sys
atlas = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
sources = json.loads(manifest.read_text())
sources['atlas'] = str(atlas)
sources['atlasSHA256'] = hashlib.sha256(atlas.read_bytes()).hexdigest()
sources['harnessSHA256'] = hashlib.sha256(pathlib.Path('scripts/ThinkingGlyphUIHarness.swift').read_bytes()).hexdigest()
sources['resourceLoading'] = 'Real production PNG copied to the standalone app bundle under the asset name'
manifest.write_text(json.dumps(sources, indent=2))
pathlib.Path('thinking-glyph-evidence/ThinkingGlyphProduction.sources.json').write_text(json.dumps(sources, indent=2))
PYATLAS
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
echo "Preparing simulator: $(date -u +%FT%TZ)"
xcrun simctl boot "$thinking_device" || true
xcrun simctl bootstatus "$thinking_device" -b
echo "Installing animation harness: $(date -u +%FT%TZ)"
xcrun simctl install "$thinking_device" "$thinking_app"
echo "Installed animation harness: $(date -u +%FT%TZ)"
thinking_container=$(xcrun simctl get_app_container "$thinking_device" com.ze.thinking-glyph-harness data)
printf '%s\n' "$thinking_device" > "$RUNNER_TEMP/thinking-glyph-device.txt"
printf '%s\n' "$thinking_container" > "$RUNNER_TEMP/thinking-glyph-container.txt"
rm -f "$thinking_container/Documents/thinking-glyph-result.json"
echo "Launching animation harness: $(date -u +%FT%TZ)"
xcrun simctl launch "$thinking_device" com.ze.thinking-glyph-harness
echo "Animation harness launched: $(date -u +%FT%TZ)"
fi
if [ "$thinking_phase" = prepare ]; then exit 0; fi
thinking_device=$(cat "$RUNNER_TEMP/thinking-glyph-device.txt")
thinking_container=$(cat "$RUNNER_TEMP/thinking-glyph-container.txt")
collect_thinking() {
  cp -R "$thinking_container/Documents/"thinking-glyph-* thinking-glyph-evidence/ 2>/dev/null || true
  xcrun simctl terminate "$thinking_device" com.ze.thinking-glyph-harness >/dev/null 2>&1 || true
}
trap collect_thinking EXIT
for thinking_attempt in $(seq 1 90); do
  if [ -f "$thinking_container/Documents/thinking-glyph-result.json" ]; then break; fi
  sleep 1
done
collect_thinking
trap - EXIT
python3 - <<'PY'
import json,pathlib
root=pathlib.Path('thinking-glyph-evidence')
result=json.loads((root/'thinking-glyph-result.json').read_text())
summary={key:value for key,value in result.items()
         if key not in ('frameFiles','rowFrameFiles','rowSamples','motionFrameFiles')}
summary['exportCounts']={key:len(result.get(key,[]))
                         for key in ('frameFiles','rowFrameFiles','rowSamples','motionFrameFiles')}
print(json.dumps(summary,ensure_ascii=False,indent=2))
assert result['success'],result
assert len(result['checks'])>=18,result
assert len(result['screenshots'])==2,result
assert len(result['frameFiles'])==result['frameCount'],result
assert len(result['rowFrameFiles'])==113,result
assert len(result['rowSamples'])==110,result
assert result['motionFPS']==60,result
assert len(result['motionFrameFiles'])==900,result
for name in result['screenshots'] + result['frameFiles'] + result['rowFrameFiles'] + result['motionFrameFiles']:
    assert (root/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),name
PY
