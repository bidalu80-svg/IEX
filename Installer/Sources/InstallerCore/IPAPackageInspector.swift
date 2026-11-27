import Foundation
import CZipSupport

public enum PackageErrorCode: String, Codable {
    case io, corruptZIP, unsupportedZIP, unsafePath, symbolicLink, duplicateEntry, resourceLimit
    case appNotFound, multipleApps, missingInfoPlist, invalidInfoPlist, missingExecutable
    case invalidMachO, unsupportedArchitecture, unsupportedPlatform, minimumOSVersion, encryptedExecutable
}

public struct PackageInspectionError: Error, Equatable {
    public let code: PackageErrorCode
    // Static, non-sensitive diagnostics; never includes raw plist contents or paths.
    public let detail: String
    init(_ code: PackageErrorCode, _ detail: String = "") { self.code = code; self.detail = detail }
}

public struct SystemVersion: Comparable, Equatable, Codable {
    public let components: [UInt16]
    public init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ UInt16($0) != nil }) else {
            throw PackageInspectionError(.invalidInfoPlist, "invalid OS version")
        }
        components = parts.map { UInt16($0)! } + Array(repeating: 0, count: 3 - parts.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct InspectedBundle: Equatable {
    public let relativePath: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let executable: String
    public let architectures: [String]
    public let minimumOS: SystemVersion
}

public struct InspectedPackage {
    // This exact directory is owned by this inspection; caller may remove it after use.
    public let taskDirectory: URL
    public let application: InspectedBundle
    public let extensions: [InspectedBundle]
    public let machOFiles: [String]
}

public struct IPAPackageInspector {
    public struct Limits {
        public var archiveBytes = 256 * 1024 * 1024
        public var entryBytes = 128 * 1024 * 1024
        public var expandedBytes = 1024 * 1024 * 1024
        public var entries = 20_000
        public var compressionRatio = 500
        public init() {}
    }
    public var limits: Limits
    public init(limits: Limits = Limits()) { self.limits = limits }

    /// workspace must be an app-owned private directory. No caller-provided task path is removed.
    /// All archive entries are validated before the first archive-controlled write.
    public func inspect(ipa: URL, workspace: URL, deviceOS: SystemVersion,
                        supportedArchitectures: Set<String> = ["arm64", "arm64e"]) throws -> InspectedPackage {
        let fm = FileManager.default
        let root = workspace.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        var ownsRoot = false
        do {
            guard limits.archiveBytes > 0, limits.entryBytes > 0, limits.expandedBytes > 0,
                  limits.entries > 0, limits.compressionRatio > 0 else {
                throw PackageInspectionError(.resourceLimit, "invalid limits")
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            ownsRoot = true
            let inputKind = try ipa.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard inputKind.isRegularFile == true, inputKind.isSymbolicLink != true else {
                throw PackageInspectionError(.io, "input must be a regular file")
            }
            let file = try FileHandle(forReadingFrom: ipa)
            defer { try? file.close() }
            // Read bounded bytes, including one extra byte to detect overflow. Never map a mutable input.
            guard limits.archiveBytes < Int.max else { throw PackageInspectionError(.resourceLimit) }
            let data = try file.read(upToCount: limits.archiveBytes + 1) ?? Data()
            guard data.count <= limits.archiveBytes else { throw PackageInspectionError(.resourceLimit, "archive size") }
            let entries = try ZIP.entries(data, limits: limits)
            for entry in entries {
                let target = root.appendingPathComponent(entry.path, isDirectory: entry.directory)
                if entry.directory {
                    _ = try entry.decode(data)
                    try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
                    let bytes = try entry.decode(data)
                    // Existing files are never overwritten; links/special files are never created.
                    guard fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw PackageInspectionError(.io, "create file")
                    }
                    let output = try FileHandle(forWritingTo: target)
                    do { try output.write(contentsOf: bytes); try output.close() }
                    catch { try? output.close(); throw error }
                }
            }
            let payload = root.appendingPathComponent("Payload", isDirectory: true)
            let candidates = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let apps = candidates.filter { $0.pathExtension == "app" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !apps.isEmpty else { throw PackageInspectionError(.appNotFound) }
            guard apps.count == 1 else { throw PackageInspectionError(.multipleApps) }
            let app = apps[0]
            let main = try bundle(app, root: root, os: deviceOS, architectures: supportedArchitectures)
            let extensionPaths = Set(entries.flatMap { entry -> [String] in
                let parts = entry.path.split(separator: "/")
                return parts.indices.filter { parts[$0].hasSuffix(".appex") }
                    .map { parts[...$0].joined(separator: "/") }
            }).filter { $0.hasPrefix(main.relativePath + "/") }.sorted()
            let extensions = try extensionPaths.map {
                try bundle(root.appendingPathComponent($0), root: root, os: deviceOS, architectures: supportedArchitectures)
            }
            guard Set(([main] + extensions).map(\.bundleIdentifier)).count == extensions.count + 1 else {
                throw PackageInspectionError(.invalidInfoPlist, "duplicate bundle identifiers")
            }
            var binaries: [String] = []
            // Check every Mach-O, including frameworks/dylibs and executables outside PlugIns.
            for entry in entries where !entry.directory {
                let path = root.appendingPathComponent(entry.path)
                let handle = try FileHandle(forReadingFrom: path)
                let prefix = try handle.read(upToCount: 4) ?? Data()
                try handle.close()
                if MachO.hasMagic(prefix) {
                    _ = try MachO.check(Data(contentsOf: path), os: deviceOS, supported: supportedArchitectures)
                    binaries.append(entry.path)
                }
            }
            return InspectedPackage(taskDirectory: root, application: main, extensions: extensions, machOFiles: binaries.sorted())
        } catch {
            if ownsRoot { try? fm.removeItem(at: root) }
            if let error = error as? PackageInspectionError { throw error }
            throw PackageInspectionError(.io, "file operation failed")
        }
    }

    /// Directory enumeration and symlink resolution can spell the same directory
    /// differently (notably Darwin's /private prefix). Canonicalize both URLs and
    /// compare path components before deriving an archive-relative bundle path.
    static func relativeBundlePath(_ url: URL, root: URL) throws -> String {
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let bundleParts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard bundleParts.count > rootParts.count,
              bundleParts.starts(with: rootParts) else {
            throw PackageInspectionError(.unsafePath, "bundle outside task directory")
        }
        let relative = bundleParts.dropFirst(rootParts.count).joined(separator: "/")
        guard ZIP.safeComponents(relative) != nil else {
            throw PackageInspectionError(.unsafePath, "invalid bundle relative path")
        }
        return relative
    }

    private func bundle(_ url: URL, root: URL, os: SystemVersion, architectures: Set<String>) throws -> InspectedBundle {
        let infoURL = url.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { throw PackageInspectionError(.missingInfoPlist) }
        let values: [String: Any]
        do {
            guard let parsed = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any] else {
                throw PackageInspectionError(.invalidInfoPlist)
            }
            values = parsed
        } catch { throw PackageInspectionError(.invalidInfoPlist) }
        func text(_ key: String) throws -> String {
            guard let value = values[key] as? String, !value.isEmpty else { throw PackageInspectionError(.invalidInfoPlist, "required field") }
            return value
        }
        let executable = try text("CFBundleExecutable")
        guard ZIP.safeComponents(executable) == [executable] else { throw PackageInspectionError(.unsafePath, "executable name") }
        let executableURL = url.appendingPathComponent(executable)
        guard (try? executableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PackageInspectionError(.missingExecutable)
        }
        let minimumText: String
        if let rawMinimum = values["MinimumOSVersion"] {
            guard let value = rawMinimum as? String else {
                throw PackageInspectionError(.invalidInfoPlist, "MinimumOSVersion must be a string")
            }
            minimumText = value
        } else {
            minimumText = "0"
        }
        let minOS = try SystemVersion(minimumText)
        guard minOS <= os else { throw PackageInspectionError(.minimumOSVersion) }
        let binary = try MachO.check(Data(contentsOf: executableURL), os: os, supported: architectures, executable: true)
        return try InspectedBundle(relativePath: Self.relativeBundlePath(url, root: root),
                                   bundleIdentifier: text("CFBundleIdentifier"), version: text("CFBundleShortVersionString"),
                                   build: text("CFBundleVersion"), executable: executable,
                                   architectures: binary, minimumOS: minOS)
    }
}

// A deliberately bounded ZIP subset: single disk, UTF-8/ASCII names, stored/DEFLATE.
// ZIP64, encrypted archives and nonregular entries fail closed. No external unzip process.
private enum ZIP {
    struct Entry {
        let path: String
        let directory: Bool
        let method: Int
        let size: Int
        let crc: UInt32
        let range: Range<Int>
        func decode(_ archive: Data) throws -> Data {
            let compressed = archive.subdata(in: range)
            var output: Data
            if method == 0 {
                guard compressed.count == size else { throw PackageInspectionError(.corruptZIP, "stored size") }
                output = compressed
            } else {
                output = Data(count: size)
                let valid = output.withUnsafeMutableBytes { out in
                    compressed.withUnsafeBytes { input in
                        ze_inflate(input.bindMemory(to: UInt8.self).baseAddress, compressed.count,
                                   out.bindMemory(to: UInt8.self).baseAddress, size)
                    }
                }
                guard valid == 1 else { throw PackageInspectionError(.corruptZIP, "DEFLATE stream") }
            }
            let checksum = output.withUnsafeBytes { ze_crc32($0.bindMemory(to: UInt8.self).baseAddress, output.count) }
            guard checksum == crc else { throw PackageInspectionError(.corruptZIP, "CRC mismatch") }
            return output
        }
    }
    static func safeComponents(_ path: String) -> [String]? {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = clean.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 64, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { return nil }
        return parts
    }
    static func entries(_ data: Data, limits: IPAPackageInspector.Limits) throws -> [Entry] {
        func word(_ at: Int, _ bytes: Int = 2) throws -> Int {
            guard at >= 0, at <= data.count - bytes else { throw PackageInspectionError(.corruptZIP, "truncated header") }
            return (0..<bytes).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
        }
        guard data.count >= 22 else { throw PackageInspectionError(.corruptZIP) }
        let lower = max(0, data.count - 65557)
        var end: Int?
        for pos in stride(from: data.count - 22, through: lower, by: -1) {
            if try word(pos, 4) == 0x06054b50, pos + 22 + (try word(pos + 20)) == data.count { end = pos; break }
        }
        guard let end else { throw PackageInspectionError(.corruptZIP, "end record") }
        let count = try word(end + 10)
        guard try word(end + 4) == 0, try word(end + 6) == 0, try word(end + 8) == count,
              count != 65535 else { throw PackageInspectionError(.unsupportedZIP, "multidisk/ZIP64") }
        guard count <= limits.entries else { throw PackageInspectionError(.resourceLimit, "entry count") }
        let central = try word(end + 16, 4)
        guard central + (try word(end + 12, 4)) == end else { throw PackageInspectionError(.corruptZIP, "central bounds") }
        var cursor = central
        var expanded = 0
        var entries: [Entry] = []
        var paths = Set<String>()
        var files = Set<String>()
        var requiredDirectories = Set<String>()
        var ranges: [Range<Int>] = []
        for _ in 0..<count {
            guard try word(cursor, 4) == 0x02014b50 else { throw PackageInspectionError(.corruptZIP, "central header") }
            let flags = try word(cursor + 8), method = try word(cursor + 10)
            guard flags & ~0x080e == 0, flags & 1 == 0, method == 0 || method == 8,
                  try word(cursor + 34) == 0 else { throw PackageInspectionError(.unsupportedZIP) }
            let packed = try word(cursor + 20, 4), size = try word(cursor + 24, 4)
            let nameLength = try word(cursor + 28)
            let recordEnd = cursor + 46 + nameLength + (try word(cursor + 30)) + (try word(cursor + 32))
            guard recordEnd <= end, nameLength > 0, let path = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8),
                  let parts = safeComponents(path) else { throw PackageInspectionError(.unsafePath) }
            let directory = path.hasSuffix("/")
            let type = (try word(cursor + 38, 4) >> 16) & 0xf000
            guard type != 0xa000 else { throw PackageInspectionError(.symbolicLink) }
            guard type == 0 || type == (directory ? 0x4000 : 0x8000) else { throw PackageInspectionError(.unsupportedZIP, "special file") }
            let keyParts = parts.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            let key = keyParts.joined(separator: "/")
            guard paths.insert(key).inserted else { throw PackageInspectionError(.duplicateEntry) }
            let parents = (1..<keyParts.count).map { keyParts.prefix($0).joined(separator: "/") }
            guard !parents.contains(where: { files.contains($0) }), directory || !requiredDirectories.contains(key) else {
                throw PackageInspectionError(.duplicateEntry, "file/directory conflict")
            }
            requiredDirectories.formUnion(parents)
            if !directory { files.insert(key) }
            guard size <= limits.entryBytes, packed <= limits.archiveBytes,
                  size <= limits.expandedBytes - expanded,
                  size / max(1, packed) <= limits.compressionRatio else { throw PackageInspectionError(.resourceLimit, "expanded size/ratio") }
            expanded += size
            let offset = try word(cursor + 42, 4)
            guard offset < central, try word(offset, 4) == 0x04034b50,
                  try word(offset + 6) == flags, try word(offset + 8) == method else { throw PackageInspectionError(.corruptZIP, "local header") }
            let localName = try word(offset + 26)
            let start = offset + 30 + localName + (try word(offset + 28))
            guard localName == nameLength, start <= central, start + packed <= central,
                  data.subdata(in: offset + 30..<offset + 30 + localName) == data.subdata(in: cursor + 46..<cursor + 46 + nameLength) else {
                throw PackageInspectionError(.corruptZIP, "local name/bounds")
            }
            let crc = UInt32(try word(cursor + 16, 4))
            if flags & 8 == 0 {
                guard try word(offset + 14, 4) == Int(crc), try word(offset + 18, 4) == packed,
                      try word(offset + 22, 4) == size else { throw PackageInspectionError(.corruptZIP, "local sizes") }
            }
            if directory && size != 0 { throw PackageInspectionError(.corruptZIP, "directory data") }
            ranges.append(offset..<start + packed)
            entries.append(Entry(path: parts.joined(separator: "/"), directory: directory, method: method,
                                 size: size, crc: crc, range: start..<start + packed))
            cursor = recordEnd
        }
        guard cursor == end else { throw PackageInspectionError(.corruptZIP, "central size") }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for i in sorted.indices.dropFirst() where sorted[i].lowerBound < sorted[i - 1].upperBound {
            throw PackageInspectionError(.corruptZIP, "overlapping entries")
        }
        return entries
    }
}

