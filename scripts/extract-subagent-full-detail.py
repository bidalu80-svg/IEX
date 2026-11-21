#!/usr/bin/env python3
"""Fetch pinned upstream declarations; never redraw a reference card locally."""
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from search_harness_support import search_support
import urllib.request

COMMIT = "1a71df0f381cefde80bf912b723de6f9831bc177"
REPO = "OpenMinis/OpenMinis"
ROOT = pathlib.Path(__file__).resolve().parents[1]
production_only = sys.argv[1:2] == ["--production-only"]
destination, app, evidence = map(pathlib.Path, sys.argv[(2 if production_only else 1):][:3])
cache = destination.parent / ("subagent-reference-" + COMMIT)
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

def write_production():
    local_views_path = ROOT / "Views/Chat/ZeSubAgentViews.swift"
    local_models_path = ROOT / "Agent/Chat/ZeSubAgentCoordinator.swift"
    local_views = local_views_path.read_text(encoding="utf-8")
    local_models = local_models_path.read_text(encoding="utf-8")
    local_parts = ["import SwiftUI\nimport UIKit\nimport Combine\nimport Foundation\n",
        search_support(ROOT),
        section(local_models, "enum ZeSubAgentStatus:", "/// Owns a bounded child-agent tree"),
        section(local_views, "enum ZeSubAgentTheme {", "/// Compact, native iOS dock"),
        section(local_views, "enum ZeSubAgentPresentation {", "struct ZeSubAgentDetailView:"),
        section(local_views, "struct ZeSubAgentDetailContent:", "struct ZeSubAgentTranscriptScrollStyle:"),
        (ROOT / "scripts/SubAgentFullDetailHarness.swift").read_text(encoding="utf-8")]
    local_destination = destination.with_name("ZeSubAgentFullDetailProduction.swift")
    local_destination.parent.mkdir(parents=True, exist_ok=True)
    local_destination.write_text("\n".join(local_parts), encoding="utf-8")
    print(local_destination)
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in [local_views_path, local_models_path]}

if production_only:
    write_production()
    sys.exit(0)

cache.mkdir(parents=True, exist_ok=True)
views = fetch("src/ios/Views/Chat/HelperBlockView.swift")
assert manifest["sources"]["src/ios/Views/Chat/HelperBlockView.swift"]["gitBlob"] == "2d0cf894c662a4a8e9f2ed2a6f07c0ce1163a47d"
identity = fetch("src/ios/Agent/Jobs/HelperModelIdentity.swift")
detail = fetch("src/ios/Views/Chat/AIChatView/Sheets/SubAgentRunDetail.swift")
search_root = "src/ios/Agent/MessageList/CollectionViewMessageListV3/Search/"
parts = ["import SwiftUI\nimport UIKit\nimport Combine\nimport Foundation\n",
         section(views, "struct HelperBlockInfo {", "// MARK: - Inline block"),
         views[views.index("struct HelperDetailCard:"):],
         section(identity, "struct HelperModelIdentity:", "// MARK: - Construction from live config"),
         section(detail, "// BEGIN SubAgentRunDigest", "/// [T-subagent-detail-rich] A course correction"),
         detail[detail.index("// MARK: - Summary chips"):],
         fetch("src/ios/Views/Chat/AIChatView/Support/ChatColors.swift"),
         (ROOT / "scripts/SubAgentFullDetailHarness.swift").read_text(encoding="utf-8")]
manifest["scope"] = "Unmodified complete HelperDetailCard, digest extraction, run clock and detail subviews. Session/job data are fixtures. Markdown, images and thinking badge are absent and fail if reached; no action API is exercised."
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

manifest["zeSources"] = write_production()
(evidence / "upstream-sources.json").write_text(json.dumps(manifest,indent=2),encoding="utf-8")
