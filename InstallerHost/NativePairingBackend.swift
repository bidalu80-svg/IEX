#if ZE_CONNECTION_EXPERIMENT
import Foundation
import ConnectionExperimentCore
import CConnectionABI

// Native handles and callbacks are confined to a serial worker. Only native cancel
// is concurrent. A new run gets a new session; stale callbacks keep their old context.
private final class NativeSession: @unchecked Sendable {
    let handle: OpaquePointer
    init() throws {
        guard let handle = ze_connection_new() else { throw ProbeFailure.backendUnavailable }
        self.handle = handle
    }
    func cancel() { ze_connection_cancel(handle) }
    deinit { ze_connection_free(handle) }
}
private final class NativeCallbacks: @unchecked Sendable {
    let event: @MainActor (Int32, String?) -> Void
    private let lock = NSLock()
    private var collected: [(Int32, String?)] = []
    func receive(_ code: Int32, _ pin: String?) {
        if code == 1 { Task { @MainActor in self.event(code, pin) }; return }
        lock.lock(); collected.append((code, nil)); lock.unlock()
    }
    func drain() -> [(Int32, String?)] { lock.lock(); defer { lock.unlock() }; return collected }
    init(_ event: @escaping @MainActor (Int32, String?) -> Void) { self.event = event }
}
private let nativeEvent: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void = { context, code, pointer in
    guard let context else { return }
    let callbacks = Unmanaged<NativeCallbacks>.fromOpaque(context).takeUnretainedValue()
    let pin = pointer.map { String(cString: $0) }
    // The Task retains callbacks until main-actor delivery, independent of worker return.
    callbacks.receive(code, pin)
}

private struct NativeReply: @unchecked Sendable {
    let result: Result<[String: Any], Error>
    let events: [(Int32, String?)]
}

@MainActor final class NativePairingBackend: PairingBackend, DeviceTunnelClient {
    private let queue = DispatchQueue(label: "Ze.ConnectionExperiment.native", qos: .userInitiated)
    private var session: NativeSession?
    private var activeID = UUID()
    private func call(_ operation: String, input: [String: Any] = [:],
                      event: @escaping @MainActor (Int32, String?) -> Void = { _, _ in }) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let session else { throw ProbeFailure.backendUnavailable }
        let id = activeID
        let bytes = try JSONSerialization.data(withJSONObject: input)
        guard let text = String(data: bytes, encoding: .utf8) else { throw ProbeFailure.identityInvalid }
        let callbacks = NativeCallbacks(event)
        // Replay non-PIN evidence on MainActor before returning/throwing. Independent
        // Tasks do not guarantee callback ordering, including at worker completion.
        let reply: NativeReply = await withCheckedContinuation { continuation in
            queue.async {
                let context = Unmanaged.passRetained(callbacks).toOpaque()
                defer { Unmanaged<NativeCallbacks>.fromOpaque(context).release() }
                let output = operation.withCString { op in text.withCString { input in
                    ze_connection_run(session.handle, op, input, nativeEvent, context)
                }}
                guard let output else { continuation.resume(returning: NativeReply(result: .failure(ProbeFailure.backendUnavailable), events: callbacks.drain())); return }
                let data = Data(String(cString: output).utf8); ze_connection_string_free(output)
                do {
                    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProbeFailure.backendUnavailable }
                    if let code = result["error"] as? String { throw ProbeFailure(rawValue: code) ?? .backendUnavailable }
                    guard let value = result["ok"] as? [String: Any] else { throw ProbeFailure.backendUnavailable }
                    continuation.resume(returning: NativeReply(result: .success(value), events: callbacks.drain()))
                } catch { continuation.resume(returning: NativeReply(result: .failure(error as? ProbeFailure ?? .backendUnavailable), events: callbacks.drain())) }
            }
        }
        guard activeID == id, self.session === session, !Task.isCancelled else { throw ProbeFailure.cancelled }
        for (code, pin) in reply.events { event(code, pin) }
        return try reply.result.get()
    }
    private func identity(_ value: [String: Any]) throws -> HostIdentity {
        guard let secret = value["secret"] as? [String: Any], let id = value["identifier"] as? String,
              let txt = value["txt"] as? [String:String], let paired = value["paired"] as? Bool else { throw ProbeFailure.identityInvalid }
        return HostIdentity(secret: try JSONSerialization.data(withJSONObject: secret, options: [.sortedKeys]), identifier: id, txt: txt, paired: paired)
    }
    func prepare(saved: Data?, runID: UUID, allowNewIdentity: Bool) async throws -> HostIdentity {
        try Task.checkCancellation()
        guard saved != nil || allowNewIdentity else { throw ProbeFailure.identityCreationRequired }
        guard session == nil else { throw ProbeFailure.alreadyRunning }
        activeID = runID; session = try NativeSession()
        do {
            let savedObject: Any = try saved.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            return try identity(await call("prepare", input: ["saved": savedObject, "allowNewIdentity": allowNewIdentity]))
        } catch {
            stop(runID: runID) // never cancel a replacement session from a later run
            throw error
        }
    }
    func listen() async throws -> UInt16 {
        let result = try await call("listen")
        guard let port = result["port"] as? Int, let value = UInt16(exactly: port), value > 0 else { throw ProbeFailure.listenerFailed }
        return value
    }
    func pair(identity: HostIdentity, pin: @escaping @MainActor (String) -> Void) async throws -> HostIdentity {
        let id = activeID
        return try self.identity(await call("pair") { [weak self] code, value in
            guard self?.activeID == id, code == 1, let value else { return }; pin(value)
        })
    }
    func connect(identity: HostIdentity, evidence: @escaping @MainActor (TunnelEvidence) -> Void) async throws {
        let id = activeID
        _ = try await call("connect") { [weak self] code, _ in
            guard self?.activeID == id else { return }
            switch code {
            case 2: evidence(.tcpConnected)
            case 3: evidence(.pairVerified)
            case 4: evidence(.tlsAndCDTunnel)
            case 5: evidence(.rsd(requiredService: true))
            default: break
            }
        }
    }
    func query(requestID: UUID) async throws -> ReadOnlyDeviceResult {
        let value = try await call("query", input: ["requestID": requestID.uuidString])
        guard let text = value["requestID"] as? String, let id = UUID(uuidString: text),
              let product = value["productVersion"] as? String, let build = value["buildVersion"] as? String,
              let matches = value["identityMatches"] as? Bool else { throw ProbeFailure.queryFailed }
        return ReadOnlyDeviceResult(requestID: id, productVersion: product, buildVersion: build, identityMatches: matches)
    }
    func stop(runID: UUID) { guard activeID == runID else { return }; stop() }
    func stop() { activeID = UUID(); session?.cancel(); session = nil }
    func close() { stop() }
}
#endif
