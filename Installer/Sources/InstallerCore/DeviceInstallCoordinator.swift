import Foundation

public struct InstallTarget: Hashable, Codable {
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public init(bundleIdentifier: String, version: String, build: String) {
        self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build
    }
    var valid: Bool { !bundleIdentifier.isEmpty && !version.isEmpty && !build.isEmpty }
}

public enum InstallState: String, Codable {
    case idle, uploading, uploaded, installing, pendingConfirmation, installed, launching, launched, failed, cancelled
}
public enum InstallIssue: String, Codable, Error {
    case invalidTarget, duplicateSubmission, busy, uploadRejected, installRejected, launchRejected
    case disconnected, timedOut, insufficientEvidence, cancelledAfterSubmission, invalidResponse
}
public enum InstallCommand: Equatable {
    case upload(InstallTarget), install(InstallTarget), queryInstallation(InstallTarget)
    case launch(InstallTarget), queryLaunch(InstallTarget)
}
public enum InstallResponse: Equatable {
    case uploaded, installAccepted, installRejected, launchAccepted, launchRejected
    // These responses represent independent device queries, not upload or request acknowledgements.
    case installation(InstallTarget?), running(InstallTarget, processIdentifier: Int)
    case disconnected, timedOut, uploadRejected
}

@MainActor public protocol DeviceInstallTransport: AnyObject {
    func send(_ command: InstallCommand, token: UUID, completion: @escaping @MainActor (InstallResponse) -> Void)
    func cancel(token: UUID)
}

public struct InstallSnapshot: Codable {
    public let transactionID: UUID
    public let target: InstallTarget
    public let state: InstallState
    public let installMayHaveBeenSubmitted: Bool
}

public struct InstallTransition: Codable {
    public let from: InstallState
    public let to: InstallState
    public let reason: InstallIssue?
    public let elapsed: TimeInterval
}

/// Offline transaction skeleton. Integrators must keep callbacks on the main actor and
/// persist snapshots before crossing a real install request boundary. No credentials or network.
@MainActor public final class DeviceInstallCoordinator {
    public private(set) var state: InstallState = .idle
    public private(set) var issue: InstallIssue?
    public private(set) var transitions: [InstallTransition] = []
    public private(set) var target: InstallTarget?
    public private(set) var transactionID = UUID()
    public private(set) var installMayHaveBeenSubmitted = false
    public private(set) var installationConfirmed = false
    public private(set) var launchConfirmed = false
    private let transport: DeviceInstallTransport
    private let clock: () -> TimeInterval
    private let timeout: TimeInterval
    private var token: UUID?
    private var deadline: TimeInterval?

    public init(transport: DeviceInstallTransport, timeout: TimeInterval = 30,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport; self.timeout = timeout; self.clock = clock
    }

    public var snapshot: InstallSnapshot? {
        guard let target else { return nil }
        return InstallSnapshot(transactionID: transactionID, target: target, state: state,
                               installMayHaveBeenSubmitted: installMayHaveBeenSubmitted)
    }

    @discardableResult public func start(_ target: InstallTarget) throws -> UUID {
        guard target.valid else { throw InstallIssue.invalidTarget }
        guard self.target != target else { throw InstallIssue.duplicateSubmission }
        guard self.target == nil else { throw InstallIssue.busy }
        self.target = target
        move(.uploading)
        perform(.upload(target))
        return transactionID
    }

    public func requestInstall() {
        guard state == .uploaded, let target else { return }
        // An interrupted request may already have reached the device. Never automatically resubmit.
        installMayHaveBeenSubmitted = true
        move(.installing)
        perform(.install(target))
    }

    public func requestLaunch() {
        guard state == .installed, installationConfirmed, let target else { return }
        move(.launching)
        perform(.launch(target))
    }

    public func confirmInstallation() {
        guard state == .pendingConfirmation || state == .installed, let target else { return }
        invalidate()
        move(.pendingConfirmation)
        perform(.queryInstallation(target))
    }

