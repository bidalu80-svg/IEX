#if canImport(Security)
import Foundation
import Security

@MainActor public final class KeychainPairingIdentityStore: PairingIdentityStore {
    public static let service = "app.ze.connection-experiment.identity.v1"
    private let account = "host-identity-set"
    public init() {}
    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func read() throws -> Data? {
        var request = key
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(request as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data, !data.isEmpty else { throw ProbeFailure.identityUnavailable }
        return data
    }
    public func write(_ value: Data) throws {
        guard !value.isEmpty, value.count <= 128 * 1024 else { throw ProbeFailure.identityInvalid }
        let attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        let update = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = key; for (name, value) in attributes { item[name] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ProbeFailure.storageFailed }
        } else if update != errSecSuccess { throw ProbeFailure.storageFailed }
        guard try read() == value else { throw ProbeFailure.storageFailed }
    }
    public func delete() throws {
        let code = SecItemDelete(key as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else { throw ProbeFailure.identityUnavailable }
    }
}
#endif
