import Foundation
import Combine

enum WorkBuddyRealm: String, Codable, CaseIterable, Sendable {
    case cn, global

    var baseURL: String { self == .cn ? "https://copilot.tencent.com" : "https://www.workbuddy.ai" }
    var origin: String { self == .cn ? "https://www.codebuddy.cn" : "https://www.workbuddy.ai" }
    var displayName: String { self == .cn ? "国内版" : "国际版" }
}

struct WorkBuddyTokenStorage: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    let realm: WorkBuddyRealm
    let uid: String
    let enterpriseID: String?
    var domain: String?
    let nickname: String?
    var deviceToken: String?
}

enum WorkBuddyError: LocalizedError {
    case message(String)
    case http(Int)
    case business(Int, String)
    case authorizationPending

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(let status): return "WorkBuddy 请求失败（HTTP \(status)）。"
        case .business(let code, let message): return "WorkBuddy：\(message)（\(code)）"
        case .authorizationPending: return "等待 WorkBuddy 浏览器授权…"
        }
    }
}

/// The service issues a browser URL and state; it does not use an app callback.
/// Protocol sources, pinned revisions and the unverified device-token limitation
/// are recorded in docs/workbuddy-oauth-reference.md.
@MainActor
final class WorkBuddyOAuthManager: ObservableObject {
    static let shared = WorkBuddyOAuthManager()

