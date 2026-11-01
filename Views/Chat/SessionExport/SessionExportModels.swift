//
//  SessionExportModels.swift
//  ZeApp
//
//  [T-session-share] Value types + content builder for the "Share Session"
//  feature. Everything here is plain data so the expensive CoreText layout
//  can run off the main thread: the builder is @MainActor (it reads
//  ObservableObject chat models) and produces a `SessionExportDocument`
//  that holds only strings / dates / images.
//

import Foundation
import UIKit

// MARK: - Options

enum SessionExportFormat: String, CaseIterable, Identifiable {
    case image
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return String(localized: "Long Image")
        case .pdf:   return "PDF"
        }
    }

    var systemImage: String {
        switch self {
        case .image: return "photo.on.rectangle"
        case .pdf:   return "doc.richtext"
        }
    }
}

enum SessionExportWidth: String, CaseIterable, Identifiable {
    case phone
    case pad
    case adaptive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone:    return String(localized: "Phone")
        case .pad:      return "iPad"
        case .adaptive: return String(localized: "Adaptive")
        }
    }

    /// Logical page width in points. `adaptiveWidth` is the live chat
    /// content width, so "Adaptive" reproduces what the user sees.
    func pageWidth(adaptiveWidth: CGFloat) -> CGFloat {
        switch self {
        case .phone:    return 393
        case .pad:      return 820
        case .adaptive: return min(max(adaptiveWidth, 320), 1024)
        }
    }
}

enum SessionExportTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark:  return String(localized: "Dark")
        }
    }
}

/// Everything the share sheet can change. Persisted across presentations
/// via `SessionExportOptionsStore` so a user who prefers dark + PDF does not
/// have to re-pick it every time.
struct SessionExportOptions: Hashable {
    var format: SessionExportFormat = .image
    var width: SessionExportWidth = .phone
    var theme: SessionExportTheme = .light
    /// Include the tool-call cards at all.
    var includeToolCalls: Bool = true
    /// Include the model's "thinking" blocks.
    var includeThinking: Bool = false
    /// Include the avatar / title / model name / date header.
    var includeHeader: Bool = true
    /// Widen markdown tables independently of the chosen device width.
    var adaptiveTables: Bool = false
}

/// Which messages go into the export.
enum SessionExportScope: Equatable {
    case all
    case selected(Set<UUID>)

    func contains(_ id: UUID) -> Bool {
        switch self {
        case .all:
            return true
        case .selected(let ids):
            return ids.contains(id)
        }
    }

    var isAll: Bool {
        if case .all = self { return true }
        return false
    }
}

// MARK: - Document

struct SessionExportHeader {
    let title: String
    let modelName: String
    let providerName: String?
    let date: Date
    let avatar: UIImage?
    let avatarEmoji: String?
}

struct SessionExportTool {
    let name: String
    let detail: String
    let status: String
    let duration: TimeInterval?
    let input: String?
    let output: String?
    let isFailure: Bool
    let isPending: Bool
}

enum SessionExportBlock {
    case header(SessionExportHeader)
    /// A user turn. `attachments` are display file names only.
    case user(text: String, attachments: [String], timestamp: Date)
    /// Assistant prose (markdown, inline styling supported).
    case prose(String)
    /// A fenced code block lifted out of the prose stream.
    case code(text: String, language: String?)
    case thinking(text: String, duration: TimeInterval?)
    case tool(SessionExportTool)
    /// A system-ish separator, e.g. the context-compaction marker.
    case note(String)
}

struct SessionExportDocument {
    let blocks: [SessionExportBlock]
    let generatedAt: Date

    var isEmpty: Bool { blocks.isEmpty }
}

// MARK: - Builder

@MainActor
enum SessionExportBuilder {

    /// Hard cap so one runaway thinking block can't produce a 50 MB image.
    private static let maxThinking = 6_000

