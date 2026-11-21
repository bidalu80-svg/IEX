import Foundation
import UniformTypeIdentifiers
import cmark_gfm
import cmark_gfm_extensions

// MARK: - Block & Inline Node types (inlined from swift-markdown-ui)

enum BlockNode: Hashable {
    case blockquote(children: [BlockNode])
    case bulletedList(isTight: Bool, items: [RawListItem])
    case numberedList(isTight: Bool, start: Int, items: [RawListItem])
    case taskList(isTight: Bool, items: [RawTaskListItem])
    case codeBlock(fenceInfo: String?, content: String)
    case htmlBlock(content: String)
    case paragraph(content: [InlineNode])
    case heading(level: Int, content: [InlineNode])
    case table(columnAlignments: [RawTableColumnAlignment], rows: [RawTableRow])
    case thematicBreak
    case mathBlock(content: String)
}

extension BlockNode {
    var children: [BlockNode] {
        switch self {
        case .blockquote(let children):
            return children
        case .bulletedList(_, let items):
            return items.map(\.children).flatMap { $0 }
        case .numberedList(_, _, let items):
            return items.map(\.children).flatMap { $0 }
        case .taskList(_, let items):
            return items.map(\.children).flatMap { $0 }
        default:
            return []
        }
    }

    var isParagraph: Bool {
        guard case .paragraph = self else { return false }
        return true
    }
}

struct RawListItem: Hashable {
    let children: [BlockNode]
    var continuesPrevious = false
}

struct RawTaskListItem: Hashable {
    let isCompleted: Bool
    let children: [BlockNode]
    var continuesPrevious = false
}

enum RawTableColumnAlignment: Character {
    case none = "\0"
    case left = "l"
    case center = "c"
    case right = "r"
}

struct RawTableRow: Hashable {
    let cells: [RawTableCell]
}

struct RawTableCell: Hashable {
    let content: [InlineNode]
}

enum InlineNode: Hashable, Sendable {
    case text(String)
    case softBreak
    case lineBreak
    case code(String)
    case html(String)
    case emphasis(children: [InlineNode])
    case strong(children: [InlineNode])
    case strikethrough(children: [InlineNode])
    case link(destination: String, children: [InlineNode])
    case image(source: String, children: [InlineNode])
    case inlineMath(String)
}

extension InlineNode {
    var children: [InlineNode] {
        get {
            switch self {
            case .emphasis(let children): return children
            case .strong(let children): return children
            case .strikethrough(let children): return children
            case .link(_, let children): return children
            case .image(_, let children): return children
            case .inlineMath: return []
            default: return []
            }
        }
        set {
            switch self {
            case .emphasis: self = .emphasis(children: newValue)
            case .strong: self = .strong(children: newValue)
            case .strikethrough: self = .strikethrough(children: newValue)
            case .link(let destination, _): self = .link(destination: destination, children: newValue)
            case .image(let source, _): self = .image(source: source, children: newValue)
            default: break
            }
        }
    }
}

struct SimpleSegmentID: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case text, image, video, audio, file, table }
    let kind: Kind
    let line: Int32
    let column: Int32
}

// MARK: - MarkdownContent (minimal replacement for MarkdownUI.MarkdownContent)

struct MarkdownContent: Hashable {
    let blocks: [BlockNode]

    init(_ markdown: String) {
        let (cleaned, mathSpans) = MarkdownMathExtractor.extract(from: ZeVisualizationStreaming.prepare(markdown))
        let parsed = [BlockNode](markdown: cleaned)
        if mathSpans.isEmpty {
            self.blocks = parsed
        } else {
            self.blocks = MarkdownMathExtractor.restore(blocks: parsed, spans: mathSpans)
        }
    }

    init(blocks: [BlockNode]) {
        self.blocks = blocks
    }
}

// MARK: - Math Extraction

/// Extracts LaTeX math from markdown before cmark parsing, then restores math nodes in the AST.
enum MarkdownMathExtractor {
    struct MathSpan {
        let placeholder: String
        let latex: String
        let isBlock: Bool
    }

