//
//  ChatSearch.swift
//  ZeApp
//
//  [T-chat-search] In-conversation search.
//
//  The panel is deliberately decoupled from the message list: it publishes a
//  `chatSearchJump` notification carrying the message id, and the list owns
//  scrolling + the in-place highlight. That keeps this file free of UIKit and
//  lets the same engine run in a future iPad sidebar.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Notification

extension Notification.Name {
    /// `userInfo["messageId"]: UUID` — reveal this message in the transcript.
    static let chatSearchJump = Notification.Name("chatSearchJump")
}

// MARK: - Hit

struct ChatSearchHit: Identifiable, Equatable {
    let id: String
    let messageId: UUID
    let isUser: Bool
    let timestamp: Date
    /// The matching line, trimmed and windowed around the first keyword.
    let snippet: String
    /// The full line, so the jump can find it inside the rendered text.
    let line: String
    /// First keyword, the one the jump scrolls to.
    let keyword: String
    let keywords: [String]
    /// True when the line came from a tool's output rather than prose.
    let isToolOutput: Bool
    /// Owning block, so the jump can target the exact cell instead of the
    /// first cell of the message (which is the thinking header).
    let blockId: UUID?
}

// MARK: - Engine

enum ChatSearchEngine {
    /// A hard cap so a pathological transcript cannot freeze the panel.
    static let maxHits = 400
    /// Tool output can be megabytes; only the head of each block is scanned.
    static let maxLinesPerBlock = 400

    /// Whitespace-separated keywords, also accepting the full-width
    /// separators a Chinese keyboard produces. Every keyword must appear on
    /// the same line for a hit — that is what makes a multi-word query
    /// behave like a filter instead of an OR.
    static func keywords(in query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace || $0 == "，" || $0 == "," || $0 == "、" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func search(messages: [ChatMessage], query: String) -> [ChatSearchHit] {
        let keys = keywords(in: query)
        guard !keys.isEmpty else { return [] }

        var hits: [ChatSearchHit] = []
        var seen = Set<String>()

        for message in messages {
            for line in lines(for: message) {
                guard containsAll(keys, in: line.text) else { continue }
                // The same sentence can appear twice in one turn (prose echoed
                // in a tool result); one row per line is enough.
                guard seen.insert("\(message.id.uuidString)|\(line.text)").inserted else { continue }
                hits.append(ChatSearchHit(
                    id: "\(message.id.uuidString)-\(hits.count)",
                    messageId: message.id,
                    isUser: message.role == .user,
                    timestamp: message.timestamp,
                    snippet: snippet(from: line.text, keys: keys),
                    line: line.text,
                    keyword: keys[0],
                    keywords: keys,
                    isToolOutput: line.isTool,
                    blockId: line.blockId
                ))
                if hits.count >= maxHits { return hits }
            }
        }
        return hits
    }

    // MARK: Private

    private struct SearchLine {
        let text: String
        let isTool: Bool
        /// The block this line came from, so a jump can target the exact cell
        /// instead of the first cell of the message (which is the thinking
        /// header, not the prose).
        let blockId: UUID?
    }

    private static func lines(for message: ChatMessage) -> [SearchLine] {
        var out: [SearchLine] = []

        func append(_ text: String, blockId: UUID?) {
            guard !text.isEmpty else { return }
            var added = 0
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if !line.isEmpty {
                    out.append(SearchLine(text: line, isTool: false, blockId: blockId))
                    added += 1
                    if added >= maxLinesPerBlock { return }
                }
            }
        }

        if message.role == .user {
            append(message.content, blockId: nil)
            return out
        }

        // [T-chat-search-body-only] Prose only.
        //
        // Tool output, tool summaries and thinking blocks used to be indexed
        // too, which inflated the counter (36 hits for a character that
        // appears a dozen times in the reply) and made "next" land on
        // terminal logs the reader never meant to search.
        for block in message.blocks {
            switch block.kind {
            case .text:
                append(block.content, blockId: block.id)
            default:
                break
            }
        }
        return out
    }

    private static func containsAll(_ keys: [String], in line: String) -> Bool {
        for key in keys where line.range(of: key, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }

    private static func snippet(from line: String, keys: [String], limit: Int = 180) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }

        var anchor = trimmed.startIndex
        for key in keys {
            if let range = trimmed.range(of: key, options: [.caseInsensitive, .diacriticInsensitive]) {
                anchor = range.lowerBound
                break
            }
        }

