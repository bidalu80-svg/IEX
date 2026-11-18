import Foundation

/// Pending versions have one source: the next recording configuration. They do
/// not describe linked objects; actual imageVersions always take precedence.
enum AOJITRecordingTargets {
    private struct Manifest: Decodable {
        struct Image: Decodable { let id: String; let version: String }
        let images: [Image]
    }

    private static let versions: [String: String] = {
        guard let url = Bundle.main.url(forResource: "aot-targets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [:] }
        return manifest.images.reduce(into: [:]) { $0[$1.id] = $1.version }
    }()

    /// An unknown target must not become an unconstrained package install.
    static func version(for id: String) -> String { versions[id] ?? "" }
}