    /// Extract math expressions, replacing them with placeholders.
    /// Returns the cleaned markdown and the list of extracted spans.
    static func extract(from markdown: String, recordEdits: (([MarkdownSourceEdit]) -> Void)? = nil) -> (String, [MathSpan]) {
        var spans: [MathSpan] = []
        var result = ""
        let chars = Array(markdown)
        let count = chars.count
        var i = 0
        var edits: [MarkdownSourceEdit] = []
        var offsets: [Int] = []
        func appendMath(_ latex: String, isBlock: Bool, end: Int) {
            let placeholder = "\u{FFFC}MATH\(spans.count)\u{FFFC}"
            spans.append(MathSpan(placeholder: placeholder, latex: latex, isBlock: isBlock))
            result.append(placeholder)
            if recordEdits != nil {
                if offsets.isEmpty {
                    offsets = chars.reduce(into: [0]) { offsets, character in offsets.append(offsets.last! + String(character).utf8.count) }
                }
                edits.append((offsets[i]..<offsets[end], placeholder.utf8.count))
            }
            i = end
        }

        // Track code fences and inline code to skip them
        var inFencedCode = false
        var fenceChar: Character = "`"
        var fenceLen = 0

        while i < count {
            // Check for fenced code blocks (``` or ~~~)
            if !inFencedCode && (i == 0 || chars[i - 1] == "\n" || (i > 0 && chars[i - 1] == "\r")) {
                let fc = chars[i]
                if fc == "`" || fc == "~" {
                    var fl = 0
                    var j = i
                    while j < count && chars[j] == fc { fl += 1; j += 1 }
                    if fl >= 3 {
                        inFencedCode = true
                        fenceChar = fc
                        fenceLen = fl
                        // Copy the fence line
                        while i < count && chars[i] != "\n" {
                            result.append(chars[i]); i += 1
                        }
                        if i < count { result.append(chars[i]); i += 1 } // newline
                        continue
                    }
                }
            }

            if inFencedCode {
                // Look for closing fence
                if (i == 0 || chars[i - 1] == "\n") && chars[i] == fenceChar {
                    var fl = 0
                    var j = i
                    while j < count && chars[j] == fenceChar { fl += 1; j += 1 }
                    if fl >= fenceLen {
                        inFencedCode = false
                        // Copy through the rest of the fence line
                        while i < count && chars[i] != "\n" {
                            result.append(chars[i]); i += 1
                        }
                        if i < count { result.append(chars[i]); i += 1 }
                        continue
                    }
                }
                result.append(chars[i]); i += 1
                continue
            }

            // Skip inline code spans
            if chars[i] == "`" {
                var backtickLen = 0
                var j = i
                while j < count && chars[j] == "`" { backtickLen += 1; j += 1 }
                // Find matching closing backticks
                var found = false
                var k = j
                while k <= count - backtickLen {
                    var matchLen = 0
                    while k + matchLen < count && chars[k + matchLen] == "`" { matchLen += 1 }
                    if matchLen == backtickLen {
                        // Copy everything from i through k + matchLen - 1
                        for idx in i..<(k + matchLen) {
                            result.append(chars[idx])
                        }
                        i = k + matchLen
                        found = true
                        break
                    }
                    if matchLen > 0 { k += matchLen } else { k += 1 }
                }
                if found { continue }
                // No matching close — just output the backticks
                for idx in i..<j { result.append(chars[idx]) }
                i = j
                continue
            }

            // Escaped dollar sign
            if chars[i] == "\\" && i + 1 < count && chars[i + 1] == "$" {
                result.append(chars[i]); result.append(chars[i + 1])
                i += 2
                continue
            }

            // Check for \[ ... \] (display math)
            if chars[i] == "\\" && i + 1 < count && chars[i + 1] == "[" {
                if let end = findClosingBracket(chars: chars, from: i + 2, close: "\\]") {
                    let latex = String(chars[(i + 2)..<end])
                    appendMath(latex, isBlock: true, end: end + 2)
                    continue
                }
            }

            // Check for \( ... \) (inline math)
            if chars[i] == "\\" && i + 1 < count && chars[i + 1] == "(" {
                if let end = findClosingBracket(chars: chars, from: i + 2, close: "\\)") {
                    let latex = String(chars[(i + 2)..<end])
                    appendMath(latex, isBlock: false, end: end + 2)
                    continue
                }
            }

            // Check for $$ ... $$ (display math)
            if chars[i] == "$" && i + 1 < count && chars[i + 1] == "$" {
                if let end = findDoubleDollar(chars: chars, from: i + 2) {
                    let latex = String(chars[(i + 2)..<end])
                    appendMath(latex, isBlock: true, end: end + 2)
                    continue
                }
            }

            // Check for $ ... $ (inline math)
            if chars[i] == "$" && i + 1 < count && chars[i + 1] != "$" && chars[i + 1] != " " {
                if let end = findSingleDollar(chars: chars, from: i + 1) {
                    let latex = String(chars[(i + 1)..<end])
                    // Heuristic: skip plain currency like $5, $10.
                    // [T-ios-table-cell-katex-false-positive] Also skip a span
                    // that is really a table-cell artifact: a row like
                    // `| 月付 | $20|$ **3** |` lets the `$` at `$20` pair with a
                    // later `$` and capture `20|` (a number + the column pipe)
                    // as a fake formula — rendered serif-italic with the bold
                    // `**3**` lost. See isTablePipeArtifact for the rule
                    // (whitespace-adjacent or unbalanced bars), which preserves
                    // real absolute-value formulas like $|x|$ / $\|v\|$.
                    if looksLikeMath(latex) && !isTablePipeArtifact(latex) {
                        appendMath(latex, isBlock: false, end: end + 1)
                        continue
                    }
                }
            }

            result.append(chars[i])
            i += 1
        }

        recordEdits?(edits)
        return (result, spans)
    }

    /// Restore math nodes in the parsed AST by replacing placeholder text nodes.
    static func restore(blocks: [BlockNode], spans: [MathSpan]) -> [BlockNode] {
        let placeholderMap = Dictionary(uniqueKeysWithValues: spans.map { ($0.placeholder, $0) })
        return blocks.map { restoreBlock($0, placeholderMap: placeholderMap) }
    }

