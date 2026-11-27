import XCTest
@testable import InstallerCore

final class IPAPackageInspectorTests: XCTestCase {
    var sandbox: URL!
    var workspace: URL!
    let fm = FileManager.default
    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = sandbox.appendingPathComponent("tasks")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: workspace.appendingPathComponent("other-task"))
    }
    override func tearDownWithError() throws { try fm.removeItem(at: sandbox) }

    @discardableResult func inspect(_ bytes: Data, inspector: IPAPackageInspector = IPAPackageInspector()) throws -> InspectedPackage {
        let source = sandbox.appendingPathComponent("original.ipa")
        try bytes.write(to: source)
        if let evidence = ProcessInfo.processInfo.environment["IPA_EVIDENCE"] {
            let directory = URL(fileURLWithPath: evidence).appendingPathComponent("package/fixtures")
            let label = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            try bytes.write(to: directory.appendingPathComponent(label + "-" + UUID().uuidString + ".zip"))
        }
        return try inspector.inspect(ipa: source, workspace: workspace, deviceOS: SystemVersion("27.0"))
    }
    func reject(_ entries: [FixtureEntry], _ code: PackageErrorCode, inspector: IPAPackageInspector = IPAPackageInspector(),
                file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = zip(entries)
        XCTAssertThrowsError(try inspect(bytes, inspector: inspector), file: file, line: line) {
            XCTAssertEqual(($0 as? PackageInspectionError)?.code, code, file: file, line: line)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: workspace.path), ["other-task"], file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: sandbox.appendingPathComponent("original.ipa")), bytes, file: file, line: line)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("other-task")), "keep", file: file, line: line)
    }
    func testLegalSingleApp() throws {
        let package = try inspect(zip(appEntries()))
        XCTAssertEqual(package.application.bundleIdentifier, "org.ze.test")
        XCTAssertEqual(package.application.architectures, ["arm64"])
        XCTAssertEqual(package.application.build, "42")
        XCTAssertTrue(package.extensions.isEmpty)
        XCTAssertEqual(package.machOFiles, ["Payload/Test.app/Main"])
    }
    func testExtensionsBothLayouts() throws {
        let entries = try appEntries() + appEntries("Payload/Test.app/PlugIns/Widget.appex", id: "org.ze.widget") +
            appEntries("Payload/Test.app/Extensions/Camera.appex", id: "org.ze.camera")
        let package = try inspect(zip(entries))
        XCTAssertEqual(package.extensions.count, 2)
        XCTAssertEqual(Set(package.extensions.map(\.bundleIdentifier)), ["org.ze.widget", "org.ze.camera"])
        XCTAssertEqual(package.application.relativePath, "Payload/Test.app")
        let expectedPaths = ["Payload/Test.app/Extensions/Camera.appex", "Payload/Test.app/PlugIns/Widget.appex"]
        XCTAssertEqual(package.extensions.map(\.relativePath), expectedPaths)

        // Reproduce different absolute spellings of the same task directory on any
        // host. Darwin can introduce this via /private URL canonicalization; a
        // deliberate symlink alias exercises the production path conversion on Linux.
        let alias = sandbox.appendingPathComponent("task-alias-with-a-different-length", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: package.taskDirectory)
        let canonicalApp = package.taskDirectory.appendingPathComponent("Payload/Test.app", isDirectory: true)
        let aliasedApp = alias.appendingPathComponent("Payload/Test.app", isDirectory: true)
        XCTAssertNotEqual(aliasedApp.path, canonicalApp.path)
        XCTAssertEqual(try IPAPackageInspector.relativeBundlePath(aliasedApp, root: package.taskDirectory), "Payload/Test.app")
        XCTAssertEqual(try IPAPackageInspector.relativeBundlePath(canonicalApp, root: alias), "Payload/Test.app")
        for path in expectedPaths {
            XCTAssertEqual(try IPAPackageInspector.relativeBundlePath(alias.appendingPathComponent(path), root: package.taskDirectory), path)
        }
        for unrelated in [try XCTUnwrap(sandbox), workspace.appendingPathComponent("other-task"),
                          URL(fileURLWithPath: package.taskDirectory.path + "-sibling/Payload/Test.app")] {
            XCTAssertThrowsError(try IPAPackageInspector.relativeBundlePath(unrelated, root: package.taskDirectory)) {
                XCTAssertEqual(($0 as? PackageInspectionError)?.code, .unsafePath)
            }
        }
    }
    func testMissingInfo() throws { try reject(Array(appEntries().dropFirst()), .missingInfoPlist) }
    func testMissingExecutable() throws { try reject(Array(appEntries().prefix(1)), .missingExecutable) }
    func testMultipleApps() throws { try reject(appEntries() + appEntries("Payload/Other.app", id: "org.ze.other"), .multipleApps) }
    func testNoApp() throws { try reject([FixtureEntry(name: "notes.txt", data: Data())], .appNotFound) }
    func testWrongArchitecture() throws { try reject(appEntries(cpu: 0x1000007), .unsupportedArchitecture) }
    func testMinimumOS() throws { try reject(appEntries(minimum: "28.0"), .minimumOSVersion) }
    func testMachOMinimumOS() throws {
        var entries = try appEntries(); entries[1].data = macho(minimum: 0x1c0000)
        try reject(entries, .minimumOSVersion)
    }
    func testSimulatorPlatform() throws {
        var entries = try appEntries(); entries[1].data = macho(platform: 7)
        try reject(entries, .unsupportedPlatform)
    }
    func testEncryptedMain() throws { try reject(appEntries(encrypted: true), .encryptedExecutable) }
    func testEncryptedExtensionAndFramework() throws {
        try reject(appEntries() + appEntries("Payload/Test.app/PlugIns/Widget.appex", id: "org.ze.widget", encrypted: true), .encryptedExecutable)
        try reject(appEntries() + [FixtureEntry(name: "Payload/Test.app/Frameworks/F.framework/F", data: macho(encrypted: true))], .encryptedExecutable)
    }
    func testCorruptZIP() throws {
        XCTAssertThrowsError(try inspect(Data("bad ZIP".utf8))) {
            XCTAssertEqual(($0 as? PackageInspectionError)?.code, .corruptZIP)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: workspace.path), ["other-task"])
    }
    func testCRCDetectsCorruption() throws {
        var bytes = try zip(appEntries())
        // Mutate a payload byte while keeping ZIP metadata unchanged.
        let nameSize = Int(bytes[26]) | (Int(bytes[27]) << 8)
        bytes[30 + nameSize] ^= 1
        XCTAssertThrowsError(try inspect(bytes)) {
            XCTAssertEqual(($0 as? PackageInspectionError)?.code, .corruptZIP)
            XCTAssertEqual(($0 as? PackageInspectionError)?.detail, "CRC mismatch")
        }
    }
    func testTraversalAndAbsolutePaths() throws {
        let sentinel = sandbox.appendingPathComponent("escape")
        try Data("outside".utf8).write(to: sentinel)
        for path in ["../escape", "Payload/../../escape", sentinel.path, "/tmp/selfsign-escape", "C:/escape", "Payload\\..\\escape", "Payload//escape", "./escape"] {
            try reject(appEntries() + [FixtureEntry(name: path, data: Data("bad".utf8))], .unsafePath)
            XCTAssertEqual(try String(contentsOf: sentinel), "outside")
        }
    }
    func testSymbolicLinkEscape() throws {
        try reject(appEntries() + [FixtureEntry(name: "Payload/Test.app/link", data: Data("../../../escape".utf8), mode: 0o120777)], .symbolicLink)
    }
    func testDuplicateAndCaseAlias() throws {
        let entries = try appEntries()
        try reject(entries + [entries[0]], .duplicateEntry)
        try reject(entries + [FixtureEntry(name: "payload/test.app/main", data: Data())], .duplicateEntry)
    }
    func testFileDirectoryConflict() throws {
        try reject(appEntries() + [FixtureEntry(name: "Payload/Test.app/Dir/file", data: Data()), FixtureEntry(name: "Payload/Test.app/Dir", data: Data())], .duplicateEntry)
    }
    func testResourceLimitsAndOnlyTaskCleanup() throws {
        var limits = IPAPackageInspector.Limits()
        limits.entryBytes = 16
        try reject(appEntries(), .resourceLimit, inspector: IPAPackageInspector(limits: limits))
        limits = .init(); limits.expandedBytes = 20
        try reject(appEntries(), .resourceLimit, inspector: IPAPackageInspector(limits: limits))
        limits = .init(); limits.entries = 1
        try reject(appEntries(), .resourceLimit, inspector: IPAPackageInspector(limits: limits))
        limits = .init(); limits.archiveBytes = 30
        try reject(appEntries(), .resourceLimit, inspector: IPAPackageInspector(limits: limits))
    }
    func testMalformedMachOAndPlist() throws {
        var entries = try appEntries(); entries[1].data = Data([0xcf,0xfa,0xed,0xfe])
        try reject(entries, .invalidMachO)
        entries = try appEntries(); entries[0].data = Data("not plist".utf8)
        try reject(entries, .invalidInfoPlist)
    }
    func testIndependentDeflateFixture() throws {
        // Generated by Python's standard zipfile implementation in the evidence runner.
        guard let path = ProcessInfo.processInfo.environment["IPA_DEFLATE_FIXTURE"] else { throw XCTSkip("run Installer/run-review.py for independent ZIP fixtures") }
        let package = try inspect(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(package.application.bundleIdentifier, "org.ze.test")
    }

    func testFatBinaryAndEncryptedSecondarySlice() throws {
        let arm = macho(), x86 = macho(cpu: 0x1000007)
        func fat(_ second: Data) -> Data {
            // FAT_MAGIC with big-endian records; thin slices retain their own endianness.
            func be(_ n: UInt64) -> Data { Data(le(n).reversed()) }
            return be(0xcafebabe) + be(2) + be(0x100000c) + be(0) + be(48) + be(UInt64(arm.count)) + be(0) +
                be(0x1000007) + be(0) + be(UInt64(48 + arm.count)) + be(UInt64(second.count)) + be(0) + arm + second
        }
        var entries = try appEntries(); entries[1].data = fat(x86)
        let result = try inspect(zip(entries))
        XCTAssertEqual(result.application.architectures, ["arm64", "x86_64"])
        try fm.removeItem(at: result.taskDirectory)
        entries[1].data = fat(macho(cpu: 0x1000007, encrypted: true))
        try reject(entries, .encryptedExecutable)
    }
    func testUnicodeAliasAndReverseFileDirectoryConflict() throws {
        try reject(appEntries() + [FixtureEntry(name: "Payload/Test.app/é", data: Data()),
                                  FixtureEntry(name: "Payload/Test.app/e\u{301}", data: Data())], .duplicateEntry)
        try reject(appEntries() + [FixtureEntry(name: "Payload/Test.app/Dir", data: Data()),
                                  FixtureEntry(name: "Payload/Test.app/Dir/child", data: Data())], .duplicateEntry)
    }
    func testHugeAdvertisedExpansionRejectedBeforeAllocation() throws {
        var bytes = zip([FixtureEntry(name: "bomb", data: Data())])
        let central = 30 + 4
        let huge = le(0x7fffffff)
        bytes.replaceSubrange(22..<26, with: huge)
        bytes.replaceSubrange(central + 24..<central + 28, with: huge)
        XCTAssertThrowsError(try inspect(bytes)) { XCTAssertEqual(($0 as? PackageInspectionError)?.code, .resourceLimit) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: workspace.path), ["other-task"])
    }
    func testInputSymlinkCannotAffectOriginalOrOtherTasks() throws {
        let source = sandbox.appendingPathComponent("source.zip")
        let link = sandbox.appendingPathComponent("link.zip")
        let bytes = try zip(appEntries())
        try bytes.write(to: source)
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try IPAPackageInspector().inspect(ipa: link, workspace: workspace, deviceOS: SystemVersion("27"))) {
            XCTAssertEqual(($0 as? PackageInspectionError)?.code, .io)
        }
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: workspace.path), ["other-task"])
    }
    func testDeflateDirectoryAndSizeLie() throws {
        guard let path = ProcessInfo.processInfo.environment["IPA_DEFLATE_FIXTURE"] else { throw XCTSkip("requires evidence runner") }
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        _ = try inspect(Data(contentsOf: base.appendingPathComponent("deflate-directories.zip")))
        XCTAssertThrowsError(try inspect(Data(contentsOf: base.appendingPathComponent("deflate-size-lie.zip")))) {
            XCTAssertEqual(($0 as? PackageInspectionError)?.code, .corruptZIP)
        }
    }

    func testLegacyTVOSPlatformRejected() throws {
        var entries = try appEntries(); entries[1].data = macho(versionCommand: 0x2f)
        try reject(entries, .unsupportedPlatform)
    }
    func testLegacyMacOSPlatformRejected() throws {
        var entries = try appEntries(); entries[1].data = macho(versionCommand: 0x24)
        try reject(entries, .unsupportedPlatform)
    }
    func testLegacyWatchOSPlatformRejected() throws {
        var entries = try appEntries(); entries[1].data = macho(versionCommand: 0x30)
        try reject(entries, .unsupportedPlatform)
    }
    func testMissingPlatformEvidenceRejected() throws {
        var entries = try appEntries(); entries[1].data = macho(versionCommand: nil)
        try reject(entries, .unsupportedPlatform)
    }
    func testLegacyIOSPlatformAccepted() throws {
        var entries = try appEntries(); entries[1].data = macho(versionCommand: 0x25)
        XCTAssertEqual(try inspect(zip(entries)).application.architectures, ["arm64"])
    }
    func testLegacyIOSMinimumOSCompared() throws {
        var entries = try appEntries(); entries[1].data = macho(minimum: 0x1c0000, versionCommand: 0x25)
        try reject(entries, .minimumOSVersion)
    }
    func testForeignMinimumOSComparedButRemainsPlatformError() throws {
        for command: UInt64 in [0x24, 0x2f, 0x30] {
            var entries = try appEntries(); entries[1].data = macho(minimum: 0x1c0000, versionCommand: command)
            XCTAssertThrowsError(try inspect(zip(entries))) {
                XCTAssertEqual(($0 as? PackageInspectionError)?.code, .unsupportedPlatform)
                XCTAssertEqual(($0 as? PackageInspectionError)?.detail, "non-iOS platform; minimum OS exceeds device")
            }
        }
    }

    func testMinimumOSWrongTypeIsInvalidInfoPlist() throws {
        for wrongValue: Any in [27, true, ["27.0"], ["version": "27.0"]] {
            var entries = try appEntries()
            var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: entries[0].data, format: nil) as? [String: Any])
            info["MinimumOSVersion"] = wrongValue
            entries[0].data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try reject(entries, .invalidInfoPlist)
        }
    }
    func testMissingMinimumOSRetainsFallback() throws {
        var entries = try appEntries()
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: entries[0].data, format: nil) as? [String: Any])
        info.removeValue(forKey: "MinimumOSVersion")
        entries[0].data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        XCTAssertEqual(try inspect(zip(entries)).application.minimumOS, try SystemVersion("0"))
    }
}