    static func build(messages: [ChatMessage],
                      scope: SessionExportScope,
                      options: SessionExportOptions,
                      header: SessionExportHeader?) -> SessionExportDocument {
        var blocks: [SessionExportBlock] = []

        if options.includeHeader, let header {
            blocks.append(.header(header))
        }

        for message in messages where scope.contains(message.id) {
            switch message.role {
            case .user:
                guard !message.isQueued else { continue }
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let attachments = message.attachments.map(\.fileName)
                guard !text.isEmpty || !attachments.isEmpty else { continue }
                blocks.append(.user(text: text, attachments: attachments, timestamp: message.timestamp))

            case .assistant:
                guard !message.isInternalBridge else { continue }
                blocks.append(contentsOf: assistantBlocks(for: message, options: options))

            case .compactDivider:
                blocks.append(.note(String(localized: "Context compacted")))

            case .systemInfo:
                continue
            }
        }

        return SessionExportDocument(blocks: blocks, generatedAt: Date())
    }

    private static func assistantBlocks(for message: ChatMessage,
                                        options: SessionExportOptions) -> [SessionExportBlock] {
        var out: [SessionExportBlock] = []

        // Persisted history can carry the reply only in `content` (older
        // rows, or a turn that never streamed blocks), so fall back to it.
        let source: [AssistantBlock] = message.blocks.isEmpty
            ? [AssistantBlock(kind: .text, content: message.content)]
            : message.blocks

        for block in source {
            switch block.kind {
            case .text:
                let text = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(contentsOf: splitProseAndCode(text))

            case .thinking:
                guard options.includeThinking else { continue }
                // While streaming, deltas land in the non-published buffer and
                // only flush to `content` periodically — share what exists.
                let raw = block.content.isEmpty ? block.thinkingContentBuffer : block.content
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(.thinking(text: truncate(text, limit: maxThinking),
                                     duration: block.thinkingDuration))

            case .info:
                continue

            case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool,
                 .browserTool, .readImageTool, .memoryTool:
                guard options.includeToolCalls else { continue }
                out.append(.tool(tool(for: block)))
            }
        }

        // An assistant turn whose only content is an error still deserves a
        // line in the export rather than silently vanishing.
        if out.isEmpty, let error = message.error, !error.isEmpty {
            out.append(.prose(truncate(error, limit: 800)))
        }
        return out
    }

    private static func tool(for block: AssistantBlock) -> SessionExportTool {
        let statusText: String
        var isFailure = false
        var isPending = false

        if let status = block.toolStatus {
            switch status {
            case .success:
                statusText = String(localized: "Succeeded")
            case .failed(let message):
                isFailure = true
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                statusText = trimmed.isEmpty
                    ? String(localized: "Failed")
                    : "\(String(localized: "Failed")) · \(truncate(trimmed, limit: 120))"
            case .cancelled:
                isFailure = true
                statusText = String(localized: "Cancelled")
            case .running, .streaming:
                isPending = true
                statusText = String(localized: "Running")
            }
        } else {
            statusText = String(localized: "Done")
        }

        // The export renders the live chat rows, where tool steps are collapsed
        // chips. Raw arguments and outputs stay out of the image entirely.
        let input: String? = nil
        let output: String? = nil

        return SessionExportTool(
            name: toolDisplayName(for: block.kind),
            detail: block.toolDescription,
            status: statusText,
            duration: block.toolDuration,
            input: input,
            output: output,
            isFailure: isFailure,
            isPending: isPending
        )
    }

    static func toolDisplayName(for kind: AssistantBlockKind) -> String {
        switch kind {
        case .shellTool:      return "Shell"
        case .fileReadTool:   return String(localized: "Read File")
        case .fileWriteTool:  return String(localized: "Write File")
        case .fileEditTool:   return String(localized: "Edit File")
        case .browserTool:    return String(localized: "Browser")
        case .readImageTool:  return String(localized: "Read Image")
        case .memoryTool(let action):
            if kind.isQuestionCardTool { return String(localized: "Question Card") }
            if kind.isSubAgentTool { return action }
            return action.isEmpty ? String(localized: "Memory") : action
        case .text, .thinking, .info:
            return ""
        }
    }

    // MARK: - Markdown block splitting

