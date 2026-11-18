import SwiftUI
import QuickLook

/// Shared entry for file browsing and attachment selection. All remote actions
/// pass through RemoteDiskReading; there are no server mutation controls.
struct RemoteDiskPickerView: View {
    var onSelect: ((URL) throws -> Void)? = nil
    @ObservedObject private var store = RemoteDiskStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let error = store.loadError { Text(error).foregroundStyle(.red) }
                if store.disks.isEmpty { Text("尚未添加网络磁盘，请先在设置中添加。") }
                ForEach(store.disks) { disk in
                    NavigationLink {
                        RemoteDiskBrowserView(diskID: disk.id, onSelect: onSelect)
                    } label: {
                        VStack(alignment: .leading) {
                            Label(disk.profile.name, systemImage: "externaldrive")
                            Text(disk.profile.proto.title + " · 只读").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink("管理网络磁盘") { RemoteDiskSettingsView() }
            }
            .navigationTitle("网络磁盘")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

struct RemoteDiskBrowserView: View {
    let diskID: UUID
    var onSelect: ((URL) throws -> Void)? = nil
    @State private var address: RemoteDiskAddress
    @State private var entries: [RemoteDiskEntry] = []
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var loaded = false
    @State private var downloading = false
    @State private var error: String?
    @State private var actionError: String?
    @State private var preview: RemoteDiskPreviewFile?
    @State private var selected: RemoteDiskEntry?
    @State private var chooseAction = false
    @ObservedObject private var store = RemoteDiskStore.shared
    private let reader: any RemoteDiskReading = RemoteDiskService.shared

    init(diskID: UUID, onSelect: ((URL) throws -> Void)? = nil) {
        self.diskID = diskID; self.onSelect = onSelect
        _address = State(initialValue: try! RemoteDiskAddress(diskID: diskID))
    }
    var body: some View {
        List {
            Section {
                Text(address.string).font(.caption).textSelection(.enabled)
                if !address.components.isEmpty {
                    Button { address = address.parent } label: { Label("上一级", systemImage: "arrow.up") }.disabled(loading || downloading)
                }
            }
            if loading { ProgressView("正在读取目录…") }
            if let error {
                Section("目录读取失败") {
                    Text(error).foregroundStyle(.red)
                    Button("重试") { Task { await load() } }
                    Text("首次 SFTP 连接请到磁盘设置中验证并确认主机指纹。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if loaded && entries.isEmpty { Text("空目录") }
            if error == nil {
                ForEach(entries) { entry in
                    Button {
                        if entry.isDirectory { address = entry.address }
                        else { selected = entry; chooseAction = true }
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                            Spacer()
                            if let size = entry.size, !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            if entry.isDirectory { Image(systemName: "chevron.right").font(.caption) }
                        }
                    }.disabled(loading || downloading)
                }
            }
            if downloading { ProgressView("正在受限下载…") }
        }
        .navigationTitle((try? store.disk(id: diskID).profile.name) ?? "网络磁盘")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: address.string) { await load() }
        .refreshable { await load() }
        .confirmationDialog(selected?.name ?? "文件", isPresented: $chooseAction, titleVisibility: .visible) {
            if let entry = selected {
                Button("预览") { download(entry, attach: false) }
                if onSelect != nil { Button("添加到聊天") { download(entry, attach: true) } }
                Button("验证读取") { verifyRead(entry) }
                Button("复制只读地址") { UIPasteboard.general.string = entry.address.string }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $preview, onDismiss: {
            // Preview copies have no persistent identity and may be reclaimed.
        }) { file in RemoteDiskQuickLook(url: file.url) }
        .alert("网络磁盘", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好") {}
        } message: { Text(actionError ?? "") }
    }

    @MainActor private func load() async {
        let requested = address
        let token = UUID(); requestID = token
        loading = true; loaded = false; entries = []; error = nil
        do {
            let values = try await reader.list(requested)
            guard requested == address, token == requestID, !Task.isCancelled else { return }
            entries = values; loaded = true; loading = false
        } catch {
            guard requested == address, token == requestID else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
    private func download(_ entry: RemoteDiskEntry, attach: Bool) {
        downloading = true
        Task { @MainActor in
            defer { downloading = false }
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RemoteDiskPreviews")
                let url = try await RemoteDiskService.shared.cache(entry.address, in: directory)
                if attach, let onSelect {
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    try onSelect(url)
                } else { preview = RemoteDiskPreviewFile(url: url) }
            } catch { actionError = "读取失败：" + error.localizedDescription }
        }
    }
    private func verifyRead(_ entry: RemoteDiskEntry) {
        downloading = true
        Task { @MainActor in
            defer { downloading = false }
            do {
                let disk = try store.disk(id: diskID)
                var status = store.status(for: disk)
                status.sshUpdatedAt = store.sshRevision(for: disk)
                do {
                    let data = try await reader.download(entry.address, maximumBytes: RemoteDiskService.maximumDownloadBytes)
                    status.reading = "成功（\(data.count) 字节）：\(entry.name)"
                } catch { status.reading = "失败：" + error.localizedDescription }
                status.checkedAt = .now
                try store.record(status, for: disk)
                actionError = status.reading
            } catch { actionError = error.localizedDescription }
        }
    }
}

private struct RemoteDiskPreviewFile: Identifiable { let id = UUID(); let url: URL }
private struct RemoteDiskQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
        deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}
