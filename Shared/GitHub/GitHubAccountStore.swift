import Foundation
import Combine
import Security

@MainActor
final class GitHubAccountStore: ObservableObject {
    static let shared = GitHubAccountStore()

    @Published private(set) var accounts: [GitHubAccount] = []
    @Published private(set) var isLoading = false
    @Published var persistenceError: String?

    private let session: URLSession
    private let service = "com.ze.app.github-accounts"
    private let storageURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ze/GitHub", isDirectory: true)
        storageURL = root.appendingPathComponent("accounts.json")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    var oauthClientID: String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("$(") { return trimmed }
        }
        // Public OAuth client from github.com/cli/cli internal/authflow/flow.go.
        // Device flow sends no client secret. The authorization page names GitHub CLI.
        return "178c6fc778ccc68e1d6a"
    }

    func startDeviceLogin() async throws -> GitHubDeviceAuthorization {
        guard let clientID = oauthClientID else { throw GitHubConnectorError.clientIDMissing }
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["client_id": clientID, "scope": "repo read:org workflow read:user user:email"])
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let value = try decoder.decode(DeviceResponse.self, from: data)
        guard let verification = URL(string: value.verificationURI) else { throw GitHubConnectorError.malformedResponse }
        return GitHubDeviceAuthorization(deviceCode: value.deviceCode, userCode: value.userCode,
            verificationURL: verification, expiresIn: TimeInterval(value.expiresIn), pollingInterval: TimeInterval(value.interval ?? 5))
    }

    func finishDeviceLogin(_ authorization: GitHubDeviceAuthorization) async throws -> GitHubAccount {
        guard let clientID = oauthClientID else { throw GitHubConnectorError.clientIDMissing }
        let deadline = Date().addingTimeInterval(authorization.expiresIn)
        var interval = authorization.pollingInterval
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = form(["client_id": clientID, "device_code": authorization.deviceCode,
                                     "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let tokenResponse = try? decoder.decode(TokenResponse.self, from: data)
            if let error = tokenResponse?.error {
                switch error {
                case "authorization_pending": continue
                case "slow_down": interval += 5; continue
                case "expired_token": throw GitHubConnectorError.expiredDeviceCode
                case "access_denied": throw GitHubConnectorError.authorizationDenied
                default: throw GitHubConnectorError.http(status, error)
                }
            }
            guard let token = tokenResponse?.accessToken else { throw GitHubConnectorError.malformedResponse }
            return try await addAccount(token: token, grantedScopes: tokenResponse?.scope.map(GitHubAPI.scopes))
        }
        throw GitHubConnectorError.expiredDeviceCode
    }

    func loginWithToken(_ token: String) async throws -> GitHubAccount {
        try await addAccount(token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func token(for accountID: UUID) -> String? {
        do {
            return try keychainValue(accountID: accountID)
        } catch {
            return nil
        }
    }

    func delete(_ account: GitHubAccount) {
        do {
            let remaining = accounts.filter { $0.id != account.id }
            let original = accounts
            try GitHubAccountPersistence.commit(
                writeMetadata: { try self.persist(remaining) },
                writeCredential: { try self.deleteKeychain(account.id) },
                rollbackMetadata: { try self.persist(original) })
            accounts = remaining
        } catch { persistenceError = error.localizedDescription }
    }

    private func addAccount(token: String, grantedScopes: [String]? = nil) async throws -> GitHubAccount {
        guard !token.isEmpty else { throw GitHubConnectorError.invalidToken }
        let (data, response) = try await GitHubAPI(session: session).raw(path: "/user", token: token)
        let profile = try JSONDecoder().decode(GitHubUserProfile.self, from: data)
        let existing = accounts.first { $0.login.caseInsensitiveCompare(profile.login) == .orderedSame }
        let scopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes").map(GitHubAPI.scopes) ?? grantedScopes
        let account = GitHubAccount(id: existing?.id ?? UUID(), login: profile.login,
            displayName: profile.name ?? "", avatarURL: profile.avatarURL,
            createdAt: existing?.createdAt ?? .now, grantedScopes: scopes)
        let original = accounts
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account }
        else { updated.append(account) }
        updated.sort { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
        try GitHubAccountPersistence.commit(
            writeMetadata: { try self.persist(updated) },
            writeCredential: { try self.saveKeychain(token, accountID: account.id) },
            rollbackMetadata: { try self.persist(original) })
        accounts = updated
        return account
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL), let loaded = try? decoder.decode([GitHubAccount].self, from: data) else { return }
        accounts = loaded
    }

    private func persist(_ values: [GitHubAccount]) throws {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(values).write(to: storageURL, options: .atomic)
        } catch { throw GitHubConnectorError.storage(error) }
    }

    private func accountKey(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func saveKeychain(_ token: String, accountID: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrAccount as String: accountKey(accountID), kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GitHubConnectorError.keychain(status) }
        var add = query; attrs.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw GitHubConnectorError.keychain(addStatus) }
    }
    private func keychainValue(accountID: UUID) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrAccount as String: accountKey(accountID), kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
                                     kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw GitHubConnectorError.keychain(status) }
        return value
    }
    private func deleteKeychain(_ id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                     kSecAttrAccount as String: accountKey(id), kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GitHubConnectorError.keychain(status) }
    }

    private func form(_ values: [String: String]) -> Data? {
        let encoded = values.map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
            return "\(key)=\(escaped)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }
    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw GitHubConnectorError.http((response as? HTTPURLResponse)?.statusCode ?? 0, detail)
        }
    }

    private struct DeviceResponse: Decodable { let deviceCode: String; let userCode: String; let verificationURI: String; let expiresIn: Int; let interval: Int?
        enum CodingKeys: String, CodingKey { case deviceCode = "device_code"; case userCode = "user_code"; case verificationURI = "verification_uri"; case expiresIn = "expires_in"; case interval }
    }
    private struct TokenResponse: Decodable { let accessToken: String?; let error: String?; let scope: String?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case error; case scope }
    }
}

struct GitHubUserProfile: Decodable { let login: String; let name: String?; let avatarURL: URL?
    enum CodingKeys: String, CodingKey { case login; case name; case avatarURL = "avatar_url" }
}
