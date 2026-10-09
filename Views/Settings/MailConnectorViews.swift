import SwiftUI

@MainActor
struct GmailConnectionSection: View {
    @ObservedObject private var connector = GmailConnector.shared
    @State private var selected: GmailAccount?
    var body: some View {
        Section {
            NavigationLink {
                GmailConnectionView()
            } label: {
                HStack(spacing: 12) {
                    GmailBrandMark().frame(width: 28, height: 23)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Gmail")
                        Text(connector.accounts.isEmpty ? "使用 Google 账号登录授权" : "已连接 \(connector.accounts.count) 个账号")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("邮箱连接器") }
    }
}

struct GmailBrandMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                Path { p in p.move(to: CGPoint(x: w * 0.1, y: h)); p.addLine(to: CGPoint(x: w * 0.1, y: h * 0.1)) }
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: w * 0.2, lineCap: .round))
                Path { p in p.move(to: CGPoint(x: w * 0.9, y: h)); p.addLine(to: CGPoint(x: w * 0.9, y: h * 0.1)) }
                    .stroke(Color.green, style: StrokeStyle(lineWidth: w * 0.2, lineCap: .round))
                Path { p in p.move(to: CGPoint(x: w * 0.1, y: h * 0.1)); p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.55)); p.addLine(to: CGPoint(x: w * 0.9, y: h * 0.1)) }
                    .stroke(Color.red, style: StrokeStyle(lineWidth: w * 0.2, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityHidden(true)
    }
}

@MainActor
struct GmailConnectionView: View {
    @ObservedObject private var connector = GmailConnector.shared
    @State private var disconnecting: GmailAccount?
    @State private var message = ""
    @State private var showMessage = false
    @State private var busy = false
    @State private var loginTask: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    GmailBrandMark().frame(width: 48, height: 36).padding(12)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Gmail").font(.title2.bold())
                        Text("授权 Ze 搜索和读取你的邮件").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
                Text("登录时仅申请 Gmail 只读权限。智能体可在你要求注册网站时查找对应的新验证码或验证链接；此连接不会发送、删除邮件或改变已读状态。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = connector.storageError {
                Section { Text(error).foregroundColor(.red); Button("重新读取授权") { connector.reload() } }
            }
            if !connector.configurationReady {
                Section { Text(connector.configurationMessage).font(.footnote) } header: { Text("需要应用开发者配置") }
            }
            Section {
                ForEach(connector.accounts) { account in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(account.address).font(.headline)
                        Toggle("允许智能体读取邮件", isOn: Binding(get: {
                            connector.accounts.first(where: { $0.id == account.id })?.agentEnabled ?? false
                        }, set: { enabled in
                            do { try connector.setEnabled(id: account.id, enabled: enabled) }
                            catch { report(error.localizedDescription) }
                        }))
                        Button("解除连接", role: .destructive) { disconnecting = account }
                            .disabled(busy || connector.signingIn)
                    }.padding(.vertical, 4)
                }
                Button {
                    loginTask = Task { @MainActor in
                        do { try await connector.signIn(); report("Gmail 已连接，可在账号下方选择是否允许智能体读取邮件。") }
                        catch is CancellationError {} catch { report(error.localizedDescription) }
                    }
                } label: {
                    HStack {
                        if connector.signingIn { ProgressView() }
                        Text(connector.signingIn ? "正在等待 Google 授权…" : "使用 Google 登录 / 添加账号")
                    }
                }
                .disabled(connector.signingIn || busy || !connector.configurationReady || connector.storageError != nil)
                if connector.signingIn { Button("取消登录") { loginTask?.cancel(); connector.cancelSignIn() } }
            } header: { Text("已连接账号") } footer: {
                Text("授权令牌保存在本机钥匙串，不会交给模型。访问到期后自动续期；你可以随时关闭智能体权限或解除连接。")
            }
        }
        .navigationTitle("Gmail").navigationBarTitleDisplayMode(.inline)
        .alert("邮箱连接", isPresented: $showMessage) { Button("好", role: .cancel) {} } message: { Text(message) }
        .confirmationDialog("解除 Gmail 连接？", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            Button("解除连接", role: .destructive) {
                guard let account = disconnecting else { return }; disconnecting = nil; busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { report(try await connector.disconnect(id: account.id)) } catch { report(error.localizedDescription) }
                }
            }
            Button("取消", role: .cancel) { disconnecting = nil }
        } message: { Text("删除本机令牌并请求 Google 撤销 Ze 授权，不会删除邮箱中的邮件。") }
        .onDisappear { loginTask?.cancel(); connector.cancelSignIn() }
    }
    private func report(_ value: String) { message = value; showMessage = true }
}

@MainActor
struct QQMailLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var authorizationCode = ""
    @State private var nickname = ""
    @State private var enabled = true
    @State private var connecting = false
    @State private var error = ""
    @State private var showError = false
    @State private var loginTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section {
                Label("QQ 邮箱", systemImage: "envelope.fill").font(.title2).foregroundColor(.blue)
                Text("使用 QQ 邮箱授权码连接。登录后，智能体可以读取邮件并查找用户注册网站所需的验证码或验证链接。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("QQ 邮箱地址，例如 123456@qq.com", text: $address)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("QQ 邮箱授权码（不是 QQ 密码）", text: $authorizationCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("备注名称（可选）", text: $nickname)
                Toggle("允许智能体读取此邮箱", isOn: $enabled)
            } header: { Text("登录信息") }
            .disabled(connecting)
            Section {
                Text("在 QQ 邮箱网页版的设置中开启 IMAP/SMTP 服务，按提示验证身份并生成授权码，再把授权码填到上面。不要填写 QQ 登录密码。")
                Link("打开 QQ 邮箱官网", destination: URL(string: "https://mail.qq.com/")!)
                Text("自动使用 imap.qq.com:993 与 smtp.qq.com:465（SSL/TLS）。保存前会验证 IMAP 登录，验证期间不会发送邮件。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("如何获取授权码") }
            Section {
                Button {
                    loginTask = Task { @MainActor in await connect() }
                } label: { HStack { if connecting { ProgressView() }; Text(connecting ? "正在验证邮箱登录…" : "登录并连接邮箱") } }
                    .disabled(connecting || authorizationCode.isEmpty || address.isEmpty)
            }
        }
        .navigationTitle("连接 QQ 邮箱").navigationBarTitleDisplayMode(.inline)
        .alert("QQ 邮箱连接", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(error) }
        .onDisappear { loginTask?.cancel() }
    }
    private func connect() async {
        guard !connecting else { return }
        connecting = true; defer { connecting = false }
        do {
            var account = MailAccount(); account.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard account.address.lowercased().hasSuffix("@qq.com") || account.address.lowercased().hasSuffix("@foxmail.com") else {
                throw MailError.message("请填写 @qq.com 或 @foxmail.com 邮箱；其他邮箱可使用高级 IMAP/SMTP 入口。")
            }
            account.name = nickname.isEmpty ? "QQ 邮箱" : nickname
            account.imapHost = "imap.qq.com"; account.smtpHost = "smtp.qq.com"; account.agentEnabled = enabled
            try account.validate()
            let credentials = MailCredentials(imapPassword: authorizationCode, smtpPassword: authorizationCode)
            try await MailClient.testIncoming(account: account, credentials: credentials)
            try Task.checkCancellation()
            try MailAccountStore.shared.save(account, imapPassword: credentials.imapPassword, smtpPassword: credentials.smtpPassword)
            authorizationCode = ""; dismiss()
        } catch is CancellationError {} catch { self.error = error.localizedDescription; showError = true }
    }
}
