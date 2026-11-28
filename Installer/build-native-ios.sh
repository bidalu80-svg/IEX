#!/usr/bin/env bash
set -euo pipefail
# Compile this crate to native objects with LTO off. Prebuilt Rust sysroot archive
# members can still contain bitcode; the final Apple link remains a required check.
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
    # Apple's nm cannot parse LLVM 23 bitcode members in the Rust sysroot.
    # Match the reader to the active producer; failures and all five ABI exports
    # remain mandatory. Full Ze simulator/device linking follows in the CI job.
    python3 "$root/Installer/check-native-symbols.py" "$library" "$evidence"
    shasum -a 256 "$library" > "$evidence/$target-sha256.txt"
done