    /// Split a markdown string into prose runs and fenced code blocks so the
    /// renderer can give code its own monospaced, filled card instead of
    /// trying to style it inline.
    static func splitProseAndCode(_ markdown: String) -> [SessionExportBlock] {
        var blocks: [SessionExportBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inFence = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            prose.removeAll()
            guard !text.isEmpty else { return }
            // Split very long runs so a single block stays well under the
            // image slicer's cap; the slicer can then cut on block edges
            // instead of chopping a paragraph in half.
            for chunk in chunkProse(text) {
                blocks.append(.prose(chunk))
            }
        }

        func flushCode() {
            let text = code.joined(separator: "\n")
            code.removeAll()
            let tag = language
            language = nil
            guard !text.isEmpty else { return }
            // Same reasoning as flushProse, with a wider cap: a 2 000-line
            // paste would otherwise become one 20 000 pt block that the image
            // slicer cannot break without cutting a line of code in half.
            for (index, chunk) in chunkProse(text, limit: 4_000).enumerated() {
                blocks.append(.code(text: chunk, language: index == 0 ? tag : nil))
            }
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    flushCode()
                    inFence = false
                } else {
                    flushProse()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : String(tag)
                    inFence = true
                }
                continue
            }
            if inFence {
                code.append(line)
            } else {
                prose.append(line)
            }
        }

        if inFence, !code.isEmpty {
            // Unterminated fence while streaming — still export the text.
            flushCode()
        }
        flushProse()
        return blocks
    }

    // MARK: - Helpers

    /// Splits a prose run into chunks of roughly `limit` characters, cutting
    /// at newlines so markdown structure survives the split.
    private static func chunkProse(_ text: String, limit: Int = 3_000) -> [String] {
        guard text.count > limit else { return [text] }

        var chunks: [String] = []
        var current: [String] = []
        var currentLength = 0

        for line in text.components(separatedBy: "\n") {
            if currentLength + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current.removeAll()
                currentLength = 0
            }
            current.append(line)
            currentLength += line.count + 1
        }

        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        return "\(head)\n…"
    }
}

// MARK: - Block selection (presentation-only, never mutates the live chat)

struct SessionShareCell: Identifiable {
    enum Kind { case user, text, thinking, tool, note, error }
    struct ID: Hashable {
        let messageID: UUID
        let blockID: UUID?
        let isError: Bool
    }
    let id: ID
    let kind: Kind
    /// A detached, single-cell message rendered by the existing native rows.
    let message: ChatMessage
}

// MARK: - BEGIN SessionShareSelection
// Foundation-only standalone test boundary.
/// Range operations use the order of visible cells, never UUID ordering.
/// Extract through the matching END marker; no app models or UIKit are required.
enum SessionShareSelection {
    static func below<ID: Hashable>(_ anchor: ID, ordered: [ID]) -> Set<ID> {
        guard let index = ordered.firstIndex(of: anchor) else { return [] }
        return Set(ordered[index...])
    }

    static func dragging<ID: Hashable>(from anchor: ID, to end: ID,
                                      ordered: [ID], initial: Set<ID>, selecting: Bool) -> Set<ID> {
        guard let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: end) else { return initial }
        let range = Set(ordered[min(a, b)...max(a, b)])
        return selecting ? initial.union(range) : initial.subtracting(range)
    }
}

// MARK: - END SessionShareSelection

@MainActor
enum SessionShareSnapshot {
    /// Freeze once when the picker opens. Streaming updates and disclosure changes
    /// in the live conversation cannot change the selection or cached export.
    static func capture(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.filter {
            !$0.isQueued && !$0.isInternalBridge && ($0.role == .user || $0.role == .assistant)
        }.map {
            let copy = copyMessage($0, blocks: $0.blocks, includeContent: true, includeError: false)
            copy.error = $0.error
            return copy
        }
    }

