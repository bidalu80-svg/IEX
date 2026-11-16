#!/usr/bin/env swift
// [P2.5-download-toast] Static pins for the Minis-style download bar,
// preview routing and file sharing.
//
// Run: swift BrowserDownloadToastTests.swift
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
let sheet = source("Agent/BrowserUse/BrowserSheetView.swift")
let preview = source("Agent/BrowserUse/BrowserDownloadPreview.swift")

print("\n1. BrowserDownloadCenter stays the only state source")
let center = block(manager, "final class BrowserDownloadCenter: ObservableObject {")
check("entries keep the real Progress", center.contains("let progress: Progress"))
check("entries expose their on-disk file", center.contains("var fileURL: URL?") && center.contains("var localFileURL: URL?"))
check("toast follows newest active/unseen entry", center.contains("func toastEntry(for sessionId: String) -> Entry?"))
check("toast dismissal marks seen instead of deleting", center.contains("func markSeen(id: UUID)"))
check("the manager wires the real destination into the entry",
      manager.contains("fileURL: dest"))

print("\n2. Ring progress is real bytes, never invented")
let toast = block(sheet, "struct BrowserDownloadToast: View {")
check("toast binds to BrowserDownloadCenter", toast.contains("BrowserDownloadCenter.shared"))
check("ring reads the KVO progress observer",
      block(sheet, "private struct BrowserDownloadToastRow: View {").contains("DownloadProgressObserver(progress: entry.progress)"))
let ring = block(sheet, "private struct DownloadProgressRing: View {")
check("known total shows a real percentage",
      ring.contains("Int(max(0, min(1, fraction)) * 100)"))
check("unknown total uses an indeterminate spinner",
      ring.contains("indeterminate") && ring.contains("trim(from: 0, to: 0.24)"))
check("unknown total does not render a percentage",
      !block(sheet, "private struct BrowserDownloadToastRow: View {").contains("progress.total > 0 ? \"\\(Int"))
check("completed toast shows green check + size + tap hint",
      sheet.contains("checkmark.circle.fill") && sheet.contains("点按查看"))
check("failed toast shows red exclamation",
      sheet.contains("exclamationmark.circle.fill"))

print("\n3. Preview routing")
check("text/source files use the plain-text viewer",
      preview.contains("case .text") && preview.contains("BrowserPlainTextPreview"))
check("images / video / PDF / docs use QuickLook",
      preview.contains("QLPreviewController") && preview.contains("case .quickLook"))
check("unknown types are routed to share",
      preview.contains("case .shareOnly") && preview.contains("BrowserActivityView"))
check("preview page can share the file itself", preview.contains("ShareLink(item: url)"))
check("downloads panel has a share affordance",
      sheet.contains("share.and.arrow.up") || sheet.contains("square.and.arrow.up"))

print("\n4. Cancel vs dismiss semantics")
check("downloading x cancels through the existing onCancel path",
      block(sheet, "    private func dismissToast() {").contains("center.cancel(id: entry.id)"))
check("completed/failed x only marks seen",
      block(sheet, "    private func dismissToast() {").contains("center.markSeen(id: entry.id)"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
