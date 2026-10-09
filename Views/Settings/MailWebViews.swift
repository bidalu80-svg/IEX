import SwiftUI
import WebKit

@MainActor
struct MailWebEntry: View {
    let provider: MailWebProvider
    @ObservedObject private var session: MailWebSession
    init(provider: MailWebProvider) {
        self.provider = provider
        session = MailWebStore.shared.session(provider)
    }
    var body: some View {
        NavigationLink { MailWebView(session: session) } label: {
            HStack(spacing: 12) {
                if provider == .gmail { GmailBrandMark().frame(width: 28, height: 23) }
                else { Image(systemName: "envelope.fill").foregroundColor(.blue).frame(width: 28) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title)
                    Text(session.enabled ? "网页会话已允许智能体使用" : "打开邮箱网页并登录")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("mail-web-entry-" + provider.rawValue)
    }
}

@MainActor
struct MailWebView: View {
    @ObservedObject var session: MailWebSession
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var confirmClear = false
    @State private var showHelp = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text(URL(string: session.pageURL)?.host ?? session.provider.home.host ?? "")
                    .font(.caption.monospaced()).lineLimit(1)
                Spacer()
                if session.loading { ProgressView() }
                Button { session.openHome() } label: { Image(systemName: "house") }
                    .accessibilityLabel("打开邮箱首页")
                Button { session.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新加载网页")
            }.padding(.horizontal).padding(.vertical, 10)
            Divider()
            MailWebSurface(webView: session.webView)
                .accessibilityIdentifier("mail-web-live-page")
                .overlay {
                    if session.clearing { Color(.systemBackground).overlay(ProgressView("正在清除会话…")) }
                }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                HStack {
                    Button {
                        checking = true
                        Task { @MainActor in
                            await session.verifyAndEnable(); checking = false
                            if session.enabled { dismiss() }
                        }
                    } label: {
                        HStack {
                            if checking { ProgressView() }
                            Text("已进入邮箱，允许智能体使用")
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(checking || session.loading || session.clearing)
                    .accessibilityIdentifier("mail-web-verify")
                }
            }.padding(12)
        }
        .navigationTitle(session.provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { showHelp = true } label: { Label("网页登录说明", systemImage: "info.circle") }
                    Button { session.revoke() } label: { Label("关闭智能体访问", systemImage: "hand.raised") }
                    Button("退出并清除此邮箱会话", role: .destructive) { confirmClear = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("网页登录说明", isPresented: $showHelp) { Button("知道了", role: .cancel) {} } message: {
            Text("账号、密码和二次验证由你在网页中亲自完成。智能体使用此页面的同一会话，不需要 Gmail API 配置。打开邮件可能改变已读状态。\n\n" +
                 (session.persistent ? "会话保存在此邮箱专用的本机网页存储中。重启后需再次允许智能体访问。" : "iOS 16 的专用会话仅在本次运行期间保留，退出 App 后需重新登录。") +
                 "\n\n如果 Google 提示此浏览器受限，当前网页登录尚未完成；在 Safari 登录不会自动同步到此会话。")
        }
        .confirmationDialog("清除本机邮箱网页登录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除会话", role: .destructive) { Task { await session.disconnect() } }
            Button("取消", role: .cancel) {}
        } message: { Text("清除该邮箱的专用 Cookie 和网页数据，不删除服务器邮件，不影响其他浏览器。") }
        .onAppear { session.beginManual() }
        .onDisappear { session.endManual() }
    }
}

struct MailWebSurface: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        // The session owns the view. Dismissing settings never destroys the login.
        uiView.removeFromSuperview()
    }
}
