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

    private enum PasswordMode: Identifiable {
        case export(ICloudBackupManager.BackupCategory)
        case restore
        var id: String {
            switch self { case .export(let c): return "export-\(c.rawValue)"; case .restore: return "restore" }
        }
    }

    var body: some View {
        List {
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

            if manager.isICloudAvailable {
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

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(String(localized: "Encrypted portable backup"), systemImage: "lock.doc.fill")
                        .font(.headline)
                    Text(String(localized: "Export a password-protected .minisbak file for local storage or transfer to another device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ICloudBackupManager.BackupCategory.allCases) { category in
                        Button {
                            passwordMode = .export(category)
                            showPasswordSheet = true
                        } label: {
                            Label(String.localizedStringWithFormat(String(localized: "Export %@"), category.displayName), systemImage: "square.and.arrow.up")
                        }
                        .disabled(manager.isBackingUp || manager.isRestoring)
                    }
                    Button {
                        passwordMode = .restore
                        showFileImporter = true
                    } label: {
                        Label(String(localized: "Restore .minisbak file"), systemImage: "square.and.arrow.down")
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
            }

            if manager.isRestoring {
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

            if manager.availableBackups.isEmpty && manager.isICloudAvailable {
                Section {
                    Text(String(localized: "No backups found"))
                        .foregroundColor(.secondary)
                }
            }

            Section {
                // empty section for footer
            } footer: {
                Text(String(localized: "Backups are stored in iCloud Drive and sync across your devices. Restoring will replace your current local data."))
            }
        }
        .navigationTitle(String(localized: "iCloud Backup"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
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
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [UTType.data, UTType.item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importedURL = url
            passwordMode = .restore
            showPasswordSheet = true
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
                    _ = try await manager.exportEncryptedBackup(category: category, password: password)
                case .restore:
                    guard let importedURL else { return }
                    let accessed = importedURL.startAccessingSecurityScopedResource()
                    defer { if accessed { importedURL.stopAccessingSecurityScopedResource() } }
                    try await manager.restoreEncrypted(from: importedURL, password: password)
                    self.importedURL = nil
                }
            } catch {
                showError = error.localizedDescription
            }
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
