import Combine
import Foundation
import ImageIO
import UIKit

private let faviconLogger = AppLogger(category: "BrowserFavicon")

/// Resolves website icons for the browser's tab strip and history list.
///
/// Lookup priority (matches the product plan):
///   1. an icon declared by the loaded page (`<link rel="icon">` /
///      `apple-touch-icon`), read from the already-loaded DOM via
///      `BrowserUseJS.pageIconURLs()` — never by re-fetching the page HTML;
///   2. the site-root `/favicon.ico`;
///   3. a deterministic letter tile (`FaviconView` renders it; it is not
///      persisted, since the same domain always produces the same tile).
///
/// Icons are cached per domain on disk (`FaviconDiskCache`, hard LRU limit)
/// and in a small in-memory LRU window for what is currently on screen.
/// Network and image decoding run off the main thread.
@MainActor
final class FaviconService: ObservableObject {
    static let shared = FaviconService()

    /// Incremented when a newly resolved/upgraded icon is ready. Visible
    /// `FaviconView`s observe this to replace their letter placeholder.
    @Published private(set) var revision = 0

    enum Source: Int, Equatable {
        case letter = 0
        case faviconICO = 1
        case pageLink = 2
    }

    struct LoadedIcon {
        let image: UIImage
        let source: Source
    }

    struct FallbackStyle {
        let letter: String
        let color: UIColor
    }

    // MARK: - Constants

    /// Enough for all visible chips + history rows without retaining every
    /// site the user has ever visited. The disk cache is the long-term store.
    private static let memoryLimit = 48
    /// Bound on the auxiliary per-domain maps (declared-icon URLs, last fetch,
    /// failure backoff). Without this a very long browsing session would grow
    /// them for every domain ever visited.
    private static let auxiliaryLimit = 64
    private static let maxIconBytes = 512 * 1024
    private static let requestTimeout: TimeInterval = 10
    private static let maxPageIconCandidates = 8
    private static let failureBackoff: TimeInterval = 6 * 60 * 60

    /// Ephemeral, cookie-less session: icon bytes live only in our bounded
    /// FaviconDiskCache, never in URLSession's own growing disk cache.
    private static let iconSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    // MARK: - State (main actor only)

    private var memory: [String: LoadedIcon] = [:]
    private var memoryLRU: [String] = []
    private var inFlight: [String: Task<LoadedIcon?, Never>] = [:]
    /// DOM-declared icon URLs, keyed by normalized domain.
    private var pageIconCandidates: [String: [URL]] = [:]
    /// Last page-declared URL we successfully downloaded for this domain.
    private var lastFetchedPageIcon: [String: URL] = [:]
    /// Avoids retrying a site with no usable icon on every list scroll.
    private var retryAfter: [String: Date] = [:]
    private var auxiliaryLRU: [String] = []

    private let diskCache = FaviconDiskCache()

    private init() {}

    // MARK: - Public lookup

    /// Synchronous memory-only peek for first render. Never touches disk or
    /// network, so it is safe to call from a SwiftUI body.
    func peekIcon(forDomain domain: String) -> UIImage? {
        guard let key = Self.normalizedDomain(domain) else { return nil }
        return memory[key]?.image
    }

