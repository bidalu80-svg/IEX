// The submit/discard/remove helpers are extracted unchanged from production.
import Foundation

struct InputAttachment: Equatable { let id: String }
struct QueuedPrompt {
    let id = UUID()
    let text: String
    let attachments: [InputAttachment]
}
final class ChatMessage {
    enum Role { case user }
    var queuedPromptId: UUID?
    let content: String
    init(role: Role, content: String, isQueued: Bool) { self.content = content }
}
struct Signal { func send() {} }
enum ContextState { case ok, needsCompact, exhausted }

@MainActor final class AIChatViewModel {
    var remoteDeviceId: String?
    var userDidCancel = false
    var canResume = false
    var zeSubAgentWrapUpRequested = false
    var isProcessing = false
    var isCompacting = false
    var editingMessageIndex: Int?
    var showCompactBeforeSendPrompt = false
    var showContextExhaustedPrompt = false
    var zeSubAgentResultPromptIds: Set<UUID> = []
    var zeSubAgentProgressPromptIds: [String: UUID] = [:]
    var zeSubAgentCompletionPromptIds: [String: UUID] = [:]
    var promptQueue: [QueuedPrompt] = []
    var messages: [ChatMessage] = []
    var scrollToBottomSignal = Signal()
    var inputText = "user draft"
    var attachments = [InputAttachment(id: "user-image")]
    var context = ContextState.ok
    var sent: [(String, [InputAttachment])] = []
    func checkContextBeforeSend() -> ContextState { context }
    func send() {
        sent.append((inputText, attachments))
        inputText = ""
        attachments = []
        isProcessing = true
    }
}

@main struct SubAgentDeliveryHarness {
    @MainActor static func main() {
        var count = 0
        func check(_ passed: @autoclosure () -> Bool, _ message: String) {
            precondition(passed(), message)
            count += 1
            print("PASS \(message)")
        }
        let idle = AIChatViewModel()
        check(idle.submitSubAgentResult("final result"), "idle parent accepts completion")
        check(idle.sent.count == 1 && idle.sent[0].0 == "final result" && idle.sent[0].1.isEmpty,
              "callback sends only its own text with no user attachments")
        check(idle.inputText == "user draft" && idle.attachments == [InputAttachment(id: "user-image")],
              "idle callback restores composer and attachments after send")

        let busy = AIChatViewModel()
        busy.isProcessing = true
        let user = QueuedPrompt(text: "user queued correction", attachments: [InputAttachment(id: "queued-image")])
        busy.promptQueue.append(user)
        let userRow = ChatMessage(role: .user, content: user.text, isQueued: true)
        userRow.queuedPromptId = user.id
        busy.messages.append(userRow)
        check(busy.submitSubAgentResult("background final"), "busy parent queues completion")
        check(busy.sent.isEmpty && busy.promptQueue.count == 2, "busy callback does not dispatch over current task")
        check(busy.inputText == "user draft" && busy.attachments.count == 1,
              "busy callback preserves unsent composer")
        check(busy.submitSubAgentResult("progress 1", progressKey: "child"), "progress queues through real helper")
        check(busy.submitSubAgentResult("progress 2", progressKey: "child"), "new progress replaces pending report")
        check(busy.promptQueue.count == 3 && busy.promptQueue.last?.text == "progress 2",
              "one child never accumulates pending progress")
        check(!busy.messages.contains { $0.content == "progress 1" }, "replaced progress removes old chat row")
        busy.discardQueuedSubAgentResults()
        check(busy.promptQueue.count == 1 && busy.promptQueue[0].id == user.id
              && busy.promptQueue[0].attachments == user.attachments,
              "Stop discards child callbacks while preserving user queued text and attachments")
        check(busy.messages.count == 1 && busy.messages[0].queuedPromptId == user.id,
              "Stop removes only callback rows")
        check(busy.zeSubAgentResultPromptIds.isEmpty && busy.zeSubAgentProgressPromptIds.isEmpty,
              "Stop clears callback tracking")

        let progress = AIChatViewModel()
        progress.isProcessing = true
        _ = progress.submitSubAgentResult("working", progressKey: "child")
        check(!progress.hasQueuedNonProgressPrompt, "progress alone does not interrupt parent tool chain")
        _ = progress.submitSubAgentResult("done")
        check(progress.hasQueuedNonProgressPrompt, "completion remains eligible at tool boundary")
        progress.discardQueuedSubAgentProgress(key: "child")
        check(progress.promptQueue.count == 1 && progress.promptQueue[0].text == "done",
              "completion can remove stale progress while keeping final result")

        let siblings = AIChatViewModel()
        siblings.isProcessing = true
        _ = siblings.submitSubAgentResult("child A final", resultKey: "A")
        _ = siblings.submitSubAgentResult("child B final", resultKey: "B")
        siblings.discardQueuedSubAgentResult(key: "A")
        check(siblings.promptQueue.count == 1 && siblings.promptQueue[0].text == "child B final",
              "card Stop removes queued completion for its child while preserving unrelated sibling")

        for context in [ContextState.needsCompact, .exhausted] {
            let blocked = AIChatViewModel()
            blocked.context = context
            check(!blocked.submitSubAgentResult("deferred result") && blocked.sent.isEmpty,
                  "context management blocks background send without launching a modal")
            check(blocked.inputText == "user draft" && blocked.attachments.count == 1,
                  "context rejection preserves composer")
        }
        let stopped = AIChatViewModel()
        stopped.userDidCancel = true
        check(!stopped.submitSubAgentResult("late result") && stopped.promptQueue.isEmpty,
              "explicitly stopped parent rejects late completion")
        let compacting = AIChatViewModel()
        compacting.isCompacting = true
        check(!compacting.submitSubAgentResult("late result") && compacting.sent.isEmpty,
              "compacting parent rejects reentrant sends")
        print("PASS \(count) production parent-callback checks")
    }
}
