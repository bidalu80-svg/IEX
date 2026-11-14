#!/usr/bin/env bash
set -euo pipefail
header_work="$RUNNER_TEMP/ze-soul-header"
header_app="$header_work/SoulHeaderHarness.app"
mkdir -p "$header_app" soul-header-evidence
python3 scripts/prepare-soul-header.py "$header_work"
cp "$header_work/sources.json" soul-header-evidence/
xcodebuild -version > soul-header-evidence/toolchain.txt
xcrun actool "$header_work/Assets.xcassets" --compile "$header_app" --platform iphonesimulator --minimum-deployment-target 26.0 --target-device iphone --output-partial-info-plist "$header_work/assets.plist" > soul-header-evidence/assets.log 2>&1
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios26.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$header_work/Header.swift" -o "$header_app/SoulHeaderHarness"
python3 - "$header_app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.ze.soul-header-harness',CFBundleExecutable='SoulHeaderHarness',CFBundleName='SoulHeaderHarness',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='26.0',UIDeviceFamily=[1],UILaunchScreen={},CFBundleDevelopmentRegion='zh-Hans'),f)
PY
codesign --force --sign - "$header_app"
header_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS-26" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$header_device" || true
xcrun simctl bootstatus "$header_device" -b
xcrun simctl install "$header_device" "$header_app"
xcodebuild build-for-testing -project "$header_work/driver/ShareDriver.xcodeproj" -scheme ShareDriver -destination "platform=iOS Simulator,id=$header_device" -derivedDataPath "$header_work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=YES > soul-header-evidence/build.log 2>&1
python3 - "$header_work" "$header_app" <<'PY'
import pathlib,plistlib,sys
work=pathlib.Path(sys.argv[1]); products=work/'DerivedData/Build/Products'
xs=list(products.glob('*.xctestrun')); assert len(xs)==1,xs
d=plistlib.loads(xs[0].read_bytes())
targets=[t for c in d.get('TestConfigurations',[]) for t in c['TestTargets']] if 'TestConfigurations' in d else [v for k,v in d.items() if not k.startswith('__')]
assert len(targets)==1
for t in targets:
    t['UITargetAppPath']=sys.argv[2]
    t['UITargetAppBundleIdentifier']='com.ze.soul-header-harness'
(products/'SoulHeader.xctestrun').write_bytes(plistlib.dumps(d))
PY
xcrun simctl io "$header_device" recordVideo --codec=h264 --force "$PWD/soul-header-evidence/header.mp4" > soul-header-evidence/recording.log 2>&1 &
header_recorder=$!
trap 'kill -INT "$header_recorder" 2>/dev/null || true' EXIT
set +e
xcodebuild test-without-building -xctestrun "$header_work/DerivedData/Build/Products/SoulHeader.xctestrun" -destination "platform=iOS Simulator,id=$header_device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -disable-concurrent-destination-testing -resultBundlePath soul-header-evidence/SoulHeader.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 180 > soul-header-evidence/test.log 2>&1
header_result=$?
kill -INT "$header_recorder" 2>/dev/null || true
wait "$header_recorder" || true
trap - EXIT
set -e
cat soul-header-evidence/test.log
xcrun xcresulttool export attachments --path soul-header-evidence/SoulHeader.xcresult --output-path soul-header-evidence/screenshots || true
exit "$header_result"