    // MARK: - Private Helpers

    private static func findClosingBracket(chars: [Character], from start: Int, close: String) -> Int? {
        let closeChars = Array(close)
        var i = start
        while i <= chars.count - closeChars.count {
            var match = true
            for j in 0..<closeChars.count {
                if chars[i + j] != closeChars[j] { match = false; break }
            }
            if match { return i }
            i += 1
        }
        return nil
    }

    private static func findDoubleDollar(chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count - 1 {
            if chars[i] == "$" && chars[i + 1] == "$" { return i }
            i += 1
        }
        return nil
    }

    private static func findSingleDollar(chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count { i += 2; continue } // skip escaped
            if chars[i] == "$" && (i == 0 || chars[i - 1] != " ") { return i }
            if chars[i] == "\n" { return nil } // single-line only
            i += 1
        }
        return nil
    }

    /// Heuristic: content looks like LaTeX if it contains special chars or is long enough.
    private static func looksLikeMath(_ content: String) -> Bool {
        if content.isEmpty { return false }
        let mathChars: Set<Character> = ["\\", "^", "_", "{", "}", "∫", "∑", "∏", "√"]
        for ch in content {
            if mathChars.contains(ch) { return true }
        }
        // Length > 2 also qualifies (e.g., "x+y")
        return content.count > 2
    }

    /// [T-ios-table-cell-katex-false-positive] True when a candidate inline-math
    /// span is really a markdown table-cell artifact (a `$` that paired across
    /// `|` column separators) rather than a formula. Two signals, both of which
    /// a real formula avoids:
    ///   1. An unescaped pipe with whitespace on a side — the table column
    ///      separator is written ` | ` / `| ` / ` |`. Real LaTeX keeps pipes
    ///      flush against operands.
    ///   2. An ODD number of unescaped pipes — absolute-value / norm bars always
    ///      come in balanced pairs (`|x|`, `\frac{|a|}{|b|}`), so an odd count
    ///      (e.g. `20|`, `240|`) is a stray column separator, not math.
    /// Escaped `\|` (LaTeX norm) is never counted as a bare pipe.
    private static func isTablePipeArtifact(_ content: String) -> Bool {
        let chars = Array(content)
        var bareCount = 0
        for (idx, ch) in chars.enumerated() where ch == "|" {
            if idx > 0 && chars[idx - 1] == "\\" { continue }   // escaped norm bar
            bareCount += 1
            let prevIsSpace = idx > 0 && chars[idx - 1].isWhitespace
            let nextIsSpace = idx + 1 < chars.count && chars[idx + 1].isWhitespace
            if prevIsSpace || nextIsSpace { return true }
        }
        return bareCount % 2 == 1
    }

    private static func restoreBlock(_ block: BlockNode, placeholderMap: [String: MathSpan]) -> BlockNode {
        switch block {
        case .paragraph(let content):
            let restored = restoreInlines(content, placeholderMap: placeholderMap)
            // If paragraph contains only a single block-math placeholder, promote to mathBlock
            if restored.count == 1, case .inlineMath(let latex) = restored[0] {
                if let span = placeholderMap.values.first(where: { $0.latex == latex && $0.isBlock }) {
                    return .mathBlock(content: span.latex)
                }
            }
            // Check for mathBlock in a paragraph that has only whitespace + the math
            let nonWhitespace = restored.filter {
                switch $0 {
                case .text(let t): return !t.trimmingCharacters(in: .whitespaces).isEmpty
                case .softBreak, .lineBreak: return false
                default: return true
                }
            }
            if nonWhitespace.count == 1, case .inlineMath(let latex) = nonWhitespace[0] {
                if let span = placeholderMap.values.first(where: { $0.latex == latex && $0.isBlock }) {
                    return .mathBlock(content: span.latex)
                }
            }
            return .paragraph(content: restored)
        case .heading(let level, let content):
            return .heading(level: level, content: restoreInlines(content, placeholderMap: placeholderMap))
        case .blockquote(let children):
            return .blockquote(children: children.map { restoreBlock($0, placeholderMap: placeholderMap) })
        case .bulletedList(let isTight, let items):
            return .bulletedList(isTight: isTight, items: items.map {
                RawListItem(children: $0.children.map { restoreBlock($0, placeholderMap: placeholderMap) }, continuesPrevious: $0.continuesPrevious)
            })
        case .numberedList(let isTight, let start, let items):
            return .numberedList(isTight: isTight, start: start, items: items.map {
                RawListItem(children: $0.children.map { restoreBlock($0, placeholderMap: placeholderMap) }, continuesPrevious: $0.continuesPrevious)
            })
        case .taskList(let isTight, let items):
            return .taskList(isTight: isTight, items: items.map {
                RawTaskListItem(isCompleted: $0.isCompleted, children: $0.children.map { restoreBlock($0, placeholderMap: placeholderMap) }, continuesPrevious: $0.continuesPrevious)
            })
        case .table(let alignments, let rows):
            return .table(columnAlignments: alignments, rows: rows.map { row in
                RawTableRow(cells: row.cells.map { cell in
                    RawTableCell(content: restoreInlines(cell.content, placeholderMap: placeholderMap))
                })
            })
        default:
            return block
        }
    }

    private static func restoreInlines(_ inlines: [InlineNode], placeholderMap: [String: MathSpan]) -> [InlineNode] {
        inlines.flatMap { restoreInline($0, placeholderMap: placeholderMap) }
    }

    private static func restoreInline(_ node: InlineNode, placeholderMap: [String: MathSpan]) -> [InlineNode] {
        switch node {
        case .text(let text):
            return splitTextWithPlaceholders(text, placeholderMap: placeholderMap)
        case .emphasis(let children):
            return [.emphasis(children: children.flatMap { restoreInline($0, placeholderMap: placeholderMap) })]
        case .strong(let children):
            return [.strong(children: children.flatMap { restoreInline($0, placeholderMap: placeholderMap) })]
        case .strikethrough(let children):
            return [.strikethrough(children: children.flatMap { restoreInline($0, placeholderMap: placeholderMap) })]
        case .link(let dest, let children):
            return [.link(destination: dest, children: children.flatMap { restoreInline($0, placeholderMap: placeholderMap) })]
        case .image(let src, let children):
            return [.image(source: src, children: children.flatMap { restoreInline($0, placeholderMap: placeholderMap) })]
        default:
            return [node]
        }
    }

    private static func splitTextWithPlaceholders(_ text: String, placeholderMap: [String: MathSpan]) -> [InlineNode] {
        var result: [InlineNode] = []
        var remaining = text

        while !remaining.isEmpty {
            // Find the next placeholder
            var earliest: (range: Range<String.Index>, span: MathSpan)?
            for (placeholder, span) in placeholderMap {
                if let range = remaining.range(of: placeholder) {
                    if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                        earliest = (range, span)
                    }
                }
            }

            guard let match = earliest else {
                result.append(.text(remaining))
                break
            }

            // Text before the placeholder
            let before = String(remaining[remaining.startIndex..<match.range.lowerBound])
            if !before.isEmpty {
                result.append(.text(before))
            }

            // The math node
            result.append(.inlineMath(match.span.latex))

            remaining = String(remaining[match.range.upperBound...])
        }

        return result
    }
}

