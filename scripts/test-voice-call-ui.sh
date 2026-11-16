#!/usr/bin/env bash
set -euo pipefail
# Leave time for bounded diagnostics before the workflow's ten-minute limit.
voice_deadline=$((SECONDS + 510))
voice_run() {
    local stage="$1" limit="$2"
    shift 2
    local remaining=$((voice_deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
        echo "ERROR: voice UI budget exhausted before $stage" >&2
        return 124
    fi
    if [ "$limit" -gt "$remaining" ]; then limit="$remaining"; fi
    echo "[voice-ui] $stage (budget ${limit}s)"
    python3 scripts/run-bounded-command.py --timeout "$limit" --log "voice-call-ui-evidence/$stage.log" -- "$@"
}
voice_work="$RUNNER_TEMP/ze-voice-call-ui"
voice_app="$voice_work/VoiceCallHarness.app"
mkdir -p "$voice_app" voice-call-ui-evidence
voice_run prepare 30 python3 scripts/prepare-voice-call-ui.py "$voice_work"
cp "$voice_work/sources.json" voice-call-ui-evidence/
voice_run assets 60 xcrun actool "$voice_work/Assets.xcassets" --compile "$voice_app" --platform iphonesimulator --minimum-deployment-target 16.0 --target-device iphone --output-partial-info-plist "$voice_work/assets.plist"
voice_run compile 90 xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$voice_work/VoiceCallUI.swift" -o "$voice_app/VoiceCallHarness"
python3 - "$voice_app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.ze.voice-call-harness',CFBundleExecutable='VoiceCallHarness',CFBundleName='VoiceCallHarness',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='16.0',UIDeviceFamily=[1],UILaunchScreen={},CFBundleDevelopmentRegion='zh-Hans'),f)
PY
voice_run sign 15 codesign --force --sign - "$voice_app"
# Build independently of live simulator startup. In #674, the selected iOS 26
# device spent minutes booting/installing before XCTest could start.
voice_run build 120 xcodebuild build-for-testing -project "$voice_work/driver/ShareDriver.xcodeproj" -scheme ShareDriver -destination 'generic/platform=iOS Simulator' -derivedDataPath "$voice_work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)"
# Prefer the oldest installed runtime instead of depending on dictionary order.
# An explicitly requested major is mandatory; auto also works on iOS-26-only hosts.
voice_run select-device 15 python3 scripts/select-voice-call-simulator.py "${ZE_SIMULATOR_IOS_MAJOR:-auto}"
voice_device=$(cat voice-call-ui-evidence/select-device.log)
voice_run device-state 15 xcrun simctl list devices available --json
voice_state=$(python3 - "$voice_device" <<'PY_STATE'
import json,sys
with open('voice-call-ui-evidence/device-state.log') as f:
    devices=json.load(f)
print(next(x['state'] for ds in devices['devices'].values() for x in ds if x['udid']==sys.argv[1]))
PY_STATE
)
if [ "$voice_state" != Booted ]; then
    voice_run boot 45 xcrun simctl boot "$voice_device"
fi
voice_run bootstatus 90 xcrun simctl bootstatus "$voice_device" -b
voice_run install 60 xcrun simctl install "$voice_device" "$voice_app"
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
voice_run test 240 xcodebuild test-without-building -xctestrun "$voice_work/DerivedData/Build/Products/VoiceCall.xctestrun" -destination "platform=iOS Simulator,id=$voice_device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -disable-concurrent-destination-testing -resultBundlePath voice-call-ui-evidence/VoiceCall.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 180
voice_result=$?
set -e
python3 scripts/run-bounded-command.py --timeout 30 --log voice-call-ui-evidence/export.log -- xcrun xcresulttool export attachments --path voice-call-ui-evidence/VoiceCall.xcresult --output-path voice-call-ui-evidence/screenshots || true
exit "$voice_result"
