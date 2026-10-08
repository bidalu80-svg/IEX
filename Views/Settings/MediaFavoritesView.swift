import SwiftUI
import AVFoundation

struct MediaFavoritesView: View {
    @StateObject private var store = MediaFavoritesStore.shared
    @State private var selectedKind: FavoriteMediaKind?
    @State private var selectedIDs = Set<UUID>()
    @State private var isEditing = false
    @State private var previewItem: FavoriteMediaItem?
    @State private var shareURL: URL?
    @State private var showDeleteConfirmation = false
    @State private var isPreparingArchive = false

    private var visibleItems: [FavoriteMediaItem] {
        guard let selectedKind else { return store.items }
        return store.items.filter { $0.kind == selectedKind }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("媒体分类", selection: $selectedKind) {
                Text("全部").tag(FavoriteMediaKind?.none)
                ForEach(FavoriteMediaKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.icon).tag(Optional(kind))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .onChange(of: selectedKind) { _ in
                selectedIDs.removeAll()
            }

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    "还没有收藏媒体",
                    systemImage: "star",
                    description: Text("在聊天中的图片、视频或音频上长按即可收藏。")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(visibleItems) { item in
                            favoriteTile(item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("收藏夹")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isEditing {
                    Button("取消") {
                        selectedIDs.removeAll()
                        isEditing = false
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !selectedIDs.isEmpty {
                    Button {
                        prepareShare()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(isPreparingArchive)
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                Button(isEditing ? "完成" : "选择") {
                    isEditing.toggle()
                    if !isEditing { selectedIDs.removeAll() }
                }
            }
        }
        .sheet(item: $previewItem) { item in
            FavoriteMediaPreviewView(item: item, fileURL: store.fileURL(for: item))
        }
        .sheet(item: $shareURL) { url in
            ZeShareSheet(url: url)
        }
        .confirmationDialog("删除收藏媒体？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.remove(ids: selectedIDs)
                selectedIDs.removeAll()
                isEditing = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除选中的 \(selectedIDs.count) 个媒体文件。")
        }
        .overlay {
            if isPreparingArchive {
                ProgressView("正在准备压缩包…")
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    @ViewBuilder
    private func favoriteTile(_ item: FavoriteMediaItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        Button {
            if isEditing {
                if isSelected { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
            } else {
                previewItem = item
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    FavoriteMediaThumbnailView(item: item, fileURL: store.fileURL(for: item))
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                    Text(item.fileName)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Image(systemName: item.kind.icon)
                        Text(item.kind.title)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(7)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if isEditing {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .blue : .white)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                previewItem = item
            } label: {
                Label("预览", systemImage: "eye")
            }
            Button {
                shareURL = store.fileURL(for: item)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                store.remove(item)
                selectedIDs.remove(item.id)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func prepareShare() {
        let selected = visibleItems.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        if selected.count == 1 {
            shareURL = store.fileURL(for: selected[0])
            return
        }
        isPreparingArchive = true
        Task { @MainActor in
            let url = await store.makeZip(for: selected)
            isPreparingArchive = false
            shareURL = url
        }
    }
}

private struct FavoriteMediaThumbnailView: View {
    let item: FavoriteMediaItem
    let fileURL: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: item.kind.icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if item.kind == .video {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.62), in: Circle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: fileURL) { await load() }
    }

    private func load() async {
        guard item.kind != .audio else { return }
        let url = fileURL
        let result = await Task.detached(priority: .utility) { () -> UIImage? in
            if item.kind == .image {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return downsampleImage(data: data, maxPixelSize: 512)
            }
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
        if let result { image = result }
    }
}

private struct FavoriteMediaPreviewView: View {
    let item: FavoriteMediaItem
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch item.kind {
                case .image:
                    ZeImageFilePreviewView(fileURL: fileURL)
                case .video:
                    ZeVideoPlayerView(url: fileURL, fileURL: fileURL)
                        .padding()
                case .audio:
                    ZeAudioPlayerView(url: fileURL, fileURL: fileURL)
                        .padding()
                }
            }
            .navigationTitle(item.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
