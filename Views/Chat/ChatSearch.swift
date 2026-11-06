// Search presentation and matching adapted from pinned iOS source 1a71df0f381cefde80bf912b723de6f9831bc177.
// Source attribution: docs/third-party/card-source-attribution.md
import Foundation
import SwiftUI
import UIKit
import Combine

// BEGIN chat-search-engine

/// Which visible piece of a message a search unit is. One message can show
/// several separately drawn texts (a user bubble and its file tiles, a sub
/// agent card's title and status line), and each is its own unit so the
/// highlighter can find the occurrence inside the Text that draws it.
enum ChatSearchField: Hashable {
    /// The main text: user bubble, assistant text block, tool capsule line,
    /// compact divider, system info row.
    case body
    /// A user file tile's name, by index into the message's attachments.
    case attachmentName(Int)
    /// A card's headline: agent callback title, sub agent card title, the
    /// "switched model" line of an info block.
    case title
    /// A card's second line: sub agent activity or status.
    case activity
    /// One line of an info block's reason list.
    case line(Int)
    /// A user_ask question, by index.
    case question(Int)
    /// A user_ask option label (question index, option index).
    case option(Int, Int)
    /// The error line in an assistant reply's footer.
    case footerError
}

struct ChatSearchUnitKey: Hashable {
    let messageId: UUID
    let blockId: UUID?
    let field: ChatSearchField
}

/// One piece of visible text, in display order.
struct ChatSearchUnit {
    let key: ChatSearchUnitKey
    let text: String
}

/// One occurrence of the query: the `ordinal`-th (0-based) non-overlapping
/// occurrence inside the unit's text.
struct ChatSearchMatch: Hashable {
    let key: ChatSearchUnitKey
    let ordinal: Int
}

enum ChatSearchMatcher {
    /// Case and diacritic insensitive: "cafe" finds "Caf茅".
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The query as searched: surrounding whitespace dropped, inner spaces
    /// kept. The whole string is ONE substring - "apple pie" does not find
    /// "apple" alone (unlike the home screen's keyword OR search).
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Non-overlapping occurrences of `query` in `text`, first to last, at
    /// most `limit`. Empty for an empty query.
    static func ranges(of query: String, in text: String, limit: Int = .max) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex,
              let r = text.range(of: query, options: compareOptions, range: from..<text.endIndex) {
            // A match never has zero length for a non-empty query, but guard
            // against an infinite loop on any surprising normalisation.
            guard !r.isEmpty else { break }
            out.append(r)
            if out.count >= limit { break }
            from = r.upperBound
        }
        return out
    }

    /// Same as `ranges`, as UTF-16 ranges (what TextKit and NSString use).
    static func nsRanges(of query: String, in text: String, limit: Int = .max) -> [NSRange] {
        ranges(of: query, in: text, limit: limit).map { NSRange($0, in: text) }
    }

    /// Number of occurrences, capped at `limit`.
    static func count(of query: String, in text: String, limit: Int) -> Int {
        ranges(of: query, in: text, limit: limit).count
    }
}

struct ChatSearchResult: Equatable {
    /// Every match in display order (unit order, then ordinal).
    let matches: [ChatSearchMatch]
    /// Matches per unit, for the highlighter.
    let countByUnit: [ChatSearchUnitKey: Int]
    /// True when the total limit cut the list short ("2000+").
    let truncated: Bool

    static let empty = ChatSearchResult(matches: [], countByUnit: [:], truncated: false)
}

enum ChatSearchEngine {
    /// Highlights drawn in one unit; also the matches counted for it.
    static let perUnitLimit = 200
    /// Matches kept for the whole chat; the count then reads "2000+".
    static let totalLimit = 2000

