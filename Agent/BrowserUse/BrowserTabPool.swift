import Foundation
import UIKit
import WebKit
import Combine
import os.log

private let logger = AppLogger(category: "BrowserTabPool")

@MainActor
final class BrowserTabPool: ObservableObject {
    static let maxTabs = 3

    /// Upper bound on tab-overview thumbnails kept in memory. Snapshots are
    /// never written to disk; this cap is the cache's only growth bound, and
    /// old entries are evicted oldest-first.
    static let maxTabSnapshots = BrowserTabPool.maxTabs

    #if DEBUG
    /// Debug-only weak reference for the debug server to access the active pool.
    static weak var debugInstance: BrowserTabPool?
    #endif

    /// How long an idle tab survives before its WKWebView is destroyed (seconds).
    static let idleTimeout: TimeInterval = 15 * 60  // 15 minutes

    /// How often to check for idle tabs (seconds).
    static let idleCheckInterval: TimeInterval = 60

    struct Tab: Identifiable {
        let id: Int
        let manager: BrowserUseManager
        /// True while a browser action is executing on this tab AND through a
        /// 15-second grace window after it completes. Implicit-tab requests
        /// (input.tabId == nil) skip a tab that's `inUse` — fanning out to a
        /// fresh tab when capacity allows — so back-to-back navigates can't
        /// land on tab 0 mid-load and stomp each other. The grace is re-armed
        /// by every subsequent action against this same tab (typically via
        /// explicit tab_id), so the agent's own follow-up reads/scrolls stay
        /// on its tab while another agent's fresh `navigate` fans out.
        /// [T-browser-implicit-tab-inuse-until-load-ios]
        var inUse: Bool = false
        /// Outstanding Task that will flip `inUse` back to false at the end of
        /// the current grace window. Each new completion cancels the previous
        /// task and arms a fresh 15-second timer.
        var graceExpiryTask: Task<Void, Never>? = nil
        /// When this tab was last actively used (action executed or released).
        var lastActivityDate: Date = Date()
    }

    /// Grace window kept after each action completes — see `Tab.inUse`.
    /// Matches the user's spec for #594 ("15s grace, re-armed on every action").
    static let postActionGraceSeconds: TimeInterval = 15

    /// URLs saved from evicted tabs, keyed by tab ID, for restoration on next use.
    var savedURLs: [Int: String] = [:]

    /// Tab IDs that the registry preempted while still inUse. Each entry
    /// fires one "tab was reclaimed, please retry" error on the next
    /// `execute(action:)` for that tab and is then cleared. The agent's
    /// retry will go through `acquireTab` again, restoring the URL.
    var preemptedTabIds: Set<Int> = []

    // MARK: - Per-tab serialization (T-browser-use-per-tab-serial-ios)

    /// Tail of each tab id's serial chain. Concurrent tool execution (TaskGroup)
    /// can call `execute(action:)` for the SAME tab id at the same time; the
    /// pool is @MainActor but each call `await`s `manager.execute`, releasing the
    /// actor and letting a sibling operate the same WKWebView mid-flight — the
    /// two stomp on each other (the "9to5Mac" red tool error). We serialize per
    /// tab id: an operation awaits the previous one for that tab before touching
    /// the manager. Different tab ids keep independent chains and stay parallel.
    /// Each tail is tagged with a monotonic token so the tail-cleanup compares by
    /// value (Task is a struct — no identity `===`).
    private var tabSerialChains: [Int: (token: UInt64, task: Task<Void, Never>)] = [:]
    private var nextSerialToken: UInt64 = 0

    /// [T-browser-cli-timeout-reclaim] OpenZe#245. The action currently
    /// holding each tab's serial slot, as a trigger that ends its
    /// `withDeadOnTimeout` race early. Firing it runs the ordinary dead-tab
    /// path — op task cancelled, tab rebuilt, slot released by the caller's
    /// `defer` — so an external caller (the CLI giving up at 90s) reclaims the
    /// tab without waiting out the 300s ceiling. Tagged with a token so a
    /// finished action only removes its own entry.
    private var inFlightAborts: [Int: (token: UInt64, abort: () -> Void)] = [:]

    /// Per-tab in-flight action cancellation for 接管. Ends the action through
    /// `ActionDeadTimeout(isTakeover:)` without rebuilding the tab. Tagged with
    /// the same token as `inFlightAborts` so stale entries clean themselves up.
    private var inFlightTakeoverAborts: [Int: (token: UInt64, abort: () -> Void)] = [:]

    /// Max time a browser_use call waits to acquire a tab id's serial slot, i.e.
    /// for the in-flight operation on that SAME tab to finish. This is the
    /// LOCK-WAIT timeout ONLY — it is deliberately separate from the per-action
    /// browser timeout (which is unchanged and applies AFTER the slot is held).
    /// Down from 60 s: with per-agent tab ownership the only thing that can
    /// be ahead in a tab's queue is the same caller's previous action.
    private static let serialWaitTimeout: TimeInterval = 20

    @Published var tabs: [Tab] = []

    /// Last captured overview thumbnail per tab id. Keyed by tab id instead of
    /// stored on `Tab` so a tab whose WKWebView is torn down (idle eviction)
    /// keeps its final picture for as long as the bounded cache allows.
    /// Memory only — never persisted. [P2-tab-overview]
    @Published var tabSnapshots: [Int: UIImage] = [:]
    /// Oldest-first tab ids backing `tabSnapshots`, used to enforce
    /// `maxTabSnapshots`.
    var tabSnapshotOrder: [Int] = []

    // [T-p2-shared-workspace] One pool can now serve a parent agent and its
    // helpers. Each agent (`owner` = its session id) keeps its own default
    // tab, so an implicit-tab action from one agent never lands on the tab
    // the other is driving; explicit `tab_id` still reaches any tab.
    /// tab id → owner session id (the agent that opened / last drove it).
    private(set) var tabOwner: [Int: String] = [:]
    /// owner session id → the tab it acted on most recently.
    private var lastTabByOwner: [String: Int] = [:]

    /// The tab an implicit-tab action from `owner` should default to.
    // MARK: Ownership (T-browser-agent-isolation)
    //
    // One pool is shared by a chat and every agent it delegates to. Tabs are
    // tagged with the session id that created them; the chat itself and a
    // human taking over (`owner == nil`) may use any tab, an AGENT may only
    // use its own. Agents get a small quota, never see other owners' tabs in
    // list_tabs, never move the chat's selected tab, and give their tabs back
    // when their job ends. This is what stops three parallel research agents
    // from navigating each other's pages away (seen on device 2026-09-04).

    /// Tabs an agent may open at once; the chat itself keeps `maxTabs`.
    static let agentTabQuota = 2
    /// Absolute pool ceiling while agents run (the registry's global cap and
    /// memory-pressure reclaim still apply on top).
    static let maxTabsWithAgents = 6

    /// The chat that owns this pool, or a human (nil) — full access.
    private func isPrivileged(_ owner: String?) -> Bool {
        owner == nil || owner == sessionId
    }

    private func agentOwners() -> Set<String> {
        Set(tabOwner.values).subtracting([sessionId ?? ""])
    }

    /// Pool ceiling right now: 3 alone, +2 per active agent, capped at 6.
    func effectiveMaxTabs(requestingOwner: String?) -> Int {
        var owners = agentOwners()
        if let o = requestingOwner, !isPrivileged(o) { owners.insert(o) }
        return owners.isEmpty ? Self.maxTabs : min(Self.maxTabs + Self.agentTabQuota * owners.count, Self.maxTabsWithAgents)
    }

    /// True when `owner` (an agent) may act on `tabId`.
    private func mayUse(tabId: Int, owner: String?) -> Bool {
        if isPrivileged(owner) { return true }
        return tabOwner[tabId] == owner
    }

    private func notYourTabError(_ tabId: Int, owner: String) -> BrowserActionResult {
        let mine = tabIds(ownedBy: owner)
        let hint = mine.isEmpty ? "open one with action: new_tab" : "use your own tab id(s) \(mine.map(String.init).joined(separator: ", ")) or action: new_tab"
        return .error("Tab \(tabId) belongs to another agent or to the main chat and cannot be used from here — \(hint). list_tabs shows only your tabs.")
    }

    /// Close every tab an agent owns and forget its bookkeeping. Called when
    /// the agent's job ends so the slots go back to the chat and to other
    /// agents. Idempotent.
    func releaseTabs(owner: String) {
        let mine = tabIds(ownedBy: owner)
        for id in mine { _ = closeTab(id: id) }
        lastTabByOwner.removeValue(forKey: owner)
        if !mine.isEmpty { logger.info("[agent] released \(mine.count) tab(s) of owner \(owner.prefix(8))") }
    }

