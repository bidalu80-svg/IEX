import Foundation

/// All SSH credential writers invalidate the prior authentication state before
/// touching secrets. A partial Keychain failure must not retain an old session
/// or an old disk verification. Runs synchronously on the main actor so a new
/// reader cannot start between invalidation and the credential writes.
@MainActor
enum RemoteServerCredentialChange {
    static func perform(for serverID: UUID, _ write: () throws -> Void) throws {
        RemoteSSHConnectionService.shared.invalidateCredentialConnection(serverID: serverID)
        RemoteServerSessionCredentials.shared.clear(for: serverID)
        try RemoteServerStore.shared.markCredentialsChanged(serverID)
        try RemoteDiskStore.shared.clearSSHVerification(serverID: serverID)
        try write()
    }
}
