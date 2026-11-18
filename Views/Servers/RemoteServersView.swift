import Citadel
import SwiftUI
import UniformTypeIdentifiers

/// Independent management surface for SSH servers. It intentionally does not
/// reuse MCP server configuration: an MCP endpoint is not a shell host.
struct RemoteServersView: View {
    @ObservedObject private var store = RemoteServerStore.shared
    @State private var showingAddServer = false

    var body: some View {
        List {
            if store.servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("还没有服务器")
                        .font(.headline)
                    Text("添加 SSH 服务器后，可在此安全地管理终端和 SFTP 文件。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("添加服务器") { showingAddServer = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .listRowBackground(Color.clear)
            } else {
                Section("服务器") {
                    ForEach(store.servers) { server in
                        NavigationLink {
                            RemoteServerDetailView(serverID: server.id)
                        } label: {
                            RemoteServerRow(server: server)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAddServer = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加服务器")
            }
        }
        .sheet(isPresented: $showingAddServer) {
            RemoteServerEditorSheet(server: nil)
        }
    }

    private func delete(at offsets: IndexSet) {
        for offset in offsets {
            let server = store.servers[offset]
            Task { await RemoteSSHConnectionService.shared.disconnect(serverID: server.id) }
            do {
                try store.delete(server)
            } catch {
                // The model is already removed only after persist succeeds;
                // report the storage error through the next view refresh.
            }
        }
    }
}

private struct RemoteServerRow: View {
    let server: RemoteServerProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(server.enabled ? Color.blue : Color.gray, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .foregroundStyle(.primary)
                Text(server.endpointDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !server.labels.isEmpty {
                    Text(server.labels.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Circle()
                .fill(server.enabled ? (server.hasTrustedHostKey ? Color.green : Color.orange) : Color.gray)
                .frame(width: 9, height: 9)
                .accessibilityLabel(server.enabled ? (server.hasTrustedHostKey ? "已验证主机指纹" : "主机指纹尚未验证") : "已停用")
        }
    }
}

struct RemoteServerEditorSheet: View {
    let server: RemoteServerProfile?
    let draft: RemoteServerAIDraft?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = RemoteServerStore.shared

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var labels: String
    @State private var note: String
    @State private var authentication: RemoteServerAuthentication
    @State private var aiAccess: RemoteServerAIAccessLevel
    @State private var enabled: Bool
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var sessionPassword = ""
    @State private var showKeyImporter = false
    @State private var errorMessage: String?
    @State private var previousAIAccess: RemoteServerAIAccessLevel?
    @State private var showFullAccessConfirmation = false
    @State private var fullAccessConfirmationReady = false
    @State private var fullAccessConfirmationTask: Task<Void, Never>?

    init(server: RemoteServerProfile?, draft: RemoteServerAIDraft? = nil) {
        self.server = server
        self.draft = draft
        _name = State(initialValue: server?.name ?? draft?.name ?? "")
        _host = State(initialValue: server?.host ?? draft?.host ?? "")
        _port = State(initialValue: String(server?.port ?? draft?.port ?? 22))
        _username = State(initialValue: server?.username ?? draft?.username ?? "")
        _labels = State(initialValue: server?.labels.joined(separator: ", ") ?? draft?.labels.joined(separator: ", ") ?? "")
        _note = State(initialValue: server?.note ?? draft?.note ?? "")
        _authentication = State(initialValue: server?.authentication ?? draft?.authentication ?? .privateKey)
        _aiAccess = State(initialValue: server?.aiAccess ?? draft?.aiAccess ?? .none)
        _enabled = State(initialValue: server?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                if draft != nil {
                    Section {
                        Label("以下非敏感字段由 AI 生成，请逐项核对后再保存。密码、私钥和口令需要你在此填写，或由你在对话中确认后由 AI 写入 Keychain；主机指纹必须由你确认。", systemImage: "wand.and.stars")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("主机地址或 IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("标签（用逗号分隔）", text: $labels)
                }

                Section("认证") {
                    Picker("认证方式", selection: $authentication) {
                        ForEach(RemoteServerAuthentication.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    if authentication == .password {
                        SecureField("密码（留空则保留已保存密码）", text: $sessionPassword)
                            .textContentType(.password)
                        Text("密码使用本机 Keychain 保存（仅本设备，不参与 iCloud 或配置同步）；连接时优先读取 Keychain，断开连接不会清除。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if authentication == .privateKey {
                        Button {
                            showKeyImporter = true
                        } label: {
                            Label("从文件导入私钥", systemImage: "key.horizontal")
                        }
                        TextEditor(text: $privateKey)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 88)
                            .autocorrectionDisabled()
                        SecureField("私钥口令（如有）", text: $passphrase)
                            .textContentType(.password)
                        Text("仅支持 OpenSSH RSA 和 Ed25519 私钥。私钥与口令使用本机 Keychain 保存，不参与 iCloud 或配置同步。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("此档不发送密码或私钥，只使用上方用户名发起 none 认证。适用于明确只接受无认证的网关；不保存任何凭据。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("AI 访问") {
                    Picker("访问范围", selection: $aiAccess) {
                        ForEach(RemoteServerAIAccessLevel.allCases) { level in
                            if level == .fullAccess {
                                Label(level.title, systemImage: "shield.fill").tag(level)
                            } else {
                                Text(level.title).tag(level)
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Text("AI 永远不能读取私钥、密码或 Keychain 内容；它只能在你明确确认后写入凭据。即使允许命令或写入，每次执行仍须在界面中确认。完整权限除外：开启后命令与写入不再逐次确认。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("其他") {
                    Toggle("启用此服务器", isOn: $enabled)
                    TextField("备注", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(server == nil ? (draft == nil ? "添加服务器" : "确认服务器草稿") : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .fileImporter(
                isPresented: $showKeyImporter,
                // [T-remote-ssh-key-import] Match the skill/SFTP picker path:
                // .item lets any file (including extensionless private keys)
                // be tapped. The SSHKeyDetection check on save is the format
                // gate; a narrower text/data filter made valid key files
                // appear non-selectable.
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                importPrivateKey(result)
            }
            .alert("无法保存服务器", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("开启完整权限？", isPresented: $showFullAccessConfirmation) {
                Button("取消", role: .cancel) {
                    fullAccessConfirmationTask?.cancel()
                    fullAccessConfirmationTask = nil
                    fullAccessConfirmationReady = false
                    if let previousAIAccess {
                        aiAccess = previousAIAccess
                    }
                }
                Button("确认开启") {
                    fullAccessConfirmationTask?.cancel()
                    fullAccessConfirmationTask = nil
                    fullAccessConfirmationReady = false
                }
                .disabled(!fullAccessConfirmationReady)
            } message: {
                Text("开启后，AI 可以直接读取、写入文件并执行命令，不再每次向你确认。请只对可信的服务器开启。")
            }
            .onChange(of: aiAccess) { oldValue, newValue in
                guard newValue == .fullAccess, oldValue != .fullAccess else { return }
                previousAIAccess = oldValue
                fullAccessConfirmationReady = false
                showFullAccessConfirmation = true
                fullAccessConfirmationTask?.cancel()
                fullAccessConfirmationTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    fullAccessConfirmationReady = true
                }
            }
        }
    }

    private func importPrivateKey(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                throw RemoteServerError.unsupportedPrivateKey
            }
            privateKey = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            guard let port = Int(port) else {
                throw RemoteServerError.invalidProfile("端口必须是数字")
            }
            let id = server?.id ?? UUID()
            let profile = RemoteServerProfile(
                id: id,
                name: name,
                host: host,
                port: port,
                username: username,
                labels: labels.split(separator: ",").map(String.init),
                note: note,
                authentication: authentication,
                enabled: enabled,
                aiAccess: aiAccess,
                quickCommands: server?.quickCommands ?? RemoteServerQuickCommand.defaults,
                knownHost: server?.knownHost,
                createdAt: server?.createdAt ?? .now,
                updatedAt: .now,
                lastConnectedAt: server?.lastConnectedAt
            )
            try store.save(profile)

            switch authentication {
            case .password:
                RemoteServerSessionCredentials.shared.clear(for: id)
                RemoteServerSecretStore.delete(kind: .privateKey, for: id)
                RemoteServerSecretStore.delete(kind: .privateKeyPassphrase, for: id)
                if !sessionPassword.isEmpty {
                    try RemoteServerSecretStore.save(sessionPassword, kind: .password, for: id)
                    RemoteServerSessionCredentials.shared.setPassword(sessionPassword, for: id)
                }
            case .privateKey:
                RemoteServerSessionCredentials.shared.clear(for: id)
                RemoteServerSecretStore.delete(kind: .password, for: id)
                if !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try SSHKeyDetection.detectPrivateKeyType(from: privateKey)
                    try RemoteServerSecretStore.save(privateKey, kind: .privateKey, for: id)
                    if passphrase.isEmpty {
                        RemoteServerSecretStore.delete(kind: .privateKeyPassphrase, for: id)
                    } else {
                        try RemoteServerSecretStore.save(passphrase, kind: .privateKeyPassphrase, for: id)
                    }
                } else if try RemoteServerSecretStore.value(kind: .privateKey, for: id) == nil {
                    throw RemoteServerError.secretMissing
                }
            case .none:
                // The none method carries no secret; clear anything left over
                // from a previous authentication choice.
                RemoteServerSessionCredentials.shared.clear(for: id)
                RemoteServerSecretStore.deleteAll(for: id)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteServerDetailView: View {
    let serverID: UUID

    @ObservedObject private var store = RemoteServerStore.shared
    @ObservedObject private var connection = RemoteSSHConnectionService.shared
    @State private var showingEditor = false
    @State private var password = ""
    @State private var showingPasswordPrompt = false
    @State private var pendingHostTrust: RemoteKnownHost?
    @State private var errorMessage: String?
    @State private var isConnecting = false

    private var server: RemoteServerProfile? { store.server(id: serverID) }

    var body: some View {
        Group {
            if let server {
                List {
                    Section("连接") {
                        LabeledContent("地址", value: server.endpointDescription)
                        LabeledContent("认证", value: server.authentication.title)
                        if let knownHost = server.knownHost {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已验证主机指纹")
                                Text("\(knownHost.algorithm)  \(knownHost.fingerprint)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Label("首次连接前需要确认主机指纹", systemImage: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                        }
                    }

                    Section {
                        if connection.isConnected(to: server.id) {
                            Label("已连接", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            NavigationLink {
                                RemoteSFTPBrowserView(serverID: server.id, initialPath: "/")
                            } label: {
                                Label("SFTP 文件", systemImage: "folder")
                            }
                            NavigationLink {
                                RemoteCommandConsoleView(serverID: server.id, serverName: server.name)
                            } label: {
                                Label("命令终端", systemImage: "terminal")
                            }
                            Button(role: .destructive) {
                                Task { await connection.disconnect(serverID: server.id) }
                            } label: {
                                Label("断开连接", systemImage: "xmark.circle")
                            }
                        } else {
                            Button {
                                requestConnection(for: server)
                            } label: {
                                HStack {
                                    Label("连接服务器", systemImage: "bolt.horizontal.circle")
                                    Spacer()
                                    if isConnecting { ProgressView() }
                                }
                            }
                            .disabled(isConnecting)
                        }
                    }

                    if !server.quickCommands.isEmpty {
                        Section("快捷命令") {
                            ForEach(server.quickCommands) { command in
                                NavigationLink {
                                    RemoteCommandConsoleView(serverID: server.id, serverName: server.name, initialCommand: command.command)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.title)
                                        Text(command.command)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }

                    if let items = connection.diagnostics[server.id], !items.isEmpty {
                        Section("连接诊断") {
                            ForEach(Array(items.suffix(8).reversed())) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    if !item.detail.isEmpty {
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(server.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("编辑") { showingEditor = true }
                    }
                }
                .sheet(isPresented: $showingEditor) {
                    RemoteServerEditorSheet(server: server)
                }
                .alert("输入连接密码", isPresented: $showingPasswordPrompt) {
                    SecureField("密码", text: $password)
                    Button("连接") {
                        guard !password.isEmpty else { return }
                        RemoteServerSessionCredentials.shared.setPassword(password, for: server.id)
                        try? RemoteServerSecretStore.save(password, kind: .password, for: server.id)
                        beginConnection(for: server)
                    }
                    Button("取消", role: .cancel) { password = "" }
                } message: {
                    Text("密码会保存到本机 Keychain（仅本设备，不参与 iCloud 同步）。")
                }
                .confirmationDialog(
                    "确认服务器主机指纹",
                    isPresented: Binding(get: { pendingHostTrust != nil }, set: { if !$0 { pendingHostTrust = nil } }),
                    titleVisibility: .visible
                ) {
                    if let identity = pendingHostTrust {
                        Button("确认信任并连接") {
                            do {
                                try store.setKnownHost(identity, for: server.id)
                                pendingHostTrust = nil
                                beginConnection(for: store.server(id: server.id) ?? server)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    Button("取消", role: .cancel) { pendingHostTrust = nil }
                } message: {
                    if let identity = pendingHostTrust {
                        Text("请仅在通过服务器控制台或管理员核验后确认。\n\n\(identity.algorithm)\n\(identity.fingerprint)")
                    }
                }
                .alert("连接未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("服务器不存在")
                        .font(.headline)
                }
            }
        }
    }

    private func requestConnection(for server: RemoteServerProfile) {
        if server.authentication == .password, !hasStoredPassword(for: server) {
            password = ""
            showingPasswordPrompt = true
        } else {
            beginConnection(for: server)
        }
    }

    /// Keychain is authoritative; the in-memory session value is the fallback.
    private func hasStoredPassword(for server: RemoteServerProfile) -> Bool {
        if let stored = try? RemoteServerSecretStore.value(kind: .password, for: server.id),
           !stored.isEmpty {
            return true
        }
        if let memory = RemoteServerSessionCredentials.shared.password(for: server.id), !memory.isEmpty {
            return true
        }
        return false
    }

    private func beginConnection(for server: RemoteServerProfile) {
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await connection.connect(to: server)
            } catch let error as RemoteServerError {
                switch error {
                case .hostKeyUntrusted(let identity): pendingHostTrust = identity
                case .hostKeyChanged: errorMessage = error.localizedDescription
                default: errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
