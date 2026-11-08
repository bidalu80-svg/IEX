#!/bin/bash
set -euo pipefail
APP="$RUNNER_TEMP/ZeFeedbackHarness.app"
mkdir -p "$APP" feedback-ui-evidence
PROBE="$RUNNER_TEMP/ZeFeedbackCompletionProbe.swift"
python3 - "$PROBE" <<'PY'
import pathlib,sys
source=pathlib.Path('Agent/Chat/AIChatViewModel.swift').read_text(encoding='utf-8')
start=source.index('    private func notifyCompletionFeedback(')
opening=source.index('{', start)
depth=1
end=opening+1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method=source[start:end].replace('private func notifyCompletionFeedback', 'func notifyCompletionFeedback', 1)
pathlib.Path(sys.argv[1]).write_text("""import Foundation
struct FeedbackProbeBlock {
    enum Kind { case text, tool }
    var kind: Kind
    var content: String
}
final class FeedbackProbeMessage {
    let id = UUID()
    var error: String?
    var blocks = [FeedbackProbeBlock(kind: .text, content: "Finished reply")]
}
@MainActor final class FeedbackCompletionProbe {
    var messages: [FeedbackProbeMessage] = []
    var userDidCancel = false
    var canResume = false
    var feedbackCompletedReplyID: UUID?
    var feedbackAudibleReplyID: UUID?
"""+method+"\n}\n", encoding="utf-8")
PY
xcrun swiftc -parse-as-library -D DEBUG \
  -target "$(uname -m)-apple-ios16.0-simulator" \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  Shared/AppFeedbackPreferences.swift Shared/AppFeedback.swift \
  Views/Settings/SoundHapticsSettingsView.swift scripts/FeedbackUIHarness.swift "$PROBE" \
  -o "$APP/ZeFeedbackHarness"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ze.feedback-harness</string>
<key>CFBundleExecutable</key><string>ZeFeedbackHarness</string>
<key>CFBundleName</key><string>ZeFeedbackHarness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>16.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
DEVICE=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); candidates=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in candidates if x["state"]=="Booted"), candidates[0]["udid"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" com.ze.feedback-harness data)
collect() {
  cp "$CONTAINER/Documents/"feedback-* feedback-ui-evidence/ 2>/dev/null || true
  xcrun simctl terminate "$DEVICE" com.ze.feedback-harness >/dev/null 2>&1 || true
}
trap collect EXIT
python3 - "$CONTAINER/Documents" <<'PY'
import pathlib,sys
for path in pathlib.Path(sys.argv[1]).glob('feedback-*'):
    if path.is_file() and path.suffix in ('.png','.json'): path.unlink()
PY
xcrun simctl launch "$DEVICE" com.ze.feedback-harness -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
for attempt in $(seq 1 45); do
  if [ -f "$CONTAINER/Documents/feedback-ui-result.json" ]; then break; fi
  sleep 1
done
collect
python3 - <<'PY'
import json,pathlib
path=pathlib.Path('feedback-ui-evidence/feedback-ui-result.json')
result=json.loads(path.read_text())
print(json.dumps(result,indent=2,ensure_ascii=False))
assert result['success'],result
assert len(result['screenshots']) == 10,result
for name in result['screenshots']:
    assert (path.parent/name).read_bytes().startswith(b'\x89PNG\r\n\x1a\n'),name
PY
