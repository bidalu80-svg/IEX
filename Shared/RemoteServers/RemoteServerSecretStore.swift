import Foundation
import Security

/// SSH secrets are intentionally device-only (`ThisDeviceOnly`, not
/// synchronizable). The metadata store contains no secret material.
enum RemoteServerSecretStore {
    private static let service = "com.ze.app.remote-servers"

    enum Kind: String, CaseIterable {
        case privateKey
        case privateKeyPassphrase
        /// Passwords and S3 secret keys for backup destinations. They are
        /// device-only and intentionally excluded from Codable profiles.
        case remoteSecret
    }

    static func save(_ value: String, kind: Kind, for serverID: UUID) throws {
        let account = account(kind: kind, serverID: serverID)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw RemoteServerSecretStoreError.osStatus(updateStatus) }

        var add = query
        add.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus != errSecSuccess { throw RemoteServerSecretStoreError.osStatus(addStatus) }
    }

    static func value(kind: Kind, for serverID: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind: kind, serverID: serverID),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw RemoteServerSecretStoreError.osStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(kind: Kind, for serverID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(kind: kind, serverID: serverID),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func deleteAll(for serverID: UUID) {
        Kind.allCases.forEach { delete(kind: $0, for: serverID) }
    }

    private static func account(kind: Kind, serverID: UUID) -> String {
        "\(serverID.uuidString.lowercased()).\(kind.rawValue)"
    }
}

enum RemoteServerSecretStoreError: LocalizedError {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status): return "无法安全存储服务器凭据（Keychain 错误 \(status)）"
        }
    }
}

/// Password authentication is session-only by design. It has no disk or
/// Keychain persistence and is cleared on an explicit disconnect/delete.
@MainActor
final class RemoteServerSessionCredentials {
    static let shared = RemoteServerSessionCredentials()

    private var passwords: [UUID: String] = [:]

    func setPassword(_ password: String, for serverID: UUID) {
        passwords[serverID] = password
    }

    func password(for serverID: UUID) -> String? {
        passwords[serverID]
    }

    func clear(for serverID: UUID) {
        passwords.removeValue(forKey: serverID)
    }
}
