#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$root/stage1-connection-evidence/host-device"
work="${RUNNER_TEMP:?}/ze-connection-device"
checkout="$work/workspace/ios"
mkdir -p "$evidence" "$checkout" "$work/scripts" "$work/workspace/shared/bashism"
# Run after the simulator helper, which installed the native build toolchain.
sim_root="$RUNNER_TEMP/ze-share-search-simulator"
export PATH="$sim_root/meson-venv/bin:$(brew --prefix llvm)/bin:$(brew --prefix libarchive)/bin:$PATH"
rsync -a --exclude='.git' --exclude='.spm' --exclude='.build' --exclude='*.ipa' \
    --exclude='Vendor/ZeNative' --exclude='Installer/Native/target' \
    --exclude='siboot-ref' --exclude='vendor-ref' --exclude='stage1-connection-evidence' \
    "$root/" "$checkout/"
mkdir -p "$checkout/Vendor"
ln -sfn "$root/Vendor/ZeNative" "$checkout/Vendor/ZeNative"
cp "$sim_root/scripts/gen_debug_skill.sh" "$work/scripts/gen_debug_skill.sh"
printf '[]\n' > "$work/workspace/shared/bashism/bashism_rules.json"
printf '[]\n' > "$work/workspace/shared/bashism/bashism_test_vectors.json"
SRCROOT="$checkout" bash "$work/scripts/gen_debug_skill.sh"
if [ ! -f "$checkout/Configs/ProviderCustomization.xcconfig" ]; then
    cp "$checkout/Configs/ProviderCustomization.xcconfig.example" "$checkout/Configs/ProviderCustomization.xcconfig"
fi
python3 - "$checkout/Ze.xcodeproj/project.pbxproj" "$work" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
for name in set(re.findall(r'\.\./\.\./build/frameworks/([^";]+\.framework)', text)):
    (pathlib.Path(sys.argv[2]) / 'build/frameworks' / name).mkdir(parents=True, exist_ok=True)
PY
# Real device iSH/FFmpeg libraries. Never substitute a native backend stub.
ZE_NATIVE_SDK=iphoneos bash "$root/scripts/prepare-ze-native-deps.sh" "$work/deps" \
    2>&1 | tee "$evidence/dependencies.log"
library="$root/Installer/Native/target/aarch64-apple-ios/release/libze_connection.a"
test -s "$library"
cd "$checkout"
xcodebuild build -project Ze.xcodeproj -scheme Ze -configuration Debug \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$work/DerivedData" \
    -clonedSourcePackagesDirPath "$sim_root/spm" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' ENABLE_DEBUG_DYLIB=NO ZE_AOT_OBJECTS='' \
    ZE_CONNECTION_SWIFT_FLAGS='-DZE_CONNECTION_EXPERIMENT' \
    "INFOPLIST_KEY_ZEConnectionSourceCommit=${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)}" \
    "ZE_CONNECTION_LINK_FLAGS=-Xlinker $library -framework Security" \
    2>&1 | tee "$evidence/flag-on-device-build.log"
app="$work/DerivedData/Build/Products/Debug-iphoneos/Ze.app"
xcrun nm "$app/Ze" > "$evidence/symbols.txt"
grep -q '_ze_connection_run' "$evidence/symbols.txt"
/usr/libexec/PlistBuddy -c 'Print :NSBonjourServices' "$app/Info.plist" > "$evidence/bonjour-plist.txt"
grep -q '_remotepairing-pairable-host._tcp' "$evidence/bonjour-plist.txt"
mkdir -p "$evidence/package/Payload"
cp -R "$app" "$evidence/package/Payload/Ze.app"
(cd "$evidence/package" && /usr/bin/zip -qry "$evidence/Ze-connection-experiment-unsigned.ipa" Payload)
shasum -a 256 "$evidence/Ze-connection-experiment-unsigned.ipa" > "$evidence/ipa-sha256.txt"
rm -rf "$evidence/package"
