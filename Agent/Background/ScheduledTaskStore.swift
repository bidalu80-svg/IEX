import Foundation
import Combine

#if os(iOS)
import BackgroundTasks
import UIKit

@MainActor
final class ScheduledTaskStore: ObservableObject {
    static let shared = ScheduledTaskStore()
    static let backgroundIdentifier = "com.ze.app.scheduled-tasks"
    @Published private(set) var tasks: [ScheduledTaskDefinition] = []
    @Published private(set) var runs: [ScheduledTaskRun] = []
    @Published var lastError: String?

    private let repository: ScheduledTaskRepository
    private var storageReady = true
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var worker: Task<Void, Never>?
    private var activeReceipt: ScheduledTaskExecutionReceipt?
    private var needsFinalizationRetry = false
    private var activeRunID: UUID?
    private var cancelledRuns: Set<UUID> = []

    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        repository = ScheduledTaskRepository(fileURL: root.appendingPathComponent("ScheduledTasks/state.json"))
        do {
            var snapshot = try repository.load()
            // Never replay an occurrence claimed before a process termination.
            snapshot.recoverInterruptedRuns(at: Date())
            try repository.write(snapshot)
            tasks = snapshot.tasks
            runs = snapshot.runs
        } catch {
            storageReady = false
            lastError = ScheduledTaskError.storageUnavailable.localizedDescription
        }
    }

    func registerBackgroundTask() {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundIdentifier, using: .main) { task in
            Task { @MainActor in
                let store = ScheduledTaskStore.shared
                task.expirationHandler = {
                    Task { @MainActor in store.worker?.cancel() }
                }
                store.start()
                store.tick()
                await store.worker?.value
                task.expirationHandler = nil
                task.setTaskCompleted(success: store.lastError == nil)
                store.scheduleBackgroundWake()
            }
        }
        if !registered { lastError = String(localized: "系统后台调度注册失败，打开应用后仍会检查到期任务。") }
    }

    func start() {
        guard timer == nil, storageReady else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in ScheduledTaskStore.shared.tick() }
        }
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    ScheduledTaskStore.shared.tick()
                    ScheduledTaskStore.shared.scheduleBackgroundWake()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification,
                                                                 object: nil, queue: .main) { _ in
            Task { @MainActor in ScheduledTaskStore.shared.refreshFutureDates() }
        })
        tick()
        scheduleBackgroundWake()
    }

    func save(_ definition: ScheduledTaskDefinition) throws {
        var task = definition
        task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
        task.prompt = task.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.prompt.isEmpty else { throw ScheduledTaskError.invalidPrompt }
        guard usableEntry(task.modelEntryId) != nil else { throw ScheduledTaskError.invalidModel }
        if task.runMode == .currentConversation, task.sessionId == nil { throw ScheduledTaskError.invalidSession }
        if task.runMode == .newConversation { task.sessionId = nil }
        task.nextRunAt = task.nextOccurrence(after: Date())
        guard task.nextRunAt != nil else { throw ScheduledTaskError.invalidSchedule }
        var updated = tasks
        if let index = updated.firstIndex(where: { $0.id == task.id }) { updated[index] = task }
        else { updated.append(task) }
        try commit(tasks: updated, runs: runs)
        start()
        scheduleBackgroundWake()
    }

    func delete(id: UUID) throws {
        try commit(tasks: tasks.filter { $0.id != id }, runs: runs)
        if let run = runs.first(where: { $0.taskId == id && $0.status == .running }) { cancelRun(id: run.id) }
        scheduleBackgroundWake()
    }

    func setEnabled(id: UUID, enabled: Bool) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = tasks
        updated[index].isEnabled = enabled
        if enabled {
            updated[index].nextRunAt = updated[index].nextOccurrence(after: Date())
            guard updated[index].nextRunAt != nil else { throw ScheduledTaskError.invalidSchedule }
        }
        try commit(tasks: updated, runs: runs)
        scheduleBackgroundWake()
    }

    func cancelRun(id: UUID) {
        guard activeRunID == id else { return }
        cancelledRuns.insert(id)
        activeReceipt?.cancel()
    }

    private func commit(tasks: [ScheduledTaskDefinition], runs: [ScheduledTaskRun]) throws {
        guard storageReady else { throw ScheduledTaskError.storageUnavailable }
        // Preserve active runs and a bounded history of 200 completed runs.
        let retained = Array(runs.sorted { $0.startedAt > $1.startedAt }.prefix(200))
        try repository.write(ScheduledTaskSnapshot(tasks: tasks, runs: retained))
        self.tasks = tasks
        self.runs = retained
        if needsFinalizationRetry { lastError = nil }
        needsFinalizationRetry = false
    }

    private func usableEntry(_ id: String) -> ModelEntry? {
        let store = ProviderConfigStore.shared
        guard let entry = store.entry(for: id), !entry.isHidden,
              entry.model.capabilities.supportedModalities.contains(.textOutput),
              let provider = store.instance(for: entry.providerInstanceId),
              provider.isEnabled, provider.hasAnyCredential else { return nil }
        return entry
    }

    private func tick() {
        guard storageReady, worker == nil else { return }
        if needsFinalizationRetry {
            do { try commit(tasks: tasks, runs: runs) }
            catch { reportStorageError(); return }
        }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.worker = nil; self.scheduleBackgroundWake() }
            let now = Date()
            let due = self.tasks.filter { $0.isEnabled && ($0.nextRunAt.map { $0 <= now } ?? false) }
                .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            for task in due {
                guard !Task.isCancelled else { break }
                await self.execute(taskID: task.id)
            }
        }
    }

    private func execute(taskID: UUID) async {
        guard let task = tasks.first(where: { $0.id == taskID }), task.isEnabled,
              let dueAt = task.nextRunAt, dueAt <= Date() else { return }
        if task.isExpired(at: Date()) {
            var updated = tasks
            if let index = updated.firstIndex(where: { $0.id == taskID }) { updated[index].isEnabled = false; updated[index].nextRunAt = nil }
            do { try commit(tasks: updated, runs: runs) } catch { reportStorageError() }
            return
        }
        // Defer a busy/locked conversation; never replace user text or attachments.
        var vm: AIChatViewModel?
        var preflightError: String?
        if task.runMode == .currentConversation {
            if let sid = task.sessionId, await ChatStore.shared.getSession(sid) != nil {
                guard !SessionLockStore.shared.isVisuallyLocked(sid),
                      !SessionActivityTracker.isActiveThreadSafe(sid) else { return }
                let (cached, isNew) = ViewModelCache.shared.getOrCreate(for: sid)
                guard isConversationIdle(cached) else { return }
                if isNew || ViewModelCache.shared.consumeStaleFlag(sessionId: sid) {
                    await cached.loadSession(activate: false)
                }
                guard isConversationIdle(cached) else {
                    ViewModelCache.shared.markStale(sessionId: sid)
                    return
                }
                if cached.remoteDeviceId != nil { preflightError = String(localized: "此对话为只读远程对话，请改为新建对话运行。") }
                vm = cached
            } else { preflightError = ScheduledTaskError.invalidSession.localizedDescription }
        }
        guard !Task.isCancelled, let latest = tasks.first(where: { $0.id == taskID }),
              latest == task else { return }
        let entry = usableEntry(task.modelEntryId)
        if entry == nil { preflightError = ScheduledTaskError.invalidModel.localizedDescription }
        var snapshot = ScheduledTaskSnapshot(tasks: tasks, runs: runs)
        guard var record = snapshot.claim(taskID: taskID, at: Date()) else { return }
        do { try commit(tasks: snapshot.tasks, runs: snapshot.runs) } catch { reportStorageError(); return }
        activeRunID = record.id
        defer { activeRunID = nil; activeReceipt = nil; cancelledRuns.remove(record.id) }
        if let preflightError {
            finish(id: record.id, status: .failed, error: preflightError)
            return
        }
        guard let entry else { return }
        let executor = vm ?? ViewModelCache.shared.createDraft()
        if vm == nil { executor.sessionSource = "scheduled-task"; executor.selectedModel = entry.model }
        let previousPreferred = executor.preferredModelEntryReference
        var didRestoreModel = false
        let restoreModel = {
            guard !didRestoreModel else { return }
            didRestoreModel = true
            executor.preferredModelEntryReference = previousPreferred
        }
        defer { restoreModel() }
        let sid = await executor.ensureSessionReturningId(activate: false)
        guard !Task.isCancelled, !cancelledRuns.contains(record.id) else {
            finish(id: record.id, status: .interrupted, error: String(localized: "任务已取消或后台运行时间已结束。"))
            return
        }
        // Recheck after awaiting session creation; a foreground sender may have won.
        guard isConversationIdle(executor) else {
            finish(id: record.id, status: .failed, error: String(localized: "对话正忙，本次任务未发送。"))
            return
        }
        guard usableEntry(task.modelEntryId) != nil else {
            finish(id: record.id, status: .failed, error: ScheduledTaskError.invalidModel.localizedDescription)
            return
        }
        executor.preferredModelEntryReference = entry.id
        // A background sender must not open compact/clear-history dialogs.
        switch executor.checkContextBeforeSend() {
        case .ok: break
        case .needsCompact, .exhausted:
            finish(id: record.id, status: .failed,
                   error: String(localized: "对话上下文空间不足，请整理当前对话或改为新建对话运行。"))
            return
        }
        record.sessionId = sid
        if let index = runs.firstIndex(where: { $0.id == record.id }) {
            var records = runs; records[index] = record
            do { try commit(tasks: tasks, runs: records) }
            catch {
                finish(id: record.id, status: .failed, error: String(localized: "运行记录保存失败，本次任务未发送。"))
                return
            }
        }
        // Keep the scheduled model on the resulting conversation, as with manual selection.
        let providers = ProviderConfigStore.shared
        providers.setBinding(SessionModelBinding(sessionId: sid,
            primarySource: .directEntry(modelEntryId: entry.id, compositeKey: entry.compositeKey),
            subModelSource: providers.binding(for: sid)?.subModelSource), for: sid)
        executor.selectedModel = entry.model
        NotificationCenter.default.post(name: .sessionModelBindingChanged, object: nil, userInfo: ["sessionId": sid])
        // Each receipt ends at this send's turn boundary, before user-queued turns.
        let receipt = ScheduledTaskExecutionReceipt(vm: executor, onFinish: restoreModel)
        activeReceipt = receipt
        executor.scheduledTurnCompletion = { [weak receipt] in receipt?.finish() }
        executor.inputText = task.prompt
        executor.send()
        executor.scheduledTurnCompletion = nil
        if !receipt.hasStarted { receipt.finish() }
        let deadline = Date().addingTimeInterval(15 * 60)
        while receipt.result == nil && !Task.isCancelled && !cancelledRuns.contains(record.id) && Date() < deadline {
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { break }
        }
        if receipt.result == nil { receipt.cancel() }
        if let result = receipt.result {
            finish(id: record.id, status: result.status, error: result.error, summary: result.summary)
        }
    }

    private func isConversationIdle(_ vm: AIChatViewModel) -> Bool {
        !vm.isProcessing && !vm.isLoadingSession && !vm.isCompacting &&
        vm.editingMessageIndex == nil && vm.pendingSendText == nil && vm.pendingSendAttachments.isEmpty &&
        vm.promptQueue.isEmpty && !vm.showCompactBeforeSendPrompt && !vm.showContextExhaustedPrompt &&
        vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty
    }

    private func finish(id: UUID, status: ScheduledTaskRunStatus, error: String?, summary: String = "") {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        var updated = runs
        updated[index].status = status
        updated[index].finishedAt = Date()
        updated[index].error = error
        updated[index].summary = summary
        do { try commit(tasks: tasks, runs: updated) }
        catch {
            // The original claim stays durable; retry only its terminal state, never its prompt.
            runs = updated
            needsFinalizationRetry = true
            lastError = String(localized: "运行结果暂未写入存储，将自动重试保存；不会重新发送任务。")
        }
    }

    private func reportStorageError() {
        lastError = String(localized: "定时任务保存失败，请检查设备存储空间。任务不会在记录保存前发送。")
    }

    private func refreshFutureDates() {
        var updated = tasks
        let now = Date()
        for index in updated.indices where updated[index].isEnabled {
            // Keep already-due occurrences eligible for one catch-up execution.
            if let next = updated[index].nextRunAt, next > now {
                updated[index].nextRunAt = updated[index].nextOccurrence(after: now)
                if updated[index].nextRunAt == nil { updated[index].isEnabled = false }
            }
        }
        do { try commit(tasks: updated, runs: runs) } catch { reportStorageError() }
        tick()
        scheduleBackgroundWake()
    }

    private func scheduleBackgroundWake() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundIdentifier)
        guard let next = tasks.filter(\.isEnabled).compactMap(\.nextRunAt).min() else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = max(next, Date().addingTimeInterval(60))
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            // Foreground dispatch remains available if Background App Refresh is disabled.
            lastError = String(localized: "系统暂未接受后台调度，任务将在应用恢复运行时检查执行。")
        }
    }
}

