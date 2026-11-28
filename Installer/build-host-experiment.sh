#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$root/stage1-connection-evidence/host"
mkdir -p "$evidence"
# Existing production build helper creates a full simulator Ze with real iSH and
# FFmpeg dependencies. Its ordinary build remains flag OFF and is not modified.
bash "$root/scripts/build-share-search-simulator.sh" 2>&1 | tee "$evidence/flag-off-build.log"
sim_root="${RUNNER_TEMP:?}/ze-share-search-simulator"
app="$sim_root/DerivedData/Build/Products/Debug-iphonesimulator/Ze.app"
xcrun nm "$app/Ze" > "$evidence/flag-off-symbols.txt"
if grep -q '_ze_connection_run' "$evidence/flag-off-symbols.txt"; then
    echo 'Experiment ABI unexpectedly linked in default Ze' >&2; exit 1
fi
library="$root/Installer/Native/target/aarch64-apple-ios-sim/release/libze_connection.a"
test -s "$library"
cd "$sim_root/workspace/ios"
xcodebuild build -project Ze.xcodeproj -scheme Ze -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$sim_root/DerivedData-experiment" -clonedSourcePackagesDirPath "$sim_root/spm" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' ENABLE_DEBUG_DYLIB=NO ZE_AOT_OBJECTS='' \
    ZE_CONNECTION_SWIFT_FLAGS='-DZE_CONNECTION_EXPERIMENT' \
    "INFOPLIST_KEY_ZEConnectionSourceCommit=${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)}" \
    "ZE_CONNECTION_LINK_FLAGS=-Xlinker $library -framework Security" \
    2>&1 | tee "$evidence/flag-on-build.log"
app="$sim_root/DerivedData-experiment/Build/Products/Debug-iphonesimulator/Ze.app"
xcrun nm "$app/Ze" > "$evidence/flag-on-symbols.txt"
grep -q '_ze_connection_run' "$evidence/flag-on-symbols.txt"
/usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "$app/Info.plist" > "$evidence/bonjour-plist.txt"
grep -q '_remotepairing-pairable-host._tcp' "$evidence/bonjour-plist.txt"
shasum -a 256 "$app/Ze" > "$evidence/experiment-binary-sha256.txt"
# This is compilation/linkage evidence. No simulator/device discovery is claimed.
