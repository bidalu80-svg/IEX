#!/usr/bin/env python3
"""Same reference scenarios, actual shipping bar/control declarations."""
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
destination, app, evidence = map(pathlib.Path, sys.argv[1:4])
sources = {}
def read(path):
    data = (ROOT / path).read_bytes()
    sources[path] = hashlib.sha256(data).hexdigest()
    return data.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]
search = read("Views/Chat/ChatSearch.swift")
bar = read("Views/Chat/ChatSearchOverlay.swift")
share = read("Views/Chat/SessionExport/ChatShareSelectionView.swift")
colors = read("Views/Chat/AIChatView.swift")
engine = section(search, "// BEGIN chat-search-engine", "// END chat-search-engine")
palette = section(colors, "enum ChatColors {", "\n}\n") + "\n}"
controls = section(share, "private struct ChatShareFloatingButtonSurface:", "/// [T-share-opts-not-remembered] Starting values")
adapter = '''
func ShareLocalized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
struct ChatSearchHit {}
@MainActor final class ChatSearchModel: ObservableObject {
    @Published var query = ""
    @Published var hits: [ChatSearchHit] = []
    @Published var currentIndex = 0
    @Published var isTruncated = false
    @Published var isSearching = false
    @Published var notice: String?
    @Published var focusRequest = 0
    var normalizedQuery: String { ChatSearchMatcher.normalizedQuery(query) }
    func step(_ direction: Int) { preconditionFailure("UI fixture never invokes search") }
    func deactivate() { preconditionFailure("UI fixture never invokes search") }
}
'''
harness = read("scripts/ShareSearchReferenceHarness.swift")
begin = harness.index("@MainActor final class ChatSearchController:")
end = harness.index("@MainActor private struct ShareSearchReferenceScene:")
harness = harness[:begin] + adapter + harness[end:]
harness = harness.replace("ChatSearchController", "ChatSearchModel")
harness = harness.replace("ChatSearchBar(search: search, onDone: {})", "ChatSearchOverlay(model: search, onJump: { _ in }, onClose: {})")
harness = harness.replace('search.matchCount = ["search-empty", "search-none", "search-loading"].contains(scenario) ? 0 : scenario == "search-truncated" ? 2000 : 12', 'search.hits = Array(repeating: ChatSearchHit(), count: ["search-empty", "search-none", "search-loading"].contains(scenario) ? 0 : scenario == "search-truncated" ? 2000 : 12)')
harness = harness.replace("search.currentIndex = search.matchCount > 0 ? 2 : nil", "search.currentIndex = search.hits.isEmpty ? 0 : 2")
harness = harness.replace("search.notice = .wrappedToFirst", 'search.notice = String(localized: "Wrapped to the first result")').replace("search.notice = .wrappedToLast", 'search.notice = String(localized: "Wrapped to the last result")')
harness = harness.replace('"reference-', '"production-').replace('"reference-ui-result.json"', '"production-ui-result.json"')
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(["import SwiftUI\nimport UIKit\nimport Combine\n", engine, palette, bar, controls, harness]), encoding="utf-8")
catalog = json.loads(read("Localizable.xcstrings"))
translations = {k: e["localizations"]["zh-Hans"]["stringUnit"]["value"] for k, e in catalog["strings"].items() if "stringUnit" in e.get("localizations", {}).get("zh-Hans", {})}
def quote(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'
localization = app / "zh-Hans.lproj/Localizable.strings"
localization.parent.mkdir(parents=True, exist_ok=True)
localization.write_text("\n".join(f"{quote(k)} = {quote(v)};" for k, v in sorted(translations.items())), encoding="utf-8")
evidence.mkdir(parents=True, exist_ok=True)
(evidence / "production-sources.json").write_text(json.dumps({"sha256": sources, "scope": "Unmodified production search bar and share format control; fixture state. Not end-to-end search or export evidence."}, indent=2), encoding="utf-8")
print(destination)
