import Combine
import Foundation
import UIKit
import UserNotifications

private let logger = AppLogger(category: "AIChatVM")

// MARK: - Session Activity Tracker

/// Tracks which sessions are currently processing, so the home screen
/// can display a spinner even when the user navigates away from the chat.
@MainActor
final class SessionActivityTracker: ObservableObject {
    static let shared = SessionActivityTracker()
    /// Session IDs that are currently processing (streaming / running tools).
    /// Canonical keys are real session IDs (UUIDs). Draft IDs are mirrored
    /// through `draftAliases` instead — see `setDraftAlias` — so the tracker
    /// only ever stores one entry per active session, preserving the
    /// "processing ends → entry clears" invariant that Live Activity relies
    /// on.
    @Published var activeSessions: Set<String> = []
    /// Maps a sidebar draft ID to its real session ID after ensureSession
    /// migrates from draft→real. Allows sidebar proxy rows that still
    /// identify themselves by draftId (ContentView's `displaySessions`) to
    /// reflect the live state of their underlying real session without
    /// double-inserting into `activeSessions`.
    @Published var draftAliases: [String: String] = [:]
    @Published var currentToolStatus: String = ""

    /// Per-session tool info for Live Activity carousel.
    struct SessionToolInfo {
        var title: String = ""
        var toolName: String = ""
        var toolStatus: String = ""
        var loopIteration: Int = 0
        /// When `toolName` last changed. Used to pick the most-recently-invoked
        /// tool across all sessions for the Dynamic Island minimal icon.
        var lastToolChange: Date = .distantPast
    }
    @Published var sessionToolInfo: [String: SessionToolInfo] = [:]

    /// The SF Symbol for the most-recently-invoked tool across all active
    /// sessions (the session whose `toolName` changed last). Drives the
    /// Dynamic Island minimal icon's "latest tool" frame. Nil when no active
    /// session has a tool yet.
    func latestToolName() -> String? {
        let active = activeSessions
        return sessionToolInfo
            .filter { active.contains($0.key) && !$0.value.toolName.isEmpty }
            .max { $0.value.lastToolChange < $1.value.lastToolChange }?
            .value.toolName
    }
    private var lastLiveActivityPush: Date = .distantPast
    private static let liveActivityThrottleInterval: TimeInterval = 5.0
    private var throttledUpdateWorkItem: DispatchWorkItem?

    func updateToolInfo(sessionId: String, toolName: String, toolStatus: String) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        let nameChanged = info.toolName != toolName
        let statusChanged = info.toolStatus != toolStatus
        info.toolName = toolName
        info.toolStatus = toolStatus
        if nameChanged {
            info.lastToolChange = Date()
        }
        sessionToolInfo[sessionId] = info
        guard nameChanged || statusChanged else { return }
        logger.info("[LiveActivity][toolInfo] sid=\(sessionId.prefix(8)) toolName=\(toolName) status=\(toolStatus) nameChanged=\(nameChanged)")
        if nameChanged {
            throttledUpdateWorkItem?.cancel()
            throttledUpdateWorkItem = nil
            lastLiveActivityPush = Date()
            BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolNameChange")
        } else {
            let elapsed = Date().timeIntervalSince(lastLiveActivityPush)
            if elapsed >= Self.liveActivityThrottleInterval {
                throttledUpdateWorkItem?.cancel()
                throttledUpdateWorkItem = nil
                lastLiveActivityPush = Date()
                BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolStatusChange")
            } else if throttledUpdateWorkItem == nil {
                let delay = Self.liveActivityThrottleInterval - elapsed
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lastLiveActivityPush = Date()
                    self.throttledUpdateWorkItem = nil
                    BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "toolStatusThrottled")
                }
                throttledUpdateWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    func updateLoopIteration(_ sessionId: String, iteration: Int) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        info.loopIteration = iteration
        sessionToolInfo[sessionId] = info
    }

    func updateSessionTitle(_ sessionId: String, title: String) {
        var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
        guard info.title != title else { return }
        info.title = title
        sessionToolInfo[sessionId] = info
        BackgroundKeepAliveManager.shared.updateLiveActivityIfNeeded(source: "titleChange")
    }

    /// Thread-safe mirror of `activeSessions` + `draftAliases`, readable from
    /// non-MainActor contexts — notably the ChatStore actor's iCloud merge
    /// path, which must know whether a session is mid-run before applying a
    /// remote message. The `@MainActor`-isolated published state can't be read
    /// off-main, so every mutation also refreshes this lock-guarded snapshot.
    private static let mirrorLock = NSLock()
    nonisolated(unsafe) private static var activeSessionsMirror: Set<String> = []
    nonisolated(unsafe) private static var draftAliasesMirror: [String: String] = [:]

    /// Non-MainActor query: is this session (or its draft alias) running
    /// locally? Used by sync to avoid clobbering a session that's actively
    /// streaming / running tools.
    nonisolated static func isActiveThreadSafe(_ sessionId: String) -> Bool {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        if activeSessionsMirror.contains(sessionId) { return true }
        if let real = draftAliasesMirror[sessionId], activeSessionsMirror.contains(real) { return true }
        return false
    }

    private func syncMirror() {
        Self.mirrorLock.lock()
        Self.activeSessionsMirror = activeSessions
        Self.draftAliasesMirror = draftAliases
        Self.mirrorLock.unlock()
    }

    func setActive(_ sessionId: String, title: String? = nil, source: String = #function) {
        // Seed the title before publishing `activeSessions`. The keep-alive
        // subscriber starts the Live Activity synchronously from that publish;
        // filling this first prevents its initial frame from falling back to
        // “Agent Task” while the database title lookup is still in flight.
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            var info = sessionToolInfo[sessionId] ?? SessionToolInfo()
            info.title = title
            sessionToolInfo[sessionId] = info
        }
        let wasPresent = activeSessions.contains(sessionId)
        activeSessions.insert(sessionId)
        syncMirror()
        logger.info("🟢[Tracker] setActive(\(sessionId.prefix(8))) src=\(source) wasPresent=\(wasPresent) now count=\(activeSessions.count) ids=[\(activeSessions.map { $0.prefix(8) }.joined(separator: ","))]")
    }

    func setInactive(_ sessionId: String, source: String = #function) {
        let wasPresent = activeSessions.contains(sessionId)
        activeSessions.remove(sessionId)
        sessionToolInfo.removeValue(forKey: sessionId)
        // Drop any alias pointing at this session — if the real session is
        // no longer active, its draft alias should not linger either.
        let orphanedAliases = draftAliases.filter { $0.value == sessionId }.map { $0.key }
        for draftKey in orphanedAliases {
            draftAliases.removeValue(forKey: draftKey)
        }
        syncMirror()
        logger.info("🔴[Tracker] setInactive(\(sessionId.prefix(8))) src=\(source) wasPresent=\(wasPresent) now count=\(activeSessions.count) ids=[\(activeSessions.map { $0.prefix(8) }.joined(separator: ","))] clearedAliases=\(orphanedAliases.count)")
    }

    /// Register an alias from a draft ID to its newly-minted real session
    /// ID. After this, `isActive(draftId)` returns `isActive(realId)`.
    /// Removed automatically when the real session goes inactive.
    func setDraftAlias(draft draftId: String, real realId: String) {
        draftAliases[draftId] = realId
        syncMirror()
        logger.info("🔗[Tracker] setDraftAlias(\(draftId.prefix(8)) → \(realId.prefix(8)))")
    }

    func isActive(_ sessionId: String) -> Bool {
        if activeSessions.contains(sessionId) { return true }
        if let realId = draftAliases[sessionId],
           activeSessions.contains(realId) { return true }
        return false
    }
}

