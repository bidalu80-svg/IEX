import Foundation
import UIKit

private let logger = AppLogger(category: "BrowserTabPool")

extension BrowserTabPool {
    // MARK: - Tab Overview Snapshots

    /// Last overview thumbnail captured for `id`, or nil when the card should
    /// fall back to favicon + title.
    func tabSnapshot(forTabId id: Int) -> UIImage? {
        tabSnapshots[id]
    }

    /// Capture a thumbnail of `tabId`'s visible page. Called from the
    /// `selectedTabId` setter (the outgoing tab is still the visible one —
    /// SwiftUI only swaps the web view on its next update) and by the overview
    /// opener for the tab currently on screen. The capture itself never
    /// changes the webView frame/viewport (see `captureThumbnail`).
    func captureTabSnapshot(tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let manager = tab.manager
        manager.captureThumbnail { [weak self] image in
            guard let image else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Ignore a late capture from a tab that was closed or whose
                // WKWebView was rebuilt before the snapshot finished.
                guard self.tabs.contains(where: { $0.id == tabId && $0.manager === manager }) else { return }
                self.storeTabSnapshot(image, forTabId: tabId)
            }
        }
    }

    func discardTabSnapshot(forTabId id: Int) {
        guard tabSnapshots[id] != nil || tabSnapshotOrder.contains(id) else { return }
        tabSnapshots.removeValue(forKey: id)
        tabSnapshotOrder.removeAll { $0 == id }
    }

    /// Called after `didFinish`. A short delay lets the first frame paint and
    /// keeps the capture clear of the sheet's presentation/resize animation;
    /// the capture itself is frame-preserving either way.
    func scheduleTabSnapshotAfterLoad(manager: BrowserUseManager) {
        guard let tabId = tabs.first(where: { $0.manager === manager })?.id else { return }
        Task { @MainActor [weak self, weak manager] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, let manager else { return }
            guard self.tabs.contains(where: { $0.id == tabId && $0.manager === manager }) else { return }
            self.captureTabSnapshot(tabId: tabId)
        }
    }

    // MARK: - Idle Eviction

    func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evictIdleTabs()
            }
        }
    }

    // MARK: - Registry-driven Eviction

    /// Evict a specific tab on behalf of the registry (cross-pool reclaim).
    /// Saves the URL like the idle timer does so it restores on next use.
    /// Caller has already confirmed the tab is non-inUse.
    func evictTabForRegistry(id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        guard !tab.inUse else { return } // safety net
        let url = tab.manager.currentURL
        if !url.isEmpty {
            savedURLs[id] = url
        }
        tabs.remove(at: idx)
        if selectedTabId == id {
            selectedTabId = tabs.first?.id ?? 0
        }
        persistURLs()
        logger.info("Evicted tab \(id) at registry request (url=\(url.prefix(60)))")
    }

    /// Preempt an in-use tab on behalf of the registry. Saves the URL,
    /// stops any ongoing load, and tears the WKWebView down. The agent
    /// driving this tab is currently `await`ing inside execute() — it
    /// will throw or return whatever WebKit produces when its webView is
    /// dropped. The tab id is added to `preemptedTabIds` so the agent's
    /// next call into `execute(action:)` returns a friendly retry hint
    /// instead of silently re-creating the tab.
    func preemptTabForRegistry(id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        let url = tab.manager.currentURL
        if !url.isEmpty {
            savedURLs[id] = url
        }
        tab.manager.stopLoading()
        tabs.remove(at: idx)
        preemptedTabIds.insert(id)
        if selectedTabId == id {
            selectedTabId = tabs.first?.id ?? 0
        }
        persistURLs()
        logger.info("Preempted in-use tab \(id) at registry request (url=\(url.prefix(60)))")
    }

    /// Evict all non-inUse tabs in response to a memory warning. Returns
    /// the number evicted so the registry can log a single summary line.
    func evictAllIdleForMemoryWarning() -> Int {
        var evicted = 0
        tabs.removeAll { tab in
            guard !tab.inUse else { return false }
            let url = tab.manager.currentURL
            if !url.isEmpty {
                savedURLs[tab.id] = url
            }
            evicted += 1
            return true
        }
        if evicted > 0 {
            if !tabs.contains(where: { $0.id == selectedTabId }) {
                selectedTabId = tabs.first?.id ?? 0
            }
            persistURLs()
        }
        return evicted
    }

    // MARK: - Disk Persistence

    /// On-disk model for saved tab URLs.
    private struct PersistedTabs: Codable {
        var tabURLs: [Int: String]    // tab ID → URL (live + evicted)
        var selectedTabId: Int
        /// Session-scoped viewport override. nil = no override, fall back to global.
        var sessionViewportWidth: Int?
        var sessionViewportHeight: Int?
    }

    nonisolated private static func storeURL(for sessionId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZeChat/browser_tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sessionId).json")
    }

    /// Collect all known URLs (live tabs + savedURLs) and write to disk.
    func persistURLs() {
        guard let sessionId else { return }
        var allURLs = savedURLs
        for tab in tabs {
            let url = tab.manager.currentURL
            if !url.isEmpty {
                allURLs[tab.id] = url
            }
        }
        // A session viewport override is worth persisting even when there are
        // no tabs yet, so set_viewport survives an empty-session reopen.
        let hasSessionViewport = sessionViewportWidth > 0 && sessionViewportHeight > 0
        guard !allURLs.isEmpty || hasSessionViewport else {
            // Nothing to persist — remove file if it exists
            let url = Self.storeURL(for: sessionId)
            try? FileManager.default.removeItem(at: url)
            return
        }
        let data = PersistedTabs(
            tabURLs: allURLs,
            selectedTabId: selectedTabId,
            sessionViewportWidth: hasSessionViewport ? sessionViewportWidth : nil,
            sessionViewportHeight: hasSessionViewport ? sessionViewportHeight : nil
        )
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: Self.storeURL(for: sessionId), options: .atomic)
            logger.info("Persisted \(allURLs.count) tab URL(s) for session \(sessionId.prefix(8))")
        } catch {
            logger.error("Failed to persist tab URLs: \(error.localizedDescription)")
        }
    }

    /// Load persisted tab URLs into savedURLs for lazy restoration.
    func loadPersistedURLs() {
        guard let sessionId else { return }
        let url = Self.storeURL(for: sessionId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let persisted = try JSONDecoder().decode(PersistedTabs.self, from: data)
            // Merge persisted URLs into savedURLs (don't overwrite already-live tabs)
            let liveIds = Set(tabs.map(\.id))
            for (tabId, tabURL) in persisted.tabURLs where !liveIds.contains(tabId) {
                savedURLs[tabId] = tabURL
            }
            if !tabs.contains(where: { $0.id == persisted.selectedTabId }) {
                selectedTabId = persisted.selectedTabId
            }
            if let w = persisted.sessionViewportWidth, let h = persisted.sessionViewportHeight,
               w > 0, h > 0 {
                sessionViewportWidth = w
                sessionViewportHeight = h
                // Re-apply to any live tabs that predate load (rare: usually
                // sessionId is set before tabs exist, but be safe).
                if !tabs.isEmpty {
                    applyViewportToAllTabs()
                }
            }
            logger.info("Loaded \(persisted.tabURLs.count) persisted tab URL(s) for session \(sessionId.prefix(8))")
        } catch {
            logger.error("Failed to load persisted tab URLs: \(error.localizedDescription)")
        }
    }

    /// Delete persisted tab data for a session (called on session delete).
    nonisolated static func deletePersistedData(for sessionId: String) {
        let url = storeURL(for: sessionId)
        try? FileManager.default.removeItem(at: url)
    }
}
