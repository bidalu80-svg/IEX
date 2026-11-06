import Combine
import Foundation

/// Persistent state for one independently running child agent.
enum ZeSubAgentPreferences {
    static let enabledKey = "subAgentsEnabled"
    static let dockEnabledKey = "subAgentDockEnabled"
    static let modelEntryKey = "subAgentModelEntryId"
    static let settingsRootSessionId = "__ze_subagent_settings__"

    static var isEnabled: Bool {
        guard let value = UserDefaults.standard.object(forKey: enabledKey) as? NSNumber else { return true }
        return value.boolValue
    }

    static var configuredModelEntryReference: String? {
        guard let value = UserDefaults.standard.string(forKey: modelEntryKey), !value.isEmpty else { return nil }
        return value
    }
}

enum ZeSubAgentStatus: String, Codable, CaseIterable, Sendable {
    case idle, queued, running, awaitingApproval = "awaiting_approval", cancelling
    case completed, failed, cancelled, interrupted, closed, timedOut = "timed_out"

    var isActive: Bool {
        switch self {
        case .queued, .running, .awaitingApproval, .cancelling: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return String(localized: "待命")
        case .queued: return String(localized: "排队中")
        case .running: return String(localized: "运行中")
        case .awaitingApproval: return String(localized: "等待确认")
        case .cancelling: return String(localized: "正在停止")
        case .completed: return String(localized: "已完成")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已停止")
        case .interrupted: return String(localized: "已中断")
        case .closed: return String(localized: "已关闭")
        case .timedOut: return String(localized: "已超时")
        }
    }
}

/// One live tool or text event from the child chat loop. Snapshots are kept
/// with the child record so the black card remains readable after relaunch.
struct ZeSubAgentStep: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let icon: String
    let content: String
    let state: String
    var duration: TimeInterval? = nil
    var imageFilePath: String? = nil
    var toolName: String? = nil
}

struct ZeSubAgentRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let parentId: String
    let rootSessionId: String
    let nickname: String
    let depth: Int
    var status: ZeSubAgentStatus
    var revision: Int
    let createdAt: Date
    var updatedAt: Date
    let prompt: String
    var output: String
    var error: String?
    var childSessionId: String?
    var inputTokens: Int
    var outputTokens: Int
    /// Optional model pin used by this child. nil means it followed the parent
    /// conversation model when it was created.
    var modelEntryReference: String?
    /// Optional for backward-compatible decoding of existing persisted agents.
    var steps: [ZeSubAgentStep]?
    var pendingInputCount: Int? = nil
    var cacheReadTokens: Int? = nil
    var turnCount: Int? = nil
    /// Identifies the delegating assistant turn, so Stop never reaches unrelated work.
    var parentTurnId: String? = nil
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var budgetMinutes: Int? = nil
    var requestedModel: String? = nil
    var modelPinUnavailable: Bool? = nil
    var requestModelId: String? = nil
    var requestModelName: String? = nil
    var requestProviderName: String? = nil
    var deliveryState: String? = nil
    var wrapUpStartedAt: Date? = nil

    var shortPrompt: String {
        let value = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 96 ? String(value.prefix(96)) + "…" : value
    }
}

/// Owns a bounded child-agent tree for each root conversation.
///
/// Child agents reuse the existing AIChatViewModel/agent loop instead of adding
/// a second provider stack. This keeps provider routing, tools, cancellation,
/// background handling, and persistence consistent with normal Ze sessions.
@MainActor
final class ZeSubAgentCoordinator: ObservableObject {
    static let shared = ZeSubAgentCoordinator()

    static let maxAgentsPerRoot = 6
    static let maxDepth = 3
    static let maxQueuedPerRoot = 24
    static let defaultBudgetMinutes = 10
    static let maxBudgetMinutes = 60
    static let wrapUpGraceSeconds: TimeInterval = 90
    static let wrapUpToolPatience: TimeInterval = 20

    private final class ParentReference {
        weak var value: AIChatViewModel?
        init(_ value: AIChatViewModel) { self.value = value }
    }

    /// A single cheap scalar invalidates the dock; records themselves stay in
    /// private dictionaries so SwiftUI never deep-compares every session row.
    @Published private(set) var updateToken: Int = 0

    private var recordsByRoot: [String: [String: ZeSubAgentRecord]] = [:]
    private var loadedRoots: Set<String> = []
    private var children: [String: AIChatViewModel] = [:]
    private var childAgentIds: [ObjectIdentifier: String] = [:]
    private var parents: [String: ParentReference] = [:]
    private var queuedStarts: [String: [String]] = [:]
    private var queuedInputs: [String: [String]] = [:]
    private var deliveryTasks: [String: Task<Void, Never>] = [:]
    private var mutedDeliveries: Set<String> = []
    private var inlineWaiters: [String: Int] = [:]
    private var budgetToolStopped: Set<String> = []
    private let now: () -> Date
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private var launchTasks: [String: Task<Void, Never>] = [:]
    private var finishingTasks: [String: Task<Void, Never>] = [:]
    private var loadTasks: [String: Task<Void, Never>] = [:]
    private var launchInputs: [String: [String]] = [:]
    private var toolNameHistoryCounts: [String: Int] = [:]
    private var cachedToolNames: [String: [String: String]] = [:]
    private var completedSteps: [String: [UUID: [ZeSubAgentStep]]] = [:]
    private var completedToolSteps: [String: [UUID: ZeSubAgentStep]] = [:]
    private var lastPersistedAt: [String: Date] = [:]
    private var persistTasks: [String: Task<Void, Never>] = [:]
    private var publishScheduled = false
    private static let persistenceQueue = DispatchQueue(label: "app.ze.subagents.persistence", qos: .utility)
    private var settingsParent: AIChatViewModel?
    private let logger = AppLogger(category: "SubAgents")

