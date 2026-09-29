import Foundation

/// GitHub Copilot OAuth using GitHub's device authorization flow.
/// The GitHub access token is kept in the per-provider Keychain; Copilot's
/// short-lived API token is exchanged lazily and cached in memory.
@MainActor
final class GitHubCopilotOAuthManager: ObservableObject {
    static let shared = GitHubCopilotOAuthManager()

    struct DeviceLoginPresentation: Equatable {
        let userCode: String
        let verificationURL: String
        let verificationURLComplete: String?
    }

    private struct DeviceAuthorization: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String?
        let expiresIn: Int
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case verificationUriComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct AccessTokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }

    private struct CopilotTokenResponse: Decodable {
        let token: String
        let expiresAt: TimeInterval?
        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
        }
    }

    private typealias Storage = GitHubCopilotOAuthTokenStorage

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    /// The OAuth App client id is configured locally; never ship a guessed or
    /// borrowed third-party identifier in the binary.
    private var cached: [String: CachedToken] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    var clientID: String {
        let local = UserDefaults.standard.string(forKey: "GitHubCopilotOAuthClientID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !local.isEmpty { return local }
        return Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String ?? ""
    }

    func isAuthenticated(instanceId: String) -> Bool {
        guard let storage = load(instanceId: instanceId) else { return false }
        return !storage.githubAccessToken.isEmpty
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = load(instanceId: instanceId)?.githubAccessToken, token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func logout(instanceId: String) {
        cached[instanceId] = nil
        inFlight[instanceId]?.cancel()
        inFlight[instanceId] = nil
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
        ProviderKeychainHelper.deleteOAuthString(instanceId: instanceId, account: "manual-oauth-token")
    }

    func login(
        instanceId: String,
        present: @escaping (DeviceLoginPresentation) -> Void
    ) async throws {
        guard !clientID.isEmpty else {
            throw LLMProviderError.providerError("请先填写 GitHub OAuth 应用的客户端 ID 并启用设备授权流程。")
        }
        let auth = try await requestDeviceAuthorization()
        present(DeviceLoginPresentation(
            userCode: auth.userCode,
            verificationURL: auth.verificationUri,
            verificationURLComplete: auth.verificationUriComplete
        ))
        let token = try await pollForAccessToken(
            deviceCode: auth.deviceCode,
            interval: auth.interval ?? 5,
            expiresIn: auth.expiresIn
        )
        let sessionToken = try await exchangeForCopilotToken(instanceId: instanceId, githubToken: token)
        let expiry = cached[instanceId]?.expiresAt
        save(Storage(githubAccessToken: token, copilotToken: sessionToken, copilotExpiresAt: expiry), instanceId: instanceId)
    }

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = load(instanceId: instanceId), !storage.githubAccessToken.isEmpty else {
            throw LLMProviderError.noCredentials
        }
        if let cachedToken = cached[instanceId], cachedToken.expiresAt > Date().addingTimeInterval(60) {
            return cachedToken.value
        }
        if let copilotToken = storage.copilotToken,
           let expiry = storage.copilotExpiresAt,
           expiry > Date().addingTimeInterval(60) {
            cached[instanceId] = CachedToken(value: copilotToken, expiresAt: expiry)
            return copilotToken
        }
        if let task = inFlight[instanceId] { return try await task.value }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.exchangeForCopilotToken(instanceId: instanceId, githubToken: storage.githubAccessToken)
        }
        inFlight[instanceId] = task
        defer { inFlight[instanceId] = nil }
        return try await task.value
    }

    private func requestDeviceAuthorization() async throws -> DeviceAuthorization {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode(["client_id": clientID, "scope": "read:user"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.providerError("GitHub 登录请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        do { return try JSONDecoder().decode(DeviceAuthorization.self, from: data) }
        catch { throw LLMProviderError.providerError("GitHub 登录响应格式错误：\(error.localizedDescription)") }
    }

    private func pollForAccessToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var delay = max(3, interval)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = formEncode([
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            let (data, _) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(AccessTokenResponse.self, from: data)
            if let accessToken = result.accessToken, !accessToken.isEmpty { return accessToken }
            switch result.error {
            case "authorization_pending": continue
            case "slow_down": delay += 5
            case "access_denied": throw LLMProviderError.providerError("GitHub 登录已取消")
            case "expired_token": throw LLMProviderError.providerError("GitHub 登录验证码已过期")
            default: throw LLMProviderError.providerError(result.errorDescription ?? "GitHub 登录失败")
            }
        }
        throw LLMProviderError.providerError("GitHub 登录超时，请重新开始")
    }

    private func exchangeForCopilotToken(instanceId: String, githubToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/v2/token")!)
        request.httpMethod = "GET"
        request.setValue("token \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GitHubCopilot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.providerError("GitHub Copilot 令牌交换失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        let result = try JSONDecoder().decode(CopilotTokenResponse.self, from: data)
        let expiry = result.expiresAt.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(1800)
        cached[instanceId] = CachedToken(value: result.token, expiresAt: expiry)
        if var storage = load(instanceId: instanceId) {
            storage.copilotToken = result.token
            storage.copilotExpiresAt = expiry
            save(storage, instanceId: instanceId)
        }
        return result.token
    }

    private func load(instanceId: String) -> Storage? {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: Storage.self)
    }

    private func save(_ storage: Storage, instanceId: String) {
        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
    }

    private func formEncode(_ values: [String: String]) -> Data {
        let body = values.map { key, value in
            "\(escape(key))=\(escape(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

struct GitHubCopilotOAuthTokenStorage: Codable {
    var githubAccessToken: String
    var copilotToken: String?
    var copilotExpiresAt: Date?
}
