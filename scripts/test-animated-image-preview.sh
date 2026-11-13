#!/usr/bin/env bash
set -euo pipefail
preview_work="$RUNNER_TEMP/ze-animation-preview"
preview_app="$preview_work/AnimationPreview.app"
preview_evidence="animated-image-preview-evidence"
mkdir -p "$preview_app" "$preview_evidence"
python3 scripts/prepare-animated-image-preview.py "$preview_work"
cp "$preview_work/sources.json" "$preview_evidence/"
xcrun --sdk iphonesimulator swiftc -parse-as-library -D DEBUG -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" "$preview_work/AnimationPreview.swift" -o "$preview_app/AnimationPreview" 2>&1 | tee "$preview_evidence/compile.log"
python3 - "$preview_app/Info.plist" <<'PYPLIST'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='com.ze.animation-preview',CFBundleExecutable='AnimationPreview',CFBundleName='AnimationPreview',CFBundlePackageType='APPL',CFBundleVersion='1',CFBundleShortVersionString='1.0',MinimumOSVersion='16.0',UIDeviceFamily=[1],UILaunchScreen={}),f)
PYPLIST
codesign --force --sign - "$preview_app"
preview_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$preview_device" || true
xcrun simctl bootstatus "$preview_device" -b
xcrun simctl install "$preview_device" "$preview_app"
preview_container=$(xcrun simctl get_app_container "$preview_device" com.ze.animation-preview data)
collect_preview() {
    if [ -d "$preview_container/Documents/share-verification" ]; then
        cp -R "$preview_container/Documents/share-verification" "$preview_evidence/"
    fi
    xcrun simctl terminate "$preview_device" com.ze.animation-preview >/dev/null 2>&1 || true
}
trap collect_preview EXIT
python3 scripts/share-xcui-driver.py prepare --work "$preview_work/driver" --device "$preview_device"
ZE_ANIMATED_IMAGE_ONLY=true python3 scripts/share-xcui-driver.py run --work "$preview_work/driver" --device "$preview_device" --app "$preview_app" --container "$preview_container" --bundle com.ze.animation-preview --evidence "$preview_evidence/xcui"
python3 - "$preview_container/Documents/share-verification/result.json" <<'PYRESULT'
import json,sys
x=json.load(open(sys.argv[1]));print(json.dumps(x,indent=2));assert x['success'],x
assert any('webp real play button resumes' in c for c in x['checks']),x
PYRESULT
