#!/usr/bin/env python3
"""Exercise production keyboard host, SelfSizingCell and MessageListLayout on iOS.

The list coordinator/VM and Markdown renderer are NOT part of this fixture.
Real background streaming on the complete application still needs device checks.
Use --prepare-only DIR to inspect the exact assembled simulator source on Linux.
"""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
PATHS = [
    "Views/Chat/ChatKeyboardViewport.swift",
    "Agent/MessageList/MessageListInfrastructure.swift",
    "Agent/MessageList/MessageListLayout.swift",
    "scripts/ForegroundRefreshHarness.swift",
]


def prepare(work):
    work.mkdir(parents=True, exist_ok=True)
    sources = [(ROOT / name).read_text(encoding="utf-8") for name in PATHS]
    cell_source = sources[1].split("// MARK: - NoAnimationCollectionView", 1)[0]
    source = work / "ForegroundRefresh.swift"
    source.write_text("\n".join([sources[0], cell_source, sources[2], sources[3]]), encoding="utf-8")
    (work / "sources.json").write_text(json.dumps({
        "sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in PATHS},
        "scope": "Unchanged production host, cell, layout. Fixture logger, exception bridge and message data. No production VM/coordinator/Markdown, no device IME/performance proof.",
    }, indent=2) + "\n", encoding="utf-8")
    return source


def run(work):
    source = prepare(work)
    app = work / "ForegroundRefresh.app"
    app.mkdir()
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-parse-as-library", "-swift-version", "5",
                    "-target", f"{platform.machine()}-apple-ios16.0-simulator", "-sdk", sdk,
                    str(source), "-o", str(app / "ForegroundRefresh")], check=True)
    with (app / "Info.plist").open("wb") as out:
        plistlib.dump(dict(CFBundleIdentifier="com.ze.foreground-refresh-checks", CFBundleExecutable="ForegroundRefresh",
                          CFBundleName="ForegroundRefresh", CFBundlePackageType="APPL", CFBundleVersion="1",
                          CFBundleShortVersionString="1.0", MinimumOSVersion="16.0", UIDeviceFamily=[1],
                          UILaunchScreen={}), out)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    devices = [d for runtime, rows in inventory["devices"].items() if "iOS" in runtime
               for d in rows if d["name"].startswith("iPhone")]
    if not devices:
        raise RuntimeError("No available iPhone simulator")
    device = next((d for d in devices if d["state"] == "Booted"), devices[0])
    udid = device["udid"]
    if device["state"] != "Booted":
        subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
    bundle = "com.ze.foreground-refresh-checks"
    subprocess.run(["xcrun", "simctl", "install", udid, str(app)], check=True)
    data = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, bundle, "data"], text=True).strip())
    result_path = data / "Documents/fg-refresh-result.json"
    result_path.unlink(missing_ok=True)
    subprocess.run(["xcrun", "simctl", "launch", udid, bundle], check=True)
    deadline = time.monotonic() + 45
    while not result_path.exists():
        if time.monotonic() >= deadline:
            raise RuntimeError("Simulator checks did not produce a result within 45s")
        time.sleep(0.2)
    result = json.loads(result_path.read_text())
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result["success"]:
        raise RuntimeError(result["error"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-only", type=Path, metavar="DIR")
    args = parser.parse_args()
    if args.prepare_only:
        print(prepare(args.prepare_only))
    elif not shutil.which("xcrun"):
        print("SKIP: iOS runtime checks require Xcode and an iPhone simulator; no simulator assertions ran.")
    else:
        with tempfile.TemporaryDirectory(prefix="fg-refresh-") as directory:
            run(Path(directory))
