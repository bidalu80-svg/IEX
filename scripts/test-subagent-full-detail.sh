#!/bin/bash
set -euo pipefail
if [ "${ZE_FULL_DETAIL_CHILD:-}" != "1" ]; then
  exec python3 - "$0" <<'PY'
import json, os, pathlib, signal, subprocess, sys
p=pathlib.Path('subagent-full-detail-evidence'); p.mkdir(exist_ok=True)
child=subprocess.Popen(['bash',sys.argv[1]],env={**os.environ,'ZE_FULL_DETAIL_CHILD':'1'},start_new_session=True)
try:
    code=child.wait(timeout=175)
except subprocess.TimeoutExpired:
    os.killpg(child.pid,signal.SIGTERM)
    try: child.wait(timeout=3)
    except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL)
    code=124
if code: (p/'harness-failure.json').write_text(json.dumps({'success':False,'exitCode':code,'error':'Detail harness failed or timed out; see CI log'}))
sys.exit(code)
PY
fi
REF_APP="$RUNNER_TEMP/ZeFullDetailReference.app"
ZE_APP="$RUNNER_TEMP/ZeFullDetailLocal.app"
mkdir -p "$REF_APP" "$ZE_APP" subagent-full-detail-evidence
python3 scripts/extract-subagent-full-detail.py "$RUNNER_TEMP/SubAgentFullDetailReference.swift" "$REF_APP" subagent-full-detail-evidence
python3 scripts/prepare-ui-harness-localization.py "$ZE_APP" subagent-full-detail-evidence
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="$(uname -m)-apple-ios16.0-simulator"
xcrun --sdk iphonesimulator swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" "$RUNNER_TEMP/SubAgentFullDetailReference.swift" -o "$REF_APP/Harness"
xcrun --sdk iphonesimulator swiftc -parse-as-library -D ZE_DETAIL -target "$TARGET" -sdk "$SDK" "$RUNNER_TEMP/ZeSubAgentFullDetailProduction.swift" -o "$ZE_APP/Harness"
python3 - "$REF_APP" "$ZE_APP" <<'PY'
import pathlib,plistlib,sys
for app,kind in zip(sys.argv[1:],['reference','ze']):
    obj={'CFBundleIdentifier':'com.ze.full-detail-'+kind,'CFBundleExecutable':'Harness','CFBundleName':'FullDetailHarness','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'zh-Hans','CFBundleLocalizations':['zh-Hans'],'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'16.0','UIDeviceFamily':[1],'UILaunchScreen':{}}
    (pathlib.Path(app)/'Info.plist').write_bytes(plistlib.dumps(obj))
PY
codesign --force --sign - "$REF_APP"
codesign --force --sign - "$ZE_APP"
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); c=[x for r,ds in d["devices"].items() if "iOS" in r for x in ds if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in c if x["state"]=="Booted"),c[0]["udid"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
FIXTURE_START=$(python3 -c 'import time; print(time.time()-1)')
CONTAINER=""
PREFIX=""
BUNDLE=""
collect() {
  if [ -n "$CONTAINER" ]; then
    cp "$CONTAINER/Documents/"*.png subagent-full-detail-evidence/ 2>/dev/null || true
    cp "$CONTAINER/Documents/"*-result.json subagent-full-detail-evidence/ 2>/dev/null || true
  fi
  if [ -n "$BUNDLE" ]; then xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true; fi
}
trap collect EXIT
for KIND in reference ze; do
  if [ "$KIND" = reference ]; then APP="$REF_APP"; else APP="$ZE_APP"; fi
  BUNDLE="com.ze.full-detail-$KIND"
  PREFIX="$KIND-detail"
  xcrun simctl install "$DEVICE" "$APP"
  CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
  python3 - "$CONTAINER/Documents" "$PREFIX" <<'PY'
import pathlib,sys
for p in pathlib.Path(sys.argv[1]).glob(sys.argv[2]+'-*'):
    if p.is_file() and p.suffix in ('.png','.json'): p.unlink()
PY
  xcrun simctl launch "$DEVICE" "$BUNDLE" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN --fixture-start "$FIXTURE_START"
  for attempt in $(seq 1 40); do
    if [ -f "$CONTAINER/Documents/$PREFIX-result.json" ]; then break; fi
    sleep 1
  done
  collect
  python3 - "$PREFIX" <<'PY'
import pathlib,json,sys
p=pathlib.Path('subagent-full-detail-evidence')/(sys.argv[1]+'-result.json')
r=json.loads(p.read_text()); print(json.dumps(r,indent=2))
assert r['success'] and len(r['screenshots'])==4,r
for s in r['screenshots']: assert (p.parent/s['file']).read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
PY
done
python3 scripts/compare-subagent-full-detail.py
