#!/usr/bin/env python3
"""Fetch pinned upstream declarations; never redraw a reference card locally."""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

COMMIT = "1a71df0f381cefde80bf912b723de6f9831bc177"
REPO = "OpenMinis/OpenMinis"
ROOT = pathlib.Path(__file__).resolve().parents[1]
destination = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
evidence = pathlib.Path(sys.argv[3])
cache = destination.parent / ("subagent-reference-" + COMMIT)
cache.mkdir(parents=True, exist_ok=True)
manifest = {"repository": REPO, "commit": COMMIT, "sources": {}, "rendering": "Unmodified upstream declarations; no replacement UI"}

def fetch(path):
    target = cache / pathlib.Path(path).name
    if not target.exists():
        endpoint = f"repos/{REPO}/contents/{path}?ref={COMMIT}"
        data = json.loads(subprocess.check_output(["gh", "api", endpoint], timeout=30))
        if data.get("content"):
            raw = base64.b64decode(data["content"])
        else:
            blob_data = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPO}/git/blobs/{data['sha']}"], timeout=30))
            raw = base64.b64decode(blob_data["content"])
        target.write_bytes(raw)
    raw = target.read_bytes()
    blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    manifest["sources"][path] = {"gitBlob": blob, "sha256": hashlib.sha256(raw).hexdigest()}
    return raw.decode("utf-8")

def section(source, start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]

views = fetch("src/ios/Views/Chat/HelperBlockView.swift")
assert manifest["sources"]["src/ios/Views/Chat/HelperBlockView.swift"]["gitBlob"] == "2d0cf894c662a4a8e9f2ed2a6f07c0ce1163a47d", "Pinned reference view changed"
identity = fetch("src/ios/Agent/Jobs/HelperModelIdentity.swift")
detail = fetch("src/ios/Views/Chat/AIChatView/Sheets/SubAgentRunDetail.swift")
assert manifest["sources"]["src/ios/Views/Chat/AIChatView/Sheets/SubAgentRunDetail.swift"]["gitBlob"] == "951e443e8bacaeeded68874a34ef59b25c29caea"
search_root = "src/ios/Agent/MessageList/CollectionViewMessageListV3/Search/"
parts = ["import SwiftUI\nimport UIKit\nimport Combine\nimport Foundation\n",
         section(views, "struct HelperBlockInfo {", "// MARK: - Tool live sheet content"),
         views[views.index("struct AgentDetailCard<"):],
         section(identity, "struct HelperModelIdentity:", "// MARK: - Construction from live config"),
         section(detail, "// BEGIN SubAgentRunDigest", "// END SubAgentRunDigest"),
         section(detail, "// MARK: - Summary chips", "// MARK: - Actions"),
         fetch("src/ios/Views/Chat/AIChatView/Support/ChatColors.swift"),
         fetch(search_root + "ChatSearchEngine.swift"), fetch(search_root + "ChatSearchHighlights.swift"),
         (ROOT / "scripts/SubAgentReferenceHarness.swift").read_text(encoding="utf-8")]
manifest["scope"] = "Original inline and raw thumbnail Views plus original stats/timeline sections with a fixture digest; not the complete detail sheet or parent floating bar rim. Runtime action fixtures fail if invoked."
destination.write_text("\n".join(parts), encoding="utf-8")
catalog = json.loads(fetch("src/ios/Localizable.xcstrings"))
translations = {k: e["localizations"]["zh-Hans"]["stringUnit"]["value"] for k,e in catalog["strings"].items() if "stringUnit" in e.get("localizations",{}).get("zh-Hans",{})}
def quote(s): return '"' + s.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n').replace('\r','\\r').replace('\t','\\t') + '"'
localization = app / "zh-Hans.lproj/Localizable.strings"
localization.parent.mkdir(parents=True, exist_ok=True)
localization.write_text("\n".join(f"{quote(k)} = {quote(v)};" for k,v in sorted(translations.items()))+"\n",encoding="utf-8")
evidence.mkdir(parents=True, exist_ok=True)
(evidence / "upstream-sources.json").write_text(json.dumps(manifest,indent=2),encoding="utf-8")
print(destination)