    /// Restores by querying even when the old process thought it had succeeded. Existing
    /// matching applications prove presence/version, not that this transaction installed them.
    public func restore(_ snapshot: InstallSnapshot) throws {
        guard target == nil else { throw InstallIssue.busy }
        guard snapshot.target.valid else { throw InstallIssue.invalidTarget }
        transactionID = snapshot.transactionID
        target = snapshot.target
        installMayHaveBeenSubmitted = snapshot.installMayHaveBeenSubmitted
        move(.pendingConfirmation)
        perform(.queryInstallation(snapshot.target))
    }

    public func cancel() {
        guard state != .idle && state != .launched && state != .failed && state != .cancelled else { return }
        invalidate() // Clears identity first; even a synchronous cancellation callback is stale.
        if installMayHaveBeenSubmitted {
            move(.pendingConfirmation, .cancelledAfterSubmission)
        } else {
            move(.cancelled)
        }
    }

    /// A caller-driven clock avoids hidden retries and allows deterministic lifecycle tests.
    public func checkTimeout() {
        guard let deadline, clock() >= deadline, token != nil else { return }
        invalidate()
        uncertain(.timedOut)
    }

    private func perform(_ command: InstallCommand) {
        let next = UUID()
        token = next
        deadline = clock() + max(0, timeout)
        transport.send(command, token: next) { [weak self] response in
            guard let self, self.token == next else { return }
            self.token = nil
            self.deadline = nil
            self.receive(response, for: command)
        }
    }

    private func invalidate() {
        let previous = token
        token = nil
        deadline = nil
        if let previous { transport.cancel(token: previous) }
    }

    private func uncertain(_ issue: InstallIssue) {
        move(installMayHaveBeenSubmitted || installationConfirmed || state == .pendingConfirmation
             ? .pendingConfirmation : .failed, issue)
    }

    private func receive(_ response: InstallResponse, for command: InstallCommand) {
        if response == .disconnected { uncertain(.disconnected); return }
        if response == .timedOut { uncertain(.timedOut); return }
        switch (command, response) {
        case (.upload, .uploaded): move(.uploaded)
        case (.upload, .uploadRejected): move(.failed, .uploadRejected)
        case (.install, .installRejected): move(.failed, .installRejected)
        case (.install(let expected), .installAccepted):
            move(.pendingConfirmation)
            perform(.queryInstallation(expected))
        case (.queryInstallation(let expected), .installation(let found)):
            guard found == expected else { move(.pendingConfirmation, .insufficientEvidence); return }
            installationConfirmed = true
            move(.installed)
        case (.launch(let expected), .launchAccepted):
            // An accepted launch command alone never proves a process actually started.
            perform(.queryLaunch(expected))
        case (.launch, .launchRejected): move(.installed, .launchRejected)
        case (.queryLaunch(let expected), .running(let observed, let pid)):
            guard expected == observed, pid > 0, installationConfirmed else {
                move(.pendingConfirmation, .insufficientEvidence); return
            }
            launchConfirmed = true
            move(.launched)
        default: uncertain(.invalidResponse)
        }
    }

    private func move(_ next: InstallState, _ reason: InstallIssue? = nil) {
        transitions.append(InstallTransition(from: state, to: next, reason: reason, elapsed: clock()))
        state = next; issue = reason
    }
}

/// Programmable fixture transport; it deliberately permits duplicate and late callbacks
/// so the production coordinator must defend against them. No sockets or device services.
@MainActor public final class MockTransport: DeviceInstallTransport {
    public struct Request {
        public let command: InstallCommand
        public let token: UUID
        fileprivate let completion: @MainActor (InstallResponse) -> Void
    }
    public private(set) var requests: [Request] = []
    public private(set) var cancelledTokens: [UUID] = []
    public init() {}
    public func send(_ command: InstallCommand, token: UUID, completion: @escaping @MainActor (InstallResponse) -> Void) {
        requests.append(Request(command: command, token: token, completion: completion))
    }
    public func cancel(token: UUID) { cancelledTokens.append(token) }
    /// Returns false for an absent request; test drivers must assert and stop that path.
    @discardableResult public func reply(_ response: InstallResponse, to index: Int) -> Bool {
        guard requests.indices.contains(index) else { return false }
        requests[index].completion(response)
        return true
    }
}