    /// Searches `units` (already in display order). Returns nil when
    /// `isCancelled` turns true part-way, so a stale run never publishes.
    static func search(units: [ChatSearchUnit], query rawQuery: String,
                       perUnitLimit: Int = perUnitLimit, totalLimit: Int = totalLimit,
                       isCancelled: () -> Bool = { false }) -> ChatSearchResult? {
        let query = ChatSearchMatcher.normalizedQuery(rawQuery)
        guard !query.isEmpty else { return .empty }
        var matches: [ChatSearchMatch] = []
        var countByUnit: [ChatSearchUnitKey: Int] = [:]
        var truncated = false
        for (i, unit) in units.enumerated() {
            if i % 64 == 0, isCancelled() { return nil }
            let remaining = totalLimit - matches.count
            guard remaining > 0 else {
                // Only report truncation when something was actually dropped.
                if ChatSearchMatcher.count(of: query, in: unit.text, limit: 1) > 0 {
                    truncated = true
                    break
                }
                continue
            }
            let n = ChatSearchMatcher.count(of: query, in: unit.text, limit: min(perUnitLimit, remaining + 1))
            guard n > 0 else { continue }
            let kept = min(n, remaining, perUnitLimit)
            if n > remaining { truncated = true }
            countByUnit[unit.key] = kept
            for ordinal in 0..<kept {
                matches.append(ChatSearchMatch(key: unit.key, ordinal: ordinal))
            }
        }
        return ChatSearchResult(matches: matches, countByUnit: countByUnit, truncated: truncated)
    }
}

/// Moving through the results. Index 0 is the earliest match; "next" goes
/// toward newer messages, "previous" toward older ones, both wrapping.
enum ChatSearchNavigation {
    /// Where a fresh search lands: the newest match (chat reads bottom-up).
    static func initialIndex(count: Int) -> Int? {
        count > 0 ? count - 1 : nil
    }

    /// One step from `index`. `wrapped` is true when the step went past an
    /// end and came round to the other one.
    static func step(from index: Int?, count: Int, forward: Bool) -> (index: Int, wrapped: Bool)? {
        guard count > 0 else { return nil }
        guard let index, index >= 0, index < count else {
            return (forward ? 0 : count - 1, false)
        }
        if forward {
            return index + 1 < count ? (index + 1, false) : (0, count > 1)
        }
        return index > 0 ? (index - 1, false) : (count - 1, count > 1)
    }

    /// The current match after the results were recomputed (new content
    /// streamed in): the same match if it still exists, otherwise the old
    /// index clamped to the new count.
    static func relocate(previous: ChatSearchMatch?, previousIndex: Int?,
                         in matches: [ChatSearchMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let previous, let i = matches.firstIndex(of: previous) { return i }
        guard let previousIndex else { return nil }
        return min(max(previousIndex, 0), matches.count - 1)
    }

    /// The "3/12" counter (1-based), "2000+" when truncated.
    static func counterText(index: Int?, count: Int, truncated: Bool) -> String {
        let total = truncated ? "\(count)+" : "\(count)"
        guard let index, count > 0 else { return "0/\(total)" }
        return "\(index + 1)/\(total)"
    }
}

// END chat-search-engine

// BEGIN chat-search-markdown-text

enum ChatSearchMarkdownText {
    /// Visible text of `blocks`, plus a streaming reply's not-yet-parsed tail
    /// (`splitStreamingTableTail`'s plain suffix, which the view appends to
    /// the rendered body as plain text).
    static func text(blocks: [BlockNode], plainSuffix: String = "") -> String {
        var out = ""
        appendSequence(blocks, listDepth: 0, to: &out)
        if !plainSuffix.isEmpty { appendNormalized(plainSuffix, to: &out) }
        return out
    }

    /// Characters the renderer inserts that no reader sees, and their stand-in
    /// in search text: zero-width and hair spaces (CJK emphasis fix, breakable
    /// inline code, inline code padding) vanish; a line separator (around
    /// tables, beside images) reads as a line break; the attachment character
    /// itself is replaced by the attachment's text by the caller.
    static func normalizedScalar(_ s: Unicode.Scalar) -> Unicode.Scalar?? {
        switch s.value {
        case 0x200B, 0x200A, 0xFFFC: return .some(nil)
        case 0x2028: return .some("\n")
        default: return nil
        }
    }