private enum MachO {
    static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return [[0xce,0xfa,0xed,0xfe], [0xcf,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xce], [0xfe,0xed,0xfa,0xcf],
                [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]]
            .contains(Array(data.prefix(4)))
    }
    static func check(_ data: Data, os: SystemVersion, supported: Set<String>, executable: Bool = false) throws -> [String] {
        func fail(_ detail: String) -> PackageInspectionError { PackageInspectionError(.invalidMachO, detail) }
        func integer(_ at: Int, _ size: Int, little: Bool = true) throws -> UInt64 {
            guard at >= 0, at <= data.count - size else { throw fail("truncated") }
            return (0..<size).reduce(0) { $0 | UInt64(data[at + $1]) << ((little ? $1 : size - 1 - $1) * 8) }
        }
        guard hasMagic(data) else { throw fail("magic") }
        let magic = Array(data.prefix(4))
        let fat = magic[0] == 0xca || magic[0] == 0xbe || magic[0] == 0xbf
        var slices: [Range<Int>] = []
        var declaredCPUs: [UInt64] = []
        if fat {
            let little = magic[0] != 0xca
            let wide = magic[3] == 0xbf || magic[0] == 0xbf
            let count = Int(try integer(4, 4, little: little))
            guard (1...64).contains(count) else { throw fail("fat count") }
            let record = wide ? 32 : 20
            for i in 0..<count {
                let at = 8 + i * record
                let start = try integer(at + 8, wide ? 8 : 4, little: little)
                let size = try integer(at + (wide ? 16 : 12), wide ? 8 : 4, little: little)
                guard start >= UInt64(8 + count * record), start <= UInt64(data.count), size <= UInt64(data.count) - start else { throw fail("fat bounds") }
                let range = Int(start)..<Int(start + size)
                guard !slices.contains(where: { $0.overlaps(range) }) else { throw fail("fat overlap") }
                slices.append(range)
                declaredCPUs.append(try integer(at, 4, little: little))
            }
        } else { slices = [0..<data.count] }
        var architectures = Set<String>()
        for (index, slice) in slices.enumerated() {
            guard slice.count >= 28 else { throw fail("header") }
            let start = slice.lowerBound
            let magic = Array(data[start..<start + 4])
            guard magic == [0xcf,0xfa,0xed,0xfe] || magic == [0xce,0xfa,0xed,0xfe] ||
                  magic == [0xfe,0xed,0xfa,0xcf] || magic == [0xfe,0xed,0xfa,0xce] else { throw fail("thin magic") }
            let little = magic[0] != 0xfe
            let wide = magic[0] == 0xcf || magic[3] == 0xcf
            let cpu = try integer(start + 4, 4, little: little)
            if fat && cpu != declaredCPUs[index] { throw fail("fat CPU mismatch") }
            let subtype = try integer(start + 8, 4, little: little) & 0xffffff
            let arch = cpu == 0x100000c ? (subtype == 2 ? "arm64e" : "arm64") : cpu == 0x1000007 ? "x86_64" : "other"
            architectures.insert(arch)
            if executable, try integer(start + 12, 4, little: little) != 2 { throw fail("not executable") }
            let count = Int(try integer(start + 16, 4, little: little))
            let commandBytes = Int(try integer(start + 20, 4, little: little))
            var cursor = start + (wide ? 32 : 28)
            guard cursor <= slice.upperBound, commandBytes <= slice.upperBound - cursor, count <= commandBytes / 8 else { throw fail("load commands") }
            let end = cursor + commandBytes
            var hasIOSPlatform = false
            var hasOtherPlatform = false
            var minimumIsTooHigh = false
            for _ in 0..<count {
                guard cursor <= end - 8 else { throw fail("command header") }
                let command = try integer(cursor, 4, little: little)
                let size = Int(try integer(cursor + 4, 4, little: little))
                guard size >= 8, size <= end - cursor else { throw fail("command size") }
                if command == 0x21 || command == 0x2c {
                    guard size >= (command == 0x2c ? 24 : 20) else { throw fail("encryption command") }
                    if try integer(cursor + 16, 4, little: little) != 0 { throw PackageInspectionError(.encryptedExecutable) }
                }
                if [0x24, 0x25, 0x2f, 0x30, 0x32].contains(command) {
                    guard size >= (command == 0x32 ? 24 : 16) else { throw fail("OS command") }
                    let isIOS: Bool
                    if command == 0x32 {
                        isIOS = try integer(cursor + 8, 4, little: little) == 2
                    } else {
                        isIOS = command == 0x25
                    }
                    hasIOSPlatform = hasIOSPlatform || isIOS
                    hasOtherPlatform = hasOtherPlatform || !isIOS
                    let version = try integer(cursor + (command == 0x32 ? 12 : 8), 4, little: little)
                    let minimum = try SystemVersion("\(version >> 16).\((version >> 8) & 255).\(version & 255)")
                    minimumIsTooHigh = minimumIsTooHigh || minimum > os
                }
                cursor += size
            }
            guard cursor == end else { throw fail("command count") }
            // Evidence is required for every slice. Known foreign platforms remain platform
            // errors even when their parsed minimum OS also exceeds the device version.
            guard hasIOSPlatform, !hasOtherPlatform else {
                throw PackageInspectionError(.unsupportedPlatform,
                    minimumIsTooHigh ? "non-iOS platform; minimum OS exceeds device" : "missing or non-iOS platform")
            }
            if minimumIsTooHigh { throw PackageInspectionError(.minimumOSVersion) }
        }
        guard !architectures.isDisjoint(with: supported) else { throw PackageInspectionError(.unsupportedArchitecture) }
        return architectures.sorted()
    }
}