/// Keeps the screen awake while any chat session is running a task, when the
/// user has opted in via Appearance Settings. Toggles
/// `UIApplication.isIdleTimerDisabled` from transitions of
/// `SessionActivityTracker.activeSessions`; revokes the lock as soon as all
/// sessions go idle so we don't keep the screen on longer than necessary.
@MainActor
final class KeepScreenAwakeController {
    static let shared = KeepScreenAwakeController()

    static let userDefaultsKey = "keepScreenAwakeDuringTasks"

    private var activityCancellable: AnyCancellable?
    private var defaultsObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var lockHeld = false
    private var appInBackground = false

    private init() {}

    /// Wire up observers. Safe to call once at app launch.
    func start() {
        // Use a strong `self` capture — this is a singleton and the
        // cancellables/observers live for the app lifetime. A `[weak self]`
        // here would never actually fire anyway, but writing `self` avoids
        // the class of bugs where a subtle retain-cycle audit removes the
        // shared reference and the sink silently becomes a no-op.
        activityCancellable = SessionActivityTracker.shared.$activeSessions
            .receive(on: DispatchQueue.main)
            .sink { _ in
                KeepScreenAwakeController.shared.refresh(reason: "tracker")
            }

        // `UserDefaults.didChangeNotification` fires for every key in the
        // suite, which is very chatty but cheap — refresh() is idempotent
        // and short-circuits when shouldHoldLock matches the current state.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { _ in
            KeepScreenAwakeController.shared.refresh(reason: "defaults")
        }

        // Release the lock when the app is not in the foreground so we
        // don't keep a backgrounded device awake (the system puts us to
        // sleep soon anyway, but being explicit avoids holding the lock
        // across a background→foreground cycle if iOS ever keeps us
        // scheduled longer than expected).
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            KeepScreenAwakeController.shared.onScenePhaseChanged(background: true)
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            // [T-ios-scenephase-active-sigkill] Defer the foreground transition
            // off the synchronous notification delivery. Writing isIdleTimerDisabled
            // synchronously here overlaps with SwiftUI view-graph re-evaluation
            // during the foreground transition → SIGKILL. Matches the deferral
            // pattern in BackgroundKeepAliveManager (6e54b5fd). The background
            // observer above stays synchronous — backgrounding has no view-graph risk.
            Task { @MainActor in
                await Task.yield()
                KeepScreenAwakeController.shared.onScenePhaseChanged(background: false)
            }
        }

        refresh(reason: "start")
    }

    private func onScenePhaseChanged(background: Bool) {
        appInBackground = background
        refresh(reason: background ? "background" : "foreground")
    }

    /// Evaluate the desired idle-timer state and apply it when it differs
    /// from the current held state. Safe to call from any observer.
    private func refresh(reason: String) {
        let enabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        let sessionCount = SessionActivityTracker.shared.activeSessions.count
        let hasRunningTask = sessionCount > 0
        // Three ways to release the lock:
        //   - user turned the setting off
        //   - nothing is running
        //   - app went to background (system will sleep us anyway; we just
        //     want to not hold a stale lock)
        let shouldHoldLock = enabled && hasRunningTask && !appInBackground

        guard shouldHoldLock != lockHeld else {
            logger.debug("[KeepScreen] noop reason=\(reason) sessions=\(sessionCount) enabled=\(enabled) bg=\(self.appInBackground) held=\(self.lockHeld)")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = shouldHoldLock
        lockHeld = shouldHoldLock
        logger.info("[KeepScreen] isIdleTimerDisabled=\(shouldHoldLock) reason=\(reason) sessions=\(sessionCount) enabled=\(enabled) bg=\(self.appInBackground)")
    }
}

