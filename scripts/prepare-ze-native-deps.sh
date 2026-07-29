#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_input="${1:?Usage: prepare-ze-native-deps.sh <deps-output-directory>}"
output_parent="$(cd "$(dirname "$output_input")" && pwd)"
output_dir="$output_parent/$(basename "$output_input")"
vendor_dir="$repo_root/Vendor/ZeNative"
work_root="${RUNNER_TEMP:-$repo_root/.build}/ze-native-build"

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
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
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
if [ -f "$ish_products/meson/cpu-offsets.h" ]; then
    cp "$ish_products/meson/cpu-offsets.h" "$output_dir/include/ish/"
elif [ -f "$ish_products/cpu-offsets.h" ]; then
    cp "$ish_products/cpu-offsets.h" "$output_dir/include/ish/"
fi
mkdir -p "$output_dir/include/ish/deps"
cp "$ish_dir/deps/config.h" "$output_dir/include/ish/deps/"

native_build="$ish_dir/build-native"
meson setup "$native_build" \
    --buildtype=release \
    -Dlog='' \
    -Dkernel=ish \
    -Dengine=asbestos \
    -Dguest_arch=arm64
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

ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
export CC="$(xcrun --sdk iphoneos -f clang)"
export CFLAGS="-arch arm64 -miphoneos-version-min=16.0 -isysroot $ios_sdk -Oz -fPIC -Wno-implicit-function-declaration"
export LDFLAGS="-arch arm64 -miphoneos-version-min=16.0 -isysroot $ios_sdk"
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

ZE_NATIVE_WORKDIR="$work_root" bash "$repo_root/scripts/build-ze-ffmpeg.sh"
cp -R "$work_root/frameworks" "$output_dir/frameworks"

for framework in FFmpeg libavcodec libavformat libavutil libavfilter libswresample libswscale; do
    test -s "$output_dir/frameworks/$framework.framework/$framework"
    test -f "$output_dir/frameworks/$framework.framework/Info.plist"
done

echo "Prepared real Ze native dependencies in $output_dir"
