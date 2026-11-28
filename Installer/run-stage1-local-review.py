#!/usr/bin/env python3
"""Run all local verification against one committed tree. Never push or run CI."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT).decode().strip()


def manifest():
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
    return {name.decode(): hashlib.sha256((ROOT / name.decode()).read_bytes()).hexdigest()
            for name in names if name and (ROOT / name.decode()).is_file()}


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args(); evidence = args.evidence.resolve()
    if evidence.exists():
        parser.error("Use a fresh evidence directory")
    if git("status", "--porcelain", "--untracked-files=no"):
        parser.error("Commit all tracked changes before verification")
    evidence.mkdir(parents=True)
    before = manifest(); commit = git("rev-parse", "HEAD"); tree = git("rev-parse", "HEAD^{tree}")
    write(evidence / "source-sha256.json", before)
    result = {"status": "FAIL", "sourceCommit": commit, "sourceTree": tree, "stages": [],
              "appleCompilation": "NOT TESTED", "device": "NOT TESTED"}
    write(evidence / "environment.json", {"sourceCommit": commit, "sourceTree": tree,
          "python": sys.version, "policy": "No tracked changes or HEAD movement during this run"})
    commands = [
        ("core-and-19-runner-tests-and-two-mutations", [sys.executable, "Installer/run-review.py", "--evidence", str(evidence / "core")]),
        ("connection-tests-and-four-mutations", [sys.executable, "Installer/run-connection-review.py", "--evidence", str(evidence / "connection")]),
        ("rust-protocol-tests", ["cargo", "test", "--locked", "--manifest-path", "Installer/Native/Cargo.toml"]),
        ("production-swift-rust-abi", ["bash", "Installer/test-native-abi.sh", str(evidence / "native-abi")]),
    ]
    try:
        # No logging subscriber may be added without stripping upstream payloads.
        # Scan the complete integrated Rust source/Cargo and host adapters. The
        # copied upstream tracing statements remain documented, not activated.
        integration = list((ROOT / "Installer/Native/src").rglob("*.rs"))
        integration += list((ROOT / "InstallerHost").glob("*.swift")) + [ROOT / "Installer/Native/Cargo.toml"]
        prohibited = re.compile(r"tracing[_-]subscriber|set_global_default|set_default|with_default|SubscriberInitExt")
        if any(prohibited.search(path.read_text()) for path in integration):
            raise RuntimeError("Native logging guard needs review before enabling a subscriber")
        result["loggingGuard"] = "PASS"
        for name, command in commands:
            with (evidence / (name + ".log")).open("w") as log:
                code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False).returncode
            result["stages"].append({"name": name, "command": command, "exitCode": code})
            print(name + ": exit " + str(code), flush=True)
        stable = git("rev-parse", "HEAD") == commit and manifest() == before and not git("status", "--porcelain", "--untracked-files=no")
        result["treeUnchanged"] = stable
        if not stable:
            raise RuntimeError("HEAD or tracked sources changed during verification")
        result["status"] = "PASS" if all(s["exitCode"] == 0 for s in result["stages"]) else "FAIL"
    except Exception as error:
        result["error"] = str(error)
    finally:
        write(evidence / "summary.json", result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