// MARK: - cmark parsing glue

struct SimpleBodySegment: Hashable {
    struct Media: Hashable {
        let source: String
        let alt: [InlineNode]
        let linkDestination: String?
        var url: URL? { URL(string: source) }
        var name: String {
            guard let name = url?.lastPathComponent, !name.isEmpty else { return source }
            return name
        }

        var galleryTitle: String {
            Self.galleryTitle(alt: ChatSearchMarkdownText.inlineText(alt), source: source)
        }

        fileprivate static func galleryTitle(alt: String, source: String) -> String {
            alt.isEmpty ? (source as NSString).lastPathComponent : alt
        }

        var kind: SimpleSegmentID.Kind {
            let ext = url?.pathExtension.lowercased() ?? ""
            if zeVideoExtensions.contains(ext) { return .video }
            if zeAudioExtensions.contains(ext) { return .audio }
            guard !ext.isEmpty, !zeImageExtensions.contains(ext),
                  let type = UTType(filenameExtension: ext), !type.isDynamic else { return .image }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            return .file
        }

        var markdown: String {
            let caption = ChatSearchMarkdownText.inlineText(alt)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            let image = "![\(caption)](\(Self.destination(source)))"
            return linkDestination.map { "[\(image)](\(Self.destination($0)))" } ?? image
        }