// MARK: - Session Concurrency Manager

/// Limits the number of sessions actively running LLM requests.
/// Excess sessions are suspended in FIFO order and resumed when slots free up.
@MainActor
final class SessionConcurrencyManager: ObservableObject {
    static let shared = SessionConcurrencyManager()

    let maxConcurrent: Int = 5

    @Published private(set) var runningSessions: Set<String> = []
    @Published private(set) var suspendedSessions: [String] = []
    private var waiters: [(id: String, continuation: CheckedContinuation<Void, Never>)] = []

    /// Acquire a processing slot. Returns immediately if under limit, otherwise suspends until a slot opens.
    func acquireSlot(sessionId: String) async throws {
        if runningSessions.count < maxConcurrent {
            runningSessions.insert(sessionId)
            return
        }

        // Over limit — suspend and wait
        suspendedSessions.append(sessionId)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append((id: sessionId, continuation: continuation))
        }
        // After resuming, check if the task was cancelled while waiting
        try Task.checkCancellation()
        runningSessions.insert(sessionId)
    }

    /// Release a processing slot and resume the next waiting session (FIFO).
    func releaseSlot(sessionId: String) {
        runningSessions.remove(sessionId)
        resumeNextWaiter()
    }

    /// Cancel a suspended session's wait so cancellation can propagate.
    func cancelWait(sessionId: String) {
        suspendedSessions.removeAll { $0 == sessionId }
        if let idx = waiters.firstIndex(where: { $0.id == sessionId }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume()
        }
    }

    /// Whether a session is currently suspended waiting for a slot.
    func isSuspended(_ sessionId: String) -> Bool {
        suspendedSessions.contains(sessionId)
    }

    private func resumeNextWaiter() {
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        suspendedSessions.removeAll { $0 == next.id }
        next.continuation.resume()
    }
}

// MARK: - ViewModel Cache

/// Caches AIChatViewModel instances by session ID so re-entering a session
/// reuses the same (possibly still-running) ViewModel instead of creating a new one.
@MainActor
final class ViewModelCache {
    static let shared = ViewModelCache()

    private var cache: [String: AIChatViewModel] = [:]

    /// Session IDs in least-recently-used → most-recently-used order. Kept in
    /// sync with `cache`: appended/moved to the end on every access, removed
    /// with the entry. Drives soft-cap eviction so we don't retain a fully
    /// loaded ViewModel (messages + agentHistory + parsed markdown blocks) for
    /// every session opened since launch — the primary driver of the app's
    /// resident-memory baseline, which pushes the process toward jetsam once
    /// iSH (gh/python3) adds its own footprint. [T-ios-vmcache-lru-evict]
    private var lruOrder: [String] = []

    /// Soft cap on cached ViewModels. Beyond this, the least-recently-used
    /// NON-processing VMs are evicted (a processing VM is never evicted — its
    /// agent loop must keep running). Re-entering an evicted session rebuilds
    /// the VM and re-hydrates messages from SQLite via the normal isNew path.
    /// [T-ios-vmcache-lru-evict]
    private static let softCap: Int = 6

