#!/bin/bash
set -euo pipefail
APP="$RUNNER_TEMP/ZeFavoritesHarness.app"
mkdir -p "$APP"
xcrun swiftc -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Views/Chat/Media/MediaFavoriteControls.swift scripts/FavoritesUIHarness.swift \
  -o "$APP/ZeFavoritesHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.favorites-harness</string>
<key>CFBundleExecutable</key><string>ZeFavoritesHarness</string>
<key>CFBundleName</key><string>ZeFavoritesHarness</string>
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
trap 'xcrun simctl terminate "$DEVICE" com.ze.favorites-harness >/dev/null 2>&1 || true' EXIT
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.ze.favorites-harness
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.favorites-harness data)
for attempt in $(seq 1 60); do
  if [ -f "$CONTAINER/Documents/favorites-ui-result.json" ]; then break; fi
  sleep 2
done
mkdir -p favorites-ui-evidence
cp "$CONTAINER/Documents/favorites-ui-result.json" favorites-ui-evidence/
python3 -c 'import json; d=json.load(open("favorites-ui-evidence/favorites-ui-result.json")); print(json.dumps(d,indent=2)); assert d["success"],d'
cp "$CONTAINER/Documents/"*.png favorites-ui-evidence/
