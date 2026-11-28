#if canImport(Darwin)
import Foundation

/// Listener is owned by PairingBackend. This object only publishes its already-bound
/// port; it does not ask NetService to create a second, disconnected listener.
@MainActor public final class BonjourPairingHost: NSObject, PairingHost, NetServiceDelegate {
    public static let serviceType = "_remotepairing-pairable-host._tcp."
    private var service: NetService?
    private var pending: CheckedContinuation<Void, Error>?
    public override init() { super.init() }
    public func publish(identity: HostIdentity, port: UInt16) async throws {
        guard service == nil, port != 0, identity.txt["identifier"] == identity.identifier,
              identity.txt["authTag"]?.isEmpty == false else { throw ProbeFailure.publicationFailed }
        let item = NetService(domain: "local.", type: Self.serviceType, name: identity.identifier, port: Int32(port))
        guard item.setTXTRecord(NetService.data(fromTXTRecord: identity.txt.mapValues { Data($0.utf8) })) else {
            throw ProbeFailure.publicationFailed
        }
        service = item; item.delegate = self
        try await withCheckedThrowingContinuation { pending = $0; item.publish(options: .noAutoRename) }
    }
    public func stop() {
        let completion = pending; pending = nil
        service?.delegate = nil; service?.stop(); service = nil
        completion?.resume(throwing: ProbeFailure.cancelled)
    }
    nonisolated public func netServiceDidPublish(_ sender: NetService) {
        Task { @MainActor in
            guard self.service === sender else { return }
            let completion = self.pending; self.pending = nil; completion?.resume()
        }
    }
    nonisolated public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Task { @MainActor in
            guard self.service === sender else { return }
            let completion = self.pending; self.pending = nil
            self.service?.stop(); self.service = nil
            completion?.resume(throwing: ProbeFailure.publicationFailed)
        }
    }
}
#endif
