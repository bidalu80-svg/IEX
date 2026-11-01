import SwiftUI
import UIKit
import Foundation

// Peripheral dependencies of the real ChatModels.swift only. The production
// message/block classes and SessionExportModels.swift are compiled unmodified.
// No network, tokenizer accuracy, persistence or question-card parsing is tested.
struct AppLogger {
    init(category: String) {}
    func debug(_ text: String) {}
    func info(_ text: String) {}
}
struct BPETokenizer {
    static let shared = BPETokenizer()
    func countTokens(_ text: String) -> Int { text.count }
}
struct RawMessage {
    static func isInternalBridgeText(_ text: String) -> Bool { text == "__fixture_internal_bridge__" }
}
struct LLMUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
}
struct QuestionCardState { var chromeTitle = "Question fixture" }
enum QuestionCardParser { static func headline(fromToolInput: String?) -> String? { nil } }
struct ToolSnapshot {}
struct MediaRef {}
struct MarkdownContent {}

@main
struct SessionShareHarness: App {
    @State private var ran = false
    var body: some Scene {
        WindowGroup {
            Text("Session sharing behavior regression").task {
                guard !ran else { return }
                ran = true
                runChecks()
            }
        }
    }

    @MainActor private func runChecks() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw NSError(domain: "SessionShareHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks.append(name)
        }
        do {
            let first = AssistantBlock(kind: .text, content: "FIRST_PROSE_SENTINEL")
            let thought = AssistantBlock(kind: .thinking, content: "short")
            thought.thinkingContentBuffer = "BUFFERED_THOUGHT_SENTINEL"
            let tool1 = AssistantBlock(kind: .shellTool(command: "echo first"), content: "TOOL_ONE_SENTINEL", toolStatus: .success)
            let tool2 = AssistantBlock(kind: .fileReadTool(path: "/fixture.txt"), content: "TOOL_TWO_SENTINEL", toolStatus: .success)
            let last = AssistantBlock(kind: .text, content: "FINAL_PROSE_SENTINEL")
            let user = ChatMessage(role: .user, content: "USER_SENTINEL")
            let attachment = InputAttachment(fileName: "fixture.txt", cacheURL: URL(fileURLWithPath: "/fixture.txt"), kind: .document)
            user.inputAttachments = [attachment]
            let reply = ChatMessage(role: .assistant, content: "unselected aggregate content", blocks: [first, thought, tool1, tool2, last])
            reply.error = "ERROR_SENTINEL"
            let queued = ChatMessage(role: .user, content: "queued", isQueued: true)
            let bridge = ChatMessage(role: .assistant, content: "__fixture_internal_bridge__")
            let frozen = SessionShareSnapshot.capture([user, reply, queued, bridge])
            try check(frozen.count == 2, "Queued and bridge messages are excluded")
            try check(frozen[0] !== user && frozen[1] !== reply, "Snapshot does not retain original message objects")
            try check(zip(frozen[1].blocks, reply.blocks).allSatisfy { $0.0 !== $0.1 }, "Snapshot deep-copies every block object")
            first.content = "LIVE_MUTATION_SENTINEL"
            thought.thinkingContentBuffer = "LIVE_THOUGHT_MUTATION"
            reply.error = nil
            try check(frozen[1].blocks[0].content == "FIRST_PROSE_SENTINEL", "Live text changes cannot modify frozen content")
            try check(frozen[1].blocks[1].content == "BUFFERED_THOUGHT_SENTINEL", "Buffered thinking is captured before later deltas")
            let cells = SessionShareSnapshot.cells(frozen)
            try check(cells.count == 7, "User, each of five blocks, and error each get a cell")
            try check(Set(cells.map(\.id)).count == cells.count, "Cell identifiers are unique")
            try check(cells.map(\.id) == SessionShareSnapshot.cells(frozen).map(\.id), "Cell IDs are stable across repeated enumeration")
            let chosen = Set([cells[0].id, cells[4].id, cells[5].id])
            let exported = SessionShareSnapshot.selectedMessages(frozen, selection: chosen)
            try check(exported.count == 2, "Selection preserves user and reply transcript order")
            try check(exported[0].content == "USER_SENTINEL" && exported[0].inputAttachments.count == 1, "Selected user retains content and input attachments")
            try check(exported[1].blocks.map(\.content) == ["TOOL_TWO_SENTINEL", "FINAL_PROSE_SENTINEL"], "Only the selected tool and final prose are exported in order")
            try check(exported[1].content.isEmpty && exported[1].error == nil, "Unselected aggregate content and error cannot leak")
            exported[1].blocks[0].content = "EXPORT_MUTATION"
            try check(frozen[1].blocks[3].content == "TOOL_TWO_SENTINEL", "Export copies cannot mutate frozen selection")
            try check(SessionShareSnapshot.selectedMessages(frozen, selection: []).isEmpty, "Empty selection exports nothing")
            let errorOnly = SessionShareSnapshot.selectedMessages(frozen, selection: [cells[6].id])
            try check(errorOnly.count == 1 && errorOnly[0].blocks.map(\.content) == ["ERROR_SENTINEL"] && errorOnly[0].content.isEmpty, "Error-only selection renders the selected error without unrelated reply content")
            let legacy = SessionShareSnapshot.capture([ChatMessage(role: .assistant, content: "LEGACY_CONTENT_SENTINEL")])
            let legacyCells = SessionShareSnapshot.cells(legacy)
            try check(legacyCells.count == 1, "Legacy assistant without blocks remains selectable")
            try check(SessionShareSnapshot.selectedMessages(legacy, selection: [legacyCells[0].id])[0].blocks.map(\.content) == ["LEGACY_CONTENT_SENTINEL"], "Legacy content becomes a renderable selected text block")
            try check(!user.isUserTextExpanded && reply.isStepsCollapsed && !tool2.isToolGroupExpanded, "Selection never changes live disclosure state")
            for width: CGFloat in [320, 393, 820, 1024] {
                try check(SessionExportWidth.adaptive.pageWidth(adaptiveWidth: width) == width, "Adaptive width preserves valid \(width)pt input")
            }
            try check(SessionExportWidth.adaptive.pageWidth(adaptiveWidth: 10) == 320, "Adaptive width clamps narrow input")
            try check(SessionExportWidth.adaptive.pageWidth(adaptiveWidth: 2048) == 1024, "Adaptive width clamps wide input")
            checks.append(contentsOf: try SessionShareRenderChecks.run(documents: documents))
            let result: [String: Any] = ["success": true, "checks": checks, "coverage": "Production snapshot/selection and native export algorithms (host, PDF glyphs/pagination, image slicing/budget). Row factory is a UIKit fixture; real chat rows, MarkdownRenderView, tables and media appearance are not covered."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: documents.appendingPathComponent("session-share-result.json"), options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["success": false, "checks": checks, "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]).write(to: documents.appendingPathComponent("session-share-result.json"), options: .atomic)
        }
    }
}
