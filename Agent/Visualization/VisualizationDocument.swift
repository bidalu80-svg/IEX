import Foundation

/// Small, transient UI values. No datasets, views, bitmaps or disk cache.
/// A share request copies these values independently of the live conversation.
struct ZeVisualizationSelection: Equatable {
    var seriesIndex: Int?
    var lastHalf = false
    var selectedText: String?
    var selectedPointIndex: Int?
    var customStateJSON: String?
    var customContentHeight: Double?
}

/// Immutable, provider-independent snapshots. JSON stays in the existing message
/// store; derived caches never own the only copy of a user's data.
struct ZeVisualizationDocument: Codable, Hashable {
    let schemaVersion: Int
    let id: String
    let title: String
    var subtitle: String?
    var sources: [ZeVisualizationSource]?
    let components: [ZeVisualizationComponent]

    var plainText: String {
        ([title, subtitle ?? ""] + components.map(\.plainText) + (sources ?? []).map(\.plainText))
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct ZeVisualizationSource: Codable, Hashable {
    let id: String
    let label: String
    var url: String?
    var observedAt: String?
    var retrievedAt: String?
    var plainText: String { [label, observedAt, retrievedAt, url].compactMap { $0 }.joined(separator: " · ") }
}

enum ZeVisualizationKind: String, Codable, Hashable {
    case metricGrid = "metric_grid", line, bar, area, pie, donut, table, info, custom
    var isChart: Bool { [.line, .bar, .area, .pie, .donut].contains(self) }
}

struct ZeVisualizationComponent: Codable, Hashable {
    let id: String
    let type: ZeVisualizationKind
    var title: String?
    var unit: String?
    var sourceIDs: [String]?
    var items: [ZeVisualizationItem]?
    var series: [ZeVisualizationSeries]?
    /// numeric, time (Unix seconds), or category (x is the category index).
    var xAxis: String?
    var headers: [String]?
    var rows: [[ZeVisualizationCell]]?
    /// Self-contained model-authored interface; no remote scripts/resources.
    var html: String?
    var height: Int?
    var fallbackText: String?
    var plainText: String {
        var parts = [title ?? "", unit ?? ""].filter { !$0.isEmpty }
        if let fallbackText { parts.append(fallbackText) }
        parts += (items ?? []).map { [$0.label, $0.displayValue, $0.detail ?? ""].filter { !$0.isEmpty }.joined(separator: ": ") }
        for series in series ?? [] {
            parts.append(series.label)
            parts += series.points.map { "\(xLabel($0)): \($0.y.map { ZeVisualizationFormat.number($0) } ?? "—")" }
        }
        if let headers { parts.append(headers.joined(separator: "\t")) }
        parts += (rows ?? []).map { $0.map(\.text).joined(separator: "\t") }
        return parts.joined(separator: "\n")
    }
    func xLabel(_ point: ZeVisualizationPoint) -> String {
        if let label = point.label { return label }
        if xAxis == "time" {
            return Date(timeIntervalSince1970: point.x).formatted(date: .abbreviated, time: .omitted)
        }
        return ZeVisualizationFormat.number(point.x)
    }
    var csv: String {
        func quote(_ s: String) -> String {
            // Spreadsheet formula injection is possible even in model/user supplied labels.
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: s.hasPrefix) ? "'" + s : s
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let values: [[String]]
        if type == .table { values = [headers ?? []] + (rows ?? []).map { $0.map(\.text) } }
        else if let series { values = [["Series", "X", "Value", "Unit"]] + series.flatMap { s in s.points.map { [s.label, xLabel($0), $0.y.map { String($0) } ?? "", unit ?? ""] } } }
        else { values = [["Label", "Value", "Unit"]] + (items ?? []).map { [$0.label, $0.displayValue, unit ?? ""] } }
        return values.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n")
    }
}

struct ZeVisualizationItem: Codable, Hashable {
    let id: String
    let label: String
    var value: Double?
    var precision: Int?
    var text: String?
    var detail: String?
    var missingReason: String?
    var displayValue: String { value.map { ZeVisualizationFormat.number($0, precision: precision) } ?? text ?? missingReason ?? "—" }
}
struct ZeVisualizationSeries: Codable, Hashable {
    let id: String
    let label: String
    let points: [ZeVisualizationPoint]
}
struct ZeVisualizationPoint: Codable, Hashable {
    let x: Double
    var y: Double?
    var label: String?
}
enum ZeVisualizationCell: Codable, Hashable {
    case number(Double), text(String), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .text(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .number(let n): try c.encode(n); case .text(let s): try c.encode(s); case .null: try c.encodeNil() }
    }
    var text: String { switch self { case .number(let n): return ZeVisualizationFormat.number(n); case .text(let s): return s; case .null: return "—" } }
}
enum ZeVisualizationFormat {
    static func number(_ n: Double, precision: Int? = nil) -> String {
        if let precision { return n.formatted(.number.precision(.fractionLength(max(0, min(6, precision))))) }
        return n.formatted(.number.precision(.fractionLength(0...4)))
    }
}

enum ZeVisualizationError: Error, Equatable {
    case incomplete, invalid, limit, version
    var text: String {
        switch self {
        case .incomplete: return String(localized: "Visualization data is incomplete.")
        case .invalid: return String(localized: "Visualization data could not be displayed. Ask for a text table instead.")
        case .limit: return String(localized: "Visualization is too large. Ask for a smaller data range.")
        case .version: return String(localized: "This visualization requires a newer format.")
        }
    }
}

enum ZeVisualizationParser {
    static let maxBytes = 262_144
    static func isFence(_ info: String?) -> Bool { info?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ze-visualization" }
    static func parse(_ json: String) -> Result<ZeVisualizationDocument, ZeVisualizationError> {
        guard json.utf8.count <= maxBytes else { return .failure(.limit) }
        guard json.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}") else { return .failure(.incomplete) }
        guard let d = try? JSONDecoder().decode(ZeVisualizationDocument.self, from: Data(json.utf8)) else { return .failure(.invalid) }
        guard d.schemaVersion == 1 else { return .failure(.version) }
        func text(_ s: String?) -> Bool { (s?.utf8.count ?? 0) <= 4096 }
        func id(_ s: String) -> Bool { !s.isEmpty && s.utf8.count <= 128 }
        func number(_ n: Double) -> Bool { n.isFinite && abs(n) <= 1e15 }
        func unique(_ ids: [String]) -> Bool { ids.allSatisfy(id) && Set(ids).count == ids.count }
        guard id(d.id), !d.title.isEmpty, text(d.title), text(d.subtitle), (1...12).contains(d.components.count),
              unique(d.components.map(\.id)), (d.sources?.count ?? 0) <= 16,
              unique((d.sources ?? []).map(\.id)) else { return .failure(.limit) }
        let sourceIDs = Set((d.sources ?? []).map(\.id))
        for source in d.sources ?? [] {
            guard text(source.label), text(source.observedAt), text(source.retrievedAt) else { return .failure(.limit) }
            if let raw = source.url {
                guard raw.utf8.count <= 2048, let u = URL(string: raw), ["https", "http"].contains(u.scheme?.lowercased() ?? ""),
                      u.host != nil, u.user == nil, u.password == nil else { return .failure(.invalid) }
            }
        }
        var totalPoints = 0
        guard d.components.filter({ $0.type == .custom }).count <= 2 else { return .failure(.limit) }
        for c in d.components {
            guard text(c.title), text(c.unit), (c.sourceIDs ?? []).allSatisfy(sourceIDs.contains),
                  [nil, "numeric", "time", "category"].contains(c.xAxis),
                  (c.items?.count ?? 0) <= 48, unique((c.items ?? []).map(\.id)),
                  (c.series?.count ?? 0) <= 8, unique((c.series ?? []).map(\.id)) else { return .failure(.invalid) }
            for item in c.items ?? [] {
                guard text(item.label), text(item.text), text(item.detail), text(item.missingReason),
                      item.precision.map({ (0...6).contains($0) }) ?? true,
                      item.value.map(number) ?? true else { return .failure(.invalid) }
                if c.type == .pie || c.type == .donut, let value = item.value, value < 0 { return .failure(.invalid) }
            }
            for series in c.series ?? [] {
                guard text(series.label), !series.points.isEmpty else { return .failure(.invalid) }
                totalPoints += series.points.count
                guard totalPoints <= 2000 else { return .failure(.limit) }
                var previous: Double?
                for p in series.points {
                    guard number(p.x), p.y.map(number) ?? true, text(p.label), previous.map({ p.x > $0 }) ?? true else { return .failure(.invalid) }
                    if c.xAxis == "time", !(0...253_402_300_799).contains(p.x) { return .failure(.invalid) }
                    previous = p.x
                }
            }
            let headers = c.headers ?? [], rows = c.rows ?? []
            guard headers.count <= 12, headers.allSatisfy({ text($0) }), rows.count <= 200 else { return .failure(.limit) }
            for row in rows {
                guard row.count == headers.count else { return .failure(.invalid) }
                for cell in row {
                    switch cell { case .number(let n): if !number(n) { return .failure(.invalid) }; case .text(let s): if !text(s) { return .failure(.limit) }; case .null: break }
                }
            }
            switch c.type {
            case .custom:
                guard let html = c.html, !html.isEmpty, html.utf8.count <= 131_072,
                      let fallback = c.fallbackText, !fallback.isEmpty, text(fallback),
                      (180...600).contains(c.height ?? 360) else { return .failure(.invalid) }
            case .metricGrid, .info, .pie, .donut: guard !(c.items ?? []).isEmpty else { return .failure(.invalid) }
            case .line, .bar, .area: guard !(c.series ?? []).isEmpty else { return .failure(.invalid) }
            case .table: guard !headers.isEmpty else { return .failure(.invalid) }
            }
        }
        return .success(d)
    }
}

/// Small cost-limited LRU. No UI objects, disk files, credentials or source fetches.
/// Lock protects both LRU and generation: a concurrent parse cannot repopulate
/// the cache after a user clears it. Incomplete streaming prefixes are not cached.
final class ZeVisualizationCache: @unchecked Sendable {
    static let shared = ZeVisualizationCache()
    private let lock = NSLock()
    private var entries: [String: (Result<ZeVisualizationDocument, ZeVisualizationError>, Int)] = [:]
    private var order: [String] = []
    private var cost = 0
    private var generation = 0
    let countLimit = 24
    let costLimit = 2 * 1024 * 1024
    var statistics: (count: Int, cost: Int) { lock.lock(); defer { lock.unlock() }; return (order.count, cost) }
    func clear() { lock.lock(); defer { lock.unlock() }; entries.removeAll(); order.removeAll(); cost = 0; generation &+= 1 }
    func parse(_ raw: String) -> Result<ZeVisualizationDocument, ZeVisualizationError> {
        guard raw.utf8.count <= ZeVisualizationParser.maxBytes else { return .failure(.limit) }
        lock.lock()
        if let hit = entries[raw] { order.removeAll { $0 == raw }; order.append(raw); lock.unlock(); return hit.0 }
        let before = generation
        lock.unlock()
        let result = ZeVisualizationParser.parse(raw)
        if case .failure(.incomplete) = result { return result }
        let estimatedCost = raw.utf8.count * 6 + 1024
        lock.lock(); defer { lock.unlock() }
        guard before == generation, entries[raw] == nil, estimatedCost <= costLimit else { return result }
        while !order.isEmpty && (order.count >= countLimit || cost + estimatedCost > costLimit) {
            let key = order.removeFirst(); cost -= entries.removeValue(forKey: key)?.1 ?? 0
        }
        entries[raw] = (result, estimatedCost); order.append(raw); cost += estimatedCost
        return result
    }
}

enum ZeVisualizationStreaming {
    /// Recover an omitted/wrong fence only for a complete validated visualization
    /// envelope. Ordinary JSON, inline code and explicitly typed code examples are
    /// left alone. Strings/escapes are scanned, never matched with a brace regex.
    static func normalizeEnvelopes(_ markdown: String) -> String {
        guard markdown.contains("{") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var typedFence: Character?
        var typedLength = 0
        var recovered = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = trimmed.first
            let run = first.map { ch in trimmed.prefix(while: { $0 == ch }).count } ?? 0
            if let fence = typedFence {
                output.append(line); index += 1
                if first == fence, run >= typedLength, trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).isEmpty {
                    typedFence = nil
                }
                continue
            }
            let isFence = (first == "`" || first == "~") && run >= 3
            let info = isFence ? trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces).lowercased() : ""
            if isFence && info != "json" && !info.isEmpty {
                typedFence = first; typedLength = run
                output.append(line); index += 1; continue
            }
            let start = isFence ? index + 1 : index
            guard start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("{") else {
                if isFence { typedFence = first; typedLength = run }
                output.append(line); index += 1; continue
            }
            var payload: [String] = []
            var depth = 0, bytes = 0, end = start
            var quoted = false, escaped = false, complete = false, invalidTail = false
            while end < lines.count && bytes <= ZeVisualizationParser.maxBytes {
                let candidate = lines[end]
                // Stop at the generic fence even when JSON has been interrupted.
                if isFence && candidate.trimmingCharacters(in: .whitespaces).hasPrefix(String(repeating: String(first!), count: run)) { break }
                payload.append(candidate); bytes += candidate.utf8.count + 1
                for character in candidate {
                    if complete {
                        if !character.isWhitespace { invalidTail = true }
                        continue
                    }
                    if quoted {
                        if escaped { escaped = false }
                        else if character == "\\" { escaped = true }
                        else if character == "\"" { quoted = false }
                    } else if character == "\"" { quoted = true }
                    else if character == "{" || character == "[" { depth += 1 }
                    else if character == "}" || character == "]" { depth -= 1; if depth == 0 { complete = true } }
                }
                end += 1
                if complete { break }
            }
            let raw = payload.joined(separator: "\n")
            let signature = raw.prefix(512)
            let compactSignature = signature.filter { !$0.isWhitespace }
            let likelyEnvelope = signature.contains("\"schemaVersion\"")
                || "{\"schemaVersion\"".hasPrefix(compactSignature)
            var after = end
            var genericClosed = !isFence
            if isFence {
                while after < lines.count && lines[after].trimmingCharacters(in: .whitespaces).isEmpty { after += 1 }
                if after < lines.count {
                    let closing = lines[after].trimmingCharacters(in: .whitespaces)
                    let closingRun = closing.prefix(while: { $0 == first }).count
                    genericClosed = closingRun >= run && closing.dropFirst(closingRun).isEmpty
                    if genericClosed { after += 1 }
                }
            }
            if complete, !invalidTail, genericClosed, recovered < 4,
               case .success = ZeVisualizationCache.shared.parse(raw) {
                output.append("\n```ze-visualization\n" + raw + "\n```\n")
                recovered += 1; index = isFence ? after : end
            } else if likelyEnvelope, (!complete && end == lines.count || isFence && !genericClosed && (after == lines.count || after == lines.count - 1 && lines[after].allSatisfy { $0 == first || $0.isWhitespace })), bytes <= ZeVisualizationParser.maxBytes {
                // Stable placeholder until the remaining stream arrives. No
                // decoding or partial chart redraw on every arriving token.
                output.append("```ze-visualization-pending\n\n```")
                index = lines.count
            } else {
                // Consume scanned candidates once: no quadratic rescan of nested
                // JSON lines. A nonvisual generic fence remains an ordinary fence.
                if isFence { typedFence = first; typedLength = run; output.append(line) }
                if end > start { output.append(contentsOf: lines[start..<end]); index = end }
                else { if !isFence { output.append(line) }; index += 1 }
            }
        }
        return output.joined(separator: "\n")
    }

    /// Linear scan of fenced lines, preserving ordinary code examples. Replace
    /// an unfinished visualization payload before cmark sees its growing JSON.
    /// Four complete blocks per message bounds retained attachment data as well.
    static func prepare(_ markdown: String, readable: Bool = false) -> String {
        // A fence label itself arrives token by token. Do not briefly mount a
        // code card for an empty/partial visualization opening fence.
        var input = markdown
        if let tail = input.split(separator: "\n", omittingEmptySubsequences: false).last {
            let trimmed = tail.trimmingCharacters(in: .whitespaces)
            if let ch = trimmed.first, ch == "`" || ch == "~" {
                let run = trimmed.prefix(while: { $0 == ch }).count
                let info = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
                if run >= 3, !info.isEmpty, "ze-visualization".hasPrefix(info), info != "ze-visualization" {
                    input.removeLast(tail.count)
                }
            }
        }
        let markdown = normalizeEnvelopes(input)
        guard markdown.contains("ze-visualization") else { return markdown }
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var fence: Character?
        var length = 0
        var visual = false
        var payload: [String] = []
        var bytes = 0
        var count = 0
        func finish(_ closed: Bool) {
            if closed, bytes <= ZeVisualizationParser.maxBytes, count <= 4 {
                if readable {
                    switch ZeVisualizationCache.shared.parse(payload.joined(separator: "\n")) {
                    case .success(let document): output.append(document.plainText)
                    case .failure(let error): output.append(error.text)
                    }
                } else {
                    output.append("```ze-visualization")
                    output.append(contentsOf: payload)
                    output.append("```")
                }
            } else if closed {
                output.append(ZeVisualizationError.limit.text)
            } else {
                output.append(readable ? ZeVisualizationError.incomplete.text : "```ze-visualization-pending\n\n```")
            }
            payload.removeAll(keepingCapacity: false)
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let first = trimmed.first
            let run = first.map { ch in trimmed.prefix(while: { $0 == ch }).count } ?? 0
            if let current = fence {
                if first == current, run >= length, trimmed.dropFirst(run).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if visual { finish(true) } else { output.append(line) }
                    fence = nil; visual = false
                } else if visual {
                    bytes += line.utf8.count + 1
                    if bytes <= ZeVisualizationParser.maxBytes { payload.append(line) }
                } else { output.append(line) }
            } else if (first == "`" || first == "~"), run >= 3 {
                fence = first; length = run
                let info = String(trimmed.dropFirst(run)).trimmingCharacters(in: .whitespacesAndNewlines)
                visual = ZeVisualizationParser.isFence(info) || (readable && info == "ze-visualization-pending")
                if visual { count += 1; bytes = 0 } else { output.append(line) }
            } else { output.append(line) }
        }
        if visual { finish(false) }
        return output.joined(separator: "\n")
    }
}

