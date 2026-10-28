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

check("ze-config get aojit" in code_map, "CODE_MAP documents ze-config get aojit")
check("/proc/ish/jit" in code_map, "CODE_MAP warns that /proc/ish/jit does not exist")

jit_c = src("Vendor/ZeNative/ish/asbestos/guest-arm64/jit.c")
aot_h = src("Vendor/ZeNative/ish/asbestos/guest-arm64/aot.h")
check("aot_img_hits" in jit_c and "ish_aot_hits_for_image" in jit_c,
      "the engine counts hits per attached image")
check("ish_aot_attached_path" in aot_h and "ish_aot_hits_for_image" in aot_h,
      "per-image diagnostics are declared in aot.h")

print(f"\n{checks} checks passed")
