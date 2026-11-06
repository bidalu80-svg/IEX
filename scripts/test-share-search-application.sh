#!/usr/bin/env bash
set -euo pipefail

app="${ZE_SHARE_SEARCH_SIM_APP:?Run build-share-search-simulator.sh first}"
evidence="${1:-share-search-application-evidence}"
mkdir -p "$evidence"
test -d "$app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
device=$(xcrun simctl list devices available --json | python3 -c 'import sys,json; d=json.load(sys.stdin); xs=[x for runtime,devices in d["devices"].items() if "iOS" in runtime for x in devices if x["name"].startswith("iPhone")]; print(next((x["udid"] for x in xs if x["state"]=="Booted"),xs[0]["udid"]))')
xcrun simctl boot "$device" || true
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
container=$(xcrun simctl get_app_container "$device" "$bundle_id" data)
collect() {
    local kind
    for kind in share search; do
        if [ -d "$container/Documents/$kind-verification" ]; then
            mkdir -p "$evidence/$kind-verification"
            cp -R "$container/Documents/$kind-verification/." "$evidence/$kind-verification/"
        fi
    done
    for stream in "$container"/Documents/verification-*.log; do
        if [ -f "$stream" ]; then cp "$stream" "$evidence/"; fi
    done
}
diagnostics() {
    collect
    xcrun simctl io "$device" screenshot "$evidence/final-screen.png" || true
    xcrun simctl spawn "$device" log show --last 8m --style compact --predicate 'process == "Ze" OR eventMessage CONTAINS "com.ze.app"' > "$evidence/application-system.log" 2>&1 || true
    mkdir -p "$evidence/crashes"
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Ze*' -type f -exec cp {} "$evidence/crashes/" \; 2>/dev/null || true
}
trap diagnostics EXIT
for kind in share search; do
    xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
    # Delete only this generated result marker; retain earlier artifacts if a
    # fresh run fails, and rely on the fresh success manifest for validation.
    rm -f "$container/Documents/$kind-verification/result.json"
    xcrun simctl launch --stdout="$container/Documents/verification-$kind-stdout.log" --stderr="$container/Documents/verification-$kind-stderr.log" "$device" "$bundle_id" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN "--verify-conversation-$kind"
    for attempt in $(seq 1 150); do
        if [ -f "$container/Documents/$kind-verification/result.json" ]; then break; fi
        sleep 2
    done
    collect
    python3 - "$evidence/$kind-verification/result.json" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
assert p.exists(),f'Actual application did not produce fresh result: {p}'
result=json.loads(p.read_text())
print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['success'],result
PY
done
xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
