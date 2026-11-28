import XCTest
@testable import ConnectionExperimentCore

@MainActor private final class Fixture: PairingBackend, DeviceTunnelClient, PairingHost, PairingIdentityStore, ProbeLifetime {
    var saved: Data? = Data("SECRET-KEY".utf8)
    var calls: [String] = []
    var failure = ProbeFailure.queryFailed
    var errorAt: String?
    var paired = false
    var stale = false
    var mismatch = false
    var missingField = false
    var events: [TunnelEvidence] = [.tcpConnected, .pairVerified, .tlsAndCDTunnel, .rsd(requiredService: true)]
    var holdPrepare = false
    var prepareWaiting: CheckedContinuation<Void, Never>?
    var sessions: Set<UUID> = []
    var holdPair = false
    var waiting: CheckedContinuation<Void, Never>?
    var expiration: ((ProbeFailure) -> Void)?
    var lateEvidence: ((TunnelEvidence) -> Void)?
    func action(_ name: String) throws { calls.append(name); if errorAt == name { throw failure } }
    func identity(_ paired: Bool) -> HostIdentity {
        HostIdentity(secret: Data((paired ? "SECRET-PAIRED" : "SECRET-KEY").utf8), identifier: "FAKE-UDID",
                     txt: ["identifier":"FAKE-UDID", "authTag":"SECRET-AUTHTAG"], paired: paired)
    }
    func prepare(saved: Data?, runID: UUID, allowNewIdentity: Bool) async throws -> HostIdentity {
        try action("prepare")
        if saved == nil && !allowNewIdentity { throw ProbeFailure.identityCreationRequired }
        if holdPrepare { await withCheckedContinuation { prepareWaiting = $0 } }
        sessions.insert(runID)
        return identity(saved == Data("SECRET-PAIRED".utf8) || paired)
    }
    func stop(runID: UUID) { sessions.remove(runID); calls.append("stopOwned") }
    func listen() async throws -> UInt16 { try action("listen"); return 12345 }
    func pair(identity: HostIdentity, pin: @escaping @MainActor (String) -> Void) async throws -> HostIdentity {
        try action("pair"); pin("SECRET-PIN")
        if holdPair { await withCheckedContinuation { waiting = $0 } }
        return self.identity(true)
    }
    func stop() { calls.append("stop") }
    func connect(identity: HostIdentity, evidence: @escaping @MainActor (TunnelEvidence) -> Void) async throws {
        try action("connect"); lateEvidence = evidence; events.forEach(evidence)
    }
    func query(requestID: UUID) async throws -> ReadOnlyDeviceResult {
        try action("query")
        return ReadOnlyDeviceResult(requestID: stale ? UUID() : requestID,
                                    productVersion: missingField ? "" : "27.2", buildVersion: "24A1", identityMatches: !mismatch)
    }
    func close() { calls.append("close") }
    func publish(identity: HostIdentity, port: UInt16) async throws { try action("publish") }
    func read() throws -> Data? { try action("read"); return saved }
    func write(_ value: Data) throws { try action("write"); saved = value }
    func delete() throws { saved = nil }
    func acquire(expired: @escaping @MainActor (ProbeFailure) -> Void) throws { try action("acquire"); expiration = expired }
    func release() { calls.append("release"); expiration = nil }
}

