// Compile this fixture with the shipping coordinator; no copied lifecycle logic.
// swiftc -parse-as-library Agent/Chat/ZeSubAgentCoordinator.swift scripts/SubAgentLifecycleHarness.swift -o /tmp/subagent-tests
import Foundation

struct AppLogger {
    init(category: String) {}
    func info(_ message: String) {}
    func error(_ message: String) { print(message) }
}
struct ModelEntry { var id = "model"; var model = "fixture" }
@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func entry(for id: String) -> ModelEntry? { nil }
}
enum Role { case user, assistant }
enum AgentContentPart {
    case text(String), toolUse(String, String, String)
    case toolResult(String, String, String, Bool, String?, String?, String?, String?)
    case imageData
}
struct AgentMessage {
    var role: Role
    var parts: [AgentContentPart]
    var dbMessageId: String?
    var reasoningEcho: String?
    var reasoningContent: String?
}
enum BlockKind: Equatable {
    case text, thinking, shellTool, fileReadTool, fileWriteTool, fileEditTool
    case browserTool, readImageTool, memoryTool, info
}
enum BlockStatus { case streaming, running, success, failed, cancelled }
final class TestBlock {
    let id = UUID()
    var kind: BlockKind = .shellTool
    var toolDescription = "fixture tool"
    var toolStatus: BlockStatus? = .running
    var content = "first"
    var toolDuration: TimeInterval? = nil
    var imageFilePath: String? = nil
}
final class ChatMessage {
    let id = UUID()
    var role: Role
    var blocks: [TestBlock]
    var error: String?
    init(role: Role, blocks: [TestBlock] = []) { self.role = role; self.blocks = blocks }
}
struct QueuedPrompt { let id = UUID(); let text: String }
@MainActor final class AIChatViewModel {
    var sessionSource = ""
    var workspaceSessionId: String?
    var fileSystemSessionId: String? { workspaceSessionId ?? sessionId }
    var preferredModelEntryReference: String?
    var selectedModel = "fixture"
    var initialGroupId: String?
    var memoryEnabled = false
    var autoCompactEnabled = true
    var agentHistory: [AgentMessage] = []
    var messages: [ChatMessage] = []
    var inputText = ""
    var sessionId: String?
    var draftId: String?
    var isProcessing = false
    var isSuspended = false
    var userDidCancel = false
    var canResume = false
    var errorMessage: String?
    var sessionInputTokens = 0
    var sessionOutputTokens = 0
    var sessionCacheReadTokens = 0
    var promptQueue: [QueuedPrompt] = []
    var currentTask: Task<Void, Never>?
    var sendCount = 0
    var loadedSession: String?
    var sentInputs: [String] = []
    func resolveCurrentEntry() -> ModelEntry? { nil }
    func send() {
        guard !isProcessing, !inputText.isEmpty else { return }
        sendCount += 1
        sentInputs.append(inputText)
        inputText = ""
        sessionId = sessionId ?? UUID().uuidString
        isProcessing = true
        userDidCancel = false
        canResume = false
        messages.append(ChatMessage(role: .assistant, blocks: [TestBlock()]))
    }
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        userDidCancel = true
        isProcessing = false
    }
    func enqueuePrompt() {
        guard isProcessing, !inputText.isEmpty else { return }
        promptQueue.append(QueuedPrompt(text: inputText))
        inputText = ""
    }
    func removeQueuedPrompt(id: UUID) { promptQueue.removeAll { $0.id == id } }
    func loadSession(activate: Bool) async {
        loadedSession = sessionId
        agentHistory = [AgentMessage(role: .user, parts: [.text("persisted task")]),
                        AgentMessage(role: .assistant, parts: [.text("persisted progress")])]
    }
}

