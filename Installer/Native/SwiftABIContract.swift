import Foundation
import ConnectionExperimentCore

/// Compiled with the production adapter and real Rust archive, never a stub.
@main struct SwiftABIContract {
    enum Failure: Error { case contract }
    @MainActor static func main() async throws {
        let first = NativePairingBackend()
        do { _ = try await first.prepare(saved: nil, runID: UUID(), allowNewIdentity: false); throw Failure.contract }
        catch ProbeFailure.identityCreationRequired { }
        let cancelledRunID = UUID()
        let queued = Task { try await first.prepare(saved: nil, runID: cancelledRunID, allowNewIdentity: true) }
        queued.cancel()
        do { _ = try await queued.value; throw Failure.contract } catch is CancellationError { }
        let firstRunID = UUID()
        let identity = try await first.prepare(saved: nil, runID: firstRunID, allowNewIdentity: true)
        guard !identity.paired, identity.txt["identifier"] == identity.identifier,
              identity.txt["authTag"]?.isEmpty == false else { throw Failure.contract }
        let port = try await first.listen()
        guard port > 0 else { throw Failure.contract }
        let pairing = Task { try await first.pair(identity: identity) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        first.stop()
        do { _ = try await pairing.value; throw Failure.contract }
        catch ProbeFailure.cancelled { /* expected, authenticated handshake never occurred */ }
        let nextRunID = UUID()
        _ = try await first.prepare(saved: identity.secret, runID: nextRunID, allowNewIdentity: false)
        first.stop(runID: firstRunID) // stale cleanup cannot stop the new session
        guard try await first.listen() > 0 else { throw Failure.contract }
        first.stop(runID: nextRunID)
        let restoredBackend = NativePairingBackend()
        let restored = try await restoredBackend.prepare(saved: identity.secret, runID: UUID(), allowNewIdentity: false)
        guard restored == identity else { throw Failure.contract }
        restoredBackend.stop()
        let corrupt = NativePairingBackend()
        do { _ = try await corrupt.prepare(saved: Data("{}".utf8), runID: UUID(), allowNewIdentity: false); throw Failure.contract }
        catch ProbeFailure.identityInvalid { }
        _ = try await corrupt.prepare(saved: identity.secret, runID: UUID(), allowNewIdentity: false)
        corrupt.stop()
        print("{\"nativeABI\":\"PASS\",\"identityRoundtrip\":true,\"listenerCancellation\":true,\"device\":\"NOT TESTED\"}")
    }
}
