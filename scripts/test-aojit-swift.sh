#!/bin/bash
# macOS standalone compile of real production Swift, no copied algorithms.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
if ! command -v swiftc >/dev/null 2>&1; then
    echo 'SKIP: Swift compiler unavailable; production Swift harness was not executed.'
    exit 77
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ze-aojit-swift.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cc -c "$repo/scripts/AOJITHarness.c" -o "$scratch/native-fixture.o"
swiftc -swift-version 5 -parse-as-library -import-objc-header "$repo/scripts/AOJITHarness.h" \
    "$repo/Agent/ISH/AOJITModuleProbe.swift" "$repo/Agent/Chat/AOJITRuntimeStatus.swift" \
    "$repo/Agent/Chat/AOJITShellStats.swift" "$repo/scripts/AOJITSwiftHarness.swift" \
    "$scratch/native-fixture.o" -o "$scratch/test"
"$scratch/test"