    private let makeChild: @MainActor () -> AIChatViewModel
    private let storageDirectory: URL?

    init(storageDirectory: URL? = nil, now: @escaping () -> Date = Date.init,
         makeChild: @escaping @MainActor () -> AIChatViewModel = { AIChatViewModel() }) {
        self.storageDirectory = storageDirectory
        self.makeChild = makeChild
        self.now = now
    }

    func records(for rootSessionId: String) -> [ZeSubAgentRecord] {
        loadRootIfNeeded(rootSessionId)
        return recordsByRoot[rootSessionId, default: [:]].values.sorted {
            if $0.status.isActive != $1.status.isActive { return $0.status.isActive }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }

    func activeCount(for rootSessionId: String) -> Int {
        records(for: rootSessionId).filter { $0.status.isActive }.count
    }

    func record(id: String, rootSessionId: String) -> ZeSubAgentRecord? {
        loadRootIfNeeded(rootSessionId)
        return recordsByRoot[rootSessionId]?[id]
    }

    func record(id: String) -> ZeSubAgentRecord? {
        guard let location = locate(id: id) else { return nil }
        return record(id: id, rootSessionId: location.root)
    }

    func owns(id: String, parent: AIChatViewModel) -> Bool {
        let root = rootSessionId(for: parent)
        loadRootIfNeeded(root)
        guard let location = locate(id: id), location.root == root else { return false }
        let owner = childAgentIds[ObjectIdentifier(parent)] ?? root
        let owned = location.record.parentId == owner
        if owned { parents[id] = ParentReference(parent) }
        return owned
    }

    @discardableResult
    func spawn(
        from parent: AIChatViewModel,
        message: String,
        forkContext: Bool = false,
        nickname: String = "",
        modelEntryReference: String? = nil,
        budgetMinutes: Int = ZeSubAgentCoordinator.defaultBudgetMinutes
    ) -> ZeSubAgentRecord {
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = rootSessionId(for: parent)
        guard ZeSubAgentPreferences.isEnabled else {
            return failedRecord(root: root, parent: parent, message: "子代理功能已关闭，请在设置中重新启用。")
        }
        loadRootIfNeeded(root)
        let existing = recordsByRoot[root, default: [:]].values
        guard !prompt.isEmpty else { return failedRecord(root: root, parent: parent, message: "子代理任务不能为空") }
        guard queuedStarts[root, default: []].count < Self.maxQueuedPerRoot else {
            return failedRecord(root: root, parent: parent, message: "当前会话已有 24 个子代理排队，请等待部分任务结束。")
        }

        let parentId = childAgentIds[ObjectIdentifier(parent)] ?? root
        let parentDepth = recordsByRoot[root]?[parentId]?.depth ?? 0
        guard parentDepth < Self.maxDepth else {
            return failedRecord(root: root, parent: parent, message: "子代理层级最多为 3 层")
        }

        let requestedModelReference = modelEntryReference ?? ZeSubAgentPreferences.configuredModelEntryReference
        let configuredEntry = requestedModelReference.flatMap { ProviderConfigStore.shared.entry(for: $0) }
        let inheritedEntry = parent.resolveCurrentEntry()
        let effectiveEntry = configuredEntry ?? inheritedEntry
        let effectiveModelReference = effectiveEntry?.id
        let id = UUID().uuidString
        let now = Date()
        var record = ZeSubAgentRecord(
            id: id,
            parentId: parentId,
            rootSessionId: root,
            nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "子代理 \(existing.count + 1)" : String(nickname.prefix(40)),
            depth: parentDepth + 1,
            status: .queued,
            revision: 1,
            createdAt: now,
            updatedAt: now,
            prompt: prompt,
            output: "",
            error: nil,
            childSessionId: nil,
            inputTokens: 0,
            outputTokens: 0,
            modelEntryReference: effectiveModelReference,
            steps: []
        )
        record.parentTurnId = parent.messages.last(where: { $0.role == .assistant })?.id.uuidString
        record.budgetMinutes = min(Self.maxBudgetMinutes, max(1, budgetMinutes))
        record.modelPinUnavailable = requestedModelReference != nil && configuredEntry == nil
        record.requestedModel = configuredEntry?.model.displayName ?? requestedModelReference
            ?? effectiveEntry?.model.displayName ?? parent.selectedModel.displayName
        record.deliveryState = "pending"
        parents[id] = ParentReference(parent)
        recordsByRoot[root, default: [:]][id] = record
        persist(root)
        publish()

        let child = makeChild()
        child.sessionSource = "subagent"
        // Keep the child chat session independent, but route /var/ze workspace,
        // attachments, offloads, and browser files through the root session's
        // filesystem context. This makes real file artifacts visible to the
        // parent and sibling agents instead of leaving them in isolated folders.
        child.workspaceSessionId = parent.fileSystemSessionId ?? root
        child.preferredModelEntryReference = effectiveEntry?.id
        child.selectedModel = effectiveEntry?.model ?? parent.selectedModel
        child.initialGroupId = effectiveEntry == nil ? parent.initialGroupId : nil
        child.memoryEnabled = parent.memoryEnabled
        child.autoCompactEnabled = true
        if forkContext {
            child.agentHistory = forkedHistory(from: parent.agentHistory)
        }
        children[id] = child
        childAgentIds[ObjectIdentifier(child)] = id
        queuedInputs[id] = [prompt]
        queuedStarts[root, default: []].append(id)
        drainQueuedStarts(root: root)
        logger.info("[SubAgent] spawn id=\(id.prefix(8)) root=\(root.prefix(8)) depth=\(record.depth) fork=\(forkContext)")
        return self.record(id: id, rootSessionId: root) ?? record
    }

    @discardableResult
    func spawnFromSettings(message: String) -> ZeSubAgentRecord {
        if settingsParent == nil {
            let parent = makeChild()
            parent.sessionId = ZeSubAgentPreferences.settingsRootSessionId
            parent.workspaceSessionId = ZeSubAgentPreferences.settingsRootSessionId
            parent.sessionSource = "subagent-settings"
            settingsParent = parent
        }
        guard let parent = settingsParent else {
            return failedRecord(root: ZeSubAgentPreferences.settingsRootSessionId, parent: AIChatViewModel(), message: "子代理设置初始化失败")
        }
        return spawn(from: parent, message: message, forkContext: false, nickname: "")
    }

    /// Running children read queued input at the next model turn, after any
    /// in-flight tool batch has committed its results. The existing chat queue
    /// supplies the persistence and tool-call/result pairing guarantees.
    func sendInput(id: String, message: String, interrupt: Bool = false) -> ZeSubAgentRecord? {
        guard let location = locate(id: id), var record = record(id: id, rootSessionId: location.root) else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, record.status != .closed, record.status != .cancelling else { return nil }
        guard !record.status.isActive || record.wrapUpStartedAt == nil || interrupt else { return nil }
        if queuedInputs[id] != nil {
            queuedInputs[id, default: []].append(text)
            record.pendingInputCount = max(0, queuedInputs[id, default: []].count - 1)
            update(record, root: location.root)
            return record
        }
        if launchTasks[id] != nil {
            launchInputs[id, default: []].append(text)
            record.pendingInputCount = launchInputs[id]?.count
            update(record, root: location.root)
            return record
        }
        let child = childModel(for: record)
        if child.isProcessing && !interrupt {
            child.inputText = text
            child.enqueuePrompt()
            record.pendingInputCount = child.promptQueue.count
            record.updatedAt = Date()
            update(record, root: location.root)
            return record
        }
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        if child.isProcessing {
            stopChild(id: id)
        }
        let previousTask = finishingTasks[id]
        record.status = .queued
        record.error = nil
        record.startedAt = nil
        record.finishedAt = nil
        record.wrapUpStartedAt = nil
        record.deliveryState = "pending"
        mutedDeliveries.remove(id)
        deliveryTasks.removeValue(forKey: id)?.cancel()
        record.revision += 1
        record.updatedAt = Date()
        record.pendingInputCount = 1
        update(record, root: location.root)
        let revision = record.revision
        launchInputs[id] = [text]
        launchTasks[id] = Task { @MainActor [weak self, weak child] in
            // cancel() makes isProcessing false before cleanup has finished.
            // Joining the actual task prevents the old cleanup from corrupting
            // the new turn; an arbitrary delay cannot provide that guarantee.
            await previousTask?.value
            guard let self, let child, !Task.isCancelled else { return }
            await self.loadTasks[id]?.value
            guard !Task.isCancelled,
                  var current = self.record(id: id, rootSessionId: location.root),
                  current.revision == revision, current.status == .queued else { return }
            let inputs = self.launchInputs.removeValue(forKey: id) ?? []
            self.launchTasks[id] = nil
            self.finishingTasks[id] = nil
            current.pendingInputCount = 0
            current.output = ""
            current.steps = []
            self.update(current, root: location.root)
            self.queuedInputs[id] = inputs
            self.queuedStarts[location.root, default: []].append(id)
            self.drainQueuedStarts(root: location.root)
        }
        return record
    }

    /// Reuse the real child transcript, including its normal tool renderers.
    func transcriptViewModel(id: String) async -> AIChatViewModel? {
        guard let record = record(id: id) else { return nil }
        let child = childModel(for: record)
        await loadTasks[id]?.value
        return child
    }

    private func childModel(for record: ZeSubAgentRecord) -> AIChatViewModel {
        if let existing = children[record.id] { return existing }
        let child = makeChild()
        child.sessionSource = "subagent"
        child.workspaceSessionId = record.rootSessionId
        child.preferredModelEntryReference = record.modelEntryReference
        if let ref = record.modelEntryReference, let entry = ProviderConfigStore.shared.entry(for: ref) {
            child.selectedModel = entry.model
        }
        children[record.id] = child
        childAgentIds[ObjectIdentifier(child)] = record.id
        if let sessionId = record.childSessionId {
            child.sessionId = sessionId
            loadTasks[record.id] = Task { @MainActor [weak child] in
                guard let child else { return }
                await child.loadSession(activate: false)
            }
        } else if !record.output.isEmpty {
            // Legacy records without a session link still retain useful context.
            child.agentHistory = [AgentMessage(role: .user, parts: [.text(record.prompt)]),
                                  AgentMessage(role: .assistant, parts: [.text(record.output)])]
        }
        return child
    }

    private func stopChild(id: String) {
        launchTasks.removeValue(forKey: id)?.cancel()
        launchInputs[id] = nil
        queuedInputs[id] = nil
        if let root = locate(id: id)?.root { queuedStarts[root]?.removeAll { $0 == id } }
        guard let child = children[id] else { return }
        // cancel() normally resumes queued chat prompts. A child Stop means
        // stop the whole task, including corrections that have not run yet.
        for prompt in child.promptQueue { child.removeQueuedPrompt(id: prompt.id) }
        if let task = child.currentTask { finishingTasks[id] = task }
        child.cancel()
    }

    /// Stop the requested child and its descendants. Siblings are preserved
    /// for tool callers that explicitly address one child by ID.
    func cancel(id: String) {
        guard let location = locate(id: id), var record = record(id: id, rootSessionId: location.root) else { return }
        let all = Array(recordsByRoot[location.root, default: [:]].values)
        var pendingParents = [id]
        var descendants: [String] = []
        while let parentId = pendingParents.popLast() {
            for childRecord in all where childRecord.parentId == parentId {
                pendingParents.append(childRecord.id)
                if childRecord.status.isActive { descendants.append(childRecord.id) }
            }
        }
        for childId in descendants where self.record(id: childId)?.status.isActive == true { cancel(id: childId) }
        pollTasks.removeValue(forKey: id)?.cancel()
        stopChild(id: id)
        record.status = .cancelled
        record.error = nil
        record.pendingInputCount = 0
        record.finishedAt = now()
        mutedDeliveries.insert(id)
        deliveryTasks.removeValue(forKey: id)?.cancel()
        record.deliveryState = "suppressed"
        record.steps = record.steps?.map { step in
            guard step.state == "running" else { return step }
            return ZeSubAgentStep(id: step.id, title: step.title, icon: step.icon,
                                  content: step.content, state: "cancelled", duration: step.duration, imageFilePath: step.imageFilePath, toolName: step.toolName)
        }
        record.revision += 1
        record.updatedAt = Date()
        update(record, root: location.root)
        let revision = record.revision
        let finishing = finishingTasks[id]
        Task { @MainActor [weak self] in
            await finishing?.value
            guard let self, self.record(id: id)?.revision == revision else { return }
            self.finishingTasks[id] = nil
            self.drainQueuedStarts(root: location.root)
        }
    }

    /// The detail card's Stop covers siblings from this exact delegating turn.
    /// Old records with no turn identity deliberately stop only the selection.
    func cancelRunGroup(id: String) {
        guard let selected = record(id: id) else { return }
        let group = records(for: selected.rootSessionId).filter {
            Self.belongsToRunGroup($0, selected: selected) && $0.status.isActive
        }.map(\.id)
        for childId in group { cancel(id: childId) }
    }

    static func belongsToRunGroup(_ candidate: ZeSubAgentRecord, selected: ZeSubAgentRecord) -> Bool {
        if candidate.id == selected.id { return true }
        guard let turn = selected.parentTurnId else { return false }
        return candidate.rootSessionId == selected.rootSessionId && candidate.parentId == selected.parentId
            && candidate.parentTurnId == turn
    }

    func close(id: String) {
        guard let location = locate(id: id) else { return }
        cancel(id: id)
        guard var record = record(id: id, rootSessionId: location.root) else { return }
        record.status = .closed
        record.updatedAt = Date()
        update(record, root: location.root)
        let previous = finishingTasks[id]
        let revision = record.revision
        Task { @MainActor [weak self] in
            await previous?.value
            guard let self, let current = self.record(id: id),
                  current.status == .closed, current.revision == revision else { return }
            if let child = self.children.removeValue(forKey: id) {
                self.childAgentIds[ObjectIdentifier(child)] = nil
            }
            self.loadTasks[id] = nil
            self.finishingTasks[id] = nil
            self.completedSteps[id] = nil
            self.completedToolSteps[id] = nil
        }
    }

    func resume(id: String) -> ZeSubAgentRecord? {
        guard var record = record(id: id) else { return nil }
        guard [.closed, .interrupted, .failed, .cancelled, .timedOut].contains(record.status) else { return record }
        let continuation = record.childSessionId == nil && record.output.isEmpty
            ? record.prompt
            : "此前任务已中断，现在继续。已有对话和工作区文件仍有效，但浏览器标签、运行中的 shell 进程和未保存状态可能已丢失。按已有结果继续，需要时重新打开页面或运行命令，不要假定旧进程仍在运行。完成后报告最终结果。"
        mutedDeliveries.remove(id)
        record.status = .idle
        update(record, root: record.rootSessionId)
        return sendInput(id: id, message: continuation)
    }

    func wait(ids: [String], timeout: TimeInterval = 30) async -> [ZeSubAgentRecord] {
        let wanted = Set(ids.filter { !$0.isEmpty })
        for id in wanted { deliveryTasks.removeValue(forKey: id)?.cancel() }
        for id in wanted { inlineWaiters[id, default: 0] += 1 }
        defer {
            for id in wanted {
                let remaining = max(0, inlineWaiters[id, default: 1] - 1)
                inlineWaiters[id] = remaining == 0 ? nil : remaining
                guard let record = record(id: id), !record.status.isActive,
                      record.deliveryState == "pending" else { continue }
                if Task.isCancelled { deliverResult(record) }
                else { markDelivery(id: id, revision: record.revision, state: "inline") }
            }
        }
        let deadline = Date().addingTimeInterval(min(max(timeout, 0), 300))
        while !Task.isCancelled && Date() < deadline {
            let current = wanted.compactMap { id -> ZeSubAgentRecord? in
                guard let loc = locate(id: id) else { return nil }
                return record(id: id, rootSessionId: loc.root)
            }
            if current.isEmpty || current.allSatisfy({ !$0.status.isActive }) { return current }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { break }
        }
        return wanted.compactMap { id -> ZeSubAgentRecord? in
            guard let loc = locate(id: id) else { return nil }
            return record(id: id, rootSessionId: loc.root)
        }
    }

    func toolSummary(_ record: ZeSubAgentRecord?) -> String {
        guard let record else { return "未知子代理" }
        return "\(record.nickname) [\(record.status.displayName)]\(record.output.isEmpty ? "" : "\n\(String(record.output.suffix(1200)))")"
    }

    /// Called from the real provider route for each attempted model, including
    /// fallback. This is request identity, never inferred server identity.
    func recordRequest(from child: AIChatViewModel, modelId: String, modelName: String, provider: String) {
        guard let id = childAgentIds[ObjectIdentifier(child)], let location = locate(id: id) else { return }
        var record = location.record
        guard record.requestModelId != modelId || record.requestProviderName != provider else { return }
        record.requestModelId = modelId
        record.requestModelName = modelName
        record.requestProviderName = provider
        update(record, root: location.root)
    }

    /// Stop is a lasting veto for results belonging to that run, even after
    /// the parent's cancellation handler resets userDidCancel for a new turn.
    func parentDidCancel(_ parent: AIChatViewModel) {
        parent.discardQueuedSubAgentResults()
        let root = rootSessionId(for: parent)
        let owner = childAgentIds[ObjectIdentifier(parent)] ?? root
        let owned = Set(parents.compactMap { $0.value.value === parent ? $0.key : nil })
            .union(recordsByRoot[root, default: [:]].values.filter { $0.parentId == owner }.map(\.id))
        for id in owned {
            mutedDeliveries.insert(id)
            deliveryTasks.removeValue(forKey: id)?.cancel()
        }
        for id in owned where record(id: id)?.status.isActive == true { cancel(id: id) }
    }

    private func runningSlots(root: String) -> Int {
        recordsByRoot[root, default: [:]].values.filter {
            ($0.status.isActive && $0.startedAt != nil && queuedInputs[$0.id] == nil)
                || finishingTasks[$0.id] != nil
        }.count
    }

    private func drainQueuedStarts(root: String) {
        while runningSlots(root: root) < Self.maxAgentsPerRoot,
              let id = queuedStarts[root]?.first {
            queuedStarts[root]?.removeFirst()
            guard var record = record(id: id, rootSessionId: root), record.status == .queued,
                  let child = children[id], let inputs = queuedInputs.removeValue(forKey: id) else { continue }
            record.startedAt = now()
            record.finishedAt = nil
            record.wrapUpStartedAt = nil
            record.deliveryState = "pending"
            record.pendingInputCount = 0
            budgetToolStopped.remove(id)
            child.zeSubAgentWrapUpRequested = false
            update(record, root: root)
            child.inputText = inputs.joined(separator: "\n\n")
            child.send()
            startPolling(id: id, root: root)
        }
    }

    enum BudgetAction: Equatable { case none, wrapUp, stopTool, timeout }
    static func budgetAction(startedAt: Date?, budgetMinutes: Int?, wrapUpAt: Date?,
                             stoppedTool: Bool, now: Date) -> BudgetAction {
        guard let startedAt, let budgetMinutes,
              now.timeIntervalSince(startedAt) >= Double(budgetMinutes * 60) else { return .none }
        guard let wrapUpAt else { return .wrapUp }
        let grace = now.timeIntervalSince(wrapUpAt)
        if grace >= wrapUpGraceSeconds { return .timeout }
        if grace >= wrapUpToolPatience && !stoppedTool { return .stopTool }
        return .none
    }

    private func markDelivery(id: String, revision: Int, state: String) {
        guard let location = locate(id: id), location.record.revision == revision else { return }
        var record = location.record
        record.deliveryState = state
        update(record, root: location.root)
    }

    private func deliverResult(_ record: ZeSubAgentRecord) {
        guard record.deliveryState == "pending", inlineWaiters[record.id, default: 0] == 0,
              deliveryTasks[record.id] == nil else { return }
        guard !mutedDeliveries.contains(record.id),
              let parent = parents[record.id]?.value ?? children[record.parentId]
                ?? (record.parentId == record.rootSessionId ? ViewModelCache.shared.get(for: record.parentId) : nil),
              record.rootSessionId != ZeSubAgentPreferences.settingsRootSessionId else {
            markDelivery(id: record.id, revision: record.revision, state: "suppressed")
            return
        }
        parents[record.id] = ParentReference(parent)
        let parentTask = parent.isProcessing ? nil : parent.currentTask
        deliveryTasks[record.id] = Task { @MainActor [weak self, weak parent] in
            await parentTask?.value
            guard let self else { return }
            // A cancelled older delivery must never erase a newer revision's task.
            guard !Task.isCancelled else { return }
            defer { self.deliveryTasks[record.id] = nil }
            guard let parent, !self.mutedDeliveries.contains(record.id),
                  self.inlineWaiters[record.id, default: 0] == 0,
                  let current = self.record(id: record.id), current.revision == record.revision,
                  current.deliveryState == "pending" else { return }
            let body = record.output.isEmpty ? (record.error ?? "没有最终输出，请检查子代理记录。") : record.output
            let text = "[子代理任务结束 · \(record.nickname) · \(record.status.displayName) · id=\(record.id)]\n" + body
            let accepted = parent.submitSubAgentResult(text)
            self.markDelivery(id: record.id, revision: record.revision, state: accepted ? "delivered" : "unavailable")
        }
    }

    // MARK: - Runtime

    private func startPolling(id: String, root: String) {
        pollTasks[id]?.cancel()
        completedSteps[id] = [:]
        completedToolSteps[id] = [:]
        toolNameHistoryCounts[id] = nil
        cachedToolNames[id] = nil
        pollTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let child = self.children[id] {
                guard let current = self.record(id: id, rootSessionId: root) else { return }
                var next = current
                if child.isProcessing {
                    switch Self.budgetAction(startedAt: current.startedAt, budgetMinutes: current.budgetMinutes,
                                             wrapUpAt: current.wrapUpStartedAt, stoppedTool: self.budgetToolStopped.contains(id), now: self.now()) {
                    case .none: break
                    case .wrapUp:
                        next.wrapUpStartedAt = self.now()
                        child.zeSubAgentWrapUpRequested = true
                    case .stopTool:
                        self.budgetToolStopped.insert(id)
                        child.stopCurrentCommand()
                    case .timeout:
                        self.stopChild(id: id)
                        next.status = .timedOut
                        next.error = "已达到时间预算及 90 秒收尾宽限。"
                        next.output = self.output(from: child)
                        next.steps = self.steps(from: child, id: id)
                        next.finishedAt = self.now()
                        next.updatedAt = self.now()
                        self.update(next, root: root)
                        self.pollTasks[id] = nil
                        self.deliverResult(next)
                        let finishing = self.finishingTasks[id]
                        let revision = next.revision
                        Task { @MainActor [weak self] in
                            await finishing?.value
                            guard let self, self.record(id: id)?.revision == revision else { return }
                            self.finishingTasks[id] = nil
                            self.drainQueuedStarts(root: root)
                        }
                        return
                    }
                }
                next.error = child.errorMessage ?? child.messages.last(where: { $0.role == .assistant })?.error
                next.status = Self.runtimeStatus(processing: child.isProcessing, suspended: child.isSuspended,
                                                 cancelled: child.userDidCancel, resumable: child.canResume,
                                                 error: next.error)
                next.output = self.output(from: child)
                next.steps = self.steps(from: child, id: id)
                next.childSessionId = child.sessionId
                // These counters are maintained by the request loop. Avoid
                // sessionTokenStats, which rescans every historical tool block.
                next.inputTokens = child.sessionInputTokens
                next.outputTokens = child.sessionOutputTokens
                next.cacheReadTokens = child.sessionCacheReadTokens
                next.turnCount = child.agentHistory.lazy.filter { $0.role == .assistant }.count
                next.pendingInputCount = child.promptQueue.count
                if !next.status.isActive { next.finishedAt = self.now() }
                if next.status == .completed, Self.hasFinalAnswer(child.agentHistory), let final = child.agentHistory.last {
                    next.output = final.parts.compactMap { part -> String? in
                        if case .text(let text) = part { return text }
                        return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if next.status == .completed && !Self.hasFinalAnswer(child.agentHistory) {
                    next.status = .failed
                    next.error = "子代理结束，但没有返回最终交付内容。"
                }
                if next != current {
                    next.updatedAt = Date()
                    self.update(next, root: root, immediate: next.status != current.status || !next.status.isActive)
                }
                if !child.isProcessing {
                    self.pollTasks[id] = nil
                    self.completedSteps[id] = nil
                    self.completedToolSteps[id] = nil
                    self.deliverResult(next)
                    let finishing = child.currentTask
                    self.finishingTasks[id] = finishing
                    let revision = next.revision
                    Task { @MainActor [weak self] in
                        await finishing?.value
                        guard let self, self.record(id: id)?.revision == revision else { return }
                        self.finishingTasks[id] = nil
                        self.drainQueuedStarts(root: root)
                    }
                    return
                }
                do { try await Task.sleep(nanoseconds: 350_000_000) }
                catch { return }
            }
        }
    }

    static func hasFinalAnswer(_ history: [AgentMessage]) -> Bool {
        guard let last = history.last, last.role == .assistant else { return false }
        var hasText = false
        for part in last.parts {
            switch part {
            case .toolUse: return false
            case .text(let text):
                hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default: break
            }
        }
        return hasText
    }

    static func runtimeStatus(processing: Bool, suspended: Bool, cancelled: Bool,
                              resumable: Bool, error: String?) -> ZeSubAgentStatus {
        if processing { return suspended ? .queued : .running }
        if cancelled { return .cancelled }
        if error != nil { return .failed }
        if resumable { return .interrupted }
        return .completed
    }

    private func steps(from child: AIChatViewModel, id: String) -> [ZeSubAgentStep] {
        let messages = child.messages.filter { $0.role == .assistant }
        let liveId = messages.last?.id
        var toolNames = cachedToolNames[id, default: [:]]
        var knownCount = toolNameHistoryCounts[id, default: 0]
        if knownCount > child.agentHistory.count { knownCount = 0; toolNames = [:] }
        for message in child.agentHistory.dropFirst(knownCount) {
            for part in message.parts {
                if case .toolUse(let toolId, let name, _) = part { toolNames[toolId] = name }
            }
        }
        toolNameHistoryCounts[id] = child.agentHistory.count
        cachedToolNames[id] = toolNames
        var cache = completedSteps[id, default: [:]]
        var toolCache = completedToolSteps[id, default: [:]]
        let validIds = Set(messages.map(\.id))
        cache = cache.filter { validIds.contains($0.key) }
        let result = messages.flatMap { message -> [ZeSubAgentStep] in
            if message.id != liveId, let cached = cache[message.id] { return cached }
            let steps = message.blocks.compactMap { block -> ZeSubAgentStep? in
                // Reasoning is intentionally kept out of the sub-agent card.
                // Its buffer changes for nearly every streamed token; copying
                // it into the coordinator record forces persistence, object
                // publication, and a full card diff on every poll, which causes
                // visible frame drops while a child model is thinking.
                guard block.kind != .thinking else { return nil }
                if let cached = toolCache[block.id] { return cached }
                var title: String
                let icon: String
                var toolName: String? = nil
                switch block.kind {
                case .text:
                    guard !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    title = "子代理回复"; icon = "text.bubble"
                case .thinking:
                    title = "正在思考"; icon = "brain.head.profile"
                case .shellTool:
                    toolName = "shell_execute"
                    title = "命令 · \(block.toolDescription)"; icon = "terminal"
                case .fileReadTool:
                    toolName = "file_read"
                    title = "读取文件 · \(block.toolDescription)"; icon = "doc.text.magnifyingglass"
                case .fileWriteTool:
                    toolName = "file_write"
                    title = "写入文件 · \(block.toolDescription)"; icon = "square.and.pencil"
                case .fileEditTool:
                    toolName = "file_edit"
                    title = "编辑文件 · \(block.toolDescription)"; icon = "pencil.line"
                case .browserTool:
                    toolName = "browser_use"
                    title = "浏览器 · \(block.toolDescription)"; icon = "safari"
                case .readImageTool:
                    toolName = "read_image"
                    title = "查看图片 · \(block.toolDescription)"; icon = "photo"
                case .memoryTool(let action):
                    toolName = action
                    title = "代理工具 · \(block.toolDescription)"; icon = "square.stack.3d.up"
                case .info:
                    title = "进度"; icon = "info.circle"
                }
                if let id = block.toolUseId, let actualName = toolNames[id] { toolName = actualName }
                if toolName != nil { title = block.toolSummary ?? block.toolDescription }
                let state: String
                switch block.toolStatus {
                case .streaming, .running: state = "running"
                case .success: state = "success"
                case .failed: state = "failed"
                case .cancelled: state = "cancelled"
                case nil: state = "info"
                }
                let detail = block.content
                let step = ZeSubAgentStep(
                    id: block.id.uuidString,
                    title: String(title.prefix(160)),
                    icon: icon,
                    content: String(detail.suffix(1600)),
                    state: state,
                    duration: block.toolDuration,
                    imageFilePath: block.imageFilePath,
                    toolName: toolName
                )
                if block.toolDuration != nil && ["success", "failed", "cancelled"].contains(state) {
                    toolCache[block.id] = step
                }
                return step
            }
            if message.id != liveId { cache[message.id] = steps }
            return steps
        }
        completedSteps[id] = cache
        completedToolSteps[id] = toolCache
        return result
    }

    private func output(from child: AIChatViewModel) -> String {
        // The detail surface is a latest-output preview. Walking backwards
        // bounds copying even when a session contains megabytes of tool logs.
        var fragments: [String] = []
        var remaining = 32_000
        for message in child.messages.reversed() where message.role == .assistant {
            for block in message.blocks.reversed() where block.kind == .text {
                let tail = String(block.content.suffix(remaining))
                if !tail.isEmpty {
                    fragments.append(tail)
                    remaining -= tail.count + 1
                    if remaining <= 0 { break }
                }
            }
            if !fragments.isEmpty { break }
        }
        return fragments.reversed().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rootSessionId(for vm: AIChatViewModel) -> String {
        if let id = childAgentIds[ObjectIdentifier(vm)], let location = locate(id: id) { return location.root }
        return vm.sessionId ?? vm.draftId ?? "root-\(ObjectIdentifier(vm).hashValue)"
    }

    private func locate(id: String) -> (root: String, record: ZeSubAgentRecord)? {
        for (root, records) in recordsByRoot {
            if let record = records[id] { return (root, record) }
        }
        return nil
    }

    private func failedRecord(root: String, parent: AIChatViewModel, message: String) -> ZeSubAgentRecord {
        let now = Date()
        return ZeSubAgentRecord(id: UUID().uuidString, parentId: root, rootSessionId: root, nickname: "子代理", depth: 0, status: .failed, revision: 1, createdAt: now, updatedAt: now, prompt: "", output: "", error: message, childSessionId: nil, inputTokens: 0, outputTokens: 0, modelEntryReference: nil, steps: [])
    }

    private func update(_ record: ZeSubAgentRecord, root: String, immediate: Bool = true) {
        recordsByRoot[root, default: [:]][record.id] = record
        if immediate || Date().timeIntervalSince(lastPersistedAt[root] ?? .distantPast) >= 2 {
            persist(root)
        } else if persistTasks[root] == nil {
            // A throttle with a trailing flush: continuous tokens cannot defer
            // the write indefinitely, and the last partial output is retained.
            persistTasks[root] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard let self else { return }
                self.persistTasks[root] = nil
                self.persist(root)
            }
        }
        publish()
    }

    private func publish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.publishScheduled = false
            self.updateToken &+= 1
        }
    }

