#!/usr/bin/env bash
set -euo pipefail
native_app="$RUNNER_TEMP/ZeNativeLayoutHarness.app"
native_evidence="native-layout-evidence"
native_stub="$RUNNER_TEMP/NativeLayoutCacheBoundary.swift"
mkdir -p "$native_app" "$native_evidence"
cat > "$native_stub" <<'SWIFT'
import UIKit
@MainActor enum SelectableMarkdownView {
    static func clearVisualizationCaches() {}
}
SWIFT
python3 - "$native_evidence/native-layout-sources.json" <<'PY'
import hashlib,json,pathlib,sys
files=['Agent/Visualization/VisualizationDocument.swift','Views/Chat/Visualization/VisualizationAttachment.swift','scripts/NativeVisualizationLayoutHarness.swift']
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    'sources': {name:hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() for name in files},
    'scope':'Complete unmodified production model and UIKit drawing compiled for iOS 16; cache callback stub only; no system share UI.'
},indent=2),encoding='utf-8')
PY
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Agent/Visualization/VisualizationDocument.swift \
  Views/Chat/Visualization/VisualizationAttachment.swift \
  "$native_stub" scripts/NativeVisualizationLayoutHarness.swift \
  -o "$native_app/ZeNativeLayoutHarness" 2>&1 | tee "$native_evidence/native-layout-build.log"
cat > "$native_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.native-layout-harness</string>
<key>CFBundleExecutable</key><string>ZeNativeLayoutHarness</string>
<key>CFBundleName</key><string>ZeNativeLayoutHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$native_app"
native_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$native_device" || true
xcrun simctl bootstatus "$native_device" -b
xcrun simctl install "$native_device" "$native_app"
native_container=$(xcrun simctl get_app_container "$native_device" com.ze.native-layout-harness data)
collect_native_layout() {
  cp "$native_container/Documents/"native-layout-* "$native_evidence/" 2>/dev/null || true
  xcrun simctl terminate "$native_device" com.ze.native-layout-harness >/dev/null 2>&1 || true
}
trap collect_native_layout EXIT
rm -f "$native_container/Documents/native-layout-result.json"
xcrun simctl launch "$native_device" com.ze.native-layout-harness -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
for native_attempt in $(seq 1 45); do
  if [ -f "$native_container/Documents/native-layout-result.json" ]; then break; fi
  sleep 1
done
collect_native_layout
trap - EXIT
python3 - "$native_evidence" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
result=json.loads((root/'native-layout-result.json').read_text())
result['sourceManifest']=json.loads((root/'native-layout-sources.json').read_text())
(root/'native-layout-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in result.items() if k!='geometry'},ensure_ascii=False,indent=2))
assert result['success'],result
assert len(result['checks'])==10,result
assert len(result['screenshots'])==2,result
for name in result['screenshots']:
    assert (root/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),name
PY