    static func cells(_ messages: [ChatMessage]) -> [SessionShareCell] {
        var result: [SessionShareCell] = []
        for message in messages {
            if message.role == .user || message.blocks.isEmpty {
                if !message.content.isEmpty || !message.attachments.isEmpty || !message.inputAttachments.isEmpty {
                    result.append(SessionShareCell(id: .init(messageID: message.id, blockID: nil, isError: false),
                                                   kind: message.role == .user ? .user : .text,
                                                   message: copyMessage(message, blocks: [], includeContent: true, includeError: false)))
                }
            } else {
                for block in message.blocks {
                    let kind: SessionShareCell.Kind
                    switch block.kind {
                    case .text: kind = .text
                    case .thinking: kind = .thinking
                    case .info: kind = .note
                    default: kind = .tool
                    }
                    result.append(SessionShareCell(id: .init(messageID: message.id, blockID: block.id, isError: false),
                                                   kind: kind,
                                                   message: copyMessage(message, blocks: [block], includeContent: false, includeError: false)))
                }
            }
            if let error = message.error, !error.isEmpty {
                result.append(SessionShareCell(id: .init(messageID: message.id, blockID: nil, isError: true),
                                               kind: .error,
                                               message: copyMessage(message, blocks: [], includeContent: false, includeError: true)))
            }
        }
        return result
    }

    static func selectedMessages(_ messages: [ChatMessage], selection: Set<SessionShareCell.ID>) -> [ChatMessage] {
        messages.compactMap { message in
            let selected = selection.filter { $0.messageID == message.id }
            guard !selected.isEmpty else { return nil }
            let blocks = message.blocks.filter { block in selected.contains { $0.blockID == block.id } }
            return copyMessage(message, blocks: blocks,
                               includeContent: selected.contains { $0.blockID == nil && !$0.isError },
                               includeError: selected.contains { $0.isError })
        }
    }

    private static func copyMessage(_ source: ChatMessage, blocks: [AssistantBlock],
                                    includeContent: Bool, includeError: Bool) -> ChatMessage {
        var detachedBlocks = blocks.map(copyBlock)
        // Native assistant rows render blocks, not ChatMessage.content. Materialize
        // legacy replies and selected error-only rows rather than exporting blanks.
        if source.role == .assistant, detachedBlocks.isEmpty, includeContent, !source.content.isEmpty {
            detachedBlocks.append(AssistantBlock(kind: .text, content: source.content))
        }
        if source.role == .assistant, includeError, let error = source.error, !error.isEmpty {
            detachedBlocks.append(AssistantBlock(kind: .text, content: error))
        }
        let copy = ChatMessage(role: source.role, content: includeContent ? source.content : "",
                               blocks: detachedBlocks, timestamp: source.timestamp)
        copy.error = nil
        copy.attachments = source.role == .user && includeContent ? source.attachments : []
        copy.inputAttachments = source.role == .user && includeContent ? source.inputAttachments : []
        copy.firstTokenLatency = source.firstTokenLatency
        copy.taskDuration = source.taskDuration
        copy.usage = source.usage
        copy.streamInterruptCount = source.streamInterruptCount
        copy.isUserTextExpanded = true
        copy.isStepsCollapsed = false
        return copy
    }

    private static func copyBlock(_ source: AssistantBlock) -> AssistantBlock {
        let content = source.kind == .thinking && source.thinkingContentBuffer.count > source.content.count
            ? source.thinkingContentBuffer : source.content
        let copy = AssistantBlock(kind: source.kind, content: content,
                                  toolStatus: source.toolStatus, toolUseId: source.toolUseId)
        copy.thinkingContentBuffer = content
        copy.contentUpdateSeq = source.contentUpdateSeq
        copy.imageFilePath = source.imageFilePath
        copy.browserURL = source.browserURL
        copy.toolSummary = source.toolSummary
        copy.toolDuration = source.toolDuration
        copy.toolStartTime = source.toolStartTime
        copy.wasBackgroundSuspended = source.wasBackgroundSuspended
        copy.toolInputArgs = source.toolInputArgs
        copy.questionCard = source.questionCard
        copy.isQuestionCardExpanded = true
        copy.streamingFileContent = source.streamingFileContent
        copy.isThinkingExpanded = true
        copy.isToolGroupExpanded = true
        copy.thinkingDuration = source.thinkingDuration
        copy.thinkingStartTime = source.thinkingStartTime
        copy.thinkingUserToggled = true
        // Do not share mutable attributed-string/layout caches across render widths.
        return copy
    }
}
