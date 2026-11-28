import Foundation
import ConnectionExperimentCore
import CConnectionABI

/// Compiled with the production adapter and real Rust archive, never a stub.
@main struct SwiftABIContract {
    enum Failure: Error { case contract }
    // Fixed labels only: never print identities, PINs, payloads or native replies.
    static func progress(_ step: String) {
        FileHandle.standardError.write(Data(("ABI step: " + step + "\n").utf8))
    }
    @MainActor static func main() async throws {
        progress("01 entered Swift main; before raw ze_connection_new")
        guard let raw = ze_connection_new() else { throw Failure.contract }
        progress("02 raw runtime created; before cancel/free")
        ze_connection_cancel(raw)
        ze_connection_free(raw)
        progress("03 raw runtime freed; before adapter construction")
        let first = NativePairingBackend()
        progress("04 before missing-consent rejection")
        do { _ = try await first.prepare(saved: nil, runID: UUID(), allowNewIdentity: false); throw Failure.contract }
        catch ProbeFailure.identityCreationRequired { }
        progress("05 missing-consent rejected; before queued cancellation")
        let cancelledRunID = UUID()
        let queued = Task { try await first.prepare(saved: nil, runID: cancelledRunID, allowNewIdentity: true) }
        queued.cancel()
        do { _ = try await queued.value; throw Failure.contract } catch is CancellationError { }
        progress("06 queued cancellation passed; before new identity prepare")
        let firstRunID = UUID()
        let identity = try await first.prepare(saved: nil, runID: firstRunID, allowNewIdentity: true)
        progress("07 identity prepared; before identity assertions")
        guard !identity.paired, identity.txt["identifier"] == identity.identifier,
              identity.txt["authTag"]?.isEmpty == false else { throw Failure.contract }
        progress("08 before listener creation")
        let port = try await first.listen()
        guard port > 0 else { throw Failure.contract }
        progress("09 listener created; before pairing cancellation")
        let pairing = Task { try await first.pair(identity: identity) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        first.stop()
        do { _ = try await pairing.value; throw Failure.contract }
        catch ProbeFailure.cancelled { /* expected, authenticated handshake never occurred */ }
        progress("10 pairing cancelled; before saved identity prepare")
        let nextRunID = UUID()
        _ = try await first.prepare(saved: identity.secret, runID: nextRunID, allowNewIdentity: false)
        progress("11 saved identity prepared; before stale cleanup/listen")
        first.stop(runID: firstRunID) // stale cleanup cannot stop the new session
        guard try await first.listen() > 0 else { throw Failure.contract }
        first.stop(runID: nextRunID)
        progress("12 stale cleanup passed; before identity roundtrip")
        let restoredBackend = NativePairingBackend()
        let restored = try await restoredBackend.prepare(saved: identity.secret, runID: UUID(), allowNewIdentity: false)
        guard restored == identity else { throw Failure.contract }
        restoredBackend.stop()
        progress("13 identity roundtrip passed; before corrupt identity rejection")
        let corrupt = NativePairingBackend()
        do { _ = try await corrupt.prepare(saved: Data("{}".utf8), runID: UUID(), allowNewIdentity: false); throw Failure.contract }
        catch ProbeFailure.identityInvalid { }
        progress("14 corrupt identity rejected; before retry")
        _ = try await corrupt.prepare(saved: identity.secret, runID: UUID(), allowNewIdentity: false)
        corrupt.stop()
        progress("15 all ABI assertions passed")
        print("{\"nativeABI\":\"PASS\",\"identityRoundtrip\":true,\"listenerCancellation\":true,\"device\":\"NOT TESTED\"}")
    }
}
