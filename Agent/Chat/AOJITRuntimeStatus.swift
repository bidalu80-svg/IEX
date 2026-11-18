import Foundation

struct AOJITRuntimeStatus {
    struct Coverage: Equatable {
        var blocks = 0
        /// Blocks installed from an image.
        var hits = 0
        /// Of those, found by content in another version (family matching).
        var moved = 0
    }
    var rejected: Set<String> = []
    var accepted: Set<String> = []
    var hits: [String: Coverage] = [:]
    var abi: String?

    init(report: String) {
        for raw in report.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: "(abi ") {
                abi = String(line[r.upperBound...].prefix { $0 != ")" })
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count >= 2, parts[0] == "ok" { accepted.insert(parts[1]) }
            if parts.count >= 2, parts[0].hasPrefix("rejected") { rejected.insert(parts[1]) }
            // "/path   blocks / hits / moved" (moved: family runtimes; absent before)
            if parts.count >= 4, parts[0].hasPrefix("/"), parts[2] == "/",
               let blocks = Int(parts[1]), let hit = Int(parts[3]) {
                let moved = parts.count >= 6 && parts[4] == "/" ? Int(parts[5]) ?? 0 : 0
                hits[parts[0]] = Coverage(blocks: blocks, hits: hit, moved: moved)
            }
        }
    }
}
