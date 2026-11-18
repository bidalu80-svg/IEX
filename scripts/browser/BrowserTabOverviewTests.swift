#!/usr/bin/env swift
// [T-browser-tab-overview] P2 acceptance pins for the bottom share button and
// the tab-overview grid.
//
// These checks are static: they pin the red lines that are easy to regress
// without a device (the thumbnail capture must not resize the WKWebView, the
// snapshot cache must stay bounded, and the overview must keep its five
// interactions). The behavioural parts that need WebKit are verified on device.
//
// Run: swift BrowserTabOverviewTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
/// The declaration starting at `marker`, through its matching closing brace.
func block(_ src: String, _ marker: String) -> String {
    guard let start = src.range(of: marker) else { return "/* MISSING: \(marker) */" }
    var depth = 0
    var i = start.lowerBound
    var seenOpen = false
    while i < src.endIndex {
        let c = src[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" {
            depth -= 1
            if seenOpen && depth == 0 { return String(src[start.lowerBound...i]) }
        }
        i = src.index(after: i)
    }
    return "/* UNTERMINATED: \(marker) */"
}

let manager = source("Agent/BrowserUse/BrowserUseManager.swift")
let pool = source("Agent/BrowserUse/BrowserTabPool.swift")
let sheet = source("Agent/BrowserUse/BrowserSheetView.swift")
let overview = source("Agent/BrowserUse/BrowserTabOverviewView.swift")

print("\n1. Thumbnail capture preserves the viewport (red line §4.5)")
let thumbnail = block(manager, "    func captureThumbnail(completion: @escaping (UIImage?) -> Void) {")
check("captureThumbnail exists", !thumbnail.isEmpty && !thumbnail.hasPrefix("/*"))
check("it never assigns webView.frame",
      !thumbnail.contains("webView.frame") && !thumbnail.contains("webView.bounds ="))
check("it never calls the viewport-restoring / rebuilding paths",
      !thumbnail.contains("restoreViewportFrame") && !thumbnail.contains("setViewport"))
check("it snapshots the current bounds as-is",
      thumbnail.contains("webView.bounds.size") && thumbnail.contains("configuration.rect"))
check("it downsamples through WKSnapshotConfiguration",
      thumbnail.contains("WKSnapshotConfiguration") && thumbnail.contains("snapshotWidth"))
check("a completed load asks the pool for a fresh thumbnail",
      manager.contains("self.onPageLoadFinished?()"))

print("\n2. Snapshot cache (red line §4.3)")
let store = block(pool, "    private func storeTabSnapshot(")
check("the cap is exactly maxTabs", pool.contains("static let maxTabSnapshots = BrowserTabPool.maxTabs"))
check("old entries are evicted above the cap",
      store.contains("while tabSnapshotOrder.count > Self.maxTabSnapshots")
      && store.contains("tabSnapshots.removeValue"))
check("the cache never touches disk",
      !store.contains("FileManager") && !store.contains("write(to:"))
let idleEviction = block(pool, "    private func evictIdleTabs() {")
check("idle eviction keeps the tab's last snapshot", !idleEviction.contains("discardTabSnapshot"))
check("closing a tab does discard its snapshot",
      block(pool, "    func closeTab(id: Int) -> BrowserActionResult {").contains("discardTabSnapshot(forTabId: id)"))
check("every selection change captures the outgoing tab first",
      pool.contains("if oldValue != selectedTabId {")
      && pool.contains("captureTabSnapshot(tabId: oldValue)"))

print("\n3. Bottom share button")
check("the bottom bar has a share button", sheet.contains("systemName: \"square.and.arrow.up\""))
check("share is disabled while the agent drives",
      sheet.contains(".disabled(isAgentControlled || (manager?.currentURL.isEmpty ?? true))"))
check("share content is frozen before presentation",
      sheet.contains("BrowserSharePayload(title: title, url: url)"))
check("share body is the title plus the URL",
      overview.contains("return trimmed.isEmpty ? url.absoluteString : \"\\(trimmed)\\n\\(url.absoluteString)\""))

print("\n4. Tab count button and overview")
check("the old read-only count is gone",
      !sheet.contains("Text(\"\\(pool.tabs.count)/\\(BrowserTabPool.maxTabs)\")"))
check("the tab count is a button that opens the full-page overview",
      sheet.contains("showTabOverview = true")
      && sheet.contains(".fullScreenCover(isPresented: $showTabOverview)")
      && sheet.contains("RoundedRectangle(cornerRadius: 5"))
check("the overview is a two-column LazyVGrid",
      overview.contains("LazyVGrid(columns: columns")
      && overview.components(separatedBy: "GridItem(.flexible()").count - 1 == 2)
check("it has + and the Chinese Done title in the top bar",
      overview.contains("systemName: \"plus\"") && overview.contains("Button(\"完成\")") && overview.contains(".navigationTitle(\"标签页\")"))
check("each card closes its own tab", overview.contains("pool.closeTab(id: tab.id)"))
check("tapping a card switches and dismisses",
      overview.contains("pool.selectedTabId = tab.id") && overview.contains("dismiss()"))
check("the current tab gets an accent outline",
      overview.contains("stroke(isSelected ? Color.accentColor"))
check("cards read the pool's bounded snapshot cache",
      overview.contains("pool.tabSnapshot(forTabId: tab.id)"))
check("no-snapshot cards fall back to favicon + title",
      overview.contains("thumbnailPlaceholder")
      && overview.contains("FaviconView(")
      && overview.contains("tabTitle(for: tab)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
