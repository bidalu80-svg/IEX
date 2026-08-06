import SwiftUI

// MARK: - View Model

class StorageManagementViewModel: ObservableObject {
    struct SessionStorage: Identifiable {
        let id: String
        let title: String?
        var zeSize: Int64 = 0
        var totalSize: Int64 { zeSize }
    }

    @Published var shellContainerSize: Int64 = 0
    @Published var chatDatabaseSize: Int64 = 0
    @Published var sessions: [SessionStorage] = []
    @Published var isLoading = true

    private let fm = FileManager.default
    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func format(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    var totalSessionSize: Int64 {
        sessions.reduce(0) { $0 + $1.totalSize }
    }

    func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let libraryURL = self.fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let documentsURL = self.fm.urls(for: .documentDirectory, in: .userDomainMask).first!

            // Shell container
            let rootfsURL = documentsURL.appendingPathComponent("alpine-rootfs", isDirectory: true)
            let shellSize = self.directorySize(at: rootfsURL)

            // Chat database
            let dbURL = libraryURL.appendingPathComponent("ZeChat/ze.db")
            let dbSize = self.fileSize(at: dbURL)

            // Per-session ze files: Library/ZeChat/ze/<sessionId>/
            let zeBaseURL = libraryURL.appendingPathComponent("ZeChat/ze", isDirectory: true)
            // Get all chat sessions
            let chatSessions = await ChatStore.shared.listSessions()

            // Build a set of session IDs
            let sessionIds = Set(chatSessions.map(\.id))

            // Enumerate ze directories
            var zeSizes: [String: Int64] = [:]
            if let contents = try? self.fm.contentsOfDirectory(at: zeBaseURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for dir in contents {
                    let sid = dir.lastPathComponent
                    if sessionIds.contains(sid) {
                        zeSizes[sid] = self.directorySize(at: dir)
                    }
                }
            }

            // Build session storage entries
            let sorted: [SessionStorage] = chatSessions.map { session in
                SessionStorage(
                    id: session.id,
                    title: session.title,
                    zeSize: zeSizes[session.id] ?? 0
                )
            }.sorted { $0.totalSize > $1.totalSize }

            await MainActor.run {
                self.shellContainerSize = shellSize
                self.chatDatabaseSize = dbSize
                self.sessions = sorted
                self.isLoading = false
            }
        }
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == false {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

// MARK: - Storage Management View

struct StorageManagementView: View {
    @StateObject private var vm = StorageManagementViewModel()

    var body: some View {
        List {
            Section("概览") {
                storageRow(icon: "terminal", color: .gray, label: "Shell 容器", value: vm.format(vm.shellContainerSize))
                storageRow(icon: "cylinder", color: .blue, label: "聊天数据库", value: vm.format(vm.chatDatabaseSize))
                storageRow(icon: "doc", color: .indigo, label: "会话文件", value: vm.format(vm.totalSessionSize))
            }

            Section("会话") {
                if vm.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if vm.sessions.isEmpty {
                    Text("暂无会话")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.sessions) { session in
                        NavigationLink {
                            SessionStorageDetailView(session: session, onFilesCleared: { vm.load() })
                        } label: {
                            HStack {
                                Text(session.title ?? "未命名")
                                    .lineLimit(1)
                                Spacer()
                                Text(vm.format(session.totalSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("存储")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.load() }
    }

    private func storageRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(color, in: Circle())
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Session Storage Detail View

struct SessionStorageDetailView: View {
    let session: StorageManagementViewModel.SessionStorage
    var onFilesCleared: (() -> Void)?

    @State private var showClearConfirmation = false
    @State private var isClearing = false
    @State private var currentZeSize: Int64

    init(session: StorageManagementViewModel.SessionStorage, onFilesCleared: (() -> Void)? = nil) {
        self.session = session
        self.onFilesCleared = onFilesCleared
        _currentZeSize = State(initialValue: session.zeSize)
    }

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    private var zeURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("ZeChat/ze/\(session.id)", isDirectory: true)
    }

    private var totalFileSize: Int64 { currentZeSize }
    private var hasFiles: Bool { totalFileSize > 0 }

    var body: some View {
        List {
            Section("Ze 文件") {
                if currentZeSize > 0 {
                    NavigationLink {
                        FileBrowserView(rootPath: zeURL)
                    } label: {
                        HStack {
                            Label("浏览文件", systemImage: "folder")
                            Spacer()
                            Text(formatter.string(fromByteCount: currentZeSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("暂无 Ze 文件")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    HStack {
                        if isClearing {
                            ProgressView()
                                .controlSize(.small)
                            Text("清理中…")
                        } else {
                            Label("清理会话文件", systemImage: "trash")
                        }
                        Spacer()
                        if !isClearing {
                            Text(formatter.string(fromByteCount: totalFileSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!hasFiles || isClearing)
            } footer: {
                Text("删除此会话生成的所有文件，但会保留聊天内容。")
            }
        }
        .navigationTitle(session.title ?? "会话")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清理会话文件？", isPresented: $showClearConfirmation) {
            Button("清理 \(formatter.string(fromByteCount: totalFileSize))", role: .destructive) {
                clearFiles()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("将删除 \(formatter.string(fromByteCount: totalFileSize)) 的文件，此操作无法撤销。")
        }
    }

    private func clearFiles() {
        isClearing = true
        let sessionId = session.id
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            let zeDir = lib.appendingPathComponent("ZeChat/ze/\(sessionId)", isDirectory: true)
            try? fm.removeItem(at: zeDir)

            await MainActor.run {
                currentZeSize = 0
                isClearing = false
                onFilesCleared?()
            }
        }
    }
}