        let lead = 48
        let start = trimmed.index(anchor, offsetBy: -lead, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
        let end = trimmed.index(start, offsetBy: limit, limitedBy: trimmed.endIndex) ?? trimmed.endIndex

        var out = String(trimmed[start..<end])
        if start > trimmed.startIndex { out = "…" + out }
        if end < trimmed.endIndex { out += "…" }
        return out
    }
}

// MARK: - In-place highlight

/// Shared query for the in-place highlight.
///
/// Deliberately not an `@Environment` value: the transcript is a UIKit
/// collection view, and each cell is built with its own
/// `UIHostingConfiguration`, which creates an independent SwiftUI environment
/// (the file already documents this for `vm`). A store is the only path that
/// actually reaches the text views inside those cells.
final class ChatSearchHighlightStore {
    static let shared = ChatSearchHighlightStore()

    private let subject = CurrentValueSubject<String, Never>("")
    private(set) var query: String = ""

    var publisher: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }

    private init() {}

    func set(_ newValue: String) {
        guard newValue != query else { return }
        query = newValue
        subject.send(newValue)
    }
}

// MARK: - Highlight

enum ChatSearchHighlight {
    /// Paints every keyword occurrence with the accent tint, merging overlaps
    /// so `ab` + `bc` in `abc` does not double-apply attributes. Mirrors the
    /// session-list highlighter so both search surfaces look the same.
    static func attributed(_ text: String,
                           keywords: [String],
                           base: Color,
                           accent: Color = .accentColor) -> AttributedString {
        var attr = AttributedString(text)
        attr.foregroundColor = base
        guard !keywords.isEmpty else { return attr }

        let total = text.count
        var ranges: [Range<String.Index>] = []
        for key in keywords {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: key,
                                         options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchStart..<text.endIndex) {
                ranges.append(range)
                searchStart = range.upperBound
                if ranges.count > 200 { break }
            }
        }
        guard !ranges.isEmpty else { return attr }

        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }

        for range in merged {
            let lo = text.distance(from: text.startIndex, to: range.lowerBound)
            let hi = text.distance(from: text.startIndex, to: range.upperBound)
            // `AttributedString.index(_:offsetByCharacters:)` traps out of
            // range, so clamp before indexing.
            guard lo >= 0, hi <= total, lo < hi else { continue }
            let lower = attr.index(attr.startIndex, offsetByCharacters: lo)
            let upper = attr.index(attr.startIndex, offsetByCharacters: hi)
            attr[lower..<upper].backgroundColor = accent.opacity(0.22)
            attr[lower..<upper].foregroundColor = accent
            attr[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attr
    }
}

// MARK: - Model

/// Owns the query, the debounce and the hit list. Deliberately not
/// `@MainActor`: `@StateObject` initialisers run before the view is isolated,
/// and every mutation here already happens on the main queue (SwiftUI
/// bindings and the debounce work item).
final class ChatSearchModel: ObservableObject {
    @Published var query: String = "" {
        didSet { schedule() }
    }
    @Published private(set) var hits: [ChatSearchHit] = []
    @Published private(set) var currentIndex: Int = 0

    private var messages: [ChatMessage] = []
    private var pending: DispatchWorkItem?

    var current: ChatSearchHit? {
        hits.indices.contains(currentIndex) ? hits[currentIndex] : nil
    }

    /// Re-read the transcript. Called when the panel opens and whenever the
    /// conversation grows underneath it.
    func bind(messages: [ChatMessage]) {
        self.messages = messages
        schedule()
    }

    func clear() {
        pending?.cancel()
        pending = nil
        query = ""
        hits = []
        currentIndex = 0
    }

    func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        currentIndex = (currentIndex + delta + hits.count) % hits.count
    }

    func select(_ hit: ChatSearchHit) {
        if let index = hits.firstIndex(of: hit) { currentIndex = index }
    }

    private func schedule() {
        pending?.cancel()
        let query = self.query
        let snapshot = messages

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []
            currentIndex = 0
            return
        }

        let work = DispatchWorkItem { [weak self] in
            let result = ChatSearchEngine.search(messages: snapshot, query: query)
            guard let self else { return }
            self.hits = result
            self.currentIndex = 0
        }
        pending = work
        // Typing debounce: a 400-message transcript costs a few milliseconds,
        // but running that on every keystroke still shows up as input lag.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}
