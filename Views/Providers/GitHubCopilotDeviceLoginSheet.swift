import SwiftUI
import WebKit

@available(iOS 16.0, *)
struct GitHubCopilotDeviceLoginSheet: View {
    let instanceId: String
    var onFinish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .starting
    @State private var copied = false
    @State private var task: Task<Void, Never>?

    private enum Phase: Equatable {
        case starting
        case awaiting(code: String, url: String, completeURL: String?)
        case success
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text("正在连接 GitHub…").foregroundStyle(.secondary)

                case let .awaiting(code, url, completeURL):
                    Text("请在下方 GitHub 页面登录并授权 GitHub Copilot。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = code
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(copied ? "验证码已复制" : "复制验证码")
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                    if let target = completeURL.flatMap(URL.init(string:)) ?? URL(string: url) {
                        GitHubCopilotLoginWebView(url: target)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                            .frame(minHeight: 360)
                            .accessibilityLabel("GitHub 授权页面")
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("授权地址无效")
                                .font(.headline)
                            Text("请取消后重新开始 GitHub Copilot 登录。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    }

                    Text("授权完成后保持此页面打开，Ze 会自动检测登录结果。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    ProgressView()
                        .controlSize(.small)

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("GitHub Copilot 已连接")
                        .font(.headline)

                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重新登录") { start() }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle("GitHub Copilot 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { finish(false) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting)
        .onAppear { start() }
        .onDisappear {
            // The device-code polling task is intentionally kept alive while
            // the embedded WKWebView is visible. finish() is the explicit
            // cancellation path.
        }
    }

    private func start() {
        task?.cancel()
        copied = false
        phase = .starting
        task = Task { @MainActor in
            do {
                try await GitHubCopilotOAuthManager.shared.login(instanceId: instanceId) { presentation in
                    phase = .awaiting(
                        code: presentation.userCode,
                        url: presentation.verificationURL,
                        completeURL: presentation.verificationURLComplete
                    )
                }
                phase = .success
                try? await Task.sleep(nanoseconds: 700_000_000)
                finish(true)
            } catch is CancellationError {
                // User dismissed the sheet.
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ success: Bool) {
        task?.cancel()
        onFinish(success)
        dismiss()
    }
}

/// A real in-app WKWebView for GitHub's device authorization page.
///
/// The device flow has no redirect callback: GitHubCopilotOAuthManager polls
/// the device token endpoint while this view owns the login page. Keeping the
/// web view on the default website data store preserves the normal GitHub
/// login session without handing the URL to the external Safari application.
@available(iOS 16.0, *)
private struct GitHubCopilotLoginWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // SwiftUI may call updateUIView repeatedly. Do not reload the GitHub
        // page on every state update, otherwise the login form loses focus.
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Keep GitHub's login, consent, and intermediate redirects inside
            // this WKWebView. The device flow does not need an app callback.
            // Cancel non-web schemes instead of handing them to Safari or
            // another external application.
            if let scheme = navigationAction.request.url?.scheme?.lowercased(),
               scheme != "http", scheme != "https", scheme != "about" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // GitHub may request a new window for help/consent links. Reuse
            // the current in-app page instead of opening Safari or dropping it.
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
