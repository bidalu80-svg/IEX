#!/bin/sh
# Legacy entry point disabled: it cannot establish reference workload provenance
# or exact module identity. Use the repository's checked recording workflow.
set -eu
echo 'Legacy AOJIT recording is disabled. Stage reference workloads with scripts/prepare-aot-workloads.sh, then use scripts/record-aot.py (or .github/workflows/aot-record.yml).' >&2
exit 1