        private static func destination(_ value: String) -> String {
            value.isEmpty ? "" : "<" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ">", with: "\\>") + ">"
        }
    }

    let id: SimpleSegmentID
    let blocks: [BlockNode]
    let media: Media?

    private struct SourceSpan {
        let startLine: Int32
        let startColumn: Int32
        let endLine: Int32
        let endColumn: Int32
        let cutsInlineWrapper: Bool

        init(_ node: UnsafeNode, cutsInlineWrapper: Bool = false) {
            startLine = cmark_node_get_start_line(node)
            startColumn = cmark_node_get_start_column(node)
            endLine = cmark_node_get_end_line(node)
            endColumn = cmark_node_get_end_column(node)
            self.cutsInlineWrapper = cutsInlineWrapper
        }
    }

    private struct SourceText {
        let bytes: [UInt8]
        let lineStarts: [Int]

        init(_ original: String) {
            let bytes = Array(original.utf8)
            var lineStarts = [0]
            for offset in bytes.indices where bytes[offset] == 10 || (bytes[offset] == 13 && (offset + 1 == bytes.count || bytes[offset + 1] != 10)) {
                lineStarts.append(offset + 1)
            }
            self.bytes = bytes
            self.lineStarts = lineStarts
        }

        func offset(_ line: Int32, _ column: Int32) -> Int? {
            let row = Int(line) - 1
            guard lineStarts.indices.contains(row), column >= 0 else { return nil }
            let offset = lineStarts[row] + Int(column)
            let limit = row + 1 < lineStarts.count ? lineStarts[row + 1] : bytes.count
            return offset <= limit ? offset : nil
        }

        func slice(_ start: Int, _ end: Int) -> String? {
            guard 0 <= start, start < end, end <= bytes.count else { return nil }
            return String(bytes: bytes[start..<end], encoding: .utf8)
        }
    }

    private struct OriginalSource {
        let raw: SourceText
        let prepared: SourceText
        let edits: [[MarkdownSourceEdit]]

        func offset(_ line: Int32, _ column: Int32, isStart: Bool) -> Int? {
            guard var offset = prepared.offset(line, column) else { return nil }
            for stage in edits.reversed() {
                var shift = 0
                for edit in stage {
                    let start = edit.range.lowerBound + shift
                    if offset < start || (offset == start && (edit.replacementLength != 0 || !isStart)) { break }
                    guard offset >= start + edit.replacementLength else { return nil }
                    shift += edit.replacementLength - edit.range.count
                }
                offset -= shift
            }
            return offset
        }
    }

    private enum Piece<Node> {
        case content(Node)
        case standalone(SimpleBodySegment, SourceSpan)

        static func group<Wrapped>(_ pieces: [Self], wrap: ([Node]) -> Wrapped) -> [Piece<Wrapped>] {
            var output: [Piece<Wrapped>] = []
            var pending: [Node] = []
            func flush() {
                if !pending.isEmpty { output.append(.content(wrap(pending))); pending.removeAll() }
            }
            for piece in pieces {
                switch piece {
                case .content(let node): pending.append(node)
                case .standalone(let segment, let span): flush(); output.append(.standalone(segment, span))
                }
            }
            flush()
            return output
        }
    }

    private static func prepareSource(_ markdown: String, finalised: Bool, recordEdits: (([MarkdownSourceEdit]) -> Void)? = nil)
        -> (markdown: String, math: [MarkdownMathExtractor.MathSpan], plainSuffix: String, prefixEndsWithBlankLine: Bool) {
        let split = finalised ? (prefix: markdown, plainSuffix: "") : splitStreamingTableTail(markdown)
        let formatted = prepareMarkdownForRender(split.prefix, recordEdits: recordEdits)
        let prepared = ZeVisualizationStreaming.prepare(formatted, recordEdits: recordEdits)
        let (cleaned, spans) = MarkdownMathExtractor.extract(from: prepared, recordEdits: recordEdits)
        return (cleaned, spans, split.plainSuffix, !split.plainSuffix.isEmpty && split.prefix.hasSuffix("\n\n"))
    }

    static func parse(_ markdown: String, finalised: Bool) -> [Self] {
        let prepared = prepareSource(markdown, finalised: finalised)
        let pieces = UnsafeNode.parseMarkdown(prepared.markdown) { $0.children.flatMap(blockPieces) } ?? []
        var output: [Self] = []
        var pending: [BlockNode] = []
        var textID = SimpleSegmentID(kind: .text, line: 0, column: 0)
        func flush() {
            let blocks = MarkdownMathExtractor.restore(blocks: pending, spans: prepared.math)
            if blocks.contains(where: visible) { output.append(.init(id: textID, blocks: blocks, media: nil)) }
            pending.removeAll()
        }
        for piece in pieces {
            switch piece {
            case .content(let block): pending.append(block)
            case .standalone(let segment, _):
                flush()
                output.append(.init(id: segment.id, blocks: MarkdownMathExtractor.restore(blocks: segment.blocks, spans: prepared.math), media: segment.media))
                textID = .init(kind: .text, line: segment.id.line, column: segment.id.column)
            }
        }
        if !prepared.plainSuffix.isEmpty,
           !pending.isEmpty || output.last?.id.kind != .table || prepared.prefixEndsWithBlankLine {
            pending.append(.paragraph(content: [.text(prepared.plainSuffix)]))
        }
        flush()
        return output
    }

    private static func originalStandalones(in original: String, segments: [Self], finalised: Bool)
        -> (spans: [SimpleSegmentID: SourceSpan], source: OriginalSource)? {
        let standalone = segments.filter { $0.id.kind != .text }
        guard !standalone.isEmpty else { return nil }
        var edits: [[MarkdownSourceEdit]] = []
        let prepared = prepareSource(original, finalised: finalised) { stage in
            if !stage.isEmpty { edits.append(stage) }
        }
        let pieces = UnsafeNode.parseMarkdown(prepared.markdown) { $0.children.flatMap(blockPieces) } ?? []
        let raw = pieces.compactMap { piece -> (segment: Self, span: SourceSpan)? in
            guard case .standalone(let segment, let span) = piece else { return nil }
            return (segment, span)
        }
        let byPosition = Dictionary(grouping: raw, by: { $0.segment.id })
        var spans: [SimpleSegmentID: SourceSpan] = [:]
        for segment in standalone {
            guard let candidates = byPosition[segment.id], candidates.count == 1, let candidate = candidates.first,
                  candidate.segment.media == segment.media else { continue }
            spans[segment.id] = candidate.span
        }
        return (spans, OriginalSource(raw: SourceText(original), prepared: SourceText(prepared.markdown), edits: edits))
    }

    private static let galleryImagePattern = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

    static func imageGalleryTitles(in original: String, segments: [Self], finalised: Bool = true) -> [SimpleSegmentID: String] {
        guard let (spans, source) = originalStandalones(in: original, segments: segments, finalised: finalised) else { return [:] }
        var titles: [SimpleSegmentID: String] = [:]
        for (id, span) in spans where id.kind == .image {
            guard let start = source.offset(id.line, id.column - 1, isStart: true),
                  let end = source.offset(span.endLine, span.endColumn, isStart: false),
                  let slice = source.raw.slice(start, end) else { continue }
            let content = slice as NSString
            let range = NSRange(location: 0, length: content.length)
            guard let match = galleryImagePattern?.firstMatch(in: slice, options: .anchored, range: range) else { continue }
            let alt = content.substring(with: match.range(at: 1))
            let src = content.substring(with: match.range(at: 2))
            titles[id] = Media.galleryTitle(alt: alt, source: src)
        }
        return titles
    }

    func markdownForCopy(in original: String, segments: [Self], finalised: Bool = true) -> String {
        let fallback = media?.markdown ?? original
        guard let index = segments.firstIndex(of: self),
              let (spans, source) = Self.originalStandalones(in: original, segments: segments, finalised: finalised) else { return fallback }
        if id.kind != .text {
            guard let span = spans[id] else { return fallback }
            guard let start = source.offset(span.startLine, span.startColumn - 1, isStart: true),
                  let end = source.offset(span.endLine, span.endColumn, isStart: false) else { return fallback }
            return source.raw.slice(start, end) ?? fallback
        }
        let preceding = segments[..<index].last(where: { $0.id.kind != .text })
        let following = segments[(index + 1)...].first(where: { $0.id.kind != .text })
        if preceding == nil, following == nil { return original }
        let prior = preceding.flatMap { spans[$0.id] }
        let next = following.flatMap { spans[$0.id] }
        let start = prior.flatMap { source.offset($0.endLine, $0.endColumn, isStart: false) }
        let end = next.flatMap { source.offset($0.startLine, $0.startColumn - 1, isStart: true) }
        guard preceding == nil || start != nil, following == nil || end != nil,
              let slice = source.raw.slice(start ?? 0, end ?? source.raw.bytes.count) else { return fallback }
        if prior?.cutsInlineWrapper == true || next?.cutsInlineWrapper == true {
            return slice
        }
        return slice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func position(_ node: UnsafeNode, kind: SimpleSegmentID.Kind) -> SimpleSegmentID {
        .init(kind: kind, line: cmark_node_get_start_line(node), column: cmark_node_get_start_column(node))
    }

    private static func inlinePieces(_ node: UnsafeNode) -> [Piece<InlineNode>] {
        inlinePieces(node, link: nil, linkedImage: nil, insideWrapper: false)
    }

    private static func inlinePieces(_ node: UnsafeNode, link: String?, linkedImage: UnsafeNode?, insideWrapper: Bool) -> [Piece<InlineNode>] {
        guard let inline = InlineNode(unsafeNode: node) else { return [] }
        if case .image(let source, let alt) = inline {
            let media = Media(source: source, alt: alt, linkDestination: link)
            let span = SourceSpan(linkedImage ?? node, cutsInlineWrapper: insideWrapper)
            return [.standalone(.init(id: position(node, kind: media.kind), blocks: [], media: media), span)]
        }
        switch inline {
        case .emphasis, .strong, .strikethrough, .link:
            var destination = link
            var enclosingImage = linkedImage
            if case .link(let target, let children) = inline {
                destination = target
                if children.count == 1, case .image? = children.first { enclosingImage = node }
            }
            let splitsWrapper = insideWrapper || enclosingImage == nil
            return Piece.group(node.children.flatMap { inlinePieces($0, link: destination, linkedImage: enclosingImage, insideWrapper: splitsWrapper) }) { children in
                var wrapper = inline
                wrapper.children = children
                return wrapper
            }
        default: return [.content(inline)]
        }
    }

    private static func blockPieces(_ node: UnsafeNode) -> [Piece<BlockNode>] {
        switch node.nodeType {
        case .paragraph, .heading:
            return Piece.group(node.children.flatMap(inlinePieces)) { children in
                node.nodeType == .heading ? .heading(level: node.headingLevel, content: children) : .paragraph(content: children)
            }
        case .blockquote:
            return Piece.group(node.children.flatMap(blockPieces)) { .blockquote(children: $0) }
        case .list:
            let items = node.children.enumerated().flatMap { index, item in
                var emittedMarker = false
                return Piece.group(item.children.flatMap(blockPieces)) { children in
                    let continuation = emittedMarker
                    if children.contains(where: visible) { emittedMarker = true }
                    return (index, item.isTaskListItem && item.isTaskListItemChecked, children, continuation)
                }
            }
            let isTask = node.children.contains(where: \.isTaskListItem)
            return Piece.group(items) { children in
                if isTask {
                    return .taskList(isTight: node.isTightList, items: children.map { .init(isCompleted: $0.1, children: $0.2, continuesPrevious: $0.3) })
                }
                let items = children.map { RawListItem(children: $0.2, continuesPrevious: $0.3) }
                if node.listType == CMARK_ORDERED_LIST {
                    return .numberedList(isTight: node.isTightList, start: node.listStart + (children.first?.0 ?? 0), items: items)
                }
                return .bulletedList(isTight: node.isTightList, items: items)
            }
        case .table:
            guard let table = BlockNode(unsafeNode: node) else { return [] }
            return [.standalone(.init(id: position(node, kind: .table), blocks: [table], media: nil), SourceSpan(node))]
        default:
            return BlockNode(unsafeNode: node).map { [.content($0)] } ?? []
        }
    }

    private static func visible(_ block: BlockNode) -> Bool {
        switch block {
        case .paragraph(let content), .heading(_, let content):
            return content.contains(where: visible)
        case .blockquote, .bulletedList, .numberedList, .taskList:
            return block.children.contains(where: visible)
        default: return true
        }
    }

    private static func visible(_ node: InlineNode) -> Bool {
        switch node {
        case .text(let value):
            return value.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value != 0x200B }
        case .softBreak, .lineBreak: return false
        case .emphasis, .strong, .strikethrough, .link: return node.children.contains(where: visible)
        default: return true
        }
    }
}