    /// `text` with the invisible characters above removed / mapped.
    static func appendNormalized(_ text: String, to out: inout String) {
        var scalars = String.UnicodeScalarView()
        var changed = false
        for s in text.unicodeScalars {
            if let mapped = normalizedScalar(s) {
                changed = true
                if let m = mapped { scalars.append(m) }
            } else {
                scalars.append(s)
            }
        }
        out += changed ? String(scalars) : text
    }

    static func normalized(_ text: String) -> String {
        var out = ""
        appendNormalized(text, to: &out)
        return out
    }

    /// A table's visible text: cells separated by a tab, rows by a newline.
    /// Used for the renderer's TableAttachment by both sides.
    static func tableText(rows: [RawTableRow], columnCount: Int) -> String {
        rows.map { row in
            row.cells.prefix(columnCount).map { normalized(inlineText($0.content)) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// A code block's visible text: its content without the final newline
    /// (MarkdownNSRenderer.renderCodeBlockAttachment trims it the same way).
    static func codeText(_ content: String) -> String {
        content.hasSuffix("\n") ? String(content.dropLast()) : content
    }

    /// Inline text as the renderer writes it, before normalisation.
    static func inlineText(_ inlines: [InlineNode]) -> String {
        var out = ""
        for (i, node) in inlines.enumerated() {
            switch node {
            case .text(let t): out += t
            case .code(let c): out += c
            case .emphasis(let ch), .strong(let ch), .strikethrough(let ch), .link(_, let ch):
                out += inlineText(ch)
            case .image, .inlineMath:
                // Drawn by an attachment with no text form.
                break
            case .html(let h): out += h
            case .softBreak:
                // [T-md-image-own-line] A soft break touching an image becomes
                // a line separator in the renderer.
                out += isImage(at: i - 1, in: inlines) || isImage(at: i + 1, in: inlines) ? "\n" : " "
            case .lineBreak: out += "\n"
            }
        }
        return out
    }

    private static func isImage(at index: Int, in inlines: [InlineNode]) -> Bool {
        guard inlines.indices.contains(index), case .image = inlines[index] else { return false }
        return true
    }

    private static func appendSequence(_ blocks: [BlockNode], listDepth: Int, to out: inout String) {
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += "\n" }
            appendBlock(block, listDepth: listDepth, to: &out)
        }
    }

    private static func appendBlock(_ block: BlockNode, listDepth: Int, to out: inout String) {
        switch block {
        case .paragraph(let content), .heading(_, let content):
            appendNormalized(inlineText(content), to: &out)
        case .codeBlock(_, let content):
            out += codeText(content)
        case .blockquote(let children):
            appendSequence(children, listDepth: listDepth, to: &out)
        case .bulletedList(_, let items):
            // Same glyphs by depth as renderBulletedList.
            let glyph: String
            switch listDepth {
            case 0: glyph = "\u{2022}"
            case 1: glyph = "\u{25E6}"
            default: glyph = "\u{25AA}"
            }
            for (i, item) in items.enumerated() {
                if i > 0 { out += "\n" }
                out += glyph + "  "
                appendSequence(item.children, listDepth: listDepth + 1, to: &out)
            }
        case .numberedList(_, let start, let items):
            for (i, item) in items.enumerated() {
                if i > 0 { out += "\n" }
                out += "\(start + i). "
                appendSequence(item.children, listDepth: listDepth + 1, to: &out)
            }
        case .taskList(_, let items):
            for (i, item) in items.enumerated() {
                if i > 0 { out += "\n" }
                out += item.isCompleted ? "\u{2611} " : "\u{2610} "
                appendSequence(item.children, listDepth: listDepth + 1, to: &out)
            }
        case .table(let alignments, let rows):
            // U+2028 + attachment + U+2028 in the renderer.
            out += "\n" + tableText(rows: rows, columnCount: alignments.count) + "\n"
        case .thematicBreak, .mathBlock:
            break
        case .htmlBlock(let content):
            appendNormalized(content, to: &out)
        }
    }
}

// END chat-search-markdown-text

// BEGIN chat-search-highlights
/// What one unit highlights: the first `count` occurrences of `query`, with
/// occurrence `current` (if any) drawn as the current result.
struct ChatSearchUnitHighlight: Equatable {
    let query: String
    let count: Int
    let current: Int?

