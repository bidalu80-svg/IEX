import Foundation

/// The OpenMinis bundled core restore, offered only after the linked image has
/// actually been replaced with the corresponding r8 recording. The old Ze r12 /
/// r14 images must never be advertised as repaired by installing these APKs.
enum AOJITRestore {
    static func packages(for library: AOJITLibrary) -> [String] {
        let expected: (String, [String])
        switch library.id {
        case "musl": expected = ("384940f9110e809da953d6fbabcb31d297c217b5", ["musl", "musl-utils"])
        case "busybox": expected = ("2f8b429ec88eacccb94c8bb23ec060ab4a028ee8", ["busybox", "busybox-binsh", "ssl_client"])
        default: return []
        }
        return AOJITModuleProbe.images.contains { $0.buildId == expected.0 } ? expected.1 : []
    }

    static func run(for library: AOJITLibrary) async throws -> (code: Int, output: String) {
        let packages = packages(for: library)
        guard !packages.isEmpty else {
            throw NSError(domain: "AOJITRestore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled APKs do not match this app's linked core image. Host recording is required."])
        }
        guard let bundled = Bundle.main.url(forResource: "AOJITRestore", withExtension: nil) else {
            throw NSError(domain: "AOJITRestore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled restore packages are missing."])
        }
        let stage = "/var/cache/minis-aojit/bundled"
        try await Task.detached(priority: .utility) {
            try RootfsManager.shared.stageFiles(from: bundled, toLinuxDir: stage)
        }.value
        let result = try await ISHExecutionCoordinator.shared.execute(
            sessionId: "aojit-settings",
            command: "sh \(stage)/restore.sh \(stage) \(packages.joined(separator: " ")) 2>&1; rc=$?; rm -rf \(stage); exit $rc",
            timeout: 900, lineCallback: { _ in }, pidCallback: { _ in })
        return (Int(result.exitCode), result.output)
    }

    static func message(code: Int, output: String) -> String {
        let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
        switch code {
        case 0: return String(localized: "Restored the bundled package build. New commands use the restored modules.")
        case 1: return String(localized: "The bundled package build is already installed.")
        case 11: return String(localized: "Nothing was changed: the installed build could not be downloaded for rollback.")
        case 12: return String(localized: "Nothing was changed: the simulation would change other packages.") + "\n" + tail
        case 13: return String(localized: "The install failed and was rolled back.") + "\n" + tail
        case 14: return String(localized: "Install and rollback failed. Recovery APKs remain in /var/cache/minis-aojit/rollback/.") + "\n" + tail
        default: return String(localized: "Restore failed.") + "\n" + tail
        }
    }
}


extension RootfsManager {
    func stageFiles(from dir: URL, toLinuxDir linuxDir: String) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let src = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let relativePath = "\(linuxDir)/\(name)"
            let dest = dataPath.appendingPathComponent(String(relativePath.dropFirst()))
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            ensureParentDirsInMetaDB(for: relativePath)
            ensureFakefsMetadata(for: relativePath, isDirectory: false, mode: 0o100644)
        }
    }

}
