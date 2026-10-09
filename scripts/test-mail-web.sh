#!/bin/bash
set -euo pipefail
APP="$RUNNER_TEMP/ZeMailWebHarness.app"
mkdir -p "$APP"
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios16.0-simulator" \
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
otool -L "$APP/ZeMailWebHarness"
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(x["udid"] for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
trap 'xcrun simctl terminate "$DEVICE" com.ze.mail-web-harness >/dev/null 2>&1 || true' EXIT
# Xcode 16.4 + older iOS simulator runtimes can keep libswiftWebKit in
# the runtime Cryptex while the SDK links /usr/lib/swift. Set a simulator-only
# fallback, never change the production app or disable a runtime test.
RUNTIME_ID=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); device=sys.argv[1]; print(next(r for r,ds in d["devices"].items() if any(x["udid"]==device for x in ds)))' "$DEVICE")
RUNTIME_BUNDLE=$(xcrun simctl list runtimes --json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(next(r.get("bundlePath", "") for r in d["runtimes"] if r["identifier"]==sys.argv[1]))' "$RUNTIME_ID")
for directory in "$RUNTIME_BUNDLE/Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift" "$RUNTIME_BUNDLE/Contents/Resources/RuntimeRoot/usr/lib/swift"; do
  if [ -f "$directory/libswiftWebKit.dylib" ]; then
    export SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH="$directory:/usr/lib/swift"
    echo "WebKit runtime fallback: $directory"
    break
  fi
done
xcrun simctl install "$DEVICE" "$APP"
for attempt in 1 2 3; do
  if xcrun simctl launch --terminate-running-process "$DEVICE" com.ze.mail-web-harness; then break; fi
  sleep 3
  if [ "$attempt" = 3 ]; then
    mkdir -p mail-web-evidence
    xcrun simctl spawn "$DEVICE" log show --last 2m --predicate 'process == "ZeMailWebHarness" OR eventMessage CONTAINS "Library not loaded"' > mail-web-evidence/launch-diagnostics.log || true
    find "$HOME/Library/Logs/DiagnosticReports" -name '*MailWebHarness*' -exec cp '{}' mail-web-evidence/ \; || true
    cat mail-web-evidence/launch-diagnostics.log
    exit 1
  fi
done
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.mail-web-harness data)
for attempt in $(seq 1 90); do
  if [ -f "$CONTAINER/Documents/mail-web-result.json" ]; then break; fi
  sleep 2
done
mkdir -p mail-web-evidence
cp "$CONTAINER/Documents/"*.png mail-web-evidence/ || true
cp "$CONTAINER/Documents/mail-web-result.json" mail-web-evidence/
python3 -c 'import json; d=json.load(open("mail-web-evidence/mail-web-result.json")); print(json.dumps(d,ensure_ascii=False,indent=2)); assert d["success"],d'
