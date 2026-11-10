#!/usr/bin/env python3
"""Compile unchanged production chrome, brand views and session resolution."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import sys

root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1])
catalog = Path(sys.argv[2])
sources = {}

def read(name):
    path = root / name
    sources[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return path.read_text(encoding="utf-8")

chat = read("Views/Chat/AIChatView.swift")
palette = chat[chat.index("enum ChatColors {"):]
palette = palette[:palette.index("\n}") + 2]
chrome = chat.split("// BEGIN ProviderChatChrome", 1)[1].split("// END ProviderChatChrome", 1)[0]
picker = read("Views/Providers/SessionModelPicker.swift")
resolution = picker[picker.index("struct SessionModelDisplay {"):]
add = read("Views/Providers/AddProviderView.swift")
copilot = add[add.index("struct GitHubCopilotIcon: View {"):]
brand = read("Views/Providers/ProviderBrandIcon.swift")
harness = read("scripts/ProviderChatChromeHarness.swift")
instances = read("Views/Providers/ProviderInstancesView.swift")
instance_row = instances.split("private struct InstanceRow: View {", 1)[1].split("// MARK: - Shadow Voice Row", 1)[0]
instance_row = "private struct InstanceRow: View {" + instance_row
types = read("Providers/ProviderTypes.swift")
def member(text, start):
    section = text[text.index(start):]
    return section[:section.index("\n    }") + len("\n    }")]
type_extensions = "extension ProviderType {\n" + member(types, "    var displayName: String {") + "\n" + member(types, "    var pickerSubtitle: String {") + "\n}\n"
type_section = add.split("private var typePickerSection: some View {", 1)[1]
row_body = type_section.split("} label: {", 1)[1].split("\n                }\n            }\n        } header:", 1)[0]
add_row = "private struct ProductionAddProviderRow: View {\nlet type: ProviderType\nvar body: some View {\n" + row_body + "\n}\n"
for name in ["providerPickerLabel", "providerIcon", "providerColor"]:
    add_row += member(add, "    private func " + name + "(") + "\n"
add_row += "}\n"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("import SwiftUI\nimport UIKit\n" + palette + "\n" + copilot + "\n" + brand + "\n" + resolution + "\n" + chrome + "\n" + type_extensions + instance_row + add_row + harness, encoding="utf-8")
catalog.mkdir(parents=True, exist_ok=True)
(catalog / "Contents.json").write_text('{"info":{"version":1,"author":"xcode"}}')
assets = list((root / "Assets.xcassets").glob("ProviderBrand*.imageset"))
assets.append(root / "Assets.xcassets/WorkBuddy.imageset")
for asset in assets:
    shutil.copytree(asset, catalog / asset.name, dirs_exist_ok=True)
    for path in asset.rglob("*"):
        if path.is_file():
            sources[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
strings = json.loads(read("Localizable.xcstrings"))["strings"]
translations = {}
for key, value in strings.items():
    unit = value.get("localizations", {}).get("zh-Hans", {}).get("stringUnit")
    if unit:
        translations[key] = unit["value"]
localization = output.parent / "ProviderChromeLocalization/zh-Hans.lproj"
localization.mkdir(parents=True, exist_ok=True)
(localization / "Localizable.strings").write_bytes(plistlib.dumps(translations, fmt=plistlib.FMT_BINARY))
output.with_suffix(".sources.json").write_text(json.dumps({
    "sources": sources,
    "scope": "Production brand artwork, navbar chrome, provider badge and SessionModelDisplay. In-memory configuration fixtures; no account/network fixture claims.",
    "assetSets": len(assets)
}, indent=2), encoding="utf-8")
print(output)
