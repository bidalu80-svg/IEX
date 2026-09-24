import Combine
import Foundation

/// Persistent state for one independently running child agent.
enum ZeSubAgentStatus: String, Codable, CaseIterable {
    case idle, queued, running, awaitingApproval = "awaiting_approval", cancelling
    case completed, failed, cancelled, interrupted, closed

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
        }
    }
}

struct ZeSubAgentRecord: Identifiable, Codable, Equatable {
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

    /// A single cheap scalar invalidates the dock; records themselves stay in
    /// private dictionaries so SwiftUI never deep-compares every session row.
    @Published private(set) var updateToken: Int = 0

    private var recordsByRoot: [String: [String: ZeSubAgentRecord]] = [:]
    private var loadedRoots: Set<String> = []
    private var children: [String: AIChatViewModel] = [:]
    private var childAgentIds: [ObjectIdentifier: String] = [:]
    private var pollTasks: [String: Task<Void, Never>] = [:]
    private let logger = AppLogger(category: "SubAgents")

    private init() {}

    func records(for rootSessionId: String) -> [ZeSubAgentRecord] {
        loadRootIfNeeded(rootSessionId)
        return recordsByRoot[rootSessionId, default: [:]].values.sorted {
            if $0.status.isActive != $1.status.isActive { return $0.status.isActive }
            return $0.updatedAt > $1.updatedAt
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
        return location.record.parentId == owner
    }

    @discardableResult
    func spawn(from parent: AIChatViewModel, message: String, forkContext: Bool = false, nickname: String = "") -> ZeSubAgentRecord {
        let prompt = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = rootSessionId(for: parent)
        loadRootIfNeeded(root)
        let existing = recordsByRoot[root, default: [:]].values
        guard !prompt.isEmpty else { return failedRecord(root: root, parent: parent, message: "子代理任务不能为空") }
        guard existing.filter({ $0.status != .closed }).count < Self.maxAgentsPerRoot else {
            return failedRecord(root: root, parent: parent, message: "已达到当前会话的子代理上限（6）")
        }

        let parentId = childAgentIds[ObjectIdentifier(parent)] ?? root
        let parentDepth = recordsByRoot[root]?[parentId]?.depth ?? 0
        guard parentDepth < Self.maxDepth else {
            return failedRecord(root: root, parent: parent, message: "子代理层级最多为 3 层")
        }

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
            outputTokens: 0
        )
        recordsByRoot[root, default: [:]][id] = record
        persist(root)
        publish()

        let child = AIChatViewModel()
        child.sessionSource = "subagent"
        // Keep the child chat session independent, but route /var/ze workspace,
        // attachments, offloads, and browser files through the root session's
        // filesystem context. This makes real file artifacts visible to the
        // parent and sibling agents instead of leaving them in isolated folders.
        child.workspaceSessionId = parent.fileSystemSessionId ?? root
        child.selectedModel = parent.selectedModel
        child.initialGroupId = parent.initialGroupId
        child.memoryEnabled = parent.memoryEnabled
        child.autoCompactEnabled = true
        if forkContext {
            child.agentHistory = forkedHistory(from: parent.agentHistory)
        }
        children[id] = child
        childAgentIds[ObjectIdentifier(child)] = id
        child.inputText = prompt
        child.send()
        logger.info("[SubAgent] spawn id=\(id.prefix(8)) root=\(root.prefix(8)) depth=\(record.depth) fork=\(forkContext)")
        startPolling(id: id, root: root)
        return record
    }

    func sendInput(id: String, message: String, interrupt: Bool = false) -> ZeSubAgentRecord? {
        guard let location = locate(id: id), var record = record(id: id, rootSessionId: location.root) else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return record }
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        let child: AIChatViewModel
        if let existingChild = children[id] {
            child = existingChild
        } else {
            // After a process restart, persisted records keep their transcript
            // summary but not the live provider object. Rehydrate a lightweight
            // VM on the first follow-up instead of silently losing the agent.
            let rehydrated = AIChatViewModel()
            rehydrated.sessionSource = "subagent"
            // Persisted child records retain the root session ID, which is the
            // shared filesystem identity needed after app relaunch.
            rehydrated.workspaceSessionId = location.root
            children[id] = rehydrated
            childAgentIds[ObjectIdentifier(rehydrated)] = id
            child = rehydrated
        }
        if record.status.isActive {
            guard interrupt else { return record }
            child.cancel()
            record.status = .cancelling
            update(record, root: location.root)
        }
        record.status = .queued
        record.error = nil
        record.output = ""
        record.revision += 1
        record.updatedAt = Date()
        update(record, root: location.root)
        Task { @MainActor [weak self, weak child] in
            guard let self, let child else { return }
            if interrupt { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            child.inputText = text
            child.send()
            self.startPolling(id: id, root: location.root)
        }
        return record
    }

