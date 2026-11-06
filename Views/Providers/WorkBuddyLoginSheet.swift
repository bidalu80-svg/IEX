import SwiftUI

/// WorkBuddy completes authorization through server polling after browser login.
struct WorkBuddyLoginSheet: View {
    let instanceId: String
    var onFinish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var realm: WorkBuddyRealm = .cn
    @State private var loginTask: Task<Void, Never>?
    @State private var isLoggingIn = false
    @State private var loginURL: URL?
    @State private var errorMessage: String?
    @State private var completed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image("WorkBuddy").resizable().scaledToFit().frame(width: 52, height: 52)
                    Picker("账号区域", selection: $realm) {
                        ForEach(WorkBuddyRealm.allCases, id: \.self) { region in
                            Text(region.displayName).tag(region)
                        }
                    }.disabled(isLoggingIn)
                    Text("在浏览器完成 WorkBuddy 账号授权后返回 Ze；授权结果会自动同步。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if isLoggingIn {
                        ProgressView("等待浏览器授权…")
                        if let loginURL {
                            Button("重新打开登录页面") { openURL(loginURL) }
                        }
                    } else {
                        Button("使用 WorkBuddy 登录") { startLogin() }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("WorkBuddy 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancel(); dismiss() }
                }
            }
        }
        .onAppear { realm = WorkBuddyOAuthManager.shared.realm(instanceId: instanceId) ?? .cn }
        .onDisappear { if !completed { cancel() } }
    }

    private func startLogin() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        loginTask = Task { @MainActor in
            defer { isLoggingIn = false }
            do {
                try await WorkBuddyOAuthManager.shared.login(instanceId: instanceId, realm: realm) { url in
                    loginURL = url
                    openURL(url)
                }
                try Task.checkCancellation()
                completed = true
                onFinish(true)
                dismiss()
            } catch is CancellationError {
                // The cancelled attempt never completes the add-provider flow.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        loginTask?.cancel()
        loginTask = nil
        WorkBuddyOAuthManager.shared.cancelLogin(instanceId: instanceId)
    }
}
