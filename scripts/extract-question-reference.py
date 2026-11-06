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
cache = destination.parent / ("question-reference-" + COMMIT)
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

views = fetch("src/ios/Views/Chat/UserAskCardView.swift")
assert manifest["sources"]["src/ios/Views/Chat/UserAskCardView.swift"]["gitBlob"] == "a25b5871a124a0f639469c6ef516a530d7fc4239", "Pinned reference view changed"
core = fetch("src/ios/Agent/Chat/UserAskCore.swift")
colors = fetch("src/ios/Views/Chat/AIChatView/Support/ChatColors.swift")
center = fetch("src/ios/Agent/Chat/UserAskCenter.swift")
recommended = section(center, "    static func preselectRecommended(", "    // MARK: - Dismissal")
search_root = "src/ios/Agent/MessageList/CollectionViewMessageListV3/Search/"
units = fetch(search_root + "ChatSearchUnits.swift")
# The miniature uses the original pure summary rules and original render methods;
# only its dependency adapter is supplied by the harness.
tile_models = section(views, "struct UserAskSummaryRow:", "// END UserAskSummary")
tile_methods = section(views, "    private func richTile(", "    /// The plain list:")
tile_view = """
@MainActor struct ReferenceQuestionThumbnail: View {
    let ask: PendingAsk
    let resolved: Bool
    private var t: UserAskTypography { .current }
    static let tileSize = CGSize(width: 100, height: 65)
    var body: some View {
        if resolved {
            richTile(UserAskSummary.resolvedTile(ask.questions, results: [(.answered, ["请求参数兼容", "工具卡片与滚动"])]), tint: .accentColor)
        } else {
            richTile(UserAskSummary.pendingTile(questions: ask.questions, current: ask.currentIndex, answer: ask.answers[ask.currentIndex]), tint: .accentColor)
        }
    }
""" + tile_methods + "}\n"
parts = ["import SwiftUI\nimport UIKit\nimport Combine\nimport Foundation\n", core,
         section(views, "enum UserAskCardModel {", "// MARK: - Card"),
         section(views, "enum UserAskPendingLayoutCache {", "// MARK: - Summary (mini preview tile + tool sheet)"),
         tile_models, tile_view, colors, fetch(search_root + "ChatSearchEngine.swift"), fetch(search_root + "ChatSearchHighlights.swift"),
         "enum ChatSearchDisplayText {\n" + section(units, "    nonisolated static func userAskTopic", "// MARK: - Snapshot"),
         (ROOT / "scripts/QuestionReferenceHarness.swift").read_text(encoding="utf-8").replace("    // UPSTREAM_PRESELECT_RECOMMENDED", recommended)]
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
