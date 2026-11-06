import Foundation

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
    print("PASS: \(message)")
}
private final class PidBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0
    func put(_ pid: Int32) { lock.lock(); value = pid; lock.unlock() }
    func get() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
}
@main struct KernelRuntimeHarness {
    static func main() async throws {
        let router = ZeFsRouter.shared
        let parent = router.context(for: "workspace")
        let a = router.context(for: "workspace", ownerId: "child-a")
        let b = router.context(for: "workspace", ownerId: "child-b")
        expect(parent != a && a != b, "shared workspace gets separate owner tokens")
        expect(a == router.context(for: "workspace", ownerId: "child-a"), "owner token is stable")
        expect(router.sid(for: a) == "workspace" && router.sid(for: b) == "workspace", "child file routing retains shared workspace")
        expect(ISHExecutionCoordinator.callerSessionId(fsContext: a).sid == "child-a", "native caller resolves child owner")
        expect(ISHExecutionCoordinator.callerSessionId(fsContext: UInt64.max).sid == nil, "unknown token never selects another chat")
        expect(router.hostURL(forGuest: "/var/ze/workspace-copy/a", sid: "workspace") == nil, "filesystem prefix boundary enforced")

        let coordinator = ISHExecutionCoordinator.shared
        let gate = DispatchSemaphore(value: 0)
        ISHExecutionCoordinator.killQueue.async { gate.wait() }
        let started = Date()
        let timeout = try await coordinator.execute(sessionId: "timeout", command: "LONG_OUTPUT", timeout: 0.05, lineCallback: { _ in }, pidCallback: { _ in })
        expect(Date().timeIntervalSince(started) < 2, "timeout resumes while kill queue is blocked")
        expect(timeout.exitCode == -1 && timeout.output.contains("TAIL"), "timeout returns latest partial output")
        expect(timeout.output.count < 257_000 && timeout.output.contains("Earlier output"), "single oversized line is bounded and marked truncated")
        gate.signal()

        let boxA = PidBox(), boxB = PidBox()
        let taskA = Task { try await coordinator.execute(sessionId: "workspace", command: "WAIT", timeout: 20, ownerId: "child-a", lineCallback: { _ in }, pidCallback: { boxA.put($0) }) }
        let taskB = Task { try await coordinator.execute(sessionId: "workspace", command: "WAIT", timeout: 20, ownerId: "child-b", lineCallback: { _ in }, pidCallback: { boxB.put($0) }) }
        for _ in 0..<200 {
            if ISHExecutionCoordinator.hasStoppableCommand(sessionId: "workspace", ownerId: "child-a") && ISHExecutionCoordinator.hasStoppableCommand(sessionId: "workspace", ownerId: "child-b") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pidB = boxB.get()
        let stopStarted = Date()
        expect(ISHExecutionCoordinator.stopAllNonisolated(sessionId: "workspace", ownerId: "child-a") == 1, "child Stop selects only its own command")
        expect(Date().timeIntervalSince(stopStarted) < 0.5, "Stop returns immediately")
        let stopped = try await taskA.value
        expect(stopped.output.contains("Stopped by user") && stopped.output.contains("output-before-wait"), "unresponsive Stop resolves after grace with partial output")
        expect(ISHExecutionCoordinator.hasStoppableCommand(sessionId: "workspace", ownerId: "child-b"), "sibling command survives Stop")
        ISHShellExecutor.finish(pidB)
        let resultB = try await taskB.value
        expect(resultB.exitCode == 0, "sibling completes normally")

        let sync = try await coordinator.execute(sessionId: "sync", command: "SYNC_DONE", timeout: 1, lineCallback: { _ in }, pidCallback: { _ in })
        expect(sync.exitCode == 0 && !ISHExecutionCoordinator.hasStoppableCommand(sessionId: "sync", ownerId: nil), "synchronous completion leaves no abandon handler")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.execute(sessionId: "cancelled", command: "WAIT", timeout: 1, lineCallback: { _ in }, pidCallback: { _ in })
        }
        do { _ = try await cancelled.value; fatalError("cancellation must throw") }
        catch is CancellationError { print("PASS: pre-cancelled command throws") }
        let inflight = await coordinator.debugInflightCount()
        expect(inflight == 0, "cancellation and completion remove all inflight entries")
        print("Kernel coordinator/router behavioral regressions passed; native guest runtime not exercised.")
    }
}