    /// Occurrences to draw: the first `ChatSearchEngine.perUnitLimit`, and
    /// the current one is always among them (it is < count <= limit).
    var drawLimit: Int { min(count, ChatSearchEngine.perUnitLimit) }
}

/// One unit's highlight, observed by the view that draws that unit.
@MainActor
final class ChatSearchHighlightToken: ObservableObject {
    @Published fileprivate(set) var state: ChatSearchUnitHighlight?
    init(state: ChatSearchUnitHighlight?) { self.state = state }
}

@MainActor
final class ChatSearchHighlightCenter {
    /// Opens the chat's search bar with an optional query. Set by the chat
    /// page while it shows this conversation (nil in lists with no search
    /// bar, such as a sub agent's transcript), so the long-press menus can
    /// offer "Search in Chat" without a callback threaded through every cell.
    var openSearch: ((String?) -> Void)?
    /// Which chat page installed `openSearch`, so a page going away cannot
    /// clear the opener a newer page for the same conversation installed.
    var openSearchOwner: UUID?

    private var tokens: [ChatSearchUnitKey: ChatSearchHighlightToken] = [:]
    private var states: [ChatSearchUnitKey: ChatSearchUnitHighlight] = [:]

    /// The token for `key`, created on first use with the current state.
    /// Tokens live as long as the center (one per chat view model), so a view
    /// that keeps its token across cell reuse still receives later updates.
    func token(for key: ChatSearchUnitKey) -> ChatSearchHighlightToken {
        if let t = tokens[key] { return t }
        let t = ChatSearchHighlightToken(state: states[key])
        tokens[key] = t
        return t
    }

    func state(for key: ChatSearchUnitKey) -> ChatSearchUnitHighlight? { states[key] }

    /// A new result set. Only units whose state actually changed publish.
    func apply(result: ChatSearchResult, query: String, current: ChatSearchMatch?) {
        var next: [ChatSearchUnitKey: ChatSearchUnitHighlight] = [:]
        next.reserveCapacity(result.countByUnit.count)
        for (key, count) in result.countByUnit {
            next[key] = ChatSearchUnitHighlight(query: query, count: count,
                                                current: current?.key == key ? current?.ordinal : nil)
        }
        let changed = Set(next.keys).union(states.keys).filter { next[$0] != states[$0] }
        states = next
        for key in changed { tokens[key]?.state = next[key] }
    }

    /// Moves the current mark: touches at most the two units involved.
    func setCurrent(from old: ChatSearchMatch?, to new: ChatSearchMatch?) {
        var keys: [ChatSearchUnitKey] = []
        if let old { keys.append(old.key) }
        if let new, new.key != old?.key { keys.append(new.key) }
        for key in keys {
            guard let s = states[key] else { continue }
            let current = new?.key == key ? new?.ordinal : nil
            let updated = ChatSearchUnitHighlight(query: s.query, count: s.count, current: current)
            guard updated != s else { continue }
            states[key] = updated
            tokens[key]?.state = updated
        }
    }

    /// Search closed: every highlight goes away.
    func clear() {
        let keys = Array(states.keys)
        states.removeAll()
        for key in keys { tokens[key]?.state = nil }
    }
}

// MARK: - Environment

private struct ChatSearchHighlightsKey: EnvironmentKey {
    static let defaultValue: ChatSearchHighlightCenter? = nil
}

private struct ChatSearchDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ChatSearchMessageIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The chat's highlight center; nil outside the message list.
    var chatSearchHighlights: ChatSearchHighlightCenter? {
        get { self[ChatSearchHighlightsKey.self] }
        set { self[ChatSearchHighlightsKey.self] = newValue }
    }

    /// The row is drawn at reduced opacity (compacted history): highlights
    /// use stronger colours so they still read through the fade.
    var chatSearchDimmed: Bool {
        get { self[ChatSearchDimmedKey.self] }
        set { self[ChatSearchDimmedKey.self] = newValue }
    }