    init() {
        // Evict aggressively under memory pressure — same hook BrowserTabPool
        // and ThumbnailCache use. Drops every non-processing cached VM (and
        // its messages / history / parsed-markdown trees).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evictOnMemoryWarning() }
        }
    }
    /// Session IDs whose underlying SQLite rows were mutated by an
    /// inbound iCloud merge while the user was NOT on that session's
    /// chat screen. The next `getOrCreate` HIT for one of these IDs
    /// returns `isStale=true` so AIChatView can trigger a reload
    /// instead of rendering the cached `messages` snapshot. The set is
    /// consumed (drained) on read — a single reload pays off the debt.
    /// See ChatStore.mergeRemoteMessage for the producer side
    /// (T-inbound-message-cached-vm-stale).
    private var staleSessionIds: Set<String> = []

    /// Get an existing ViewModel for the session, or create and cache a new one.
    /// Returns `(vm, isNew)` — caller should only call `loadSession()` when `isNew` is true.
    /// For staleness-aware callers (e.g. AIChatView's init), additionally check
    /// `consumeStaleFlag(sessionId:)` AFTER this call and trigger a reload
    /// when it returns true.
    func getOrCreate(for sessionId: String) -> (vm: AIChatViewModel, isNew: Bool) {
        if let existing = cache[sessionId] {
            touch(sessionId)
            logger.info("🔄SESSION ViewModelCache HIT session=\(sessionId) vm=\(existing.vmInstanceId) isProcessing=\(existing.isProcessing)")
            return (existing, false)
        }
        let vm = AIChatViewModel()
        vm.sessionId = sessionId
        cache[sessionId] = vm
        touch(sessionId)
        // A brand-new cache entry doesn't need the stale signal — its
        // `isNew` path already triggers loadSession — clear any
        // accumulated marker so we don't carry it past a remove+recreate.
        staleSessionIds.remove(sessionId)
        let isStillActive = SessionActivityTracker.shared.activeSessions.contains(sessionId)
        logger.info("🔄SESSION ViewModelCache MISS session=\(sessionId) vm=\(vm.vmInstanceId) — created new, trackerActive=\(isStillActive)")
        if isStillActive {
            logger.warning("[BlocksLost] ViewModelCache MISS for tracker-active session \(sessionId.prefix(8)) — agent loop running on a different VM; new VM will pick up results via detachedLoopEnd notification")
        }
        evictIfOverCap()
        return (vm, true)
    }

    /// Returns true if the given session was marked stale by an inbound
    /// iCloud merge since the cached VM last loaded, and consumes the
    /// flag in the same call so a single reload pays off the debt. Safe
    /// to call even when no VM is cached (returns false).
    func consumeStaleFlag(sessionId: String) -> Bool {
        staleSessionIds.remove(sessionId) != nil
    }

    /// Mark a cached session as having stale messages (e.g. iCloud merged
    /// new MessageV2 rows into SQLite). No-op when the session has no
    /// cached VM. When the session IS the foreground-visible one,
    /// `.cloudSyncDidFetchChanges` already drove an in-place reload via
    /// `reloadMessagesFromDB`, so this only matters for background
    /// sessions opened later (T-inbound-message-cached-vm-stale).
    func markStale(sessionId: String) {
        guard cache[sessionId] != nil else { return }
        staleSessionIds.insert(sessionId)
    }

    /// Get an existing cached ViewModel without creating a new one.
    func get(for sessionId: String) -> AIChatViewModel? {
        if cache[sessionId] != nil { touch(sessionId) }
        return cache[sessionId]
    }

    /// Remove a session's ViewModel from the cache (e.g. on session delete).
    func remove(sessionId: String) {
        lruOrder.removeAll { $0 == sessionId }
        if let removed = cache.removeValue(forKey: sessionId) {
            removed.cancel()
            logger.info("🔄SESSION ViewModelCache REMOVE session=\(sessionId) vm=\(removed.vmInstanceId)")
        }
        ChatScrollMemory.shared.clear(sessionId)
    }

    /// Create a fresh (uncached) ViewModel for draft sessions (nil sessionId).
    func createDraft() -> AIChatViewModel {
        let vm = AIChatViewModel()
        logger.info("🔄SESSION ViewModelCache createDraft vm=\(vm.vmInstanceId)")
        return vm
    }

    /// Draft ViewModels keyed by the parent's draft ID (`__new__<UUID>`).
    ///
    /// [T-foldable-draft] Changing pane layout rebuilds the chat subtree, and
    /// the un-keyed `createDraft()` handed the replacement view an empty
    /// ViewModel — the text already typed into the composer disappeared on
    /// fold/unfold. ContentView already owns a stable draft ID, so keying the
    /// draft VM by it makes the rebuild reuse the same instance (composer text,
    /// attachments and any queued send included).
    private var drafts: [String: AIChatViewModel] = [:]

    /// Get the draft ViewModel for a stable draft ID, creating it once.
    func getOrCreateDraft(id: String) -> AIChatViewModel {
        if let existing = drafts[id] {
            logger.info("🔄SESSION ViewModelCache DRAFT HIT id=\(id) vm=\(existing.vmInstanceId)")
            return existing
        }
        let vm = createDraft()
        drafts[id] = vm
        logger.info("🔄SESSION ViewModelCache DRAFT MISS id=\(id) vm=\(vm.vmInstanceId) — created new")
        evictDraftsIfOverCap()
        return vm
    }

    /// Drop a draft entry once it no longer owns a view (session deleted, or
    /// the draft was abandoned by starting another one).
    func forgetDraft(id: String) {
        drafts.removeValue(forKey: id)
        ChatScrollMemory.shared.clear(id)
    }

    /// Drafts are cheap while empty but not once they hold messages, and every
    /// abandoned "New Chat" leaves one behind.
    private func evictDraftsIfOverCap() {
        guard drafts.count > Self.softCap else { return }
        // Snapshot the keys first: mutating the dictionary while iterating its
        // `keys` view is not allowed.
        let victims = Array(drafts.keys).prefix(drafts.count - Self.softCap)
        for key in victims {
            drafts.removeValue(forKey: key)
        }
    }

    /// Move a draft ViewModel into the cache once its session ID is assigned.
    func cacheDraft(_ vm: AIChatViewModel, sessionId: String) {
        // The draft is a real session now; keeping the draft key would retain
        // the same VM under two keys and restore the composer text of a draft
        // that no longer exists.
        drafts = drafts.filter { $0.value !== vm }
        cache[sessionId] = vm
        touch(sessionId)
        logger.info("🔄SESSION ViewModelCache cacheDraft session=\(sessionId) vm=\(vm.vmInstanceId)")
        evictIfOverCap()
    }

    // MARK: - LRU eviction

    /// Mark a session as most-recently-used.
    private func touch(_ sessionId: String) {
        lruOrder.removeAll { $0 == sessionId }
        lruOrder.append(sessionId)
    }

    /// Evict least-recently-used, non-processing VMs down to `softCap`.
    /// A processing VM (running agent loop) is skipped — it must stay alive —
    /// so the resident count can briefly exceed the cap when many sessions are
    /// processing at once, which is intended.
    /// A VM must stay resident if its agent loop is running OR it's the
    /// session the user is currently viewing (evicting the foreground VM would
    /// drop its unsent input draft / scroll state and force a reload mid-view).
    private func isEvictable(_ sessionId: String, _ vm: AIChatViewModel) -> Bool {
        if vm.isProcessing { return false }
        if sessionId == AIChatViewModel.activeSessionId { return false }
        if SessionActivityTracker.shared.activeSessions.contains(sessionId) { return false }
        return true
    }

    private func evictIfOverCap() {
        guard cache.count > Self.softCap else { return }
        var overflow = cache.count - Self.softCap
        // Walk LRU → MRU, evicting evictable VMs first.
        for sessionId in lruOrder where overflow > 0 {
            guard let vm = cache[sessionId], isEvictable(sessionId, vm) else { continue }
            evict(sessionId, vm: vm, reason: "over softCap(\(Self.softCap))")
            overflow -= 1
        }
    }

    /// On a memory warning, drop every evictable cached VM (and its
    /// messages / agentHistory / parsed-markdown trees). Re-entering a
    /// session rebuilds its VM from SQLite.
    private func evictOnMemoryWarning() {
        let victims = cache.filter { isEvictable($0.key, $0.value) }
        for (sessionId, vm) in victims {
            evict(sessionId, vm: vm, reason: "memory warning")
        }
        logger.info("🔄SESSION ViewModelCache memory-warning evicted \(victims.count) VM(s), \(self.cache.count) remain")
    }

    private func evict(_ sessionId: String, vm: AIChatViewModel, reason: String) {
        vm.cancel()
        cache.removeValue(forKey: sessionId)
        lruOrder.removeAll { $0 == sessionId }
        // Clearing the stale marker too — a rebuilt VM loads fresh from SQLite.
        staleSessionIds.remove(sessionId)
        logger.info("🔄SESSION ViewModelCache EVICT session=\(sessionId) vm=\(vm.vmInstanceId) (\(reason))")
    }

    // MARK: - Background UI Suspension

    /// Suspend streaming UI updates on ALL cached VMs that are actively
    /// processing. Called from ZeApp on scenePhase → .inactive so that
    /// no MarkdownRenderer layout work runs on the main thread while the
    /// app is transitioning to background — iOS can SIGKILL for excessive
    /// background CPU/rendering otherwise.
    func suspendAllStreamingUI() {
        for (_, vm) in cache where vm.isProcessing {
            vm.setStreamingUIUpdatesSuspended(true)
        }
    }

    /// Resume streaming UI updates on ALL cached VMs, flushing any chunks
    /// that accumulated while backgrounded. Called from ZeApp on
    /// scenePhase → .active so the user sees the latest content
    /// immediately on return.
    func resumeAllStreamingUI() {
        var cleared = 0
        for (_, vm) in cache where vm.streamingUIUpdatesSuspended {
            vm.setStreamingUIUpdatesSuspended(false)
            cleared += 1
        }
        // [T-ios-scroll-suspend-leak] Record how many VMs this foreground-return
        // pass unblocked. A leaked scroll-suspend that survived a switch-away
        // gets cleared here on the NEXT foreground return — so a nonzero count
        // long after backgrounding is a signal the leak occurred.
        if cleared > 0 {
            logger.info("[SuspendState] resumeAllStreamingUI cleared \(cleared) suspended VM(s)")
            // [T-ios-tool-status-desync] Nudge the session list to re-query
            // the DB so the row subtitle picks up any tool_use blocks that
            // were persisted while the app was suspended. The per-VM
            // objectWillChange above covers in-chat views; this covers the
            // session list whose lastMessage comes from a DB query triggered
            // by .sessionDidUpdate.
            for (sid, vm) in cache where vm.isProcessing {
                NotificationCenter.default.post(name: .sessionDidUpdate, object: sid)
            }
        }
    }

    // MARK: - Pending Transfer

    /// Stash for input content being moved to another session.
    struct PendingTransfer {
        let inputText: String
        let attachments: [InputAttachment]
    }

    /// Set by MoveToSessionSheet, consumed by AIChatView on appear.
    static var pendingTransfer: PendingTransfer?
}