extension Array where Element == BlockNode {
    init(markdown: String) {
        let blocks = UnsafeNode.parseMarkdown(markdown) { document in
            document.children.compactMap(BlockNode.init(unsafeNode:))
        }
        self.init(blocks ?? .init())
    }
}

extension BlockNode {
    fileprivate init?(unsafeNode: UnsafeNode) {
        switch unsafeNode.nodeType {
        case .blockquote:
            self = .blockquote(children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:)))
        case .list:
            if unsafeNode.children.contains(where: \.isTaskListItem) {
                self = .taskList(
                    isTight: unsafeNode.isTightList,
                    items: unsafeNode.children.map(RawTaskListItem.init(unsafeNode:))
                )
            } else {
                switch unsafeNode.listType {
                case CMARK_BULLET_LIST:
                    self = .bulletedList(
                        isTight: unsafeNode.isTightList,
                        items: unsafeNode.children.map(RawListItem.init(unsafeNode:))
                    )
                case CMARK_ORDERED_LIST:
                    self = .numberedList(
                        isTight: unsafeNode.isTightList,
                        start: unsafeNode.listStart,
                        items: unsafeNode.children.map(RawListItem.init(unsafeNode:))
                    )
                default:
                    fatalError("cmark reported a list node without a list type.")
                }
            }
        case .codeBlock:
            let info = unsafeNode.fenceInfo
            let content = unsafeNode.literal ?? ""
            if ZeVisualizationParser.isFence(info) { _ = ZeVisualizationCache.shared.parse(content) }
            self = .codeBlock(fenceInfo: info, content: content)
        case .htmlBlock:
            self = .htmlBlock(content: unsafeNode.literal ?? "")
        case .paragraph:
            self = .paragraph(content: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
        case .heading:
            self = .heading(
                level: unsafeNode.headingLevel,
                content: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:))
            )
        case .table:
            self = .table(
                columnAlignments: unsafeNode.tableAlignments,
                rows: unsafeNode.children.map(RawTableRow.init(unsafeNode:))
            )
        case .thematicBreak:
            self = .thematicBreak
        default:
            assertionFailure("Unhandled node type '\(unsafeNode.nodeType)' in BlockNode.")
            return nil
        }
    }
}

