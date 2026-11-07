import Foundation

@main struct VisualizationCoreHarness {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ text: String) {
        checks += 1
        guard condition() else { fatalError("Visualization: \(text)") }
    }
    static let fixture = #"{"schemaVersion":1,"id":"fuel","title":"Metrics","sources":[{"id":"user","label":"User data"}],"components":[{"id":"grid","type":"metric_grid","unit":"USD","sourceIDs":["user"],"items":[{"id":"a","label":"A","value":8.91,"precision":2},{"id":"b","label":"B","value":null,"missingReason":"Missing"}]}]}"#
    static func accepted(_ s: String) -> Bool { if case .success = ZeVisualizationParser.parse(s) { return true }; return false }
    static func main() throws {
        require(accepted(fixture), "valid metrics")
        let document = try ZeVisualizationParser.parse(fixture).get()
        require(document.plainText.contains("Missing"), "missing is not zero")
        let encoded = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let restored = try ZeVisualizationParser.parse(encoded).get()
        require(restored == document, "snapshot round trip")
        require(!accepted(fixture.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")), "unknown schema")
        require(!accepted(fixture.replacingOccurrences(of: "metric_grid", with: "javascript")), "unknown component")
        require(!accepted(fixture.replacingOccurrences(of: "\"sourceIDs\":[\"user\"]", with: "\"sourceIDs\":[\"absent\"]")), "source reference")
        require(!accepted(fixture.replacingOccurrences(of: "\"id\":\"b\"", with: "\"id\":\"a\"")), "duplicate IDs")
        require(!accepted(fixture.replacingOccurrences(of: "8.91", with: "1e309")), "nonfinite")
        require(!accepted(fixture.replacingOccurrences(of: "8.91", with: "1e16")), "unsafe plot magnitude")
        require(!accepted(fixture.replacingOccurrences(of: "\"label\":\"User data\"", with: "\"label\":\"User data\",\"url\":\"javascript:alert(1)\"")), "source scheme")
        require(!accepted(fixture.replacingOccurrences(of: "metric_grid", with: "pie").replacingOccurrences(of: "8.91", with: "-1")), "negative pie")
        let chart = #"{"schemaVersion":1,"id":"c","title":"Trend","components":[{"id":"c","type":"line","series":[{"id":"a","label":"A","points":[{"x":1,"y":10},{"x":2,"y":null},{"x":3,"y":12}]}]}]}"#
        require(accepted(chart), "gaps accepted")
        require(!accepted(chart.replacingOccurrences(of: "\"x\":2", with: "\"x\":1")), "duplicate X rejected")
        let table = #"{"schemaVersion":1,"id":"t","title":"Table","components":[{"id":"t","type":"table","headers":["Name","Value"],"rows":[["=SUM(A1)",10],["B",null]]}]}"#
        require(accepted(table), "typed table")
        let csv = try ZeVisualizationParser.parse(table).get().components[0].csv
        require(csv.contains("'=SUM(A1)"), "CSV formula escaped")
        require(!accepted(table.replacingOccurrences(of: "[\"B\",null]", with: "[\"B\"]")), "ragged table")
        require(!accepted(String(repeating: "x", count: ZeVisualizationParser.maxBytes + 1)), "byte limit")
        let open = "before\n```ze-visualization\n" + fixture
        let waiting = ZeVisualizationStreaming.prepare(open)
        require(waiting.contains("ze-visualization-pending") && !waiting.contains("8.91"), "no partial rendering")
        let closed = open + "\n```\nafter"
        require(ZeVisualizationStreaming.prepare(closed) == closed, "closed fence intact")
        let readable = ZeVisualizationStreaming.prepare(closed, readable: true)
        require(readable.contains("Missing") && !readable.contains("schemaVersion"), "whole reply copy and speech use values")
        require(ZeVisualizationStreaming.prepare(open, readable: true).contains("8.91") == false, "unfinished copy does not expose protocol")
        let ordinary = "```swift\nlet x = \"ze-visualization\"\n```"
        require(ZeVisualizationStreaming.prepare(ordinary) == ordinary, "ordinary code intact")
        require(ZeVisualizationStreaming.prepare("~~~ze-visualization\n" + fixture + "\n~~~").contains(fixture), "tilde fences")
        let cache = ZeVisualizationCache()
        for i in 0..<100 { _ = cache.parse(fixture.replacingOccurrences(of: "Metrics", with: "Metrics \(i)")) }
        require(cache.statistics.count <= cache.countLimit && cache.statistics.cost <= cache.costLimit, "LRU bounded")
        cache.clear(); require(cache.statistics.count == 0 && cache.statistics.cost == 0, "clear releases entries")
        _ = cache.parse("{"); require(cache.statistics.count == 0, "incomplete not cached")
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 7 == 0 { cache.clear() } else { _ = cache.parse(fixture) }
        }
        cache.clear(); require(cache.statistics.count == 0, "concurrent clear")
        require(accepted(fixture), "cache purge leaves snapshot valid")
        print("Visualization core: \(checks) checks passed")
    }
}
