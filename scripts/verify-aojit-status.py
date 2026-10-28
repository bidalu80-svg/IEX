#!/usr/bin/env python3
"""Structural checks for the guest-readable AOJIT status surface.

AOJIT lives entirely in the host process: the guest has no /proc entry and
no on-disk marker. An agent that checks from the shell therefore concludes
"AOJIT is off" on a build where every image is attached — that false
negative already cost a debugging session, so the status has to be
reachable through `ze-config`:

* the `aojit` topic is registered at launch;
* every documented sub-path is a ReadOnlyField (the agent must not be able
  to flip the switch behind the Settings UI);
* the verdict separates the user switch from the kernel readback, which is
  the check that actually answers "is it on?";
* hit rate is guarded against a zero denominator;
* CODE_MAP tells future agents not to look in /proc.
"""
from pathlib import Path
import re

ROOT = Path(".")
checks = 0


def check(condition, name):
    global checks
    assert condition, name
    checks += 1
    print("PASS:", name)


def src(path):
    return (ROOT / path).read_text(encoding="utf-8")


builtins = src("Shared/Config/ConfigRegistry+Builtins.swift")
code_map = src("CODE_MAP.md")
accel = src("Agent/ISH/AOJITAcceleration.swift")

check("registerAOJIT(into: r)" in builtins, "aojit topic is registered at launch")

paths = [
    "aojit",
    "aojit.enabled",
    "aojit.jit_runtime",
    "aojit.images_linked",
    "aojit.images_attached",
    "aojit.aot_hits",
    "aojit.block_translations",
    "aojit.hit_rate",
    "aojit.status",
    "aojit.libraries",
    "aojit.images",
    "aojit.images_unattached",
]
for path in paths:
    check(f'path: "{path}"' in builtins, f"{path} is registered")

# Every aojit field must be a ReadOnlyField: the settings page owns the
# switch, and a writable path would let a tool call silently flip the
# runtime under a speed test.
block = builtins.split("private static func registerAOJIT", 1)[1]
block = block.split("// MARK: Self-meta", 1)[0]
fields = re.findall(r"(ReadOnlyField|AppStorageBoolField|ClosureField)\(\s*\n\s*path: \"(aojit[^\"]*)\"", block)
check(len(fields) == len(paths), f"all {len(paths)} aojit paths parsed")
check(all(kind == "ReadOnlyField" for kind, _ in fields), "every aojit field is read-only")

check("if !n.enabled" in block and "if !n.runtime" in block,
      "verdict separates the user switch from the kernel readback")
check("guard n.blocks > 0" in block or "n.blocks > 0 ?" in block,
      "hit rate is guarded against a zero denominator")
check("ish_aot_attached_count()" in block and "ish_aot_hits()" in block,
      "counters are read from the engine, not from cached UI state")
check("store.refresh()" in block,
      "an unprobed rootfs is probed instead of reporting an empty table")

for symbol in ["linkedImageCount", "attachedImageCount", "aotHitCount", "translatedBlockCount", "states"]:
    check(symbol in accel, f"AOJITAcceleration exposes {symbol}")

# [T-aojit-v2] The 1.15 format distinguishes "linked" from "attached" from
# "serving": an image made by another engine abi is rejected at registration,
# and an image of another version of the file still serves blocks by content.
for symbol in ["rejectedImageCount", "familyHitCount", "jitAbi"]:
    check(symbol in accel, f"AOJITAcceleration exposes {symbol} for the v2 format")
check("ish_aot_rejected_count()" in accel and "ish_aot_image_match(" in accel,
      "the status page asks the engine which images it accepted")
check("imageMatch == 2" in accel,
      "a family image is reported as serving another version, not as full speed")
check("ish_aot_moved_hits()" in accel,
      "blocks served by another version are counted")

check("ze-config get aojit" in code_map, "CODE_MAP documents ze-config get aojit")
check("/proc/ish/jit" in code_map, "CODE_MAP warns that /proc/ish/jit does not exist")

jit_c = src("Vendor/ZeNative/ish/asbestos/guest-arm64/jit.c")
aot_h = src("Vendor/ZeNative/ish/asbestos/guest-arm64/aot.h")
check("aot_img_hits" in jit_c and "ish_aot_hits_for_image" in jit_c,
      "the engine counts hits per attached image")
check("ish_aot_attached_path" in aot_h and "ish_aot_hits_for_image" in aot_h,
      "per-image diagnostics are declared in aot.h")

# [T-aojit-v2] The 1.15 image header: identity is build-id + family, the
# tables are self-relative, and a translation's key is the compact 6-word one.
check("AOT_KEY_UNIT 6" in aot_h and "build_id_len" in aot_h and "by_hash" in aot_h,
      "the image header carries the 1.15 identity fields")
check("aot_rel(" in aot_h and "int32_t key;" in aot_h,
      "the image tables use self-relative 32-bit pointers")

# The UI must compare against what the image was recorded from, not against
# the on-device warm-up record (which always says "full speed").
versions_txt = src("aot/VERSIONS.txt")
recorded = {}
for line in versions_txt.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    # The file uses name-version where version itself contains "-rN":
    # python3-3.12.16-r0 -> name python3, version 3.12.16-r0.
    match = re.match(r"^(.+)-(\d[\d.]*(?:_p\d+)?-r\d+)$", line)
    if match:
        recorded[match.group(1)] = match.group(2)

check("imageVersions" in accel, "AOJITAcceleration declares the recorded image versions")
check("Self.imageVersions[library.package]" in accel,
      "status compares the installed version with the recorded image version")

swift_map = dict(re.findall(
    r'"([a-z0-9_\-]+)": "([^"]+)"',
    accel.split("static let imageVersions", 1)[1].split("= [", 1)[1].split("]", 1)[0],
))
for pkg, ver in swift_map.items():
    check(recorded.get(pkg) == ver, f"imageVersions[{pkg}] matches aot/VERSIONS.txt ({ver})")
for pkg in ["musl", "busybox", "python3"]:
    check(pkg in swift_map, f"imageVersions covers {pkg}")

print(f"\n{checks} checks passed")