    private func preferredTab(for owner: String?) -> Int? {
        guard let owner, let id = lastTabByOwner[owner], tabs.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Tabs currently attributed to `owner`.
    func tabIds(ownedBy owner: String) -> [Int] {
        tabOwner.filter { $0.value == owner }.map(\.key).sorted()
    }

    @Published var selectedTabId: Int = 0 {
        didSet {
            rebindLoadingObservation()
            // Capture the tab being left before the view swaps it out. Doing
            // this in the setter covers every switch path (tab chips,
            // overview, new/closed tabs, agent-driven selection), not just the
            // ones that happen to call a UI helper. [P2-tab-overview]
            if oldValue != selectedTabId {
                captureTabSnapshot(tabId: oldValue)
            }
        }
    }
    /// The GLOBAL default profile (Browser Settings / ze-config), as this
    /// pool last read it from UserDefaults. It decides what a tab is CREATED
    /// with; it does not describe the tabs that are already open - each tab
    /// keeps the profile it was created or last switched with, in its own
    /// `BrowserUseManager.currentProfile`. See `syncGlobalDefaultsFromStore()`.
    @Published var userAgentProfile: UserAgentProfile = .mobileSafari
    @Published var customUserAgentString: String = ""

    /// Global custom viewport. Zero means "use the UA profile default".
    /// Persisted across launches via UserDefaults, and like the profile above
    /// only a default for tabs created later. Session-level overrides
    /// live in `sessionViewportWidth`/`sessionViewportHeight`.
    @Published var customViewportWidth: Int = 0
    @Published var customViewportHeight: Int = 0

    /// Per-session viewport override set via the `set_viewport` action.
    /// When both > 0 these shadow the global custom viewport. Persisted in
    /// the session tabs file, not UserDefaults, and cleared by
    /// `set_viewport --reset`.
    @Published var sessionViewportWidth: Int = 0
    @Published var sessionViewportHeight: Int = 0

    // MARK: - UA Defaults Keys
    private static let uaProfileKey = "BrowserUserAgentProfile"
    private static let uaCustomStringKey = "BrowserCustomUserAgentString"

    // MARK: - Viewport Defaults Keys (global)
    private static let viewportWidthKey = "BrowserCustomViewportWidth"
    private static let viewportHeightKey = "BrowserCustomViewportHeight"

    /// Session ID for disk persistence. Set by AIChatViewModel.
    var sessionId: String? {
        didSet {
            if let sessionId, sessionId != oldValue {
                loadPersistedURLs()
            }
            // A reused pool that moves to a different real session starts
            // clean; a draft→real id migration (nil → id) does not.
            if let oldValue, oldValue != sessionId {
                resetControlForNewSession()
            }
        }
    }

    /// Timer that periodically evicts idle tabs.
    var idleTimer: Timer?
    private var loadingObservation: AnyCancellable?

    /// Whether the active tab's webview is currently loading a page.
    @Published var isBrowserLoading: Bool = false

    /// Compatibility alias for the control state machine. Kept for callers
    /// outside the sheet; never a second gate inside the UI.
    var isAgentBrowsing: Bool { controlState == .agent }

    // MARK: - Browser Control (P3)

    /// Pool-level single source of truth for UI usability. `agent` while the
    /// agent drives, `user` after 接管 (until 交还), `idle` otherwise. The old
    /// `isAgentBusy` blanket lock is replaced by this state in BrowserSheetView.
    @Published private(set) var controlState: BrowserControlState = .idle

    /// Called on every user-visible control transition. The chat VM turns it
    /// into an ephemeral session system event; it never fabricates a user
    /// message.
    var onControlStateChange: ((BrowserControlEvent) -> Void)?

    /// Non-nil while an agent-initiated `browser_request_takeover` is waiting
    /// for the user. `controlState` is `.user` throughout; this carries the
    /// reason shown in the sheet banner and the id that guards the single
    /// waiter from double-resume.
    @Published private(set) var pendingTakeoverRequest: BrowserTakeoverRequestInfo?

    /// True while the current `.user` control state came from the agent's
    /// `browser_request_takeover` tool (as opposed to the user pressing 接管).
    var isTakeoverRequested: Bool { pendingTakeoverRequest != nil }

    /// Continuation for the waiting `browser_request_takeover` action. The
    /// action yields here — no polling, no timeout, no main-thread blocking.
    private var takeoverRequestContinuation: CheckedContinuation<BrowserActionResult, Never>?
    /// Covers the tiny window where the user finishes/cancels before the
    /// action reaches its continuation (e.g. an already-cancelled task).
    private var bufferedTakeoverRequestResult: (id: UUID, result: BrowserActionResult)?

    /// System-event lines waiting to ride the next browser tool result. Bounded
    /// like the dialog queue so a pathological flapping session cannot grow it
    /// without limit.
    private var pendingControlEvents: [String] = []
    private static let maxPendingControlEvents = 8

    /// Read-only actions allowed while the user holds control. Everything else
    /// returns `user_takeover` before touching the WKWebView.
    private static let readOnlyActions: Set<BrowserAction> = [
        .screenshot, .getText, .getPageInfo, .getReadable, .getBackbone,
        .findElements, .getCookies, .listTabs, .waitForDomStable, .fetch
    ]

    /// The manager for the currently selected UI tab.
    var activeManager: BrowserUseManager? {
        tabs.first { $0.id == selectedTabId }?.manager
    }

    /// True when any tab is mid-navigation — used by the per-tool-call stop
    /// button to decide whether there's a browser load worth cancelling.
    /// [T-ios-browser-tool-stop-button]
    var hasLoadingTab: Bool {
        tabs.contains { $0.manager.isLoading }
    }

    /// Stop in-flight page loads on EVERY tab. A hung `navigate` awaits the
    /// manager's navigationContinuation, which `stopLoading()` resolves (WebKit
    /// fires didFailProvisionalNavigation/cancelled), so the awaited
    /// `execute(action:)` returns and the tool call completes. Mirrors the
    /// "one stop tap cancels every in-flight shell" semantics for the browser
    /// side. Returns the number of tabs that were actually loading.
    /// [T-ios-browser-tool-stop-button]
    @discardableResult
    func stopAllLoading() -> Int {
        var stopped = 0
        for tab in tabs where tab.manager.isLoading {
            tab.manager.stopLoading()
            stopped += 1
        }
        return stopped
    }

    init() {
        // Restore the persisted UA preference and global custom viewport
        // (0 = not set → fall back to UA).
        syncGlobalDefaultsFromStore()
        startIdleTimer()
        BrowserTabPoolRegistry.shared.register(self)
        #if DEBUG
        Self.debugInstance = self
        #endif
    }

    deinit {
        idleTimer?.invalidate()
        // Registry holds a weak ref and lazily compacts stale entries on
        // every operation, so we don't need to unregister explicitly here
        // (deinit is nonisolated; hopping to MainActor isn't safe).
    }

    /// Re-subscribe to the active manager's `isLoading` so `isBrowserLoading` stays in sync.
    private func rebindLoadingObservation() {
        loadingObservation?.cancel()
        guard let mgr = activeManager else {
            isBrowserLoading = false
            return
        }
        isBrowserLoading = mgr.isLoading
        loadingObservation = mgr.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in
                self?.isBrowserLoading = loading
            }
    }

    // MARK: - Tab Lifecycle

    /// Acquire or create a tab for agent use. Returns the tab ID and marks it inUse.
    func acquireTab() -> Int {
        // If tab 0 exists and is available, use it
        if let idx = tabs.firstIndex(where: { $0.id == 0 }) {
            tabs[idx].inUse = true
            tabs[idx].lastActivityDate = Date()
            return 0
        }
        // Otherwise create tab 0, restoring saved URL if available.
        // Ask the registry for a global slot — may evict an idle tab in
        // another session's pool. If denied (everyone is busy), we still
        // create the tab: the agent needs *some* surface to act on, and
        // failing here would surface as an unrecoverable tool error.
        BrowserTabPoolRegistry.shared.requestSlot(for: self)
        discardTabSnapshot(forTabId: 0)
        let manager = makeManager()
        let tab = Tab(id: 0, manager: manager, inUse: true)
        tabs.append(tab)
        selectedTabId = 0
        restoreSavedURL(for: 0, manager: manager)
        logger.info("Created tab 0")
        return 0
    }

    /// Ensure tab 0 exists for UI display without marking it as agent-busy.
    func ensureTabForUI() {
        if !tabs.contains(where: { $0.id == 0 }) {
            // Pure UI prefetch — if we're at the global cap and can't evict
            // anyone, skip the prefetch. The user can still tap to create
            // it via acquireTab/newTab, which prioritise creation.
            guard BrowserTabPoolRegistry.shared.requestSlot(for: self) else {
                logger.info("Skipping UI prefetch tab — global cap reached and no idle siblings to evict")
                return
            }
            discardTabSnapshot(forTabId: 0)
            let manager = makeManager()
            let tab = Tab(id: 0, manager: manager, inUse: false)
            tabs.append(tab)
            selectedTabId = 0
            restoreSavedURL(for: 0, manager: manager)
            logger.info("Created tab 0 for UI")
        }
    }

    /// Create a new tab (up to maxTabs). Returns a result with the new tab ID or an error.
    func newTab(url: String? = nil, owner: String? = nil) -> BrowserActionResult {
        if let owner, !isPrivileged(owner) {
            let mine = tabIds(ownedBy: owner)
            if mine.count >= Self.agentTabQuota {
                return .error("You already have \(mine.count) tab(s) (limit \(Self.agentTabQuota) per agent). Reuse tab id(s) \(mine.map(String.init).joined(separator: ", ")) — navigate them to the next page — or close_tab one of yours first.")
            }
        }
        let ceiling = effectiveMaxTabs(requestingOwner: owner)
        guard tabs.count < ceiling else {
            return isPrivileged(owner)
                ? .error("Maximum of \(ceiling) tabs reached. Close a tab first with close_tab.")
                : .error("The browser is at its tab limit right now (\(ceiling)). Reuse one of your own tabs, or close_tab one of yours and retry.")
        }
        // Try to make room globally. Unlike acquireTab, newTab is an
        // explicit "open another" — falling back to "load in current tab"
        // would be more confusing than a clear error, so refuse on denial.
        guard BrowserTabPoolRegistry.shared.requestSlot(for: self) else {
            return .error("Browser memory cap reached across all sessions (\(BrowserTabPoolRegistry.globalTabCap) tabs). Close a tab here or in another session first.")
        }
        let nextId = (tabs.map(\.id).max() ?? -1) + 1
        discardTabSnapshot(forTabId: nextId)
        let manager = makeManager()
        let tab = Tab(id: nextId, manager: manager, inUse: true)
        tabs.append(tab)
        selectedTabId = nextId
        if let owner { tabOwner[nextId] = owner; lastTabByOwner[owner] = nextId }
        // If the agent supplied a URL with new_tab, load it. Previously the
        // url was silently dropped (the tool said "Opened new tab 0" but the
        // tab was blank) — restoreSavedURL only fires for tabs that had a
        // persisted URL, which a brand-new tab never has.
        // [T-ios-new-tab-url-dropped]
        let trimmedUrl = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let loadUrl = trimmedUrl, !loadUrl.isEmpty {
            manager.loadURL(loadUrl)
        } else {
            restoreSavedURL(for: nextId, manager: manager)
        }
        logger.info("Created new tab \(nextId), total: \(self.tabs.count)")
        let urlSuffix = (trimmedUrl?.isEmpty == false) ? " at \(trimmedUrl!)" : ""
        return BrowserActionResult(
            text: "Opened new tab \(nextId)\(urlSuffix). You now have \(tabs.count) tab(s). Use tab_id: \(nextId) to target this tab.",
            tabId: nextId)
    }

    /// Open a URL in a new tab, or in the current tab if at max capacity.
    func openURL(_ url: URL) {
        if tabs.count < Self.maxTabs {
            _ = newTab()
            activeManager?.loadURL(url.absoluteString)
        } else {
            // At capacity — load in current tab
            touchActivity()
            activeManager?.loadURL(url.absoluteString)
        }
    }

