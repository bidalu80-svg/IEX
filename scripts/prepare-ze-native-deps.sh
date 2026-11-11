#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_input="${1:?Usage: prepare-ze-native-deps.sh <deps-output-directory>}"
output_parent="$(cd "$(dirname "$output_input")" && pwd)"
output_dir="$output_parent/$(basename "$output_input")"
vendor_dir="$repo_root/Vendor/ZeNative"
native_sdk="${ZE_NATIVE_SDK:-iphoneos}"
case "$native_sdk" in
    iphoneos) native_destination='generic/platform=iOS'; native_target='arm64-apple-ios16.0' ;;
    iphonesimulator) native_destination='generic/platform=iOS Simulator'; native_target='arm64-apple-ios16.0-simulator' ;;
    *) echo "Unexpected ZE_NATIVE_SDK: $native_sdk" >&2; exit 1 ;;
esac
work_root="${RUNNER_TEMP:-$repo_root/.build}/ze-native-build-$native_sdk"

if [ "$(basename "$output_dir")" != "deps" ]; then
    echo "Refusing to replace a directory not named deps: $output_dir" >&2
    exit 1
fi

for required in "$vendor_dir/ish/iSH.xcodeproj" "$vendor_dir/lame-3.100/configure" \
                "$vendor_dir/ffmpeg-patch" "$repo_root/scripts/build-ze-ffmpeg.sh"; do
    test -e "$required" || { echo "Missing vendored input: $required" >&2; exit 1; }
done

rm -rf "$work_root"
mkdir -p "$work_root"
cp -R "$vendor_dir/ish" "$work_root/ish"
cp -R "$vendor_dir/lame-3.100" "$work_root/lame-3.100"
cp -R "$vendor_dir/ffmpeg-patch" "$work_root/ffmpeg-patch"

ish_dir="$work_root/ish"
ish_products="$work_root/ish-products"
mkdir -p "$ish_products"

xcodebuild \
    -project "$ish_dir/iSH.xcodeproj" \
    -target libish \
    -target libish_emu \
    -target libfakefs \
    -configuration Release \
    -sdk "$native_sdk" \
    -destination "$native_destination" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CONFIGURATION_BUILD_DIR="$ish_products" \
    GUEST_ARCH=arm64 \
    NINJA_TARGETS='libish.a libish_emu.a libfakefs.a' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

for library in libish.a libish_emu.a libfakefs.a; do
    if [ ! -s "$ish_products/$library" ] && [ -s "$ish_products/meson/$library" ]; then
        cp "$ish_products/meson/$library" "$ish_products/$library"
    fi
    test -s "$ish_products/$library"
done

rm -rf "$output_dir"
mkdir -p "$output_dir/include/ish" "$output_dir/libs" "$output_dir/resources"
cp "$ish_products/libish.a" "$ish_products/libish_emu.a" "$ish_products/libfakefs.a" "$output_dir/libs/"

copy_headers() {
    local source_dir="$1"
    local relative_dir="$2"
    while IFS= read -r -d '' header; do
        local destination="$output_dir/include/ish/$relative_dir${header#"$source_dir"/}"
        mkdir -p "$(dirname "$destination")"
        cp "$header" "$destination"
    done < <(find "$source_dir" -type f \( -name '*.h' -o -name '*.inc' \) -print0)
}

while IFS= read -r -d '' header; do
    cp "$header" "$output_dir/include/ish/"
done < <(find "$ish_dir" -maxdepth 1 -type f \( -name '*.h' -o -name '*.inc' \) -print0)
for component in emu kernel fs util platform asbestos; do
    copy_headers "$ish_dir/$component" "$component/"
done

# The vendored iSH source has no checked-in public umbrella header. Generate
# the same integration header expected by Ze's Swift bridging header.
cat > "$output_dir/include/ish/ish.h" <<'EOF'
#ifndef ISH_H
#define ISH_H

#include "misc.h"
#include "debug.h"

#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/errno.h"

#include "fs/fd.h"
#include "fs/stat.h"
#include "fs/tty.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/poll.h"
#include "fs/dev.h"

#include "emu/cpu.h"
#include "emu/tlb.h"
#include "emu/mmu.h"
#if defined(GUEST_X86)
#include "emu/float80.h"
#endif

#include "platform/platform.h"

#endif /* ISH_H */
EOF
test -s "$output_dir/include/ish/ish.h"

if [ -f "$ish_products/meson/cpu-offsets.h" ]; then
    cp "$ish_products/meson/cpu-offsets.h" "$output_dir/include/ish/"
elif [ -f "$ish_products/cpu-offsets.h" ]; then
    cp "$ish_products/cpu-offsets.h" "$output_dir/include/ish/"
