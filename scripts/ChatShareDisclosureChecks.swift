import Foundation
import CoreGraphics

@main enum ChatShareDisclosureChecks {
    static func main() {
        let user = UUID(), reply = UUID(), openReply = UUID(), running = UUID()
        let early = UUID(), firstTool = UUID(), thought = UUID(), secondTool = UUID(), final = UUID()
        let sources = [
            ChatShareBlockSource(id: early, kind: .text, isEmpty: false),
            ChatShareBlockSource(id: firstTool, kind: .tool, isEmpty: false),
            ChatShareBlockSource(id: thought, kind: .thinking, isEmpty: false),
            ChatShareBlockSource(id: secondTool, kind: .tool, isEmpty: false),
            ChatShareBlockSource(id: final, kind: .text, isEmpty: false)
        ]
        let units = [ChatShareUnit(kind: .user, messageIds: [user]),
                     ChatShareUnit(kind: .reply, messageIds: [reply, openReply, running])]
        let blocks = [reply: sources, openReply: sources, running: sources]
        let headers: Set<UUID> = [reply, openReply, running]
        let expanded = ChatShareCells.cells(units: units, blocks: blocks, errors: [], taskHeaders: headers)
        let mixed = ChatShareCells.cells(units: units, blocks: blocks, errors: [], taskHeaders: headers,
                                         collapsedMessages: [reply], collapsibleMessages: [reply, openReply])
        let closed = mixed.filter { $0.messageId == reply }
        precondition(closed.map(\.kind) == [.taskHeader, .text], "closed task hides all process blocks")
        precondition(closed.last?.blockId == final, "last reply block identity preserved")
        precondition(closed.first?.canToggleSteps == true && closed.first?.stepsCollapsed == true)
        precondition(!mixed.contains { $0.kind == .toolGroup }, "task folding never emits old tool-count rows")
        precondition(mixed.filter { $0.messageId == openReply }.count == 6, "open task retains every original block")
        precondition(mixed.first { $0.messageId == running }?.canToggleSteps == false, "running task has no collapse action")
        let selected = Set(closed.map(\.id))
        let unfolded = ChatShareCells.remapSelection(selected, from: mixed, to: expanded)
        let expected = Set(expanded.filter { $0.messageId == reply }.map(\.id))
        precondition(unfolded == expected, "selected collapsed task restores its full hidden trail")
        precondition(ChatShareCells.remapSelection(unfolded, from: expanded, to: mixed) == selected)
        let finalOnly = Set(closed.filter { $0.kind == .text }.map(\.id))
        precondition(ChatShareCells.remapSelection(finalOnly, from: mixed, to: expanded) == finalOnly,
                     "selecting final text alone does not silently include hidden tools")
        let noText = ChatShareCells.cells(units: [units[1]], blocks: [reply: sources.filter { $0.kind != .text }],
                                         errors: [], taskHeaders: [reply], collapsedMessages: [reply])
        precondition(noText.filter { $0.messageId == reply }.map(\.kind) == [.taskHeader], "no final text remains a header only")
        let ids = mixed.map(\.id)
        precondition(Set(ids).count == ids.count, "headers and blocks have stable distinct identities across messages")
        print("PASS: task disclosure projection, partial selection, mixed state and round-trip checks")
    }
}