#endif

/// A receipt belongs to one send, not the reusable VM. Capture a terminal snapshot
/// synchronously so a subsequent manual/queued send cannot be cancelled or counted.
@MainActor
final class ScheduledTaskExecutionReceipt {
    private weak var vm: AIChatViewModel?
    private let messageCount: Int
    private let onFinish: () -> Void
    private var observation: AnyCancellable?
    private var latch = ScheduledTaskCompletionLatch()
    private var cancelRequested = false
    private(set) var hasStarted = false
    var result: ScheduledTaskTurnResult? { latch.result }

    init(vm: AIChatViewModel, onFinish: @escaping () -> Void) {
        self.vm = vm
        self.messageCount = vm.messages.count
        self.onFinish = onFinish
        observation = vm.$isProcessing.dropFirst().sink { [weak self] processing in
            guard let self, self.result == nil else { return }
            if processing { self.hasStarted = true }
            else if self.hasStarted { self.finish() }
        }
    }

    func cancel() {
        guard result == nil, !cancelRequested else { return }
        cancelRequested = true
        // cancel() publishes false synchronously, completing this receipt before
        // it can start draining a later user prompt. Never cancel a second time.
        vm?.cancel()
        finish()
    }

    func finish() {
        guard result == nil, let vm else { return }
        let interrupted = cancelRequested || vm.userDidCancel
        // Only the scheduled user message and its assistant/tool messages belong
        // to this result; queued user bubbles can already be visible in messages.
        let tail = vm.messages.dropFirst(messageCount)
        let turn = tail.dropFirst().prefix { $0.role != .user }
        let output = turn.filter { $0.role == .assistant }
            .flatMap { $0.blocks.filter { $0.kind == .text }.map(\.content) }.joined(separator: "\n")
        let providerError = vm.errorMessage ?? turn.last(where: { $0.role == .assistant })?.error
        let error: String?
        if interrupted { error = String(localized: "任务已取消或后台运行时间已结束。") }
        else if let providerError { error = String(localized: "模型执行失败，请检查网络、服务商凭据和额度。") + "\n" + providerError }
        else if !hasStarted { error = String(localized: "任务未启动，请检查对话状态后重试。") }
        else { error = nil }
        let status: ScheduledTaskRunStatus = interrupted ? .interrupted : (error == nil ? .succeeded : .failed)
        if latch.finish(ScheduledTaskTurnResult(status: status, summary: String(output.suffix(8000)), error: error)) {
            observation?.cancel()
            observation = nil
            onFinish()
        }
    }
}
