#!/usr/bin/env bash
set -euo pipefail
keyboard_work="$RUNNER_TEMP/ze-keyboard-viewport"
keyboard_app="$keyboard_work/KeyboardHarness.app"
mkdir -p "$keyboard_app" keyboard-viewport-evidence
python3 scripts/prepare-keyboard-viewport.py "$keyboard_work"
cp "$keyboard_work/sources.json" keyboard-viewport-evidence/
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$keyboard_work/KeyboardViewport.swift" -o "$keyboard_app/KeyboardHarness"
python3 - "$keyboard_app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.ze.keyboard-harness',CFBundleExecutable='KeyboardHarness',CFBundleName='KeyboardHarness',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='16.0',UIDeviceFamily=[1],UILaunchScreen={},CFBundleDevelopmentRegion='zh-Hans'),f)
PY
codesign --force --sign - "$keyboard_app"
keyboard_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$keyboard_device" || true
xcrun simctl bootstatus "$keyboard_device" -b
xcrun simctl install "$keyboard_device" "$keyboard_app"
xcodebuild build-for-testing -project "$keyboard_work/driver/ShareDriver.xcodeproj" -scheme ShareDriver -destination "platform=iOS Simulator,id=$keyboard_device" -derivedDataPath "$keyboard_work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=YES > keyboard-viewport-evidence/build.log 2>&1
python3 - "$keyboard_work" "$keyboard_app" <<'PY'
import pathlib,plistlib,sys
work=pathlib.Path(sys.argv[1]); products=work/'DerivedData/Build/Products'
xs=list(products.glob('*.xctestrun')); assert len(xs)==1,xs
d=plistlib.loads(xs[0].read_bytes())
targets=[t for c in d.get('TestConfigurations',[]) for t in c['TestTargets']] if 'TestConfigurations' in d else [v for k,v in d.items() if not k.startswith('__')]
assert len(targets)==1
for t in targets:
    t['UITargetAppPath']=sys.argv[2]
    t['UITargetAppBundleIdentifier']='com.ze.keyboard-harness'
(products/'Keyboard.xctestrun').write_bytes(plistlib.dumps(d))
PY
xcrun simctl io "$keyboard_device" recordVideo --codec=h264 --force "$PWD/keyboard-viewport-evidence/keyboard.mp4" > keyboard-viewport-evidence/recording.log 2>&1 &
keyboard_recorder=$!
trap 'kill -INT "$keyboard_recorder" 2>/dev/null || true' EXIT
set +e
xcodebuild test-without-building -xctestrun "$keyboard_work/DerivedData/Build/Products/Keyboard.xctestrun" -destination "platform=iOS Simulator,id=$keyboard_device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -disable-concurrent-destination-testing -resultBundlePath keyboard-viewport-evidence/Keyboard.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 180 > keyboard-viewport-evidence/test.log 2>&1
keyboard_result=$?
kill -INT "$keyboard_recorder" 2>/dev/null || true
wait "$keyboard_recorder" || true
trap - EXIT
set -e
cat keyboard-viewport-evidence/test.log
xcrun xcresulttool export attachments --path keyboard-viewport-evidence/Keyboard.xcresult --output-path keyboard-viewport-evidence/screenshots || true
keyboard_data=$(xcrun simctl get_app_container "$keyboard_device" com.ze.keyboard-harness data)
if [ -f "$keyboard_data/Documents/keyboard-motion.json" ]; then
  cp "$keyboard_data/Documents/keyboard-motion.json" keyboard-viewport-evidence/
fi
exit "$keyboard_result"
