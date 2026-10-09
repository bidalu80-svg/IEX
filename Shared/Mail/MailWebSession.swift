import Foundation
import Combine
import WebKit

enum MailWebProvider: String, CaseIterable, Identifiable {
    case gmail, qq
    var id: String { rawValue }
    var title: String { self == .gmail ? "Gmail" : "QQ 邮箱" }
    var home: URL { URL(string: self == .gmail ? "https://mail.google.com/" : "https://mail.qq.com/")! }
    var storeID: UUID { UUID(uuidString: self == .gmail ? "49BCA8C5-78A8-47CC-B080-516C5913BA10" : "49BCA8C5-78A8-47CC-B080-516C5913BA11")! }
    func contains(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return self == .gmail ? host == "mail.google.com" : (host == "mail.qq.com" || host.hasSuffix(".mail.qq.com"))
    }
}

/// The settings screen and mail_web tool hold THIS SAME WKWebView. No Safari
/// cookie import, API tokens, password capture or general browser cookie backup.
@MainActor
final class MailWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let provider: MailWebProvider
    let webView: WKWebView
    @Published private(set) var status = "尚未打开邮箱网页"
    @Published private(set) var pageURL = ""
    @Published private(set) var loading = false
    @Published private(set) var enabled = false
    @Published private(set) var clearing = false
    @Published private(set) var manual = false
    private(set) var generation = UUID()
    private var busy = false
    private var observations: [NSKeyValueObservation] = []
    // Permission is intentionally not persisted. On relaunch the user verifies
    // the restored mailbox before giving the model access to private content.
    init(provider: MailWebProvider, dataStore: WKWebsiteDataStore? = nil) {
        self.provider = provider
        let config = WKWebViewConfiguration()
        if let dataStore { config.websiteDataStore = dataStore }
        else if #available(iOS 17.0, *) { config.websiteDataStore = WKWebsiteDataStore(forIdentifier: provider.storeID) }
        else { config.websiteDataStore = .nonPersistent() }
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.pageURL = view.url?.absoluteString ?? "" }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.loading = view.isLoading }
            }
        ]
    }
    var persistent: Bool { webView.configuration.websiteDataStore.isPersistent }
    func beginManual() {
        manual = true; generation = UUID(); webView.stopLoading()
        if webView.url == nil { openHome() }
    }
    func endManual() { manual = false; generation = UUID() }
    func openHome() {
        guard !clearing else { return }
        revoke(); status = "请在网页中亲自完成登录及二次验证"
        webView.load(URLRequest(url: provider.home))
    }
    func revoke() { enabled = false; generation = UUID() }
    func verifyAndEnable() async {
        guard !clearing else { return }
        let version = generation
        do {
            let value = try await evaluate(MailWebScripts.inspect(provider: provider, includeText: false))
            guard generation == version, !clearing else { return }
            guard value["mailbox"] as? Bool == true else {
                revoke(); status = "尚未检测到邮箱界面。请完成登录；若网页提示浏览器受限，此登录尚未成功。"; return
            }
            enabled = true; generation = UUID(); status = "已检测到邮箱界面，允许智能体使用此网页会话"
        } catch { revoke(); status = "检查网页失败：\(error.localizedDescription)" }
    }
    func disconnect() async {
        guard !clearing else { return }
        clearing = true; revoke(); webView.stopLoading()
        // Replacing the document first prevents its scripts from rewriting cookies
        // while the isolated provider store is being erased.
        webView.loadHTMLString("<html><body>邮箱连接已解除</body></html>", baseURL: nil)
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        clearing = false; status = "已清除此邮箱专用网页会话；其他浏览器登录不受影响"
    }
    func accessVersion() throws -> UUID {
        try Task.checkCancellation()
        guard enabled, !manual, !clearing, !loading, provider.contains(webView.url) else {
            throw MailError.message("请在设置 → 邮箱 → \(provider.title) 中完成网页登录，点击允许智能体使用，再返回聊天。登录/手动操作期间不读取网页。")
        }
        return generation
    }
    func validate(_ version: UUID) throws {
        guard try accessVersion() == version else { throw MailError.message("网页会话已变更，旧操作已取消。") }
    }
    func perform(action: String, snapshot: String?, index: Int?, text: String?) async throws -> [String: Any] {
        let version = try accessVersion()
        guard !busy else { throw MailError.message("此邮箱网页正在处理另一项操作，请稍后重试。") }
        busy = true; defer { busy = false }
        let script: String
        if action == "read" { script = MailWebScripts.inspect(provider: provider, includeText: true) }
        else {
            guard ["click", "type", "submit_search", "describe"].contains(action), let snapshot,
                  let index, index >= 0, index < 150, (text?.count ?? 0) <= 1000 else {
                throw MailError.message("请先 read，使用返回的 snapshot 和 element index 操作网页。")
            }
            script = MailWebScripts.interact(provider: provider, action: action, snapshot: snapshot, index: index, text: text ?? "")
        }
        let result = try await evaluate(script)
        // A click may navigate; do not expose automatic post-click page text.
        // Read requires a fresh permission/domain/readiness check on the next call.
        guard enabled, generation == version, !manual, !clearing else { throw MailError.message("邮箱权限已变更，旧结果已丢弃。") }
        try Task.checkCancellation()
        if action == "read" {
            try validate(version)
            guard result["mailbox"] as? Bool == true else {
                revoke(); status = "登录状态需要重新确认"
                throw MailError.message("未检测到邮箱界面，可能已退出登录。请重新打开邮箱网页登录。")
            }
        }
        return result
    }
    private func evaluate(_ script: String) async throws -> [String: Any] {
        try Task.checkCancellation()
        let webView = self.webView
        let task = Task<String, Error> { @MainActor in
            let value = try await webView.evaluateJavaScript(script, in: nil, in: .defaultClient)
            guard let dictionary = value as? [String: Any] else { throw MailError.message("邮箱网页未返回有效结果。") }
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            return String(decoding: data, as: UTF8.self)
        }
        let json = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await MailAsyncWait.value(task) }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw MailError.message("网页操作超时，结果尚未确认。请手动检查，避免重复点击。")
            }
            defer { group.cancelAll(); task.cancel() }
            return try await group.next()!
        }
        guard let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw MailError.message("网页结果编码失败。")
        }
        return value
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        status = "正在打开网页…"
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageURL = webView.url?.absoluteString ?? ""
        if !provider.contains(webView.url) { revoke() }
        status = enabled ? "邮箱网页会话可用" : "网页已打开；完成登录后点击允许智能体使用"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        revoke(); status = "网页加载失败：\(error.localizedDescription)"
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        revoke(); status = "网页加载失败：\(error.localizedDescription)"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        revoke(); status = "网页进程已退出，请重新加载并确认登录"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["https", "about"].contains(url.scheme ?? "") else {
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame?.isMainFrame != false, !provider.contains(url) { revoke() }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" {
            revoke(); webView.load(navigationAction.request)
        }
        return nil
    }
}

@MainActor
final class MailWebStore: ObservableObject {
    static let shared = MailWebStore()
    private var sessions: [MailWebProvider: MailWebSession] = [:]
    func session(_ provider: MailWebProvider) -> MailWebSession {
        if let session = sessions[provider] { return session }
        let session = MailWebSession(provider: provider); sessions[provider] = session; return session
    }
    var allowed: [MailWebSession] { sessions.values.filter { $0.enabled } }
}
