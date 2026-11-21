import SwiftUI
import WebKit

enum StorageCacheCategory: String, CaseIterable, Identifiable, Hashable {
    case browser, network, media, visualization, metadata

    var id: Self { self }

    var title: String {
        switch self {
        case .browser: return "浏览器缓存"
        case .network: return "网络请求缓存"
        case .media: return "媒体文件缓存"
        case .visualization: return String(localized: "Visualization cache")
        case .metadata: return "模型及检测缓存"
        }
    }

    var icon: String {
        switch self {
        case .browser: return "globe"
        case .network: return "arrow.down.circle"
        case .media: return "photo.on.rectangle"
        case .visualization: return "chart.bar"
        case .metadata: return "list.bullet"
        }
    }
}

struct StorageCacheUsage {
    let measuredBytes: Int64
    let estimatedBytes: Int64?
    let failed: Int
    let isPartial: Bool
    let websiteRecords: Int?

    init(measuredBytes: Int64 = 0, failed: Int = 0, isPartial: Bool = false, websiteRecords: Int? = nil) {
        self.measuredBytes = measuredBytes
        estimatedBytes = nil
        self.failed = failed
        self.isPartial = isPartial || failed > 0
        self.websiteRecords = websiteRecords
    }

    init(estimatedBytes: Int64) {
        measuredBytes = 0
        self.estimatedBytes = estimatedBytes
        failed = 0
        isPartial = true
        websiteRecords = nil
    }

    var canClear: Bool { measuredBytes > 0 || isPartial }

    func label(format: (Int64) -> String) -> String {
        if let estimatedBytes { return "估算 \(format(estimatedBytes))" }
        return isPartial ? (measuredBytes > 0 ? "至少 \(format(measuredBytes))" : "大小未知") : format(measuredBytes)
    }
}

@MainActor
final class StorageCacheCleaner: ObservableObject {
    enum Selection: Equatable {
        case all
        case category(StorageCacheCategory)

        var categories: [StorageCacheCategory] {
            switch self {
            case .all: return StorageCacheCategory.allCases
            case .category(let category): return [category]
            }
        }

        var actionTitle: String {
            switch self {
            case .all: return "清理全部缓存"
            case .category(let category): return "清理\(category.title)"
            }
        }
    }

    struct Completion {
        let selection: Selection
        let remaining: StorageCacheUsage
        let inUse: Int
        let failed: Int
    }

    @Published private(set) var usage: [StorageCacheCategory: StorageCacheUsage] = [:]
    @Published private(set) var isBusy = false

    func usage(for selection: Selection) -> StorageCacheUsage? {
        switch selection {
        case .category(let category): return usage[category]
        case .all:
            guard usage.count == StorageCacheCategory.allCases.count else { return nil }
            let values = usage.values
            return StorageCacheUsage(measuredBytes: values.reduce(0) { $0 + $1.measuredBytes },
                                     failed: values.reduce(0) { $0 + $1.failed },
                                     isPartial: values.contains { $0.isPartial },
                                     websiteRecords: usage[.browser]?.websiteRecords)
        }
    }

    func load() async {
        _ = await refresh(.all)
    }

    func refresh(_ selection: Selection) async -> StorageCacheUsage? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        for category in selection.categories {
            usage[category] = await measure(category)
        }
        return usage(for: selection)
    }

    func clear(_ selection: Selection) async -> Completion? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        var result = StorageCacheFileResult()
        for category in selection.categories {
            result.merge(await clearCategory(category))
        }
        for category in selection.categories {
            usage[category] = await measure(category)
        }
        guard let remaining = usage(for: selection) else { return nil }
        return Completion(selection: selection, remaining: remaining, inUse: result.inUse, failed: result.failed)
    }

    private func measure(_ category: StorageCacheCategory) async -> StorageCacheUsage {
        switch category {
        case .browser:
            let files = await FaviconService.shared.storageCacheFiles(clear: false)
            let records = await browserCacheRecordCount()
            return StorageCacheUsage(measuredBytes: files.bytes, failed: files.failed, isPartial: true, websiteRecords: records)
        case .network:
            let cache = URLCache.shared
            return StorageCacheUsage(measuredBytes: Int64(cache.currentDiskUsage) + Int64(cache.currentMemoryUsage))
        case .media:
            let files = await diskFiles([.audio, .remotePreviews], clear: false)
            return StorageCacheUsage(measuredBytes: files.bytes, failed: files.failed, isPartial: true)
        case .visualization:
            return StorageCacheUsage(estimatedBytes: Int64(ZeVisualizationCache.shared.statistics.cost))
        case .metadata:
            let files = await diskFiles([.modelCatalogs, .probe], clear: false)
            return StorageCacheUsage(measuredBytes: files.bytes, failed: files.failed)
        }
    }

    private func clearCategory(_ category: StorageCacheCategory) async -> StorageCacheFileResult {
        switch category {
        case .browser:
            for store in await browserStores() {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    store.removeData(ofTypes: Self.browserCacheTypes, modifiedSince: .distantPast) { continuation.resume() }
                }
            }
            BrowserTabPoolRegistry.shared.clearPreviewCache()
            return await FaviconService.shared.storageCacheFiles(clear: true)
        case .network:
            await Task.detached(priority: .utility) { URLCache.shared.removeAllCachedResponses() }.value
        case .media:
            ZeMediaCache.shared.clearCachedObjects()
            NativeMediaImageCache.shared.clearCachedImages()
            ThumbnailCache.shared.removeAll()
            return await diskFiles([.audio, .remotePreviews], clear: true)
        case .visualization:
            ZeVisualizationCache.shared.clear()
            SelectableMarkdownView.clearVisualizationCaches()
        case .metadata:
            return await diskFiles([.modelCatalogs, .probe], clear: true)
        }
        return StorageCacheFileResult()
    }

    private func diskFiles(_ areas: [StorageCacheFiles.Area], clear: Bool) async -> StorageCacheFileResult {
        await Task.detached(priority: .utility) {
            areas.reduce(into: StorageCacheFileResult()) { result, area in
                result.merge(StorageCacheFiles.process(area, clear: clear))
            }
        }.value
    }

    private static let browserCacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]

    private func browserStores() async -> [WKWebsiteDataStore] {
        let standard = WKWebsiteDataStore.default()
        if #available(iOS 17.0, *) {
            let identifiers: [UUID] = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
            }
            return [standard] + identifiers.map { WKWebsiteDataStore(forIdentifier: $0) }
        }
        return [standard]
    }

    private func browserCacheRecordCount() async -> Int {
        var count = 0
        for store in await browserStores() {
            count += await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                store.fetchDataRecords(ofTypes: Self.browserCacheTypes) { continuation.resume(returning: $0.count) }
            }
        }
        return count
    }
}
