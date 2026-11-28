import Foundation

public enum ProbeFailure: String, Error, Codable {
    case disabled, alreadyRunning, cancelled, timeout, audioConflict, backgroundExpired
    case identityCreationRequired, identityUnavailable, identityInvalid, storageFailed, listenerFailed, publicationFailed
    case connectionRefused, connectionTimeout
    case pairingRejected, wrongPIN, disconnected, routeBlocked, wrongService, identityRejected
    case tlsFailed, tunnelParameters, rsdFailed, serviceMissing, queryFailed, identityMismatch
    case staleResponse, invalidEvidence, backendUnavailable
}

public struct HostIdentity: Equatable {
    // Secret envelope: passed only to the backend and the dedicated identity store.
    public let secret: Data
    public let identifier: String
    public let txt: [String: String]
    public let paired: Bool
    public init(secret: Data, identifier: String, txt: [String: String], paired: Bool) {
        self.secret = secret; self.identifier = identifier; self.txt = txt; self.paired = paired
    }
}

public struct ReadOnlyDeviceResult {
    public let requestID: UUID
    public let productVersion: String
    public let buildVersion: String
    public let identityMatches: Bool
    public init(requestID: UUID, productVersion: String, buildVersion: String, identityMatches: Bool) {
        self.requestID = requestID; self.productVersion = productVersion
        self.buildVersion = buildVersion; self.identityMatches = identityMatches
    }
}

public enum TunnelEvidence: Equatable {
    case tcpConnected, pairVerified, tlsAndCDTunnel, rsd(requiredService: Bool)
}

@MainActor public protocol PairingBackend: AnyObject {
    func prepare(saved: Data?, runID: UUID, allowNewIdentity: Bool) async throws -> HostIdentity
    /// Starts a real native listener before Bonjour is published. Zero is invalid.
    func listen() async throws -> UInt16
    func pair(identity: HostIdentity, pin: @escaping @MainActor (String) -> Void) async throws -> HostIdentity
    /// Release only resources owned by this run, including after a stale prepare.
    func stop(runID: UUID)
}

@MainActor public protocol DeviceTunnelClient: AnyObject {
    /// May emit only evidence actually acquired by this session, in order.
    func connect(identity: HostIdentity, evidence: @escaping @MainActor (TunnelEvidence) -> Void) async throws
    func query(requestID: UUID) async throws -> ReadOnlyDeviceResult
    func close()
}

@MainActor public protocol PairingHost: AnyObject {
    func publish(identity: HostIdentity, port: UInt16) async throws
    func stop()
}

@MainActor public protocol PairingIdentityStore: AnyObject {
    /// nil means item-not-found only. Locked/inaccessible/corrupt must throw.
    func read() throws -> Data?
    func write(_ value: Data) throws
    func delete() throws
}

@MainActor public protocol ProbeLifetime: AnyObject {
    func acquire(expired: @escaping @MainActor (ProbeFailure) -> Void) throws
    func release()
}

public enum ProbeMode: String, Codable { case firstPairing, appReopen, deviceRestart }
public enum ProbeStep: String, Codable, CaseIterable {
    case identity, listener, publication, systemDiscovery, lifetime, pairing, persistence
    case route, tcp, pairVerify, tlsCDTunnel, rsd, query, appReopen, deviceRestart
}
public enum EvidenceVerdict: String, Codable { case pass = "PASS", fail = "FAIL", blocked = "BLOCKED", notTested = "NOT TESTED" }
public enum ProbeState: Equatable { case idle, running, stopped(ProbeFailure), queryPassed }
