import SwiftUI

struct GitHubConnectorView: View {
    @StateObject private var store = GitHubAccountStore.shared
    @State private var showingLogin = false
    @State private var showingTokenLogin = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    GitHubMark(size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GitHub 连接器")
                            .font(.headline)
                        Text("登录后，模型可以按你的确认读取和管理项目。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)

                Button {
                    showingLogin = true
                } label: {
                    Label("登录 GitHub", systemImage: "person.crop.circle.badge.plus")
                }

                Button {
                    showingTokenLogin = true
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
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("已连接")
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.delete(account)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
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
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingLogin) {
            GitHubAccountLoginSheet(store: store)
        }
        .sheet(isPresented: $showingTokenLogin) {
            GitHubTokenLoginSheet(store: store)
        }
    }
}

private struct GitHubAccountLoginSheet: View {
    @ObservedObject var store: GitHubAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var authorization: GitHubDeviceAuthorization?
    @State private var isStarting = true
    @State private var isPolling = false
    @State private var copied = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                GitHubMark(size: 64)
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
                    Text("授权完成后返回此处，页面会自动继续。")
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
        errorMessage = nil
        task = Task { @MainActor in
            do {
                let next = try await store.startDeviceLogin()
                authorization = next
                isStarting = false
                isPolling = true
                _ = try await store.finishDeviceLogin(next)
                finish()
            } catch is CancellationError {
                // 用户关闭页面或系统取消了当前轮询。
            } catch {
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
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

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
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func login() {
        isLoggingIn = true
        errorMessage = nil
        Task { @MainActor in
            do {
                _ = try await store.loginWithToken(token)
                dismiss()
            } catch {
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
        Image(systemName: "cat.fill")
            .font(.system(size: size * 0.72, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .accessibilityLabel("GitHub")
    }
}
