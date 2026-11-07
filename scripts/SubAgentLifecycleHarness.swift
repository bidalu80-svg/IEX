// Compile this fixture with the shipping coordinator; no copied lifecycle logic.
// swiftc -parse-as-library Agent/Chat/ZeSubAgentCoordinator.swift scripts/SubAgentLifecycleHarness.swift -o /tmp/subagent-tests
import Foundation

struct AppLogger {
    init(category: String) {}
    func info(_ message: String) {}
    func error(_ message: String) { print(message) }
}
struct FixtureModel { var id = "fixture"; var displayName = "Fixture Model" }
struct ModelEntry { var id = "model"; var model = FixtureModel() }
@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func entry(for id: String) -> ModelEntry? { nil }
}
@MainActor final class ViewModelCache {
    static let shared = ViewModelCache()
    func get(for sessionId: String) -> AIChatViewModel? { nil }
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
    case browserTool, readImageTool, memoryTool(String), info
}
enum BlockStatus { case streaming, running, success, failed, cancelled }
final class TestBlock {
    let id = UUID()
    var kind: BlockKind = .shellTool
    var toolDescription = "fixture tool"
    var toolSummary: String?
    var toolUseId: String?
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
    var selectedModel = FixtureModel()
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
    var zeSubAgentWrapUpRequested = false
    var stoppedTools = 0
    var receivedResults: [String] = []
    var sendCount = 0
    func discardQueuedSubAgentResults() {}
    func discardQueuedSubAgentProgress(key: String) {}
    func discardQueuedSubAgentResult(key: String) {}
    func stopCurrentCommand() { stoppedTools += 1 }
    func submitSubAgentResult(_ text: String, progressKey: String? = nil, resultKey: String? = nil) -> Bool {
        guard !userDidCancel, !canResume else { return false }
        receivedResults.append(text)
        return true
    }
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
        func waitFor(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ze-subagent-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.set(true, forKey: ZeSubAgentPreferences.enabledKey)
        var made: [AIChatViewModel] = []
        var testNow = Date()
        let coordinator = ZeSubAgentCoordinator(storageDirectory: folder, now: { testNow }) {
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
        let waitingChild = made.last!
        check(overflow.status == .queued && overflow.error == nil && waitingChild.sendCount == 0,
              "seventh concurrent task queues without starting")
        check(overflow.startedAt == nil, "queued task budget has not started")
        coordinator.cancel(id: active.removeFirst())
        await tick()
        check(waitingChild.sendCount == 1, "queued child starts automatically when a slot frees")
        check(coordinator.record(id: overflow.id)?.startedAt != nil, "budget starts only at dispatch")
        for id in active { coordinator.cancel(id: id) }
        coordinator.cancel(id: overflow.id)

        let budgeted = coordinator.spawn(from: parent, message: "bounded work", budgetMinutes: 1)
        let budgetChild = made.last!
        testNow = testNow.addingTimeInterval(61)
        await waitFor { budgetChild.zeSubAgentWrapUpRequested }
        check(budgetChild.zeSubAgentWrapUpRequested && budgetChild.isProcessing, "budget requests final answer before cancellation")
        testNow = testNow.addingTimeInterval(21)
        await waitFor { budgetChild.stoppedTools == 1 }
        check(budgetChild.stoppedTools == 1, "budget stops a lingering tool after twenty seconds")
        testNow = testNow.addingTimeInterval(70)
        await waitFor { coordinator.record(id: budgeted.id)?.status == .timedOut && !budgetChild.isProcessing }
        check(coordinator.record(id: budgeted.id)?.status == .timedOut && !budgetChild.isProcessing,
              "budget hard stop remains timeout rather than user cancellation")
        await waitFor { coordinator.record(id: budgeted.id)?.deliveryState == "delivered" }
        check(coordinator.record(id: budgeted.id)?.deliveryState == "delivered", "terminal timeout reaches parent exactly once")
        let deliveredCount = parent.receivedResults.count
        await tick()
        check(parent.receivedResults.count == deliveredCount, "completion delivery is not duplicated on subsequent polls")

        let awaited = coordinator.spawn(from: parent, message: "wait for final result")
        let awaitedChild = made.last!
        let waiter = Task { @MainActor in await coordinator.wait(ids: [awaited.id], timeout: 2) }
        await Task.yield()
        let finalText = String(repeating: "final answer ", count: 4000)
        awaitedChild.agentHistory = [AgentMessage(role: .assistant, parts: [.text(finalText)])]
        awaitedChild.isProcessing = false
        let waited = await waiter.value
        check(waited.first?.deliveryState == "pending" || waited.first?.deliveryState == "inline", "wait receives terminal result")
        check(coordinator.record(id: awaited.id)?.deliveryState == "inline", "explicit wait consumes completion inline")
        check(coordinator.record(id: awaited.id)?.output == finalText.trimmingCharacters(in: .whitespacesAndNewlines), "final answer is preserved beyond preview limit")
        check(parent.receivedResults.count == deliveredCount, "inline wait does not duplicate parent callback")

        let cancellable = coordinator.spawn(from: parent, message: "cancel only wait")
        let cancelledWait = Task { @MainActor in await coordinator.wait(ids: [cancellable.id], timeout: 300) }
        await Task.yield()
        cancelledWait.cancel()
        _ = await cancelledWait.value
        check(coordinator.record(id: cancellable.id)?.status.isActive == true, "cancelling wait leaves child running and exits promptly")
        coordinator.cancel(id: cancellable.id)

        check(!ZeSubAgentCoordinator.hasFinalAnswer([AgentMessage(role: .assistant, parts: [.text("working"), .toolUse("t", "shell_execute", "{}")])]),
              "tool narration is not a final answer")
        check(!ZeSubAgentCoordinator.hasFinalAnswer([AgentMessage(role: .user, parts: [.text("tool result")])]),
              "tool result alone is not a final answer")

        let modelRun = coordinator.spawn(from: parent, message: "track fallback model")
        coordinator.recordRequest(from: made.last!, modelId: "fallback-id", modelName: "Fallback Model", provider: "Fixture Provider")
        check(coordinator.record(id: modelRun.id)?.requestModelId == "fallback-id", "real request route identity is recorded")
        coordinator.parentDidCancel(parent)
        check(coordinator.record(id: modelRun.id)?.status == .cancelled, "parent Stop cancels owned live children")
        made.last?.isProcessing = false
        await tick()
        check(parent.receivedResults.count == deliveredCount, "cancelled parent is never revived by child result")

        let progressParent = AIChatViewModel()
        progressParent.sessionId = "progress-root"
        let frequent = coordinator.spawn(from: progressParent, message: "frequent updates", progressReport: "frequent")
        let frequentChild = made.last!
        testNow = testNow.addingTimeInterval(14)
        await tick()
        check(progressParent.receivedResults.isEmpty, "frequent progress does not report before fifteen seconds")
        testNow = testNow.addingTimeInterval(1)
        await tick()
        check(progressParent.receivedResults.count == 1, "frequent progress reports first activity after fifteen seconds")
        testNow = testNow.addingTimeInterval(15)
        await tick()
        check(progressParent.receivedResults.count == 1, "unchanged frequent progress is suppressed")
        frequentChild.agentHistory.append(AgentMessage(role: .assistant, parts: [.text("new turn")]))
        testNow = testNow.addingTimeInterval(15)
        await tick()
        check(progressParent.receivedResults.count == 2, "changed turn produces next frequent report")
        coordinator.cancel(id: frequent.id)
        let moderate = coordinator.spawn(from: progressParent, message: "moderate updates", progressReport: "moderate")
        testNow = testNow.addingTimeInterval(59)
        await tick()
        check(progressParent.receivedResults.count == 2, "moderate progress waits sixty seconds")
        testNow = testNow.addingTimeInterval(1)
        await tick()
        check(progressParent.receivedResults.count == 3, "moderate progress reports at sixty seconds")
        testNow = testNow.addingTimeInterval(60)
        await tick()
        check(progressParent.receivedResults.count == 4, "moderate progress repeats unchanged state at next interval")
        coordinator.parentDidCancel(progressParent)
        testNow = testNow.addingTimeInterval(60)
        await tick()
        check(progressParent.receivedResults.count == 4 && coordinator.record(id: moderate.id)?.status == .cancelled,
              "parent Stop suppresses future progress")
        check(first.progressReport == "none", "progress defaults to none")

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
        check(restoredChildren.first?.sentInputs.first?.contains("shell") == true, "resume explains lost browser and process state")
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
        for key in ["pendingInputCount", "cacheReadTokens", "turnCount", "parentTurnId", "startedAt", "finishedAt", "budgetMinutes", "requestedModel", "requestModelId", "requestModelName", "requestProviderName", "deliveryState", "wrapUpStartedAt"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(ZeSubAgentRecord.self, from: JSONSerialization.data(withJSONObject: json))
        check(old.pendingInputCount == nil && old.parentTurnId == nil, "legacy saved records decode without new metrics")
        await tick()
        print("PASS \(checks) child-agent lifecycle checks")
    }
}
