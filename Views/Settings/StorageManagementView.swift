import SwiftUI

// MARK: - View Model

@MainActor
class StorageManagementViewModel: ObservableObject {
    struct SessionStorage: Identifiable {
        let id: String
        let title: String?
        let usage: StorageUsage
        var zeSize: Int64 { usage.bytes }
    }

    @Published var sessions: [SessionStorage] = []
    @Published var isLoading = true
    @Published private(set) var deletingSessionIDs = Set<String>()

    private var loadTask: Task<Void, Never>?
    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func format(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    func format(_ usage: StorageUsage) -> String {
        guard usage.failed > 0 else { return format(usage.bytes) }
        return "已统计 \(format(usage.bytes))"
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let chatSessions = await ChatStore.shared.listSessions()
            guard !Task.isCancelled else { return }
            let sessionIDs = chatSessions.map(\.id)
            let scan = Task.detached(priority: .utility) {
                guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return [String: StorageUsage]() }
                let root = library.appendingPathComponent("ZeChat/ze", isDirectory: true)
                return sessionIDs.reduce(into: [String: StorageUsage]()) { result, id in
                    guard !Task.isCancelled else { return }
                    result[id] = StorageMaintenance.measure(root.appendingPathComponent(id, isDirectory: true)) ?? StorageUsage()
                }
            }
            let result = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.sessions = chatSessions.map { session in
                SessionStorage(
                    id: session.id,
                    title: session.title,
                    usage: result[session.id] ?? StorageUsage(failed: 1)
                )
            }.sorted { $0.zeSize > $1.zeSize }
            self.isLoading = false
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
    }
}

// MARK: - Storage Management View

@MainActor
struct StorageManagementView: View {
    private enum CleanupTarget: String, CaseIterable, Identifiable {
        case temporary, caches, browser

        var id: Self { self }

        var title: String {
            switch self {
            case .temporary: return "临时文件"
            case .caches: return "缓存"
            case .browser: return "浏览器缓存"
            }
        }
    }

    private struct StorageSnapshot {
        let occupancy: StorageMaintenance.Occupancy
        let caches: StorageUsage
        let drafts: StorageUsage
        let browser: StorageUsage?
    }

    private enum StorageAlert: Identifiable {
        case deleteSession(StorageManagementViewModel.SessionStorage)
        case confirmCleanup(CleanupTarget)
        case cleanupResult(CleanupTarget, StorageMaintenance.Cleanup)

        var id: Int {
            switch self {
            case .deleteSession: return 0
            case .confirmCleanup: return 1
            case .cleanupResult: return 2
            }
        }
    }

    @StateObject private var vm = StorageManagementViewModel()
    @State private var storageAlert: StorageAlert?
    @State private var snapshot: StorageSnapshot?
    @State private var cleaning: CleanupTarget?

