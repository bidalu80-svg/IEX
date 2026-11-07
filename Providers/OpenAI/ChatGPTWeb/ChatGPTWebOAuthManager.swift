import Foundation
import Combine
import UIKit
import WebKit
import CryptoKit
import Security

/// Experimental web-client authorization, intentionally separate from Codex.
/// Protocol reference: basketikun/chatgpt2api @ 92dd80e91543157d36a4ddad60e765c5293760e9.
/// This is a first-party web client flow, not a registered public Ze OAuth client.
struct ChatGPTWebTokenStorage: Codable, Sendable, RefreshableOAuthToken {
    let accessToken: String
    let refreshToken: String?
    let expireDate: Date
    // Required discriminator prevents decoding a Codex token as a web credential.
    let credentialKind: String
    var isExpired: Bool { expireDate <= Date() }

    init(accessToken: String, refreshToken: String?, expireDate: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expireDate = expireDate
        self.credentialKind = "chatGPTWeb"
    }
}

@MainActor
final class ChatGPTWebOAuthManager: ObservableObject {
    static let shared = ChatGPTWebOAuthManager()
    static let clientID = "app_2SKx67EdpoN0G6j64rFvigXD"
    static let redirectURI = "https://platform.openai.com/auth/callback"
    @Published private(set) var isAuthenticating = false
    private let refreshFlight = OAuthRefreshSingleFlight<ChatGPTWebTokenStorage>()
    private var generations: [String: UUID] = [:]
    private var browser: ChatGPTWebLoginController?
    private var loginInstanceId: String?

