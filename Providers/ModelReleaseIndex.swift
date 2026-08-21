import Foundation

/// Resolves a model's catalog release information into a stable picker order.
/// Missing catalog data never hides a model: local, custom, and relay-backed
/// entries sort after dated entries and remain available.
enum ModelReleaseIndex {
    struct Rank: Comparable {
        let releaseDay: Int?
        let outputCostPerMTok: Double
        let contextWindow: Int
        let displayName: String

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            switch (lhs.releaseDay, rhs.releaseDay) {
            case let (left?, right?) where left != right: return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if lhs.outputCostPerMTok != rhs.outputCostPerMTok {
                return lhs.outputCostPerMTok > rhs.outputCostPerMTok
            }
            if lhs.contextWindow != rhs.contextWindow { return lhs.contextWindow > rhs.contextWindow }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func rank(modelId: String, displayName: String, contextWindow: Int?) -> Rank {
        let hit = resolve(modelId)
        return Rank(releaseDay: hit.day, outputCostPerMTok: hit.outputCost ?? 0,
                    contextWindow: contextWindow ?? hit.context ?? 0, displayName: displayName)
    }

    /// Accepts models.dev's full YYYY-MM-DD format and its YYYY-MM entries.
    static func parseReleaseDate(_ raw: String) -> (date: Date, day: Int)? {
        let parts = raw.split(separator: "-")
        guard parts.count == 2 || parts.count == 3,
              let year = Int(parts[0]), parts[0].count == 4,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = parts.count == 3 ? Int(parts[2]) : 1,
              (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: components) else { return nil }
        let epoch = DateComponents(calendar: calendar, timeZone: TimeZone(secondsFromGMT: 0),
                                   year: 1970, month: 1, day: 1).date!
        return (date, Int(date.timeIntervalSince(epoch) / 86_400))
    }

    private struct Hit { let day: Int?; let outputCost: Double?; let context: Int? }

    private static func resolve(_ raw: String) -> Hit {
        guard let index = ModelsDevAPI.releaseIndex() else { return Hit(day: nil, outputCost: nil, context: nil) }
        let cleaned = clean(raw)
        if let entry = index.byFullId[cleaned] { return hit(entry) }
        var tail = cleaned.split(separator: "/").last.map(String.init) ?? cleaned
        tail = stripVendorPrefix(tail)
        if let entry = index.byTail[tail] { return hit(entry) }
        let undated = stripDateSuffix(tail)
        if undated != tail, let entry = index.byTail[undated] { return hit(entry) }
        var parts = undated.split(separator: "-").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let entry = index.byTail[parts.joined(separator: "-")] { return hit(entry) }
        }
        return Hit(day: nil, outputCost: nil, context: nil)
    }

    private static func hit(_ entry: ModelsDevAPI.ReleaseEntry) -> Hit {
        Hit(day: entry.day, outputCost: entry.outputCost, context: entry.context)
    }

    private static func clean(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = value.firstIndex(of: ":") { value = String(value[..<index]) }
        if let index = value.firstIndex(of: "@") { value = String(value[..<index]) }
        for region in ["us.", "eu.", "apac.", "global."] where value.hasPrefix(region) {
            value = String(value.dropFirst(region.count)); break
        }
        return value
    }

    private static func stripVendorPrefix(_ value: String) -> String {
        guard let dot = value.firstIndex(of: ".") else { return value }
        let prefix = value[..<dot]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isLetter) else { return value }
        return String(value[value.index(after: dot)...])
    }

    private static func stripDateSuffix(_ value: String) -> String {
        guard value.count > 9 else { return value }
        let suffix = value.suffix(9)
        guard suffix.first == "-" else { return value }
        let digits = suffix.dropFirst()
        guard digits.count == 8, digits.allSatisfy(\.isNumber), digits.hasPrefix("20") else { return value }
        return String(value.dropLast(9))
    }
}