final class ConnectionProbeTests: XCTestCase {
    @MainActor private func make(_ f: Fixture, enabled: Bool = true) -> ConnectionProbeCoordinator {
        ConnectionProbeCoordinator(enabled: enabled, backend: f, tunnel: f, host: f, store: f, lifetime: f, recorder: ConnectionEvidenceRecorder())
    }
    @MainActor private func settle(_ c: ConnectionProbeCoordinator) async {
        for _ in 0..<100 where c.state == .running { await Task.yield() }
    }
    @MainActor func testImmediateCancelBeforeTaskRunsDoesNotReadOrPrepare() async {
        let f = Fixture(); let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); c.cancel()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(f.calls.contains("read")); XCTAssertFalse(f.calls.contains("prepare")); XCTAssertTrue(f.sessions.isEmpty)
        XCTAssertTrue(c.start(mode: .firstPairing, routeConfirmed: true)); await settle(c)
        XCTAssertEqual(c.state, .queryPassed); XCTAssertTrue(f.sessions.isEmpty)
    }
    @MainActor func testStalePrepareReclaimsOnlyItsOwnSession() async {
        let f = Fixture(); f.holdPrepare = true; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        let old = f.prepareWaiting; c.cancel(); f.holdPrepare = false; f.holdPair = true
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(f.sessions.count, 1)
        old?.resume(); for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(c.state, .running); XCTAssertEqual(f.sessions.count, 1)
        c.cancel(); f.waiting?.resume(); for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(f.sessions.isEmpty)
    }
    @MainActor func testLateNotificationAuthorizationCannotWriteNextRun() async {
        let f = Fixture(); f.holdPair = true; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        let old = c.lifecycleCallback(.notificationUnavailable)
        c.cancel(); let waiting = f.waiting
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        let before = try? c.recorder.export(); old()
        XCTAssertEqual(try? c.recorder.export(), before); XCTAssertEqual(c.state, .running)
        let current = c.lifecycleCallback(.notificationUnavailable); current()
        XCTAssertEqual(c.recorder.lifecycle.last?.event, .notificationUnavailable)
        c.cancel(); waiting?.resume(); f.waiting?.resume()
    }
    @MainActor func testLateLifetimeCallbackCannotExpireNextLease() async {
        let scope = ProbeCallbackScope(); var oldCalls = 0; var newCalls = 0
        scope.begin(); let old = scope.bind { oldCalls += 1 }
        scope.invalidate(); scope.begin(); let current = scope.bind { newCalls += 1 }
        let queued = Task { @MainActor in old() }; await queued.value
        XCTAssertEqual(oldCalls, 0); XCTAssertEqual(newCalls, 0)
        current(); XCTAssertEqual(newCalls, 1)
        scope.invalidate(); current(); XCTAssertEqual(newCalls, 1)
    }
    @MainActor func testMissingIdentityRequiresConfirmationBeforeAnyPrepareOrSave() async {
        let f = Fixture(); f.saved = nil; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.identityCreationRequired)); XCTAssertNil(f.saved)
        XCTAssertFalse(f.calls.contains("prepare")); XCTAssertFalse(f.calls.contains("write")); XCTAssertFalse(f.calls.contains("listen"))
        XCTAssertTrue(c.confirmNewIdentity(runID: c.recorder.runID)); await settle(c)
        XCTAssertEqual(c.state, .queryPassed); XCTAssertEqual(f.saved, Data("SECRET-PAIRED".utf8))
    }
    @MainActor func testOldIdentityCreationConsentCannotAuthorizeNextRun() async {
        let f = Fixture(); f.saved = nil; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c); let old = c.recorder.runID
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertFalse(c.confirmNewIdentity(runID: old)); XCTAssertNil(f.saved); XCTAssertFalse(f.calls.contains("prepare"))
        XCTAssertTrue(c.confirmNewIdentity(runID: c.recorder.runID)); await settle(c)
        XCTAssertEqual(c.state, .queryPassed)
        XCTAssertFalse(c.confirmNewIdentity(runID: old))
    }
    @MainActor func testDiscoveryCanBeAddedAfterQueryOrRouteBlockWithoutChangingConclusions() async {
        for route in [true,false] {
            let f = Fixture(); let c = make(f); c.start(mode: .firstPairing, routeConfirmed: route); await settle(c)
            let runID = c.recorder.runID; let state = c.state; let before = c.recorder.results; let events = c.recorder.events.count
            XCTAssertTrue(c.confirmSettingsDiscovery(runID: runID))
            XCTAssertEqual(c.state,state); XCTAssertEqual(c.recorder.runID,runID)
            XCTAssertEqual(c.recorder.results[.systemDiscovery],.pass)
            for step in ProbeStep.allCases where step != .systemDiscovery { XCTAssertEqual(c.recorder.results[step],before[step]) }
            XCTAssertEqual(c.recorder.events.count,events+1)
            XCTAssertTrue(c.confirmSettingsDiscovery(runID: runID)); XCTAssertEqual(c.recorder.events.count,events+1)
        }
    }
    @MainActor func testDiscoveryConfirmationRejectsOldRunAndUnpublishedRun() async {
        let f = Fixture(); let c = make(f); c.start(mode: .firstPairing, routeConfirmed: false); await settle(c)
        let old = c.recorder.runID
        c.start(mode: .appReopen, routeConfirmed: true)
        let before = try? c.recorder.export()
        XCTAssertFalse(c.confirmSettingsDiscovery(runID: old)); XCTAssertEqual(try? c.recorder.export(),before)
        await settle(c)
        XCTAssertFalse(c.confirmSettingsDiscovery(runID: c.recorder.runID)) // reused identity did not publish
        XCTAssertNotEqual(c.recorder.results[.systemDiscovery],.pass)
    }
    @MainActor func testFirstQueryAndOrdering() async {
        let f = Fixture(), c = make(Fixture())
        let probe = make(f); XCTAssertTrue(probe.start(mode: .firstPairing, routeConfirmed: true)); await settle(probe)
        XCTAssertEqual(probe.state, .queryPassed)
        XCTAssertEqual(probe.isReusingIdentity, false)
        XCTAssertLessThan(f.calls.firstIndex(of:"write")!, f.calls.firstIndex(of:"listen")!)
        XCTAssertLessThan(f.calls.firstIndex(of:"listen")!, f.calls.firstIndex(of:"publish")!)
        XCTAssertEqual(probe.recorder.results[.systemDiscovery], .notTested)
        XCTAssertEqual(probe.recorder.results[.appReopen], .notTested)
        XCTAssertEqual(c.state, .idle)
    }
    @MainActor func testFlagOffDoesNothing() async {
        let f = Fixture(); let c = make(f, enabled: false)
        XCTAssertFalse(c.start(mode: .firstPairing, routeConfirmed: true)); XCTAssertTrue(f.calls.isEmpty)
        XCTAssertEqual(c.state, .stopped(.disabled))
    }
    @MainActor func testPublicationIsNotQuerySuccess() async {
        let f = Fixture(); f.holdPair = true; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .running); XCTAssertEqual(c.recorder.results[.query], .notTested)
        c.cancel(); f.waiting?.resume(); await settle(c)
    }
    @MainActor func testTCPIsNotPairVerify() async {
        let f = Fixture(); f.events = [.tcpConnected]; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.invalidEvidence)); XCTAssertFalse(f.calls.contains("query"))
        XCTAssertNotEqual(c.recorder.results[.pairVerify], .pass)
    }
    @MainActor func testQueryFailureHasNoLocalFallback() async {
        let f = Fixture(); f.errorAt = "query"; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.queryFailed)); XCTAssertEqual(c.recorder.results[.query], .fail)
    }
    @MainActor func testCancelRejectsLateSuccess() async {
        let f = Fixture(); f.holdPair = true; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c); c.cancel()
        f.waiting?.resume(); for _ in 0..<100 { await Task.yield() }; f.lateEvidence?(.pairVerified)
        XCTAssertEqual(c.state, .stopped(.cancelled)); XCTAssertFalse(f.calls.contains("query"))
        XCTAssertNotEqual(c.recorder.results[.pairing], .pass)
        XCTAssertEqual(f.saved, Data("SECRET-KEY".utf8))
    }
    @MainActor func testDuplicateStart() async {
        let f = Fixture(); f.holdPair = true; let c = make(f)
        XCTAssertTrue(c.start(mode: .firstPairing, routeConfirmed: true))
        XCTAssertFalse(c.start(mode: .firstPairing, routeConfirmed: true)); await settle(c)
        c.cancel(); f.waiting?.resume()
    }
    @MainActor func testTimeout() async {
        let f = Fixture(); f.holdPair = true; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true, timeoutSeconds: 0.001)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(c.state, .stopped(.timeout)); f.waiting?.resume()
    }
    @MainActor func testAudioAndBackgroundExpirationReleaseResources() async {
        for reason in [ProbeFailure.audioConflict, .backgroundExpired] {
            let f = Fixture(); f.holdPair = true; let c = make(f)
            c.start(mode: .firstPairing, routeConfirmed: true); await settle(c); f.expiration?(reason)
            XCTAssertEqual(c.state, .stopped(reason)); XCTAssertTrue(f.calls.contains("release")); f.waiting?.resume()
        }
    }
    @MainActor func testMissingVPNPreservesPairing() async {
        let f = Fixture(); let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: false); await settle(c)
        XCTAssertEqual(c.state, .stopped(.routeBlocked)); XCTAssertEqual(f.saved, Data("SECRET-PAIRED".utf8))
        XCTAssertEqual(c.recorder.results[.pairing], .pass); XCTAssertEqual(c.recorder.results[.query], .blocked)
    }
    @MainActor func testRestoresAreSeparateAndSkipListener() async {
        let f = Fixture(); f.saved = Data("SECRET-PAIRED".utf8)
        for mode in [ProbeMode.appReopen, .deviceRestart] {
            let c = make(f); c.start(mode: mode, routeConfirmed: true); await settle(c)
            XCTAssertEqual(c.state, .queryPassed); XCTAssertEqual(c.isReusingIdentity, true); XCTAssertFalse(f.calls.contains("listen"))
            XCTAssertEqual(c.recorder.results[mode == .appReopen ? .appReopen : .deviceRestart], .pass)
            XCTAssertEqual(c.recorder.results[mode == .appReopen ? .deviceRestart : .appReopen], .notTested)
        }
    }
    @MainActor func testMissingRestoreIdentityDoesNotGenerate() async {
        let f = Fixture(); f.saved = nil; let c = make(f); c.start(mode: .appReopen, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.identityUnavailable)); XCTAssertFalse(f.calls.contains("prepare"))
    }
    @MainActor func testStoreFailureDoesNotPublish() async {
        let f = Fixture(); f.errorAt = "read"; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertFalse(f.calls.contains("listen")); XCTAssertNotEqual(c.state, .queryPassed)
    }
    @MainActor func testMissingService() async {
        let f = Fixture(); f.events[3] = .rsd(requiredService: false); let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.serviceMissing)); XCTAssertFalse(f.calls.contains("query"))
    }
    @MainActor func testReorderedEvidenceRejected() async {
        let f = Fixture(); f.events = [.pairVerified, .tcpConnected]; let c = make(f)
        c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.invalidEvidence))
    }
    @MainActor func testFreshIdentityAndRequiredFields() async {
        for kind in 0..<3 {
            let f = Fixture(); f.stale = kind == 0; f.mismatch = kind == 1; f.missingField = kind == 2
            let c = make(f); c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
            XCTAssertEqual(c.state, .stopped([ProbeFailure.staleResponse, .identityMismatch, .queryFailed][kind]))
        }
    }
    @MainActor func testStorageErrorsAreClassifiedAndDoNotPublish() async {
        for (operation, expected) in [("read", ProbeFailure.identityUnavailable), ("write", .storageFailed)] {
            let f = Fixture(); f.errorAt = operation; let c = make(f)
            c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
            XCTAssertEqual(c.state, .stopped(expected)); XCTAssertFalse(f.calls.contains("publish"))
        }
    }
    @MainActor func testPINAndProtocolRejectionAreSeparate() async {
        for failure in [ProbeFailure.wrongPIN, .pairingRejected, .disconnected] {
            let f = Fixture(); f.errorAt = "pair"; f.failure = failure; let c = make(f)
            c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
            XCTAssertEqual(c.state, .stopped(failure)); XCTAssertFalse(f.calls.contains("connect"))
            XCTAssertEqual(c.recorder.results[.query], .blocked)
        }
    }
    @MainActor func testRejectedReuseKeepsIdentity() async {
        let f = Fixture(); let saved = Data("SECRET-PAIRED".utf8); f.saved = saved
        f.errorAt = "connect"; f.failure = .identityRejected; let c = make(f)
        c.start(mode: .appReopen, routeConfirmed: true); await settle(c)
        XCTAssertEqual(c.state, .stopped(.identityRejected)); XCTAssertEqual(f.saved, saved)
        XCTAssertFalse(f.calls.contains("pair")); XCTAssertFalse(f.calls.contains("query"))
    }
    @MainActor func testSecretMarkersNeverExported() async throws {
        let f = Fixture(); let c = make(f); c.start(mode: .firstPairing, routeConfirmed: true); await settle(c)
        let report = String(decoding: try c.recorder.export(), as: UTF8.self)
        for secret in ["SECRET-PIN", "SECRET-KEY", "SECRET-PAIRED", "FAKE-UDID", "SECRET-AUTHTAG"] { XCTAssertFalse(report.contains(secret)) }
    }
}
