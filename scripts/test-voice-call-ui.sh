#!/usr/bin/env bash
set -euo pipefail
voice_work="$RUNNER_TEMP/ze-voice-call-ui"
voice_app="$voice_work/VoiceCallHarness.app"
mkdir -p "$voice_app" voice-call-ui-evidence
python3 scripts/prepare-voice-call-ui.py "$voice_work"
cp "$voice_work/sources.json" voice-call-ui-evidence/
xcrun actool "$voice_work/Assets.xcassets" --compile "$voice_app" --platform iphonesimulator --minimum-deployment-target 16.0 --target-device iphone --output-partial-info-plist "$voice_work/assets.plist"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$voice_work/VoiceCallUI.swift" -o "$voice_app/VoiceCallHarness"
python3 - "$voice_app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.ze.voice-call-harness',CFBundleExecutable='VoiceCallHarness',CFBundleName='VoiceCallHarness',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='16.0',UIDeviceFamily=[1],UILaunchScreen={},CFBundleDevelopmentRegion='zh-Hans'),f)
PY
codesign --force --sign - "$voice_app"
voice_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$voice_device" || true
xcrun simctl bootstatus "$voice_device" -b
xcrun simctl install "$voice_device" "$voice_app"
xcodebuild build-for-testing -project "$voice_work/driver/ShareDriver.xcodeproj" -scheme ShareDriver -destination "platform=iOS Simulator,id=$voice_device" -derivedDataPath "$voice_work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=YES > voice-call-ui-evidence/build.log 2>&1
python3 - "$voice_work" "$voice_app" <<'PY'
import pathlib,plistlib,sys
work=pathlib.Path(sys.argv[1]); products=work/'DerivedData/Build/Products'
xs=list(products.glob('*.xctestrun')); assert len(xs)==1,xs
d=plistlib.loads(xs[0].read_bytes())
targets=[t for c in d.get('TestConfigurations',[]) for t in c['TestTargets']] if 'TestConfigurations' in d else [v for k,v in d.items() if not k.startswith('__')]
assert len(targets)==1
for t in targets:
    t['UITargetAppPath']=sys.argv[2]
    t['UITargetAppBundleIdentifier']='com.ze.voice-call-harness'
(products/'VoiceCall.xctestrun').write_bytes(plistlib.dumps(d))
PY
set +e
xcodebuild test-without-building -xctestrun "$voice_work/DerivedData/Build/Products/VoiceCall.xctestrun" -destination "platform=iOS Simulator,id=$voice_device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -disable-concurrent-destination-testing -resultBundlePath voice-call-ui-evidence/VoiceCall.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 180 > voice-call-ui-evidence/test.log 2>&1
voice_result=$?
set -e
cat voice-call-ui-evidence/test.log
xcrun xcresulttool export attachments --path voice-call-ui-evidence/VoiceCall.xcresult --output-path voice-call-ui-evidence/screenshots || true
exit "$voice_result"
