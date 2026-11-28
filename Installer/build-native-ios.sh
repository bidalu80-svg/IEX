#!/usr/bin/env bash
set -euo pipefail
# Ship native objects, not Rust LLVM bitcode for Apple's/Swift's older reader.
# Keep LTO off in Cargo.toml; Rust performs compilation before the Apple linker.
export RUSTFLAGS="${RUSTFLAGS:-} -C embed-bitcode=no"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="${1:-$root/stage1-connection-evidence/native}"
mkdir -p "$evidence"
git -C "$root" rev-parse HEAD > "$evidence/source-commit.txt"
cp "$root/Installer/Native/upstream/manifest.json" "$evidence/dependency-manifest.json"
shasum -a 256 "$root/Installer/Native/Cargo.lock" > "$evidence/cargo-lock-sha256.txt"
test "$(uname -s)" = Darwin
command -v cargo
command -v rustup
rustc --version > "$evidence/rust-version.txt"
xcodebuild -version > "$evidence/xcode-version.txt"
# Both are real iOS static libraries. No empty fallback archives are produced.
rustup target add aarch64-apple-ios aarch64-apple-ios-sim 2>&1 | tee "$evidence/rustup.log"
for target in aarch64-apple-ios aarch64-apple-ios-sim; do
    cargo build --locked --release --manifest-path "$root/Installer/Native/Cargo.toml" --target "$target" \
        2>&1 | tee "$evidence/$target-build.log"
    library="$root/Installer/Native/target/$target/release/libze_connection.a"
    test -s "$library"
    xcrun nm -gU "$library" > "$evidence/$target-symbols.txt"
    grep -q '_ze_connection_run' "$evidence/$target-symbols.txt"
    shasum -a 256 "$library" > "$evidence/$target-sha256.txt"
done
