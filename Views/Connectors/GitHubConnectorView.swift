import SwiftUI

struct GitHubConnectorView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var deviceLoginRequest: GitHubLoginRequest?
    @State private var tokenLoginRequest: GitHubLoginRequest?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    GitHubMark(size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub连接器")
                            .font(.headline)
                        Text("登录后，模型可以按你的确认读取和管理项目。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)

                Button {
                    deviceLoginRequest = GitHubLoginRequest(expectedLogin: nil)
                } label: {
                    Label("登录 GitHub", systemImage: "person.crop.circle.badge.plus")
                }

                Button {
                    tokenLoginRequest = GitHubLoginRequest(expectedLogin: nil)
                } label: {
                    Label("使用访问令牌登录", systemImage: "key.fill")
                }
            } footer: {
                Text("写入文件、创建提交和推送到分支前，模型会先请求你的确认。访问令牌只保存在本机钥匙串中。")
            }

            Section("已登录账号") {
                if store.accounts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                        Text("还没有 GitHub 账号")
                            .font(.headline)
                        Text("点击上方按钮添加一个或多个账号。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 12) {
                            AvatarView(url: account.avatarURL)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.login)
                                    .font(.body.weight(.medium))
                                if !account.displayName.isEmpty {
                                    Text(account.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(account.permissionSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if account.loginMethod == .manualToken {
                                    Text("手工令牌：请在 GitHub 调整或重新生成权限后，再粘贴更新。")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if account.scopeState != .satisfied {
                                    Button("补全账号权限") {
                                        deviceLoginRequest = GitHubLoginRequest(expectedLogin: account.login)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                }
                                if account.loginMethod == .manualToken || account.scopeState != .satisfied {
                                    Button("更新访问令牌") {
                                        tokenLoginRequest = GitHubLoginRequest(expectedLogin: account.login)
                                    }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                                }
                            }
                            Spacer()
                            Image(systemName: account.scopeState == .satisfied ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(account.scopeState == .satisfied ? Color.green : Color.orange)
                                .accessibilityLabel(account.permissionSummary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.delete(account)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button("补全账号权限") {
                                deviceLoginRequest = GitHubLoginRequest(expectedLogin: account.login)
                            }
                            Button(role: .destructive) {
                                store.delete(account)
                            } label: {
                                Label("删除账号", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .alert("账号保存失败", isPresented: Binding(
            get: { store.persistenceError != nil },
            set: { if !$0 { store.persistenceError = nil } })) {
                Button("好") { store.persistenceError = nil }
            } message: { Text(store.persistenceError ?? "") }
        .navigationTitle("GitHub连接器")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $deviceLoginRequest) { request in
            GitHubAccountLoginSheet(store: store, expectedLogin: request.expectedLogin)
        }
        .sheet(item: $tokenLoginRequest) { request in
            GitHubTokenLoginSheet(store: store, expectedLogin: request.expectedLogin)
        }
    }
}

private struct GitHubLoginRequest: Identifiable {
    let id = UUID()
    let expectedLogin: String?
}

private struct GitHubAccountLoginSheet: View {
    @ObservedObject var store: GitHubAccountStore
    let expectedLogin: String?
    @Environment(\.dismiss) private var dismiss
    @State private var authorization: GitHubDeviceAuthorization?
    @State private var isStarting = true
    @State private var isPolling = false
    @State private var copied = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 20) {
                GitHubMark(size: 64)
                if let expectedLogin {
                    Text("正在为 \(expectedLogin) 补全权限，请在浏览器登录此账号。")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                if isStarting {
                    ProgressView()
                    Text("正在准备 GitHub 登录…")
                        .foregroundStyle(.secondary)
                } else if let authorization {
                    Text("打开 GitHub 授权页面，输入下面的验证码并允许访问。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button {
                        UIPasteboard.general.string = authorization.userCode
                        copied = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(authorization.userCode)
                                .font(.system(.title, design: .monospaced).weight(.bold))
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 20)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button {
                        UIApplication.shared.open(authorization.verificationURL)
                    } label: {
                        Label("打开 GitHub 授权页面", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    if isPolling {
                        ProgressView("等待 GitHub 授权…")
                            .controlSize(.small)
                    }
                    Text(store.oauthClientID == "178c6fc778ccc68e1d6a"
                        ? "授权页显示 GitHub CLI；撤销此应用授权也可能影响其他 GitHub CLI 使用。授权后返回此处核验。"
                        : "授权页显示配置的 OAuth 应用名称。授权完成后返回此处核验。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("本次请求仓库及删除、组织、账号资料、密钥、包、Projects、Codespaces，以及企业、审计、Copilot 席位与网络配置权限。不会绕过账号角色、组织审批、SSO 或产品限制；也不代表已实现对应管理工具。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("这是一组有限的 OAuth scope，不等于所有账号能力；企业及产品专项的实际授权兼容性仍待验证。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("重新开始") { start() }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity)
            }
            .navigationTitle("登录 GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { finish() }
                }
            }
        }
        .interactiveDismissDisabled(isStarting || isPolling)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task?.cancel()
        isStarting = true
        isPolling = false
        authorization = nil
        copied = false
        errorMessage = nil
        task = Task { @MainActor in
            do {
                let next = try await store.startDeviceLogin()
                authorization = next
                isStarting = false
                isPolling = true
                _ = try await store.finishDeviceLogin(next, expectedLogin: expectedLogin)
                finish()
            } catch is CancellationError {
                // 用户关闭页面或系统取消了当前轮询。
            } catch {
                guard !Task.isCancelled else { return }
                isStarting = false
                isPolling = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finish() {
        task?.cancel()
        dismiss()
    }
}

private struct GitHubTokenLoginSheet: View {
    @ObservedObject var store: GitHubAccountStore
    let expectedLogin: String?
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("访问令牌") {
                    SecureField("粘贴 GitHub 访问令牌", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("令牌只用于验证账号和调用 GitHub API，保存后不会显示给模型。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("允许受限令牌登录，实际权限取决于所提供令牌。细粒度令牌不能仅凭 OAuth scope 判断权限；请在 GitHub 调整或重新生成后粘贴更新。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let expectedLogin {
                        Text("更新账号：\(expectedLogin)。其他账号的令牌不会替换原账号。")
                            .font(.footnote)
                    }
                }
                Section {
                    Button {
                        login()
                    } label: {
                        HStack {
                            Spacer()
                            if isLoggingIn { ProgressView() } else { Text("登录并保存账号") }
                            Spacer()
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoggingIn)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("使用访问令牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isLoggingIn)
        .onDisappear { task?.cancel() }
    }

    private func login() {
        isLoggingIn = true
        errorMessage = nil
        task = Task { @MainActor in
            do {
                _ = try await store.loginWithToken(token, expectedLogin: expectedLogin)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                isLoggingIn = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AvatarView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(.secondary)
    }
}

struct GitHubMark: View {
    let size: CGFloat

    var body: some View {
        Image("GitHubMark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .accessibilityLabel("GitHub")
    }
}
