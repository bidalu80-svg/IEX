import Foundation
import CZipSupport

// Synthetic bytes only: these Mach-O headers are parser inputs, never executable applications.
struct FixtureEntry {
    var name: String
    var data: Data
    var mode: UInt32 = 0o100644
}
func le(_ value: UInt64, _ count: Int = 4) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
func macho(cpu: UInt64 = 0x100000c, encrypted: Bool = false, minimum: UInt64 = 0x100000,
           platform: UInt64 = 2, versionCommand: UInt64? = 0x32) -> Data {
    let build: Data
    if let versionCommand {
        build = versionCommand == 0x32
            ? le(versionCommand) + le(24) + le(platform) + le(minimum) + le(minimum) + le(0)
            : le(versionCommand) + le(16) + le(minimum) + le(minimum)
    } else {
        build = Data()
    }
    let encryption = encrypted ? le(0x2c) + le(24) + le(0) + le(0) + le(1) + le(0) : Data()
    let commandCount: UInt64 = (versionCommand == nil ? 0 : 1) + (encrypted ? 1 : 0)
    let headerFields: [UInt64] = [0xfeedfacf, cpu, 0, 2, commandCount, UInt64(build.count + encryption.count), 0, 0]
    var header = Data()
    for field in headerFields { header += le(field) }
    header += build
    header += encryption
    return header
}
func appEntries(_ path: String = "Payload/Test.app", id: String = "org.ze.test", cpu: UInt64 = 0x100000c,
                encrypted: Bool = false, minimum: String = "16.0") throws -> [FixtureEntry] {
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "Main",
        "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2", "MinimumOSVersion": minimum]
    return [FixtureEntry(name: path + "/Info.plist", data: try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)),
            FixtureEntry(name: path + "/Main", data: macho(cpu: cpu, encrypted: encrypted))]
}
func zip(_ entries: [FixtureEntry]) -> Data {
    var body = Data(), central = Data()
    for entry in entries {
        let name = Data(entry.name.utf8)
        let crc = entry.data.withUnsafeBytes { ze_crc32($0.bindMemory(to: UInt8.self).baseAddress, entry.data.count) }
        let size = UInt64(entry.data.count), offset = UInt64(body.count)
        body += le(0x04034b50) + le(20,2) + le(0,2) + le(0,2) + le(0,2) + le(0,2)
        body += le(UInt64(crc)) + le(size) + le(size) + le(UInt64(name.count),2) + le(0,2) + name + entry.data
        central += le(0x02014b50) + le(0x314,2) + le(20,2) + le(0,2) + le(0,2) + le(0,2) + le(0,2)
        central += le(UInt64(crc)) + le(size) + le(size) + le(UInt64(name.count),2) + le(0,2) + le(0,2)
        central += le(0,2) + le(0,2) + le(UInt64(entry.mode) << 16) + le(offset) + name
    }
    return body + central + le(0x06054b50) + le(0,2) + le(0,2) + le(UInt64(entries.count),2) + le(UInt64(entries.count),2) + le(UInt64(central.count)) + le(UInt64(body.count)) + le(0,2)
}