    /// The message a block view belongs to, for views that only hold the
    /// block (tool capsule, sub agent card, user_ask card).
    var chatSearchMessageId: UUID? {
        get { self[ChatSearchMessageIdKey.self] }
        set { self[ChatSearchMessageIdKey.self] = newValue }
    }
}

// MARK: - Colours

enum ChatSearchHighlightStyle {
    /// Every match: a highlighter-pen yellow.
    static func matchColor(dimmed: Bool) -> UIColor {
        UIColor.systemYellow.withAlphaComponent(dimmed ? 0.9 : 0.45)
    }

    /// The current match: orange, clearly stronger than the others.
    static func currentColor(dimmed: Bool) -> UIColor {
        UIColor.systemOrange.withAlphaComponent(dimmed ? 1 : 0.85)
    }
}

// MARK: - SwiftUI text with highlights

/// Drop-in for `Text(text)` on a searchable row. Outside the message list (no
/// highlight center) it IS `Text(text)`. Font, colour and line limits applied
/// to it reach the inner Text through the environment, as with a plain Text.
///
/// `searchOffset` skips a leading part of `text` that is drawn but not
/// searched (the agent callback card's "Agent result 路 " label): matches are
/// counted in `text` from that character on, the same string the search unit
/// holds.
struct SearchHighlightText: View {
    let text: String
    let key: ChatSearchUnitKey?
    var searchOffset: Int = 0
    @Environment(\.chatSearchHighlights) private var center
    @Environment(\.chatSearchDimmed) private var dimmed

    init(_ text: String, key: ChatSearchUnitKey?, searchOffset: Int = 0) {
        self.text = text
        self.key = key
        self.searchOffset = searchOffset
    }

    /// For a block's views: the key from the message id in the environment.
    init(_ text: String, blockId: UUID, field: ChatSearchField, messageId: UUID?) {
        self.init(text, key: messageId.map { ChatSearchUnitKey(messageId: $0, blockId: blockId, field: field) })
    }

    var body: some View {
        if let center, let key {
            Observed(token: center.token(for: key), text: text, searchOffset: searchOffset, dimmed: dimmed)
        } else {
            Text(text)
        }
    }

    private struct Observed: View {
        @ObservedObject var token: ChatSearchHighlightToken
        let text: String
        let searchOffset: Int
        let dimmed: Bool

        var body: some View {
            if let state = token.state {
                Text(SearchHighlightText.attributed(text, searchOffset: searchOffset, state: state, dimmed: dimmed))
            } else {
                Text(text)
            }
        }
    }

    /// `text` with its first `state.drawLimit` occurrences backed in yellow
    /// and the current one in orange. Built piecewise, so its cost is linear
    /// in the text however many highlights it carries.
    static func attributed(_ text: String, searchOffset: Int, state: ChatSearchUnitHighlight,
                           dimmed: Bool) -> AttributedString {
        let start = text.index(text.startIndex, offsetBy: min(max(searchOffset, 0), text.count))
        let searchable = text[start...]
        let ranges = ChatSearchMatcher.ranges(of: state.query, in: String(searchable), limit: state.drawLimit)
        guard !ranges.isEmpty else { return AttributedString(text) }
        let searchableString = String(searchable)
        var out = AttributedString(String(text[..<start]))
        var cursor = searchableString.startIndex
        let match = Color(ChatSearchHighlightStyle.matchColor(dimmed: dimmed))
        let current = Color(ChatSearchHighlightStyle.currentColor(dimmed: dimmed))
        for (ordinal, r) in ranges.enumerated() {
            out += AttributedString(String(searchableString[cursor..<r.lowerBound]))
            var hit = AttributedString(String(searchableString[r]))
            hit.backgroundColor = ordinal == state.current ? current : match
            out += hit
            cursor = r.upperBound
        }
        out += AttributedString(String(searchableString[cursor...]))
        return out
    }
}


private struct ChatSearchBlockIdKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var chatSearchBlockId: UUID? { get { self[ChatSearchBlockIdKey.self] } set { self[ChatSearchBlockIdKey.self] = newValue } }
}

// END chat-search-highlights

