import SwiftUI

/// Shared by backup destinations and remote disks. A hostname is separate from
/// the root folder and port, so no endpoint suffix is silently discarded.
struct RemoteStorageConfigurationFields: View {
    @Binding var profile: RemoteStorageProfile
    @Binding var secret: String
    var body: some View {
        Section("基本信息") {
            TextField("名称", text: $profile.name)
            TextField("主机名（不含协议、端口和路径）", text: $profile.host)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("端口", value: $profile.port, format: .number.grouping(.never)).keyboardType(.numberPad)
            if profile.proto == .webdav || profile.proto == .s3 || profile.proto == .ftp {
                Toggle(profile.proto == .ftp ? "隐式 FTPS（990）" : "使用 HTTPS", isOn: $profile.useTLS)
                    .onChange(of: profile.useTLS) { tls in
                        if profile.proto == .ftp { profile.port = tls ? 990 : 21 }
                        else if profile.port == 443 || profile.port == 80 { profile.port = tls ? 443 : 80 }
                    }
            }
        }
        Section("认证信息") {
            TextField("用户名 / Access Key", text: $profile.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(profile.proto == .s3 ? "Secret Key（留空保留原值）" : "密码（留空保留原值）", text: $secret)
        }
        if profile.proto == .smb {
            Section("SMB 共享") { TextField("共享名称", text: Binding(get: { profile.share ?? "" }, set: { profile.share = $0 })) }
        }
        if profile.proto == .s3 {
            Section("S3 设置") {
                TextField("存储桶", text: Binding(get: { profile.bucket ?? "" }, set: { profile.bucket = $0 }))
                TextField("区域", text: Binding(get: { profile.region ?? "us-east-1" }, set: { profile.region = $0 }))
            }
        }
        Section("远程路径") {
            TextField("文件夹路径", text: $profile.path).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
}

struct RemoteDiskSettingsView: View {
    @ObservedObject private var store = RemoteDiskStore.shared
    @State private var adding = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text("只读磁盘供 AI 文件工具、文件浏览和聊天附件读取。连接、列目录与读取分别验证；成功仅代表该次操作。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let loadError = store.loadError { Text(loadError).foregroundStyle(.red) }
            }
            ForEach(store.disks) { disk in
                NavigationLink { RemoteDiskDetailView(diskID: disk.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(disk.profile.name, systemImage: "externaldrive.badge.checkmark")
                        Text(disk.profile.proto.title + " · 只读").font(.caption).foregroundStyle(.secondary)
                        Text("读取：" + (store.status(for: disk).reading)).font(.caption)
                    }
                }
                .swipeActions { Button("删除配置", role: .destructive) { do { try store.remove(disk) } catch { self.error = error.localizedDescription } } }
            }
            Button { adding = true } label: { Label("添加网络磁盘", systemImage: "plus") }
        }
        .navigationTitle("网络磁盘")
        .sheet(isPresented: $adding) { RemoteDiskEditorView(disk: nil) }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
    }
}

private struct RemoteDiskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var servers = RemoteServerStore.shared
    @State private var profile: RemoteStorageProfile
    @State private var serverID: UUID?
    @State private var secret = ""
    @State private var error: String?
    @State private var newSSH = false
    init(disk: RemoteDisk?) {
        _profile = State(initialValue: disk?.profile ?? .init(name: "", proto: .webdav, host: "", port: 443))
        _serverID = State(initialValue: disk?.sshServerID)
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("协议", selection: $profile.proto) { ForEach(RemoteStorageProtocol.allCases) { Text($0.title).tag($0) } }
                    .onChange(of: profile.proto) { proto in
                        profile.port = proto == .sftp ? 22 : proto == .smb ? 445 : proto == .ftp ? (profile.useTLS ? 990 : 21) : (profile.useTLS ? 443 : 80)
                        secret = ""
                    }
                if profile.proto == .sftp {
                    Section("SFTP / SSH") {
                        TextField("磁盘名称", text: $profile.name)
                        Picker("SSH 服务器", selection: $serverID) {
                            Text("请选择").tag(nil as UUID?)
                            ForEach(servers.servers) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("添加 SSH 服务器") { newSSH = true }
                        TextField("文件夹路径", text: $profile.path).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("沿用服务器的认证与主机指纹。磁盘始终只读，无需开启服务器的 AI 命令或写入权限。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else { RemoteStorageConfigurationFields(profile: $profile, secret: $secret) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("网络磁盘配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } }
            }
            .sheet(isPresented: $newSSH) { RemoteServerEditorSheet(server: nil) }
        }
    }
    private func save() {
        do {
            if profile.proto == .sftp {
                guard let serverID, let server = servers.server(id: serverID) else { throw RemoteDiskError.invalidConfiguration("请选择 SSH 服务器") }
                profile.host = server.host; profile.port = server.port; profile.username = server.username
            }
            try RemoteDiskStore.shared.save(.init(profile: profile, sshServerID: profile.proto == .sftp ? serverID : nil), secret: secret.isEmpty ? nil : secret)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct RemoteDiskDetailView: View {
    let diskID: UUID
    @ObservedObject private var store = RemoteDiskStore.shared
    @State private var editing = false
    @State private var busy = false
    @State private var error: String?
    @State private var pendingHost: RemoteKnownHost?
    @State private var pendingServerID: UUID?
    var body: some View {
        diskContent
            .alert("确认 SSH 主机指纹", isPresented: hostTrustPresented) {
                Button("信任并重试") { trustHostAndRetry() }
                Button("取消", role: .cancel) { pendingHost = nil }
            } message: {
                Text(hostTrustMessage)
            }
    }

    @ViewBuilder private var diskContent: some View {
        Group {
            if let disk = try? store.disk(id: diskID) {
                diskDetails(disk)
            } else { Text("网络磁盘已删除") }
        }
    }

    private func diskDetails(_ disk: RemoteDisk) -> some View {
        List {
            verificationSection(for: disk)
            Section {
                NavigationLink("浏览只读磁盘 / 选择文件验证") { RemoteDiskBrowserView(diskID: diskID) }
                Text((try? RemoteDiskAddress(diskID: diskID).string) ?? "").font(.caption).textSelection(.enabled)
                Button("编辑配置") { editing = true }.disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(disk.profile.name)
        .sheet(isPresented: $editing) { RemoteDiskEditorView(disk: disk) }
    }

    private func verificationSection(for disk: RemoteDisk) -> some View {
        Section("验证结果") {
            let status = store.status(for: disk)
            LabeledContent("连接", value: status.connection)
            LabeledContent("列目录", value: status.listing)
            LabeledContent("读取", value: status.reading)
            if let date = status.checkedAt { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
            Button(busy ? "验证中…" : "重新验证") { verify(disk) }.disabled(busy)
        }
    }

    private var hostTrustPresented: Binding<Bool> {
        Binding<Bool>(
            get: { pendingHost != nil },
            set: { presented in
                if !presented { pendingHost = nil }
            }
        )
    }

    private var hostTrustMessage: String {
        let algorithm: String = pendingHost?.algorithm ?? ""
        let fingerprint: String = pendingHost?.fingerprint ?? ""
        let heading: String = "请与服务器管理员核对：\n"
        return heading + algorithm + "\n" + fingerprint
    }

    private func trustHostAndRetry() {
        do {
            guard let host = pendingHost, let id = pendingServerID else { return }
            try RemoteServerStore.shared.setKnownHost(host, for: id)
            pendingHost = nil
            if let disk = try? store.disk(id: diskID) { verify(disk) }
        } catch { self.error = error.localizedDescription }
    }
    private func verify(_ disk: RemoteDisk) {
        busy = true; error = nil
        let sshRevision = store.sshRevision(for: disk)
        Task { @MainActor in
            defer { busy = false }
            do {
                // Probe once here to present the existing SSH trust challenge.
                if disk.profile.proto == .sftp { try await RemoteDiskService.shared.testConnection(disk) }
                let result = await RemoteDiskService.shared.verify(disk)
                try store.record(result, for: disk)
            } catch let failure as RemoteServerError {
                if case .hostKeyUntrusted(let host) = failure { pendingHost = host; pendingServerID = disk.sshServerID }
                else { error = failure.localizedDescription }
                var result = RemoteDiskVerification(); result.checkedAt = .now; result.sshUpdatedAt = sshRevision; result.connection = "失败：" + failure.localizedDescription
                do { try store.record(result, for: disk) } catch { self.error = error.localizedDescription }
            } catch { self.error = error.localizedDescription }
        }
    }
}