extension RawListItem {
    fileprivate init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .item else {
            fatalError("Expected a list item but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:)))
    }
}

extension RawTaskListItem {
    fileprivate init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .taskListItem || unsafeNode.nodeType == .item else {
            fatalError("Expected a list item but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(
            isCompleted: unsafeNode.isTaskListItemChecked,
            children: unsafeNode.children.compactMap(BlockNode.init(unsafeNode:))
        )
    }
}

extension RawTableRow {
    fileprivate init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .tableRow || unsafeNode.nodeType == .tableHead else {
            fatalError("Expected a table row but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(cells: unsafeNode.children.map(RawTableCell.init(unsafeNode:)))
    }
}

extension RawTableCell {
    fileprivate init(unsafeNode: UnsafeNode) {
        guard unsafeNode.nodeType == .tableCell else {
            fatalError("Expected a table cell but got a '\(unsafeNode.nodeType)' instead.")
        }
        self.init(content: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
    }
}

extension InlineNode {
    fileprivate init?(unsafeNode: UnsafeNode) {
        switch unsafeNode.nodeType {
        case .text: self = .text(unsafeNode.literal ?? "")
        case .softBreak: self = .softBreak
        case .lineBreak: self = .lineBreak
        case .code: self = .code(unsafeNode.literal ?? "")
        case .html: self = .html(unsafeNode.literal ?? "")
        case .emphasis:
            self = .emphasis(children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
        case .strong:
            self = .strong(children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
        case .strikethrough:
            self = .strikethrough(children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:)))
        case .link:
            self = .link(
                destination: unsafeNode.url ?? "",
                children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:))
            )
        case .image:
            self = .image(
                source: unsafeNode.url ?? "",
                children: unsafeNode.children.compactMap(InlineNode.init(unsafeNode:))
            )
        default:
            assertionFailure("Unhandled node type '\(unsafeNode.nodeType)' in InlineNode.")
            return nil
        }
    }
}

// MARK: - UnsafeNode helpers

private typealias UnsafeNode = UnsafeMutablePointer<cmark_node>

extension UnsafeNode {
    fileprivate var nodeType: NodeType {
        let typeString = String(cString: cmark_node_get_type_string(self))
        guard let nodeType = NodeType(rawValue: typeString) else {
            fatalError("Unknown node type '\(typeString)' found.")
        }
        return nodeType
    }