    // MARK: - Persistence

    private func loadRootIfNeeded(_ root: String) {
        guard !loadedRoots.contains(root) else { return }
        loadedRoots.insert(root)
        let url = fileURL(for: root)
        guard let data = try? Data(contentsOf: url), var records = try? JSONDecoder().decode([ZeSubAgentRecord].self, from: data) else {
            recordsByRoot[root] = [:]
            return
        }
        for index in records.indices where records[index].status.isActive {
            records[index].status = .interrupted
            records[index].pendingInputCount = 0
            records[index].error = String(localized: "应用重新启动后，未自动重跑此子代理。")
            records[index].revision += 1
            records[index].updatedAt = Date()
        }
        recordsByRoot[root] = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        if records.contains(where: { $0.status == .interrupted }) { persist(root) }
    }

    private func persist(_ root: String) {
        loadRootIfNeeded(root)
        persistTasks.removeValue(forKey: root)?.cancel()
        lastPersistedAt[root] = Date()
        let url = fileURL(for: root)
        let snapshot = Array(recordsByRoot[root, default: [:]].values)
        // Serial ordering prevents an older partial snapshot from overwriting
        // a terminal state. Encoding and atomic disk IO stay off the UI actor.
        Self.persistenceQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                AppLogger(category: "SubAgents").error("[SubAgent] persist failed: \(error.localizedDescription)")
            }
        }
    }

    private func fileURL(for root: String) -> URL {
        let base = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ze/SubAgents", isDirectory: true)
        let safe = Data(root.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return base.appendingPathComponent("\(safe).json")
    }

    private func forkedHistory(from history: [AgentMessage]) -> [AgentMessage] {
        var total = 0
        let recent = Array(history.suffix(48))
        return recent.compactMap { message in
            var copy = message
            copy.dbMessageId = nil
            copy.reasoningEcho = nil
            copy.reasoningContent = nil
            var parts: [AgentContentPart] = []
            for part in message.parts {
                let text: String
                switch part {
                case .text(let value):
                    text = value
                case .toolUse(_, let name, _):
                    text = "[此前调用工具：\(name)]"
                case .toolResult(_, let name, let value, let isError, _, _, _, _):
                    text = "[此前工具结果 \(name)\(isError ? "（失败）" : "")]\n\(value)"
                case .imageData:
                    text = "[图片上下文已省略；需要时请重新使用 read_image]"
                }
                let clipped = String(text.suffix(8_000))
                total += clipped.count
                if total <= 120_000 { parts.append(.text(clipped)) }
            }
            guard !parts.isEmpty else { return nil }
            copy.parts = parts
            return copy
        }
    }
}
