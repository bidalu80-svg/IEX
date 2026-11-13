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
swift_fallback=$(python3 scripts/simulator-webkit-environment.py "$device" --app "$app" --output "$evidence/webkit-runtime")
if [ -n "$swift_fallback" ]; then
    export SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH="$swift_fallback"
fi
collect() {
    local kind
    for kind in chat share search; do
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
    python3 - "$device" "$evidence/application-system.log" <<'PY'
import subprocess,sys
with open(sys.argv[2], 'w') as log:
    try:
        subprocess.run(['xcrun','simctl','spawn',sys.argv[1],'log','show','--last','8m','--style','compact',
                        '--predicate','process == "Ze" OR eventMessage CONTAINS "com.ze.app"'],
                       stdout=log,stderr=subprocess.STDOUT,timeout=60)
    except subprocess.TimeoutExpired:
        log.write('\nSystem log collection reached its 60 second deadline.\n')
PY
    mkdir -p "$evidence/crashes"
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'Ze*' -type f -exec cp {} "$evidence/crashes/" \; 2>/dev/null || true
}
trap diagnostics EXIT
verification_failed=0
# Build only a small XCTest UI runner. It attaches to the app already built by
# build-share-search-simulator.sh; no additional Ze/native dependency build.
xcui_work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ze-share-xcui-driver"
xcui_ready=1
if ! python3 scripts/share-xcui-driver.py prepare --work "$xcui_work" --device "$device"; then
    xcui_ready=0
    verification_failed=1
fi
mkdir -p "$evidence/xcui"
if [ -f "$xcui_work/build.log" ]; then cp "$xcui_work/build.log" "$evidence/xcui/build.log"; fi
verification_kinds="chat share search"
if [ "${ZE_MULTI_IMAGE_ONLY:-false}" = true ]; then verification_kinds="share"; fi
for kind in $verification_kinds; do
    xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
    # Delete only this generated result marker; retain earlier artifacts if a
    # fresh run fails, and rely on the fresh success manifest for validation.
    rm -f "$container/Documents/$kind-verification/result.json" "$evidence/$kind-verification/result.json"
    if [ "$kind" = share ]; then
        rm -f "$container/Documents/share-verification/ui-request.json" "$container/Documents/share-verification/ui-ack.json"
        if [ "$xcui_ready" -ne 1 ]; then
            echo 'Share verification failed: the external XCTest driver did not build.'
            continue
        fi
    fi
    if [ "$kind" = share ]; then
        # XCTest owns launch with the verification arguments and the same WebKit
        # fallback environment. Starting via simctl before testmanager risks a
        # reinstall/relaunch losing those arguments and racing the first UI request.
        if ! python3 scripts/share-xcui-driver.py run --work "$xcui_work" --device "$device" \
            --app "$app" --container "$container" --bundle "$bundle_id" --evidence "$evidence/xcui"; then
            verification_failed=1
        fi
    else
        if ! launch_output=$(xcrun simctl launch --stdout="$container/Documents/verification-$kind-stdout.log" --stderr="$container/Documents/verification-$kind-stderr.log" "$device" "$bundle_id" -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN "--verify-conversation-$kind"); then
            verification_failed=1
            collect
            continue
        fi
        echo "$launch_output"
        app_pid="${launch_output##*: }"
        for attempt in $(seq 1 150); do
            if [ -f "$container/Documents/$kind-verification/result.json" ]; then break; fi
            if [[ "$app_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$app_pid" 2>/dev/null; then
                echo "$kind application exited before producing its result (pid $app_pid)"
                break
            fi
            sleep 2
        done
    fi
    collect
    if ! python3 - "$evidence/$kind-verification/result.json" "$kind" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
assert p.exists(),f'Actual application did not produce fresh result: {p}'
result=json.loads(p.read_text())
print(json.dumps(result,ensure_ascii=False,indent=2))
assert result['success'],result
if sys.argv[2] == 'chat':
    assert result['lastStage'] == 'complete', result
    assert len(result['checks']) >= 21, result
    assert len(result['screenshots']) >= 10, result
    assert result['systemVersion'], result
    for stage in ('open-first-new-chat', 'open-persisted-history', 'open-second-new-chat',
                  'return-home-3', 'reopen-history-3'):
        assert stage in result['stages'], (stage, result)
PY
    then
        verification_failed=1
    fi
done
xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
exit "$verification_failed"