    fileprivate var children: UnsafeNodeSequence {
        .init(cmark_node_first_child(self))
    }

    fileprivate var literal: String? {
        cmark_node_get_literal(self).map(String.init(cString:))
    }

    fileprivate var url: String? {
        cmark_node_get_url(self).map(String.init(cString:))
    }

    fileprivate var isTaskListItem: Bool {
        self.nodeType == .taskListItem
    }

    fileprivate var listType: cmark_list_type {
        cmark_node_get_list_type(self)
    }

    fileprivate var listStart: Int {
        Int(cmark_node_get_list_start(self))
    }

    fileprivate var isTaskListItemChecked: Bool {
        cmark_gfm_extensions_get_tasklist_item_checked(self)
    }

    fileprivate var isTightList: Bool {
        cmark_node_get_list_tight(self) != 0
    }

    fileprivate var fenceInfo: String? {
        cmark_node_get_fence_info(self).map(String.init(cString:))
    }

    fileprivate var headingLevel: Int {
        Int(cmark_node_get_heading_level(self))
    }

    fileprivate var tableColumns: Int {
        Int(cmark_gfm_extensions_get_table_columns(self))
    }

    fileprivate var tableAlignments: [RawTableColumnAlignment] {
        (0..<self.tableColumns).map { column in
            let ascii = cmark_gfm_extensions_get_table_alignments(self)[column]
            let scalar = UnicodeScalar(ascii)
            let character = Character(scalar)
            return .init(rawValue: character) ?? .none
        }
    }

    fileprivate static func parseMarkdown<ResultType>(
        _ markdown: String,
        body: (UnsafeNode) throws -> ResultType
    ) rethrows -> ResultType? {
        cmark_gfm_core_extensions_ensure_registered()

        // [T-strikethrough-syntax] Require a DOUBLE tilde for strikethrough.
        // cmark-gfm's strikethrough extension accepts a SINGLE `~` as a
        // delimiter by default, so prose using `~` as a range separator
        // (e.g. "msg 41797~42810", "6月14日~6月16日") was incorrectly struck
        // through. CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE makes only `~~text~~`
        // trigger strikethrough; a lone `~` stays literal — matching GFM.
        let parser = cmark_parser_new(CMARK_OPT_DEFAULT | CMARK_OPT_STRIKETHROUGH_DOUBLE_TILDE)
        defer { cmark_parser_free(parser) }

        let extensionNames: Set<String>

        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]
        } else {
            extensionNames = ["autolink", "strikethrough", "tagfilter", "tasklist"]
        }

        for extensionName in extensionNames {
            guard let syntaxExtension = cmark_find_syntax_extension(extensionName) else {
                continue
            }
            cmark_parser_attach_syntax_extension(parser, syntaxExtension)
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)

        guard let document = cmark_parser_finish(parser) else {
            return nil
        }

        defer { cmark_node_free(document) }
        return try body(document)
    }
}

// MARK: - NodeType enum

private enum NodeType: String {
    case document
    case blockquote = "block_quote"
    case list
    case item
    case codeBlock = "code_block"
    case htmlBlock = "html_block"
    case customBlock = "custom_block"
    case paragraph
    case heading
    case thematicBreak = "thematic_break"
    case text
    case softBreak = "softbreak"
    case lineBreak = "linebreak"
    case code
    case html = "html_inline"
    case customInline = "custom_inline"
    case emphasis = "emph"
    case strong
    case link
    case image
    case inlineAttributes = "attribute"
    case none = "NONE"
    case unknown = "<unknown>"

    // Extensions
    case strikethrough
    case table
    case tableHead = "table_header"
    case tableRow = "table_row"
    case tableCell = "table_cell"
    case taskListItem = "tasklist"
}

// MARK: - UnsafeNodeSequence

private struct UnsafeNodeSequence: Sequence {
    struct Iterator: IteratorProtocol {
        private var node: UnsafeNode?

        init(_ node: UnsafeNode?) {
            self.node = node
        }

        mutating func next() -> UnsafeNode? {
            guard let node else { return nil }
            defer { self.node = cmark_node_next(node) }
            return node
        }
    }

    private let node: UnsafeNode?

    init(_ node: UnsafeNode?) {
        self.node = node
    }

    func makeIterator() -> Iterator {
        .init(self.node)
    }
}
