import SwiftUI
import UniformTypeIdentifiers

struct ICloudBackupView: View {
    @StateObject private var manager = ICloudBackupManager.shared
    @State private var showError: String?
    @State private var showRestoreConfirm: ICloudBackupManager.BackupEntry?
    @State private var showPasswordSheet = false
    @State private var passwordMode: PasswordMode?
    @State private var showFileImporter = false
    @State private var importedURL: URL?
    @State private var selectedMode = 0
    @State private var showDestinationImporter = false
    @State private var showDestinationEditor = false
    @State private var pendingDestinationFolder: URL?
    @State private var selectedDestination: ICloudBackupManager.BackupDestination?
    @State private var destinationCategory: ICloudBackupManager.BackupCategory = .full
    @State private var backupSelection = ICloudBackupManager.BackupSelection.forCategory(.full)
    @State private var remoteFiles: [UUID: [RemoteSFTPEntry]] = [:]
    @State private var remoteLoading: UUID?
    @State private var showProtocolPicker = false
    @AppStorage("ze.backup.maxFileSizeMB") private var maxFileSizeMB = 100
    @AppStorage("ze.backup.encryptionEnabled") private var encryptionEnabled = true

    private enum PasswordMode: Identifiable {
        case export(ICloudBackupManager.BackupCategory)
        case restore
        case restoreDestination(ICloudBackupManager.BackupDestination, String)
        var id: String {
            switch self {
            case .export(let c): return "export-\(c.rawValue)"
            case .restore: return "restore"
            case .restoreDestination(let destination, let fileName): return "restore-\(destination.id)-\(fileName)"
            }
        }
    }

    var body: some View {
        List {
            Picker(String(localized: "Backup and Restore"), selection: $selectedMode) {
                Text(String(localized: "Backup")).tag(0)
                Text(String(localized: "Restore")).tag(1)
            }
            .pickerStyle(.segmented)

            if selectedMode == 0 {
                backupOptionsSection
                encryptionSection
                destinationsSection
            } else {
                restoreSection
            }

            // MARK: - Status & Backup Actions
            Section {
                if !manager.isICloudAvailable {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.red)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(String(localized: "iCloud is not available"))
                            .foregroundColor(.primary)
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.icloud.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(String(localized: "iCloud connected"))
                            .foregroundColor(.green)
                    }
                }
            }