extension Notification.Name { static let chatSearchJump = Notification.Name("chatSearchJump") }
struct ChatSearchHit: Identifiable, Equatable {
    let match: ChatSearchMatch
    let text: String
    let keyword: String
    var id: ChatSearchMatch { match }
    var messageId: UUID { match.key.messageId }
    var blockId: UUID? { match.key.blockId }
    var line: String { text }
    var keywords: [String] { [keyword] }
}
enum ChatSearchDisplayText {
    static func userBubble(_ content: String) -> String {
        var text = content
        for tag in ["user-attached-files", "system-reminder"] {
            while let start = text.range(of: "<\(tag)>") {
                let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
                text.removeSubrange(start.lowerBound..<end)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func toolCapsule(_ block: AssistantBlock) -> String {
        if let summary = block.toolSummary, !summary.isEmpty { return summary }; return block.toolDescription
    }

}
struct ChatSearchTextCacheEntry { let raw: String; let finalised: Bool; let text: String }
struct ChatSearchPendingUnit {
    let key: ChatSearchUnitKey
    let text: String
    var markdown: Bool = false
    var blocks: [BlockNode]? = nil
    var finalised: Bool = true
}
enum ChatSearchUnitBuilder {
    @MainActor static func snapshot(messages: [ChatMessage], sessionId: String?) -> [ChatSearchPendingUnit] {
        var units: [ChatSearchPendingUnit] = []
        func add(_ mid: UUID, _ bid: UUID?, _ field: ChatSearchField, _ text: String) {
            if !text.isEmpty { units.append(.init(key: .init(messageId: mid, blockId: bid, field: field), text: text)) }
        }
        for message in messages {
            let mid = message.id
            switch message.role {
            case .user:
                for (index, meta) in message.attachments.enumerated() where !meta.isImage && !meta.isVideo { add(mid, nil, .attachmentName(index), meta.fileName) }
                add(mid, nil, .body, ChatSearchDisplayText.userBubble(message.content))
            case .compactDivider, .systemInfo: add(mid, nil, .body, message.content)
            case .assistant:
                for block in message.blocks {
                    let bid = block.id
                    if let card = block.questionCard {
                        guard card.status != .pending else { continue }
                        add(mid, bid, .title, ChatSearchQuestionText.questionTopic(card)); add(mid, bid, .activity, ChatSearchQuestionText.questionDigest(card))
                        if block.isQuestionCardExpanded { for (index, question) in card.questions.enumerated() { add(mid, bid, .question(index), question.prompt) } }
                        continue
                    }
                    if block.kind.isSubAgentTool {
                        let records = ZeSubAgentBlockLink.records(for: block, rootSessionId: sessionId, coordinator: .shared)
                        if let record = records.first(where: { $0.status.isActive }) ?? records.first {
                            add(mid, bid, .title, record.shortPrompt)
                            if record.status.isActive { if let step = record.steps?.last(where: { $0.state == "running" }) { add(mid, bid, .activity, step.title) } }
                            else { add(mid, bid, .activity, ZeSubAgentPresentation.status(record)) }
                        } else { add(mid, bid, .title, block.toolDescription) }
                        continue
                    }
                    switch block.kind {
                    case .thinking: break
                    case .text:
                        units.append(.init(key: .init(messageId: mid, blockId: bid, field: .body), text: block.content, markdown: true, blocks: block.cachedMarkdown?.blocks, finalised: block.cachedMarkdown != nil || block.cachedAttributedString != nil))
                    case .info:
                        let lines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }; let reasons = lines.filter { $0.hasPrefix("⚠️") }
                        let shown = reasons.count <= 9 ? reasons : Array(reasons.prefix(4)) + [String(localized: "⋯ \(reasons.count - 8) more")] + Array(reasons.suffix(4))
                        for (index, line) in shown.enumerated() { add(mid, bid, .line(index), line) }
                        if let switched = lines.first(where: { !$0.hasPrefix("⚠️") }) { add(mid, bid, .title, switched) }
                    default: add(mid, bid, .body, ChatSearchDisplayText.toolCapsule(block))
                    }
                }
                if let error = message.error { add(mid, nil, .footerError, error) }
            }
        }
        return units
    }
    static func resolve(_ pending: [ChatSearchPendingUnit], cache: [UUID: ChatSearchTextCacheEntry] = [:], isCancelled: () -> Bool) -> (units: [ChatSearchUnit], cache: [UUID: ChatSearchTextCacheEntry])? {
        var units: [ChatSearchUnit] = [], nextCache: [UUID: ChatSearchTextCacheEntry] = [:]
        for (index, unit) in pending.enumerated() {
            if index % 32 == 0 && isCancelled() { return nil }
            var text = unit.text
            if unit.markdown, let bid = unit.key.blockId {
                if let cached = cache[bid], cached.raw == unit.text, cached.finalised == unit.finalised { text = cached.text }
                else {
                    let split = unit.finalised ? (prefix: unit.text, plainSuffix: "") : splitStreamingTableTail(unit.text)
                    let blocks = (split.plainSuffix.isEmpty ? unit.blocks : nil) ?? MarkdownContent(prepareMarkdownForRender(split.prefix)).blocks
                    text = ChatSearchMarkdownText.text(blocks: blocks, plainSuffix: split.plainSuffix)
                }
                nextCache[bid] = .init(raw: unit.text, finalised: unit.finalised, text: text)
            }
            units.append(.init(key: unit.key, text: text))
        }
        return (units, nextCache)
    }

}
@MainActor final class ChatSearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue && isActive { schedule() } } }
    @Published private(set) var hits: [ChatSearchHit] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var isActive = false
    @Published private(set) var isSearching = false
    @Published private(set) var isTruncated = false
    @Published private(set) var notice: String?
    @Published private(set) var focusRequest = 0
    let highlights = ChatSearchHighlightCenter()
    weak var viewModel: AIChatViewModel?
    private var messages: [ChatMessage] = []
    private var pending: DispatchWorkItem?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var subscriptions: [AnyCancellable] = []
    private var messageSubscriptions: [AnyCancellable] = []
    private var refreshScheduled = false
    private var noticeWork: DispatchWorkItem?
    private var textCache: [UUID: ChatSearchTextCacheEntry] = [:]
    private var lastSnapshotSignature: Int?
    var normalizedQuery: String { ChatSearchMatcher.normalizedQuery(query) }
    var current: ChatSearchHit? { hits.indices.contains(currentIndex) ? hits[currentIndex] : nil }
    var counterText: String { ChatSearchNavigation.counterText(index: hits.isEmpty ? nil : currentIndex, count: hits.count, truncated: isTruncated) }
    func bind(viewModel: AIChatViewModel) { guard self.viewModel !== viewModel else { return }; self.viewModel = viewModel; messages = viewModel.messages }
    func bind(messages: [ChatMessage]) { self.messages = messages; if isActive { observeMessages(); contentChanged() } }
    func activate(prefill: String? = nil) {
        if !isActive {
            isActive = true
            if let vm = viewModel {
                messages = vm.messages
                subscriptions = [vm.objectWillChange.sink { [weak self] _ in self?.contentChanged() }, ZeSubAgentCoordinator.shared.objectWillChange.sink { [weak self] _ in self?.contentChanged() }]
            }
            observeMessages()
        }
        focusRequest += 1
        if let prefill, !ChatSearchMatcher.normalizedQuery(prefill).isEmpty { query = prefill }
        else if !normalizedQuery.isEmpty { schedule() }
    }
    func deactivate() { isActive = false; subscriptions.removeAll(); messageSubscriptions.removeAll(); clear() }
    func clear() {
        pending?.cancel(); pending = nil; searchTask?.cancel(); searchTask = nil; generation += 1
        query = ""; hits = []; currentIndex = 0; isSearching = false; isTruncated = false; notice = nil; highlights.clear()
    }
    func step(_ delta: Int) {
        guard let result = ChatSearchNavigation.step(from: currentIndex, count: hits.count, forward: delta > 0) else { return }
        let old = current?.match; currentIndex = result.index; highlights.setCurrent(from: old, to: current?.match)
        if result.wrapped {
            notice = delta > 0 ? String(localized: "Wrapped to the first result") : String(localized: "Wrapped to the last result"); noticeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.notice = nil }; noticeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        }
        navigate()
    }
    func select(_ hit: ChatSearchHit) {
        guard let index = hits.firstIndex(of: hit) else { return }; let old = current?.match; currentIndex = index
        highlights.setCurrent(from: old, to: current?.match); navigate()
    }
    private func observeMessages() {
        messageSubscriptions.removeAll()
        for message in messages {
            messageSubscriptions.append(message.objectWillChange.sink { [weak self] _ in self?.contentChanged() })
            for block in message.blocks { messageSubscriptions.append(block.objectWillChange.sink { [weak self] _ in self?.contentChanged() }) }
        }
    }
    private func contentChanged() {
        guard isActive, !refreshScheduled, !normalizedQuery.isEmpty else { return }; refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }; self.refreshScheduled = false
            guard self.isActive, self.pending == nil, !self.isSearching else { return }
            if let vm = self.viewModel { self.messages = vm.messages }; self.observeMessages(); self.run(landOnNewest: false)
        }
    }
    private func schedule() {
        pending?.cancel(); searchTask?.cancel(); generation += 1
        if normalizedQuery.isEmpty { pending = nil; hits = []; currentIndex = 0; isSearching = false; isTruncated = false; highlights.clear(); return }
        isSearching = true
        let work = DispatchWorkItem { [weak self] in self?.run(landOnNewest: true) }; pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func run(landOnNewest: Bool) {
        pending = nil; guard isActive else { return }; searchTask?.cancel(); generation += 1
        let token = generation, query = normalizedQuery
        if let vm = viewModel { messages = vm.messages }
        let snapshot = ChatSearchUnitBuilder.snapshot(messages: messages, sessionId: viewModel?.sessionId)
        var fingerprint = Hasher()
        for unit in snapshot { fingerprint.combine(unit.key); fingerprint.combine(unit.text); fingerprint.combine(unit.finalised) }
        let signature = fingerprint.finalize()
        if !landOnNewest, signature == lastSnapshotSignature { return }
        lastSnapshotSignature = signature
        let cache = textCache
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let resolved = ChatSearchUnitBuilder.resolve(snapshot, cache: cache, isCancelled: { Task.isCancelled }), let result = ChatSearchEngine.search(units: resolved.units, query: query, isCancelled: { Task.isCancelled }) else { return }
            let texts = Dictionary(resolved.units.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
            await MainActor.run {
                guard let self, self.isActive, token == self.generation else { return }; let old = self.current?.match, oldIndex = self.currentIndex
                self.textCache = resolved.cache
                self.hits = result.matches.map { .init(match: $0, text: texts[$0.key] ?? "", keyword: query) }
                self.currentIndex = (landOnNewest ? ChatSearchNavigation.initialIndex(count: result.matches.count) : ChatSearchNavigation.relocate(previous: old, previousIndex: oldIndex, in: result.matches)) ?? 0
                self.isTruncated = result.truncated; self.isSearching = false; self.highlights.apply(result: result, query: query, current: self.current?.match)
                if landOnNewest { self.navigate() }
            }
        }
    }
    func navigate() {
        guard let current else { return }
        NotificationCenter.default.post(name: .chatSearchJump, object: self, userInfo: ["hit": current])
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: "结果 \(currentIndex + 1)，共 \(hits.count) 个") }
    }
}


// BEGIN chat-search-question-text
enum ChatSearchQuestionText {
    static func questionTopic(_ card: QuestionCardState) -> String {
        if card.questions.count == 1 { return card.questions.first?.prompt ?? card.displayQuestion }
        return card.questions.map { ($0.header?.isEmpty == false ? $0.header : nil) ?? $0.prompt }.joined(separator: " / ")
    }
    static func questionDigest(_ card: QuestionCardState) -> String {
        card.questions.indices.map { card.displayAnswerValues(at: $0).joined(separator: ", ") }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
// END chat-search-question-text
