import XCTest
@testable import InstallerCore

final class DeviceInstallCoordinatorTests: XCTestCase {
    @MainActor private func scenario(_ name: String, _ body: (MockTransport, DeviceInstallCoordinator, InstallTarget) throws -> Void) rethrows {
        let mock = MockTransport()
        var now: TimeInterval = 0
        let coordinator = DeviceInstallCoordinator(transport: mock, timeout: 10, clock: { now })
        let target = InstallTarget(bundleIdentifier: "org.ze.test", version: "1.2", build: "42")
        defer {
            if let path = ProcessInfo.processInfo.environment["IPA_EVIDENCE"] {
                let url = URL(fileURLWithPath: path).appendingPathComponent("transaction/\(name).json")
                try? JSONEncoder().encode(coordinator.transitions).write(to: url)
            }
        }
        now = 1
        try body(mock, coordinator, target)
    }
    @MainActor private func reply(_ response: InstallResponse, to index: Int, on mock: MockTransport,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        // XCTest's own interruption stops the scenario after reporting the assertion,
        // without adding an unrelated unexpected-error failure.
        _ = try XCTUnwrap(mock.reply(response, to: index) ? index : nil,
                          "Missing mock request at index \(index); stopping this scenario", file: file, line: line)
    }
    @MainActor private func upload(_ mock: MockTransport, _ c: DeviceInstallCoordinator, _ target: InstallTarget) throws {
        try c.start(target)
        XCTAssertEqual(c.state, .uploading)
        try reply(.uploaded, to: 0, on: mock)
        XCTAssertEqual(c.state, .uploaded)
        XCTAssertFalse(c.installationConfirmed)
        XCTAssertFalse(c.launchConfirmed)
    }
    func testCompleteFlow() async throws {
        try await MainActor.run {
            try scenario("complete") { mock, c, target in
                try upload(mock, c, target)
                c.requestInstall()
                XCTAssertEqual(c.state, .installing)
                try reply(.installAccepted, to: 1, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation)
                let query = try XCTUnwrap(mock.requests.dropFirst(2).first, "Missing installation query request")
                XCTAssertEqual(query.command, .queryInstallation(target))
                try reply(.installation(target), to: 2, on: mock)
                XCTAssertEqual(c.state, .installed)
                XCTAssertTrue(c.installationConfirmed)
                XCTAssertFalse(c.launchConfirmed)
                c.requestLaunch()
                try reply(.launchAccepted, to: 3, on: mock)
                XCTAssertEqual(c.state, .launching)
                XCTAssertFalse(c.launchConfirmed)
                try reply(.running(target, processIdentifier: 123), to: 4, on: mock)
                XCTAssertEqual(c.state, .launched)
                XCTAssertTrue(c.launchConfirmed)
            }
        }
    }
    func testInstallRejectedAfterUpload() async throws {
        try await MainActor.run {
            try scenario("install-rejected") { mock, c, target in
                try upload(mock, c, target); c.requestInstall()
                try reply(.installRejected, to: 1, on: mock)
                XCTAssertEqual(c.state, .failed); XCTAssertEqual(c.issue, .installRejected)
                XCTAssertFalse(c.installationConfirmed)
            }
        }
    }
    func testDisconnectAfterRequestAndRecover() async throws {
        try await MainActor.run {
            try scenario("disconnect-recover") { mock, c, target in
                try upload(mock, c, target); c.requestInstall()
                try reply(.disconnected, to: 1, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation)
                XCTAssertEqual(c.issue, .disconnected)
                c.confirmInstallation()
                try reply(.installation(target), to: 2, on: mock)
                XCTAssertEqual(c.state, .installed)
                XCTAssertEqual(mock.requests.filter { $0.command == .install(target) }.count, 1)
            }
        }
    }
    func testCancelBeforeSubmitIgnoresLateCallback() async throws {
        try await MainActor.run {
            try scenario("cancel-upload") { mock, c, target in
                try c.start(target); c.cancel()
                try reply(.uploaded, to: 0, on: mock)
                XCTAssertEqual(c.state, .cancelled)
                XCTAssertEqual(mock.cancelledTokens.count, 1)
                c.requestInstall(); XCTAssertEqual(mock.requests.count, 1)
            }
        }
    }
    func testCancelAfterSubmitIgnoresLateCallback() async throws {
        try await MainActor.run {
            try scenario("cancel-submitted") { mock, c, target in
                try upload(mock, c, target); c.requestInstall(); c.cancel()
                try reply(.installAccepted, to: 1, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation)
                XCTAssertEqual(c.issue, .cancelledAfterSubmission)
                XCTAssertEqual(mock.requests.count, 2)
                XCTAssertFalse(c.installationConfirmed)
            }
        }
    }
    func testDuplicateSubmissionAndCallbacks() async throws {
        try await MainActor.run {
            try scenario("duplicate") { mock, c, target in
                try upload(mock, c, target)
                XCTAssertThrowsError(try c.start(target)) { XCTAssertEqual($0 as? InstallIssue, .duplicateSubmission) }
                c.requestInstall(); c.requestInstall()
                XCTAssertEqual(mock.requests.count, 2)
                try reply(.installAccepted, to: 1, on: mock); try reply(.installAccepted, to: 1, on: mock)
                try reply(.uploaded, to: 0, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation)
                XCTAssertEqual(mock.requests.count, 3)
            }
        }
    }
    func testRestoreWhenTargetAlreadyExists() async throws {
        try await MainActor.run {
            try scenario("restore-existing") { mock, c, target in
                let original = DeviceInstallCoordinator(transport: MockTransport())
                try original.start(target)
                let data = try JSONEncoder().encode(original.snapshot!)
                try c.restore(JSONDecoder().decode(InstallSnapshot.self, from: data))
                XCTAssertEqual(mock.requests.map(\.command), [.queryInstallation(target)])
                try reply(.installation(target), to: 0, on: mock)
                XCTAssertEqual(c.state, .installed)
                XCTAssertFalse(c.launchConfirmed)
                XCTAssertEqual(c.transactionID, original.transactionID)
                c.requestInstall()
                XCTAssertEqual(mock.requests.count, 1)
            }
        }
    }
    func testWrongIdentifierVersionAndBuildStayPending() async throws {
        try await MainActor.run {
            try scenario("wrong-query-evidence") { mock, c, target in
                try upload(mock, c, target); c.requestInstall(); try reply(.installAccepted, to: 1, on: mock)
                let mismatches: [InstallTarget?] = [nil,
                    InstallTarget(bundleIdentifier: "org.ze.other", version: "1.2", build: "42"),
                    InstallTarget(bundleIdentifier: target.bundleIdentifier, version: "1.1", build: "42"),
                    InstallTarget(bundleIdentifier: target.bundleIdentifier, version: "1.2", build: "41")]
                for (index, found) in mismatches.enumerated() {
                    if index > 0 { c.confirmInstallation() }
                    try reply(.installation(found), to: index + 2, on: mock)
                    XCTAssertEqual(c.state, .pendingConfirmation)
                    XCTAssertEqual(c.issue, .insufficientEvidence)
                    XCTAssertFalse(c.installationConfirmed)
                }
            }
        }
    }
    func testQueryTimeoutIsUnknown() async throws {
        try await MainActor.run {
            try scenario("query-timeout") { mock, c, target in
                try upload(mock, c, target); c.requestInstall(); try reply(.installAccepted, to: 1, on: mock)
                try reply(.timedOut, to: 2, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation); XCTAssertEqual(c.issue, .timedOut)
            }
        }
    }
    func testInstalledDoesNotMeanLaunched() async throws {
        try await MainActor.run {
            try scenario("launch-rejected") { mock, c, target in
                try upload(mock, c, target); c.requestInstall(); try reply(.installAccepted, to: 1, on: mock)
                try reply(.installation(target), to: 2, on: mock)
                c.requestLaunch(); try reply(.launchRejected, to: 3, on: mock)
                XCTAssertEqual(c.state, .installed); XCTAssertEqual(c.issue, .launchRejected)
                XCTAssertFalse(c.launchConfirmed)
            }
        }
    }
    func testWrongLaunchEvidence() async throws {
        try await MainActor.run {
            try scenario("wrong-launch") { mock, c, target in
                try upload(mock, c, target); c.requestInstall(); try reply(.installAccepted, to: 1, on: mock)
                try reply(.installation(target), to: 2, on: mock)
                c.requestLaunch(); try reply(.launchAccepted, to: 3, on: mock)
                try reply(.running(target, processIdentifier: 0), to: 4, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation); XCTAssertFalse(c.launchConfirmed)
            }
        }
    }
    func testClockTimeoutInvalidatesCallback() async throws {
        try await MainActor.run {
            var now: TimeInterval = 0
            let mock = MockTransport()
            let c = DeviceInstallCoordinator(transport: mock, timeout: 5, clock: { now })
            let target = InstallTarget(bundleIdentifier: "org.ze.test", version: "1", build: "1")
            try c.start(target); now = 5; c.checkTimeout()
            XCTAssertEqual(c.state, .failed); XCTAssertEqual(c.issue, .timedOut)
            try reply(.uploaded, to: 0, on: mock); XCTAssertEqual(c.state, .failed)
        }
    }