    func cancel(id: String) {
        guard let location = locate(id: id), var record = record(id: id, rootSessionId: location.root) else { return }
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        children[id]?.cancel()
        record.status = .cancelled
        record.error = nil
        record.revision += 1
        record.updatedAt = Date()
        update(record, root: location.root)
    }

    func close(id: String) {
        guard let location = locate(id: id), var record = record(id: id, rootSessionId: location.root) else { return }
        children[id]?.cancel()
        pollTasks[id]?.cancel()
        pollTasks[id] = nil
        children[id] = nil
        record.status = .closed
        record.revision += 1
        record.updatedAt = Date()
        update(record, root: location.root)
    }

    func resume(id: String) -> ZeSubAgentRecord? {
        guard let location = locate(id: id), var record = record(id: id, rootSessionId: location.root) else { return nil }
        guard record.status == .closed || record.status == .interrupted || record.status == .failed || record.status == .cancelled else { return record }
        record.status = .idle
        record.error = nil
        record.revision += 1
        record.updatedAt = Date()
        update(record, root: location.root)
        return record
    }

    func wait(ids: [String], timeout: TimeInterval = 30) async -> [ZeSubAgentRecord] {
        let wanted = Set(ids.filter { !$0.isEmpty })
        let deadline = Date().addingTimeInterval(min(max(timeout, 0), 300))
        while Date() < deadline {
            let current = wanted.compactMap { id -> ZeSubAgentRecord? in
                guard let loc = locate(id: id) else { return nil }
                return record(id: id, rootSessionId: loc.root)
            }
            if current.isEmpty || current.allSatisfy({ !$0.status.isActive }) { return current }
            try? await Task.sleep(nanoseconds: 250_000_000)
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

    // MARK: - Runtime

    private func startPolling(id: String, root: String) {
        pollTasks[id]?.cancel()
        pollTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            var observedRunning = false
            while !Task.isCancelled, let child = self.children[id] {
                if let current = self.record(id: id, rootSessionId: root) {
                    var next = current
                    if child.isProcessing {
                        observedRunning = true
                        next.status = .running
                    } else if observedRunning || current.status.isActive {
                        next.status = child.errorMessage == nil && child.messages.last(where: { $0.role == .assistant })?.error == nil ? .completed : .failed
                    }
                    next.output = self.output(from: child)
                    next.error = child.errorMessage ?? child.messages.last(where: { $0.role == .assistant })?.error
                    next.childSessionId = child.sessionId
                    let usage = child.sessionTokenStats
                    next.inputTokens = usage.input
                    next.outputTokens = usage.output
                    next.updatedAt = Date()
                    if next != current { self.update(next, root: root) }
                    if observedRunning && !child.isProcessing {
                        self.pollTasks[id] = nil
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private func output(from child: AIChatViewModel) -> String {
        let text = child.messages
            .filter { $0.role == .assistant }
            .flatMap { $0.blocks.filter { $0.kind == .text }.map(\.content) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 32_000 ? String(text.suffix(32_000)) : text
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
        return ZeSubAgentRecord(id: UUID().uuidString, parentId: root, rootSessionId: root, nickname: "子代理", depth: 0, status: .failed, revision: 1, createdAt: now, updatedAt: now, prompt: "", output: "", error: message, childSessionId: nil, inputTokens: 0, outputTokens: 0)
    }

    private func update(_ record: ZeSubAgentRecord, root: String) {
        recordsByRoot[root, default: [:]][record.id] = record
        persist(root)
        publish()
    }

    private func publish() { updateToken &+= 1 }

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
            records[index].error = String(localized: "应用重新启动后，未自动重跑此子代理。")
            records[index].revision += 1
            records[index].updatedAt = Date()
        }
        recordsByRoot[root] = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        if records.contains(where: { $0.status == .interrupted }) { persist(root) }
    }

    private func persist(_ root: String) {
        loadRootIfNeeded(root)
        let url = fileURL(for: root)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(recordsByRoot[root, default: [:]].values))
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("[SubAgent] persist failed: \(error.localizedDescription)")
        }
    }

    private func fileURL(for root: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
