#!/usr/bin/env python3
"""Pinned reference search bar and share format control, never replacement UI."""
import base64
import hashlib
import json
import pathlib
import subprocess
import sys

COMMIT = "1a71df0f381cefde80bf912b723de6f9831bc177"
ROOT = pathlib.Path(__file__).resolve().parents[1]
destination, app, evidence = map(pathlib.Path, sys.argv[1:4])
cache = destination.parent / ("share-search-reference-" + COMMIT)
cache.mkdir(parents=True, exist_ok=True)
manifest = {"repository": "OpenMinis/OpenMinis", "commit": COMMIT, "sources": {},
            "scope": "Original complete ChatSearchBar and ChatShareFormatSwitch; fixture state only. The share selection page, preview toolbar, export content and navigation are NOT covered by this component reference.",
            "compatibility": "Only a compiler >=6.2 guard is added around the original iOS26 glassEffect branch; the pre-iOS26 material branch is verbatim."}

def fetch(path):
    target = cache / pathlib.Path(path).name
    if not target.exists():
        data = json.loads(subprocess.check_output(["gh", "api", f"repos/OpenMinis/OpenMinis/contents/{path}?ref={COMMIT}"], timeout=45))
        if not data.get("content"):
            data = json.loads(subprocess.check_output(["gh", "api", f"repos/OpenMinis/OpenMinis/git/blobs/{data['sha']}"], timeout=45))
        target.write_bytes(base64.b64decode(data["content"]))
    raw = target.read_bytes()
    manifest["sources"][path] = {"gitBlob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(), "sha256": hashlib.sha256(raw).hexdigest()}
    return raw.decode("utf-8")

def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

bar = fetch("src/ios/Views/Chat/AIChatView/Overlays/ChatSearchBar.swift")
engine = fetch("src/ios/Agent/MessageList/CollectionViewMessageListV3/Search/ChatSearchEngine.swift")
controller = fetch("src/ios/Agent/MessageList/CollectionViewMessageListV3/Search/ChatSearchController.swift")
colors = fetch("src/ios/Views/Chat/AIChatView/Support/ChatColors.swift")
share = fetch("src/ios/Views/Chat/ChatShareSelectionView.swift")
surface = section(share, "private struct ChatShareFloatingButtonSurface:", "/// The preview's floating")
# Swift 6.0 SDKs do not know glassEffect even in an availability branch.
# Retain both source branches, selected by compiler capability only.
surface = surface.replace("        if #available(iOS 26.0, *) {", "        #if compiler(>=6.2)\n        if #available(iOS 26.0, *) {")
legacy = section(share, "        } else {\n            content\n                .buttonStyle(.plain)", "\n        }\n    }\n}").split("        } else {\n", 1)[1]
surface = surface.replace("\n    }\n}", "\n        #else\n" + legacy + "\n        #endif\n    }\n}")
notice = section(controller, "    static func noticeText(", "\n}\n")
parts = ["import SwiftUI\nimport UIKit\nimport Combine\n", engine, colors,
         section(bar, "struct ChatSearchBar:", "/// [T-in-chat-search] The chat page's side"),
         surface, section(share, "private struct ChatShareFormatSwitch:", "/// [T-share-opts-not-remembered] Starting values"),
         (ROOT / "scripts/ShareSearchReferenceHarness.swift").read_text(encoding="utf-8").replace("    // ORIGINAL_NOTICE_TEXT", notice)]
destination.write_text("\n".join(parts), encoding="utf-8")
catalog = json.loads(fetch("src/ios/Localizable.xcstrings"))
translations = {k: e["localizations"]["zh-Hans"]["stringUnit"]["value"] for k, e in catalog["strings"].items() if "stringUnit" in e.get("localizations", {}).get("zh-Hans", {})}
def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
localization = app / "zh-Hans.lproj/Localizable.strings"
localization.parent.mkdir(parents=True, exist_ok=True)
localization.write_text("\n".join(f"{quote(k)} = {quote(v)};" for k, v in sorted(translations.items())), encoding="utf-8")
evidence.mkdir(parents=True, exist_ok=True)
(evidence / "upstream-sources.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(destination)
