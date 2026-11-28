#!/usr/bin/env bash
set -euo pipefail
# Ship native objects, not Rust LLVM bitcode for Apple's/Swift's older reader.
# Keep LTO off in Cargo.toml; Rust performs compilation before the Apple linker.
export RUSTFLAGS="${RUSTFLAGS:-} -C embed-bitcode=no"
# Isolate artifacts from concurrent cargo test/build invocations with other flags.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="${1:-$root/stage1-connection-evidence/native-abi}"
export CARGO_TARGET_DIR="$root/Installer/Native/target/swift-abi"
mkdir -p "$evidence"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cargo build --locked --manifest-path "$root/Installer/Native/Cargo.toml" 2>&1 | tee "$evidence/rust-build.log"
swift build --package-path "$root/Installer" --scratch-path "$work/build" --target ConnectionExperimentCore \
    2>&1 | tee "$evidence/swift-build.log"
bin="$(swift build --package-path "$root/Installer" --scratch-path "$work/build" --show-bin-path)"
objects=()
for object in "$bin/ConnectionExperimentCore.build/"*.swift.o; do
    test -f "$object"; objects+=("$object")
done
link=()
if [ "$(uname -s)" = Darwin ]; then
    link=(-framework Security)
else
    link=(-Xlinker -ldl -Xlinker -lpthread -Xlinker -lm)
fi
swiftc -parse-as-library -D ZE_CONNECTION_EXPERIMENT \
    -I "$bin/Modules" -I "$root/Installer/Sources/CConnectionABI" \
    "$root/InstallerHost/NativePairingBackend.swift" "$root/Installer/Native/SwiftABIContract.swift" \
    "${objects[@]}" -Xlinker "$CARGO_TARGET_DIR/debug/libze_connection.a" \
    "${link[@]}" -o "$work/native-contract" 2>&1 | tee "$evidence/swift-link.log"
"$work/native-contract" | tee "$evidence/contract.json"