    func testRestoreQueryTimeoutStaysPendingWithoutPriorSubmission() async throws {
        try await MainActor.run {
            try scenario("restore-timeout") { mock, c, target in
                let original = DeviceInstallCoordinator(transport: MockTransport())
                try original.start(target)
                try c.restore(original.snapshot!)
                try reply(.timedOut, to: 0, on: mock)
                XCTAssertEqual(c.state, .pendingConfirmation)
                XCTAssertFalse(c.installationConfirmed)
                XCTAssertFalse(c.launchConfirmed)
            }
        }
    }

    func testMockReplyRejectsMissingRequestsWithoutCrashing() async {
        await MainActor.run {
            let mock = MockTransport()
            XCTAssertFalse(mock.reply(.uploaded, to: -1))
            XCTAssertFalse(mock.reply(.uploaded, to: 0))
            var callbacks = 0
            mock.send(.upload(InstallTarget(bundleIdentifier: "org.ze.test", version: "1", build: "1")), token: UUID()) { _ in
                callbacks += 1
            }
            XCTAssertFalse(mock.reply(.uploaded, to: 1))
            XCTAssertEqual(callbacks, 0)
            XCTAssertTrue(mock.reply(.uploaded, to: 0))
            XCTAssertEqual(callbacks, 1)
        }
    }
}
