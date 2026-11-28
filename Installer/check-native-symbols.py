#!/usr/bin/env python3
"""Inspect real archives using the active Rust toolchain's matching LLVM reader."""
import argparse
from pathlib import Path
import subprocess

SYMBOLS = ("ze_connection_new", "ze_connection_cancel", "ze_connection_free",
           "ze_connection_run", "ze_connection_string_free")


def required_symbols(text, apple):
    defined = set()
    for line in text.splitlines():
        fields = line.split()
        # llvm-nm BSD format: address, type, symbol. Require an external text
        # definition, never an undefined reference, local symbol or substring.
        if len(fields) >= 3 and fields[-2] == "T":
            defined.add(fields[-1])
    prefix = "_" if apple else ""
    return [prefix + name for name in SYMBOLS if prefix + name not in defined]


def llvm_nm():
    subprocess.run(["rustup", "component", "add", "llvm-tools-preview"], check=True)
    sysroot = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    version = subprocess.check_output(["rustc", "-vV"], text=True)
    host = next(line.removeprefix("host: ") for line in version.splitlines() if line.startswith("host: "))
    tool = sysroot / "lib/rustlib" / host / "bin/llvm-nm"
    if not tool.is_file():
        raise RuntimeError("Active Rust toolchain has no llvm-nm: " + str(tool))
    return tool, version


def check(library, evidence, apple=True):
    evidence.mkdir(parents=True, exist_ok=True)
    tool, version = llvm_nm()
    (evidence / "symbol-toolchain.txt").write_text(version + "llvm-nm: " + str(tool) + "\n" +
        subprocess.check_output([str(tool), "--version"], text=True))
    output = evidence / (library.parent.parent.name + "-symbols.txt")
    command = [str(tool), "--extern-only", "--defined-only", "--format=bsd", str(library)]
    with output.open("w") as log, (evidence / (output.stem + "-stderr.log")).open("w") as errors:
        subprocess.run(command, stdout=log, stderr=errors, check=True)
    missing = required_symbols(output.read_text(), apple)
    if missing:
        raise RuntimeError("Missing exported text definitions: " + ", ".join(missing))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--elf", action="store_true", help="Linux local verification of the same reader")
    args = parser.parse_args()
    check(args.library.resolve(), args.evidence.resolve(), apple=not args.elf)


if __name__ == "__main__":
    main()