fi
mkdir -p "$output_dir/include/ish/deps"
cp "$ish_dir/deps/config.h" "$output_dir/include/ish/deps/"

native_build="$ish_dir/build-native"
meson setup "$native_build" "$ish_dir" \
    --buildtype=release \
    -Dlog='' \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dguest_arch=arm64 \
    -Djit=true
ninja -C "$native_build" tools/fakefsify

alpine_version='3.21'
alpine_release='0'
alpine_tarball="alpine-minirootfs-${alpine_version}.${alpine_release}-aarch64.tar.gz"
alpine_url="https://dl-cdn.alpinelinux.org/alpine/v${alpine_version}/releases/aarch64/${alpine_tarball}"
curl --fail --location --retry 3 --retry-delay 2 "$alpine_url" -o "$work_root/$alpine_tarball"
"$native_build/tools/fakefsify" "$work_root/$alpine_tarball" "$work_root/alpine-rootfs"
test -d "$work_root/alpine-rootfs/data"
test -f "$work_root/alpine-rootfs/meta.db"
(
    cd "$work_root"
    /usr/bin/zip -qry "$output_dir/resources/alpine-rootfs.zip" alpine-rootfs -x '*.db-shm' -x '*.db-wal'
)
test -s "$output_dir/resources/alpine-rootfs.zip"
cp -R "$ish_dir/app/RootfsPatch.bundle" "$output_dir/resources/RootfsPatch.bundle"

# Host iSH generation above needs Homebrew LLVM; iOS libraries below must
# resolve all compiler/linker tools from the same selected Xcode toolchain.
ios_sdk="$(xcrun --sdk "$native_sdk" --show-sdk-path)"
native_toolchain_bin="$(dirname "$(xcrun --sdk "$native_sdk" -f clang)")"
export PATH="$native_toolchain_bin:$PATH"
export AR="$(xcrun --sdk "$native_sdk" -f ar)"
export RANLIB="$(xcrun --sdk "$native_sdk" -f ranlib)"
export LD="$(xcrun --sdk "$native_sdk" -f ld)"
native_evidence="$repo_root/native-build-evidence/$native_sdk"
mkdir -p "$native_evidence"
# Keep diagnostics even when configure exits before application logs exist.
collect_native_diagnostics() {
    local result=$?
    trap - EXIT
    for relative in lame-3.100/config.log ffmpeg-6.1.2/ffbuild/config.log; do
        if [ -f "$work_root/$relative" ]; then
            mkdir -p "$native_evidence/$(dirname "$relative")"
            cp "$work_root/$relative" "$native_evidence/$relative" || true
            if [ "$result" -ne 0 ]; then tail -n 160 "$work_root/$relative" >&2; fi
        fi
    done
    exit "$result"
}
trap collect_native_diagnostics EXIT
export CC="$(xcrun --sdk "$native_sdk" -f clang)"
export CFLAGS="-target $native_target -isysroot $ios_sdk -Oz -fPIC -Wno-implicit-function-declaration"
export LDFLAGS="-target $native_target -isysroot $ios_sdk -fuse-ld=$LD"
# Run the same compile/link sanity check before configure; retain the actual
# selected linker and diagnostics without retrying or hiding a failing build.
cat > "$native_evidence/compiler-probe.c" <<'EOF'
int main(void) { return 0; }
EOF
{
    "$CC" --version
    "$LD" -version_details
    echo "SDK=$ios_sdk TARGET=$native_target"
    "$CC" $CFLAGS $LDFLAGS -v "$native_evidence/compiler-probe.c" -o "$native_evidence/compiler-probe"
} > "$native_evidence/compiler-probe.log" 2>&1 || {
    cat "$native_evidence/compiler-probe.log" >&2
    exit 1
}
(
    cd "$work_root/lame-3.100"
    ./configure \
        --prefix="$work_root/lame-build" \
        --host=aarch64-apple-darwin \
        --disable-shared \
        --enable-static \
        --disable-frontend \
        --disable-decoder \
        --disable-gtktest \
        --with-pic
    make -j"$(sysctl -n hw.ncpu)"
    make install
)
test -s "$work_root/lame-build/lib/libmp3lame.a"

ZE_NATIVE_SDK="$native_sdk" ZE_NATIVE_WORKDIR="$work_root" bash "$repo_root/scripts/build-ze-ffmpeg.sh"
cp -R "$work_root/frameworks" "$output_dir/frameworks"

for framework in FFmpeg libavcodec libavformat libavutil libavfilter libswresample libswscale; do
    test -s "$output_dir/frameworks/$framework.framework/$framework"
    test -f "$output_dir/frameworks/$framework.framework/Info.plist"
done

echo "Prepared real Ze native dependencies in $output_dir"
