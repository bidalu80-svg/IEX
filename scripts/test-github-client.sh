#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ze-github-tests.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  Shared/GitHub/GitHubModels.swift \
  Shared/GitHub/GitHubRepositoryClient.swift \
  scripts/GitHubRepositoryClientTests.swift \
  -o "$build_dir/github-client-tests"
"$build_dir/github-client-tests"
