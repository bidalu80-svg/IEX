#!/usr/bin/env bash
set -euo pipefail
chrome_phase="${1:-all}"
case "$chrome_phase" in all|prepare|verify) ;; *) exit 2 ;; esac
chrome_app="$RUNNER_TEMP/ZeProviderChromeHarness.app"
chrome_source="$RUNNER_TEMP/ProviderChromeProduction.swift"
chrome_catalog="$RUNNER_TEMP/ProviderChromeAssets.xcassets"
if [ "$chrome_phase" != verify ]; then
  mkdir -p "$chrome_app" provider-chrome-evidence
  python3 scripts/extract-provider-chat-chrome.py "$chrome_source" "$chrome_catalog"
  cp "${chrome_source%.swift}.sources.json" provider-chrome-evidence/
  cp -R "$RUNNER_TEMP/ProviderChromeLocalization/zh-Hans.lproj" "$chrome_app/"
  xcrun actool "$chrome_catalog" --compile "$chrome_app" --platform iphonesimulator --minimum-deployment-target 16.0 --target-device iphone --target-device ipad --output-partial-info-plist "$RUNNER_TEMP/provider-chrome-assets.plist"
  xcrun --sdk iphonesimulator swiftc -parse-as-library \
    -target "$(uname -m)-apple-ios16.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$chrome_source" -o "$chrome_app/ZeProviderChromeHarness"
  cat > "$chrome_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.provider-chrome-harness</string>
<key>CFBundleExecutable</key><string>ZeProviderChromeHarness</string>
<key>CFBundleName</key><string>ZeProviderChromeHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
</dict></plist>
PLIST
  codesign --force --sign - "$chrome_app"
  chrome_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
  xcrun simctl boot "$chrome_device" || true
  xcrun simctl bootstatus "$chrome_device" -b
  xcrun simctl install "$chrome_device" "$chrome_app"
  chrome_container=$(xcrun simctl get_app_container "$chrome_device" com.ze.provider-chrome-harness data)
  printf '%s\n' "$chrome_device" > "$RUNNER_TEMP/provider-chrome-device.txt"
  printf '%s\n' "$chrome_container" > "$RUNNER_TEMP/provider-chrome-container.txt"
  rm -f "$chrome_container/Documents/provider-chrome-result.json"
  xcrun simctl launch "$chrome_device" com.ze.provider-chrome-harness -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
fi
if [ "$chrome_phase" = prepare ]; then exit 0; fi
chrome_device=$(cat "$RUNNER_TEMP/provider-chrome-device.txt")
chrome_container=$(cat "$RUNNER_TEMP/provider-chrome-container.txt")
collect_chrome() {
  cp "$chrome_container/Documents/"provider-chrome-* provider-chrome-evidence/ 2>/dev/null || true
  xcrun simctl terminate "$chrome_device" com.ze.provider-chrome-harness >/dev/null 2>&1 || true
}
trap collect_chrome EXIT
for chrome_attempt in $(seq 1 90); do
  if [ -f "$chrome_container/Documents/provider-chrome-result.json" ]; then break; fi
  sleep 1
done
collect_chrome
trap - EXIT
python3 - <<'PY'
import json,pathlib
root=pathlib.Path('provider-chrome-evidence')
result=json.loads((root/'provider-chrome-result.json').read_text())
print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['success'], result
assert len(result['checks']) >= 20, result
assert len(result['screenshots']) >= 16, result
for name in result['screenshots']:
    assert (root/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), name
PY