    private func storage(_ instanceId: String) -> ChatGPTWebTokenStorage? {
        guard let value = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: ChatGPTWebTokenStorage.self),
              value.credentialKind == "chatGPTWeb", !value.accessToken.isEmpty else { return nil }
        return value
    }

    func isAuthenticated(instanceId: String) -> Bool { storage(instanceId) != nil }
    func maskedToken(instanceId: String) -> String? {
        storage(instanceId).map { ClaudeOAuthManager.maskToken($0.accessToken) }
    }

    func login(instanceId: String) async throws {
        guard !isAuthenticating else {
            throw LLMError.providerError(message: "已有网页登录正在进行，请先完成或取消。")
        }
        let verifier = try Self.randomURLString()
        let state = try Self.randomURLString()
        let nonce = try Self.randomURLString()
        let challenge = Self.urlEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        components.queryItems = [
            .init(name: "issuer", value: "https://auth.openai.com"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "audience", value: "https://api.openai.com/v1"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "response_type", value: "code"),
            .init(name: "response_mode", value: "query"),
            .init(name: "screen_hint", value: "login_or_signup"),
            .init(name: "max_age", value: "0"),
            .init(name: "device_id", value: UUID().uuidString),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "auth0Client", value: "eyJuYW1lIjoiYXV0aDAtc3BhLWpzIiwidmVyc2lvbiI6IjEuMjEuMCJ9")
        ]
        guard let url = components.url,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            throw LLMError.providerError(message: "请回到前台后重新打开网页登录。")
        }
        while let next = presenter.presentedViewController { presenter = next }
        let generation = UUID()
        generations[instanceId] = generation
        isAuthenticating = true
        loginInstanceId = instanceId
        let controller = ChatGPTWebLoginController(url: url, expectedState: state)
        controller.onUserCancel = { [weak self] in
            guard self?.generations[instanceId] == generation else { return }
            self?.generations[instanceId] = UUID()
        }
        browser = controller
        defer {
            controller.stop()
            controller.navigationController?.dismiss(animated: true)
            browser = nil
            loginInstanceId = nil
            isAuthenticating = false
        }
        let code = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await controller.authorize(presenting: presenter)
        }, onCancel: {
            Task { @MainActor in controller.cancel() }
        })
        try Task.checkCancellation()
        let token = try await Self.requestToken([
            "client_id": Self.clientID, "grant_type": "authorization_code",
            "code": code, "code_verifier": verifier, "redirect_uri": Self.redirectURI
        ], previousRefreshToken: nil)
        try Task.checkCancellation()
        guard generations[instanceId] == generation else { throw CancellationError() }
        ProviderKeychainHelper.saveOAuthToken(token, instanceId: instanceId)
        guard storage(instanceId)?.accessToken == token.accessToken else {
            throw LLMError.providerError(message: "登录凭据保存失败，请重试。")
        }
    }

    func cancelLogin() {
        if let id = loginInstanceId { generations[id] = UUID() }
        browser?.cancel()
    }

    func logout(instanceId: String) {
        generations[instanceId] = UUID()
        if loginInstanceId == instanceId { cancelLogin() }
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    func validAccessToken(instanceId: String) async throws -> String {
        guard let current = storage(instanceId) else {
            throw LLMError.invalidAPIKey(detail: "请先完成 ChatGPT 网页登录。")
        }
        if current.expireDate.timeIntervalSinceNow > 300 { return current.accessToken }
        guard let refresh = current.refreshToken, !refresh.isEmpty else {
            if !current.isExpired { return current.accessToken }
            throw LLMError.invalidAPIKey(detail: "网页登录已过期，请重新登录。")
        }
        let generation = generations[instanceId] ?? UUID()
        generations[instanceId] = generation
        let renewed = try await refreshFlight.run(instanceId: instanceId) { [self] in
            guard generations[instanceId] == generation else { throw CancellationError() }
            // A late caller may have read the old token before a completed rotation.
            guard let latest = storage(instanceId) else { throw CancellationError() }
            if latest.accessToken != current.accessToken { return latest }
            let value = try await Self.requestToken([
                "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refresh
            ], previousRefreshToken: refresh)
            guard generations[instanceId] == generation,
                  storage(instanceId)?.refreshToken == refresh else { throw CancellationError() }
            ProviderKeychainHelper.saveOAuthToken(value, instanceId: instanceId)
            guard storage(instanceId)?.accessToken == value.accessToken else {
                throw LLMError.providerError(message: "更新后的登录凭据保存失败。")
            }
            return value
        }
        guard generations[instanceId] == generation else { throw CancellationError() }
        return renewed.accessToken
    }

    private static func requestToken(_ body: [String: String], previousRefreshToken: String?) async throws -> ChatGPTWebTokenStorage {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://platform.openai.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.openai.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            // Never propagate an OAuth response body: it may include credentials or PII.
            if http.statusCode == 401 {
                throw LLMError.invalidAPIKey(detail: "网页登录授权已失效，请重新登录。")
            }
            throw LLMError.providerError(message: "网页授权请求失败（HTTP \(http.statusCode)）。请重新登录；网页验证或服务策略变化也可能导致此错误。")
        }
        return try ChatGPTWebAuthProtocol.decodeToken(data, previousRefreshToken: previousRefreshToken)
    }

    private static func randomURLString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LLMError.providerError(message: "生成登录校验信息失败。")
        }
        return urlEncoded(Data(bytes))
    }

    private static func urlEncoded(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// BEGIN ChatGPTWebAuthProtocol
/// Validation shared by the live browser/token client and deterministic fixtures.
enum ChatGPTWebAuthProtocol {
    /// OAuth response_mode=query reads authorization values only from the query.
    /// Fragments (such as #_=_) do not change callback identity.
    static func isCallbackURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "platform.openai.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
            // URL.path applies filesystem-style normalization on Foundation
            // (notably a trailing slash). Match the actual encoded URL path.
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/auth/callback"
    }

    static func callbackCode(_ url: URL, expectedState: String) throws -> String {
        guard isCallbackURL(url) else {
            throw LLMError.providerError(message: "网页登录回调地址校验失败。")
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = items.filter { $0.name == "state" }
        let codes = items.filter { $0.name == "code" }
        guard !expectedState.isEmpty, states.count == 1, states.first?.value == expectedState,
              codes.count == 1, let code = codes.first?.value, !code.isEmpty,
              !items.contains(where: { $0.name == "error" }) else {
            throw LLMError.providerError(message: "网页登录回调校验失败，请重新登录。")
        }
        return code
    }

    static func decodeToken(_ data: Data, previousRefreshToken: String?, now: Date = Date()) throws -> ChatGPTWebTokenStorage {
        struct Response: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard !result.access_token.isEmpty else { throw URLError(.cannotParseResponse) }
        // JWT expiry is only a scheduling hint; no identity/authorization claims are trusted.
        let expiry: Date?
        if let seconds = result.expires_in, seconds.isFinite, seconds > 0 {
            expiry = now.addingTimeInterval(seconds)
        } else {
            let parts = result.access_token.split(separator: ".")
            if parts.count == 3 {
                var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base += String(repeating: "=", count: (4 - base.count % 4) % 4)
                if let raw = Data(base64Encoded: base),
                   let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                   let exp = json["exp"] as? Double, exp.isFinite {
                    expiry = Date(timeIntervalSince1970: exp)
                } else { expiry = nil }
            } else { expiry = nil }
        }
        guard let expiry, expiry > now else {
            throw LLMError.providerError(message: "网页授权未返回有效的凭据有效期。")
        }
        let refresh = result.refresh_token.flatMap { $0.isEmpty ? nil : $0 } ?? previousRefreshToken
        return ChatGPTWebTokenStorage(accessToken: result.access_token, refreshToken: refresh, expireDate: expiry)
    }

}
// END ChatGPTWebAuthProtocol

/// The vendor's HTTPS callback cannot be redirected to an unregistered app URI.
/// Capture only that exact navigation inside an isolated browser; do not request passwords.
@MainActor
private final class ChatGPTWebLoginController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let url: URL
    private let expectedState: String
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false
    var onUserCancel: (() -> Void)?

    init(url: URL, expectedState: String) {
        self.url = url
        self.expectedState = expectedState
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ChatGPT 网页登录（实验）"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        view = webView
        webView.load(URLRequest(url: url))
    }

    func authorize(presenting presenter: UIViewController) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            guard !finished else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let navigation = UINavigationController(rootViewController: self)
            navigation.modalPresentationStyle = .pageSheet
            navigation.presentationController?.delegate = self
            presenter.present(navigation, animated: true)
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000_000) }
                catch { return }
                self?.finish(.failure(LLMError.providerError(message: "网页登录已超时，请重新打开。")))
            }
        }
    }

    @objc func cancel() {
        onUserCancel?()
        finish(.failure(CancellationError()))
        navigationController?.dismiss(animated: true)
    }
    func stop() { timeoutTask?.cancel(); webView?.stopLoading() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { cancel() }

    private func finish(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        stop()
        let saved = continuation
        continuation = nil
        saved?.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { decisionHandler(.cancel); return }
        if ChatGPTWebAuthProtocol.isCallbackURL(target), action.targetFrame?.isMainFrame == true {
            decisionHandler(.cancel)
            do {
                finish(.success(try ChatGPTWebAuthProtocol.callbackCode(target, expectedState: expectedState)))
            } catch { finish(.failure(error)) }
            return
        }
        decisionHandler(target.scheme == "https" || target.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, action.request.url?.scheme == "https" { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(LLMError.providerError(message: "登录网页加载失败，请检查网络后重试。")))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(LLMError.providerError(message: "登录网页加载中断，请重新登录。")))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(LLMError.providerError(message: "登录网页已关闭，请重新登录。")))
    }
}
