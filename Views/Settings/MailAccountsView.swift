import SwiftUI

@MainActor
struct MailAccountsView: View {
    @ObservedObject private var store = MailAccountStore.shared
    @State private var editing: MailAccount?
    @State private var deleting: MailAccount?
    @State private var result = ""
    @State private var showResult = false
    @State private var testingID: UUID?
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                MailWebEntry(provider: .gmail)
                MailWebEntry(provider: .qq)
            } header: { Text("网页登录邮箱") } footer: {
                Text("直接打开邮箱网页，由你登录。允许后，智能体在同一会话中查看邮件和验证码，无需配置 Gmail API。")
            }
            Section {
                NavigationLink("高级连接方式（API / IMAP）") {
                    List {
                        GmailConnectionSection()
                        NavigationLink { QQMailLoginView() } label: { Text("QQ 邮箱授权码连接") }
                    }.navigationTitle("高级连接方式")
                }
            }
            if let error = store.loadError {
                Section {
                    Text(error).foregroundColor(.red)
                    Button("重新读取") { store.reload() }
                }
            }
            Section {
                ForEach(store.accounts) { account in accountRow(account) }
                if store.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("还没有添加邮箱", systemImage: "envelope")
                        Text("连接邮箱后，智能体可以查看邮件、查找注册验证码和验证链接。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Button { editing = MailAccount() } label: { Label("添加邮箱（高级 IMAP/SMTP）", systemImage: "plus") }
                    .disabled(store.loadError != nil)
            } header: { Text("QQ 与其他已保存邮箱") } footer: {
                Text("邮箱密码和授权码保存在本机钥匙串，不会交给模型。收信不会改变邮件已读状态；每次发信都需要确认。当前提供收件箱文本读取与纯文本发信，附件不在本次收发范围内。")
            }
        }
        .navigationTitle("邮箱")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { account in MailAccountEditor(account: account) }
        .alert("邮箱连接", isPresented: $showResult) { Button("好", role: .cancel) {} } message: { Text(result) }
        .confirmationDialog("删除已保存的邮箱？", isPresented: deletionPresented, titleVisibility: .visible) {
            Button("删除邮箱", role: .destructive) {
                guard let account = deleting else { return }
                do { try store.delete(account) } catch { result = error.localizedDescription; showResult = true }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { Text("仅删除本机配置和授权码，不会删除服务器上的邮件。") }
        .onAppear { store.reload() }
        .onDisappear { testTask?.cancel(); testTask = nil; testingID = nil }
    }
    private var deletionPresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
    private func accountRow(_ account: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { editing = account } label: {
                HStack {
                    Image(systemName: "envelope.fill").foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.title).foregroundStyle(.primary)
                        Text(account.address).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
            HStack {
                Text(account.agentEnabled ? "智能体访问已开启" : "智能体访问已关闭")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if testingID == account.id { ProgressView() }
                Button("测试连接") { test(account) }.font(.caption).disabled(testingID != nil)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button(role: .destructive) { deleting = account } label: { Label("删除", systemImage: "trash") }
        }
    }
    private func test(_ account: MailAccount) {
        testingID = account.id
        testTask = Task { @MainActor in
            defer { testingID = nil }
            do {
                try await MailClient.test(account: account, credentials: store.credentials(for: account.id))
                result = "IMAP 收信与 SMTP 发信认证均成功。测试没有发送邮件。"
            } catch { result = error.localizedDescription }
            if !Task.isCancelled { showResult = true }
        }
    }
}

@MainActor
private struct MailAccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account: MailAccount
    @State private var imapPassword = ""
    @State private var smtpPassword = ""
    @State private var imapPort: String
    @State private var smtpPort: String
    @State private var error = ""
    @State private var showError = false
    private let isExisting: Bool

    init(account: MailAccount) {
        _account = State(initialValue: account)
        _imapPort = State(initialValue: String(account.imapPort))
        _smtpPort = State(initialValue: String(account.smtpPort))
        isExisting = MailAccountStore.shared.accounts.contains { $0.id == account.id }
    }
    var body: some View {
        NavigationStack {
            Form {
                identitySection
                incomingSection
                outgoingSection
                Section {
                    Toggle("允许智能体使用此邮箱", isOn: $account.agentEnabled)
                } footer: { Text("开启后，模型可以读取此邮箱的邮件。发信仍会显示收件人、主题和正文，等待你确认。") }
            }
            .navigationTitle(isExisting ? "编辑邮箱" : "添加邮箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
            .alert("保存邮箱", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(error) }
        }
    }
    private var identitySection: some View {
        Section {
            TextField("备注名称（可选）", text: $account.name)
            TextField("邮箱地址", text: $account.address)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("邮箱信息") } footer: {
            Text("请先在邮箱服务商处开启 IMAP/SMTP，并生成邮箱授权码或应用专用密码。仅提供 OAuth 登录的邮箱暂不适用此连接方式。")
        }
    }
    private var incomingSection: some View {
        Section {
            TextField("IMAP 服务器，例如 imap.example.com", text: $account.imapHost)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("SSL/TLS 端口", text: $imapPort).keyboardType(.numberPad)
            TextField("登录用户名（留空使用邮箱地址）", text: $account.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(isExisting ? "新授权码（留空保留）" : "密码或邮箱授权码", text: $imapPassword)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("收信服务器 · IMAP") } footer: { Text("使用直接 SSL/TLS 加密连接，常用端口为 993。") }
    }
    private var outgoingSection: some View {
        Section {
            TextField("SMTP 服务器，例如 smtp.example.com", text: $account.smtpHost)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("SSL/TLS 端口", text: $smtpPort).keyboardType(.numberPad)
            TextField("登录用户名（留空使用收信用户名）", text: $account.smtpUsername)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(isExisting ? "新发信授权码（留空保留）" : "发信授权码（留空使用收信授权码）", text: $smtpPassword)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("发信服务器 · SMTP") } footer: {
            Text("使用直接 SSL/TLS 加密连接，常用端口为 465。请勿填写 STARTTLS 端口 587。编辑已有邮箱时，两个授权码字段留空分别保留原值。")
        }
    }
    private func save() {
        do {
            guard let incoming = Int(imapPort), let outgoing = Int(smtpPort) else { throw MailError.message("请输入有效端口。") }
            account.imapPort = incoming; account.smtpPort = outgoing
            account.address = account.address.trimmingCharacters(in: .whitespacesAndNewlines)
            account.imapHost = account.imapHost.trimmingCharacters(in: .whitespacesAndNewlines)
            account.smtpHost = account.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines)
            try MailAccountStore.shared.save(account, imapPassword: imapPassword, smtpPassword: smtpPassword)
            imapPassword = ""; smtpPassword = ""; dismiss()
        } catch { self.error = error.localizedDescription; showError = true }
    }
}
