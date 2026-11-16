#!/usr/bin/env bash
set -euo pipefail
# Pool setup and execution under one deadline: #676 assets exceeded 60s,
# #674 setup through signing took 31s, simulator selection/boot took 128s,
# and runner installation inside test took 162.565s. The test stage's observed
# lower bound is 201.682141s; its 3x alone exceeds 510s. No per-stage 3x promise.
# Rule: 504s command pool + 6s termination reserve = 510s nominal.
# The largest single observed operation (162.565s runner install) fits ~3x
# inside the pool only when other stages are fast (3x = 487.695s).
# Inline filesystem/Python work and bounded log-tail printing have no timeout;
# 510s covers command execution and termination grace, not strict wall time.
voice_deadline=$((SECONDS + 504))
voice_run() {
    local stage="$1"
    shift
    local remaining=$((voice_deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
        echo "ERROR: voice UI budget exhausted before $stage" >&2
        return 124
    fi
    echo "[voice-ui] $stage (shared budget remaining ${remaining}s)"
    python3 scripts/run-bounded-command.py --timeout "$remaining" --log "voice-call-ui-evidence/$stage.log" -- "$@"
}
voice_work="$RUNNER_TEMP/ze-voice-call-ui"
voice_app="$voice_work/VoiceCallHarness.app"
mkdir -p "$voice_app" voice-call-ui-evidence
voice_run prepare python3 scripts/prepare-voice-call-ui.py "$voice_work"
cp "$voice_work/sources.json" voice-call-ui-evidence/
voice_run assets xcrun actool "$voice_work/Assets.xcassets" --compile "$voice_app" --platform iphonesimulator --minimum-deployment-target 16.0 --target-device iphone --output-partial-info-plist "$voice_work/assets.plist"
# Keep stdout separate from diagnostics, with xcrun still in the bounded tree.
voice_run sdk-path bash -c 'xcrun --sdk iphonesimulator --show-sdk-path > "$1"' _ "$voice_work/sdk-path.stdout"
voice_sdk=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).read_text().strip())' "$voice_work/sdk-path.stdout")
voice_run compile xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$voice_sdk" "$voice_work/VoiceCallUI.swift" -o "$voice_app/VoiceCallHarness"
python3 - "$voice_app/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.ze.voice-call-harness',CFBundleExecutable='VoiceCallHarness',CFBundleName='VoiceCallHarness',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='16.0',UIDeviceFamily=[1],UILaunchScreen={},CFBundleDevelopmentRegion='zh-Hans'),f)
PY
voice_run sign codesign --force --sign - "$voice_app"
# Build independently of live simulator startup. In #674, the selected iOS 26
# device spent minutes booting/installing before XCTest could start.
voice_run build xcodebuild build-for-testing -project "$voice_work/driver/ShareDriver.xcodeproj" -scheme ShareDriver -destination 'generic/platform=iOS Simulator' -derivedDataPath "$voice_work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)"
# Prefer the oldest installed runtime instead of depending on dictionary order.
# An explicitly requested major is mandatory; auto also works on iOS-26-only hosts.
voice_run select-device python3 scripts/select-voice-call-simulator.py "${ZE_SIMULATOR_IOS_MAJOR:-auto}"
voice_device=$(cat voice-call-ui-evidence/select-device.log)
voice_run device-state xcrun simctl list devices available --json
voice_state=$(python3 - "$voice_device" <<'PY_STATE'
import json,sys
with open('voice-call-ui-evidence/device-state.log') as f:
    devices=json.load(f)
print(next(x['state'] for ds in devices['devices'].values() for x in ds if x['udid']==sys.argv[1]))
PY_STATE
)
if [ "$voice_state" != Booted ]; then
    voice_run boot xcrun simctl boot "$voice_device"
fi
voice_run bootstatus xcrun simctl bootstatus "$voice_device" -b
voice_run install xcrun simctl install "$voice_device" "$voice_app"
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
voice_run test xcodebuild test-without-building -xctestrun "$voice_work/DerivedData/Build/Products/VoiceCall.xctestrun" -destination "platform=iOS Simulator,id=$voice_device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -disable-concurrent-destination-testing -resultBundlePath voice-call-ui-evidence/VoiceCall.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 180
voice_result=$?
set -e
# Diagnostics share the deadline too. Ordinary export failure remains best
# effort; exhaustion must never turn a successful test into a successful timeout.
set +e
voice_run export xcrun xcresulttool export attachments --path voice-call-ui-evidence/VoiceCall.xcresult --output-path voice-call-ui-evidence/screenshots
voice_export_result=$?
set -e
if [ "$voice_result" -eq 0 ] && [ "$voice_export_result" -eq 124 ]; then
    voice_result=124
fi
exit "$voice_result"