// MARK: - Interactive question cards

/// One question presented by the assistant through the `ask_user` tool.
struct QuestionCardQuestion: Codable, Equatable, Identifiable {
    let id: String
    let prompt: String
    let options: [String]

    init(id: String, prompt: String, options: [String] = []) {
        self.id = id
        self.prompt = prompt
        self.options = options
    }
}

enum QuestionCardStatus: String, Codable, Equatable {
    case pending
    case confirmed
    case unconfirmed
}

/// UI state attached to the assistant's ask_user block. The state is derived
/// from the persisted tool_use/tool_result pair when a session is reloaded.
struct QuestionCardState: Codable, Equatable {
    let requestId: String
    let title: String
    let questions: [QuestionCardQuestion]
    let timeoutAt: Date
    var currentIndex: Int
    var answers: [String?]
    var status: QuestionCardStatus

    init(requestId: String, title: String, questions: [QuestionCardQuestion], timeoutAt: Date, status: QuestionCardStatus = .pending) {
        self.requestId = requestId
        self.title = title
        self.questions = questions
        self.timeoutAt = timeoutAt
        self.currentIndex = 0
        self.answers = Array(repeating: nil, count: questions.count)
        self.status = status
    }

    /// The question currently on screen. Clamped so a stale `currentIndex`
    /// from an older payload can never index out of bounds.
    var currentQuestion: QuestionCardQuestion? {
        guard !questions.isEmpty else { return nil }
        let index = min(max(currentIndex, 0), questions.count - 1)
        return questions[index]
    }