    /// Create a new tab using a pre-built WKWebViewConfiguration (for window.open / OAuth popups).
    /// Returns the new tab's WKWebView so the opener retains a window.opener reference.
    /// WebKit will automatically load the navigation into the returned WKWebView.
    @discardableResult
    func openWithConfiguration(_ configuration: WKWebViewConfiguration, url: URL?) -> WKWebView? {
        guard tabs.count < Self.maxTabs else {
            // At capacity — load in current tab instead
            if let url {
                activeManager?.loadURL(url.absoluteString)
            }
            return nil
        }
        // Apply the same global gate as newTab. window.open opened by JS
        // is rare enough that returning nil (= cancel the popup) is the
        // least-bad outcome when memory is tight.
        guard BrowserTabPoolRegistry.shared.requestSlot(for: self) else {
            logger.info("Suppressing window.open popup — global tab cap reached")
            if let url {
                activeManager?.loadURL(url.absoluteString)
            }
            return nil
        }
        let nextId = (tabs.map(\.id).max() ?? -1) + 1
        discardTabSnapshot(forTabId: nextId)
        // A popup is a new tab like any other: it starts from the global
        // default as it stands now, not from what this pool read at init.
        syncGlobalDefaultsFromStore()
        let ua = resolvedUserAgentString()
        let vp = resolvedViewportSize()
        let manager = BrowserUseManager(profile: userAgentProfile, customString: ua,
                                        configuration: configuration,
                                        viewportWidth: vp.width, viewportHeight: vp.height)
        wireManager(manager)
        let tab = Tab(id: nextId, manager: manager, inUse: false)
        tabs.append(tab)
        selectedTabId = nextId
        logger.info("Created popup tab \(nextId) via window.open, total: \(self.tabs.count)")
        return manager.webView
    }

    /// Close the tab that owns the given WKWebView (called when window.close() fires).
    func closeWebView(_ webView: WKWebView) {
        if let tab = tabs.first(where: { $0.manager.webView === webView }) {
            _ = closeTab(id: tab.id)
        }
    }

    /// Close a specific tab and remove its WKWebView.
    func closeTab(id: Int) -> BrowserActionResult {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else {
            return .error("No tab with id \(id)")
        }
        // Don't save URL on explicit close — user intentionally closed it
        savedURLs.removeValue(forKey: id)
        discardTabSnapshot(forTabId: id)
        tabs.remove(at: idx)
        tabOwner.removeValue(forKey: id)
        for (o, t) in lastTabByOwner where t == id { lastTabByOwner.removeValue(forKey: o) }
        logger.info("Closed tab \(id), remaining: \(self.tabs.count)")

        // If the closed tab was selected, switch to another
        if selectedTabId == id {
            selectedTabId = tabs.first?.id ?? 0
        }

        persistURLs()
        return BrowserActionResult(text: "Closed tab \(id). \(tabs.count) tab(s) remaining.")
    }

    /// List all open tabs with their URLs and titles.
    func listTabs(owner: String? = nil) -> BrowserActionResult {
        // An agent sees only its own tabs; the chat / a human sees everything
        // with each agent's tabs tagged.
        let visible = isPrivileged(owner) ? tabs : tabs.filter { tabOwner[$0.id] == owner }
        if visible.isEmpty {
            return BrowserActionResult(text: isPrivileged(owner)
                ? "No tabs open."
                : "You have no tabs yet (limit \(Self.agentTabQuota) per agent). Open one with action: new_tab, or just navigate.")
        }
        var lines: [String] = [isPrivileged(owner) ? "Open tabs:" : "Your tabs (\(visible.count)/\(Self.agentTabQuota)):"]
        for tab in visible {
            let url = tab.manager.currentURL.isEmpty ? "(blank)" : tab.manager.currentURL
            let title = tab.manager.pageTitle.isEmpty ? "(untitled)" : tab.manager.pageTitle
            let marker = isPrivileged(owner) && tab.id == selectedTabId ? " *" : ""
            let ownerTag = isPrivileged(owner)
                ? (tabOwner[tab.id].flatMap { $0 == sessionId ? nil : " [agent \($0.prefix(8))]" } ?? "")
                : ""
            lines.append("  Tab \(tab.id): \(title) — \(url)\(marker)\(ownerTag)")
        }
        return BrowserActionResult(text: lines.joined(separator: "\n"))
    }

    /// Acquire the serial slot for `tabId`, waiting at most `serialWaitTimeout`
    /// for the previous operation on that tab to finish. Returns a `release`
    /// closure on success (MUST be called when the operation completes, via
    /// `defer`), or `nil` if the wait timed out (caller should return the
    /// open-a-new-tab guidance error). The release is also what lets the NEXT
    /// queued operation for this tab proceed.
    ///
    /// Implementation: each caller appends a gated `Task` to the tab's chain and
    /// awaits the PREVIOUS tail (with a timeout). Its own gate is only completed
    /// by `release`, so the next caller blocks on it. The timeout races the
    /// predecessor await against a sleep — it does NOT cancel the predecessor's
    /// real browser work, only this caller's willingness to keep waiting.
    private func acquireSerialSlot(tabId: Int) async -> (() -> Void)? {
        let predecessor = tabSerialChains[tabId]?.task

        // Our gate: completed by `release`. The successor awaits this.
        // We previously stored the resume closure in an IUO populated INSIDE the
        // gate `Task { ... }` body. Under memory pressure the gate Task can be
        // scheduled late, so `release()` would run before the IUO was assigned
        // and crash on `nil!` (P0 SIGTRAP — 7 hits on a single iPhone 14 PM in
        // 8 minutes, all paired with mach_vm_allocate_kernel failed kernel
        // triage). [T-ios-browsertabpool-serialslot-nil-crash]
        //
        // Fix: store the gate as a one-shot box that can hold EITHER a
        // resume closure OR a pre-arrived `release()` signal. The gate Task
        // installs its continuation atomically; if release fired first, the
        // continuation resumes synchronously the moment it's installed. Either
        // ordering is safe — no IUO, no race.
        let token = nextSerialToken
        nextSerialToken &+= 1

        final class GateBox: @unchecked Sendable {
            private var lock = os_unfair_lock()
            private var resume: (() -> Void)?
            private var preFired = false

            /// Called by `release()`. If the gate Task has already installed
            /// its continuation, fire it; otherwise mark pre-fired so the
            /// installer fires immediately on arrival.
            func signal() {
                os_unfair_lock_lock(&lock)
                if let r = resume {
                    resume = nil
                    os_unfair_lock_unlock(&lock)
                    r()
                } else {
                    preFired = true
                    os_unfair_lock_unlock(&lock)
                }
            }

            /// Called from the gate Task once `withCheckedContinuation` hands
            /// it the resume closure. If release already fired, drain it now.
            func install(_ r: @escaping () -> Void) {
                os_unfair_lock_lock(&lock)
                if preFired {
                    os_unfair_lock_unlock(&lock)
                    r()
                } else {
                    resume = r
                    os_unfair_lock_unlock(&lock)
                }
            }
        }
        let gateBox = GateBox()
        let gate = Task<Void, Never> {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                gateBox.install { cont.resume() }
            }
        }
        tabSerialChains[tabId] = (token, gate)

        var released = false
        let release: () -> Void = { [weak self] in
            guard !released else { return }
            released = true
            gateBox.signal()
            // Clear the chain entry if we're still the tail (no one queued after
            // us) — compare by token since Task is a struct.
            Task { @MainActor in
                guard let self else { return }
                if self.tabSerialChains[tabId]?.token == token {
                    self.tabSerialChains.removeValue(forKey: tabId)
                }
            }
        }

        guard let predecessor else {
            // No one ahead — slot is free immediately.
            return release
        }

