#!/usr/bin/env python3
"""Extract unchanged production views and generate a standalone UI test target."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1])
work.mkdir(parents=True, exist_ok=True)
sources = {}

def read(name):
    path = ROOT / name
    sources[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return path.read_text(encoding="utf-8")

brand = read("Views/Providers/ProviderBrandIcon.swift")
panel = read("Views/Chat/Voice/VoiceCallPanel.swift")
add = read("Views/Providers/AddProviderView.swift")
copilot = add[add.index("struct GitHubCopilotIcon: View {"):]
harness = read("scripts/VoiceCallUIHarness.swift")
(work / "VoiceCallUI.swift").write_text(brand + "\n" + panel + "\n" + copilot + "\n" + harness, encoding="utf-8")
assets = work / "Assets.xcassets"
assets.mkdir(exist_ok=True)
(assets / "Contents.json").write_text('{"info":{"version":1,"author":"xcode"}}')
for path in [*list((ROOT / "Assets.xcassets").glob("ProviderBrand*.imageset")), ROOT / "Assets.xcassets/WorkBuddy.imageset"]:
    shutil.copytree(path, assets / path.name, dirs_exist_ok=True)
    for asset in path.rglob("*"):
        if asset.is_file(): sources[str(asset.relative_to(ROOT))] = hashlib.sha256(asset.read_bytes()).hexdigest()
(work / "sources.json").write_text(json.dumps({"sources": sources, "scope": "Unchanged production panel and brand artwork; fixture state; XCTest real taps. No microphone/model/audio-quality claim."}, indent=2))
spec = importlib.util.spec_from_file_location("share_driver", ROOT / "scripts/share-xcui-driver.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.DRIVER = read("scripts/VoiceCallUITests.swift")
module.write_project(work / "driver")
print(work)