    /// Number of questions with a non-empty answer. Used by the collapsed
    /// summary and the segmented progress bar.
    var answeredCount: Int {
        questions.indices.reduce(into: 0) { count, index in
            guard index < answers.count else { return }
            if let value = answers[index]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                count += 1
            }
        }
    }

    /// `1/4`-style progress. While pending this points at the question being
    /// asked; once resolved it reports what was actually answered.
    var progressText: String {
        let total = max(questions.count, 1)
        let done: Int
        switch status {
        case .pending:
            done = min(max(currentIndex + 1, 1), total)
        case .confirmed:
            done = total
        case .unconfirmed:
            done = answeredCount
        }
        return "\(done)/\(total)"
    }

    var statusLabel: String {
        switch status {
        case .pending: return String(localized: "Waiting for your answer…")
        case .confirmed: return String(localized: "Answered")
        case .unconfirmed: return String(localized: "Unconfirmed")
        }
    }

    /// Titles that carry no information — the model's default tool label.
    /// Kept in one place so the card header, the host chrome and the
    /// persisted block summary all agree on what counts as "no title".
    private static let genericTitles: Set<String> = [
        "",
        String(localized: "Assistant question"),
        String(localized: "Question card"),
        "Assistant question",
        "Question card",
        "助手提问",
        "提问卡片",
        "助手提問",
        "提問卡片",
        "Ze is asking a question",
        "Ze 正在提问",
        "Ze 正在提問",
    ]

    var hasCustomTitle: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !Self.genericTitles.contains(trimmed)
    }

    /// The question the card is about. Pending cards follow the current
    /// step; resolved cards keep the first question so the collapsed card
    /// still says what was asked instead of only "Answered".
    var displayQuestion: String {
        let prompt: String?
        if status == .pending {
            prompt = currentQuestion?.prompt
        } else {
            prompt = questions.first?.prompt
        }
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        if hasCustomTitle { return title.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(localized: "Question card")
    }

    /// Small label above the question when the model supplied a real topic.
    var eyebrow: String? {
        guard hasCustomTitle else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == displayQuestion ? nil : trimmed
    }

    /// One-line title used by rails, the host bottom bar and the floating
    /// toolbar. Always the question, never the generic "Question card".
    var chromeTitle: String { displayQuestion }

    /// The card header's primary line. Kept as `headline` because older
    /// call sites (session rows, snapshots) already read this name.
    var headline: String { displayQuestion }

    /// Compact text for `block.content`, so every surface that only knows
    /// about a tool's content string still shows the question or answer.
    var summaryText: String {
        switch status {
        case .pending:
            return displayQuestion
        case .confirmed:
            if let preview = answerPreview {
                return "\(String(localized: "Answered")) · \(preview)"
            }
            return String(localized: "Answered")
        case .unconfirmed:
            if let preview = answerPreview {
                return "\(String(localized: "Unconfirmed")) · \(preview)"
            }
            return String(localized: "Unconfirmed")
        }
    }

    /// All submitted answers, joined for the collapsed one/two-line preview.
    var answerPreview: String? {
        let values = questions.indices.compactMap { index -> String? in
            guard index < answers.count,
                  let value = answers[index]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }
}

/// Remembers manual expand/collapse choices across app launches. The default
/// is intentionally state-driven: a pending card is open, a resolved card is
/// closed. Only deviations from that default are persisted, so the override
/// map stays tiny and a solved card can never reopen itself after a restart.
enum QuestionCardExpansionStore {
    private static let storageKey = "ze.questionCard.expansion.v1"
    private static let maxEntries = 120

    static func isExpanded(for requestId: String, status: QuestionCardStatus) -> Bool {
        if let stored = overrides()[requestId] { return stored }
        return status == .pending
    }

    static func setExpanded(_ expanded: Bool, for requestId: String, status: QuestionCardStatus) {
        var map = overrides()
        if expanded == (status == .pending) {
            map.removeValue(forKey: requestId)
        } else {
            map[requestId] = expanded
        }
        if map.count > maxEntries {
            let overflow = Array(map.keys.prefix(map.count - maxEntries))
            for key in overflow {
                map.removeValue(forKey: key)
            }
        }
        UserDefaults.standard.set(map, forKey: storageKey)
    }

    private static func overrides() -> [String: Bool] {
        let raw = UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
        return raw.compactMapValues { $0 as? Bool }
    }
}

struct QuestionCardResponse: Codable, Equatable {
    struct Answer: Codable, Equatable {
        let id: String
        let question: String
        let answer: String?
    }

    let confirmed: Bool
    let status: String
    let answers: [Answer]
    let source: String

    var json: String {
        let payload: [String: Any] = [
            "confirmed": confirmed,
            "status": status,
            "source": source,
            "answers": answers.map { answer -> [String: Any] in
                var item: [String: Any] = [
                    "id": answer.id,
                    "question": answer.question
                ]
                item["answer"] = answer.answer ?? NSNull()
                return item
            }
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"confirmed\":false,\"status\":\"unconfirmed\",\"answers\":[],\"source\":\"system\"}"
        }
        return string
    }
}

enum QuestionCardParser {
    static func questions(from arguments: [String: Any]) -> [QuestionCardQuestion] {
        if let raw = arguments["questions"] as? String {
            return parse(raw)
        }
        if let raw = arguments["questions"] as? [[String: Any]] {
            return raw.enumerated().compactMap { makeQuestion($0.element, index: $0.offset) }
        }
        if let question = arguments["question"] as? String {
            return parse(question)
        }
        return []
    }

    static func state(requestId: String, arguments: [String: Any], timeout: TimeInterval) -> QuestionCardState? {
        let questions = questions(from: arguments)
        guard !questions.isEmpty else { return nil }
        let title = (arguments["tool_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuestionCardState(
            requestId: requestId,
            title: title?.isEmpty == false ? title! : String(localized: "Assistant question"),
            questions: questions,
            timeoutAt: Date().addingTimeInterval(timeout)
        )
    }

    /// Resolve a title for chrome that only has the serialized tool input
    /// (rails, floating toolbar, restored blocks whose card state has not
    /// been rebuilt yet). Returns the question, never the generic label.
    static func headline(fromToolInput raw: String?) -> String? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = state(requestId: "preview", arguments: arguments, timeout: 900) else {
            return nil
        }
        return state.chromeTitle
    }

    static func apply(resultJSON: String, to state: inout QuestionCardState) {
        guard let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if state.answers.count < state.questions.count {
            state.answers += Array(repeating: nil, count: state.questions.count - state.answers.count)
        }
        if let status = object["status"] as? String {
            state.status = status == QuestionCardStatus.confirmed.rawValue ? .confirmed : .unconfirmed
        } else if let confirmed = object["confirmed"] as? Bool {
            state.status = confirmed ? .confirmed : .unconfirmed
        } else {
            state.status = .unconfirmed
        }
        if let answers = object["answers"] as? [[String: Any]] {
            for (index, question) in state.questions.enumerated() {
                if let match = answers.first(where: { ($0["id"] as? String) == question.id }) {
                    state.answers[index] = match["answer"] as? String
                }
            }
            state.currentIndex = min(answers.count, max(0, state.questions.count - 1))
        } else if let answers = object["answers"] as? [String: Any] {
            for (index, question) in state.questions.enumerated() {
                state.answers[index] = answers[question.id] as? String
            }
        }
        state.currentIndex = min(max(state.currentIndex, 0), max(state.questions.count - 1, 0))
    }

    private static func parse(_ raw: String) -> [QuestionCardQuestion] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let array = object as? [[String: Any]] {
            let parsed = array.enumerated().compactMap { makeQuestion($0.element, index: $0.offset) }
            if !parsed.isEmpty { return parsed }
        }

        return trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .enumerated()
            .map { index, line in
                let pieces = line.components(separatedBy: "||")
                let prompt = pieces[0]
                    .replacingOccurrences(of: #"^\s*\d+[.)、]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let options = splitOptionList(pieces.dropFirst().joined(separator: "||"))
                return QuestionCardQuestion(id: "q\(index + 1)", prompt: prompt, options: Array(options.prefix(8)))
            }
            .filter { !$0.prompt.isEmpty }
    }

    /// Splits a free-text option list on `|`, `、`, `,` and `，`, but only at
    /// the top level.
    ///
    /// The model routinely writes one option as
    /// `free 生图/gpt-image-2（默认，约 941×1672）`. Splitting on every comma
    /// turned that single answer into two radio rows — `…（默认` and
    /// `约 941×1672）` — which read as if the card had four choices. A
    /// separator nested inside brackets belongs to the option text.
    private static func splitOptionList(_ raw: String) -> [String] {
        let openers: Set<Character> = ["（", "(", "【", "[", "「", "“"]
        let closers: Set<Character> = ["）", ")", "】", "]", "」", "”"]

        var parts: [String] = []
        var current = ""
        var depth = 0

        for character in raw {
            if openers.contains(character) {
                depth += 1
                current.append(character)
                continue
            }
            if closers.contains(character) {
                depth = max(depth - 1, 0)
                current.append(character)
                continue
            }
            let isSeparator = character == "|" || character == "、" || character == "," || character == "，"
            if isSeparator, depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        parts.append(current)

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func makeQuestion(_ dictionary: [String: Any], index: Int) -> QuestionCardQuestion? {
        let prompt = (dictionary["prompt"] as? String ?? dictionary["question"] as? String ?? dictionary["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        let id = (dictionary["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = (dictionary["options"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return QuestionCardQuestion(id: id?.isEmpty == false ? id! : "q\(index + 1)", prompt: prompt, options: Array(options.prefix(8)))
    }
}

/// Owns the single pending question-card continuation for a chat turn and
/// bridges in-app answers, speech answers, notification replies, and timeout.
@MainActor
final class QuestionCardCoordinator {
    static let shared = QuestionCardCoordinator()
    nonisolated static let categoryId = "ZE_QUESTION_CARD"
    static let replyActionId = "ZE_QUESTION_REPLY"
    static let unconfirmedActionId = "ZE_QUESTION_UNCONFIRMED"

    private final class PendingRequest {
        let id: String
        weak var block: AssistantBlock?
        var state: QuestionCardState
        var continuation: CheckedContinuation<QuestionCardResponse, Never>?
        var timeoutTask: Task<Void, Never>?
        var source = "in_app"

        init(id: String, state: QuestionCardState, block: AssistantBlock?) {
            self.id = id
            self.state = state
            self.block = block
        }
    }

    private var pending: [String: PendingRequest] = [:]
    private let logger = AppLogger(category: "QuestionCard")
    private var backgroundObserver: NSObjectProtocol?

    private func notifyLayoutChange(for block: AssistantBlock?) {
        guard let block else { return }
        NotificationCenter.default.post(name: .questionCardToggled, object: block.id)
    }

    private init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.postNotificationsForPendingCards()
            }
        }
    }

    func isPending(requestId: String) -> Bool {
        pending[requestId] != nil
    }

    func request(
        state: QuestionCardState,
        block: AssistantBlock?
    ) async -> QuestionCardResponse {
        let requestId = state.requestId
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<QuestionCardResponse, Never>) in
                if pending[requestId] != nil {
                    finish(requestId: requestId, status: .unconfirmed, source: "replaced")
                }
                let request = PendingRequest(id: requestId, state: state, block: block)
                request.continuation = continuation
                pending[requestId] = request
                block?.questionCard = state
                block?.isQuestionCardExpanded = QuestionCardExpansionStore.isExpanded(
                    for: state.requestId,
                    status: state.status
                )
                block?.content = state.summaryText
                block?.toolSummary = state.chromeTitle
                notifyLayoutChange(for: block)
                block?.toolStatus = .running
                persist(request.state)
                scheduleTimeout(for: requestId, at: state.timeoutAt)
                postNotification(for: request)
                logger.info("[QuestionCard] PRESENT id=\(requestId.prefix(20)) questions=\(state.questions.count) timeout=\(state.timeoutAt)")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(requestId: requestId, status: .unconfirmed, source: "cancelled")
            }
        }
    }

    func submitAnswer(requestId: String, answer: String, source: String = "in_app") {
        guard let request = pending[requestId], request.state.status == .pending else { return }
        let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if request.state.answers.count < request.state.questions.count {
            request.state.answers += Array(
                repeating: nil,
                count: request.state.questions.count - request.state.answers.count
            )
        }
        let index = request.state.currentIndex
        guard request.state.questions.indices.contains(index) else {
            finish(requestId: requestId, status: .confirmed, source: source)
            return
        }
        request.source = source
        request.state.answers[index] = cleaned
        if index + 1 < request.state.questions.count {
            request.state.currentIndex = index + 1
            request.block?.questionCard = request.state
            request.block?.content = request.state.summaryText
            request.block?.toolSummary = request.state.chromeTitle
            notifyLayoutChange(for: request.block)
            persist(request.state)
            postNotification(for: request)
            return
        }
        finish(requestId: requestId, status: .confirmed, source: source)
    }

    func submitUnconfirmed(requestId: String, source: String = "in_app") {
        guard pending[requestId] != nil else { return }
        finish(requestId: requestId, status: .unconfirmed, source: source)
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        guard let requestId = userInfo["requestId"] as? String else { return }
        switch response.actionIdentifier {
        case Self.replyActionId:
            let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            submitAnswer(requestId: requestId, answer: text, source: "notification")
        case Self.unconfirmedActionId:
            submitUnconfirmed(requestId: requestId, source: "notification")
        case UNNotificationDefaultActionIdentifier:
            // The shared notification delegate routes a normal tap to the
            // session. Reply actions are handled above without opening it.
            break
        default:
            break
        }
    }

    private func scheduleTimeout(for requestId: String, at deadline: Date) {
        pending[requestId]?.timeoutTask?.cancel()
        let delay = max(0, deadline.timeIntervalSinceNow)
        pending[requestId]?.timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            self?.finish(requestId: requestId, status: .unconfirmed, source: "timeout")
        }
    }

    private func finish(requestId: String, status: QuestionCardStatus, source: String) {
        guard let request = pending.removeValue(forKey: requestId) else { return }
        request.timeoutTask?.cancel()
        request.state.status = status
        request.block?.questionCard = request.state
        request.block?.isQuestionCardExpanded = false
        QuestionCardExpansionStore.setExpanded(false, for: requestId, status: status)
        request.block?.content = request.state.summaryText
        request.block?.toolSummary = request.state.chromeTitle
        notifyLayoutChange(for: request.block)
        removeNotification(requestId: requestId)
        let answers = request.state.questions.enumerated().map { index, question in
            QuestionCardResponse.Answer(
                id: question.id,
                question: question.prompt,
                answer: index < request.state.answers.count ? request.state.answers[index] : nil
            )
        }
        let response = QuestionCardResponse(
            confirmed: status == .confirmed,
            status: status.rawValue,
            answers: answers,
            source: source
        )
        request.continuation?.resume(returning: response)
        request.continuation = nil
        UserDefaults.standard.removeObject(forKey: stateKey(requestId))
        logger.info("[QuestionCard] RESOLVED id=\(requestId.prefix(20)) status=\(status.rawValue) source=\(source)")
    }

    private func persist(_ state: QuestionCardState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: stateKey(state.requestId))
    }

    private func stateKey(_ requestId: String) -> String {
        "question-card.state.\(requestId)"
    }

    private func registerNotificationCategory() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionId,
            title: String(localized: "Answer"),
            options: [],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Type your answer")
        )
        let unconfirmed = UNNotificationAction(
            identifier: Self.unconfirmedActionId,
            title: String(localized: "Leave unconfirmed"),
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryId, actions: [reply, unconfirmed], intentIdentifiers: [])
        ])
    }

    private func postNotificationsForPendingCards() {
        for request in pending.values {
            postNotification(for: request)
        }
    }

    private func postNotification(for request: PendingRequest) {
        guard UIApplication.shared.applicationState != .active else { return }
        guard UserDefaults.standard.object(forKey: "backgroundNotificationsEnabled") == nil
                || UserDefaults.standard.bool(forKey: "backgroundNotificationsEnabled") else { return }
        guard request.state.questions.indices.contains(request.state.currentIndex) else { return }
        registerNotificationCategory()
        let question = request.state.questions[request.state.currentIndex]
        let content = UNMutableNotificationContent()
        content.title = request.state.title
        let options = question.options.isEmpty ? "" : "\n" + question.options.joined(separator: " · ")
        content.body = "\(question.prompt)\(options)"
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        content.userInfo = [
            "requestId": request.id,
            "sessionId": AIChatViewModel.activeSessionId ?? ""
        ]
        let notification = UNNotificationRequest(
            identifier: "question-card-\(request.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notification)
    }

    private func removeNotification(requestId: String) {
        let center = UNUserNotificationCenter.current()
        let id = "question-card-\(requestId)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}
