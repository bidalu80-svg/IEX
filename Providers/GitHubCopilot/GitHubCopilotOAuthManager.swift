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

    /// GitHub returns the Copilot routing information from this private
    /// account endpoint. Individual accounts use a regional/individual API
    /// host and do not always expose the legacy v2 token exchange endpoint.
    private struct CopilotUserResponse: Decodable {
        struct Endpoints: Decodable {
            let api: String?
        }

        let endpoints: Endpoints?
        let copilotPlan: String?

        enum CodingKeys: String, CodingKey {
            case endpoints
            case copilotPlan = "copilot_plan"
        }
    }

    private struct CopilotTokenResponse: Decodable {
        let token: String
        let expiresAt: TimeInterval?
        let endpoints: CopilotUserResponse.Endpoints?

        enum CodingKeys: String, CodingKey {
            case token
            case expiresAt = "expires_at"
            case endpoints
        }
    }

    private struct CopilotTokenExchangeResult {
        let token: String
        let expiresAt: Date
        let apiBaseURL: String?
    }

    private struct HTTPFailure: Error {
        let statusCode: Int
        let body: String
    }

    private typealias Storage = GitHubCopilotOAuthTokenStorage

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    /// GitHub's public Copilot OAuth application id. It is not a user
    /// credential; GitHub device authorization requires it to identify the
    /// first-party Copilot client. Keep the UserDefaults/Info.plist overrides
    /// below for enterprise builds that use their own registered OAuth app.
    private static let copilotOAuthClientID = "Iv1.b507a08c87ecfe98"

    private var cached: [String: CachedToken] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    var clientID: String {
        let local = UserDefaults.standard.string(forKey: "GitHubCopilotOAuthClientID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !local.isEmpty { return local }
        if let bundled = Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String,
           !bundled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Self.copilotOAuthClientID
    }

    /// The account-specific Copilot API host discovered during device login.
    /// Returning this to the provider factory avoids routing individual
    /// accounts through the generic host, which produces HTTP 404.
    func apiBaseURL(instanceId: String) -> String? {
        load(instanceId: instanceId)?.copilotAPIBaseURL
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
            throw LLMProviderError.providerError("GitHub Copilot OAuth 客户端未配置。")
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

        // Resolve the account route before attempting the legacy exchange. A
        // 404 from /copilot_internal/v2/token is expected for some individual
        // accounts; those accounts can use the GitHub OAuth token directly on
        // their account-specific Copilot host.
        let user = try? await fetchCopilotUser(githubToken: token)
        let discoveredBase = normalizedCopilotAPIBase(user?.endpoints?.api)
        let shouldUseGitHubToken = isDirectCopilotRoute(user: user, apiBaseURL: discoveredBase)

        if shouldUseGitHubToken {
            saveDirectToken(token, apiBaseURL: discoveredBase, instanceId: instanceId)
            return
        }

        do {
            let exchanged = try await exchangeForCopilotToken(githubToken: token)
            let routed = CopilotTokenExchangeResult(
                token: exchanged.token,
                expiresAt: exchanged.expiresAt,
                apiBaseURL: exchanged.apiBaseURL ?? discoveredBase
            )
            saveExchange(routed, githubToken: token, instanceId: instanceId)
        } catch let failure as HTTPFailure where failure.statusCode == 404 {
            // Keep the login usable when GitHub has routed the account to a
            // direct Copilot host but omitted the route from /user.
            guard discoveredBase != nil else {
                throw LLMProviderError.providerError("GitHub Copilot 令牌交换失败（HTTP 404）。GitHub 未返回 Copilot API 路由，请确认 OAuth 应用已启用设备授权并重试。")
            }
            saveDirectToken(token, apiBaseURL: discoveredBase, instanceId: instanceId)
        }
    }

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = load(instanceId: instanceId), !storage.githubAccessToken.isEmpty else {
            throw LLMProviderError.noCredentials
        }
        if let cachedToken = cached[instanceId], cachedToken.expiresAt > Date().addingTimeInterval(60) {
            return cachedToken.value
        }
        if storage.usesGitHubTokenDirectly == true {
            cacheDirectToken(storage.githubAccessToken, instanceId: instanceId)
            return storage.githubAccessToken
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
            return try await self.refreshAccessToken(instanceId: instanceId, storage: storage)
        }
        inFlight[instanceId] = task
        defer { inFlight[instanceId] = nil }
        return try await task.value
    }

    private func refreshAccessToken(instanceId: String, storage: Storage) async throws -> String {
        do {
            let exchanged = try await exchangeForCopilotToken(githubToken: storage.githubAccessToken)
            saveExchange(exchanged, githubToken: storage.githubAccessToken, instanceId: instanceId)
            return exchanged.token
        } catch let failure as HTTPFailure where failure.statusCode == 404 {
            // Migrate tokens created by pre-v1.0.8 builds. They have no saved
            // route metadata, so discover it once and switch to direct-token
            // mode when GitHub reports an individual Copilot host.
            if let user = try? await fetchCopilotUser(githubToken: storage.githubAccessToken),
               let base = normalizedCopilotAPIBase(user.endpoints?.api),
               isDirectCopilotRoute(user: user, apiBaseURL: base) {
                saveDirectToken(storage.githubAccessToken, apiBaseURL: base, instanceId: instanceId)
                return storage.githubAccessToken
            }
            throw LLMProviderError.providerError("GitHub Copilot 令牌交换失败（HTTP 404）。请重新登录以刷新 Copilot 路由。")
        }
    }

    private func requestDeviceAuthorization() async throws -> DeviceAuthorization {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode(["client_id": clientID, "scope": "read:user"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.providerError("GitHub 登录请求没有返回 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.providerError("GitHub 登录请求失败（HTTP \(http.statusCode)）：\(bodySnippet(data))")
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
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LLMProviderError.providerError("GitHub 登录轮询失败（HTTP \(http.statusCode)）：\(bodySnippet(data))")
            }
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

    private func fetchCopilotUser(githubToken: String) async throws -> CopilotUserResponse {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitHubCopilot/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, body: bodySnippet(data))
        }
        return try JSONDecoder().decode(CopilotUserResponse.self, from: data)
    }

    private func exchangeForCopilotToken(githubToken: String) async throws -> CopilotTokenExchangeResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/v2/token")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(githubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("GitHubCopilot/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPFailure(statusCode: -1, body: "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPFailure(statusCode: http.statusCode, body: bodySnippet(data))
        }
        let result = try JSONDecoder().decode(CopilotTokenResponse.self, from: data)
        let expiry = result.expiresAt.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(1800)
        return CopilotTokenExchangeResult(
            token: result.token,
            expiresAt: expiry,
            apiBaseURL: normalizedCopilotAPIBase(result.endpoints?.api)
        )
    }

    private func saveExchange(_ result: CopilotTokenExchangeResult, githubToken: String, instanceId: String) {
        cached[instanceId] = CachedToken(value: result.token, expiresAt: result.expiresAt)
        let old = load(instanceId: instanceId)
        save(Storage(
            githubAccessToken: githubToken,
            copilotToken: result.token,
            copilotExpiresAt: result.expiresAt,
            copilotAPIBaseURL: result.apiBaseURL ?? old?.copilotAPIBaseURL,
            usesGitHubTokenDirectly: false
        ), instanceId: instanceId)
    }

    private func saveDirectToken(_ token: String, apiBaseURL: String?, instanceId: String) {
        cacheDirectToken(token, instanceId: instanceId)
        save(Storage(
            githubAccessToken: token,
            copilotToken: token,
            copilotExpiresAt: nil,
            copilotAPIBaseURL: apiBaseURL,
            usesGitHubTokenDirectly: true
        ), instanceId: instanceId)
    }

    private func cacheDirectToken(_ token: String, instanceId: String) {
        // The GitHub OAuth token remains the source of truth; this short cache
        // only prevents repeated Keychain reads while a request is built.
        cached[instanceId] = CachedToken(value: token, expiresAt: Date().addingTimeInterval(300))
    }

    private func isDirectCopilotRoute(user: CopilotUserResponse?, apiBaseURL: String?) -> Bool {
        let plan = user?.copilotPlan?.lowercased() ?? ""
        return plan.contains("individual")
            || plan.contains("free")
            || apiBaseURL?.contains("individual.githubcopilot.com") == true
    }

    private func normalizedCopilotAPIBase(_ raw: String?) -> String? {
        guard let raw, var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "githubcopilot.com" || host.hasSuffix(".githubcopilot.com") else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func load(instanceId: String) -> Storage? {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: Storage.self)
    }

    private func save(_ storage: Storage, instanceId: String) {
        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
    }

    private func bodySnippet(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "响应体不可读" }
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(compact.prefix(180))
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
    /// Account-specific Copilot API host returned by GitHub.
    var copilotAPIBaseURL: String?
    /// True when the GitHub OAuth token itself is the Copilot bearer token.
    /// Optional keeps Keychain records written before v1.0.8 decodable.
    var usesGitHubTokenDirectly: Bool?
}
