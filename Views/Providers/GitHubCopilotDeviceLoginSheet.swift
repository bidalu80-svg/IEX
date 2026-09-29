import SwiftUI
import SafariServices

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
            VStack(spacing: 22) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text("正在连接 GitHub…").foregroundStyle(.secondary)
                case let .awaiting(code, url, completeURL):
                    Text("打开 GitHub 登录页面并授权 GitHub Copilot。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button { UIPasteboard.general.string = code; copied = true } label: {
                        HStack(spacing: 8) {
                            Text(code).font(.system(.title, design: .monospaced).weight(.bold))
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .padding(.vertical, 12).padding(.horizontal, 20)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                    Button {
                        let target = completeURL.flatMap(URL.init(string:)) ?? URL(string: url)
                        if let target { UIApplication.shared.open(target) }
                    } label: { Label("打开 GitHub 授权页面", systemImage: "safari") }
                    .buttonStyle(.borderedProminent).tint(.pink)
                    Text("授权完成后返回此处，页面会自动继续。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ProgressView().controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                    Text("GitHub Copilot 已连接").font(.headline)
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("重新登录") { start() }.buttonStyle(.borderedProminent).tint(.pink)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            .navigationTitle("GitHub Copilot 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { finish(false) } } }
        }
        .interactiveDismissDisabled(phase == .starting)
        .onAppear { start() }
        // Opening the external GitHub authorization page can make this sheet
        // disappear temporarily. Keep the device-code poll alive; finish()
        // remains the explicit cancellation path.
        .onDisappear { }
    }

    private func start() {
        task?.cancel(); copied = false; phase = .starting
        task = Task { @MainActor in
            do {
                try await GitHubCopilotOAuthManager.shared.login(instanceId: instanceId) { presentation in
                    phase = .awaiting(code: presentation.userCode, url: presentation.verificationURL, completeURL: presentation.verificationURLComplete)
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
        task?.cancel(); onFinish(success); dismiss()
    }
}
