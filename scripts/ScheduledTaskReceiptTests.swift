// Compile the real receipt with deterministic main-actor VM events on macOS.
// This fake models only its observable interface; it makes no provider requests.
import Foundation
import Combine

@MainActor
final class AIChatViewModel {
    struct Message {
        enum Role { case user, assistant }
        struct Block {
            enum Kind { case text }
            var kind: Kind = .text
            var content: String
        }
        var role: Role
        var blocks: [Block] = []
        var error: String?
    }
    @Published var isProcessing = false
    var messages: [Message] = []
    var userDidCancel = false
    var errorMessage: String?
    var cancelCount = 0
    var resumeQueuedAfterCancel = false

    func send() {
        userDidCancel = false
        messages.append(Message(role: .user))
        isProcessing = true
    }
    func answer(_ text: String) {
        messages.append(Message(role: .assistant, blocks: [.init(content: text)]))
    }
    func cancel() {
        cancelCount += 1
        userDidCancel = true
        isProcessing = false
        if resumeQueuedAfterCancel { send() }
    }
}

@main
struct ScheduledTaskReceiptTests {
    @MainActor static var count = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: \(name)") }
        count += 1
        print("PASS: \(name)")
    }

    @MainActor static func main() {
        let vm = AIChatViewModel()
        var restorations = 0
        let receipt = ScheduledTaskExecutionReceipt(vm: vm) { restorations += 1 }
        check(receipt.result == nil && !receipt.hasStarted, "receipt waits for its send")
        vm.send(); vm.answer("scheduled answer")
        receipt.finish() // real send invokes this before draining the user's queue
        check(receipt.result?.status == .succeeded && receipt.result?.summary == "scheduled answer", "turn boundary freezes scheduled result")
        vm.send(); vm.answer("later user answer")
        vm.errorMessage = "later user failure"
        receipt.cancel(); receipt.finish()
        check(vm.cancelCount == 0 && vm.isProcessing, "late cancellation never stops subsequent user turn")
        check(receipt.result?.summary == "scheduled answer" && receipt.result?.error == nil, "later turn cannot contaminate summary or error")
        check(restorations == 1, "model pin restored exactly once before later turn")

        let stoppedVM = AIChatViewModel()
        let stopped = ScheduledTaskExecutionReceipt(vm: stoppedVM) {}
        stoppedVM.send(); stoppedVM.answer("partial")
        stoppedVM.cancel() // chat page Stop, not scheduler cancelRun
        check(stopped.result?.status == .interrupted, "chat Stop is interrupted, never succeeded")
        stoppedVM.send()
        stopped.cancel()
        check(stoppedVM.cancelCount == 1 && stoppedVM.isProcessing, "scheduler does not recancel after chat Stop")

        let queuedVM = AIChatViewModel()
        queuedVM.resumeQueuedAfterCancel = true
        let queued = ScheduledTaskExecutionReceipt(vm: queuedVM) {}
        queuedVM.send(); queuedVM.answer("partial scheduled answer")
        queued.cancel(); queued.cancel()
        check(queuedVM.cancelCount == 1 && queuedVM.isProcessing, "cancel is idempotent even when queue resumes synchronously")
        check(queued.result?.status == .interrupted && queued.result?.summary == "partial scheduled answer", "cancel captures only original turn")

        let queuedBubbleVM = AIChatViewModel()
        let queuedBubble = ScheduledTaskExecutionReceipt(vm: queuedBubbleVM) {}
        queuedBubbleVM.send(); queuedBubbleVM.answer("first answer")
        queuedBubbleVM.messages.append(.init(role: .user))
        queuedBubbleVM.answer("unrelated answer")
        queuedBubble.finish()
        check(queuedBubble.result?.summary == "first answer", "already-visible queued user bubble bounds output")

        let failureVM = AIChatViewModel()
        let failure = ScheduledTaskExecutionReceipt(vm: failureVM) {}
        failureVM.send(); failureVM.errorMessage = "network down"
        failureVM.isProcessing = false
        check(failure.result?.status == .failed && failure.result?.error?.contains("network down") == true, "provider error preserves failure details")

        let noStartVM = AIChatViewModel()
        let noStart = ScheduledTaskExecutionReceipt(vm: noStartVM) {}
        noStart.finish()
        check(noStart.result?.status == .failed, "rejected send is not reported as successful")
        print("Scheduled receipt tests passed: \(count)")
    }
}
