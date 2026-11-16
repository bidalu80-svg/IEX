#!/usr/bin/env bash
set -euo pipefail
layout_app="${ZE_SHARE_SEARCH_SIM_APP:?Build complete simulator app first}"
layout_work="$RUNNER_TEMP/chat-layout-driver"
layout_evidence="$PWD/chat-layout-evidence"
mkdir -p "$layout_work" "$layout_evidence"
layout_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$layout_app/Info.plist")
layout_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json,os; d=json.load(sys.stdin); major=os.environ.get("ZE_SIMULATOR_IOS_MAJOR","18"); xs=[x for r,ds in d["devices"].items() if ("iOS-"+major+"-") in r for x in ds if x["name"].startswith("iPhone")]; assert xs,"No available iPhone simulator for iOS "+major; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$layout_device" || true
xcrun simctl bootstatus "$layout_device" -b
xcrun simctl install "$layout_device" "$layout_app"
layout_container=$(xcrun simctl get_app_container "$layout_device" "$layout_bundle" data)
layout_fallback=$(python3 scripts/simulator-webkit-environment.py "$layout_device" --app "$layout_app" --output "$layout_evidence/webkit-runtime")
layout_recording_pid=""
if [ "${ZE_VERIFY_SOUL_HEADER:-0}" = 1 ]; then
    xcrun simctl io "$layout_device" recordVideo --codec=h264 "$layout_evidence/soul-avatar-full-app.mp4" > "$layout_evidence/recording.log" 2>&1 &
    layout_recording_pid=$!
fi
collect_layout() {
    # Preserve the real-tap trace before any simulator/video cleanup can stall.
    if [ -d "$layout_container/Documents/chat-verification" ]; then
        cp -R "$layout_container/Documents/chat-verification" "$layout_evidence/"
        if [ "${ZE_VERIFY_SOUL_HEADER:-0}" = 1 ]; then
            python3 scripts/check-soul-tap-evidence.py "$layout_container/Documents/chat-verification/avatar-tap-events.json" \
                > "$layout_evidence/avatar-tap-summary.json" || true
        fi
    fi
    if [ -n "$layout_recording_pid" ]; then
        kill -INT "$layout_recording_pid" 2>/dev/null || true
        wait "$layout_recording_pid" || true
    fi
    xcrun simctl io "$layout_device" screenshot "$layout_evidence/final-screen.png" || true
    mkdir -p "$layout_evidence/crashes"
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Ze*' -type f -exec cp {} "$layout_evidence/crashes/" \; 2>/dev/null || true
    xcrun xcresulttool export attachments --path "$layout_evidence/Layout.xcresult" --output-path "$layout_evidence/xcui-screenshots" || true
}
trap collect_layout EXIT
python3 - "$layout_work" <<'PY'
import importlib.util,pathlib,sys
sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('driver','scripts/share-xcui-driver.py')
driver=importlib.util.module_from_spec(spec);spec.loader.exec_module(driver)
driver.DRIVER=pathlib.Path('scripts/ChatLayoutApplicationUITests.swift').read_text()
driver.write_project(pathlib.Path(sys.argv[1]))
PY
xcodebuild build-for-testing -project "$layout_work/ShareDriver.xcodeproj" -scheme ShareDriver -destination "platform=iOS Simulator,id=$layout_device" -derivedDataPath "$layout_work/DerivedData" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= ONLY_ACTIVE_ARCH=YES > "$layout_evidence/driver-build.log" 2>&1
python3 - "$layout_work" "$layout_app" "$layout_bundle" "$layout_fallback" <<'PY'
import os,pathlib,plistlib,sys
work=pathlib.Path(sys.argv[1]);products=work/'DerivedData/Build/Products'
xs=list(products.glob('*.xctestrun'));assert len(xs)==1,xs
d=plistlib.loads(xs[0].read_bytes())
targets=[t for c in d.get('TestConfigurations',[]) for t in c['TestTargets']] if 'TestConfigurations' in d else [v for k,v in d.items() if not k.startswith('__')]
for t in targets:
    t['UITargetAppPath']=sys.argv[2];t['UITargetAppBundleIdentifier']=sys.argv[3]
    t.setdefault('EnvironmentVariables',{}).update(ZE_LAYOUT_BUNDLE=sys.argv[3],ZE_LAYOUT_DYLD=sys.argv[4],ZE_VERIFY_SOUL_HEADER=os.environ.get('ZE_VERIFY_SOUL_HEADER','0'))
(products/'Layout.xctestrun').write_bytes(plistlib.dumps(d))
PY
if [ "${ZE_VERIFY_KEYBOARD_HANG:-0}" = 1 ]; then
    SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH="$layout_fallback" xcrun simctl launch "$layout_device" "$layout_bundle" \
        -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN --verify-conversation-chat --verify-keyboard-hang
    python3 - "$layout_container/Documents/chat-verification/result.json" <<'PY'
import json,pathlib,sys,time
path=pathlib.Path(sys.argv[1])
deadline=time.monotonic()+300
while time.monotonic()<deadline:
    if path.exists():
        result=json.loads(path.read_text())
        print(json.dumps(result,ensure_ascii=False,indent=2))
        assert result['success'],result
        break
    time.sleep(1)
else:
    raise TimeoutError('Keyboard-hang verification did not finish in 300 seconds')
PY
    exit 0
fi
if [ "${ZE_VERIFY_SOUL_HEADER:-0}" = 1 ]; then
    SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH="$layout_fallback" xcrun simctl launch "$layout_device" "$layout_bundle" \
        -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN --verify-conversation-chat --verify-chat-layout-only --verify-soul-avatar
    python3 - "$layout_container/Documents/chat-verification/result.json" <<'PY'
import json,pathlib,sys,time
path=pathlib.Path(sys.argv[1])
deadline=time.monotonic()+300
while time.monotonic()<deadline:
    if path.exists():
        result=json.loads(path.read_text())
        print(json.dumps(result,ensure_ascii=False,indent=2))
        assert result['success'],result
        break
    time.sleep(1)
else:
    raise TimeoutError('Complete avatar application did not finish in 300 seconds')
PY
fi
xcodebuild test-without-building -xctestrun "$layout_work/DerivedData/Build/Products/Layout.xctestrun" -destination "platform=iOS Simulator,id=$layout_device" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -resultBundlePath "$layout_evidence/Layout.xcresult" -test-timeouts-enabled YES -default-test-execution-time-allowance 420 > "$layout_evidence/test.log" 2>&1
if [ "${ZE_VERIFY_SOUL_HEADER:-0}" = 1 ]; then
    python3 scripts/check-soul-tap-evidence.py "$layout_container/Documents/chat-verification/avatar-tap-events.json"
fi
python3 - "$layout_container/Documents/chat-verification/result.json" <<'PY'
import os,pathlib,json,sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text());print(json.dumps(d,ensure_ascii=False,indent=2))
assert d['success'],d
assert 'production-transcript-fade' in d['stages'],d
assert d['lastStage']=='complete',d
if os.environ.get('ZE_VERIFY_SOUL_HEADER') == '1':
    assert 'production-soul-avatar' in d['stages'],d
    assert int(d['systemVersion'].split('.')[0]) == int(os.environ.get('ZE_SIMULATOR_IOS_MAJOR','26')),d
PY
