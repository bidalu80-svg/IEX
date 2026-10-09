import Foundation
import Combine
import Security
import CryptoKit
import AuthenticationServices
import UIKit

/// The connector uses Ze's own installed-app OAuth client, never another provider's ID.
@MainActor
final class GmailConnector: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GmailConnector()
    static let readScope = "https://www.googleapis.com/auth/gmail.readonly"
    @Published private(set) var accounts: [GmailAccount] = []
    @Published private(set) var signingIn = false
    @Published private(set) var storageError: String?
    private struct Record: Codable { var account: GmailAccount; var token: GmailToken }
    private var records: [Record] = []
    private var access = MailAccessTracker()
    private var authSession: ASWebAuthenticationSession?
    private var authSessionID: UUID?
    private var authContinuation: CheckedContinuation<URL, Error>?
    private struct RefreshFlight { let id: UUID; let task: Task<GmailToken, Error> }
    private var refreshes: [UUID: RefreshFlight] = [:]
    private var disconnecting = Set<UUID>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
        return URLSession(configuration: config)
    }()
    private override init() { super.init(); reload() }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.ze.gmail.oauth.v1",
         kSecAttrAccount as String: "accounts", kSecAttrSynchronizable as String: false]
    }
    private var clientID: String { Bundle.main.object(forInfoDictionaryKey: "GmailOAuthClientID") as? String ?? "" }
    private var callbackScheme: String { Bundle.main.object(forInfoDictionaryKey: "GmailOAuthCallbackScheme") as? String ?? "" }
    var configurationReady: Bool {
        guard clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("$("),
              callbackScheme == clientID.split(separator: ".").reversed().joined(separator: ".") else { return false }
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(callbackScheme) }
    }
    var configurationMessage: String {
        "此安装包尚未配置 Ze 专用的 Google iOS OAuth 客户端。开发者需在 Google Cloud 为 com.ze.app 创建客户端、启用 Gmail API，并配置只读权限同意页后重新编译；这不是邮箱密码或 API Key。"
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func reload() {
        access.reset(ids: [])
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        do {
            if status == errSecItemNotFound { records = [] }
            else {
                guard status == errSecSuccess, let data = result as? Data else { throw MailError.message("请解锁设备后重新读取邮箱连接。") }
                records = try JSONDecoder().decode([Record].self, from: data)
            }
            access.reset(ids: records.map { $0.account.id })
            accounts = records.map(\.account); storageError = nil
        } catch { storageError = "读取 Google 授权失败，已保留原凭据，请解锁设备后重试。" }
    }
    private func persist(_ updated: [Record]) throws {
        guard storageError == nil else { throw MailError.message(storageError!) }
        let data = try JSONEncoder().encode(updated)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw MailError.message("保存 Google 授权失败（\(status)），原有连接已保留。") }
        let changed = Set(updated.filter { value in
            records.first(where: { $0.account.id == value.account.id })?.account != value.account
        }.map { $0.account.id })
        access.synchronize(ids: updated.map { $0.account.id }, changed: changed)
        records = updated; accounts = updated.map(\.account)
    }
    private func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MailError.message("生成登录校验参数失败，请重试。") }
        return GmailEncoding.encode(Data(bytes))
    }
    func signIn() async throws {
        guard configurationReady else { throw MailError.message(configurationMessage) }
        guard !signingIn, storageError == nil else { throw MailError.message("登录正在进行，或邮箱凭据暂未解锁。") }
        signingIn = true; defer { signingIn = false }
        let verifier = try randomToken(), state = try randomToken()
        let redirect = callbackScheme + ":/oauthredirect"
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code",
            "scope": Self.readScope, "state": state, "code_challenge": GmailEncoding.encode(Data(SHA256.hash(data: Data(verifier.utf8)))),
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let callback = try await authenticate(url.url!)
        try Task.checkCancellation()
        guard callback.scheme == callbackScheme, callback.path == "/oauthredirect", callback.host == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw MailError.message("Google 登录回调地址无效。") }
        let values = components.queryItems ?? []
        guard values.filter({ $0.name == "state" }).count == 1, values.first(where: { $0.name == "state" })?.value == state else {
            throw MailError.message("登录校验不匹配，请重新登录。")
        }
        guard values.first(where: { $0.name == "error" }) == nil,
              values.filter({ $0.name == "code" }).count == 1,
              let code = values.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw MailError.message("Google 授权未完成或已取消。") }
        let reply: GmailTokenReply = try await tokenRequest(["client_id": clientID, "code": code, "code_verifier": verifier,
            "redirect_uri": redirect, "grant_type": "authorization_code"])
        guard reply.scope?.split(separator: " ").contains(Substring(Self.readScope)) ?? true else {
            throw MailError.message("未授予 Gmail 只读权限，请重新授权。")
        }
        // Profile is only available after Gmail authorization; never trust an email from the callback.
        let profile: GmailProfile = try await request(path: "profile", token: reply.access_token)
        guard MailCodec.validAddress(profile.emailAddress) else { throw MailError.message("Google 返回的邮箱资料无效。") }
        let old = records.first { $0.account.address.lowercased() == profile.emailAddress.lowercased() }
        guard let refresh = reply.refresh_token ?? old?.token.refreshToken, !refresh.isEmpty else {
            throw MailError.message("Google 未返回持续访问凭据，请在 Google 账号中移除 Ze 授权后重新连接。")
        }
        let account = old?.account ?? GmailAccount(address: profile.emailAddress)
        let token = GmailToken(accessToken: reply.access_token, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(reply.expires_in), clientID: clientID)
        var updated = records.filter { $0.account.id != account.id }; updated.append(Record(account: account, token: token))
        try Task.checkCancellation()
        try persist(updated)
        access.invalidate(account.id)
    }
    func cancelSignIn() {
        authSession?.cancel(); finishAuthentication(.failure(CancellationError()))
    }
    private func finishAuthentication(_ result: Result<URL, Error>) {
        let cont = authContinuation; authContinuation = nil; authSession = nil; authSessionID = nil; cont?.resume(with: result)
    }
    private func authenticate(_ url: URL) async throws -> URL {
        let sessionID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                authContinuation = continuation
                authSessionID = sessionID
                let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, _ in
                    Task { @MainActor in
                        guard self?.authSessionID == sessionID else { return }
                        if let callback { self?.finishAuthentication(.success(callback)) }
                        else { self?.finishAuthentication(.failure(MailError.message("Google 登录已取消或未完成。"))) }
                    }
                }
                auth.presentationContextProvider = self
                // Use the system account session, not an embedded WebView or copied cookies.
                auth.prefersEphemeralWebBrowserSession = false
                authSession = auth
                if !auth.start() { finishAuthentication(.failure(MailError.message("打开 Google 登录失败，请稍后重试。"))) }
            }
        }, onCancel: { Task { @MainActor in
            if self.authSessionID == sessionID { self.cancelSignIn() }
        } })
    }
    func setEnabled(id: UUID, enabled: Bool) throws {
        guard let index = records.firstIndex(where: { $0.account.id == id }) else { throw MailError.message("邮箱连接已删除。") }
        var updated = records; updated[index].account.agentEnabled = enabled; try persist(updated)
    }
    func disconnect(id: UUID) async throws -> String {
        guard let record = records.first(where: { $0.account.id == id }), !disconnecting.contains(id) else { throw MailError.message("连接已删除或正在解除。") }
        disconnecting.insert(id); defer { disconnecting.remove(id) }
        refreshes[id]?.task.cancel(); refreshes[id] = nil
        // Local removal happens first so the model loses access even while offline.
        try persist(records.filter { $0.account.id != id })
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = GmailEncoding.form(["token": record.token.refreshToken])
        if let (_, response) = try? await session.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200 {
            return "本机连接和 Google 授权已解除。"
        }
        return "本机连接已解除；Google 端撤销尚未确认，可在 Google 账号 → 第三方连接中移除 Ze。"
    }
    func authorized(_ id: UUID) throws -> GmailAccount {
        guard storageError == nil, !disconnecting.contains(id), let account = accounts.first(where: { $0.id == id && $0.agentEnabled }) else {
            throw MailError.message("此 Gmail 账号未连接、访问已关闭或凭据尚未解锁。")
        }
        return account
    }
    func accessTicket(for id: UUID) throws -> MailAccessTicket {
        _ = try authorized(id)
        return try access.ticket(for: id)
    }
    func validateAccess(_ ticket: MailAccessTicket) throws {
        _ = try authorized(ticket.accountID)
        try access.validate(ticket)
    }
    private func accessToken(_ id: UUID) async throws -> String {
        let ticket = try accessTicket(for: id)
        guard let original = records.first(where: { $0.account.id == id }) else { throw MailError.message("邮箱连接已删除。") }
        if original.token.expiresAt > Date().addingTimeInterval(60) { return original.token.accessToken }
        if let ongoing = refreshes[id] { return try await MailAsyncWait.value(ongoing.task).accessToken }
        let flightID = UUID()
        let task = Task { @MainActor in
            defer { if self.refreshes[id]?.id == flightID { self.refreshes[id] = nil } }
            let reply: GmailTokenReply = try await self.tokenRequest(["client_id": original.token.clientID,
                "refresh_token": original.token.refreshToken, "grant_type": "refresh_token"])
            let token = GmailToken(accessToken: reply.access_token, refreshToken: reply.refresh_token ?? original.token.refreshToken,
                expiresAt: Date().addingTimeInterval(reply.expires_in), clientID: original.token.clientID)
            try self.validateAccess(ticket)
            guard let index = self.records.firstIndex(where: { $0.account.id == id }),
                  self.records[index].token.refreshToken == original.token.refreshToken else { throw MailError.message("邮箱授权已变更，请重试。") }
            var updated = self.records; updated[index].token = token; try self.persist(updated)
            return token
        }
        refreshes[id] = RefreshFlight(id: flightID, task: task)
        return try await MailAsyncWait.value(task).accessToken
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> GmailTokenReply {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"; req.httpBody = GmailEncoding.form(fields)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError.message("Google 授权交换或续期失败，请检查应用 OAuth 配置并重新连接邮箱。") }
        return try JSONDecoder().decode(GmailTokenReply.self, from: data)
    }
    private func request<T: Decodable>(path: String, query: [URLQueryItem] = [], token: String) async throws -> T {
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        url.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: url.url!); req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MailError.message("Gmail 请求失败（\(status)）。401/403 请重新授权或检查 Gmail API 与只读权限；429 请稍后重试。")
        }
        guard data.count < 12_000_000 else { throw MailError.message("邮件内容过大，请选择较小邮件。") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func search(id: UUID, query: String, pageToken: String? = nil, limit: Int = 10, includeSpamTrash: Bool = false) async throws -> GmailMessageList {
        guard query.count <= 1000, (pageToken?.count ?? 0) <= 2000 else { throw MailError.message("搜索参数过长。") }
        let ticket = try accessTicket(for: id)
        let token = try await accessToken(id)
        try validateAccess(ticket)
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "maxResults", value: String(min(max(limit, 1), 20)))]
        if includeSpamTrash { items.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let result: GmailMessageList = try await request(path: "messages", query: items, token: token)
        try validateAccess(ticket); return result
    }
    func read(id: UUID, messageID: String, metadataOnly: Bool = false) async throws -> GmailMessage {
        guard !messageID.isEmpty, messageID.count <= 128, messageID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw MailError.message("邮件 ID 无效。") }
        let ticket = try accessTicket(for: id)
        let token = try await accessToken(id)
        try validateAccess(ticket)
        let result: GmailMessage = try await request(path: "messages/" + messageID,
            query: [URLQueryItem(name: "format", value: metadataOnly ? "metadata" : "full")], token: token)
        try validateAccess(ticket); return result
    }
}
