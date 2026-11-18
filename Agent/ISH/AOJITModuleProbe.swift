import Foundation
import Darwin

/// Checks the installed ELF against the identity in the signed, linked image.
/// No guest commands, cached package version, or warm-up record is evidence here.
enum AOJITModuleProbe {
    enum State: Equatable { case matched, family, mismatch, notInstalled }

    struct Image {
        let path: String
        let buildId: String
        let family: String?
    }

    static var images: [Image] {
        (0..<ish_aot_image_count()).compactMap { index in
            guard let pointer = ish_aot_image_metadata(index), let path = pointer.pointee.path else { return nil }
            var module = pointer.pointee
            let length = min(Int(module.build_id_len), 20)
            let id = withUnsafeBytes(of: &module.build_id) {
                $0.prefix(length).map { String(format: "%02x", $0) }.joined()
            }
            return Image(path: String(cString: path), buildId: id,
                         family: module.family.map { String(cString: $0) })
        }
    }

    static var hasLegacySQLiteImage: Bool {
        images.contains { $0.path.contains("_sqlite3.cpython") }
            && !images.contains { $0.path.contains("libsqlite3.so") }
    }

    static func state(for library: AOJITLibrary) -> State {
        let image = images.first { image in library.imageMatch.contains { image.path.contains($0) } }
        // The Node row exists before its first image is linked. Probe its actual
        // module so an installed Node reports No Image, rather than Available.
        let sonames = ["libwebp": "/usr/lib/libwebp.so.7", "libjpeg": "/usr/lib/libjpeg.so.8",
                       "zlib": "/usr/lib/libz.so.1", "sqlite": "/usr/lib/libsqlite3.so.0",
                       "pcre2": "/usr/lib/libpcre2-8.so.0"]
        let preferred = library.id == "sqlite" && hasLegacySQLiteImage ? image?.path : sonames[library.id]
        guard let path = preferred ?? image?.path ?? (library.id == "nodejs" ? "/usr/bin/node" : nil) else { return .mismatch }
        return state(path: path, image: image, root: RootfsManager.shared.dataPath)
    }

    static func state(path: String, image: Image?, root: URL) -> State {
        var path = path
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        for _ in 0..<4 {
            // Resolve fakefs links in the guest namespace; never read outside root.
            let url = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { return .mismatch }
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                path = resolve(target, from: path)
                continue
            }
            guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { return .mismatch }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .notInstalled }
            let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            guard !head.isEmpty else { return .notInstalled }
            if let next = linkTarget(head, from: path) { path = next; continue }
            guard let image else { return .mismatch }
            if let id = buildId(inELF: head), !image.buildId.isEmpty, id == image.buildId { return .matched }
            let file = (path as NSString).lastPathComponent
            if let pattern = image.family, fnmatch(pattern, file, 0) == 0 { return .family }
            return .mismatch
        }
        return .mismatch
    }

    private static func resolve(_ target: String, from path: String) -> String {
        let value = target.hasPrefix("/") ? target : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
        return (value as NSString).standardizingPath
    }

    static func linkTarget(_ data: Data, from path: String) -> String? {
        guard data.count < 1024, !data.starts(with: [0x7f, 0x45, 0x4c, 0x46]),
              let target = String(data: data, encoding: .utf8), !target.isEmpty,
              !target.contains("\0"), !target.contains("\n") else { return nil }
        return resolve(target, from: path)
    }

    /// Bounded ELF64 little-endian PT_NOTE parser. Malformed or truncated ELF
    /// cannot produce an exact match, including overflows in offsets or lengths.
    static func buildId(inELF data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 64, b.starts(with: [0x7f, 0x45, 0x4c, 0x46, 2, 1]) else { return nil }
        func number(_ offset: Int, _ size: Int) -> Int? {
            guard offset >= 0, size <= b.count, offset <= b.count - size else { return nil }
            let value = (0..<size).reduce(UInt64(0)) { $0 | UInt64(b[offset + $1]) << (8 * $1) }
            return Int(exactly: value)
        }
        guard let phoff = number(32, 8), let stride = number(54, 2), stride >= 56,
              let count = number(56, 2), phoff <= b.count,
              count <= (b.count - phoff) / stride else { return nil }
        for index in 0..<count {
            let ph = phoff + index * stride
            guard number(ph, 4) == 4, let start = number(ph + 8, 8),
                  let size = number(ph + 32, 8), start <= b.count,
                  size <= b.count - start else { continue }
            let end = start + size
            var offset = start
            while offset <= end - 12 {
                guard let names = number(offset, 4), let descs = number(offset + 4, 4),
                      let type = number(offset + 8, 4), names <= end - offset - 12 else { return nil }
                let name = offset + 12
                let desc = name + ((names + 3) & ~3)
                guard desc <= end, descs <= end - desc else { return nil }
                if type == 3, names == 4, descs > 0,
                   Array(b[name..<(name + 4)]) == [0x47, 0x4e, 0x55, 0] {
                    return b[desc..<(desc + descs)].map { String(format: "%02x", $0) }.joined()
                }
                offset = desc + ((descs + 3) & ~3)
            }
        }
        return nil
    }
}
