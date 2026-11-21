import SwiftUI

// MARK: - View Model

@MainActor
class StorageManagementViewModel: ObservableObject {
    struct SessionStorage: Identifiable {
        let id: String
        let title: String?
        let usage: StorageAccounting.Usage
        var zeSize: Int64 { usage.bytes }
    }

    @Published private(set) var snapshot: StorageAccounting.Snapshot?
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

    func format(_ usage: StorageAccounting.Usage) -> String {
        guard usage.isIncomplete else { return format(usage.bytes) }
        return usage.bytes > 0 ? "至少 \(format(usage.bytes))" : "大小未知"
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let chatSessions = await ChatStore.shared.listSessions()
            guard !Task.isCancelled else { return }
            let sessionIDs = chatSessions.map(\.id)
            let scan = Task.detached(priority: .utility) {
                let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                return try StorageAccounting.scan(home: home, sessionIDs: sessionIDs)
            }
            let result = await withTaskCancellationHandler {
                try? await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            self.snapshot = result
            self.sessions = chatSessions.map { session in
                SessionStorage(
                    id: session.id,
                    title: session.title,
                    usage: result?.sessions[session.id] ?? .unknown
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
    private struct StorageRow: Identifiable {
        let entry: StorageAccounting.Entry
        let depth: Int

        var id: String { entry.id }
    }

    private enum StorageAlert: Identifiable {
        case deleteSession(StorageManagementViewModel.SessionStorage)
        case clearCaches(StorageCacheCleaner.Selection, StorageCacheUsage)
        case cacheResult(StorageCacheCleaner.Completion)

        var id: Int {
            switch self {
            case .deleteSession: return 0
            case .clearCaches: return 1
            case .cacheResult: return 2
            }
        }
    }

    @StateObject private var vm = StorageManagementViewModel()
    @StateObject private var caches = StorageCacheCleaner()
    @State private var storageAlert: StorageAlert?
    @State private var expandedStoragePaths = Set<String>()

    var body: some View {
        List {
            overviewSection

            if let snapshot = vm.snapshot {
                Section {
                    storageRow(icon: "terminal", color: .gray, label: "Shell 容器", value: vm.format(snapshot.shell))
                    storageRow(icon: "cylinder", color: .blue, label: "聊天数据库", value: vm.format(snapshot.database))
                    let sessionUsage = StorageAccounting.Usage.sum(Array(snapshot.sessions.values))
                    storageRow(icon: "doc", color: .indigo, label: "会话文件", value: vm.format(sessionUsage))
                } header: {
                    Text("对话与 Shell")
                } footer: {
                    Text("以上明细已计入概览。")
                }
            }

            cacheSection

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
        .task { await caches.load() }
        .alert(item: $storageAlert, content: makeAlert)
    }

    private var overviewSection: some View {
        Section {
            if let snapshot = vm.snapshot {
                storageRow(icon: "internaldrive", color: .blue, label: "存储总计", value: vm.format(snapshot.total))
                ForEach(visibleRows(in: snapshot.regions)) { row in
                    accountingRow(row)
                }
            } else if !vm.isLoading {
                Text("大小未知")
                    .foregroundStyle(.secondary)
            }
            if vm.isLoading {
                ProgressView("统计中…")
            }
        } header: {
            Text("概览")
        } footer: {
            Text("仅统计应用沙盒内的文件，不含 App 本体。")
        }
    }

    private func visibleRows(in entries: [StorageAccounting.Entry], depth: Int = 0) -> [StorageRow] {
        var rows: [StorageRow] = []
        for entry in entries {
            rows.append(StorageRow(entry: entry, depth: depth))
            if expandedStoragePaths.contains(entry.id), let children = entry.children {
                rows.append(contentsOf: visibleRows(in: children, depth: depth + 1))
            }
        }
        return rows
    }

    private func accountingRow(_ row: StorageRow) -> some View {
        let entry = row.entry
        let expanded = expandedStoragePaths.contains(entry.id)
        let label = storageRow(
            icon: entry.children != nil || row.depth == 0 ? "folder" : "doc",
            color: row.depth == 0 ? .blue : .gray,
            label: entry.name,
            value: vm.format(entry.usage)
        )
        return Group {
            if let children = entry.children, !children.isEmpty {
                Button {
                    if expanded {
                        expandedStoragePaths.remove(entry.id)
                    } else {
                        expandedStoragePaths.insert(entry.id)
                    }
                } label: {
                    HStack {
                        label
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "已展开" : "已收起")
            } else {
                label
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 5)) * 12)
    }

    private var cacheSection: some View {
        Section {
            ForEach(StorageCacheCategory.allCases) { category in
                cacheRow(.category(category), icon: category.icon, label: category.title)
            }
            cacheRow(.all, icon: "internaldrive", label: "缓存总计")
        } header: {
            Text("缓存")
        } footer: {
            Text("总计只含实测大小，不含可视化估算。WebKit 和部分内存缓存不提供大小。正在使用的文件会保留。")
        }
    }

    private func cacheRow(_ selection: StorageCacheCleaner.Selection, icon: String, label: String) -> some View {
        let usage = caches.usage(for: selection)
        return VStack(alignment: .leading, spacing: 8) {
            storageRow(icon: icon, color: .teal, label: label, value: usage?.label(format: vm.format) ?? "统计中…")
            if selection == .category(.browser), let records = usage?.websiteRecords {
                Text("WebKit 缓存记录：\(records) 条")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(selection.actionTitle) {
                Task { @MainActor in
                    guard let current = await caches.refresh(selection), storageAlert == nil else { return }
                    storageAlert = .clearCaches(selection, current)
                }
            }
            .disabled(caches.isBusy || usage?.canClear != true)
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
        case .clearCaches(let selection, let usage):
            let size = usage.label(format: vm.format)
            let label = selection == .all ? "当前缓存总大小" : "当前分类缓存大小"
            return Alert(
                title: Text("\(selection.actionTitle)？"),
                message: Text("\(label)：\(size)。聊天、网站登录数据和正在使用的文件会保留。"),
                primaryButton: .destructive(Text("清理")) {
                    Task { @MainActor in
                        guard let result = await caches.clear(selection) else { return }
                        vm.load()
                        storageAlert = .cacheResult(result)
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        case .cacheResult(let result):
            var message = "重新统计：\(result.remaining.label(format: vm.format))。"
            if result.inUse > 0 { message += "保留了 \(result.inUse) 个正在使用的文件。" }
            if result.failed > 0 { message += "有 \(result.failed) 项未能清理。" }
            if result.remaining.failed > 0 { message += "部分文件无法统计。" }
            if let records = result.remaining.websiteRecords { message += "WebKit 剩余缓存记录：\(records) 条。" }
            return Alert(title: Text(result.failed > 0 ? "部分缓存未能清理" : "清理完成"), message: Text(message), dismissButton: .default(Text("好")))
        }
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
