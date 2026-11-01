#!/bin/bash
# Real production behavior tests. Requires Xcode on macOS; no source-grep verdicts.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ze-share-tests.XXXXXX")"
EVIDENCE="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/session-share-evidence"
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/test.log") 2>&1
DEVICE=""
CONTAINER=""
BUNDLE=com.ze.session-share-harness
cleanup() {
  local status=$?
  echo "$status" > "$EVIDENCE/exit-code.txt"
  if [ -n "$CONTAINER" ] && [ -d "$CONTAINER/Documents" ]; then
    cp -R "$CONTAINER/Documents/." "$EVIDENCE/" || true
  fi
  # Preserve the exact generated sources for diagnosing an early compiler error.
  for generated in "$WORK/SessionShareSelection.swift" "$WORK/SessionExportNativeRenderer.swift"; do
    if [ -f "$generated" ]; then cp "$generated" "$EVIDENCE/" || true; fi
  done
  if [ -n "$DEVICE" ]; then
    xcrun simctl spawn "$DEVICE" log show --last 5m --style compact --predicate 'process == "ZeSessionShareHarness"' > "$EVIDENCE/simulator.log" 2>&1 || true
    xcrun simctl terminate "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# FIRST: type-check all three edited production files together, unmodified.
# This is not -parse and not the extracted renderer used by behavior fixtures.
# Full-app chat view/VM dependencies are declared in the clearly marked fixtures.
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -typecheck -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$SDK" \
  Agent/Chat/ChatModels.swift Shared/ConsecutiveToolCallsPolicy.swift \
  Views/Chat/SessionExport/SessionExportModels.swift \
  Views/Chat/SessionExport/SessionExportNativeRenderer.swift \
  Views/Chat/SessionExport/SessionShareSheet.swift \
  scripts/SessionShareHarness.swift scripts/SessionShareRenderChecks.swift scripts/SessionShareUIFixtures.swift
echo "PASS: all three complete production share files iOS type-checked"

# Extract exact production code with only an explicit fixture content factory.
python3 scripts/prepare-session-share-tests.py "$WORK"
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
  "$WORK/SessionShareSelection.swift" scripts/SessionShareSelectionTests.swift \
  -o "$WORK/selection-tests"
"$WORK/selection-tests"
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
  "$WORK/SessionShareRenderPolicy.swift" scripts/SessionShareRenderPolicyTests.swift \
  -o "$WORK/render-policy-tests"
"$WORK/render-policy-tests"
# Compile the host-side validator; after simctl execution it MUST consume the
# actual PDF/PNG files and manifest produced by the production native renderer.
xcrun swiftc -parse-as-library scripts/SessionShareArtifactTests.swift -o "$WORK/share-artifacts"

APP="$WORK/ZeSessionShareHarness.app"
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios16.0-simulator" -sdk "$SDK" \
  Agent/Chat/ChatModels.swift Shared/ConsecutiveToolCallsPolicy.swift \
  Views/Chat/SessionExport/SessionExportModels.swift scripts/SessionShareHarness.swift \
  "$WORK/SessionExportNativeRenderer.swift" scripts/SessionShareRenderChecks.swift \
  Views/Chat/SessionExport/SessionShareSheet.swift scripts/SessionShareUIFixtures.swift \
  -o "$APP/ZeSessionShareHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.session-share-harness</string>
<key>CFBundleExecutable</key><string>ZeSessionShareHarness</string>
<key>CFBundleName</key><string>ZeSessionShareHarness</string>
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
STATE=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["state"] for items in d["devices"].values() for x in items if x["udid"]==sys.argv[1]))' "$DEVICE")
if [ "$STATE" != Booted ]; then xcrun simctl boot "$DEVICE"; fi
xcrun simctl bootstatus "$DEVICE" -b
# Remove any stale result: this run must generate its own pass/fail evidence.
xcrun simctl uninstall "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE" data)
for attempt in $(seq 1 60); do
  if [ -f "$CONTAINER/Documents/session-share-result.json" ]; then break; fi
  sleep 2
done
RESULT="$CONTAINER/Documents/session-share-result.json"
if [ ! -f "$RESULT" ]; then
  echo "FAIL: simulator did not produce a session-sharing test result" >&2
  exit 1
fi
python3 - "$RESULT" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    result=json.load(f)
print(json.dumps(result,indent=2))
if result.get('success') is not True:
    raise SystemExit(1)
PY
# Cross-check the exported files independently on the host, not just in-memory
# PDFDocument assertions inside the app. Missing manifest/PNG/PDF is a hard fail.
"$WORK/share-artifacts" "$CONTAINER/Documents/share-render-manifest.json"