            // Local Files and remote destinations remain usable even when the
            // optional iCloud container is unavailable (for example in a
            // re-signed build). Only the iCloud history/status above depends
            // on the container entitlement.
            if selectedMode == 0 {
                Section(String(localized: "Backup")) {
                    ForEach(ICloudBackupManager.BackupCategory.allCases) { category in
                        Button {
                            performBackup(category: category)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 30, height: 30)
                                    .background(category.iconColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.displayName)
                                        .foregroundColor(.primary)
                                    Text(category.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if manager.isBackingUp {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                }
                            }
                        }
                        .disabled(manager.isBackingUp || manager.isRestoring)
                    }

                    if manager.isBackingUp {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: manager.progress)
                            Text(manager.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button(String(localized: "Cancel"), role: .cancel) {
                                manager.cancelCurrentOperation()
                            }
                            .font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if selectedMode == 0 { Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Encrypted portable backup"), systemImage: "lock.doc.fill")
                        .font(.headline)
                    Text(String(localized: "Export a password-protected .zebak file for local storage or transfer to another device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        BackupCategoryDetailView(category: .full, selection: $backupSelection) {
                            passwordMode = .export(.full); showPasswordSheet = true
                        }
                    } label: {
                        Label(String(localized: "Choose backup contents"), systemImage: "slider.horizontal.3")
                    }
                    Button {
                        passwordMode = .restore
                        showFileImporter = true
                    } label: {
                        Label(String(localized: "Restore .zebak file"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(manager.isBackingUp || manager.isRestoring)
                    if let url = manager.lastExportURL {
                        ShareLink(item: url) {
                            Label(String(localized: "Share latest backup"), systemImage: "link")
                        }
                        Text(url.lastPathComponent)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } }

            if selectedMode == 1 && manager.isRestoring {
                Section(String(localized: "Restoring")) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: manager.progress)
                        Text(manager.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(String(localized: "Cancel"), role: .cancel) {
                            manager.cancelCurrentOperation()
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
            }

            // MARK: - Available Backups
            let grouped = Dictionary(grouping: manager.availableBackups, by: \.deviceName)
            let sortedDevices = grouped.keys.sorted()

            ForEach(sortedDevices, id: \.self) { device in
                Section(device) {
                    ForEach(grouped[device] ?? []) { entry in
                        backupRow(entry)
                    }
                }
            }

            if selectedMode == 1 && manager.availableBackups.isEmpty && manager.isICloudAvailable {
                Section {
                    Text(String(localized: "No backups found"))
                        .foregroundColor(.secondary)
                }
            }

            if selectedMode == 1 { Section {
                // empty section for footer
            } footer: {
                Text(String(localized: "Backups are stored in iCloud Drive and sync across your devices. Restoring will replace your current local data."))
            }
            }
        }
        .navigationTitle(String(localized: "Backup and Restore"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadBackupSelection()
            await manager.listBackups()
        }
        .refreshable {
            await manager.listBackups()
        }
        .alert(String(localized: "Restore Backup"), isPresented: .init(
            get: { showRestoreConfirm != nil },
            set: { if !$0 { showRestoreConfirm = nil } }
        )) {
            Button(String(localized: "Cancel"), role: .cancel) { showRestoreConfirm = nil }
            Button(String(localized: "Restore"), role: .destructive) {
                if let entry = showRestoreConfirm {
                    performRestore(entry: entry)
                }
            }
        } message: {
            if let entry = showRestoreConfirm {
                Text("这会用 \(entry.date.formatted(date: .abbreviated, time: .shortened)) 的备份替换当前 \(entry.category.displayName) 数据，此操作无法撤销。")
            }
        }
        .alert(String(localized: "Error"), isPresented: .init(
            get: { showError != nil },
            set: { if !$0 { showError = nil } }
        )) {
            Button(String(localized: "OK")) { showError = nil }
        } message: {
            if let error = showError {
                Text(error)
            }
        }
        .sheet(isPresented: $showPasswordSheet) {
            BackupPasswordSheet {
                handlePassword($0)
                showPasswordSheet = false
            } onCancel: {
                showPasswordSheet = false
                passwordMode = nil
            } }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.data, UTType.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importedURL = url
            passwordMode = .restore
            showPasswordSheet = true
        }
        .fileImporter(isPresented: $showDestinationImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            pendingDestinationFolder = url
            showDestinationEditor = true
        }
        .sheet(isPresented: $showDestinationEditor) {
            if let folder = pendingDestinationFolder {
                BackupDestinationEditor(folderURL: folder) { destination in
                    manager.saveDestination(destination)
                    pendingDestinationFolder = nil
                }
            }
        }
        .sheet(isPresented: $showProtocolPicker) {
            BackupProtocolPickerView { server in
                manager.saveDestination(server)
                showProtocolPicker = false
            }
        }
    }

    private var backupOptionsSection: some View {
        Section {
            HStack {
                backupIconLabel(String(localized: "Device name"), systemImage: "iphone", color: .blue)
                Spacer()
                Text(DeviceIdentity.modelName).foregroundStyle(.secondary)
            }
            Toggle(isOn: selectionBinding(\.chats)) { backupIconLabel(String(localized: "Chats"), systemImage: "bubble.left.and.bubble.right", color: .blue) }
            Toggle(isOn: selectionBinding(\.sharedFiles)) { backupIconLabel(String(localized: "Shared files"), systemImage: "doc.fill", color: .indigo) }
            Toggle(isOn: selectionBinding(\.skills)) { backupIconLabel(String(localized: "Skills"), systemImage: "puzzlepiece.fill", color: .orange) }
            Toggle(isOn: selectionBinding(\.memory)) { backupIconLabel(String(localized: "Memory and Soul"), systemImage: "brain", color: .pink) }
            Toggle(isOn: selectionBinding(\.providers)) { backupIconLabel(String(localized: "AI providers"), systemImage: "link", color: .teal) }
            Toggle(isOn: selectionBinding(\.mcpServers)) { backupIconLabel(String(localized: "MCP servers"), systemImage: "square.stack.3d.down.right.fill", color: .cyan) }
            Toggle(isOn: selectionBinding(\.environmentVariables)) { backupIconLabel(String(localized: "Environment variables"), systemImage: "terminal.fill", color: .brown) }
            Picker(selection: $maxFileSizeMB) {
                Text(String(localized: "Do not back up files")).tag(-1)
                Text("1 MB").tag(1); Text("2 MB").tag(2); Text("5 MB").tag(5)
                Text("10 MB").tag(10); Text("50 MB").tag(50); Text("100 MB").tag(100); Text("500 MB").tag(500)
                Text(String(localized: "Unlimited")).tag(0)
            } label: {
                backupIconLabel(String(localized: "Maximum file size"), systemImage: "scroll", color: .gray)
            }
        } header: {
            Text(String(localized: "Include"))
        } footer: {
            Text(String(localized: "The backup includes all selected local data. Files larger than the limit are recorded but their contents are skipped."))
                .font(.caption)
        }
    }

    private var destinationsSection: some View {
        Section(String(localized: "Backup destinations")) {
            ForEach(manager.destinations) { destination in
                Button {
                    selectedDestination = destination
                    destinationCategory = .full
                    passwordMode = .export(.full)
                    showPasswordSheet = true
                } label: {
                    Label(destination.name, systemImage: destination.kind == .localFolder ? "folder" : "server.rack")
                }
                .contextMenu {
                    Button(role: .destructive) { manager.removeDestination(destination) } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
            Button { showProtocolPicker = true } label: {
                Label(String(localized: "Add server…"), systemImage: "globe")
            }
            Button { showDestinationImporter = true } label: {
                Label(String(localized: "Add backup folder"), systemImage: "folder.badge.plus")
            }
        }
    }

    private func backupIconLabel(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color, in: Circle())
            Text(title)
        }
    }

    private var encryptionSection: some View {
        Section(String(localized: "Encryption")) {
            Toggle(isOn: $encryptionEnabled) {
                backupIconLabel(String(localized: "Encrypted backup"), systemImage: "lock.open.fill", color: .gray)
            }
            Text(String(localized: "Encrypted backups protect provider credentials and other sensitive settings with your password."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var restoreSection: some View {
        Section(String(localized: "Restore from a destination")) {
            if manager.destinations.isEmpty {
                Text(String(localized: "Add a Files folder or SFTP destination to restore a Ze backup."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.destinations) { destination in
                    Button {
                        selectedDestination = destination
                        showFileImporter = destination.kind == .localFolder
                    } label: {
                        Label(destination.name, systemImage: destination.kind == .localFolder ? "folder" : "server.rack")
                    }
                }
            }
            if !manager.destinations.isEmpty {
                Text(String(localized: "Remote backup files"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(manager.destinations.filter { $0.kind == .sftpServer }) { destination in
                if let files = remoteFiles[destination.id], !files.isEmpty {
                    ForEach(files) { file in
                        Button {
                            passwordMode = .restoreDestination(destination, file.name)
                            showPasswordSheet = true
                        } label: {
                            Label(file.name, systemImage: "doc.zipper")
                        }
                    }
                } else if remoteLoading == destination.id {
                    ProgressView(String(localized: "Loading remote backups…"))
                } else {
                    Button {
                        loadRemoteFiles(for: destination)
                    } label: {
                        Label(String(localized: "Load remote backups"), systemImage: "arrow.clockwise")
                    }
                }
            }
            Button {
                showFileImporter = true
            } label: {
                Label(String(localized: "Choose a Ze backup file"), systemImage: "doc.badge.arrow.down")
            }
        }
    }

    // MARK: - Backup Row

    private func backupRow(_ entry: ICloudBackupManager.BackupEntry) -> some View {
        HStack {
            Image(systemName: entry.category.systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(entry.category.iconColor)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category.displayName)
                    .font(.body)
                HStack(spacing: 8) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    Text(entry.fileSize.formattedFileSize)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteBackup(entry)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                showRestoreConfirm = entry
            } label: {
                Label(String(localized: "Restore"), systemImage: "arrow.counterclockwise")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                showRestoreConfirm = entry
            } label: {
                Label(String(localized: "Restore"), systemImage: "arrow.counterclockwise")
            }
            .disabled(manager.isRestoring || manager.isBackingUp)

            Button(role: .destructive) {
                deleteBackup(entry)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func performBackup(category: ICloudBackupManager.BackupCategory) {
        Task {
            do {
                try await manager.backup(category: category)
            } catch {
                showError = error.localizedDescription
            }
        }
    }

    private func performRestore(entry: ICloudBackupManager.BackupEntry) {
        Task {
            do {
                try await manager.restore(from: entry)
            } catch {
                showError = error.localizedDescription
            }
        }
    }

    private func deleteBackup(_ entry: ICloudBackupManager.BackupEntry) {
        do {
            try manager.deleteBackup(entry)
        } catch {
            showError = error.localizedDescription
        }
    }

    private func handlePassword(_ password: String) {
        guard let mode = passwordMode else { return }
        passwordMode = nil
        Task {
            do {
                switch mode {
                case .export(let category):
                    if let destination = selectedDestination {
                        _ = try await manager.backupEncrypted(category: category, selection: backupSelection, to: destination, password: password)
                    } else {
                        _ = try await manager.exportEncryptedBackup(category: category, selection: backupSelection, password: password)
                    }
                case .restore:
                    guard let importedURL else { return }
                    let accessed = importedURL.startAccessingSecurityScopedResource()
                    defer { if accessed { importedURL.stopAccessingSecurityScopedResource() } }
                    if let destination = selectedDestination {
                        try await manager.restoreEncrypted(from: destination, fileName: importedURL.lastPathComponent, password: password)
                    } else {
                        try await manager.restoreEncrypted(from: importedURL, password: password)
                    }
                    self.importedURL = nil
                case .restoreDestination(let destination, let fileName):
                    try await manager.restoreEncrypted(from: destination, fileName: fileName, password: password)
                }
                selectedDestination = nil
            } catch {
                showError = error.localizedDescription
            }
        }
    }

    private func selectionBinding(_ keyPath: WritableKeyPath<ICloudBackupManager.BackupSelection, Bool>) -> Binding<Bool> {
        Binding(
            get: { backupSelection[keyPath: keyPath] },
            set: {
                backupSelection[keyPath: keyPath] = $0
                if let data = try? JSONEncoder().encode(backupSelection) {
                    UserDefaults.standard.set(data, forKey: "ze.backup.selection.v1")
                }
            }
        )
    }

    private func loadBackupSelection() {
        if let data = UserDefaults.standard.data(forKey: "ze.backup.selection.v1"),
           let value = try? JSONDecoder().decode(ICloudBackupManager.BackupSelection.self, from: data) {
            backupSelection = value
        }
    }

    private func loadRemoteFiles(for destination: ICloudBackupManager.BackupDestination) {
        guard destination.kind == .sftpServer else { return }
        remoteLoading = destination.id
        Task {
            defer { remoteLoading = nil }
            do { remoteFiles[destination.id] = try await manager.listEncryptedBackups(in: destination) }
            catch { showError = error.localizedDescription }
        }
    }
}

private struct BackupCategoryDetailView: View {
    let category: ICloudBackupManager.BackupCategory
    @Binding var selection: ICloudBackupManager.BackupSelection
    let onExport: () -> Void

    var body: some View {
        Form {
            Section {
                Label(category.displayName, systemImage: category.systemImage)
                    .font(.headline)
                Text(category.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Backup contents")) {
                if category == .sessions || category == .full {
                    Toggle(String(localized: "Chats"), isOn: $selection.chats)
                    Toggle(String(localized: "Shared files"), isOn: $selection.sharedFiles)
                }
                if category == .skillsAndMemories || category == .full {
                    Toggle(String(localized: "Skills"), isOn: $selection.skills)
                    Toggle(String(localized: "Memory and Soul"), isOn: $selection.memory)
                }
                if category == .full {
                    Toggle(String(localized: "AI providers"), isOn: $selection.providers)
                    Toggle(String(localized: "MCP servers"), isOn: $selection.mcpServers)
                    Toggle(String(localized: "Environment variables"), isOn: $selection.environmentVariables)
                }
            }
            Section {
                Button {
                    onExport()
                } label: {
                    Label(String(localized: "Export encrypted backup"), systemImage: "lock.doc.fill")
                }
                .disabled(!hasSelection)
            } footer: {
                Text(String(localized: "Secrets are included only in the encrypted backup and are protected by your password."))
            }
        }
        .navigationTitle(category.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selection) { value in
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: "ze.backup.selection.v1")
            }
        }
    }

    private var hasSelection: Bool {
        switch category {
        case .sessions: return selection.chats || selection.sharedFiles
        case .skillsAndMemories: return selection.skills || selection.memory
        case .full: return selection.chats || selection.sharedFiles || selection.skills || selection.memory || selection.providers || selection.mcpServers || selection.environmentVariables
        }
    }
}

private struct BackupProtocolPickerView: View {
    let onSelectSFTP: (ICloudBackupManager.BackupDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showServerChooser = false
    @State private var showSFTPForm = false

    private struct ProtocolRow: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let subtitle: LocalizedStringKey
        let icon: String
        let enabled: Bool
    }

    private let rows: [ProtocolRow] = [
        .init(id: "smb", title: "SMB / Windows Share", subtitle: "NAS、Windows 共享文件夹、Samba", icon: "externaldrive.connected.to.line.below", enabled: false),
        .init(id: "webdav", title: "WebDAV", subtitle: "Nextcloud、ownCloud、群晖、alist", icon: "globe", enabled: false),
        .init(id: "sftp", title: "SFTP", subtitle: "通过 SSH 访问的 Linux 服务器或 NAS", icon: "terminal", enabled: true),
        .init(id: "s3", title: "S3 兼容存储", subtitle: "MinIO、Cloudflare R2、Wasabi、阿里云 OSS、腾讯 COS", icon: "cylinder", enabled: false),
        .init(id: "ftp", title: "FTP", subtitle: "旧式文件服务器和路由器", icon: "arrow.up.arrow.down.circle", enabled: false)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "Protocol type")) {
                    ForEach(rows) { row in
                        Button {
                            guard row.enabled else { return }
                            if row.id == "sftp" { selectSFTP() }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: row.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(row.enabled ? Color.blue : Color.gray, in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title).font(.headline)
                                    Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                    if !row.enabled {
                                        Text(String(localized: "This protocol is not available yet"))
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if row.enabled { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            }
                            .padding(.vertical, 5)
                        }
                        .disabled(!row.enabled)
                    }
                }
            }
            .navigationTitle(String(localized: "Add server"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
            .confirmationDialog(String(localized: "Choose an SFTP server"), isPresented: $showServerChooser) {
                ForEach(RemoteServerStore.shared.servers) { server in
                    Button(server.name) {
                        onSelectSFTP(.init(name: server.name, kind: .sftpServer, serverID: server.id, remotePath: "/"))
                        dismiss()
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) { }
            }
            .sheet(isPresented: $showSFTPForm) {
                SFTPBackupServerEditor { destination in
                    onSelectSFTP(destination)
                    dismiss()
                }
            }
        }
    }

    private func selectSFTP() {
        let servers = RemoteServerStore.shared.servers
        guard !servers.isEmpty else { showSFTPForm = true; return }
        if servers.count == 1, let server = servers.first {
            onSelectSFTP(.init(name: server.name, kind: .sftpServer, serverID: server.id, remotePath: "/"))
            dismiss()
        } else {
            showServerChooser = true
        }
    }
}

private struct SFTPBackupServerEditor: View {
    let onSave: (ICloudBackupManager.BackupDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var remotePath = "/"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Name")) {
                    TextField(String(localized: "Displayed in backup destinations"), text: $name)
                }
                Section(String(localized: "Connection information")) {
                    TextField(String(localized: "Server"), text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(String(localized: "Username"), text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(String(localized: "Password"), text: $password)
                    TextField(String(localized: "Port (optional)"), text: $port)
                        .keyboardType(.numberPad)
                    TextField(String(localized: "Remote folder"), text: $remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text(String(localized: "The password is kept in the device session and is never written into a backup file."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "The server host key must be confirmed in Ze server settings before connecting."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(String(localized: "Add SFTP server"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Save"), action: save) }
            }
        }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanHost.isEmpty, !cleanUser.isEmpty else {
            errorMessage = String(localized: "Name, server, and username are required")
            return
        }
        guard let portValue = Int(port), (1...65_535).contains(portValue) else {
            errorMessage = String(localized: "Port must be a number between 1 and 65535")
            return
        }
        guard !password.isEmpty else {
            errorMessage = String(localized: "Enter the SFTP password to continue")
            return
        }
        do {
            let id = UUID()
            let profile = RemoteServerProfile(id: id, name: cleanName, host: cleanHost, port: portValue,
                                              username: cleanUser, authentication: .password)
            try RemoteServerStore.shared.save(profile)
            RemoteServerSessionCredentials.shared.setPassword(password, for: id)
            let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            onSave(.init(name: cleanName, kind: .sftpServer, serverID: id, remotePath: path.isEmpty ? "/" : path))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BackupPasswordSheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(String(localized: "Backup password"), text: $password)
                    Text(String(localized: "The password is used only for this operation and is never stored."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Backup password"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { onCancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Continue")) { onSubmit(password); dismiss() }
                        .disabled(password.isEmpty)
                }
            }
        }
    }
}

@available(iOS 16.0, *)
private struct BackupDestinationEditor: View {
    let folderURL: URL
    let onSave: (ICloudBackupManager.BackupDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Destination name")) {
                    TextField(String(localized: "Name"), text: $name)
                }
                Section {
                    Text(folderURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } header: {
                    Text(String(localized: "Files folder"))
                } footer: {
                    Text(String(localized: "The folder is accessed only when a backup is exported or restored."))
                }
            }
            .navigationTitle(String(localized: "Add backup destination"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        let bookmark = try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? folderURL.lastPathComponent : name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(.init(name: title, kind: .localFolder, bookmarkData: bookmark))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
