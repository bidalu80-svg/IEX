import Foundation

@MainActor public final class ConnectionProbeCoordinator {
    public private(set) var state = ProbeState.idle { didSet { changed?() } }
    public private(set) var isReusingIdentity: Bool?
    public private(set) var readOnlyResult: ReadOnlyDeviceResult?
    public let recorder: ConnectionEvidenceRecorder
    public var changed: (() -> Void)?
    public var showPIN: ((String?) -> Void)?
    private let backend: PairingBackend
    private let tunnel: DeviceTunnelClient
    private let host: PairingHost
    private let store: PairingIdentityStore
    private let lifetime: ProbeLifetime
    private let enabled: Bool
    private var generation: UUID?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var currentStep = ProbeStep.identity
    private var tunnelIndex = 0
    private var pendingIdentityCreation: (runID: UUID, route: Bool, timeout: Double)?

    public init(enabled: Bool, backend: PairingBackend, tunnel: DeviceTunnelClient, host: PairingHost,
                store: PairingIdentityStore, lifetime: ProbeLifetime, recorder: ConnectionEvidenceRecorder) {
        self.enabled = enabled; self.backend = backend; self.tunnel = tunnel; self.host = host
        self.store = store; self.lifetime = lifetime; self.recorder = recorder
    }
    /// Entry is explicit. No constructor, restore callback or scene change starts work.
    @discardableResult public func start(mode: ProbeMode, routeConfirmed: Bool, timeoutSeconds: Double = 120) -> Bool {
        begin(mode: mode, routeConfirmed: routeConfirmed, timeoutSeconds: timeoutSeconds, allowNewIdentity: false)
    }
    /// Consent is valid only for the just-displayed missing-record outcome. Missing
    /// Keychain items cannot distinguish first use from re-signing/access-domain loss.
    @discardableResult public func confirmNewIdentity(runID: UUID) -> Bool {
        guard let pending = pendingIdentityCreation, pending.runID == runID,
              recorder.runID == runID, state == .stopped(.identityCreationRequired), generation == nil else { return false }
        return begin(mode: .firstPairing, routeConfirmed: pending.route, timeoutSeconds: pending.timeout, allowNewIdentity: true)
    }
    private func begin(mode: ProbeMode, routeConfirmed: Bool, timeoutSeconds: Double, allowNewIdentity: Bool) -> Bool {
        guard enabled else { state = .stopped(.disabled); return false }
        guard generation == nil else { return false }
        pendingIdentityCreation = nil
        let token = UUID(); generation = token; tunnelIndex = 0; currentStep = .identity
        readOnlyResult = nil; isReusingIdentity = nil; recorder.begin(mode: mode); state = .running
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(timeoutSeconds, 180)) * 1_000_000_000)) }
            catch { return }
            guard self?.generation == token else { return }
            self?.stop(.timeout)
        }
        work = Task { [weak self] in
            guard let self else { return }
            do {
                // Task cancellation does not prevent a queued closure from executing.
                try self.check(token)
                let saved: Data?
                do { saved = try self.store.read() } catch { throw ProbeFailure.identityUnavailable }
                if mode != .firstPairing && saved == nil { throw ProbeFailure.identityUnavailable }
                if saved == nil && !allowNewIdentity { throw ProbeFailure.identityCreationRequired }
                var identity = try await self.backend.prepare(saved: saved, runID: token, allowNewIdentity: allowNewIdentity)
                try self.check(token)
                guard !identity.secret.isEmpty, !identity.identifier.isEmpty,
                      identity.txt["identifier"] == identity.identifier, identity.txt["authTag"]?.isEmpty == false else {
                    throw ProbeFailure.identityInvalid
                }
                if mode != .firstPairing && !identity.paired { throw ProbeFailure.identityUnavailable }
                // Save even unpaired identity before any network activity; retries retain host keys.
                try self.persist(identity.secret)
                self.isReusingIdentity = identity.paired
                self.pass(.identity)
                self.currentStep = .lifetime
                try self.lifetime.acquire { [weak self] reason in
                    guard self?.generation == token else { return }; self?.stop(reason)
                }
                self.pass(.lifetime)
                if !identity.paired {
                    self.currentStep = .listener
                    let port = try await self.backend.listen(); try self.check(token)
                    guard port != 0 else { throw ProbeFailure.listenerFailed }; self.pass(.listener)
                    self.currentStep = .publication
                    try await self.host.publish(identity: identity, port: port); try self.check(token)
                    self.pass(.publication)
                    self.currentStep = .pairing
                    let original = identity
                    identity = try await self.backend.pair(identity: identity) { [weak self] pin in
                        guard self?.generation == token else { return }; self?.showPIN?(pin)
                    }
                    try self.check(token)
                    guard identity.paired, identity.identifier == original.identifier, identity.txt == original.txt else { throw ProbeFailure.pairingRejected }
                    self.showPIN?(nil); self.pass(.pairing)
                    self.currentStep = .persistence
                    try self.persist(identity.secret)
                    self.pass(.persistence); self.host.stop()
                } else { self.pass(.persistence) }
                self.currentStep = .route
                guard routeConfirmed else { throw ProbeFailure.routeBlocked }; self.pass(.route)
                self.currentStep = .tcp
                try await self.tunnel.connect(identity: identity) { [weak self] event in
                    guard let self, self.generation == token else { return }
                    self.receive(event)
                }
                try self.check(token)
                guard self.tunnelIndex == 4 else { throw ProbeFailure.invalidEvidence }
                self.currentStep = .query
                let requestID = UUID()
                let result = try await self.tunnel.query(requestID: requestID); try self.check(token)
                guard result.requestID == requestID else { throw ProbeFailure.staleResponse }
                guard result.identityMatches else { throw ProbeFailure.identityMismatch }
                guard !result.productVersion.isEmpty, !result.buildVersion.isEmpty else { throw ProbeFailure.queryFailed }
                self.readOnlyResult = result
                self.pass(.query)
                if mode == .appReopen { self.pass(.appReopen) }
                if mode == .deviceRestart { self.pass(.deviceRestart) }
                self.cleanup(); self.state = .queryPassed
            } catch {
                guard self.generation == token else {
                    self.backend.stop(runID: token)
                    return
                }
                if error as? ProbeFailure == .identityCreationRequired {
                    self.pendingIdentityCreation = (self.recorder.runID, routeConfirmed, timeoutSeconds)
                }
                self.stop(error as? ProbeFailure ?? .disconnected)
            }
        }
        return true
    }
    /// Host callbacks capture this action before leaving MainActor; old callbacks
    /// may not append to a new run, nor to a completed run's automatic timeline.
    public func lifecycleCallback(_ event: ConnectionEvidenceRecorder.Lifecycle) -> @MainActor () -> Void {
        let token = generation
        return { [weak self] in
            guard let self, let token, self.generation == token else { return }
            self.recorder.recordLifecycle(event)
        }
    }
    private func persist(_ data: Data) throws {
        do {
            try store.write(data)
            guard try store.read() == data else { throw ProbeFailure.storageFailed }
        } catch { throw ProbeFailure.storageFailed }
    }
    private func receive(_ event: TunnelEvidence) {
        let sequence: [TunnelEvidence] = [.tcpConnected, .pairVerified, .tlsAndCDTunnel, .rsd(requiredService: true)]
        guard tunnelIndex < sequence.count, event == sequence[tunnelIndex] else {
            stop(event == .rsd(requiredService: false) ? .serviceMissing : .invalidEvidence); return
        }
        let steps: [ProbeStep] = [.tcp, .pairVerify, .tlsCDTunnel, .rsd]
        pass(steps[tunnelIndex]); tunnelIndex += 1
        currentStep = tunnelIndex < steps.count ? steps[tunnelIndex] : .query
    }
    private func check(_ token: UUID) throws {
        guard generation == token, !Task.isCancelled else { throw ProbeFailure.cancelled }
    }
    private func pass(_ step: ProbeStep) { recorder.record(step, .pass); changed?() }
    /// Manual evidence may arrive after returning from Settings and after cleanup.
    /// It belongs only to the currently displayed run; a new start invalidates it.
    @discardableResult public func confirmSettingsDiscovery(runID: UUID) -> Bool {
        guard recorder.runID == runID, recorder.results[.publication] == .pass else { return false }
        if recorder.results[.systemDiscovery] != .pass { recorder.record(.systemDiscovery, .pass); changed?() }
        return true
    }
    public func cancel() { guard generation != nil else { return }; stop(.cancelled) }
    private func stop(_ reason: ProbeFailure) {
        recorder.record(currentStep, reason == .routeBlocked ? .blocked : .fail, failure: reason)
        recorder.blockRemaining(); cleanup(); state = .stopped(reason)
    }
    private func cleanup() {
        let token = generation
        generation = nil; timer?.cancel(); timer = nil; work?.cancel(); work = nil
        host.stop(); if let token { backend.stop(runID: token) }; tunnel.close(); lifetime.release(); showPIN?(nil)
    }
}
