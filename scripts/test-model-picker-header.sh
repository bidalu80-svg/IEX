#!/bin/bash
set -euo pipefail
picker_phase="${1:-all}"
case "$picker_phase" in all|prepare|verify) ;; *) echo "Expected all, prepare or verify" >&2; exit 2 ;; esac
APP="$RUNNER_TEMP/ZeModelPickerHarness.app"
if [ "$picker_phase" != verify ]; then
mkdir -p model-picker-evidence
python3 scripts/extract-provider-quota-detail.py "$RUNNER_TEMP/ProductionDetailQuota.swift"
cp "$RUNNER_TEMP/ProductionDetailQuota.sources.json" model-picker-evidence/
mkdir -p "$APP"
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Providers/ProviderAPIQuota.swift Providers/URLBuilding.swift Providers/WorkBuddy/WorkBuddyOAuthManager.swift \
  Providers/WorkBuddy/WorkBuddyBalanceAPI.swift Views/Providers/ModelPickerProviderHeader.swift \
  "$RUNNER_TEMP/ProductionDetailQuota.swift" scripts/ModelPickerHeaderHarness.swift \
  -o "$APP/ZeModelPickerHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.model-picker-harness</string>
<key>CFBundleExecutable</key><string>ZeModelPickerHarness</string>
<key>CFBundleName</key><string>ZeModelPickerHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["udid"] for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.model-picker-harness data)
printf '%s\n' "$DEVICE" > "$RUNNER_TEMP/model-picker-device.txt"
printf '%s\n' "$CONTAINER" > "$RUNNER_TEMP/model-picker-container.txt"
rm -f "$CONTAINER/Documents/model-picker-result.json"
xcrun simctl launch "$DEVICE" com.ze.model-picker-harness
fi
if [ "$picker_phase" = prepare ]; then exit 0; fi
DEVICE=$(cat "$RUNNER_TEMP/model-picker-device.txt")
CONTAINER=$(cat "$RUNNER_TEMP/model-picker-container.txt")
trap 'xcrun simctl terminate "$DEVICE" com.ze.model-picker-harness >/dev/null 2>&1 || true' EXIT
for attempt in $(seq 1 60); do
  if [ -f "$CONTAINER/Documents/model-picker-result.json" ]; then break; fi
  sleep 2
done
mkdir -p model-picker-evidence
cp "$CONTAINER/Documents/model-picker-result.json" model-picker-evidence/
python3 -c 'import json; d=json.load(open("model-picker-evidence/model-picker-result.json")); print(json.dumps(d,indent=2)); assert d["success"],d; assert len(d["workBuddyScreenshots"])==6,d'
cp "$CONTAINER/Documents/"*.png model-picker-evidence/
