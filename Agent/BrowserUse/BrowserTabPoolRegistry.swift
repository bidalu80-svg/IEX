import Foundation
import UIKit

private let registryLogger = AppLogger(category: "BrowserTabPoolRegistry")

/// Process-wide cap on live `WKWebView` tabs across all `BrowserTabPool`s.
///
/// Each tab keeps an out-of-process WebContent (~30-80 MB resident) plus
/// shared JS heap; under multi-session concurrency the per-pool `maxTabs=3`
/// cap doesn't bound total footprint, so heavy use trips iOS VM exhaustion
/// (`mach_vm_allocate_kernel failed` / `pmap_enter resource shortage`) which
/// surfaces as null-deref crashes inside WebCore. The registry coordinates
/// across pools so creating a tab in one session can reclaim an idle tab in
/// another.
@MainActor
final class BrowserTabPoolRegistry {
    static let shared = BrowserTabPoolRegistry()

    /// Hard cap on live tabs across the whole process. Roughly 3 concurrent
    /// sessions × ~2-3 active tabs each. Tunable here if profiling says
    /// otherwise.
    static let globalTabCap = 8

    private struct WeakPool {
        weak var pool: BrowserTabPool?
    }
    private var pools: [ObjectIdentifier: WeakPool] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                BrowserTabPoolRegistry.shared.handleMemoryWarning()
            }
        }
        installLivenessProbe()
    }

    func register(_ pool: BrowserTabPool) {
        pools[ObjectIdentifier(pool)] = WeakPool(pool: pool)
    }

    func unregister(_ pool: BrowserTabPool) {
        pools.removeValue(forKey: ObjectIdentifier(pool))
    }

    /// Total live tabs across all registered pools (drops stale weak refs).
    func totalLiveTabs() -> Int {
        compactPools()
        return pools.values.reduce(0) { $0 + ($1.pool?.tabs.count ?? 0) }
    }

    /// Try to make room for one more tab in `requester`. Prefers an idle
    /// (non-`inUse`) sibling tab; if none exist, preempts the oldest
    /// `inUse` sibling tab — the agent driving that tab will see a single
    /// "tab was reclaimed, please retry" error on its next action and the
    /// tab's URL is saved for restoration. The caller itself is excluded
    /// from eviction. Returns false only when there are zero candidate
    /// tabs in OTHER pools (e.g. only one pool exists and it's at cap).
    @discardableResult
    func requestSlot(for requester: BrowserTabPool) -> Bool {
        compactPools()
        if totalLiveTabs() < Self.globalTabCap { return true }

        let requesterId = ObjectIdentifier(requester)

        // Pass 1: prefer the oldest non-inUse tab in any sibling pool.
        var idleVictim: (pool: BrowserTabPool, tabId: Int, idle: TimeInterval)? = nil
        // Pass 2 (fallback): oldest inUse tab in any sibling pool. Tracked
        // in the same loop so we don't re-scan.
        var busyVictim: (pool: BrowserTabPool, tabId: Int, idle: TimeInterval)? = nil
        let now = Date()
        for (id, weak) in pools where id != requesterId {
            guard let pool = weak.pool else { continue }
            for tab in pool.tabs {
                let idle = now.timeIntervalSince(tab.lastActivityDate)
                if !tab.inUse {
                    if idleVictim == nil || idle > idleVictim!.idle {
                        idleVictim = (pool, tab.id, idle)
                    }
                } else {
                    if busyVictim == nil || idle > busyVictim!.idle {
                        busyVictim = (pool, tab.id, idle)
                    }
                }
            }
        }
        if let v = idleVictim {
            registryLogger.info("Global cap (\(Self.globalTabCap)) reached — evicting idle tab \(v.tabId) from sibling pool (idle \(String(format: "%.0f", v.idle))s) for requester")
            v.pool.evictTabForRegistry(id: v.tabId)
            return true
        }
        if let v = busyVictim {
            registryLogger.info("Global cap (\(Self.globalTabCap)) reached and no idle siblings — preempting in-use tab \(v.tabId) (idle \(String(format: "%.0f", v.idle))s) for requester")
            v.pool.preemptTabForRegistry(id: v.tabId)
            return true
        }
        registryLogger.info("Global cap (\(Self.globalTabCap)) reached and no sibling tabs to evict — denying slot")
        return false
    }

    /// On memory warning, evict every non-inUse tab across all pools. Tabs
    /// the agent is actively driving stay alive so in-flight actions don't
    /// fail mid-step.
    private func handleMemoryWarning() {
        compactPools()
        var evicted = 0
        for weak in pools.values {
            guard let pool = weak.pool else { continue }
            evicted += pool.evictAllIdleForMemoryWarning()
        }
        if evicted > 0 {
            registryLogger.info("Memory warning — evicted \(evicted) idle tab(s) across \(self.pools.count) pool(s)")
        }
    }

    struct TabSnapshot {
        let sessionId: String
        let tabId: Int
        let url: String
        let title: String
        let isLoading: Bool
        let inUse: Bool
        let lastActivityAgo: TimeInterval
    }

    func allTabSnapshots() -> [TabSnapshot] {
        compactPools()
        let now = Date()
        var result: [TabSnapshot] = []
        for weak in pools.values {
            guard let pool = weak.pool else { continue }
            let sid = String((pool.sessionId ?? "unknown").prefix(8))
            for tab in pool.tabs {
                result.append(TabSnapshot(
                    sessionId: sid,
                    tabId: tab.id,
                    url: String(tab.manager.currentURL.prefix(100)),
                    title: String(tab.manager.pageTitle.prefix(100)),
                    isLoading: tab.manager.isLoading,
                    inUse: tab.inUse,
                    lastActivityAgo: now.timeIntervalSince(tab.lastActivityDate)
                ))
            }
        }
        return result
    }

    private func compactPools() {
        pools = pools.filter { $0.value.pool != nil }
    }

    /// [BrowserToolDiag] Teach BrowserResourceMonitor how to tell whether a tab's
    /// WebContent process is still alive, without it having to reach into the
    /// browser layer. Installed on the registry (a single instance spanning every
    /// pool) rather than per-pool, since a per-pool closure would just overwrite
    /// its predecessor on the shared monitor.
    ///
    /// A killed WebContent leaves its WKWebView blank — url nil, title empty — so
    /// a blank view under a still-pending action is our only in-app evidence that
    /// the process died silently (its termination callback is documented as
    /// unreliable when it dies mid-render). We read the live WKWebView, not the
    /// manager's cached `currentURL`, because that cache keeps the last known
    /// value and would mask the very blanking we're testing for.
    private func installLivenessProbe() {
        BrowserResourceMonitor.shared.livenessProbe = { [weak self] tabId in
            guard let self else { return nil }
            self.compactPools()
            for weak in self.pools.values {
                guard let pool = weak.pool,
                      let tab = pool.tabs.first(where: { $0.id == tabId }) else { continue }
                let webView = tab.manager.webView
                return BrowserResourceMonitor.WebContentLiveness(
                    hasURL: webView.url != nil,
                    hasTitle: !(webView.title ?? "").isEmpty
                )
            }
            return nil
        }
    }
}
