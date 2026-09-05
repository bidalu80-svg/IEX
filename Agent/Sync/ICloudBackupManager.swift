import Foundation
import SwiftUI
import UIKit
import SQLite3
import Compression
import CryptoKit
import Security
import os.log

private let logger = AppLogger(category: "ICloudBackup")

// MARK: - ICloudBackupManager

@MainActor
final class ICloudBackupManager: ObservableObject {

    static let shared = ICloudBackupManager()

    enum BackupCategory: String, CaseIterable, Identifiable {
        case sessions           // ze.db + media/ + ze/
        case skillsAndMemories  // skills.db + skills/ + memory/
        case full               // all

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .sessions: return String(localized: "Sessions")
            case .skillsAndMemories: return String(localized: "Skills & Memories")
            case .full: return String(localized: "Full Backup")
            }
        }

        var filePrefix: String {
            switch self {
            case .sessions: return "sessions"
            case .skillsAndMemories: return "skills-memories"
            case .full: return "full"
            }
        }

        var systemImage: String {
            switch self {
            case .sessions: return "bubble.left.and.bubble.right"
            case .skillsAndMemories: return "archivebox.fill"
            case .full: return "archivebox"
            }
        }

        var iconColor: Color {
            switch self {
            case .sessions:          return .blue
            case .skillsAndMemories: return .purple
            case .full:              return .orange
            }
        }

        var description: String {
            switch self {
            case .sessions:
                return String(localized: "Chat history, media attachments, and session workspace files")
            case .skillsAndMemories:
                return String(localized: "Skills, memory logs, and skill configuration files")
            case .full:
                return String(localized: "Complete backup including sessions, skills, and memories")
            }
        }
    }

    struct BackupEntry: Identifiable {
        let id: String          // file name
        let deviceName: String
        let category: BackupCategory
        let date: Date
        let fileSize: Int64
        let url: URL
    }

    struct BackupSelection: Codable, Equatable {
        var chats: Bool
        var sharedFiles: Bool
        var skills: Bool
        var memory: Bool
        var providers: Bool
        var mcpServers: Bool
        var environmentVariables: Bool

        static func forCategory(_ category: BackupCategory) -> BackupSelection {
            switch category {
            case .sessions:
                return .init(chats: true, sharedFiles: true, skills: false, memory: false,
                             providers: false, mcpServers: false, environmentVariables: false)
            case .skillsAndMemories:
                return .init(chats: false, sharedFiles: false, skills: true, memory: true,
                             providers: false, mcpServers: false, environmentVariables: false)
            case .full:
                return .init(chats: true, sharedFiles: true, skills: true, memory: true,
                             providers: true, mcpServers: true, environmentVariables: true)
            }
        }
    }

    enum BackupDestinationKind: String, Codable, CaseIterable, Identifiable {
        case localFolder
        case sftpServer
        case smbServer
        case webDAVServer
        case s3Bucket
        case ftpServer
        var id: String { rawValue }
        var title: String {
            switch self {
            case .localFolder: return String(localized: "Files folder")
            case .sftpServer: return String(localized: "SFTP server")
            case .smbServer: return String(localized: "SMB 共享")
            case .webDAVServer: return String(localized: "WebDAV")
            case .s3Bucket: return String(localized: "S3 兼容存储")
            case .ftpServer: return String(localized: "FTP")
            }
        }
    }

    struct BackupDestination: Codable, Identifiable, Hashable {
        var id: UUID
        var name: String
        var kind: BackupDestinationKind
        var bookmarkData: Data?
        var serverID: UUID?
        var remotePath: String?
        var remoteProfile: RemoteStorageProfile?
        init(id: UUID = UUID(), name: String, kind: BackupDestinationKind,
             bookmarkData: Data? = nil, serverID: UUID? = nil, remotePath: String? = nil,
             remoteProfile: RemoteStorageProfile? = nil) {
            self.id = id; self.name = name; self.kind = kind
            self.bookmarkData = bookmarkData; self.serverID = serverID; self.remotePath = remotePath; self.remoteProfile = remoteProfile
        }
    }

    @Published var isBackingUp = false
    @Published var isRestoring = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var availableBackups: [BackupEntry] = []
    @Published var lastExportURL: URL?
    @Published var isCancelled = false
    @Published private(set) var destinations: [BackupDestination] = []

    private let fm = FileManager.default
    private let containerID = "iCloud.com.ze.app"
    private let destinationsKey = "ze.backup.destinations.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: destinationsKey),
           let saved = try? JSONDecoder().decode([BackupDestination].self, from: data) {
            destinations = saved
        }
    }

    func saveDestination(_ destination: BackupDestination) {
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) { destinations[index] = destination }
        else { destinations.append(destination) }
        persistDestinations()
    }

    func removeDestination(_ destination: BackupDestination) {
        destinations.removeAll { $0.id == destination.id }
        persistDestinations()
    }

    private func persistDestinations() {
        if let data = try? JSONEncoder().encode(destinations) { UserDefaults.standard.set(data, forKey: destinationsKey) }
    }

    func backupEncrypted(category: BackupCategory, to destination: BackupDestination, password: String) async throws -> URL {
        try await backupEncrypted(category: category, selection: .forCategory(category), to: destination, password: password)
    }

    func backupEncrypted(category: BackupCategory, selection: BackupSelection, to destination: BackupDestination, password: String) async throws -> URL {
        let localURL = try await exportEncryptedBackup(category: category, selection: selection, password: password)
        switch destination.kind {
        case .localFolder:
            guard let bookmark = destination.bookmarkData else { throw BackupError.invalidDestination }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessed = folder.startAccessingSecurityScopedResource(); defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let target = folder.appendingPathComponent(localURL.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: localURL, to: target)
            return target
        case .sftpServer:
            guard let serverID = destination.serverID,
                  let profile = RemoteServerStore.shared.servers.first(where: { $0.id == serverID }) else { throw BackupError.invalidDestination }
            if !RemoteSSHConnectionService.shared.isConnected(to: serverID) { try await RemoteSSHConnectionService.shared.connect(to: profile) }
            let path = (destination.remotePath ?? "/").trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = path.hasSuffix("/") ? path + localURL.lastPathComponent : path + "/" + localURL.lastPathComponent
            try await RemoteSSHConnectionService.shared.uploadFile(try Data(contentsOf: localURL), to: remote, on: serverID)
            return localURL
        case .smbServer, .webDAVServer, .s3Bucket, .ftpServer:
            let client = try makeRemoteClient(for: destination)
            let remotePath = destination.remotePath ?? destination.remoteProfile?.path ?? "/"
            let remote = appendRemoteFile(remotePath, name: localURL.lastPathComponent)
            try await client.upload(data: Data(contentsOf: localURL), to: remote)
            return localURL
        }
    }

    func restoreEncrypted(from destination: BackupDestination, fileName: String, password: String) async throws {
        switch destination.kind {
        case .localFolder:
            guard let bookmark = destination.bookmarkData else { throw BackupError.invalidDestination }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessed = folder.startAccessingSecurityScopedResource(); defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            try await restoreEncrypted(from: folder.appendingPathComponent(fileName), password: password)
        case .sftpServer:
            guard let serverID = destination.serverID,
                  let profile = RemoteServerStore.shared.servers.first(where: { $0.id == serverID }) else { throw BackupError.invalidDestination }
            if !RemoteSSHConnectionService.shared.isConnected(to: serverID) { try await RemoteSSHConnectionService.shared.connect(to: profile) }
            let path = (destination.remotePath ?? "/").trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = path.hasSuffix("/") ? path + fileName : path + "/" + fileName
            let data = try await RemoteSSHConnectionService.shared.downloadFile(at: remote, on: serverID)
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zebak")
            try data.write(to: temp, options: .atomic); defer { try? fm.removeItem(at: temp) }
            try await restoreEncrypted(from: temp, password: password)
        case .smbServer, .webDAVServer, .s3Bucket, .ftpServer:
            let client = try makeRemoteClient(for: destination)
            let remote = appendRemoteFile(destination.remotePath ?? destination.remoteProfile?.path ?? "/", name: fileName)
            let data = try await client.download(path: remote)
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zebak")
            try data.write(to: temp, options: .atomic); defer { try? fm.removeItem(at: temp) }
            try await restoreEncrypted(from: temp, password: password)
        }
    }

    func listEncryptedBackups(in destination: BackupDestination) async throws -> [RemoteSFTPEntry] {
        switch destination.kind {
        case .localFolder:
            guard let bookmark = destination.bookmarkData else { throw BackupError.invalidDestination }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessed = folder.startAccessingSecurityScopedResource(); defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            return try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "zebak" }
                .map { url in
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    return RemoteSFTPEntry(path: url.path, name: url.lastPathComponent, isDirectory: false,
                                           size: UInt64(values?.fileSize ?? 0), modifiedAt: values?.contentModificationDate, permissions: nil)
                }
                .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .sftpServer:
            guard let serverID = destination.serverID,
                  let profile = RemoteServerStore.shared.servers.first(where: { $0.id == serverID }) else { throw BackupError.invalidDestination }
            if !RemoteSSHConnectionService.shared.isConnected(to: serverID) { try await RemoteSSHConnectionService.shared.connect(to: profile) }
            let path = (destination.remotePath ?? "/").trimmingCharacters(in: .whitespacesAndNewlines)
            return try await RemoteSSHConnectionService.shared.listDirectory(at: path.isEmpty ? "/" : path, on: serverID)
                .filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".zebak") }
        case .smbServer, .webDAVServer, .s3Bucket, .ftpServer:
            let client = try makeRemoteClient(for: destination)
            return try await client.list(path: destination.remotePath ?? destination.remoteProfile?.path ?? "/")
                .filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".zebak") }
        }
    }

    private func appendRemoteFile(_ path: String, name: String) -> String {
        let root = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty || root == "/" { return "/" + name }
        return root.hasSuffix("/") ? root + name : root + "/" + name
    }

    private func makeRemoteClient(for destination: BackupDestination) throws -> any RemoteStorageClient {
        guard let profile = destination.remoteProfile else { throw BackupError.invalidDestination }
        let secret = try RemoteServerSecretStore.value(kind: .remoteSecret, for: profile.id) ?? ""
        switch profile.proto {
        case .smb: return try SMBRemoteStorageClient(profile: profile, password: secret)
        case .webdav: return try WebDAVRemoteStorageClient(profile: profile, password: secret)
        case .s3: return try S3RemoteStorageClient(profile: profile, secret: secret)
        case .ftp: return try FTPRemoteStorageClient(profile: profile, password: secret)
        case .sftp: throw BackupError.invalidDestination
        }
    }

    // MARK: - iCloud Container

    private var iCloudContainerURL: URL? {
        fm.url(forUbiquityContainerIdentifier: containerID)
    }

    var isICloudAvailable: Bool { iCloudContainerURL != nil }

    private var backupDirectoryURL: URL? {
        guard let container = iCloudContainerURL else { return nil }
        let deviceName = DeviceIdentity.modelName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return container
            .appendingPathComponent("Documents/backups/\(deviceName)", isDirectory: true)
    }

    private var backupsRootURL: URL? {
        guard let container = iCloudContainerURL else { return nil }
        return container.appendingPathComponent("Documents/backups", isDirectory: true)
    }

    // MARK: - Local Paths

    private var zeBaseURL: URL {
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("ZeChat", isDirectory: true)
    }

    private var zeDBURL: URL { zeBaseURL.appendingPathComponent("ze.db") }
    private var skillsDBURL: URL { zeBaseURL.appendingPathComponent("skills.db") }
    private var mediaURL: URL { zeBaseURL.appendingPathComponent("media", isDirectory: true) }
    private var sessionZeURL: URL { zeBaseURL.appendingPathComponent("ze", isDirectory: true) }
    private var skillsURL: URL { zeBaseURL.appendingPathComponent("skills", isDirectory: true) }
    private var memoryURL: URL { zeBaseURL.appendingPathComponent("memory", isDirectory: true) }

    /// Local encrypted backup directory. Files use the portable `.zebak`
    /// envelope so they can be shared or copied to another device without
    /// exposing the staged ZIP contents.
    private var localBackupDirectoryURL: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ze/Backups", isDirectory: true)
    }

    func cancelCurrentOperation() {
        isCancelled = true
    }

    /// Export an encrypted, portable `.zebak` file. The password is never
    /// persisted or written to logs; callers should collect it in a secure
    /// text field and discard it after this method returns.
    func exportEncryptedBackup(category: BackupCategory, password: String) async throws -> URL {
        try await exportEncryptedBackup(category: category, selection: .forCategory(category), password: password)
    }

    func exportEncryptedBackup(category: BackupCategory, selection: BackupSelection, password: String) async throws -> URL {
        guard !password.isEmpty else { throw BackupError.emptyPassword }
        guard !isBackingUp, !isRestoring else { throw BackupError.busy }
        isBackingUp = true
        isCancelled = false
        progress = 0
        defer { isBackingUp = false; statusMessage = "" }

        try fm.createDirectory(at: localBackupDirectoryURL, withIntermediateDirectories: true)
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let stageDir = tempDir.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
        statusMessage = String(localized: "Preparing encrypted backup…")
        try checkCancelled()
        try await stageSelectedFiles(selection, to: stageDir)
        progress = 0.55
        try checkCancelled()
        let zipURL = tempDir.appendingPathComponent("payload.zip")
        try await createZip(from: stageDir, to: zipURL)
        progress = 0.75
        let encrypted = try encryptArchive(Data(contentsOf: zipURL), password: password)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let output = localBackupDirectoryURL.appendingPathComponent("\(category.filePrefix)_\(stamp).zebak")
        try encrypted.write(to: output, options: .atomic)
        progress = 1
        lastExportURL = output
        logger.info("Encrypted backup exported (category=\(category.rawValue), bytes=\(encrypted.count))")
        return output
    }

    /// Restore from a password-protected `.zebak` file. The decrypted
    /// payload is kept in a temporary directory and removed on every path.
    func restoreEncrypted(from url: URL, password: String) async throws {
        guard !password.isEmpty else { throw BackupError.emptyPassword }
        guard !isBackingUp, !isRestoring else { throw BackupError.busy }
        isRestoring = true
        isCancelled = false
        progress = 0
        defer { isRestoring = false; statusMessage = "" }
        let data = try Data(contentsOf: url)
        let zipData = try decryptArchive(data, password: password)
        try checkCancelled()
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }
        let zipURL = tempDir.appendingPathComponent("payload.zip")
        try zipData.write(to: zipURL, options: .atomic)
        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        statusMessage = String(localized: "Extracting encrypted backup…")
        try extractZip(at: zipURL, to: extractDir)
        let contentDir = extractDir.appendingPathComponent("backup", isDirectory: true)
        let root = fm.fileExists(atPath: contentDir.path) ? contentDir : extractDir
        progress = 0.55
        if fm.fileExists(atPath: root.appendingPathComponent("ze.db").path) || fm.fileExists(atPath: root.appendingPathComponent("media").path) {
            try await restoreSessionFiles(from: root)
        }
        let sharedSrc = root.appendingPathComponent("shared-files")
        if fm.fileExists(atPath: sharedSrc.path), let sharedDir = SharedContainerStore.sharedFileDirectory {
            try fm.createDirectory(at: sharedDir, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(at: sharedSrc, includingPropertiesForKeys: nil) {
                let target = sharedDir.appendingPathComponent(item.lastPathComponent)
                try replaceRestoredItem(at: target, with: item)
            }
        }
        if fm.fileExists(atPath: root.appendingPathComponent("skills.db").path) || fm.fileExists(atPath: root.appendingPathComponent("skills").path) || fm.fileExists(atPath: root.appendingPathComponent("memory").path) {
            try await restoreSkillsAndMemoryFiles(from: root)
        }
        try await restoreConfigurationFiles(from: root)
        await ChatStore.shared.reloadDatabase()
        await SkillStore.shared.reloadDatabase()
        progress = 1
        logger.info("Encrypted backup restored")
    }

    private func checkCancelled() throws {
        if isCancelled || Task.isCancelled { throw BackupError.cancelled }
    }

    /// Stage beside the destination and swap by rename. The previous item is
    /// restored if the final rename fails, so restore never deletes first.
    private func replaceRestoredItem(at target: URL, with source: URL) throws {
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let staged = parent.appendingPathComponent(".ze-restore-new-\(token)")
        let previous = parent.appendingPathComponent(".ze-restore-old-\(token)")
        defer { try? fm.removeItem(at: staged) }

        try fm.copyItem(at: source, to: staged)
        guard fm.fileExists(atPath: target.path) else {
            try fm.moveItem(at: staged, to: target)
            return
        }

        try fm.moveItem(at: target, to: previous)
        do {
            try fm.moveItem(at: staged, to: target)
            try? fm.removeItem(at: previous)
        } catch {
            if !fm.fileExists(atPath: target.path) {
                do {
                    try fm.moveItem(at: previous, to: target)
                } catch let rollbackError {
                    logger.error("Restore rollback failed for \(target.path): \(rollbackError.localizedDescription)")
                }
            }
            throw error
        }
    }

    private func encryptArchive(_ archive: Data, password: String) throws -> Data {
        var salt = Data(count: 16)
        let saltResult = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard saltResult == errSecSuccess else { throw BackupError.encryptionError }
        let material = SymmetricKey(data: Data(password.utf8))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("ZeBackup-v1".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(archive, using: key)
        guard let combined = sealed.combined else { throw BackupError.encryptionError }
        return Data("ZEBAK1".utf8) + salt + combined
    }

    private func decryptArchive(_ data: Data, password: String) throws -> Data {
        let header = Data("ZEBAK1".utf8)
        guard data.count > header.count + 16, data.prefix(header.count) == header else { throw BackupError.invalidEncryptedBackup }
        let saltStart = header.count
        let salt = data.subdata(in: saltStart..<(saltStart + 16))
        let combined = data.subdata(in: (saltStart + 16)..<data.count)
        let material = SymmetricKey(data: Data(password.utf8))
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: salt, info: Data("ZeBackup-v1".utf8), outputByteCount: 32)
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: combined), using: key) }
        catch { throw BackupError.invalidPassword }
    }

    // MARK: - Backup

    func backup(category: BackupCategory) async throws {
        guard !isBackingUp, !isRestoring else { throw BackupError.busy }
        guard let destDir = backupDirectoryURL else {
            throw BackupError.iCloudUnavailable
        }

        isBackingUp = true
        isCancelled = false
        progress = 0
        statusMessage = String(localized: "Preparing backup…")
        defer {
            isBackingUp = false
            statusMessage = ""
        }

        // Ensure destination directory exists
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create temp staging directory
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let stageDir = tempDir.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)

        // Stage files based on category
        try checkCancelled()
        statusMessage = String(localized: "Copying files…")
        progress = 0.1

        switch category {
        case .sessions:
            try await stageSessionFiles(to: stageDir)
        case .skillsAndMemories:
            try await stageSkillsAndMemoryFiles(to: stageDir)
        case .full:
            try await stageSessionFiles(to: stageDir)
            try await stageSkillsAndMemoryFiles(to: stageDir)
        }

        progress = 0.6
        try checkCancelled()
        statusMessage = String(localized: "Creating archive…")

        // Create ZIP
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let zipName = "\(category.filePrefix)_\(timestamp).zip"
        let zipURL = tempDir.appendingPathComponent(zipName)

        try await createZip(from: stageDir, to: zipURL)

        progress = 0.8
        try checkCancelled()
        statusMessage = String(localized: "Uploading to iCloud…")

        // Move ZIP to iCloud
        let destURL = destDir.appendingPathComponent(zipName)
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: zipURL, to: destURL)

        progress = 1.0
        statusMessage = String(localized: "Backup complete")
        logger.info("Backup created: \(zipName)")

        // Refresh backup list
        await listBackups()
    }

    // MARK: - Stage Files

    private func stageSessionFiles(to dir: URL) async throws {
        // WAL checkpoint ze.db before copying
        try walCheckpoint(dbPath: zeDBURL.path)

        // Copy ze.db
        let dbDest = dir.appendingPathComponent("ze.db")
        if fm.fileExists(atPath: zeDBURL.path) {
            try fm.copyItem(at: zeDBURL, to: dbDest)
        }

        // Copy media/
        if fm.fileExists(atPath: mediaURL.path) {
            try copyDirectory(mediaURL, to: dir.appendingPathComponent("media"))
        }

        // Copy ze/ (session workspace files)
        if fm.fileExists(atPath: sessionZeURL.path) {
            try copyDirectory(sessionZeURL, to: dir.appendingPathComponent("ze"))
        }
    }

    private func stageSkillsAndMemoryFiles(to dir: URL) async throws {
        // WAL checkpoint skills.db before copying
        try walCheckpoint(dbPath: skillsDBURL.path)

        // Copy skills.db
        if fm.fileExists(atPath: skillsDBURL.path) {
            try fm.copyItem(at: skillsDBURL, to: dir.appendingPathComponent("skills.db"))
        }

        // Copy skills/
        if fm.fileExists(atPath: skillsURL.path) {
            try fm.copyItem(at: skillsURL, to: dir.appendingPathComponent("skills"))
        }

        // Copy memory/
        if fm.fileExists(atPath: memoryURL.path) {
            try fm.copyItem(at: memoryURL, to: dir.appendingPathComponent("memory"))
        }
    }

    private func stageSelectedFiles(_ selection: BackupSelection, to dir: URL) async throws {
        if selection.chats { try await stageSessionFiles(to: dir) }
        if selection.sharedFiles, let shared = SharedContainerStore.sharedFileDirectory,
           fm.fileExists(atPath: shared.path) {
            try copyDirectory(shared, to: dir.appendingPathComponent("shared-files"))
        }
        if selection.skills { try await stageSkillsFiles(to: dir) }
        if selection.memory { try await stageMemoryFiles(to: dir) }
        if selection.providers || selection.mcpServers || selection.environmentVariables {
            try await stageConfigurationFiles(to: dir, providers: selection.providers,
                                              mcpServers: selection.mcpServers,
                                              environmentVariables: selection.environmentVariables)
        }
    }

    private func stageSkillsFiles(to dir: URL) async throws {
        try walCheckpoint(dbPath: skillsDBURL.path)
        if fm.fileExists(atPath: skillsDBURL.path) { try fm.copyItem(at: skillsDBURL, to: dir.appendingPathComponent("skills.db")) }
        if fm.fileExists(atPath: skillsURL.path) { try copyDirectory(skillsURL, to: dir.appendingPathComponent("skills")) }
    }

    private func stageMemoryFiles(to dir: URL) async throws {
        if fm.fileExists(atPath: memoryURL.path) { try copyDirectory(memoryURL, to: dir.appendingPathComponent("memory")) }
    }

    private func copyDirectory(_ source: URL, to destination: URL) throws {
        let limit = UserDefaults.standard.integer(forKey: "ze.backup.maxFileSizeMB")
        let maximumBytes = limit < 0 ? 0 : max(1, limit == 0 ? 100 : limit) * 1_024 * 1_024
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else { return }
        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if maximumBytes > 0 && (values.fileSize ?? 0) <= maximumBytes {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item, to: target)
            } else {
                logger.warning("Skipped backup file over configured limit: \(relative)")
            }
        }
    }

    private func stageConfigurationFiles(to dir: URL, providers: Bool = true, mcpServers: Bool = true, environmentVariables: Bool = true) async throws {
        if providers {
            let providersDir = dir.appendingPathComponent("providers", isDirectory: true)
            try fm.createDirectory(at: providersDir, withIntermediateDirectories: true)
            let exports = ProviderConfigStore.shared.instances.compactMap { ProviderConfigStore.shared.exportInstanceJSON($0.id) }
            try JSONEncoder().encode(exports).write(to: providersDir.appendingPathComponent("providers.json"), options: .atomic)
        }
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let envURL = library.appendingPathComponent("ZeChat/env-vars.json")
        if environmentVariables, fm.fileExists(atPath: envURL.path) { try fm.copyItem(at: envURL, to: dir.appendingPathComponent("env-vars.json")) }
        let mcpURL = MCPStore.syncFileURL
        if mcpServers, fm.fileExists(atPath: mcpURL.path) { try fm.copyItem(at: mcpURL, to: dir.appendingPathComponent("mcp-servers.json")) }
    }

    private func restoreConfigurationFiles(from dir: URL) async throws {
        let providersURL = dir.appendingPathComponent("providers/providers.json")
        if let data = try? Data(contentsOf: providersURL), let exports = try? JSONDecoder().decode([String].self, from: data) {
            for json in exports { _ = ProviderConfigStore.shared.importInstanceJSON(json) }
        }
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let envURL = library.appendingPathComponent("ZeChat/env-vars.json")
        let envSrc = dir.appendingPathComponent("env-vars.json")
        if fm.fileExists(atPath: envSrc.path) {
            try replaceRestoredItem(at: envURL, with: envSrc)
        }
        let mcpSrc = dir.appendingPathComponent("mcp-servers.json")
        if fm.fileExists(atPath: mcpSrc.path) {
            try replaceRestoredItem(at: MCPStore.syncFileURL, with: mcpSrc)
            MCPStore.shared.load()
        }
    }

    // MARK: - WAL Checkpoint

    private func walCheckpoint(dbPath: String) throws {
        guard fm.fileExists(atPath: dbPath) else { return }

        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK, let db = db else {
            throw BackupError.databaseError("Failed to open DB for checkpoint: \(rc)")
        }
        defer { sqlite3_close(db) }

        let checkpointRC = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        if checkpointRC != SQLITE_OK {
            logger.warning("WAL checkpoint returned \(checkpointRC) for \(dbPath)")
        }
    }

    // MARK: - ZIP Creation (using NSFileCoordinator)

    private func createZip(from sourceDir: URL, to zipURL: URL) async throws {
        // Use Foundation's built-in ZIP capability via NSFileCoordinator
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let coordinator = NSFileCoordinator()
            var error: NSError?

            coordinator.coordinate(readingItemAt: sourceDir,
                                   options: .forUploading,
                                   error: &error) { zippedURL in
                do {
                    try self.fm.copyItem(at: zippedURL, to: zipURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let error = error {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Unzip

    private func unzip(from zipURL: URL, to destDir: URL) async throws {
        // Use Process/spawning is unavailable on iOS, use a manual approach
        // We'll use NSFileCoordinator reading + FileManager to extract
        // Actually, on iOS we need a different approach since there's no built-in unzip API
        // We'll shell out to the approach of creating a temp dir and using the
        // compression framework, or use a simple custom unzip

        // For iOS, the simplest approach is to use the `Archive` type if available,
        // or we can use the command-line zip format. Let's use a minimal unzip implementation.
        try extractZip(at: zipURL, to: destDir)
    }

    /// Minimal ZIP extraction using Apple's compression support.
    /// ZIP files created by NSFileCoordinator are standard ZIP archives.
    private func extractZip(at zipURL: URL, to destination: URL) throws {
        let zipData = try Data(contentsOf: zipURL)
        guard zipData.count >= 22 else {
            throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Parse ZIP file structure
        try zipData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else {
                throw BackupError.zipError("Empty ZIP data")
            }
            let size = buffer.count

            // Find End of Central Directory record
            var eocdOffset = -1
            for i in stride(from: size - 22, through: 0, by: -1) {
                let sig = base.load(fromByteOffset: i, as: UInt32.self)
                if sig == 0x06054b50 {
                    eocdOffset = i
                    break
                }
            }

            guard eocdOffset >= 0 else {
                throw BackupError.zipError("Invalid ZIP: no EOCD")
            }

            let cdOffset = Int(base.load(fromByteOffset: eocdOffset + 16, as: UInt32.self))
            let cdEntries = Int(base.load(fromByteOffset: eocdOffset + 10, as: UInt16.self))
            guard cdEntries <= 100_000, cdOffset >= 0, cdOffset <= size else {
                throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
            }

            var offset = cdOffset
            var totalUncompressedSize = 0
            let maximumExtractedSize = 2 * 1_024 * 1_024 * 1_024
            for _ in 0..<cdEntries {
                guard offset >= 0, offset <= size - 46 else {
                    throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
                }
                let sig = base.load(fromByteOffset: offset, as: UInt32.self)
                guard sig == 0x02014b50 else {
                    throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
                }

                let method = base.load(fromByteOffset: offset + 10, as: UInt16.self)
                let compressedSize = Int(base.load(fromByteOffset: offset + 20, as: UInt32.self))
                let uncompressedSize = Int(base.load(fromByteOffset: offset + 24, as: UInt32.self))
                let nameLen = Int(base.load(fromByteOffset: offset + 28, as: UInt16.self))
                let extraLen = Int(base.load(fromByteOffset: offset + 30, as: UInt16.self))
                let commentLen = Int(base.load(fromByteOffset: offset + 32, as: UInt16.self))
                let localHeaderOffset = Int(base.load(fromByteOffset: offset + 42, as: UInt32.self))
                let nextOffset = offset + 46 + nameLen + extraLen + commentLen
                guard nextOffset >= offset, nextOffset <= size else {
                    throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
                }
                totalUncompressedSize += uncompressedSize
                guard totalUncompressedSize <= maximumExtractedSize else {
                    throw BackupError.zipError(String(localized: "The backup archive is too large."))
                }

                let nameData = Data(bytes: base + offset + 46, count: nameLen)
                let name = String(data: nameData, encoding: .utf8) ?? ""

                // Skip to next central directory entry
                offset = nextOffset

                // Read from local file header
                guard localHeaderOffset >= 0, localHeaderOffset <= size - 30 else {
                    throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
                }
                let localNameLen = Int(base.load(fromByteOffset: localHeaderOffset + 26, as: UInt16.self))
                let localExtraLen = Int(base.load(fromByteOffset: localHeaderOffset + 28, as: UInt16.self))
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen

                // Reject absolute paths and traversal components before
                // materialising archive entries. Backups can come from
                // another device, so the archive is untrusted input.
                guard !name.hasPrefix("/"), !name.contains("\\0") else {
                    throw BackupError.zipError(String(localized: "The backup archive contains an unsafe path."))
                }
                let fileURL = destination.appendingPathComponent(name).standardizedFileURL
                let destinationPrefix = destination.standardizedFileURL.path.hasSuffix("/")
                    ? destination.standardizedFileURL.path
                    : destination.standardizedFileURL.path + "/"
                guard fileURL.path == destination.standardizedFileURL.path || fileURL.path.hasPrefix(destinationPrefix) else {
                    throw BackupError.zipError(String(localized: "The backup archive contains an unsafe path."))
                }

                if name.hasSuffix("/") {
                    // Directory
                    try fm.createDirectory(at: fileURL, withIntermediateDirectories: true)
                } else {
                    // File
                    try fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)

                    if method == 0 {
                        // Stored (no compression)
                        guard dataStart >= 0, uncompressedSize >= 0,
                              dataStart <= size, uncompressedSize <= size - dataStart else {
                            throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
                        }
                        let fileData = Data(bytes: base + dataStart, count: uncompressedSize)
                        try fileData.write(to: fileURL)
                    } else if method == 8 {
                        // Deflate
                        guard dataStart >= 0, compressedSize >= 0,
                              dataStart <= size, compressedSize <= size - dataStart else {
                            throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
                        }
                        let compressedData = Data(bytes: base + dataStart, count: compressedSize)
                        let decompressed = try decompressDeflate(compressedData, expectedSize: uncompressedSize)
                        try decompressed.write(to: fileURL)
                    } else {
                        throw BackupError.zipError(String(localized: "The backup archive uses an unsupported compression method."))
                    }
                }
            }
        }
    }

    private func decompressDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        // Use Compression framework for raw deflate
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(expectedSize, 1))
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { (srcBuffer: UnsafeRawBufferPointer) -> Int in
            guard let src = srcBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, expectedSize,
                src, data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize == expectedSize else {
            throw BackupError.zipError(String(localized: "The backup archive is incomplete or damaged."))
        }

        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    // MARK: - List Backups

    @discardableResult
    func listBackups() async -> [BackupEntry] {
        guard let root = backupsRootURL else {
            availableBackups = []
            return []
        }

        var entries: [BackupEntry] = []

        do {
            // Ensure directory exists
            if !fm.fileExists(atPath: root.path) {
                try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            }

            let deviceDirs = try fm.contentsOfDirectory(at: root,
                                                         includingPropertiesForKeys: [.isDirectoryKey])
            for deviceDir in deviceDirs {
                let isDir = (try? deviceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }

                let deviceName = deviceDir.lastPathComponent
                let files = (try? fm.contentsOfDirectory(at: deviceDir,
                                                          includingPropertiesForKeys: [.fileSizeKey])) ?? []

                for file in files {
                    guard file.pathExtension == "zip" else { continue }
                    let name = file.deletingPathExtension().lastPathComponent

                    guard let entry = parseBackupFileName(name, deviceName: deviceName, url: file) else {
                        continue
                    }
                    entries.append(entry)
                }
            }
        } catch {
            logger.error("Failed to list backups: \(error.localizedDescription)")
        }

        entries.sort { $0.date > $1.date }
        availableBackups = entries
        return entries
    }

    private func parseBackupFileName(_ name: String, deviceName: String, url: URL) -> BackupEntry? {
        // Format: <category>_<yyyy-MM-dd_HHmmss>
        let parts = name.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let categoryStr = String(parts[0])
        let dateStr = String(parts[1])

        let category: BackupCategory
        switch categoryStr {
        case "sessions": category = .sessions
        case "skills-memories": category = .skillsAndMemories
        case "full": category = .full
        default: return nil
        }

        // Re-parse: prefix may contain hyphen (skills-memories)
        let actualDateStr: String
        if categoryStr == "skills-memories" {
            // name = "skills-memories_2026-03-05_143022"
            let underscoreParts = name.components(separatedBy: "_")
            // ["skills-memories", "2026-03-05", "143022"]
            guard underscoreParts.count >= 3 else { return nil }
            actualDateStr = underscoreParts[1] + "_" + underscoreParts[2]
        } else {
            actualDateStr = dateStr
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        guard let date = formatter.date(from: actualDateStr) else { return nil }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

        return BackupEntry(id: name, deviceName: deviceName, category: category,
                          date: date, fileSize: fileSize, url: url)
    }

    // MARK: - Restore

    func restore(from entry: BackupEntry) async throws {
        guard !isBackingUp, !isRestoring else { throw BackupError.busy }

        isRestoring = true
        isCancelled = false
        progress = 0
        statusMessage = String(localized: "Downloading backup…")
        defer {
            isRestoring = false
            statusMessage = ""
        }

        // Ensure file is downloaded from iCloud
        try await ensureDownloaded(entry.url)
        try checkCancelled()

        progress = 0.3
        statusMessage = String(localized: "Extracting backup…")

        // Extract to temp directory
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try await unzip(from: entry.url, to: extractDir)
        try checkCancelled()

        // The ZIP may contain a "backup" subdirectory from our staging
        let contentDir: URL
        let backupSubdir = extractDir.appendingPathComponent("backup", isDirectory: true)
        if fm.fileExists(atPath: backupSubdir.path) {
            contentDir = backupSubdir
        } else {
            contentDir = extractDir
        }

        progress = 0.5
        try checkCancelled()
        statusMessage = String(localized: "Restoring data…")

        // Restore based on category
        switch entry.category {
        case .sessions:
            try await restoreSessionFiles(from: contentDir)
        case .skillsAndMemories:
            try await restoreSkillsAndMemoryFiles(from: contentDir)
        case .full:
            try await restoreSessionFiles(from: contentDir)
            try await restoreSkillsAndMemoryFiles(from: contentDir)
        }

        progress = 0.9
        statusMessage = String(localized: "Reloading…")

        // Reload stores
        await ChatStore.shared.reloadDatabase()
        await SkillStore.shared.reloadDatabase()

        progress = 1.0
        statusMessage = String(localized: "Restore complete")
        logger.info("Restored backup: \(entry.id)")
    }

    private func restoreSessionFiles(from dir: URL) async throws {
        var databaseClosed = false
        do {
        let dbSrc = dir.appendingPathComponent("ze.db")
        if fm.fileExists(atPath: dbSrc.path) {
            // Close existing DB connection before replacing
            await ChatStore.shared.closeDatabase()
            databaseClosed = true

            // Also remove WAL and SHM files
            let walPath = zeDBURL.path + "-wal"
            let shmPath = zeDBURL.path + "-shm"
            try? fm.removeItem(atPath: walPath)
            try? fm.removeItem(atPath: shmPath)

            try replaceRestoredItem(at: zeDBURL, with: dbSrc)
        }

        let mediaSrc = dir.appendingPathComponent("media")
        if fm.fileExists(atPath: mediaSrc.path) {
            try replaceRestoredItem(at: mediaURL, with: mediaSrc)
        }

        let zeSrc = dir.appendingPathComponent("ze")
        if fm.fileExists(atPath: zeSrc.path) {
            try replaceRestoredItem(at: sessionZeURL, with: zeSrc)
        }
        } catch {
            if databaseClosed { await ChatStore.shared.reloadDatabase() }
            throw error
        }
    }

    private func restoreSkillsAndMemoryFiles(from dir: URL) async throws {
        var databaseClosed = false
        do {
        let dbSrc = dir.appendingPathComponent("skills.db")
        if fm.fileExists(atPath: dbSrc.path) {
            await SkillStore.shared.closeDatabase()
            databaseClosed = true

            let walPath = skillsDBURL.path + "-wal"
            let shmPath = skillsDBURL.path + "-shm"
            try? fm.removeItem(atPath: walPath)
            try? fm.removeItem(atPath: shmPath)

            try replaceRestoredItem(at: skillsDBURL, with: dbSrc)
        }

        let skillsSrc = dir.appendingPathComponent("skills")
        if fm.fileExists(atPath: skillsSrc.path) {
            try replaceRestoredItem(at: skillsURL, with: skillsSrc)
        }

        let memorySrc = dir.appendingPathComponent("memory")
        if fm.fileExists(atPath: memorySrc.path) {
            try replaceRestoredItem(at: memoryURL, with: memorySrc)
        }
        } catch {
            if databaseClosed { await SkillStore.shared.reloadDatabase() }
            throw error
        }
    }

    // MARK: - Download from iCloud

    private func ensureDownloaded(_ url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if values.ubiquitousItemDownloadingStatus == .current {
            return
        }

        try fm.startDownloadingUbiquitousItem(at: url)

        // Poll until downloaded (with timeout)
        let deadline = Date().addingTimeInterval(120) // 2 min timeout
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            let updated = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if updated.ubiquitousItemDownloadingStatus == .current {
                return
            }
        }

        throw BackupError.downloadTimeout
    }

    // MARK: - Delete Backup

    func deleteBackup(_ entry: BackupEntry) throws {
        try fm.removeItem(at: entry.url)
        availableBackups.removeAll { $0.id == entry.id }
    }

    // MARK: - Errors

    enum BackupError: LocalizedError {
        case iCloudUnavailable
        case databaseError(String)
        case zipError(String)
        case downloadTimeout
        case emptyPassword
        case invalidEncryptedBackup
        case invalidPassword
        case encryptionError
        case cancelled
        case busy
        case invalidDestination

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable: return String(localized: "iCloud is not available. Please sign in to iCloud in Settings.")
            case .databaseError(let msg): return String(format: String(localized: "Database error: %@"), msg)
            case .zipError(let msg): return String(format: String(localized: "Archive error: %@"), msg)
            case .downloadTimeout: return String(localized: "Timed out downloading backup from iCloud.")
            case .emptyPassword: return String(localized: "Choose a password for this backup.")
            case .invalidEncryptedBackup: return String(localized: "The selected file is not a valid Ze encrypted backup.")
            case .invalidPassword: return String(localized: "The backup password is incorrect.")
            case .encryptionError: return String(localized: "Unable to encrypt the backup.")
            case .cancelled: return String(localized: "Backup operation cancelled.")
            case .busy: return String(localized: "Another backup operation is already running.")
            case .invalidDestination: return String(localized: "The backup destination is unavailable or incomplete.")
            }
        }
    }
}

// MARK: - Helpers

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
