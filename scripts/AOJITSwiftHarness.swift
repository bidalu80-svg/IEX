import Foundation

// Only app/native boundaries are fixtures. The real production probe, report
// parser and statistics implementation are compiled by test-aojit-swift.sh.
struct AppLogger {
    init(category: String) { }
    func info(_ line: String) { print(line) }
}
struct AOJITLibrary { let id: String; let imageMatch: [String] }
final class RootfsManager {
    static let shared = RootfsManager()
    var dataPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
}

@main
struct AOJITSwiftHarness {
    static func elf(_ id: [UInt8]) -> Data {
        var data = Data(repeating: 0, count: 136 + id.count)
        func put(_ offset: Int, _ value: Int, _ bytes: Int) {
            for i in 0..<bytes { data[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        data.replaceSubrange(0..<6, with: [0x7f, 0x45, 0x4c, 0x46, 2, 1])
        put(32, 64, 8); put(54, 56, 2); put(56, 1, 2)
        put(64, 4, 4); put(72, 120, 8); put(96, 16 + id.count, 8)
        put(120, 4, 4); put(124, id.count, 4); put(128, 3, 4)
        data.replaceSubrange(132..<136, with: [0x47, 0x4e, 0x55, 0])
        data.replaceSubrange(136..<data.count, with: id)
        return data
    }

    static func main() async throws {
        let bytes = Array(UInt8(0)..<UInt8(20))
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        let data = elf(bytes)
        precondition(AOJITModuleProbe.buildId(inELF: data) == id)
        precondition(AOJITModuleProbe.buildId(inELF: data.dropLast()) == nil)
        var bigEndian = data; bigEndian[5] = 2
        precondition(AOJITModuleProbe.buildId(inELF: bigEndian) == nil)
        var malformed = data
        malformed.replaceSubrange(32..<40, with: [UInt8](repeating: 255, count: 8))
        precondition(AOJITModuleProbe.buildId(inELF: malformed) == nil)

        let root = RootfsManager.shared.dataPath
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("libx.so.1.2")
        try data.write(to: file)
        try Data("libx.so.1.2".utf8).write(to: root.appendingPathComponent("libx.so.1"))
        let image = AOJITModuleProbe.Image(path: "/libx.so.1.2", buildId: id, family: "libx.so.1*")
        precondition(AOJITModuleProbe.state(path: "/libx.so.1", image: image, root: root) == .matched)
        let other = AOJITModuleProbe.Image(path: image.path, buildId: "00", family: image.family)
        precondition(AOJITModuleProbe.state(path: "/libx.so.1", image: other, root: root) == .family)
        let foreign = AOJITModuleProbe.Image(path: image.path, buildId: "00", family: "liby.so.2*")
        precondition(AOJITModuleProbe.state(path: "/libx.so.1", image: foreign, root: root) == .mismatch)
        precondition(AOJITModuleProbe.state(path: "/missing", image: image, root: root) == .notInstalled)
        try Data("loop".utf8).write(to: root.appendingPathComponent("loop"))
        precondition(AOJITModuleProbe.state(path: "/loop", image: image, root: root) == .mismatch)
        fixture_module("/usr/lib/python3.12/lib-dynload/_sqlite3.cpython-312-aarch64-linux-musl.so", id, "_sqlite3.cpython-312-aarch64-linux-musl.so")
        precondition(AOJITModuleProbe.hasLegacySQLiteImage)
        precondition(AOJITModuleProbe.images[0].buildId == id)

        let before = AOJITShellStats.Snapshot(report: "")
        let report = """
        mode: AOT images only
        AOT: on
        blocks translated or looked up: 100, AOT installs: 80 (moved: 12)
        images: 1 in use, 1 rejected (abi 1f3bb5a0)
          ok /usr/lib/libx.so (10 translations)
          rejected /bad.so (wrong abi)
          /usr/lib/libx.so 90 / 80 / 12
        """
        let after = AOJITShellStats.Snapshot(report: report)
        precondition(after.aotOn && after.blocks == 100 && after.installs == 80 && after.moved == 12)
        precondition(after.modules["/usr/lib/libx.so"] == AOJITRuntimeStatus.Coverage(blocks: 90, hits: 80, moved: 12))
        let status = AOJITRuntimeStatus(report: report)
        precondition(status.rejected == ["/bad.so"] && status.accepted == ["/usr/lib/libx.so"])
        let line = AOJITShellStats.format(before: before, after: after, seconds: 1.25,
                                         exitCode: 3, overlap: 2, command: String(repeating: "x", count: 101))
        precondition(line.contains("aot=+80 (80%)") && line.contains("other=+10"))
        precondition(line.contains("exit=3 overlap=2") && line.hasSuffix("…\""))
        let reset = AOJITShellStats.format(before: after, after: before, seconds: 0, exitCode: 0, overlap: 0, command: "true")
        precondition(reset.contains("blocks=+0 aot=+0 (-%)") == false)
        precondition(reset.contains("blocks=+0 aot=+0 (-)"))
        precondition(AOJITShellStats.percent(9999, of: 10000) == "99%")
        precondition(AOJITShellStats.percent(1, of: 10000) == "1%")
        fixture_report(report)
        let a = await AOJITShellStats.begin()
        let b = await AOJITShellStats.begin()
        precondition(a != nil && b?.othersAtStart == 1)
        await AOJITShellStats.end(a, command: "first", exitCode: 0)
        await AOJITShellStats.end(b, command: "second", exitCode: 0)
        print("Production Swift probe/report/stats harness passed (native/app boundaries are fixtures)")
    }
}
