#!/usr/bin/env bash
set -euo pipefail

diagnostic_root="${RUNNER_TEMP:?RUNNER_TEMP is required}/ze-selection-diagnostic"
diagnostic_app="$diagnostic_root/ZeSelectionDiagnostic.app"
diagnostic_evidence="$PWD/selection-diagnostic-evidence"
mkdir -p "$diagnostic_app" "$diagnostic_evidence"

python3 - "$diagnostic_evidence/source-manifest.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
paths = ['Agent/Visualization/VisualizationDocument.swift',
         'Views/Chat/Visualization/VisualizationAttachment.swift',
         'scripts/SelectionDiagnosticHarness.swift', 'scripts/selection-diagnostic-driver.py']
result = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
          'purpose': 'Diagnosis only; feature acceptance requires actual selection in the complete application',
          'sources': {p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in paths}}
pathlib.Path(sys.argv[1]).write_text(json.dumps(result, indent=2))
PY

xcrun swiftc -parse-as-library -D DEBUG \
  -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Agent/Visualization/VisualizationDocument.swift \
  Views/Chat/Visualization/VisualizationAttachment.swift \
  scripts/SelectionDiagnosticHarness.swift \
  -o "$diagnostic_app/ZeSelectionDiagnostic" 2>&1 | tee "$diagnostic_evidence/compile.log"

cat > "$diagnostic_app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.selection-diagnostic</string>
<key>CFBundleExecutable</key><string>ZeSelectionDiagnostic</string>
<key>CFBundleName</key><string>ZeSelectionDiagnostic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$diagnostic_app"
diagnostic_device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); candidates=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in candidates if x["state"]=="Booted"), candidates[0]["udid"]))')
xcrun simctl boot "$diagnostic_device" || true
xcrun simctl bootstatus "$diagnostic_device" -b
xcrun simctl install "$diagnostic_device" "$diagnostic_app"

collect_diagnostics() {
  local diagnostic_container
  diagnostic_container=$(xcrun simctl get_app_container "$diagnostic_device" com.ze.selection-diagnostic data 2>/dev/null) || return 0
  cp "$diagnostic_container/Documents/"selection-diagnostic-* "$diagnostic_evidence/" 2>/dev/null || true
}
trap collect_diagnostics EXIT
python3 scripts/selection-diagnostic-driver.py --work "$diagnostic_root/driver" \
  --app "$diagnostic_app" --device "$diagnostic_device" --evidence "$diagnostic_evidence"
collect_diagnostics
python3 - "$diagnostic_evidence" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
names = ['plain-long', 'plain-double', 'textview-long', 'textview-double',
         'guarded-long', 'guarded-double', 'native-long', 'native-double']
results = {name: json.loads((folder / f'selection-diagnostic-{name}.json').read_text()) for name in names}
(folder / 'comparison.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
print(json.dumps(results, ensure_ascii=False, indent=2))
print('Diagnostic collection complete. Each recorded native selection must be evaluated before making a production fix.')
PY