    var body: some View {
        List {
            Section("存储占用") {
                usageRow("总占用", snapshot?.occupancy.total)
                usageRow("Documents", snapshot?.occupancy.documents)
                usageRow("Library", snapshot?.occupancy.library)
                usageRow("tmp", snapshot?.occupancy.temporary)
            }
            Section("清理") {
                ForEach(CleanupTarget.allCases) { target in
                    cleanupRow(target)
                }
                usageRow("草稿附件（不清理）", snapshot?.drafts)
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
                                Text(vm.format(session.usage))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                storageAlert = .deleteSession(session)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("存储")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.load() }
        .onDisappear { vm.cancelLoad() }
        .task {
            if cleaning == nil { await refreshStorage() }
        }
        .alert(item: $storageAlert, content: makeAlert)
    }

    private func usageRow(_ title: String, _ usage: StorageUsage?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let usage {
                Text(vm.format(usage)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func cleanupRow(_ target: CleanupTarget) -> some View {
        HStack(spacing: 12) {
            Text(target.title)
            Spacer()
            if let usage = cleanupUsage(target) {
                Text(vm.format(usage)).foregroundStyle(.secondary)
            }
            if cleaning == target {
                ProgressView().controlSize(.small)
            } else {
                Button("清理") { storageAlert = .confirmCleanup(target) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("清理\(target.title)")
                    .disabled(cleaning != nil || snapshot == nil)
            }
        }
    }

    private func cleanupUsage(_ target: CleanupTarget) -> StorageUsage? {
        switch target {
        case .temporary: return snapshot?.occupancy.temporary
        case .caches: return snapshot?.caches
        case .browser: return snapshot?.browser
        }
    }

    private func refreshStorage() async {
        let scan = Task.detached(priority: .utility) {
            (StorageMaintenance.occupancy(), StorageMaintenance.usage(.caches), StorageMaintenance.draftUsage())
        }
        let browser = await StorageBrowserCache.usage()
        let (occupancy, caches, drafts) = await scan.value
        guard !Task.isCancelled else { return }
        snapshot = StorageSnapshot(occupancy: occupancy, caches: caches, drafts: drafts, browser: browser)
    }

    private func clear(_ target: CleanupTarget) {
        guard cleaning == nil else { return }
        cleaning = target
        Task {
            let result: StorageMaintenance.Cleanup
            switch target {
            case .temporary, .caches:
                let area: StorageMaintenance.Area = target == .temporary ? .temporary : .caches
                result = await Task.detached(priority: .utility) { StorageMaintenance.sweep(area) }.value
            case .browser:
                result = await StorageBrowserCache.clear()
            }
            await refreshStorage()
            cleaning = nil
            storageAlert = .cleanupResult(target, result)
        }
    }

    private func makeAlert(_ alert: StorageAlert) -> Alert {
        switch alert {
        case .deleteSession(let session):
            return Alert(
                title: Text("删除会话？"),
                message: Text("将删除“\(session.title ?? "未命名")”的聊天内容和会话文件，此操作无法撤销。"),
                primaryButton: .destructive(Text("删除")) {
                    vm.deleteSession(session)
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .confirmCleanup(let target):
            let message: String
            switch target {
            case .temporary: message = "删除临时文件夹中的内容。"
            case .caches: message = "删除缓存文件及网络请求缓存，保留草稿附件。"
            case .browser: message = "仅清理网页的磁盘与内存缓存，保留网站登录与站点数据。"
            }
            return Alert(
                title: Text("清理\(target.title)？"),
                message: Text(message),
                primaryButton: .destructive(Text("清理")) { clear(target) },
                secondaryButton: .cancel(Text("取消"))
            )
        case .cleanupResult(let target, let result):
            let before = result.before.map { vm.format($0) } ?? "未能统计"
            let after = result.after.map { vm.format($0) } ?? "未能统计"
            var lines = ["清理前：\(before)", "清理后：\(after)"]
            if let netReduction = result.netReduction {
                if netReduction > 0 {
                    lines.append("已释放：\(vm.format(netReduction))")
                } else {
                    lines.append("期间有新文件写入，占用未减少")
                }
            } else {
                lines.append("未能核算释放量。")
            }
            if target != .browser {
                lines.append("跳过：在用 \(result.skips.inUse) 项，删除失败 \(result.skips.failed) 项。")
                if target == .caches { lines.append("保留草稿附件目录：\(result.skips.excluded) 项。") }
            }
            let title = result.skips.failed > 0 || result.skips.inUse > 0 ? "部分项目未清理" : "清理完成"
            return Alert(title: Text(title), message: Text(lines.joined(separator: "\n")), dismissButton: .default(Text("好")))
        }
    }
}

private extension StorageManagementViewModel {
    @MainActor
    func deleteSession(_ session: SessionStorage) {
        guard !deletingSessionIDs.contains(session.id) else { return }

        let sessionId = session.id
        deletingSessionIDs.insert(sessionId)
        sessions.removeAll { $0.id == sessionId }

        Task { @MainActor [weak self] in
            await ChatStore.shared.deleteSession(sessionId)
            Self.deletePersistentSessionFiles(sessionId)
            self?.deletingSessionIDs.remove(sessionId)
            self?.load()
        }
    }

    @MainActor
    private static func deletePersistentSessionFiles(_ sessionId: String) {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let sessionDirectory = library
            .appendingPathComponent("ZeChat/ze", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try? fm.removeItem(at: sessionDirectory)
        BrowserTabPool.deletePersistedData(for: sessionId)
    }
}

// MARK: - Session Storage Detail View

struct SessionStorageDetailView: View {
    let session: StorageManagementViewModel.SessionStorage
    var onFilesCleared: (() -> Void)?

    @State private var showClearConfirmation = false
    @State private var isClearing = false
    @State private var currentUsage: StorageUsage

    init(session: StorageManagementViewModel.SessionStorage, onFilesCleared: (() -> Void)? = nil) {
        self.session = session
        self.onFilesCleared = onFilesCleared
        _currentUsage = State(initialValue: session.usage)
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

    private var hasFiles: Bool { currentUsage.bytes > 0 }
    private var sizeLabel: String {
        let value = formatter.string(fromByteCount: currentUsage.bytes)
        if currentUsage.failed == 0 { return value }
        return hasFiles ? "已统计 \(value)" : "未能统计"
    }

    var body: some View {
        List {
            Section("Ze 文件") {
                if hasFiles {
                    NavigationLink {
                        FileBrowserView(rootPath: zeURL)
                    } label: {
                        HStack {
                            Label("浏览文件", systemImage: "folder")
                            Spacer()
                            Text(sizeLabel)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(currentUsage.failed > 0 ? "未能统计 Ze 文件" : "暂无 Ze 文件")
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
                            Text(sizeLabel)
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
            Button("清理", role: .destructive) {
                clearFiles()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("将删除此会话的文件（\(sizeLabel)），此操作无法撤销。")
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
                currentUsage = StorageUsage()
                isClearing = false
                onFilesCleared?()
            }
        }
    }
}
