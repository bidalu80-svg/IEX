#!/bin/bash
# Stage OpenMinis's declared suite. No substitute workloads on missing input.
# usage: prepare-aot-workloads.sh <ish CLI> <real rootfs> <pinned ish checkout>
set -euo pipefail
ish=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
root=$(cd "$2" && pwd)
source_dir=$(cd "$3" && pwd)
repo=$(cd "$(dirname "$0")/.." && pwd)
expected=0fd17a135e78b7a0cf08a4f5831217bbb76ed22f
[ "$(git -C "$source_dir" rev-parse HEAD)" = "$expected" ] || { echo 'Wrong upstream suite revision' >&2; exit 1; }
suite="$source_dir/benchmark/aojit"
[ -f "$suite/install.sh" ] || { echo "Missing pinned suite: $suite/install.sh" >&2; exit 1; }
# The suite installer copies its guest scripts and creates their input fixtures.
bash "$suite/install.sh" "$ish" "$root"
mkdir -p "$root/tmp/aojit/minis" "$root/tmp/aojit/net" "$root/tmp/aojit/ssh"
cp "$repo/scripts/aot-reference-workloads/pcre_train.sh" "$root/tmp/aojit/minis/"
cp "$repo/scripts/aot-reference-workloads/sshd_setup.sh" "$root/tmp/aojit/ssh/"
# Match record_local.sh: generate certificates on the HOST, not by installing
# a guest openssl CLI which could upgrade the exact libcrypto/libssl packages.
for kind in rsa ec; do
    if [ "$kind" = rsa ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$root/tmp/aojit/net/rsa.key" \
            -out "$root/tmp/aojit/net/rsa.crt" -days 365 -subj /CN=localhost \
            -addext subjectAltName=DNS:localhost,IP:127.0.0.1
    else
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "$root/tmp/aojit/net/ec.key" -out "$root/tmp/aojit/net/ec.crt" \
            -days 365 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1
    fi
done
cat "$root/etc/ssl/certs/ca-certificates.crt" "$root/tmp/aojit/net/rsa.crt" \
    "$root/tmp/aojit/net/ec.crt" > "$root/tmp/aojit/net/ca_bundle.pem"
python3 "$repo/scripts/record-aot.py" --ish "$ish" --root "$root" --check-only
