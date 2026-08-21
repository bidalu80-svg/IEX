import SwiftUI
import UniformTypeIdentifiers

struct RemoteSFTPBrowserView: View {
    let serverID: UUID
    let initialPath: String

    @ObservedObject private var connection = RemoteSSHConnectionService.shared
    @State private var currentPath: String
    @State private var entries: [RemoteSFTPEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showImporter = false
    @State private var pendingUpload: PendingRemoteUpload?
    @State private var newDirectoryName = ""
    @State private var showNewDirectory = false
    @State private var renameTarget: RemoteSFTPEntry?
    @State private var replacementName = ""
    @State private var deleteTarget: RemoteSFTPEntry?
    @State private var downloadURL: URL?

    init(serverID: UUID, initialPath: String) {
        self.serverID = serverID
        self.initialPath = initialPath
        _currentPath = State(initialValue: initialPath)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.blue)
                    Text(currentPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    if isLoading { ProgressView() }
                }
                if currentPath != "/" {
                    Button {
                        currentPath = parentPath(of: currentPath)
                        refresh()
                    } label: {
                        Label("上一级目录", systemImage: "arrow.up.backward")
                    }
                }
            }

            if !isLoading && entries.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("此目录为空")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowBackground(Color.clear)
            } else {
                Section("文件") {
                    ForEach(entries) { entry in
                        Button {
                            if entry.isDirectory {
                                currentPath = entry.path
                                refresh()
                            } else {
                                download(entry)
                            }
                        } label: {
                            entryRow(entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !entry.isDirectory {
                                Button {
                                    download(entry)
                                } label: {
                                    Label("下载并分享", systemImage: "arrow.down.circle")
                                }
                            }
                            Button {
                                renameTarget = entry
                                replacementName = entry.name
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteTarget = entry
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { deleteTarget = entry } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { renameTarget = entry; replacementName = entry.name } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("SFTP 文件")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showImporter = true } label: {
                        Label("上传文件", systemImage: "arrow.up.doc")
                    }
                    Button { newDirectoryName = ""; showNewDirectory = true } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                    Button { refresh() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            prepareUpload(result)
        }
        .confirmationDialog(
            "确认上传文件",
            isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingUpload {
                Button("上传") { upload(pendingUpload) }
            }
            Button("取消", role: .cancel) { pendingUpload = nil }
        } message: {
            if let pendingUpload {
                Text("将“\(pendingUpload.name)”上传到 \(currentPath)。已有同名文件会被覆盖。")
            }
        }
        .alert("新建文件夹", isPresented: $showNewDirectory) {
            TextField("文件夹名称", text: $newDirectoryName)
            Button("创建") { createDirectory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只允许单层名称，不能包含斜杠。")
        }
        .alert("重命名", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $replacementName)
            Button("重命名") { rename() }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("只允许单层名称，不能包含斜杠。")
        }
        .confirmationDialog(
            "确认删除",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let deleteTarget {
                Button("删除“\(deleteTarget.name)”", role: .destructive) { delete(deleteTarget) }
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            if let deleteTarget {
                Text(deleteTarget.isDirectory ? "只能删除空文件夹，此操作无法撤销。" : "此操作无法撤销。")
            }
        }
        .alert("SFTP 操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { downloadURL != nil }, set: { if !$0 { downloadURL = nil } })) {
            if let downloadURL { ZeShareSheet(url: downloadURL) }
        }
    }

    private func entryRow(_ entry: RemoteSFTPEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func detail(for entry: RemoteSFTPEntry) -> String {
        var pieces: [String] = []
        if let size = entry.size, !entry.isDirectory {
            pieces.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modifiedAt = entry.modifiedAt {
            pieces.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return pieces.isEmpty ? (entry.isDirectory ? "文件夹" : "文件") : pieces.joined(separator: " · ")
    }

    private func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                entries = try await connection.listDirectory(at: currentPath, on: serverID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prepareUpload(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            pendingUpload = PendingRemoteUpload(name: url.lastPathComponent, data: try Data(contentsOf: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func upload(_ upload: PendingRemoteUpload) {
        pendingUpload = nil
        let target = childPath(of: currentPath, named: upload.name)
        Task {
            do {
                try await connection.uploadFile(upload.data, to: target, on: serverID)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createDirectory() {
        guard let name = singlePathComponent(newDirectoryName) else {
            errorMessage = "文件夹名称不能为空且不能包含斜杠"
            return
        }
        Task {
            do {
                try await connection.createDirectory(at: childPath(of: currentPath, named: name), on: serverID)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rename() {
        guard let entry = renameTarget, let name = singlePathComponent(replacementName) else {
            errorMessage = "新名称不能为空且不能包含斜杠"
            return
        }
        renameTarget = nil
        Task {
            do {
                try await connection.renameItem(at: entry.path, to: childPath(of: parentPath(of: entry.path), named: name), on: serverID)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ entry: RemoteSFTPEntry) {
        deleteTarget = nil
        Task {
            do {
                try await connection.deleteItem(at: entry.path, isDirectory: entry.isDirectory, on: serverID)
                refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func download(_ entry: RemoteSFTPEntry) {
        Task {
            do {
                let data = try await connection.downloadFile(at: entry.path, on: serverID)
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Ze Downloads", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(entry.name)
                try data.write(to: url, options: .atomic)
                downloadURL = url
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func childPath(of path: String, named name: String) -> String {
        path == "/" ? "/\(name)" : path + "/" + name
    }

    private func parentPath(of path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return "/" }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private func singlePathComponent(_ raw: String) -> String? {
        let result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result != ".", result != "..", !result.contains("/") else { return nil }
        return result
    }
}

private struct PendingRemoteUpload: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}
