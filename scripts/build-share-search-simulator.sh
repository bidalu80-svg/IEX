#!/usr/bin/env bash
set -euo pipefail

# Build the whole application with real simulator iSH/FFmpeg dependencies.
# The device checkout and ../../deps are never replaced by this job.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test "$(uname -s)" = Darwin
if [ "$(uname -m)" != arm64 ]; then
    echo 'The guest-arm64 iSH JIT requires an Apple arm64 host; use macos-15-arm64.' >&2
    exit 1
fi
sim_root="${RUNNER_TEMP:?RUNNER_TEMP is required}/ze-share-search-simulator"
sim_checkout="$sim_root/workspace/ios"
mkdir -p "$sim_checkout" "$sim_root/scripts" "$sim_root/workspace/shared/bashism"
for package in ninja llvm lld libarchive pkg-config; do
    brew list "$package" >/dev/null 2>&1 || brew install "$package"
done
python3 -m venv "$sim_root/meson-venv"
"$sim_root/meson-venv/bin/pip" install meson
export PATH="$sim_root/meson-venv/bin:$(brew --prefix llvm)/bin:$(brew --prefix libarchive)/bin:$PATH"

# Keep original files and their paths together, including the application's
# generated integration harness. Large native sources are staged separately by
# prepare-ze-native-deps. No simulator changes are copied back to the checkout.
rsync -a --exclude='.git' --exclude='.spm' --exclude='Vendor/ZeNative' \
    --exclude='build-macos' --exclude='.build' --exclude='*.ipa' \
    "$repo_root/" "$sim_checkout/"
mkdir -p "$sim_checkout/Vendor"
ln -sfn "$repo_root/Vendor/ZeNative" "$sim_checkout/Vendor/ZeNative"
printf '[]\n' > "$sim_root/workspace/shared/bashism/bashism_rules.json"
printf '[]\n' > "$sim_root/workspace/shared/bashism/bashism_test_vectors.json"
cat > "$sim_root/scripts/gen_debug_skill.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$SRCROOT/Generated"
cat > "$SRCROOT/Generated/DebugSkillGenerated.swift" <<'SWIFT'
#if DEBUG
enum DebugSkillGenerated {
    static let skillMarkdownB64 = ""
    static let clientPythonB64 = ""
    static let clientNodeB64 = ""
    static let clientBashB64 = ""
}
#endif
SWIFT
SH
chmod +x "$sim_root/scripts/gen_debug_skill.sh"
SRCROOT="$sim_checkout" bash "$sim_root/scripts/gen_debug_skill.sh"
if [ ! -f "$sim_checkout/Configs/ProviderCustomization.xcconfig" ]; then
    cp "$sim_checkout/Configs/ProviderCustomization.xcconfig.example" "$sim_checkout/Configs/ProviderCustomization.xcconfig"
fi

# These optional QEMU framework references are not linked by the Ze target.
# Mirror the existing workflow's empty directory placeholders, not fake native
# implementations. The app's linked iSH and seven FFmpeg frameworks are real.
python3 - "$sim_checkout/Ze.xcodeproj/project.pbxproj" "$sim_root" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
root=pathlib.Path(sys.argv[2])
for name in set(re.findall(r'\.\./\.\./build/frameworks/([^";]+\.framework)', text)):
    (root/'build/frameworks'/name).mkdir(parents=True,exist_ok=True)
PY
ZE_NATIVE_SDK=iphonesimulator bash "$repo_root/scripts/prepare-ze-native-deps.sh" "$sim_root/deps"
for framework in FFmpeg libavcodec libavformat libavutil libavfilter libswresample libswscale; do
    bundle="$sim_root/deps/frameworks/$framework.framework"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$bundle/Info.plist")" = iPhoneSimulator
    xcrun vtool -show-build "$bundle/$framework" | tee "$sim_root/$framework-platform.txt"
    grep -q 'IOSSIMULATOR' "$sim_root/$framework-platform.txt"
done

cd "$sim_checkout"
xcodebuild -resolvePackageDependencies -project Ze.xcodeproj -scheme Ze \
    -clonedSourcePackagesDirPath "$sim_root/spm" 2>&1 | tee "$repo_root/share-search-simulator-resolve.log"
xcodebuild build -project Ze.xcodeproj -scheme Ze -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$sim_root/DerivedData" \
    -clonedSourcePackagesDirPath "$sim_root/spm" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
    ENABLE_DEBUG_DYLIB=NO ZE_AOT_OBJECTS='' \
    2>&1 | tee "$repo_root/share-search-simulator-build.log"
sim_app="$sim_root/DerivedData/Build/Products/Debug-iphonesimulator/Ze.app"
test -s "$sim_app/Ze"
test -f "$sim_app/Info.plist"
if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'ZE_SHARE_SEARCH_SIM_APP=%s\n' "$sim_app" >> "$GITHUB_ENV"
fi
printf '%s\n' "$sim_app" > "$repo_root/share-search-simulator-app-path.txt"
echo "Built simulator application: $sim_app"
