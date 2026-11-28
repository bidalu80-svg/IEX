#!/usr/bin/env bash
set -euo pipefail
# Compile this crate to native objects with LTO off. Prebuilt Rust sysroot archive
# members can still contain bitcode; the final Apple link remains a required check.
export RUSTFLAGS="${RUSTFLAGS:-} -C embed-bitcode=no"
# Isolate artifacts from concurrent cargo test/build invocations with other flags.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="${1:-$root/stage1-connection-evidence/native-abi}"
export CARGO_TARGET_DIR="$root/Installer/Native/target/swift-abi"
mkdir -p "$evidence"
python3 "$root/Installer/test-native-ci.py" 2>&1 | tee "$evidence/native-ci-tests.log"
rustc -vV > "$evidence/rust-version.txt"
swift --version > "$evidence/swift-version.txt"
uname -a > "$evidence/host.txt"
git -C "$root" rev-parse HEAD > "$evidence/source-commit.txt"
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
swiftc -g -parse-as-library -D ZE_CONNECTION_EXPERIMENT \
    -I "$bin/Modules" -I "$root/Installer/Sources/CConnectionABI" \
    "$root/InstallerHost/NativePairingBackend.swift" "$root/Installer/Native/SwiftABIContract.swift" \
    "${objects[@]}" -Xlinker "$CARGO_TARGET_DIR/debug/libze_connection.a" \
    "${link[@]}" -o "$work/native-contract" 2>&1 | tee "$evidence/swift-link.log"
if [ "$(uname -s)" = Darwin ]; then
    # Archive member names are not platform evidence. Keep actual Mach-O metadata.
    xcrun ar -t "$CARGO_TARGET_DIR/debug/libze_connection.a" > "$evidence/archive-members.txt"
    xcrun otool -l "$work/native-contract" > "$evidence/executable-load-commands.txt"
    # Best-effort diagnostics must not replace the original process failure.
    xcrun dsymutil "$work/native-contract" -o "$evidence/native-contract.dSYM" \
        > "$evidence/dsymutil.log" 2>&1 || true
fi
python3 "$root/Installer/run-native-contract.py" "$work/native-contract" "$evidence"
