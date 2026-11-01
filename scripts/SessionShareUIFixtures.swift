import SwiftUI
import UIKit

// Compile-only substitutes for the full application's chat-row dependencies.
// SessionShareSheet.swift itself is compiled UNMODIFIED, so SwiftUI type errors,
// preview API mismatches, PDFView and zoom-view code are checked early in CI.
// These fixtures do not prove real chat-row visuals or tap/drag interaction.
final class CellStateBridgeV2: ObservableObject {
    var isActiveMessage = false
    var showUsage = false
    var usageContentVisible = false
    var showsCompletionActions = false
    var onReadAloud: (() -> Void)?
    var onRetry: (() -> Void)?
}

struct SessionExportAssistantTurn: View {
    let message: ChatMessage
    let bridge: CellStateBridgeV2
    let maxWidth: CGFloat
    var body: some View { Text(message.blocks.map(\.content).joined(separator: "\n")) }
}

struct ChatMessageRow: View {
    let message: ChatMessage
    let isActiveMessage: Bool
    let commandStartTime: Date?
    let onStop: (() -> Void)?
    let onRetry: (() -> Void)?
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    let onWithdraw: (() -> Void)?
    let autoRetryAttempt: Int
    let autoRetryCountdown: Int
    let canResume: Bool
    let onResume: (() -> Void)?
    let onCompact: (() -> Void)?
    let onCopyScreenshot: (() -> Void)?
    let onReadAloud: (() -> Void)?
    let onShowCompactSummary: (() -> Void)?
    let onRevertCompact: (() -> Void)?
    let onToggleUserMessageExpansion: (() -> Void)?
    let browserPool: NSObject?
    let toolSnapshots: [ToolSnapshotItem]
    var body: some View { Text(message.content) }
}

// Peripheral production components referenced by the renderer's full row factory.
struct AssistantBlockView: View {
    let block: AssistantBlock
    let message: ChatMessage
    let isActiveMessage: Bool
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    var body: some View { Text(block.content) }
}
struct SelectableMarkdownView: View {
    let markdown: String
    var body: some View { Text(markdown) }
}
struct SoulAvatarView: View {
    let size: CGFloat
    var body: some View { Color.clear.frame(width: size, height: size) }
}
enum SoulStore {
    struct Metadata { var name = "Fixture" }
    static var cachedMetadata = Metadata()
}
enum ChatColors {
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let userMessageText = Color.primary
    static let userMessageBubble = Color.gray.opacity(0.2)
}
struct AssistantTaskDurationView: View {
    let duration: TimeInterval
    var body: some View { Text("\(duration)") }
}
struct UserAttachmentList: View {
    let attachments: [AttachmentMeta]
    var body: some View { Text(attachments.map(\.fileName).joined(separator: ",")) }
}
struct QueuedAttachmentPreview: View {
    let attachments: [InputAttachment]
    var body: some View { Text(attachments.map(\.fileName).joined(separator: ",")) }
}
struct FontSettings {
    static let shared = FontSettings()
    func scaledMessage(_ size: CGFloat) -> CGFloat { size }
}