enum ZeVisualizationPrompt {
    static let instructions = #"""
    Inline visualization selection policy: when the user asks for a chart, visualization, dashboard, interactive explanation, or a visual comparison, DEFAULT to a model-designed "custom" component in a fenced `ze-visualization` JSON block. Do not default to the legacy line/bar/pie cards or a Markdown table merely because they are easier. For substantive comparisons, trends, distributions or relationships, proactively prefer a custom visualization when it makes the answer easier to understand; do not wait for the user to name the protocol. Design the layout, chart marks, annotations, colors and useful controls for the actual question. Use one coherent composition rather than repeating identical generic cards. Implement interactions only when useful (for example selecting a series, filtering categories, changing a parameter or inspecting values). An ordinary table explicitly requested by the user, a few values for quick lookup, a text-only request, or a request to use native components should use the appropriate native table/metric/text instead. A simple factual answer does not need a chart. Never manufacture history, comparisons or interaction for decoration.
    Use only actual user/tool data, never invent current prices, historical points or sources. Use HTML/JS only in the custom component described below; never use remote data_source identifiers. Each block must be complete valid JSON, schemaVersion 1, at most 12 components, 2000 total points, 200 table rows, 12 table columns, 48 metric items, 8 series, 256 KiB; at most 4 blocks in a response. Large datasets should be summarized explicitly and original files linked. Missing values are null, not zero. Charts need real ordered distinct x values. Sources must include id,label and actual http(s) url, observedAt/retrievedAt if known; cite sourceIDs from components. All labels and explanatory text use the user's language. Earlier replies using legacy cards are not a style requirement for new replies. Output the finished interface directly; do not explain its protocol or tell the user to install software.
    IMPORTANT: A visualization is drawn by the app, not by shell/image generation tools. Never install plotting packages just to display these cards. Always include the literal opening and closing fence shown below; raw JSON or a generic json fence is not the intended output. "Inline/in the body" means this fenced block, not raw JSON text.
    For a custom design, unusual chart, interactive explanation, diagram, calculator or dashboard, use type "custom" instead of forcing it into the standard chart types. You design its complete layout and behavior with self-contained HTML/CSS/inline JavaScript/SVG/Canvas. Shape: {"id":"design","type":"custom","title":"...","height":360,"fallbackText":"Accessible text summary of actual values and conclusions","html":"<style>...</style><main>...</main><script>...</script>"}. Max 2 custom components per document, 128 KiB HTML each, height 180...600 is an initial size hint; the app measures natural content height. Keep the complete composition within 1600 CSS pixels tall at 360 CSS pixels wide. Use normal document flow and compact margins; do not use viewport heights, fixed root heights, vertically centered page shells or hidden overflow. Wrap long annotations and sources. Reserve SVG plot margins for axis labels; keep all text inside its viewBox, with the last x-axis label right-aligned. No external libraries, requests, fonts, images, navigation, iframes or permissions; the runtime is offline. Use responsive width:100%, SVG viewBox or Canvas devicePixelRatio sizing, readable labels and prefers-color-scheme. A static preview appears inline; opening it runs your controls. Use window.ZeVisualization.state to restore your JSON state before rendering; call window.ZeVisualization.setState({...}) after interactions. HTML inputs are also restored automatically. Avoid randomness, automatic animation, timers or expensive loops; repaint only on input. The current view is captured when closing and shared with the conversation. Describe the real interaction, not capabilities you did not implement. Standard native components remain useful for simple tables/metrics; custom designs are not restricted to their layouts.
    Complete custom example for user-provided values A=12, B=20 (adapt the design and data to the real request; never copy these example values as facts):
    ```ze-visualization
    {"schemaVersion":1,"id":"comparison","title":"Category comparison","components":[{"id":"design","type":"custom","title":"Inspect a category","height":280,"fallbackText":"User-provided values: A 12; B 20.","html":"<style>body{padding:16px;color:CanvasText;background:Canvas}h2{margin:0 0 12px}button{padding:8px 14px;margin-right:8px;border:1px solid #888;border-radius:8px;background:Canvas;color:CanvasText}svg{width:100%;height:150px}output{display:block;margin-top:8px}</style><h2>Category comparison</h2><button data-k='A'>A</button><button data-k='B'>B</button><svg viewBox='0 0 320 150' role='img' aria-label='A 12; B 20'><text x='0' y='40' fill='currentColor'>A</text><rect x='35' y='18' width='144' height='32' rx='6' fill='#3488ed'/><text x='190' y='40' fill='currentColor'>12</text><text x='0' y='100' fill='currentColor'>B</text><rect x='35' y='78' width='240' height='32' rx='6' fill='#269d81'/><text x='284' y='100' fill='currentColor'>20</text></svg><output id='readout'></output><script>const values={A:12,B:20};function select(k){document.getElementById('readout').textContent=k+': '+values[k];ZeVisualization.setState({selected:k});document.querySelectorAll('button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.k===k)));}document.querySelectorAll('button').forEach(b=>b.onclick=()=>select(b.dataset.k));select(ZeVisualization.state.selected==='B'?'B':'A');</script>"}]}
    ```
    Native metric example for a simple numeric lookup (not the default for a requested chart):
    ```ze-visualization
    {"schemaVersion":1,"id":"summary","title":"Budget","subtitle":"User-provided figures · USD","components":[{"id":"totals","type":"metric_grid","unit":"USD","items":[{"id":"income","label":"Income","value":3000,"precision":2},{"id":"cost","label":"Cost","value":2000,"precision":2}]}]}
    ```
    Other component shapes (same envelope):
    {"id":"trend","type":"line","title":"Trend","unit":"USD","xAxis":"numeric","series":[{"id":"a","label":"Series A","points":[{"x":1,"y":10,"label":"Day 1"},{"x":2,"y":null,"label":"Day 2"},{"x":3,"y":14,"label":"Day 3"}]}]}
    Chart type can be line,bar,area; xAxis numeric,time (Unix seconds),category (numeric category index + label). Include multiple series for comparisons. Pie/donut use type pie or donut with items like metrics, only nonnegative part-to-whole values. Info uses type info and items with id,label,text,detail. Table uses {"id":"table","type":"table","headers":["Name","Value"],"rows":[["A",10],["B",null]]}; cells are strings, numbers or null, every row matches header length. Metric items support detail and missingReason; number precision 0...6. Do not use this example data as real-world facts. Do not claim automatic refresh; stored cards are snapshots with local interactions.
    """#
}