@main struct SubAgentLifecycleHarness {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
            print("PASS \(message)")
        }
        func tick() async { try? await Task.sleep(nanoseconds: 450_000_000) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ze-subagent-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.set(true, forKey: ZeSubAgentPreferences.enabledKey)
        var made: [AIChatViewModel] = []
        let coordinator = ZeSubAgentCoordinator(storageDirectory: folder) {
            let child = AIChatViewModel()
            made.append(child)
            return child
        }
        let parent = AIChatViewModel()
        parent.sessionId = "root"
        parent.messages = [ChatMessage(role: .assistant)]
        let first = coordinator.spawn(from: parent, message: "task one")
        let child = made[0]
        await tick()
        let accepted = coordinator.sendInput(id: first.id, message: "course correction")
        check(accepted != nil && child.promptQueue.count == 1, "running correction is queued without cancellation")
        check(child.isProcessing && !child.userDidCancel, "running tool is not interrupted")
        child.messages[0].blocks[0].content = "progress after correction"
        await tick()
        check(coordinator.record(id: first.id)?.steps?.first?.content == "progress after correction", "polling survives a queued correction")

        // The old task deliberately ignores cancellation until released. A
        // subsequent Stop must invalidate the pending replacement immediately.
        var release: CheckedContinuation<Void, Never>?
        child.currentTask = Task { @MainActor in
            await withCheckedContinuation { release = $0 }
        }
        await Task.yield()
        _ = coordinator.sendInput(id: first.id, message: "replace", interrupt: true)
        await Task.yield()
        check(child.sendCount == 1, "replacement waits for real old task completion")
        coordinator.cancel(id: first.id)
        release?.resume()
        await tick()
        check(child.sendCount == 1 && coordinator.record(id: first.id)?.status == .cancelled,
              "Stop during cleanup prevents delayed replacement from reviving child")
        check(child.promptQueue.isEmpty, "Stop discards pending child corrections")

        let second = coordinator.spawn(from: parent, message: "same turn sibling")
        parent.messages.append(ChatMessage(role: .assistant))
        let unrelated = coordinator.spawn(from: parent, message: "different turn")
        let grandchild = coordinator.spawn(from: made[1], message: "nested work")
        await tick()
        check(ZeSubAgentCoordinator.belongsToRunGroup(second, selected: first), "same delegating turn groups siblings")
        check(!ZeSubAgentCoordinator.belongsToRunGroup(unrelated, selected: first), "another turn is isolated")
        coordinator.cancelRunGroup(id: second.id)
        check(coordinator.record(id: second.id)?.status == .cancelled, "group Stop cancels selected child")
        check(coordinator.record(id: grandchild.id)?.status == .cancelled, "group Stop cancels descendants")
        check(coordinator.record(id: unrelated.id)?.status.isActive == true, "group Stop leaves unrelated turn running")
        let nested = coordinator.spawn(from: made[2], message: "nested close")
        coordinator.close(id: unrelated.id)
        check(coordinator.record(id: unrelated.id)?.status == .closed && coordinator.record(id: nested.id)?.status == .cancelled,
              "closing a child stops its subtree")

        // Finished history must not consume the concurrent-agent budget.
        for index in 0..<7 {
            let entry = coordinator.spawn(from: parent, message: "sequential task \(index)")
            check(entry.error == nil, "completed history allows sequential spawn \(index + 1)")
            made.last?.isProcessing = false
            await tick()
        }
        var active: [String] = []
        for index in 0..<6 {
            let entry = coordinator.spawn(from: parent, message: "concurrent task \(index)")
            check(entry.error == nil, "concurrent slot \(index + 1) is available")
            active.append(entry.id)
        }
        let overflow = coordinator.spawn(from: parent, message: "seventh concurrent task")
        check(overflow.status == .failed && overflow.error != nil, "six active children enforce concurrency bound")
        for id in active { coordinator.cancel(id: id) }

        // Persistence writes occur on a serial background queue. Wait for its
        // terminal snapshot, then build a fresh coordinator as after relaunch.
        let persistedSession = coordinator.record(id: first.id)?.childSessionId
        await tick()
        var restoredChildren: [AIChatViewModel] = []
        let restored = ZeSubAgentCoordinator(storageDirectory: folder) {
            let vm = AIChatViewModel(); restoredChildren.append(vm); return vm
        }
        _ = restored.records(for: "root")
        let resumed = restored.resume(id: first.id)
        check(resumed?.status == .queued, "persisted cancelled task can resume")
        await tick()
        check(restoredChildren.first?.loadedSession == persistedSession && persistedSession != nil,
              "resume rehydrates original child session before sending")
        check(restoredChildren.first?.agentHistory.count == 2, "resume retains saved conversation history")
        check(restoredChildren.first?.sendCount == 1, "resume dispatches exactly one continuation")
        restored.cancel(id: first.id)

        check(ZeSubAgentCoordinator.runtimeStatus(processing: false, suspended: false, cancelled: true,
                                                  resumable: true, error: "cancelled request") == .cancelled,
              "explicit cancellation takes precedence over request errors")
        check(ZeSubAgentCoordinator.runtimeStatus(processing: false, suspended: false, cancelled: false,
                                                  resumable: true, error: nil) == .interrupted,
              "resumable interruption is not misreported as success")
        check(ZeSubAgentCoordinator.runtimeStatus(processing: true, suspended: true, cancelled: false,
                                                  resumable: false, error: nil) == .queued,
              "concurrency wait is shown as queued")
        var legacy = first
        legacy.parentTurnId = nil
        check(!ZeSubAgentCoordinator.belongsToRunGroup(second, selected: legacy), "legacy records never guess sibling ownership")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        for key in ["pendingInputCount", "cacheReadTokens", "turnCount", "parentTurnId"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(ZeSubAgentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        check(old.pendingInputCount == nil && old.parentTurnId == nil, "legacy saved records decode without new metrics")
        await tick()
        print("PASS \(checks) child-agent lifecycle checks")
    }
}