    private struct LoginState: Decodable { let state: String; let authUrl: String }
    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let domain: String?
    }
    private struct Account: Decodable {
        let uid: String
        let enterpriseId: String?
        let nickname: String?
    }
    private var generations: [String: UUID] = [:]
    private var loginTasks: [String: Task<Void, Error>] = [:]
    private var refreshTasks: [String: (id: UUID, task: Task<WorkBuddyTokenStorage, Error>)] = [:]

    private let httpSession: URLSession?

    init(configuration: URLSessionConfiguration? = nil) {
        httpSession = configuration.map { WorkBuddyHTTP.makeSession(configuration: $0) }
    }

    func isAuthenticated(instanceId: String) -> Bool {
        guard let token = load(instanceId: instanceId) else { return false }
        return !token.accessToken.isEmpty && !token.uid.isEmpty
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = load(instanceId: instanceId)?.accessToken, token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func accountName(instanceId: String) -> String? {
        guard let token = load(instanceId: instanceId) else { return nil }
        return token.nickname?.isEmpty == false ? token.nickname : token.uid
    }

    func realm(instanceId: String) -> WorkBuddyRealm? { load(instanceId: instanceId)?.realm }

    func credentialSession(instanceId: String) -> UUID {
        if let value = generations[instanceId] { return value }
        let value = UUID()
        generations[instanceId] = value
        return value
    }

    func cancelLogin(instanceId: String) {
        generations[instanceId] = UUID()
        loginTasks.removeValue(forKey: instanceId)?.cancel()
        WorkBuddyModelsAPI.invalidate(instanceId: instanceId)
    }

    func logout(instanceId: String) {
        cancelLogin(instanceId: instanceId)
        refreshTasks.removeValue(forKey: instanceId)?.task.cancel()
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    func login(instanceId: String, realm: WorkBuddyRealm = .cn, present: @escaping (URL) -> Void) async throws {
        cancelLogin(instanceId: instanceId)
        refreshTasks.removeValue(forKey: instanceId)?.task.cancel()
        let generation = UUID()
        generations[instanceId] = generation
        let task = Task { @MainActor in
            let stateData = try await WorkBuddyHTTP.data(realm: realm, path: "/v2/plugin/auth/state", method: "POST",
                query: [URLQueryItem(name: "platform", value: "CLI")], body: Data("{}".utf8), login: true, session: httpSession)
            let state = try JSONDecoder().decode(LoginState.self, from: stateData)
            guard !state.state.isEmpty, let url = URL(string: state.authUrl), url.scheme == "https",
                  let host = url.host?.lowercased(), Self.isAuthorizationHost(host, realm: realm),
                  url.user == nil, url.password == nil else {
                throw WorkBuddyError.message("WorkBuddy 返回了无效的授权地址。")
            }
            try self.checkGeneration(instanceId, generation)
            present(url)
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                try self.checkGeneration(instanceId, generation)
                let tokenData: Data
                do {
                    tokenData = try await WorkBuddyHTTP.data(realm: realm, path: "/v2/plugin/auth/token", query: [URLQueryItem(name: "state", value: state.state)], login: true, session: httpSession)
                } catch WorkBuddyError.authorizationPending {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                let token = try JSONDecoder().decode(Token.self, from: tokenData)
                guard !token.accessToken.isEmpty else { throw WorkBuddyError.message("WorkBuddy 未返回访问令牌。") }
                let accountData = try await WorkBuddyHTTP.data(realm: realm, path: "/v2/plugin/login/account",
                    query: [URLQueryItem(name: "state", value: state.state)], headers: ["Authorization": "Bearer \(token.accessToken)"], login: true, session: httpSession)
                let account = try JSONDecoder().decode(Account.self, from: accountData)
                guard !account.uid.isEmpty else { throw WorkBuddyError.message("WorkBuddy 未返回账号信息。") }
                let storage = WorkBuddyTokenStorage(accessToken: token.accessToken, refreshToken: token.refreshToken ?? "",
                    expiresAt: Self.expiry(token.expiresIn), realm: realm, uid: account.uid,
                    enterpriseID: account.enterpriseId, domain: token.domain, nickname: account.nickname, deviceToken: nil)
                try self.checkGeneration(instanceId, generation)
                try self.save(storage, instanceId: instanceId)
                return
            }
            throw WorkBuddyError.message("WorkBuddy 授权已超时，请重新登录。")
        }
        loginTasks[instanceId] = task
        defer {
            if generations[instanceId] == generation { loginTasks[instanceId] = nil }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    func validAccessToken(instanceId: String) async throws -> String {
        try await validCredentials(instanceId: instanceId).accessToken
    }

    func validCredentials(instanceId: String) async throws -> WorkBuddyTokenStorage {
        try Task.checkCancellation()
        guard let stored = load(instanceId: instanceId), !stored.accessToken.isEmpty else {
            throw WorkBuddyError.message("请先登录 WorkBuddy。")
        }
        if stored.expiresAt > Date().addingTimeInterval(90) { return stored }
        if let running = refreshTasks[instanceId] {
            let generation = generations[instanceId]
            let result = try await running.task.value
            try Task.checkCancellation()
            guard generations[instanceId] == generation, load(instanceId: instanceId) == result else { throw CancellationError() }
            return result
        }
        guard !stored.refreshToken.isEmpty else { throw WorkBuddyError.message("WorkBuddy 登录已过期，请重新登录。") }
        let generation = generations[instanceId] ?? UUID()
        generations[instanceId] = generation
        let flightID = UUID()
        let task = Task { @MainActor in
            var headers = ["X-Refresh-Token": stored.refreshToken, "X-Auth-Refresh-Source": "plugin"]
            if let enterprise = stored.enterpriseID, !enterprise.isEmpty { headers["X-Enterprise-Id"] = enterprise }
            let data = try await WorkBuddyHTTP.data(realm: stored.realm, path: "/v2/plugin/auth/token/refresh", method: "POST", headers: headers, session: httpSession)
            let response = try JSONDecoder().decode(Token.self, from: data)
            guard !response.accessToken.isEmpty else { throw WorkBuddyError.message("WorkBuddy 令牌刷新失败，请重新登录。") }
            try self.checkGeneration(instanceId, generation)
            guard self.load(instanceId: instanceId) == stored else { throw CancellationError() }
            var refreshed = stored
            refreshed.accessToken = response.accessToken
            if let value = response.refreshToken, !value.isEmpty { refreshed.refreshToken = value }
            if let value = response.domain, !value.isEmpty { refreshed.domain = value }
            refreshed.expiresAt = Self.expiry(response.expiresIn)
            try self.save(refreshed, instanceId: instanceId)
            return refreshed
        }
        refreshTasks[instanceId] = (flightID, task)
        defer { if refreshTasks[instanceId]?.id == flightID { refreshTasks[instanceId] = nil } }
        let result = try await task.value
        try checkGeneration(instanceId, generation)
        guard load(instanceId: instanceId) == result else { throw CancellationError() }
        return result
    }

    private func load(instanceId: String) -> WorkBuddyTokenStorage? {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self)
    }

    private func save(_ token: WorkBuddyTokenStorage, instanceId: String) throws {
        ProviderKeychainHelper.saveOAuthToken(token, instanceId: instanceId)
        guard load(instanceId: instanceId) == token else { throw WorkBuddyError.message("WorkBuddy 登录信息保存失败，请重试。") }
    }

    private func checkGeneration(_ instanceId: String, _ generation: UUID) throws {
        try Task.checkCancellation()
        guard generations[instanceId] == generation else { throw CancellationError() }
    }

    static func expiry(_ seconds: Double?) -> Date {
        // Missing expiry is short-lived, never an invented permanent session.
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 315_360_000 else {
            return Date().addingTimeInterval(300)
        }
        return Date().addingTimeInterval(seconds)
    }

    nonisolated static func isPending(_ message: String) -> Bool {
        let normalized = message.lowercased().replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…").union(.whitespacesAndNewlines))
        return normalized == "logining" || normalized == "authorization_pending"
    }

    static func isAuthorizationHost(_ host: String, realm: WorkBuddyRealm) -> Bool {
        let domains = realm == .cn ? ["codebuddy.cn", "copilot.tencent.com"] : ["workbuddy.ai", "codebuddy.ai"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Only contacts fixed service hosts. A rejected/redirected RPC never leaks
/// access or refresh credentials to an unrelated host through URLSession.
enum WorkBuddyHTTP {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private static let session = makeSession(configuration: .ephemeral)

    // Explicit configuration also makes isolated protocol fixtures deterministic.
    // All sessions, including injected fixtures, retain the redirect rejection.
    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    static func commonHeaders(realm: WorkBuddyRealm, login: Bool = false) -> [String: String] {
        let platform = realm == .cn ? "WorkBuddy" : "WorkBuddy AI"
        return ["Content-Type": "application/json", "Accept": "application/json",
                "Origin": realm.origin, "Referer": realm.origin + "/", "X-Requested-With": "XMLHttpRequest",
                "X-CodeBuddy-Request": "1", "Accept-Language": realm == .cn ? "zh-CN" : "en-US",
                "User-Agent": login ? "CLI/2.63.2 CodeBuddy/2.63.2" : "WorkBuddy/5.5.4 \(platform)/5.5.4 CLI/2.137.1"]
    }

    static func data(realm: WorkBuddyRealm, path: String, method: String = "GET", query: [URLQueryItem] = [],
                     body: Data? = nil, headers: [String: String] = [:], login: Bool = false, session: URLSession? = nil) async throws -> Data {
        guard var components = URLComponents(string: realm.baseURL) else { throw WorkBuddyError.message("WorkBuddy 地址配置错误。") }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw WorkBuddyError.message("WorkBuddy 请求地址错误。") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in commonHeaders(realm: realm, login: login).merging(headers, uniquingKeysWith: { _, new in new }) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await (session ?? Self.session).data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw WorkBuddyError.message("WorkBuddy 未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else { throw WorkBuddyError.http(http.statusCode) }
        return try payload(from: data, authorizationPoll: login && method == "GET" && path == "/v2/plugin/auth/token")
    }

    static func payload(from data: Data, authorizationPoll: Bool = false) throws -> Data {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = envelope["code"] as? Int else { throw WorkBuddyError.message("WorkBuddy 响应格式错误。") }
        guard code == 0 else {
            let message = envelope["msg"] as? String ?? "请求失败"
            // CN and global anonymously verified on 2026-11-07: a fresh,
            // unapproved state returns HTTP 200 / 11217 / "login ing...".
            // Classify before redaction and only at the login polling endpoint;
            // other RPCs must never turn a business failure into a retry loop.
            if authorizationPoll && (code == 11217 || WorkBuddyOAuthManager.isPending(message)) {
                throw WorkBuddyError.authorizationPending
            }
            throw WorkBuddyError.business(code, "请求失败，请检查账号状态后重试")
        }
        guard let payload = envelope["data"], JSONSerialization.isValidJSONObject(payload) else {
            throw WorkBuddyError.message("WorkBuddy 响应缺少数据。")
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
