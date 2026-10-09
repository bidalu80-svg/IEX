#!/bin/bash
set -euo pipefail
APP="$RUNNER_TEMP/ZeMailWebHarness.app"
mkdir -p "$APP"
xcrun swiftc -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Shared/Mail/MailModels.swift Shared/Mail/MailWebSession.swift Shared/Mail/MailWebScripts.swift \
  Views/Settings/MailWebViews.swift scripts/MailWebHarness.swift -o "$APP/ZeMailWebHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.mail-web-harness</string>
<key>CFBundleExecutable</key><string>ZeMailWebHarness</string>
<key>CFBundleName</key><string>ZeMailWebHarness</string>
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
trap 'xcrun simctl terminate "$DEVICE" com.ze.mail-web-harness >/dev/null 2>&1 || true' EXIT
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" com.ze.mail-web-harness
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.mail-web-harness data)
for attempt in $(seq 1 90); do
  if [ -f "$CONTAINER/Documents/mail-web-result.json" ]; then break; fi
  sleep 2
done
mkdir -p mail-web-evidence
cp "$CONTAINER/Documents/"*.png mail-web-evidence/ || true
cp "$CONTAINER/Documents/mail-web-result.json" mail-web-evidence/
python3 -c 'import json; d=json.load(open("mail-web-evidence/mail-web-result.json")); print(json.dumps(d,ensure_ascii=False,indent=2)); assert d["success"],d'