        // Wait for the predecessor, but no longer than serialWaitTimeout.
        let waited = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await predecessor.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.serialWaitTimeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if waited {
            return release
        } else {
            // Timed out waiting for the slot. Detach our gate from the chain so
            // we don't block successors, and signal the caller to bail.
            logger.warning("[SerialDiag] tab \(tabId): serial-wait timed out after \(Int(Self.serialWaitTimeout))s — releasing own gate, returning open-new-tab guidance")
            release()
            return nil
        }
    }

    /// Execute a browser action on the specified tab (or default tab 0).
    ///
    /// `singleTab` (T-browser-executejs-stale-context-ios): when true, the
    /// implicit-tab fan-out below is bypassed and an action with no explicit
    /// `tab_id` always targets `selectedTabId` (the current / most-recently
    /// navigated tab), even while that tab is inside its inUse post-action
    /// grace window. This is the `ze-browser-use` CLI path: a human/script
    /// drives a SERIAL sequence (navigate → execute_js → navigate → …) and
    /// expects "read the page I just navigated to", so spreading the read
    /// across fan-out tabs (which the grace-based fan-out does, to keep the
    /// agent's CONCURRENT navigates from stomping each other) is wrong here.
    /// The per-tab serial slot below is still honoured, so concurrent calls
    /// on the same tab stay safe. Explicit `--tab-id` still routes normally.
    /// The agent tool path leaves this false → fan-out behaviour unchanged.
    /// [BrowserToolDiag] Resource/lifecycle tracing wrapper for the
    /// backgrounded-hang investigation (a browser action was observed not
    /// returning for ~287 minutes). This is the single chokepoint every browser
    /// action passes through, so instrumenting it covers the whole tool surface.
    ///
    /// The real body lives in `executeInner`. Wrapping rather than sprinkling
    /// `defer`s inside it is deliberate: `executeInner` has a dozen early
    /// `return`s plus a `throw` path, and a wrapper cannot be escaped by a
    /// future one — whereas an in-body flag would silently mis-report the day
    /// someone adds another `return`.
    func execute(
        action input: BrowserActionInput,
        singleTab: Bool = false,
        owner: String? = nil
    ) async throws -> BrowserActionResult {
        let diagId = BrowserResourceMonitor.shared.actionWillStart(
            action: input.action.rawValue,
            url: input.url,
            tabId: input.tabId
        )
        // A browser action from the agent/CLI is an agent-control action.
        // `list_tabs` is pure metadata and must not flash the takeover card.
        if input.action != .listTabs, controlState != .user {
            controlState = .agent
        }
        do {
            var result = try await executeInner(action: input, singleTab: singleTab, owner: owner)
            // Every browser tool result carries control. A takeover event that
            // happened while this action was in flight is prepended too, so the
            // next model turn cannot miss it.
            result.control = controlState
            if let eventText = drainControlEventText() {
                result.text = eventText + "\n" + result.text
            }
            // A completed takeover request hands control to the agent by
            // definition (`control: agent`); settling it to idle here would
            // make the very result that announced the handoff lie about it.
            // Every subsequent action settles normally.
            if !(input.action == .requestTakeover && result.success) {
                settleControlAfterActionIfIdle()
            }
            BrowserResourceMonitor.shared.actionDidFinish(
                diagId,
                success: result.success,
                // A failed action carries its reason in `text` — worth keeping,
                // since a background-suspension failure will read differently
                // from an ordinary page error.
                error: result.success ? nil : result.text
            )
            return result
        } catch {
            settleControlAfterActionIfIdle()
            BrowserResourceMonitor.shared.actionDidFinish(
                diagId,
                success: false,
                error: "throw: \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func executeInner(
        action input: BrowserActionInput,
        singleTab: Bool,
        owner: String?
    ) async throws -> BrowserActionResult {
        let poolStart = CFAbsoluteTimeGetCurrent()
        // The tab an implicit (no tab_id) action from this agent falls back to.
        let implicitDefault = preferredTab(for: owner) ?? selectedTabId
        logger.info("[PoolTiming] enter action=\(input.action.rawValue) tab_id=\(input.tabId.map(String.init) ?? "nil") singleTab=\(singleTab)")

        // Control gate before ANY tab is picked or created. Write actions are
        // refused outright; read actions fall through and carry control: user.
        if controlState == .user, !Self.readOnlyActions.contains(input.action) {
            return takeoverRefusal()
        }

        // Waiting handover has no tab target: it suspends before any tab
        // resolution so it cannot hold a serial slot while the user works.
        if input.action == .requestTakeover {
            return await requestTakeover(reason: input.reason ?? "")
        }

        // Handle tab management actions
        switch input.action {
        case .newTab:
            // Pass input.url through so the new tab actually loads it — Android
            // already does this (BrowserTabPool.kt NEW_TAB branch).
            // [T-ios-new-tab-url-dropped]
            return newTab(url: input.url, owner: owner)
        case .closeTab:
            let tabId = input.tabId ?? implicitDefault
            if let owner, !mayUse(tabId: tabId, owner: owner) { return notYourTabError(tabId, owner: owner) }
            return closeTab(id: tabId)
        case .listTabs:
            return listTabs(owner: owner)
        default:
            break
        }

        // set_user_agent with a missing or unknown profile is an error, said
        // before any tab is picked or created. It used to fall back to mobile
        // Safari silently, so `user_agent: "desktop"` switched to MOBILE.
        if input.action == .setUserAgent, input.userAgent == nil {
            return .error(UserAgentProfile.invalidArgumentMessage(raw: input.userAgentRaw))
        }

        // Determine which tab to target.
        // Always go through ensureDefaultTab() when no tabs exist, even if
        // the model explicitly sends tab_id: 0 (which makes input.tabId non-nil).
        //
        // `explicitTabId`: did the model pin a specific tab? When it did NOT and
        // two such calls run concurrently (TaskGroup), both would otherwise land
        // on the SAME default tab and stomp / serialize-into-a-near-deadlock.
        // For an implicit-tab content action, if the default tab is already busy
        // with a sibling op AND we can still open another tab, give this call its
        // own fresh tab so the two navigates run in parallel and produce two tabs
        // (T-browser-use-per-tab-serial-ios — user's "should create two tabs, not
        // deadlock"). Only same explicit tab_id gets serialized below.
        let explicitTabId = input.tabId != nil
        // [T-ios-browser-readaction-tabid-monotonic-leak] Only *open-page*
        // actions (navigate) may fan out / create a fresh tab. Every other
        // action — read (get_readable, screenshot, get_text, get_page_info,
        // find_elements, get_backbone, get_cookies), exec (execute_js), and
        // operate (click, type, scroll, hover, …) — must run on an EXISTING
        // tab: the explicit tab_id if given, else the current / most-recently
        // active tab. Without this, a read action issued right after a
        // navigate saw tab 0 still `inUse` inside its 15s post-action grace,
        // found "no free tab", and fanned out to a blank new tab (the
        // monotonic 0→1→2 leak that returned empty text / blank screenshots).
        let isOpenPageAction = (input.action == .navigate)
        let targetId: Int
        // Set when an implicit navigate REUSES an idle tab that held a different
        // page — surfaced in the result so the model isn't left thinking the tab
        // still shows its old site. [T-browser-tab-reuse-silent-switch]
        var reusedTabSwitch: (tabId: Int, oldURL: String)? = nil
        if let requestedId = input.tabId, tabs.contains(where: { $0.id == requestedId }) {
            if let owner, !mayUse(tabId: requestedId, owner: owner) {
                return notYourTabError(requestedId, owner: owner)
            }
            targetId = requestedId
        } else if let owner, !isPrivileged(owner), !explicitTabId {
            // An agent's implicit target: its own last tab, else a free tab it
            // owns, else a fresh tab within its quota — NEVER the chat's
            // selected tab or another agent's.
            if let own = preferredTab(for: owner), mayUse(tabId: own, owner: owner) {
                targetId = own
            } else if let free = tabs.first(where: { !$0.inUse && tabOwner[$0.id] == owner }) {
                targetId = free.id
            } else {
                let created = newTab(url: nil, owner: owner)
                guard let id = created.tabId else { return created }
                targetId = id
            }
        } else if !isOpenPageAction {
            // Read / exec / operate action without a valid explicit tab_id:
            // follow the current tab (selectedTabId) when it exists; otherwise
            // open the default tab. NEVER fan out to a fresh blank tab and
            // never block on a serial slot to acquire one — just target the
            // tab the agent is already looking at.
            let probe = input.tabId ?? implicitDefault
            if preemptedTabIds.remove(probe) != nil {
                return .error("Browser tab \(probe) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            targetId = tabs.contains(where: { $0.id == implicitDefault })
                ? implicitDefault
                : ensureDefaultTab()
        } else {
            // Before creating a default tab, surface a one-shot preempt
            // notice if the requested-or-default id was just reclaimed.
            // The agent's retry of this same action will sail through.
            let probe = input.tabId ?? 0
            if preemptedTabIds.remove(probe) != nil {
                return .error("Browser tab \(probe) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            // Implicit-tab content action: per spec [T-browser-implicit-tab-inuse-until-load-ios]
            // NEVER dispatch onto a tab that's still inUse (action in flight OR
            // within the 15s post-action grace). Otherwise back-to-back
            // navigates land on tab 0 and stomp each other's URLs. Try:
            //   1. Pick any existing tab whose `inUse=false` (prefers reuse).
            //   2. Otherwise, if capacity remains, fan out to a fresh tab.
            //   3. Otherwise, fall back to ensureDefaultTab() — at full
            //      capacity with everything busy, the agent will hit the
            //      serial-slot wait below or return a busy hint.
            if singleTab {
                // CLI single-tab mode: never fan out. Stick to the current /
                // most-recently navigated tab so a serial navigate → read
                // sequence reads the page it just loaded. ensureDefaultTab()
                // already returns selectedTabId when that tab exists, and
                // creates tab 0 (selecting it) when the pool is empty.
                targetId = tabs.contains(where: { $0.id == implicitDefault })
                    ? implicitDefault
                    : ensureDefaultTab()
            } else if !explicitTabId {
                // [T-p2-shared-workspace] Only reuse a tab that is free AND
                // either unowned or this agent's own: the parent's idle tab
                // must not be navigated away by a helper's implicit open
                // (device run 20:57 clobbered example.com with wikipedia).
                if let freeTab = tabs.first(where: { t in
                    !t.inUse && (owner == nil || tabOwner[t.id] == nil || tabOwner[t.id] == owner)
                }) {
                    targetId = freeTab.id
                    // [T-browser-tab-reuse-silent-switch] We're about to REUSE an
                    // idle tab that already holds a page (not a blank fresh tab)
                    // for a new navigate. Its id stays the same but its content is
                    // about to change out from under any earlier task that still
                    // thinks "tab N == the old site". Capture the old URL so the
                    // navigate result can tell the model the tab was repurposed.
                    let oldURL = freeTab.manager.currentURL
                    if !oldURL.isEmpty, oldURL != "about:blank",
                       let newURL = input.url, oldURL != newURL {
                        reusedTabSwitch = (tabId: freeTab.id, oldURL: oldURL)
                    }
                } else if tabs.count < effectiveMaxTabs(requestingOwner: owner),
                          BrowserTabPoolRegistry.shared.requestSlot(for: self) {
                    let nextId = (tabs.map(\.id).max() ?? -1) + 1
                    let manager = makeManager()
                    tabs.append(Tab(id: nextId, manager: manager, inUse: true))
                    restoreSavedURL(for: nextId, manager: manager)
                    logger.info("[SerialDiag] implicit-tab action — all existing tabs inUse (action/grace), fanned out to fresh tab \(nextId)")
                    targetId = nextId
                } else {
                    targetId = ensureDefaultTab()
                }
            } else {
                targetId = ensureDefaultTab()
            }
        }
        if preemptedTabIds.remove(targetId) != nil {
            return .error("Browser tab \(targetId) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
        }
        guard let idx = tabs.firstIndex(where: { $0.id == targetId }) else {
            return .error("No tab with id \(targetId). Use list_tabs to see open tabs.")
        }

        let tabResolvedMs = Int((CFAbsoluteTimeGetCurrent() - poolStart) * 1000)
        logger.info("[PoolTiming] tab_resolved elapsed=\(tabResolvedMs)ms targetId=\(targetId) action=\(input.action.rawValue)")

        // Mark in use, touch activity, and select for UI. inUse stays true
        // through the post-action grace window — `armPostActionGrace` cancels
        // any previous timer for this tab and arms a fresh 15s one. That
        // window is what blocks back-to-back implicit-tab navigates from
        // stomping each other on tab 0 (T-browser-implicit-tab-inuse-until-load-ios).
        tabs[idx].inUse = true
        tabs[idx].graceExpiryTask?.cancel()
        tabs[idx].graceExpiryTask = nil
        tabs[idx].lastActivityDate = Date()
        if isPrivileged(owner) { selectedTabId = targetId }
        if let owner {
            lastTabByOwner[owner] = targetId
            if tabOwner[targetId] == nil { tabOwner[targetId] = owner }
        }
        defer {
            if let i = tabs.firstIndex(where: { $0.id == targetId }) {
                tabs[i].lastActivityDate = Date()
                if controlState == .user {
                    // Takeover wins: the tab is the user's now, so no agent
                    // grace window may keep it marked inUse.
                    tabs[i].inUse = false
                    tabs[i].graceExpiryTask?.cancel()
                    tabs[i].graceExpiryTask = nil
                } else {
                    armPostActionGrace(tabId: targetId)
                }
            }
        }

        // Session-scoped viewport override. --reset clears, otherwise set.
        if input.action == .setViewport {
            if input.viewportReset == true {
                resetSessionViewport()
                let vp = resolvedViewportSize()
                return BrowserActionResult(
                    text: "Viewport reset to default (\(vp.width)x\(vp.height))"
                )
            }
            guard let w = input.viewportWidth, let h = input.viewportHeight,
                  w > 0, h > 0 else {
                return .error("set_viewport requires positive viewport_width and viewport_height, or reset=true")
            }
            setSessionViewport(width: w, height: h)
            return BrowserActionResult(
                text: "Viewport set to \(w)x\(h) for this session"
            )
        }

        // [T-browser-use-per-tab-serial-ios] Serialize per tab id. Acquire the
        // tab's serial slot, waiting at most serialWaitTimeout (60s) for any
        // in-flight op on this SAME tab. On timeout, tell the model to open a
        // fresh tab instead of contending. This wait is independent of the
        // per-action browser timeout below (manager.execute), which is unchanged.
        let serialWaitStart = CFAbsoluteTimeGetCurrent()
        guard let releaseSerialSlot = await acquireSerialSlot(tabId: targetId) else {
            let serialWaitMs = Int((CFAbsoluteTimeGetCurrent() - serialWaitStart) * 1000)
            logger.info("[PoolTiming] serial_slot_timeout elapsed=\(serialWaitMs)ms tab=\(targetId) action=\(input.action.rawValue)")
            return .error(String(localized: "Multiple actions are operating on browser tab \(targetId) at the same time and it could not be acquired in time. Open a new tab (action: new_tab, or pass a different tab_id) and retry this action there so it can run in parallel."))
        }
        let serialAcquiredMs = Int((CFAbsoluteTimeGetCurrent() - serialWaitStart) * 1000)
        if serialAcquiredMs > 100 {
            logger.info("[PoolTiming] serial_slot_waited elapsed=\(serialAcquiredMs)ms tab=\(targetId)")
        }
        defer { releaseSerialSlot() }

        // The user may have taken over while this action was queued behind a
        // predecessor in the same tab's serial chain.
        if controlState == .user, !Self.readOnlyActions.contains(input.action) {
            return takeoverRefusal()
        }

        // Re-resolve the tab by id — `idx` was computed before the serial-slot
        // await, during which the tabs array may have changed (idle reclaim,
        // close, registry preempt). Indexing the stale `idx` could trap.
        guard let liveIdx = tabs.firstIndex(where: { $0.id == targetId }) else {
            return .error("No tab with id \(targetId). Use list_tabs to see open tabs.")
        }

        // Delegate to the tab's BrowserUseManager.
        // Capture the manager reference before await — the tabs array may mutate
        // (e.g. closeTab / idle reclaim / registry preempt) while we're suspended.
        let manager = tabs[liveIdx].manager

        // set_user_agent switches THIS tab and nothing else. Done here, inside
        // the tab's serial slot, so the WebView is not swapped under another
        // action that is still running on the same tab.
        if input.action == .setUserAgent, let profile = input.userAgent {
            return setUserAgent(profile, onTab: targetId, manager: manager)
        }
        let managerStart = CFAbsoluteTimeGetCurrent()
        logger.info("[PoolTiming] manager_execute_start elapsed=\(Int((managerStart - poolStart) * 1000))ms tab=\(targetId) action=\(input.action.rawValue)")
        let result: BrowserActionResult
        do {
            // [T-browser-bg-stuck-diag] Hard wall-clock ceiling on a single
            // browser action. Beyond this the tab is considered DEAD, not slow:
            // on-device testing proved a WebContent process whose JS main thread
            // is pinned cannot be recovered by stopLoading / reload / loadBlank
            // (those messages queue behind the wedged thread and never run) — the
            // ONLY recovery is to drop the whole WKWebView and open a fresh tab
            // (a new tab gets its own WebContent process, verified responsive in
            // ~3ms). So on timeout we do exactly that and hand the model the new
            // tab id plus the reason, letting it decide whether to retry there.
            var r = try await withDeadOnTimeout(
                targetId: targetId,
                action: input.action.rawValue,
                url: input.url ?? manager.currentURL
            ) {
                try await manager.execute(action: input)
            }
            let managerMs = Int((CFAbsoluteTimeGetCurrent() - managerStart) * 1000)
            logger.info("[PoolTiming] manager_execute_done elapsed=\(managerMs)ms tab=\(targetId) action=\(input.action.rawValue)")
            // If the registry preempted this tab while we were awaiting,
            // surface the friendly retry hint instead of whatever WebKit
            // produced as the final state. Consume the flag so the agent's
            // retry sails through.
            if preemptedTabIds.remove(targetId) != nil {
                return .error("Browser tab \(targetId) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            let pageURL = manager.webView.url?.absoluteString ?? manager.currentURL
            if !pageURL.isEmpty {
                r.pageURL = pageURL
            }
            // Stamp the verified targetId — NOT selectedTabId or anything else
            // the manager might infer from global state — onto both the
            // structured result and the human-readable text. Fan-out paths can
            // mutate selectedTabId mid-flight, so only `targetId` (computed at
            // dispatch time) is guaranteed to identify the tab this action
            // actually ran on. [T-ios-browser-result-tab-id]
            // [T-browser-tab-reuse-silent-switch] If this navigate repurposed an
            // idle tab that had a different page, prepend an explicit heads-up so
            // the model updates its mental model (tab N is now this URL, no longer
            // the old one) rather than operating on stale assumptions.
            if let sw = reusedTabSwitch, sw.tabId == targetId, r.success {
                r.text = "[Note] Reused existing tab \(targetId): it previously showed \(sw.oldURL) and has now been navigated to the new URL. Any earlier content on tab \(targetId) is gone; use tab_id \(targetId) to operate on THIS page.\n" + r.text
            }
            // [T-ios-js-dialogs-256] If this tab's page tried to open an
            // alert/confirm/prompt, the agent browser answered it with a
            // default rather than showing a modal (which would hang an
            // unattended loop). Surface that here, on the next result for this
            // tab, so the model can react — otherwise the interception is
            // invisible and it keeps assuming the page did what it asked.
            // Prepended so it is read before the result it qualifies; draining
            // clears the queue, so each dialog is reported exactly once.
            if let dialogReport = manager.drainInterceptedDialogReport() {
                r.text = dialogReport + r.text
            }
            result = Self.stampTabId(r, targetId: targetId)
        } catch let dead as ActionDeadTimeout {
            if dead.isTakeover {
                // 接管 interrupted this action. Do NOT rebuild the tab: the
                // user is now looking at that very page.
                let pageURL = manager.webView.url?.absoluteString ?? manager.currentURL
                var r = BrowserActionResult.userTakeover(pageURL: pageURL,
                                                        pageTitle: manager.pageTitle)
                r.tabId = targetId
                if let i = tabs.firstIndex(where: { $0.id == targetId }) {
                    tabs[i].inUse = false
                    tabs[i].graceExpiryTask?.cancel()
                    tabs[i].graceExpiryTask = nil
                }
                logger.info("[Takeover] action cancelled tab=\(targetId) action=\(input.action.rawValue) url=\(pageURL.prefix(80))")
                return r
            }
            // [T-browser-bg-stuck-diag] The action blew past actionDeadTimeout
            // — or [T-browser-cli-timeout-reclaim] its caller gave up on it
            // first (`abortedByCaller`) and asked for the tab back.
            // The tab is wedged and unrecoverable in place; drop it and open a
            // fresh one, then tell the model exactly what happened, on which new
            // tab it can continue, and (if known) the URL that hung — so it can
            // decide to retry there, try a different approach, or give up.
            let elapsed = Int(CFAbsoluteTimeGetCurrent() - managerStart)
            // [T-ios-js-dialogs-256] Drain BEFORE rebuildDeadTab, which destroys
            // this manager and would take the queue with it. A page that opened
            // a confirm() and then wedged is precisely the case where knowing
            // about the dialog explains the wedge, so this is the last chance to
            // tell the model — losing it here would be a silent, permanent drop.
            let deadTabDialogReport = manager.drainInterceptedDialogReport()
            let (newId, deadURL) = rebuildDeadTab(oldId: targetId)
            logger.warning("[PoolTiming] action_DEAD elapsed=\(elapsed)s tab=\(targetId) action=\(input.action.rawValue) abortedByCaller=\(dead.abortedByCaller) → rebuilt as tab \(newId)")
            let urlPart = deadURL.isEmpty ? "" : " while on \(deadURL)"
            let ranFor = dead.abortedByCaller ? elapsed : Int(Self.actionDeadTimeout)
            var msg = "Browser tab \(targetId) became unresponsive: the '\(input.action.rawValue)' action ran for over \(ranFor)s without completing\(urlPart) — its web page most likely wedged (an infinite script, a never-completing navigation, or a background-suspended renderer). The tab could not be recovered and was closed. A fresh tab (id \(newId)) has been opened for you. To continue, retry on tab_id \(newId)"
            if !deadURL.isEmpty { msg += " (e.g. navigate it to \(deadURL) again, or take a different approach if that page keeps hanging)" }
            msg += "."
            var r = BrowserActionResult(text: deadTabDialogReport.map { $0 + msg } ?? msg,
                                        success: false, tabId: newId)
            r.pageURL = deadURL.isEmpty ? nil : deadURL
            return r
        } catch {
            // Same check on the error path — preempt may have torn the
            // WebView out from under the action.
            if preemptedTabIds.remove(targetId) != nil {
                return .error("Browser tab \(targetId) was reclaimed under memory pressure (another session needed the slot). Please retry — the page URL has been saved and will be restored.")
            }
            throw error
        }
        persistURLs()
        let totalMs = Int((CFAbsoluteTimeGetCurrent() - poolStart) * 1000)
        logger.info("[PoolTiming] total elapsed=\(totalMs)ms tab=\(targetId) action=\(input.action.rawValue) success=\(result.success)")
        return result
    }

    /// Hard ceiling for a single browser action. Past this the tab is treated as
    /// DEAD (WebContent wedged / navigation never completing / JS thread pinned),
    /// not merely slow, and is dropped-and-rebuilt. Chosen well above any
    /// legitimate action: navigation's own timeout is 30s and the serial wait is
    /// 60s, so 300s only ever trips on a genuine wedge. [T-browser-bg-stuck-diag]
    #if DEBUG
    /// Test override so device tests can trip the dead-tab path without waiting
    /// the full 300s. Set via debug.browser.setDeadTimeout; nil → the real value.
    static var actionDeadTimeoutOverride: TimeInterval?
    static var actionDeadTimeout: TimeInterval { actionDeadTimeoutOverride ?? 300 }
    #else
    static let actionDeadTimeout: TimeInterval = 300
    #endif

    /// Thrown internally by `withDeadOnTimeout` when the wall clock elapses, or
    /// when the action is aborted from outside (`abortedByCaller`: the awaiting
    /// task was cancelled, or `abortAndRebuildTab` fired).
    private struct ActionDeadTimeout: Error {
        var abortedByCaller = false
        /// True when the interruption came from 接管 rather than a wedged tab.
        var isTakeover = false
    }

    /// One-shot race arbiter: exactly one of {operation completes, timer fires}
    /// resumes the awaiting continuation; the other's `finish` is dropped. The
    /// two racers land on different threads (a Task vs a GCD timer queue), hence
    /// the lock + `@unchecked Sendable`. `finish` may be called before `attach`
    /// (timer wins instantly), so a pending result is buffered until attach.
    private final class RaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var cont: CheckedContinuation<BrowserActionResult, Error>?
        private var pending: Result<BrowserActionResult, Error>?
        var onFinish: (() -> Void)?

        func attach(_ c: CheckedContinuation<BrowserActionResult, Error>) {
            lock.lock()
            if let p = pending {                 // result already arrived
                lock.unlock(); c.resume(with: p); return
            }
            cont = c
            lock.unlock()
        }

        func finish(_ result: Result<BrowserActionResult, Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = cont; cont = nil
            if c == nil { pending = result }     // finished before attach
            let cleanup = onFinish; onFinish = nil
            lock.unlock()
            cleanup?()
            c?.resume(with: result)
        }
    }

    /// Run `operation` with a wall-clock deadline. If it completes first, return
    /// its result. If the deadline hits first, the underlying WKWebView is
    /// unrecoverable (proven on device: stopLoading/reload/loadBlank all fail to
    /// unwedge a pinned WebContent) — so close the poisoned tab, open a fresh one
    /// (fresh WebContent process), and return an informative result carrying the
    /// NEW tab id and the reason, so the model can decide whether to retry there.
    ///
    /// The timer is a GCD wall-clock source, NOT `Task.sleep`: on-device testing
    /// showed Task timers get stretched several-fold under background CPU
    /// throttling even when the app is kept alive by audio, whereas a GCD timer
    /// on a background queue keeps firing on schedule.
    private func withDeadOnTimeout(
        targetId: Int,
        action: String,
        url: String,
        _ operation: @escaping () async throws -> BrowserActionResult
    ) async throws -> BrowserActionResult {
        let start = CFAbsoluteTimeGetCurrent()
        // Read the MainActor-isolated timeout once, here, so the nonisolated
        // timer task below captures a plain value.
        let deadline = Self.actionDeadTimeout
        logger.info("[DeadTimeout] armed deadline=\(Int(deadline))s tab=\(targetId) action=\(action)")
        // A structured TaskGroup will NOT work here: it implicitly awaits ALL
        // child tasks before returning, and the wedged `operation()` doesn't
        // honour cooperative cancellation (it's parked on a WebKit callback that
        // never fires), so the group would block on it for the full 40s+ anyway
        // — verified on device. Instead race two independent tasks through a
        // one-shot box: whoever resumes first wins, and we DON'T wait for the
        // loser. The wedged operation task is abandoned (it leaks until its
        // WebView is torn down by the tab rebuild, which is exactly what we do).
        // A caller that has already given up must not start work on the tab:
        // its cancellation would fire the abort below at once and rebuild a
        // tab that was never wedged.
        try Task.checkCancellation()
        let box = RaceBox()
        let opTask = Task {
            do { let r = try await operation(); box.finish(.success(r)) }
            catch { box.finish(.failure(error)) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + deadline)
        timer.setEventHandler {
            logger.warning("[DeadTimeout] FIRED tab=\(targetId) action=\(action)")
            box.finish(.failure(ActionDeadTimeout()))
        }
        timer.resume()
        box.onFinish = { timer.cancel(); opTask.cancel() }

        // [T-browser-cli-timeout-reclaim] Let the action be ended from outside
        // too — by `abortAndRebuildTab`, or by cancelling the task awaiting us
        // (the CLI bridge does that when the sandbox's 90s wait expires). The
        // continuation below ignores cancellation on its own, so without this a
        // caller that already gave up kept the tab's serial slot for the full
        // `deadline`, and every follow-up command on that tab timed out on it.
        let abortToken = nextSerialToken
        nextSerialToken &+= 1
        let abort: @Sendable () -> Void = {
            logger.warning("[DeadTimeout] ABORTED by caller tab=\(targetId) action=\(action)")
            box.finish(.failure(ActionDeadTimeout(abortedByCaller: true)))
        }
        inFlightAborts[targetId] = (abortToken, abort)
        // Separate channel so 接管 can end the wait without asking the
        // dead-tab path to rebuild the WKWebView the user is taking over.
        let takeoverAbort: @Sendable () -> Void = {
            logger.warning("[Takeover] cancelling in-flight action tab=\(targetId) action=\(action)")
            box.finish(.failure(ActionDeadTimeout(abortedByCaller: true, isTakeover: true)))
        }
        inFlightTakeoverAborts[targetId] = (abortToken, takeoverAbort)
        defer {
            if inFlightAborts[targetId]?.token == abortToken {
                inFlightAborts.removeValue(forKey: targetId)
            }
            if inFlightTakeoverAborts[targetId]?.token == abortToken {
                inFlightTakeoverAborts.removeValue(forKey: targetId)
            }
        }

        let raced: BrowserActionResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.attach(cont)
            }
        } onCancel: {
            abort()
        }
        return raced
    }

    /// [T-browser-cli-timeout-reclaim] OpenZe#245. Abort the action holding
    /// `tabId`'s serial slot and replace the tab with a fresh WebView.
    ///
    /// Everything runs through the action's own dead-tab path: its op task is
    /// cancelled, `rebuildDeadTab` swaps in a fresh tab, and the slot is
    /// released by `executeInner`'s `defer`. That way the slot is never freed
    /// while the old action still thinks it holds it, and the tab is never
    /// rebuilt twice.
    ///
    /// Returns false when nothing is running on `tabId`. The tab is then left
    /// alone: nothing shows it is wedged, and rebuilding it would throw away a
    /// working page.
    @discardableResult
    func abortAndRebuildTab(tabId: Int) -> Bool {
        guard let entry = inFlightAborts[tabId] else {
            logger.info("[DeadTimeout] abortAndRebuildTab tab=\(tabId): no action in flight — tab left as is")
            return false
        }
        entry.abort()
        return true
    }

    /// Drop a wedged tab and open a fresh replacement. Returns the new tab id.
    /// Separated so both the timeout path and future callers can reuse it.
    /// Returns (newTabId, deadURL). deadURL is the last-known URL of the wedged
    /// tab, surfaced to the model so it can choose to re-navigate.
    private func rebuildDeadTab(oldId: Int) -> (newId: Int, deadURL: String) {
        // Force-remove the poisoned tab. Its WKWebView is unrecoverable (proven
        // on device), so we simply drop it — removing it from `tabs` frees its
        // slot in the registry, which counts live tabs directly (no separate
        // release call). Stash the last-known URL for the model.
        let deadURL = tabs.first(where: { $0.id == oldId })?.manager.currentURL ?? ""
        tabs.removeAll { $0.id == oldId }
        discardTabSnapshot(forTabId: oldId)
        if selectedTabId == oldId { selectedTabId = tabs.first?.id ?? 0 }

        // Open a fresh tab (its own WebContent process). newTab selects it.
        let r = newTab(url: nil)
        let newId = r.tabId ?? selectedTabId
        logger.warning("[PoolTiming] tab_rebuilt oldTab=\(oldId) newTab=\(newId) deadURL=\(deadURL.prefix(60)) — dead tab dropped, fresh WebContent opened")
        return (newId, deadURL)
    }

    /// Release all tabs (called when isProcessing → false). Keeps WKWebViews alive
    /// but stamps lastActivityDate so the idle timer can reclaim them later.
    func releaseAllTabs() {
        let now = Date()
        for i in tabs.indices {
            tabs[i].graceExpiryTask?.cancel()
            tabs[i].graceExpiryTask = nil
            tabs[i].inUse = false
            tabs[i].lastActivityDate = now
        }
        persistURLs()
        if controlState == .agent { controlState = .idle }
        logger.info("Released all tabs (\(self.tabs.count) total)")
    }

    /// Stamp `targetId` onto a tab-contextual result so the Agent can see
    /// exactly which tab it just operated on, with no need to guess for
    /// follow-up reads/scrolls. Sets the structured `tabId` field and appends
    /// a `  tab_id: <N>` line to the human-readable text in the same indent
    /// style as the existing `Title:` / `Viewport:` lines. Idempotent — if
    /// the text already mentions `tab_id:` (e.g. `newTab` already embeds it
    /// in its narrative), skip the append. [T-ios-browser-result-tab-id]
    private static func stampTabId(_ result: BrowserActionResult, targetId: Int) -> BrowserActionResult {
        var r = result
        r.tabId = targetId
        if !r.text.contains("tab_id:") {
            // Append on its own indented line, matching the existing key:value
            // style. Adds a leading newline iff the text isn't empty and
            // doesn't already end with one.
            let needsNewline = !r.text.isEmpty && !r.text.hasSuffix("\n")
            r.text = r.text + (needsNewline ? "\n" : "") + "  tab_id: \(targetId)"
        }
        return r
    }

    /// Arm a 15-second grace window during which `inUse` stays true for `tabId`.
    /// Re-arming cancels any earlier in-flight grace task for the same tab, so
    /// a back-to-back action against this tab simply pushes the release
    /// further out — the agent's follow-up reads/scrolls keep the tab to
    /// themselves while another agent's parallel implicit-tab `navigate` will
    /// see `inUse=true` and fan out to a fresh tab.
    /// [T-browser-implicit-tab-inuse-until-load-ios]
    private func armPostActionGrace(tabId: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[idx].graceExpiryTask?.cancel()
        let graceNs = UInt64(Self.postActionGraceSeconds * 1_000_000_000)
        tabs[idx].graceExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: graceNs)
            guard !Task.isCancelled, let self else { return }
            if let i = self.tabs.firstIndex(where: { $0.id == tabId }) {
                self.tabs[i].inUse = false
                self.tabs[i].graceExpiryTask = nil
            }
            self.settleControlAfterActionIfIdle()
        }
    }

    /// After the last tab's grace window expires (or a metadata-only action
    /// returns), an agent-controlled pool goes back to idle. Never overrides
    /// `.user` — takeover persists until the explicit 交还.
    private func settleControlAfterActionIfIdle() {
        guard controlState == .agent else { return }
        if !tabs.contains(where: { $0.inUse }) {
            controlState = .idle
        }
    }

    /// Touch the activity timestamp for the selected tab (called by UI interactions).
    func touchActivity() {
        if let idx = tabs.firstIndex(where: { $0.id == selectedTabId }) {
            tabs[idx].lastActivityDate = Date()
        }
    }

    // MARK: - User Takeover (P3)

    /// The user tapped 接管. State flips first (so no queued action can slip
    /// through), then every tab's in-flight agent action is interrupted via
    /// the per-tab serial chain. Returns the page the user landed on.
    @discardableResult
    func userTakeover() -> BrowserActionResult {
        guard controlState != .user else {
            let snap = selectedPageSnapshot()
            return BrowserActionResult(text: "User already controls the browser.",
                                       pageURL: snap.url.isEmpty ? nil : snap.url,
                                       control: .user)
        }
        controlState = .user
        let snap = selectedPageSnapshot()

        // Stop in-flight work and clear any post-action grace so `inUse`
        // cannot keep the agent's claim on a tab the user now owns.
        for i in tabs.indices {
            tabs[i].inUse = false
            tabs[i].graceExpiryTask?.cancel()
            tabs[i].graceExpiryTask = nil
        }
        for tab in tabs {
            if let entry = inFlightTakeoverAborts[tab.id] { entry.abort() }
            tab.manager.stopLoading()
        }

        enqueueControlEvent("<system-reminder>用户已接管浏览器，当前页面："
            + "\(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url)。交还前不要操作浏览器。</system-reminder>")
        onControlStateChange?(BrowserControlEvent(kind: .takeover, state: .user,
                                                  url: snap.url, title: snap.title))
        logger.info("[Takeover] user took control url=\(snap.url.prefix(80))")
        return BrowserActionResult(text: "User took over the browser.",
                                   pageURL: snap.url.isEmpty ? nil : snap.url,
                                   control: .user)
    }

    /// Clear every tab's agent claim and interrupt in-flight work before a
    /// model-requested handover gives the browser to the user.
    private func cancelAgentWorkForUserControl() {
        for i in tabs.indices {
            tabs[i].inUse = false
            tabs[i].graceExpiryTask?.cancel()
            tabs[i].graceExpiryTask = nil
        }
        for tab in tabs {
            if let entry = inFlightTakeoverAborts[tab.id] { entry.abort() }
            tab.manager.stopLoading()
        }
    }

    // MARK: - Requested Takeover (P3.1)

    /// Agent-initiated handover used by the `browser_request_takeover` tool.
    /// This is the waiting action itself: it flips control to `.user` with a
    /// `pendingTakeoverRequest` marker, fires the sheet's presentation
    /// publisher, then suspends on a continuation until the user taps 完成
    /// (`completeTakeoverRequest`) or closes/cancels (`cancelTakeoverRequest`).
    /// There is deliberately no timeout task and no polling loop.
    func requestTakeover(reason: String) async -> BrowserActionResult {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .error("request_takeover requires a non-empty `reason` describing what the user should do.")
        }
        guard controlState != .user else {
            let snap = selectedPageSnapshot()
            return .userTakeover(pageURL: snap.url, pageTitle: snap.title)
        }

        // A handover without a page is still a valid request (e.g. login before
        // any navigation) — let the sheet open with its normal empty tab.
        if tabs.isEmpty { ensureTabForUI() }

        let request = BrowserTakeoverRequestInfo(id: UUID(), reason: trimmed)
        controlState = .user
        pendingTakeoverRequest = request
        let snap = selectedPageSnapshot()

        cancelAgentWorkForUserControl()

        enqueueControlEvent("<system-reminder>模型请求用户接管浏览器，原因：\(trimmed)。当前页面："
            + "\(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url)。用户完成前不要操作浏览器。</system-reminder>")
        onControlStateChange?(BrowserControlEvent(kind: .requestedTakeover, state: .user,
                                                  url: snap.url, title: snap.title,
                                                  requested: true, reason: trimmed))
        logger.info("[Takeover] model requested user takeover reason=\(trimmed.prefix(80)) url=\(snap.url.prefix(80))")

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<BrowserActionResult, Never>) in
                if let buffered = bufferedTakeoverRequestResult {
                    bufferedTakeoverRequestResult = nil
                    if buffered.id == request.id {
                        continuation.resume(returning: buffered.result)
                    } else {
                        takeoverRequestContinuation = continuation
                    }
                } else {
                    takeoverRequestContinuation = continuation
                }
            }
        } onCancel: {
            // Session Stop cancels the tool task. Resume the waiter so the
            // continuation cannot outlive the turn; the result is ignored by
            // the cancelled turn but state must still go back to idle.
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.finishTakeoverRequest(id: request.id, outcome: .cancelled(sessionStopped: true))
            }
        }
    }

    /// User tapped 完成 in the request banner or the sheet's existing 完成
    /// button. Returns the result that resumes the waiting tool call.
    @discardableResult
    func completeTakeoverRequest() -> BrowserActionResult {
        guard let request = pendingTakeoverRequest else {
            let snap = selectedPageSnapshot()
            return BrowserActionResult(text: "No pending browser takeover request.",
                                       pageURL: snap.url.isEmpty ? nil : snap.url,
                                       control: controlState)
        }
        return finishTakeoverRequest(id: request.id, outcome: .completed)
    }

    /// User closed the sheet or tapped 取消 while a request was pending.
    @discardableResult
    func cancelTakeoverRequest() -> BrowserActionResult {
        guard let request = pendingTakeoverRequest else {
            let snap = selectedPageSnapshot()
            return BrowserActionResult(text: "No pending browser takeover request.",
                                       pageURL: snap.url.isEmpty ? nil : snap.url,
                                       control: controlState)
        }
        return finishTakeoverRequest(id: request.id, outcome: .cancelled(sessionStopped: false))
    }

    private enum TakeoverRequestOutcome {
        case completed
        case cancelled(sessionStopped: Bool)
    }

    /// Single finish path for both UI buttons and task cancellation. Guarding
    /// on the request id makes duplicate taps / a late cancellation a no-op,
    /// so the checked continuation can never be resumed twice.
    @discardableResult
    private func finishTakeoverRequest(id: UUID,
                                       outcome: TakeoverRequestOutcome) -> BrowserActionResult {
        guard let request = pendingTakeoverRequest, request.id == id else {
            let snap = selectedPageSnapshot()
            return BrowserActionResult(text: "No pending browser takeover request.",
                                       pageURL: snap.url.isEmpty ? nil : snap.url,
                                       control: controlState)
        }
        pendingTakeoverRequest = nil
        let snap = selectedPageSnapshot()
        let result: BrowserActionResult

        switch outcome {
        case .completed:
            // Explicit hand-back to the agent. Do not settle this to idle in
            // execute()'s wrapper: the result must say control: agent.
            controlState = .agent
            enqueueControlEvent("<system-reminder>用户已完成浏览器接管请求，当前页面："
                + "\(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url)。你可以继续操作浏览器。</system-reminder>")
            onControlStateChange?(BrowserControlEvent(kind: .handBack, state: .agent,
                                                      url: snap.url, title: snap.title,
                                                      requested: true, reason: request.reason))
            result = BrowserActionResult(
                text: "User completed the requested browser task.\n"
                    + "Current page: \(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url)",
                success: true,
                pageURL: snap.url.isEmpty ? nil : snap.url,
                control: .agent
            )
            logger.info("[Takeover] requested takeover completed url=\(snap.url.prefix(80))")

        case .cancelled(let sessionStopped):
            controlState = .idle
            result = .userCancelled(pageURL: snap.url, pageTitle: snap.title,
                                    sessionStopped: sessionStopped)
            logger.info("[Takeover] requested takeover cancelled sessionStopped=\(sessionStopped) url=\(snap.url.prefix(80))")
        }

        if let continuation = takeoverRequestContinuation {
            takeoverRequestContinuation = nil
            continuation.resume(returning: result)
        } else {
            bufferedTakeoverRequestResult = (request.id, result)
        }
        return result
    }

    /// The user tapped 交还. State returns to idle; the event carries the page
    /// they stopped on so the model can pick up without asking.
    @discardableResult
    func handControlBack() -> BrowserActionResult {
        // While a model request is pending, 交还 / 完成 both mean "the user is
        // done" and must resume the waiting tool call through the same path.
        if pendingTakeoverRequest != nil {
            return completeTakeoverRequest()
        }
        guard controlState == .user else {
            let snap = selectedPageSnapshot()
            return BrowserActionResult(text: "The user does not currently hold control.",
                                       pageURL: snap.url.isEmpty ? nil : snap.url,
                                       control: controlState)
        }
        controlState = .idle
        let snap = selectedPageSnapshot()
        enqueueControlEvent("<system-reminder>用户已交还浏览器控制权，当前页面："
            + "\(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url)。你可以继续操作浏览器。</system-reminder>")
        onControlStateChange?(BrowserControlEvent(kind: .handBack, state: .idle,
                                                  url: snap.url, title: snap.title))
        logger.info("[Takeover] user handed control back url=\(snap.url.prefix(80))")
        return BrowserActionResult(text: "User handed browser control back.",
                                   pageURL: snap.url.isEmpty ? nil : snap.url,
                                   control: .idle)
    }

    /// Event lines for the next browser tool result, formatted as the existing
    /// `<system-reminder>` session convention. Drains exactly once.
    func drainControlEventText() -> String? {
        guard !pendingControlEvents.isEmpty else { return nil }
        let text = pendingControlEvents.joined(separator: "\n")
        pendingControlEvents.removeAll()
        return text
    }

    /// Prompt-level status so the model also sees control at turn start, even
    /// before it issues another browser tool call.
    var controlPromptFragment: String {
        switch controlState {
        case .idle:
            return ""
        case .agent:
            return "\n\n<browser_control>Browser control: agent. The user has not taken over.</browser_control>"
        case .user:
            let snap = selectedPageSnapshot()
            if let request = pendingTakeoverRequest {
                return "\n\n<browser_control>Browser control: USER (agent requested takeover: \(request.reason)). "
                    + "The user is performing this step now. Current page: "
                    + "\(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url). "
                    + "Wait for the browser_request_takeover tool result; do not perform browser write actions "
                    + "until it returns. Read-only actions are allowed and report control: user.</browser_control>"
            }
            return "\n\n<browser_control>Browser control: USER. The user has taken over the browser. "
                + "Current page: \(snap.title.isEmpty ? "(untitled)" : snap.title) \(snap.url). "
                + "Do not perform browser write actions (navigate, click, type, scroll, new_tab, close_tab, "
                + "set_user_agent, set_viewport, execute_js) until the user hands control back — they return "
                + "user_takeover. Read-only actions are allowed and report control: user.</browser_control>"
        }
    }

    private func takeoverRefusal() -> BrowserActionResult {
        let snap = selectedPageSnapshot()
        return .userTakeover(pageURL: snap.url, pageTitle: snap.title)
    }

    private func selectedPageSnapshot() -> (url: String, title: String) {
        guard let manager = activeManager ?? tabs.first?.manager else { return ("", "") }
        let url = manager.webView.url?.absoluteString ?? manager.currentURL
        return (url, manager.pageTitle)
    }

    private func enqueueControlEvent(_ text: String) {
        pendingControlEvents.append(text)
        while pendingControlEvents.count > Self.maxPendingControlEvents {
            pendingControlEvents.removeFirst()
        }
    }

    private func resetControlForNewSession() {
        if let request = pendingTakeoverRequest {
            _ = finishTakeoverRequest(id: request.id, outcome: .cancelled(sessionStopped: true))
        }
        controlState = .idle
        pendingControlEvents.removeAll()
    }

    // MARK: - Tab Overview Snapshots

    private func storeTabSnapshot(_ image: UIImage, forTabId id: Int) {
        tabSnapshots[id] = image
        tabSnapshotOrder.removeAll { $0 == id }
        tabSnapshotOrder.append(id)
        while tabSnapshotOrder.count > Self.maxTabSnapshots {
            let evictedId = tabSnapshotOrder.removeFirst()
            tabSnapshots.removeValue(forKey: evictedId)
        }
    }

    // MARK: - Idle Eviction

    /// Remove tabs that have been idle (not in use) for longer than `idleTimeout`.
    /// Saves their URLs so they can be restored on next use.
    private func evictIdleTabs() {
        let now = Date()
        var evicted = 0
        tabs.removeAll { tab in
            guard !tab.inUse else { return false }
            let idle = now.timeIntervalSince(tab.lastActivityDate)
            if idle >= Self.idleTimeout {
                // Save URL for restoration
                let url = tab.manager.currentURL
                if !url.isEmpty {
                    savedURLs[tab.id] = url
                }
                logger.info("Evicting idle tab \(tab.id) (idle \(String(format: "%.0f", idle))s, url=\(url.prefix(60)))")
                evicted += 1
                return true
            }
            return false
        }
        if evicted > 0 {
            // Fix selected tab if it was evicted
            if !tabs.contains(where: { $0.id == selectedTabId }) {
                selectedTabId = tabs.first?.id ?? 0
            }
            persistURLs()
            logger.info("Evicted \(evicted) idle tab(s), \(self.tabs.count) remaining")
        }
    }

    // MARK: - Private

    /// Create a BrowserUseManager wired to this pool.
    private func makeManager() -> BrowserUseManager {
        syncGlobalDefaultsFromStore()
        let ua = resolvedUserAgentString()
        let vp = resolvedViewportSize()
        let manager = BrowserUseManager(profile: userAgentProfile, customString: ua,
                                        viewportWidth: vp.width, viewportHeight: vp.height)
        wireManager(manager)
        return manager
    }

    /// Wire a manager's handlers to this pool (window.open, window.close, downloads).
    private func wireManager(_ manager: BrowserUseManager) {
        manager.newWindowHandler = { [weak self] configuration, url in
            self?.openWithConfiguration(configuration, url: url)
        }
        manager.closeHandler = { [weak self] webView in
            self?.closeWebView(webView)
        }
        // Refresh this tab's overview thumbnail after each completed load.
        // The closure is weak on both sides; the pool owns the manager.
        manager.onPageLoadFinished = { [weak self, weak manager] in
            guard let self, let manager else { return }
            self.scheduleTabSnapshotAfterLoad(manager: manager)
        }
        // Downloads land in this session's /var/ze/workspace/ so the agent
        // can read and operate on them in follow-up turns.
        manager.sessionIdProvider = { [weak self] in self?.sessionId }
        // [BrowserToolDiag] Let the manager name its own tab when its WebContent
        // process dies. Resolved by identity at call time rather than captured:
        // wireManager runs before the Tab is appended, and ids don't move once
        // assigned, so a lookup stays correct across close/reclaim/fan-out.
        manager.tabIdProvider = { [weak self, weak manager] in
            guard let self, let manager else { return nil }
            return self.tabs.first(where: { $0.manager === manager })?.id
        }
    }

    /// The effective UA string for the current profile.
    func resolvedUserAgentString() -> String? {
        if userAgentProfile == .custom {
            return customUserAgentString.isEmpty ? nil : customUserAgentString
        }
        return userAgentProfile.userAgentString
    }

    /// Resolved viewport for new WKWebViews and `desktopViewportScript` width.
    /// Priority: session override > global custom > UA profile default.
    func resolvedViewportSize() -> (width: Int, height: Int) {
        resolvedViewportSize(for: userAgentProfile)
    }

    /// The same priority for a tab whose own profile is `profile` - a tab can
    /// differ from the global default after `set_user_agent`, or because the
    /// default changed after the tab was opened.
    func resolvedViewportSize(for profile: UserAgentProfile) -> (width: Int, height: Int) {
        if sessionViewportWidth > 0 && sessionViewportHeight > 0 {
            return (sessionViewportWidth, sessionViewportHeight)
        }
        if customViewportWidth > 0 && customViewportHeight > 0 {
            return (customViewportWidth, customViewportHeight)
        }
        return profile.viewportSize
    }

    /// Bring this pool's copy of the GLOBAL browser defaults (UA profile,
    /// custom UA string, global custom viewport) up to what UserDefaults holds
    /// now. Called before every tab is created, never to change a tab that is
    /// already open.
    ///
    /// Each chat owns a pool, and a pool used to read these keys once, in
    /// `init`. Browser Settings edits the home screen's own pool and
    /// ze-config writes UserDefaults directly, so a chat that was already
    /// in memory kept opening tabs with the profile it had read at creation -
    /// "the browser is set to desktop but the session is still mobile"
    /// (ISS-033) - until the app was relaunched.
    func syncGlobalDefaultsFromStore() {
        let defaults = UserDefaults.standard
        let profile = defaults.string(forKey: Self.uaProfileKey).flatMap(UserAgentProfile.init) ?? .mobileSafari
        let custom = defaults.string(forKey: Self.uaCustomStringKey) ?? ""
        let width = defaults.integer(forKey: Self.viewportWidthKey)
        let height = defaults.integer(forKey: Self.viewportHeightKey)
        // Assign only on change: these are @Published and every open browser
        // panel observes the pool.
        if userAgentProfile != profile { userAgentProfile = profile }
        if customUserAgentString != custom { customUserAgentString = custom }
        if customViewportWidth != width { customViewportWidth = width }
        if customViewportHeight != height { customViewportHeight = height }
    }

    /// Set the global custom viewport (Browser Settings). Persists to
    /// UserDefaults as the default for tabs opened from now on, in every chat.
    /// Tabs that are already open keep the size they have. Pass
    /// width=height=0 to clear.
    func setGlobalViewport(width: Int, height: Int) {
        customViewportWidth = max(0, width)
        customViewportHeight = max(0, height)
        UserDefaults.standard.set(customViewportWidth, forKey: Self.viewportWidthKey)
        UserDefaults.standard.set(customViewportHeight, forKey: Self.viewportHeightKey)
    }

    /// Set a session-scoped viewport override. Persisted alongside the
    /// session's tab URL file so reopening the session restores it.
    /// Rebuilds all existing tab WebViews.
    func setSessionViewport(width: Int, height: Int) {
        sessionViewportWidth = max(0, width)
        sessionViewportHeight = max(0, height)
        applyViewportToAllTabs()
        persistURLs()
    }

    /// Clear the session viewport override so tabs fall back to the global
    /// setting. Does not touch UserDefaults.
    func resetSessionViewport() {
        sessionViewportWidth = 0
        sessionViewportHeight = 0
        applyViewportToAllTabs()
        persistURLs()
    }

    /// Re-apply the session viewport (set or just cleared) to every live tab.
    /// Each tab keeps its OWN profile and UA string; only its size changes, and
    /// with no session override it falls back to the global custom viewport as
    /// it stands now, then to its own profile's default.
    private func applyViewportToAllTabs() {
        syncGlobalDefaultsFromStore()
        for tab in tabs {
            let profile = tab.manager.currentProfile
            let vp = resolvedViewportSize(for: profile)
            tab.manager.setViewport(width: vp.width, height: vp.height,
                                    profile: profile, customUA: tab.manager.effectiveUserAgent)
        }
    }

    /// Browser Settings: make `profile` the global default and persist it.
    /// Every pool reads it back when it next creates a tab
    /// (`syncGlobalDefaultsFromStore`), so it applies to new tabs in every
    /// chat, old or new. Tabs that are already open are left exactly as they
    /// are - same UA, same viewport, same loaded page.
    func setUserAgentProfile(_ profile: UserAgentProfile) {
        userAgentProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: Self.uaProfileKey)
        // Always persist the latest custom string so edits made while already
        // on the custom profile survive across launches.
        UserDefaults.standard.set(customUserAgentString, forKey: Self.uaCustomStringKey)
    }

    /// `set_user_agent`: switch ONE tab to `profile`. Nothing is persisted and
    /// neither the global default nor any other tab changes; the tab goes back
    /// to the global default when it is rebuilt (closed and reopened, reclaimed
    /// while idle, replaced after a crash or timeout).
    private func setUserAgent(_ profile: UserAgentProfile, onTab tabId: Int,
                              manager: BrowserUseManager) -> BrowserActionResult {
        // The custom string and the global viewport are global settings too.
        syncGlobalDefaultsFromStore()
        let ua: String?
        if profile == .custom {
            guard !customUserAgentString.isEmpty else {
                return .error("set_user_agent: no custom user agent is set in Browser Settings. Use desktop_safari or mobile_safari. Nothing was changed.")
            }
            ua = customUserAgentString
        } else {
            ua = profile.userAgentString
        }
        // The viewport is recomputed for the NEW profile (session > global >
        // profile default) and applied in the same rebuild. Switching the UA
        // alone kept the old 390×844 frame, so `screenshot()`'s
        // `WKSnapshotConfiguration.rect = (0, 0, 390, 844)` captured only the
        // left half of a page laid out at desktop width - the "screenshot is
        // cropped" bug. `setViewport` sets profile, UA and size together and
        // rebuilds the WebView once.
        let vp = resolvedViewportSize(for: profile)
        manager.setViewport(width: vp.width, height: vp.height, profile: profile, customUA: ua)
        // The panel's title icon follows the selected tab's profile, which
        // lives on the manager; tell the pool's observers it may have changed.
        objectWillChange.send()
        logger.info("set_user_agent tab=\(tabId) profile=\(profile.rawValue) viewport=\(vp.width)x\(vp.height) globalDefault=\(self.userAgentProfile.rawValue)")
        return BrowserActionResult(
            text: "Tab \(tabId) switched to \(profile.rawValue) (\(vp.width)x\(vp.height)). This tab only, and temporary: other tabs keep their own profile, new tabs use the Browser Settings default (\(userAgentProfile.rawValue)), and this tab returns to that default if it is rebuilt.",
            tabId: tabId)
    }

    /// Restore a previously saved URL into a newly created tab.
    private func restoreSavedURL(for tabId: Int, manager: BrowserUseManager) {
        if let url = savedURLs.removeValue(forKey: tabId) {
            logger.info("Restoring saved URL for tab \(tabId): \(url.prefix(60))")
            manager.loadURL(url)
            persistURLs()
        }
    }

    /// Ensure tab 0 exists and return its ID.
    private func ensureDefaultTab() -> Int {
        if tabs.contains(where: { $0.id == 0 }) {
            return 0
        }
        return acquireTab()
    }
}