    /// Async resolve used by `FaviconView.task`: memory → disk → network.
    func icon(forDomain domain: String, pageURL: URL? = nil) async -> UIImage? {
        guard let key = Self.normalizedDomain(domain) else { return nil }
        if let cached = memory[key] {
            touchMemory(key)
            return cached.image
        }
        if let task = inFlight[key] {
            return await task.value?.image
        }

        let task = Task { [weak self] () -> LoadedIcon? in
            guard let self else { return nil }
            return await self.resolve(domain: key, pageURL: pageURL)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        guard let result else { return nil }
        store(result, for: key)
        return memory[key]?.image ?? result.image
    }

    func icon(forURL urlString: String) async -> UIImage? {
        guard let domain = Self.normalizedDomain(urlString) else { return nil }
        return await icon(forDomain: domain, pageURL: URL(string: urlString))
    }

    /// Parses the JSON returned by `BrowserUseJS.pageIconURLs()` and caches
    /// the best icon. Called after a page finishes loading, from the manager's
    /// already-loaded WKWebView.
    func registerPageIconJSON(_ jsonString: String, pageURL: URL?) async {
        guard let pageURL,
              let domain = Self.normalizedDomain(pageURL.host ?? pageURL.absoluteString),
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIcons = object["icons"] as? [String] else { return }

        let urls = rawIcons
            .compactMap { URL(string: $0) }
            .filter { url in
                guard let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
        guard !urls.isEmpty else { return }

        pageIconCandidates[domain] = Array(urls.prefix(Self.maxPageIconCandidates))
        retryAfter[domain] = nil
        rememberAuxiliaryDomain(domain)

        // A page-link icon already in memory for this exact URL needs no work.
        if let existing = memory[domain], existing.source == .pageLink,
           let fetched = lastFetchedPageIcon[domain],
           fetched == urls.first {
            return
        }

        // A /favicon.ico fetch may already be in flight (a row rendered before
        // this DOM read finished). Let it settle, then upgrade to the declared
        // icon — the priority order is page link > /favicon.ico.
        if let task = inFlight[domain] {
            _ = await task.value
        }
        if let existing = memory[domain], existing.source == .pageLink,
           let fetched = lastFetchedPageIcon[domain],
           fetched == urls.first {
            return
        }
        await fetchDeclaredIcon(domain: domain, urls: Array(urls.prefix(Self.maxPageIconCandidates)))
    }

    /// Disk footprint; exposed for diagnostics/acceptance checks.
    func diskCacheUsage() async -> FaviconDiskCache.Usage {
        await diskCache.usage()
    }

    // MARK: - Resolution

    private func resolve(domain: String, pageURL: URL?) async -> LoadedIcon? {
        if let stored = await diskCache.load(domain: domain),
           let image = await Self.decodeIcon(stored.data) {
            let source: Source = stored.source == .pageLink ? .pageLink : .faviconICO
            return LoadedIcon(image: image, source: source)
        }

        if let retryDate = retryAfter[domain], retryDate > Date() {
            return nil
        }

        let declared = pageIconCandidates[domain] ?? []
        let roots = Self.rootFaviconURLs(domain: domain, pageURL: pageURL)
        var seen = Set<String>()
        var candidates: [(url: URL, source: Source)] = []
        for url in declared {
            guard seen.insert(url.absoluteString).inserted else { continue }
            candidates.append((url, .pageLink))
        }
        for url in roots {
            guard seen.insert(url.absoluteString).inserted else { continue }
            candidates.append((url, .faviconICO))
        }

        for candidate in candidates.prefix(Self.maxPageIconCandidates) {
            guard let data = await Self.downloadIcon(candidate.url),
                  let image = await Self.decodeIcon(data) else { continue }
            await diskCache.store(domain: domain, source: candidate.source == .pageLink ? .pageLink : .faviconICO, data: data)
            if candidate.source == .pageLink {
                lastFetchedPageIcon[domain] = candidate.url
                rememberAuxiliaryDomain(domain)
            }
            return LoadedIcon(image: image, source: candidate.source)
        }

        retryAfter[domain] = Date().addingTimeInterval(Self.failureBackoff)
        rememberAuxiliaryDomain(domain)
        faviconLogger.info("No favicon for \(domain); using letter tile")
        return nil
    }

    /// Downloads the page-declared icon and upgrades an existing ICO/letter
    /// result. Runs independently of any visible view, so the history row
    /// opened later still gets the real icon from disk.
    private func fetchDeclaredIcon(domain: String, urls: [URL]) async {
        // A page-link icon may already be on disk from a previous launch.
        if lastFetchedPageIcon[domain] == nil,
           let stored = await diskCache.load(domain: domain), stored.source == .pageLink,
           let image = await Self.decodeIcon(stored.data) {
            lastFetchedPageIcon[domain] = urls.first
            rememberAuxiliaryDomain(domain)
            store(LoadedIcon(image: image, source: .pageLink), for: domain)
            return
        }

        for url in urls.prefix(4) {
            guard let data = await Self.downloadIcon(url),
                  let image = await Self.decodeIcon(data) else { continue }
            await diskCache.store(domain: domain, source: .pageLink, data: data)
            lastFetchedPageIcon[domain] = url
            rememberAuxiliaryDomain(domain)
            store(LoadedIcon(image: image, source: .pageLink), for: domain)
            return
        }
    }

    // MARK: - Memory LRU

    private func rememberAuxiliaryDomain(_ domain: String) {
        auxiliaryLRU.removeAll { $0 == domain }
        auxiliaryLRU.append(domain)
        while auxiliaryLRU.count > Self.auxiliaryLimit {
            let evicted = auxiliaryLRU.removeFirst()
            pageIconCandidates.removeValue(forKey: evicted)
            lastFetchedPageIcon.removeValue(forKey: evicted)
            retryAfter.removeValue(forKey: evicted)
        }
    }

    private func store(_ icon: LoadedIcon, for domain: String) {
        // A slow /favicon.ico fetch must never replace an already-resolved
        // page-declared icon in memory.
        if let existing = memory[domain], existing.source.rawValue > icon.source.rawValue {
            return
        }
        memory[domain] = icon
        touchMemory(domain)
        revision &+= 1
    }

    private func touchMemory(_ domain: String) {
        if let index = memoryLRU.firstIndex(of: domain) {
            memoryLRU.remove(at: index)
        }
        memoryLRU.append(domain)
        while memoryLRU.count > Self.memoryLimit {
            let evicted = memoryLRU.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    // MARK: - Networking / decoding (off the main actor)

    private static func downloadIcon(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await iconSession.data(for: request)
            guard !data.isEmpty, data.count <= maxIconBytes else { return nil }
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }

    /// Decode + downsample off-main. Bounding to 64px also caps the memory a
    /// maliciously large (but small-on-wire) image can allocate.
    private nonisolated static func decodeIcon(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            if let image = decodeImage(data) { return image }
            // Some sites still ship an ICO container whose embedded PNG
            // ImageIO refuses as a whole. Pull the PNG entry out ourselves.
            if let png = embeddedPNG(inICO: data), let image = decodeImage(png) {
                return image
            }
            return nil
        }.value
    }

    private nonisolated static func decodeImage(_ data: Data) -> UIImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: image)
            }
        }
        return UIImage(data: data)
    }

    /// Returns the first PNG-compressed entry of an ICO file, if any.
    private nonisolated static func embeddedPNG(inICO data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6,
              bytes[0] == 0, bytes[1] == 0, bytes[2] == 1, bytes[3] == 0 else { return nil }
        let count = Int(bytes[4]) | (Int(bytes[5]) << 8)
        guard count > 0 else { return nil }
        for index in 0..<count {
            let entry = 6 + index * 16
            guard entry + 16 <= bytes.count else { break }
            let size = littleEndian32(bytes, entry + 8)
            let offset = littleEndian32(bytes, entry + 12)
            guard size >= 4, offset > 0, offset <= bytes.count - size else { continue }
            guard bytes[offset] == 0x89,
                  bytes[offset + 1] == 0x50,
                  bytes[offset + 2] == 0x4E,
                  bytes[offset + 3] == 0x47 else { continue }
            return data.subdata(in: offset..<(offset + size))
        }
        return nil
    }

    private nonisolated static func littleEndian32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset])
            | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16)
            | (Int(bytes[offset + 3]) << 24)
    }

    // MARK: - URL helpers

    /// Normalizes a URL or host into the cache key (lowercased host, no port,
    /// no trailing dot). Returns nil for non-web/blank values.
    static func normalizedDomain(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("about:"),
              !trimmed.hasPrefix("data:"),
              !trimmed.hasPrefix("javascript:") else { return nil }

        var host: String?
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let value = url.host, !value.isEmpty else { return nil }
            host = value
        } else if let url = URL(string: "https://\(trimmed)"), let value = url.host, !value.isEmpty {
            host = value
        }

        guard var value = host else { return nil }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        return value
    }

    static func domain(fromURL urlString: String) -> String? {
        normalizedDomain(urlString)
    }

    private static func rootFaviconURLs(domain: String, pageURL: URL?) -> [URL] {
        func makeURL(_ scheme: String) -> URL? {
            var components = URLComponents()
            components.scheme = scheme
            components.host = domain
            if let pageURL,
               pageURL.host?.lowercased() == domain,
               let port = pageURL.port {
                components.port = port
            }
            components.path = "/favicon.ico"
            return components.url
        }

        if pageURL?.scheme?.lowercased() == "http" {
            return [makeURL("http"), makeURL("https")].compactMap { $0 }
        }
        return [makeURL("https")].compactMap { $0 }
    }

    // MARK: - Fallback tile style

    private static let palette: [UIColor] = [
        UIColor(red: 0.12, green: 0.66, blue: 0.55, alpha: 1), // teal
        UIColor(red: 0.90, green: 0.45, blue: 0.20, alpha: 1), // orange
        UIColor(red: 0.86, green: 0.28, blue: 0.45, alpha: 1), // pink
        UIColor(red: 0.30, green: 0.62, blue: 0.30, alpha: 1), // green
        UIColor(red: 0.20, green: 0.45, blue: 0.76, alpha: 1), // indigo
        UIColor(red: 0.48, green: 0.36, blue: 0.84, alpha: 1), // purple
        UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1), // blue
        UIColor(red: 0.72, green: 0.28, blue: 0.28, alpha: 1), // red
        UIColor(red: 0.22, green: 0.58, blue: 0.72, alpha: 1), // cyan
        UIColor(red: 0.62, green: 0.40, blue: 0.20, alpha: 1)  // brown
    ]

    /// Stable letter + colour for a domain. Same domain → same tile on every
    /// launch (FNV hash, never `hashValue`).
    static func fallbackStyle(forDomain domain: String) -> FallbackStyle {
        let normalized = normalizedDomain(domain) ?? domain.lowercased()
        var letterSource = normalized
        if letterSource.hasPrefix("www.") { letterSource.removeFirst(4) }
        let letter = letterSource.first(where: { $0.isLetter || $0.isNumber })
            .map { String($0).uppercased() } ?? "?"
        let index = Int(FaviconHash.value(for: normalized) % UInt64(palette.count))
        return FallbackStyle(letter: letter, color: palette[index])
    }
}
