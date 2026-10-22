import SwiftUI
import Combine

// MARK: - Assistant Block View (individual block — isolated invalidation)

struct AssistantBlockView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    let isActiveMessage: Bool
    /// Current session reasoning level, already clamped to the active model.
    var thinkingLevel: ThinkingLevel = .off
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var onTapBlank: ((CGPoint) -> Void)?
    var onCopyScreenshot: (() -> Void)?
    /// [T-selection-menu-ze-tts] Selection-menu read-aloud hooks, plumbed
    /// down to SelectableMarkdownView (nil for non-text or streaming contexts).
    var onReadAloud: (() -> Void)?
    var onSpeakText: ((String) -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    @Binding var highlightedBlockId: UUID?
    @Binding var detailBlock: AssistantBlock?
    private var isHighlighted: Bool { highlightedBlockId == block.id }

    var body: some View {
        switch block.kind {
        case .text:
            if !block.content.isEmpty {
                textBlockView
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(ChatColors.accent.opacity(isHighlighted ? 0.10 : 0))
                    )
            }
        case .thinking:
            ThinkingBlockView(
                block: block,
                isStreaming: isActiveMessage && message.blocks.last?.id == block.id,
                thinkingLevel: thinkingLevel
            )
            .padding(.vertical, 2)
            // The enclosing assistant stack first measures its children at
            // intrinsic width, then expands itself. Keep the thinking block
            // full-width for that measurement so its compact header is always
            // placed at the message's leading edge after streaming finishes.
            .frame(maxWidth: .infinity, alignment: .leading)
        case .shellTool:
            ToolCapsuleView(block: block, icon: "terminal", accentColor: .green,
                            commandStartTime: commandStartTime, onStop: onStop, browserPool: browserPool,
                            toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock)
        case .fileReadTool:
            ToolCapsuleView(block: block, icon: "doc.text", accentColor: .cyan,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock)
        case .fileWriteTool:
            ToolCapsuleView(block: block, icon: "doc.text.fill", accentColor: .blue,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock)
        case .fileEditTool:
            ToolCapsuleView(block: block, icon: "square.and.pencil", accentColor: .orange,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock)
        case .browserTool:
            ToolCapsuleView(block: block, icon: "globe", accentColor: .blue,
                            commandStartTime: commandStartTime, onStop: onStop, browserPool: browserPool,
                            toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock)
        case .readImageTool:
            ToolCapsuleView(block: block, icon: "photo", accentColor: .purple,
                            commandStartTime: commandStartTime, onStop: onStop,
                            toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock)
        case .memoryTool:
            if block.questionCard != nil {
                QuestionCardView(block: block)
                    .padding(.vertical, 4)
            } else {
                ToolCapsuleView(
                    block: block,
                    icon: block.kind.toolIconName,
                    accentColor: block.kind.isSubAgentTool ? ZeSubAgentTheme.purple : .pink,
                    commandStartTime: commandStartTime, onStop: onStop,
                    toolSnapshots: toolSnapshots, onCopyScreenshot: onCopyScreenshot, detailBlock: $detailBlock
                )
            }
        case .info:
            let allLines = block.content.components(separatedBy: "\n").filter { !$0.isEmpty }
            // Separate reason lines (⚠️) from the final switched line (✅)
            let reasonLines = allLines.filter { $0.hasPrefix("⚠️") }
            let switchedLine = allLines.first { !$0.hasPrefix("⚠️") && !$0.isEmpty }
            // Truncate middle if more than 9 reason lines
            let displayReasons: [String] = {
                if reasonLines.count <= 9 { return reasonLines }
                return Array(reasonLines.prefix(4)) + [String(localized: "⋯ \(reasonLines.count - 8) more")] + Array(reasonLines.suffix(4))
            }()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(displayReasons.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.45))
                        .lineLimit(2)
                }
                if let switchedLine {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.8))
                        Text(switchedLine)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ChatColors.primaryText.opacity(0.75))
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.14), lineWidth: 0.5))
            .contextMenu {
                Button {
                    UIPasteboard.general.string = block.content
                } label: {
                    Label(String(localized: "Copy Error"), systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ViewBuilder
    private var textBlockView: some View {
        SelectableMarkdownView(
            markdown: block.content,
            cachedContent: block.cachedMarkdown,
            cachedAttributedString: block.cachedAttributedString,
            messageId: message.id,
            blockId: block.id,
            onTapBlank: onTapBlank,
            onCopyScreenshot: onCopyScreenshot,
            onReadAloud: onReadAloud,
            onSpeakText: onSpeakText
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ZeOpenURLHandler())
    }
}

// MARK: - Shimmer Overlay (continuous leading-to-trailing shine)

/// Shared sweep timing for the compact chat status rows and the "Ze正在思考中"
/// indicator. Keeping one value prevents the two animations from drifting apart.
private enum ChatShimmerStyle {
    static let sweepDuration: TimeInterval = 1.65
}

/// A single text layer with a moving highlight. The highlighted copy is an
/// exact second render of the base text, so the sweep cannot drift and leave a
/// ghost behind when surrounding row content changes size.
private struct ChatShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let font: Font
    let color: Color
    let isActive: Bool
    let lineLimit: Int?
    /// When true, preserve intrinsic width for short status labels. Tool titles
    /// opt out so long commands receive the row's remaining width and truncate.
    let usesIntrinsicWidth: Bool
    @State private var startedAt = Date()

    init(
        text: String,
        font: Font,
        color: Color,
        isActive: Bool,
        lineLimit: Int? = 1,
        usesIntrinsicWidth: Bool = true
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.isActive = isActive
        self.lineLimit = lineLimit
        self.usesIntrinsicWidth = usesIntrinsicWidth
    }

    var body: some View {
        ZStack(alignment: .leading) {
            label.foregroundStyle(color)
            if isActive && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let phase = CGFloat((elapsed / ChatShimmerStyle.sweepDuration).truncatingRemainder(dividingBy: 1.0))
                    label
                        .foregroundStyle(.white)
                        .mask(sweepMask(phase: phase))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
        }
        .fixedSize(horizontal: usesIntrinsicWidth && lineLimit != nil, vertical: lineLimit == nil)
        .onAppear { startedAt = Date() }
        .onChange(of: isActive) { active in
            if active { startedAt = Date() }
        }
    }

    private var label: some View {
        Text(text)
            .font(font)
            .lineLimit(lineLimit)
    }

    private func sweepMask(phase: CGFloat) -> some View {
        GeometryReader { proxy in
            let bandWidth = max(52, proxy.size.width * 0.42)
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth, height: proxy.size.height)
            .offset(x: -bandWidth + phase * (proxy.size.width + bandWidth))
        }
    }
}

/// Keeps completed thinking lines static while applying the shared shimmer to
/// only the logical line currently receiving streamed content.
private struct ThinkingContentText: View {
    let text: String
    let isStreaming: Bool

    private var activeLine: String {
        guard isStreaming else { return "" }
        return text.lastIndex(of: "\n")
            .map { String(text[text.index(after: $0)...]) } ?? text
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ChatColors.tertiaryText)
                .lineSpacing(3)

            if !activeLine.isEmpty {
                ChatShimmerText(
                    text: activeLine,
                    font: .system(size: 13),
                    color: .clear,
                    isActive: true,
                    lineLimit: nil
                )
                .lineSpacing(3)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
        }
    }
}

/// A narrow shimmer band that sweeps from leading to trailing.
/// Its offset is time-driven, so a collection-view cell cannot retain a
/// stopped repeat-forever animation after it has been reused for another tool.
struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let isActive: Bool
    @State private var startedAt = Date()

    private var peakOpacity: CGFloat {
        colorScheme == .light ? 0.75 : 0.25
    }

    var body: some View {
        GeometryReader { geo in
            // This is a narrow highlight moving through the capsule's own
            // coordinate space. The previous oversized full-width gradient
            // spent most of its cycle covering the same middle pixels.
            let bandWidth = max(52, geo.size.width * 0.42)
            if isActive {
                // `.animation` only refreshes while SwiftUI already has an
                // active animation. This overlay is deliberately time-driven,
                // so that schedule rendered a single frame in reused tool
                // cells and left the shine parked in the middle. A periodic
                // schedule keeps the phase advancing from left to right.
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let phase = CGFloat((elapsed / ChatShimmerStyle.sweepDuration).truncatingRemainder(dividingBy: 1.0))
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0), .white.opacity(peakOpacity), .white.opacity(0)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: bandWidth, height: geo.size.height)
                            .offset(x: -bandWidth + phase * (geo.size.width + bandWidth))
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                }
            } else {
                Color.clear
            }
        }
        .onAppear { startedAt = Date() }
        .onChange(of: isActive) { active in
            if active { startedAt = Date() }
        }
        .clipped()
    }
}

// MARK: - Tool Step View (unified text row for all tool types)

struct ToolCapsuleView: View {
    @ObservedObject var block: AssistantBlock
    let icon: String
    let accentColor: Color
    var commandStartTime: Date?
    var onStop: (() -> Void)?
    var browserPool: BrowserTabPool?
    var toolSnapshots: [ToolSnapshotItem] = []
    var onCopyScreenshot: (() -> Void)? = nil
    @Binding var detailBlock: AssistantBlock?
    @State private var dotsActive = false
    /// [T-tool-bg-suspended-hint] Drives the background-suspension info alert.
    @State private var showBgHintAlert = false
    @ObservedObject private var keepAlive = BackgroundKeepAliveManager.shared

    /// Show the yellow ⓘ hint only when this tool was flagged as background-
    /// suspended AND enhanced background isn't already effective (nothing to
    /// suggest if it's on). Mirrors the BackgroundInterruptionTracker gate.
    private var showBgSuspendedHint: Bool {
        block.wasBackgroundSuspended && !keepAlive.enhancedBackgroundEffective
    }
    /// [T-ios-retry-hide-when-processing] Used to suppress the "Re-run From
    /// Here" long-press menu item while the agent loop is busy — tapping it
    /// mid-run would corrupt the in-flight processing state.
    @EnvironmentObject private var vm: AIChatViewModel

    /// Display text: prefer LLM-generated toolSummary, fall back to toolDescription.
    private var displayText: String {
        if let summary = block.toolSummary, !summary.isEmpty {
            return summary
        }
        return block.toolDescription
    }

    /// [T-ios-tool-bubble-longpress-menu] Human-readable, paste-back-able
    /// dump of this tool call + its result for the "Copy Tool Details"
    /// menu action. Pulls tool name from the block kind, the input JSON
    /// from toolInputArgs (pretty-printed when it parses), and the result
    /// text + status from the block's content / toolStatus (with the
    /// snapshot text as a fallback source).
    private var toolDetailsClipboard: String {
        // Tool name from the block kind.
        let toolName: String
        switch block.kind {
        case .shellTool:     toolName = "shell_execute"
        case .fileReadTool:  toolName = "file_read"
        case .fileWriteTool: toolName = "file_write"
        case .fileEditTool:  toolName = "file_edit"
        case .browserTool:   toolName = "browser_use"
        case .readImageTool: toolName = "read_image"
        case .memoryTool:    toolName = block.kind.isQuestionCardTool ? "ask_user" : "memory"
        case .text, .thinking, .info: toolName = "unknown"
        }

        // Pretty-print the input JSON when possible; otherwise emit raw.
        let inputBlock: String
        if let raw = block.toolInputArgs, !raw.isEmpty {
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: pretty, encoding: .utf8) {
                inputBlock = prettyStr
            } else {
                inputBlock = raw
            }
        } else {
            inputBlock = "(no input captured)"
        }

        // Result text: prefer the live block content, fall back to the
        // snapshot text matched by toolUseId.
        var resultText = block.content
        if resultText.isEmpty, let tuId = block.toolUseId,
           let snap = toolSnapshots.first(where: { $0.id == tuId }) {
            resultText = snap.snapshot.text ?? ""
        }
        let hasScreenshot = block.imageFilePath != nil
            || (block.toolUseId.flatMap { tuId in toolSnapshots.first(where: { $0.id == tuId }) }?.snapshot.type == .image)

        // Status string.
        let statusStr: String
        switch block.toolStatus {
        case .success:   statusStr = "success"
        case .failed:    statusStr = "failed"
        case .cancelled: statusStr = "cancelled"
        case .running:   statusStr = "running"
        case .streaming: statusStr = "streaming"
        case .none:      statusStr = "unknown"
        }

        var resultMeta = "(\(resultText.count) chars, \(statusStr)"
        if hasScreenshot { resultMeta += ", screenshot" }
        resultMeta += ")"

        return """
        ## Tool Call
        name: \(toolName)
        id: \(block.toolUseId ?? "(none)")
        input:
        \(inputBlock)

        ## Tool Result
        \(resultMeta)
        \(resultText)
        """
    }

    private var isStreaming: Bool {
        if case .streaming = block.toolStatus { return true }
        return false
    }

    private var isActive: Bool {
        switch block.toolStatus {
        case .streaming, .running: return true
        default: return false
        }
    }

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                // Status indicator / icon
                statusOrIcon

                // Description text with bouncing dots during streaming
                HStack(spacing: 0) {
                    ChatShimmerText(
                        text: displayText,
                        font: .system(size: 13, weight: .medium),
                        color: ChatColors.secondaryText,
                        isActive: isActive,
                        usesIntrinsicWidth: false
                    )
                    if isStreaming {
                        ForEach(0..<3, id: \.self) { i in
                            Text(".")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ChatColors.secondaryText)
                                .offset(y: dotsActive ? -2 : 1)
                                .animation(
                                    .easeInOut(duration: 0.35)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(i) * 0.12),
                                    value: dotsActive
                                )
                        }
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(-1)

                // Execution duration (shown after completion). The HH:mm:ss
                // start time is surfaced inside the detail view's bottom bar
                // (ToolLiveSheet.bottomBar) instead of here — the inline
                // tool-step list stays clean.
                if let dur = durationText {
                    Text(dur)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }

                // Stop button for running commands
                if case .running = block.toolStatus {
                    Button {
                        onStop?()
                    } label: {
                        // Visual: 10×10 blue square. Hit area enlarged to
                        // 24×24 via an expanded contentShape, while the negative
                        // padding pins the *layout* footprint back to 18×18 so the
                        // capsule width/height is identical to before.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .padding(-3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Stop tool"))
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 36)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(toolAccessibilityLabel)
            .onTapGesture {
                detailBlock = block
            }
            .contextMenu {
                // [T-ios-msg-contextmenu-recursion-crash] Gate the eager menu
                // tree behind an Equatable key so this tool cell's body churn
                // during `gh`/shell streaming doesn't rebuild + re-diff the menu
                // subtree every frame (part of the deep ContextMenuModifier
                // recursion in incident 98E8805F). `toolDetailsClipboard` is read
                // lazily at TAP time, so the key only tracks structure: the tool
                // (blockId) and whether the Re-run branch is shown (isProcessing).
                EquatableMenuGate(key: ToolMenuKey(
                    blockId: block.id,
                    isProcessing: vm.isProcessing,
                    hasCopyScreenshot: onCopyScreenshot != nil
                )) {
                    // [T-ios-tool-bubble-longpress-menu]
                    Button {
                        UIPasteboard.general.string = toolDetailsClipboard
                    } label: {
                        Label(String(localized: "Copy Tool Details"), systemImage: "doc.on.doc")
                    }
                    if let onCopyScreenshot {
                        Button(action: onCopyScreenshot) {
                            Label(String(localized: "Copy Screenshot"), systemImage: "photo.on.rectangle")
                        }
                    }
                    // [T-ios-retry-hide-when-processing] Only expose the
                    // destructive Re-run action when the agent loop is idle.
                    // Re-running mid-stream would tear down an in-flight turn
                    // and confuse downstream state — hide both the divider and
                    // the button as a group so the menu doesn't leave a
                    // trailing separator with nothing under it.
                    if !vm.isProcessing {
                        Divider()
                        Button(role: .destructive) {
                            // Re-run the whole assistant turn that owns this
                            // tool_use. Routed via notification so we don't have
                            // to thread a vm closure through the 4-layer cell
                            // hosting chain — AIChatView's RerunFromToolBlockListener
                            // maps blockId → owning assistant msg → preceding user
                            // msg → vm.retryFromMessage.
                            NotificationCenter.default.post(
                                name: .rerunFromToolBlock,
                                object: nil,
                                userInfo: ["blockId": block.id]
                            )
                        } label: {
                            Label(String(localized: "Re-run From Here"), systemImage: "arrow.clockwise")
                        }
                    }
                }
                .equatable()
            }
            // [T-tool-bg-suspended-hint] Yellow ⓘ just outside the capsule's
            // trailing edge when this tool was likely suspended by the OS in the
            // background. Tapping shows an alert offering to enable enhanced
            // background (deep-links to Settings → Permissions → Background).
            if showBgSuspendedHint {
                Button {
                    showBgHintAlert = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .accessibilityLabel(Text(String(localized: "Background suspension info")))
            }
            Spacer(minLength: 0)
        }
        .alert(
            String(localized: "Task may have been paused"),
            isPresented: $showBgHintAlert
        ) {
            Button(String(localized: "Go Enable")) {
                // Deep-link to Settings → Permissions → Background, nudging the
                // recommended rows ON — they highlight only while still OFF
                // (= ze://settings/background?focus=…:true,…:true). Location
                // Tracking is included so the background heartbeat that keeps the
                // task Live Activity refreshing in real time gets enabled too.
                DeepLinkCoordinator.shared.setFocus(
                    rawQueryValue: "enhancedBackgroundExecution:true,backgroundSpeakEnabled:true,locationTrackingEnabled:true")
                DeepLinkCoordinator.shared.pendingSettingsTarget = .background
            }
            Button(String(localized: "Maybe Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "This tool may have been paused by the system while running in the background. Enable enhanced background execution to improve background task reliability."))
        }
        .onChange(of: isStreaming) { streaming in
            dotsActive = streaming
        }
        .onAppear {
            if isStreaming {
                dotsActive = true
            }
        }
    }

    // MARK: - Status / Icon

    @ViewBuilder
    private var statusOrIcon: some View {
        Image(systemName: icon)
            .font(.system(size: 13))
            .foregroundStyle(iconColor)
    }

    private var iconColor: Color {
        switch block.toolStatus {
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .yellow
        default: return accentColor
        }
    }

    private var toolAccessibilityLabel: String {
        let state: String
        switch block.toolStatus {
        case .running, .streaming: state = String(localized: "in progress")
        case .success: state = String(localized: "completed")
        case .failed: state = String(localized: "failed")
        case .cancelled: state = String(localized: "cancelled")
        case .none: state = String(localized: "pending")
        }
        if let durationText { return "\(displayText), \(state), \(durationText)" }
        return "\(displayText), \(state)"
    }

    /// Formatted execution duration (e.g. "1.2s", "45s", "2m 10s").
    private var durationText: String? {
        guard let dur = block.toolDuration else { return nil }
        if dur < 1 { return String(format: "%.1fs", dur) }
        if dur < 60 { return String(format: "%.0fs", dur) }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return "\(mins)m \(secs)s"
    }

}



extension Notification.Name {
    static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled")
    /// Posted whenever a question card changes height (collapse, answer history,
    /// current question, or terminal status). The collection list clears both
    /// layout and cell measurement caches before remeasuring the block.
    static let questionCardToggled = Notification.Name("questionCardToggled")
    /// Posted when a long-press selection menu's "Add to Chat Input" action
    /// fires. userInfo["text"] is the selected text to append. The active
    /// chat's AIChatView listens and forwards to `vm.appendToInputText`.
    static let chatInputAppendRequested = Notification.Name("chatInputAppendRequested")
    /// Posted when an inline media attachment (image / video thumbnail /
    /// audio waveform) finishes async loading and its intrinsic content
    /// size changes. The collection view listens and invalidates self-sizing
    /// caches so cells re-measure. notification.object is the source URL
    /// string (for logging only — handler invalidates all visible cells).
    /// [T-attachment-size-invalidate 2026-05-21]
    static let zeAttachmentSizeChanged = Notification.Name("zeAttachmentSizeChanged")
    /// Posted from a tool capsule's long-press menu "Re-run from here".
    /// userInfo["blockId"] is the AssistantBlock.id (UUID) of the tapped
    /// tool_use. The active AIChatView listens, maps the block to its
    /// owning assistant message, finds the preceding user message, and
    /// re-runs the agent loop from there. [T-ios-tool-bubble-longpress-menu]
    static let rerunFromToolBlock = Notification.Name("rerunFromToolBlock")
}

/// Listens for `.rerunFromToolBlock` and drives the re-run. Extracted into
/// its own ViewModifier (like ChatInputAppendListener) to keep AIChatView's
/// body within the Swift type-checker budget. [T-ios-tool-bubble-longpress-menu]
///
/// "Re-run from here" semantics (block boundary —
/// T-ios-rerun-from-tool-block-position): re-run from the exact point this
/// tool_use was about to be issued. retryFromToolBlock keeps the blocks
/// BEFORE the target tool_use within its assistant turn, drops the target
/// block + later blocks in that turn + all later messages (rewriting the
/// trimmed assistant row in the DB), then re-runs the agent loop. If the
/// target is the first block with nothing preceding it, that path degrades
/// to a preceding-user-message truncation automatically.
struct RerunFromToolBlockListener: ViewModifier {
    let vm: AIChatViewModel

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .rerunFromToolBlock)) { note in
            guard let blockId = note.userInfo?["blockId"] as? UUID else { return }
            vm.retryFromToolBlock(blockId: blockId)
            vm.forceScrollToBottom.send()
        }
    }
}

/// View-modifier wrapper around the `chatInputAppendRequested` listener.
/// Extracted out of AIChatView.body because that body sits at the Swift
/// type-checker's expression budget and inlining another `.onReceive` block
/// trips the "compiler unable to type-check this expression in reasonable
/// time" diagnostic.
/// Listens for `.dismissAllImmersivePresentations` and calls the host
/// view's clear method. Extracted into its own modifier so AIChatView's
/// body type stays demangleable — adding the onReceive directly to body
/// trips the Swift type-checker timeout (same class of issue as the
/// 2026-04-17 inputBar / 2026-05-24 attachmentMenu blow-ups).
struct DismissImmersiveCoversListener: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .dismissAllImmersivePresentations)) { _ in
            onDismiss()
        }
    }
}

struct ChatInputAppendListener: ViewModifier {
    let vm: AIChatViewModel
    @Binding var inputFocused: Bool

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .chatInputAppendRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            vm.appendToInputText(text)
            // Focus the composer + pop the keyboard so the user can
            // immediately continue typing after a long-press → Add to Chat
            // Input. Independent of the post-reply auto-pop Settings
            // toggle (#354 / eb6d8164) — that gate is for *passive*
            // moments (reply finished, scroll, etc.); this is a direct
            // user gesture and should always focus. (T-add-to-input-focus)
            //
            // Async hop so the inputText `didSet` settles into the
            // composer's TextField before the focus binding flips —
            // without it the keyboard occasionally pops first and the
            // text appears mid-animation.
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }
}


// MARK: - Interactive question card

/// Light-blue visual language shared by the in-chat question card and the
/// read-only detail preview shown in Ze 主机.
enum QuestionCardTheme {
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.50, green: 0.72, blue: 1.00, alpha: 1)
            : UIColor(red: 0.165, green: 0.388, blue: 0.847, alpha: 1)
    })
    static let accentBright = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.80, blue: 1.00, alpha: 1)
            : UIColor(red: 0.33, green: 0.55, blue: 0.95, alpha: 1)
    })
    static let accentDeep = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.28, green: 0.52, blue: 0.88, alpha: 1)
            : UIColor(red: 0.12, green: 0.31, blue: 0.72, alpha: 1)
    })
    static let positive = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.31, green: 0.83, blue: 0.66, alpha: 1)
            : UIColor(red: 0.04, green: 0.50, blue: 0.38, alpha: 1)
    })
    static let warning = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.71, blue: 0.33, alpha: 1)
            : UIColor(red: 0.62, green: 0.35, blue: 0.00, alpha: 1)
    })
    static let cardTop = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.106, blue: 0.176, alpha: 1)
            : UIColor(red: 0.969, green: 0.984, blue: 1.000, alpha: 1)
    })
    static let cardBottom = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.035, green: 0.071, blue: 0.129, alpha: 1)
            : UIColor(red: 0.910, green: 0.949, blue: 1.000, alpha: 1)
    })
    static let cardBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.114, green: 0.220, blue: 0.337, alpha: 1)
            : UIColor(red: 0.812, green: 0.890, blue: 0.988, alpha: 1)
    })
    static let row = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.071, green: 0.133, blue: 0.220, alpha: 1)
            : UIColor.white
    })
    static let rowBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.125, green: 0.231, blue: 0.345, alpha: 1)
            : UIColor(red: 0.859, green: 0.918, blue: 0.988, alpha: 1)
    })
    static let selectedRow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.078, green: 0.204, blue: 0.361, alpha: 1)
            : UIColor(red: 0.898, green: 0.945, blue: 1.000, alpha: 1)
    })
    static let selectedBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.243, green: 0.435, blue: 0.659, alpha: 1)
            : UIColor(red: 0.529, green: 0.718, blue: 1.000, alpha: 1)
    })
    static let field = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.059, green: 0.118, blue: 0.196, alpha: 1)
            : UIColor.white
    })
    static let fieldBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.137, green: 0.251, blue: 0.369, alpha: 1)
            : UIColor(red: 0.831, green: 0.898, blue: 0.980, alpha: 1)
    })
    static let buttonTop = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.220, green: 0.430, blue: 0.840, alpha: 1)
            : UIColor(red: 0.180, green: 0.420, blue: 0.859, alpha: 1)
    })
    static let buttonBottom = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.140, green: 0.300, blue: 0.680, alpha: 1)
            : UIColor(red: 0.122, green: 0.322, blue: 0.761, alpha: 1)
    })
    static let shadow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 0.32)
            : UIColor(red: 0.16, green: 0.38, blue: 0.72, alpha: 0.10)
    })
    static let primaryText = Color(UIColor.label)
    static let secondaryText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.659, green: 0.702, blue: 0.761, alpha: 1)
            : UIColor(red: 0.361, green: 0.388, blue: 0.435, alpha: 1)
    })
    static let tertiaryText = Color(UIColor.tertiaryLabel)
    static let radioBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.435, green: 0.478, blue: 0.533, alpha: 1)
            : UIColor(red: 0.549, green: 0.580, blue: 0.624, alpha: 1)
    })

    static let radius: CGFloat = 22
    static let innerRadius: CGFloat = 14
    static let hairline: CGFloat = 0.8
}

extension QuestionCardStatus {
    var iconName: String {
        switch self {
        case .pending: return "questionmark"
        case .confirmed: return "checkmark"
        case .unconfirmed: return "minus"
        }
    }

    var tint: Color {
        switch self {
        case .pending: return QuestionCardTheme.accent
        case .confirmed: return QuestionCardTheme.positive
        case .unconfirmed: return QuestionCardTheme.warning
        }
    }
}

/// Segmented progress used by both the chat card and the host preview.
struct QuestionCardProgressBar: View {
    let card: QuestionCardState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int { max(card.questions.count, 1) }

    private var completed: Int {
        switch card.status {
        case .pending:
            return min(max(card.currentIndex + 1, 1), total)
        case .confirmed:
            return total
        case .unconfirmed:
            return max(card.answeredCount, 0)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index < completed ? QuestionCardTheme.accent : QuestionCardTheme.accent.opacity(0.12))
                    .frame(height: 3)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: completed)
        .accessibilityHidden(true)
    }
}

struct QuestionCardRadio: View {
    let selected: Bool
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(selected ? QuestionCardTheme.accent : Color.clear)
            Circle()
                .strokeBorder(
                    selected ? QuestionCardTheme.accent : QuestionCardTheme.radioBorder,
                    lineWidth: 1.6
                )
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(Color.white)
                .opacity(selected ? 1 : 0)
                .scaleEffect(selected ? 1 : 0.5)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72), value: selected)
        .accessibilityHidden(true)
    }
}

struct QuestionCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct QuestionCardStatusBadge: View {
    let status: QuestionCardStatus
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(status.tint.opacity(0.12))
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .stroke(status.tint.opacity(0.18), lineWidth: 1)
            Image(systemName: status.iconName)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(status.tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
private struct QuestionCardView: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var speech: SpeechRecognitionManager
    @State private var draft = ""
    @State private var selectedOptionIndex: Int?
    @State private var isSubmitting = false
    @State private var requestIsLive = true
    @State private var pendingSubmit: Task<Void, Never>?
    @FocusState private var answerFieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(block: AssistantBlock) {
        self.block = block
        _speech = ObservedObject(wrappedValue: SpeechRecognitionManager.shared)
    }

    var body: some View {
        Group {
            if let card = block.questionCard {
                cardContainer(card)
            }
        }
        .task(id: block.questionCard?.requestId) {
            guard let card = block.questionCard else { return }
            await monitorLiveness(card)
        }
        .onChange(of: block.questionCard) { newValue in
            guard let newValue else { return }
            if newValue.status != .pending {
                pendingSubmit?.cancel()
                stopVoiceIfNeeded()
                draft = ""
                selectedOptionIndex = nil
                answerFieldFocused = false
                requestIsLive = true
                // Collapse from the view, not only from the coordinator: the
                // coordinator's block reference is weak and can be stale after
                // a session reload, which used to leave the card expanded.
                setExpanded(false, haptic: false)
            } else if QuestionCardCoordinator.shared.isPending(requestId: newValue.requestId) {
                requestIsLive = true
            }
        }
    }

    private func cardContainer(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(card)
            if block.isQuestionCardExpanded {
                expandedContent(card)
                    .padding(.top, 14)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .padding(16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous)
                .stroke(QuestionCardTheme.cardBorder, lineWidth: QuestionCardTheme.hairline)
        }
        .shadow(color: QuestionCardTheme.shadow, radius: 18, x: 0, y: 10)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86),
                   value: block.isQuestionCardExpanded)
        .onChange(of: speech.recognizedText) { text in
            if speech.state == .recording {
                draft = text
            }
        }
        .onChange(of: block.questionCard?.requestId) { _ in
            requestIsLive = true
            draft = ""
            selectedOptionIndex = nil
            answerFieldFocused = false
        }
        .onChange(of: block.questionCard?.currentIndex) { _ in
            draft = ""
            selectedOptionIndex = nil
            answerFieldFocused = false
        }
        .onChange(of: draft) { value in
            guard let question = card.currentQuestion,
                  let index = selectedOptionIndex,
                  question.options.indices.contains(index) else { return }
            if question.options[index] != value {
                selectedOptionIndex = nil
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous)
            .fill(LinearGradient(
                colors: [QuestionCardTheme.cardTop, QuestionCardTheme.cardBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                RadialGradient(
                    colors: [QuestionCardTheme.accent.opacity(0.10), Color.clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 240
                )
                .clipShape(RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous))
            }
    }

    // MARK: Header

    private func cardHeader(_ card: QuestionCardState) -> some View {
        Button {
            setExpanded(!block.isQuestionCardExpanded, haptic: true)
        } label: {
            HStack(alignment: .top, spacing: 11) {
                QuestionCardStatusBadge(status: card.status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.displayQuestion)
                        .font(.headline)
                        .foregroundStyle(QuestionCardTheme.primaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(block.isQuestionCardExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Text(headerSubtitle(card))
                        .font(.caption)
                        .foregroundStyle(
                            card.status == .pending && !isRequestLive
                                ? QuestionCardTheme.warning
                                : card.status.tint
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                chevron
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(QuestionCardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(card.displayQuestion))
        .accessibilityValue(Text("\(headerSubtitle(card)), \(card.progressText)"))
        .accessibilityHint(Text(
            block.isQuestionCardExpanded
                ? String(localized: "Collapse question card")
                : String(localized: "Expand question card")
        ))
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(QuestionCardTheme.secondaryText)
            .rotationEffect(.degrees(block.isQuestionCardExpanded ? 180 : 0))
            .frame(width: 28, height: 28)
            .background(Circle().fill(QuestionCardTheme.accent.opacity(0.07)))
            .padding(.top, 4)
            .fixedSize()
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82),
                       value: block.isQuestionCardExpanded)
    }

    private func headerSubtitle(_ card: QuestionCardState) -> String {
        if card.status == .pending, !isRequestLive {
            return String(localized: "This question has expired.")
        }
        switch card.status {
        case .pending:
            if card.questions.count > 1 {
                return "\(card.progressText) · \(card.statusLabel)"
            }
            return card.statusLabel
        case .confirmed:
            // A multi-question card summarises by count: joining every answer
            // produced a single truncated line like
            // "Answered · free 生图/gpt-image-2（默认 · 2…" that said less than
            // the rows below it.
            if card.questions.count > 1 {
                return "\(card.statusLabel) · \(card.answeredCount)/\(card.questions.count)"
            }
            if let preview = card.answerPreview {
                return "\(card.statusLabel) · \(preview)"
            }
            return card.statusLabel
        case .unconfirmed:
            return card.statusLabel
        }
    }

    private func setExpanded(_ expanded: Bool, haptic: Bool) {
        guard block.isQuestionCardExpanded != expanded else { return }
        if !expanded {
            answerFieldFocused = false
            stopVoiceIfNeeded()
        }
        if haptic {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        if reduceMotion {
            block.isQuestionCardExpanded = expanded
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                block.isQuestionCardExpanded = expanded
            }
        }
        if let card = block.questionCard {
            QuestionCardExpansionStore.setExpanded(expanded, for: card.requestId, status: card.status)
        }
        // The collection view's handler reconfigures a diffable snapshot.
        // Posting synchronously from an `onChange` would mutate the data
        // source inside SwiftUI's update pass, so hand it to the next tick.
        let blockId = block.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .questionCardToggled, object: blockId)
        }
    }

    // MARK: Expanded content

    @ViewBuilder
    private func expandedContent(_ card: QuestionCardState) -> some View {
        if card.status == .pending {
            pendingContent(card)
        } else {
            resolvedContent(card)
        }
    }

    private func pendingContent(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if card.questions.count > 1 {
                QuestionCardProgressBar(card: card)
            }
            if let question = card.currentQuestion {
                if !question.options.isEmpty {
                    optionsList(question)
                        .allowsHitTesting(isRequestLive)
                        .opacity(isRequestLive ? 1 : 0.62)
                }
                if isRequestLive {
                    answerField
                    primaryAction(card)
                    leaveUnconfirmedButton(card)
                } else {
                    expiredNotice
                }
            }
        }
    }

    private func optionsList(_ question: QuestionCardQuestion) -> some View {
        VStack(spacing: 8) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionRow(option, index: index)
            }
        }
    }

    private func optionRow(_ option: String, index: Int) -> some View {
        let selected = selectedOptionIndex == index
        return Button {
            chooseOption(option, index: index)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                QuestionCardRadio(selected: selected, size: 20)
                    .padding(.top, 1)
                Text(option)
                    .font(.callout.weight(selected ? .medium : .regular))
                    .foregroundStyle(QuestionCardTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .frame(minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                    .fill(selected ? QuestionCardTheme.selectedRow : QuestionCardTheme.row)
            )
            .overlay {
                RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                    .stroke(
                        selected ? QuestionCardTheme.selectedBorder : QuestionCardTheme.rowBorder,
                        lineWidth: selected ? 1.2 : QuestionCardTheme.hairline
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous))
        }
        .buttonStyle(QuestionCardPressStyle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option))
        .accessibilityHint(Text(
            isRequestLive
                ? String(localized: "Answer")
                : String(localized: "This question has expired.")
        ))
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private func chooseOption(_ option: String, index: Int) {
        guard isRequestLive, !isSubmitting, block.questionCard?.status == .pending else { return }
        answerFieldFocused = false
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            selectedOptionIndex = index
            draft = option
        }
        // Selecting an option is the answer: submit after the radio animation
        // has been seen. This is what makes the card collapse on tap instead
        // of waiting for a second "Submit" press.
        pendingSubmit?.cancel()
        pendingSubmit = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            guard !Task.isCancelled, block.isQuestionCardExpanded else { return }
            submitCurrentAnswer()
        }
    }

    private var answerField: some View {
        HStack(spacing: 10) {
            TextField(String(localized: "Your answer"), text: $draft)
                .font(.callout)
                .foregroundStyle(QuestionCardTheme.primaryText)
                .focused($answerFieldFocused)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit { submitCurrentAnswer() }
            Button {
                toggleRecording()
            } label: {
                Image(systemName: speech.state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(speech.state == .recording ? Color.white : QuestionCardTheme.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(
                            speech.state == .recording
                                ? Color.red
                                : QuestionCardTheme.accent.opacity(0.10)
                        )
                    )
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(QuestionCardPressStyle())
            .accessibilityLabel(Text(
                speech.state == .recording
                    ? String(localized: "Stop voice answer")
                    : String(localized: "Answer by voice")
            ))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                .fill(QuestionCardTheme.field)
        )
        .overlay {
            RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                .stroke(
                    answerFieldFocused
                        ? QuestionCardTheme.accent.opacity(0.55)
                        : QuestionCardTheme.fieldBorder,
                    lineWidth: answerFieldFocused ? 1.4 : 1
                )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: answerFieldFocused)
    }

    private func primaryAction(_ card: QuestionCardState) -> some View {
        let isLast = card.currentIndex + 1 >= card.questions.count
        let canSubmit = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
        return Button {
            submitCurrentAnswer()
        } label: {
            HStack(spacing: 7) {
                Text(isLast ? String(localized: "Submit") : String(localized: "Next"))
                Image(systemName: isLast ? "checkmark" : "arrow.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [QuestionCardTheme.buttonTop, QuestionCardTheme.buttonBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            )
        }
        .buttonStyle(QuestionCardPressStyle())
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1 : 0.42)
        .shadow(color: canSubmit ? QuestionCardTheme.accent.opacity(0.22) : Color.clear,
                radius: 10, x: 0, y: 5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: canSubmit)
    }

    private func leaveUnconfirmedButton(_ card: QuestionCardState) -> some View {
        HStack {
            Spacer()
            Button {
                answerFieldFocused = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                var updated = card
                updated.status = .unconfirmed
                block.questionCard = updated
                block.content = updated.summaryText
                block.toolSummary = updated.chromeTitle
                setExpanded(false, haptic: false)
                QuestionCardCoordinator.shared.submitUnconfirmed(requestId: card.requestId)
            } label: {
                Text(String(localized: "Leave unconfirmed"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(QuestionCardTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var expiredNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(QuestionCardTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "This question has expired."))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(QuestionCardTheme.primaryText)
                Text(String(localized: "It was restored from an earlier session and can no longer be answered."))
                    .font(.caption)
                    .foregroundStyle(QuestionCardTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(QuestionCardTheme.warning.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(QuestionCardTheme.warning.opacity(0.14), lineWidth: QuestionCardTheme.hairline)
        }
    }

    private var isRequestLive: Bool {
        guard let card = block.questionCard, card.status == .pending else { return true }
        return requestIsLive
    }

    private func monitorLiveness(_ card: QuestionCardState) async {
        guard card.status == .pending else {
            requestIsLive = true
            return
        }
        // The coordinator registers a request a beat after the tool block is
        // created. Re-check a few times instead of flashing "expired" during
        // that window; a restored orphan card settles on the final check.
        var live = false
        for delay in [200_000_000, 600_000_000, 1_500_000_000] as [UInt64] {
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            live = QuestionCardCoordinator.shared.isPending(requestId: card.requestId)
            requestIsLive = live
            if live { break }
        }
        guard live else { return }
        // A live card can still time out (or be resolved from a notification)
        // long after the first checks. A slow heartbeat disables the controls
        // even when the coordinator's weak block reference was replaced and
        // its own layout notification never reached this view.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            guard block.questionCard?.status == .pending else { return }
            let stillPending = QuestionCardCoordinator.shared.isPending(requestId: card.requestId)
            requestIsLive = stillPending
            if !stillPending { return }
        }
    }

    private func submitCurrentAnswer() {
        guard let card = block.questionCard, card.status == .pending, !isSubmitting else { return }
        let answer = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        guard QuestionCardCoordinator.shared.isPending(requestId: card.requestId) else {
            requestIsLive = false
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        let isLast = card.currentIndex + 1 >= card.questions.count
        if isLast {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UISelectionFeedbackGenerator().selectionChanged()
        }

        isSubmitting = true
        answerFieldFocused = false
        stopVoiceIfNeeded()

        // Apply the answer locally as well. `QuestionCardCoordinator` keeps a
        // weak block reference; if a reload replaced the block, the local copy
        // must still advance or collapse instead of looking inert.
        var updated = card
        if updated.answers.count < updated.questions.count {
            updated.answers += Array(repeating: nil, count: updated.questions.count - updated.answers.count)
        }
        if updated.answers.indices.contains(updated.currentIndex) {
            updated.answers[updated.currentIndex] = answer
        }
        if isLast {
            updated.status = .confirmed
            block.questionCard = updated
            block.content = updated.summaryText
            block.toolSummary = updated.chromeTitle
            setExpanded(false, haptic: false)
        } else {
            updated.currentIndex = min(updated.currentIndex + 1, updated.questions.count - 1)
            block.questionCard = updated
            block.content = updated.summaryText
            block.toolSummary = updated.chromeTitle
        }

        QuestionCardCoordinator.shared.submitAnswer(requestId: card.requestId, answer: answer)
        isSubmitting = false
        draft = ""
        selectedOptionIndex = nil
    }

    // MARK: Resolved

    private func resolvedContent(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if card.status == .unconfirmed {
                unconfirmedNote
            }
            if card.status == .confirmed || card.answeredCount > 0 || card.questions.count > 1 {
                if card.questions.count > 1 {
                    answerSheet(card)
                } else if !card.questions.isEmpty {
                    // A single answer needs no second border inside the card;
                    // the header already states the question.
                    resolvedQuestionRow(card, index: 0)
                }
            }
        }
    }

    /// One quiet sheet with hairline dividers instead of a stack of nested
    /// cards: each answer is a line of text, not a panel of its own.
    private func answerSheet(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(card.questions.indices, id: \.self) { index in
                if index > 0 {
                    Rectangle()
                        .fill(QuestionCardTheme.rowBorder)
                        .frame(height: QuestionCardTheme.hairline)
                        .padding(.vertical, 10)
                }
                resolvedQuestionRow(card, index: index)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                .fill(QuestionCardTheme.row)
        )
        .overlay {
            RoundedRectangle(cornerRadius: QuestionCardTheme.innerRadius, style: .continuous)
                .stroke(QuestionCardTheme.rowBorder, lineWidth: QuestionCardTheme.hairline)
        }
    }

    private var unconfirmedNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(QuestionCardTheme.warning)
            Text(String(localized: "No answer was confirmed. The assistant will not choose for you."))
                .font(.footnote)
                .foregroundStyle(QuestionCardTheme.primaryText.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(QuestionCardTheme.warning.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(QuestionCardTheme.warning.opacity(0.14), lineWidth: QuestionCardTheme.hairline)
        }
    }

    private func resolvedQuestionRow(_ card: QuestionCardState, index: Int) -> some View {
        let question = card.questions[index]
        let answer = (index < card.answers.count ? card.answers[index] : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasAnswer = !answer.isEmpty
        let showsPrompt = card.questions.count > 1

        return HStack(alignment: .top, spacing: 10) {
            // A check confirms the answer; a dash marks an unanswered row.
            // Numbers were dropped: the prompt sits right above each answer,
            // so an index only added noise.
            ZStack {
                Circle()
                    .fill(hasAnswer
                          ? QuestionCardTheme.positive.opacity(0.14)
                          : QuestionCardTheme.accent.opacity(0.06))
                Image(systemName: hasAnswer ? "checkmark" : "minus")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(hasAnswer ? QuestionCardTheme.positive : QuestionCardTheme.tertiaryText)
            }
            .frame(width: 20, height: 20)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: showsPrompt ? 3 : 0) {
                if showsPrompt {
                    Text(question.prompt)
                        .font(.caption)
                        .foregroundStyle(QuestionCardTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(hasAnswer ? answer : String(localized: "No answer"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(hasAnswer ? QuestionCardTheme.primaryText : QuestionCardTheme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Voice

    private func stopVoiceIfNeeded() {
        if speech.state == .recording {
            speech.stopRecording()
        }
    }

    private func toggleRecording() {
        if speech.state == .recording {
            speech.stopRecording()
            draft = speech.recognizedText
            return
        }
        Task { @MainActor in
            if !speech.permissionsAlreadyGranted, !(await speech.requestPermissions()) { return }
            try? speech.startRecording()
        }
    }
}

// MARK: - Question card detail (Ze 主机 preview)

/// Read-only rendering of the full card: the question, every option, the
/// chosen answer and any free-text answer. The host sheet used to show only
/// `block.content` ("Answered" / "Unconfirmed"), which hid the interaction
/// entirely.
@MainActor
struct QuestionCardDetailView: View {
    @ObservedObject var block: AssistantBlock

    private var card: QuestionCardState? {
        if let card = block.questionCard { return card }
        guard block.kind.isQuestionCardTool,
              let raw = block.toolInputArgs,
              let data = raw.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard var card = QuestionCardParser.state(
            requestId: block.toolUseId ?? "question-card-preview",
            arguments: arguments,
            timeout: 900
        ) else {
            return nil
        }
        // Legacy rows may still carry the raw tool_result JSON in `content`;
        // apply it when present so an old card opens with its answers.
        if block.content.contains("\"answers\"") || block.content.contains("\"confirmed\"") {
            QuestionCardParser.apply(resultJSON: block.content, to: &card)
        }
        return card
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let card {
                    detailHeader(card)
                    if card.status == .pending {
                        pendingDetail(card)
                    } else {
                        resolvedDetail(card)
                    }
                } else {
                    fallback
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    private func detailHeader(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                QuestionCardStatusBadge(status: card.status)
                VStack(alignment: .leading, spacing: 3) {
                    if let eyebrow = card.eyebrow {
                        Text(eyebrow)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(QuestionCardTheme.accent.opacity(0.92))
                            .lineLimit(1)
                    }
                    Text(card.displayQuestion)
                        .font(.headline)
                        .foregroundStyle(QuestionCardTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(
                        requestIsLive
                            ? "\(card.statusLabel) · \(card.progressText)"
                            : String(localized: "This question has expired.")
                    )
                    .font(.caption)
                    .foregroundStyle(requestIsLive ? card.status.tint : QuestionCardTheme.warning)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if card.questions.count > 1 {
                QuestionCardProgressBar(card: card)
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [QuestionCardTheme.cardTop, QuestionCardTheme.cardBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                RadialGradient(
                    colors: [QuestionCardTheme.accent.opacity(0.10), Color.clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 220
                )
                .clipShape(RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: QuestionCardTheme.radius, style: .continuous)
                .stroke(QuestionCardTheme.cardBorder, lineWidth: QuestionCardTheme.hairline)
        }
        .shadow(color: QuestionCardTheme.shadow, radius: 14, x: 0, y: 8)
    }

    private var requestIsLive: Bool {
        guard let card, card.status == .pending else { return true }
        return QuestionCardCoordinator.shared.isPending(requestId: card.requestId)
    }

    private func pendingDetail(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let question = card.currentQuestion {
                if !question.options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            detailOptionRow(option, selected: false)
                        }
                    }
                    .opacity(requestIsLive ? 1 : 0.62)
                }
                if requestIsLive {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(localized: "Waiting for your answer…"))
                            .font(.caption)
                    }
                    .foregroundStyle(QuestionCardTheme.secondaryText)
                    .padding(.top, 2)
                } else {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(QuestionCardTheme.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "This question has expired."))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(QuestionCardTheme.primaryText)
                            Text(String(localized: "It was restored from an earlier session and can no longer be answered."))
                                .font(.caption)
                                .foregroundStyle(QuestionCardTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(QuestionCardTheme.warning.opacity(0.08))
                    )
                }
            }
        }
    }

    private func resolvedDetail(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if card.status == .unconfirmed {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(QuestionCardTheme.warning)
                    Text(String(localized: "No answer was confirmed. The assistant will not choose for you."))
                        .font(.footnote)
                        .foregroundStyle(QuestionCardTheme.primaryText.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QuestionCardTheme.warning.opacity(0.08))
                )
            }
            if card.status == .confirmed || card.answeredCount > 0 || card.questions.count > 1 {
                ForEach(card.questions.indices, id: \.self) { index in
                    detailQuestionRow(card, index: index)
                }
            }
        }
    }

    private func detailQuestionRow(_ card: QuestionCardState, index: Int) -> some View {
        let question = card.questions[index]
        let answer = (index < card.answers.count ? card.answers[index] : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasAnswer = !answer.isEmpty
        let answerMatchesOption = hasAnswer && question.options.contains(answer)
        return VStack(alignment: .leading, spacing: 10) {
            if card.questions.count > 1 {
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(hasAnswer ? QuestionCardTheme.accent : QuestionCardTheme.secondaryText)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle().fill(
                                hasAnswer
                                    ? QuestionCardTheme.accent.opacity(0.12)
                                    : QuestionCardTheme.accent.opacity(0.05)
                            )
                        )
                    Text(question.prompt)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(QuestionCardTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        detailOptionRow(option, selected: hasAnswer && option == answer)
                    }
                }
            }
            if !answerMatchesOption {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: hasAnswer ? "text.bubble" : "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hasAnswer ? QuestionCardTheme.accent : QuestionCardTheme.tertiaryText)
                        .frame(width: 18, height: 18)
                    Text(hasAnswer ? answer : String(localized: "No answer"))
                        .font(.callout)
                        .foregroundStyle(hasAnswer ? QuestionCardTheme.primaryText : QuestionCardTheme.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hasAnswer ? QuestionCardTheme.accent.opacity(0.06) : QuestionCardTheme.row)
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(QuestionCardTheme.row)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QuestionCardTheme.rowBorder, lineWidth: QuestionCardTheme.hairline)
        }
    }

    private func detailOptionRow(_ option: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            QuestionCardRadio(selected: selected, size: 18)
                .padding(.top, 1)
            Text(option)
                .font(.callout.weight(selected ? .medium : .regular))
                .foregroundStyle(selected ? QuestionCardTheme.primaryText : QuestionCardTheme.secondaryText)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? QuestionCardTheme.selectedRow : QuestionCardTheme.row)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    selected ? QuestionCardTheme.selectedBorder : QuestionCardTheme.rowBorder,
                    lineWidth: selected ? 1.2 : QuestionCardTheme.hairline
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(option))
        .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Question card"))
                .font(.headline)
                .foregroundStyle(QuestionCardTheme.primaryText)
            Text(block.content)
                .font(.callout)
                .foregroundStyle(QuestionCardTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(QuestionCardTheme.row)
        )
    }
}

// MARK: - Thinking Block View

/// [T-thinking-stream-jank] Main-thread hitch monitor, active only while an
/// expanded thinking block is streaming. Logs frame gaps > 100ms together with
/// the current thinking length so hitches can be correlated with content size.
/// One shared instance — at most one thinking block streams at a time.
@MainActor
final class ThinkingHitchMonitor {
    static let shared = ThinkingHitchMonitor()
    private let logger = AppLogger(category: "ThinkPerf")
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// Body-eval counter since start (bumped by the view; sampled into hitch logs).
    var bodyEvalCount = 0
    var contentLenProvider: (() -> Int)?
    /// The block that started the monitor. Stops from OTHER blocks are ignored —
    /// with several thinking blocks in one chat, an older (collapsed / finished)
    /// block's task(id:) firing false must not kill the live block's monitor.
    private var ownerId: UUID?

    func start(owner: UUID) {
        if displayLink != nil {
            ownerId = owner  // live monitor adopted by the newest streaming block
            if collapsedAt != nil {
                collapsedAt = nil  // re-expanded within the grace window
                logger.info("[ThinkPerf] phase → EXPANDED (re-expand)")
            }
            return
        }
        ownerId = owner
        lastTimestamp = 0
        bodyEvalCount = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        logger.info("[ThinkPerf] hitch-monitor START owner=\(owner.uuidString.prefix(8))")
    }

    /// When the owner collapses, keep sampling for a grace window so the
    /// COLLAPSED state's frame stats can be compared A/B against EXPANDED
    /// under the same interactions. Frame lines are tagged with the phase.
    private var collapsedAt: CFTimeInterval?
    private static let collapsedGraceSeconds: CFTimeInterval = 25

    func stop(owner: UUID) {
        guard displayLink != nil, owner == ownerId else { return }
        collapsedAt = CACurrentMediaTime()
        logger.info("[ThinkPerf] phase → COLLAPSED (monitor continues \(Int(Self.collapsedGraceSeconds))s for A/B) bodyEvals=\(self.bodyEvalCount)")
    }

    private func hardStop() {
        displayLink?.invalidate()
        displayLink = nil
        ownerId = nil
        collapsedAt = nil
        logger.info("[ThinkPerf] hitch-monitor STOP bodyEvals=\(self.bodyEvalCount)")
    }

    // Per-second frame statistics: dropped-frame count (>33ms), worst gap, and
    // frame count — a per-second FPS/drop summary shows sub-100ms jank the
    // single HITCH threshold misses.
    private var statWindowStart: CFTimeInterval = 0
    private var statFrames = 0
    private var statDropped = 0
    private var statWorstMs: Double = 0

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { statWindowStart = link.timestamp; return }
        let gapMs = (link.timestamp - lastTimestamp) * 1000
        statFrames += 1
        if gapMs > 33 { statDropped += 1 }
        if gapMs > statWorstMs { statWorstMs = gapMs }
        if gapMs > 100 {
            logger.info("[ThinkPerf] HITCH gap=\(Int(gapMs))ms contentLen=\(self.contentLenProvider?() ?? -1) bodyEvals=\(self.bodyEvalCount)")
        }
        let windowDt = link.timestamp - statWindowStart
        if windowDt >= 1.0 {
            let fps = Double(statFrames) / windowDt
            let phase = collapsedAt == nil ? "EXP" : "COL"
            // [T-log-noise-privacy 2026-07-18] info → debug: per-second frame
            // stats; the HITCH lines (rare, actionable) stay at info.
            logger.debug("[ThinkPerf] [\(phase)] frames/s=\(Int(fps)) dropped=\(self.statDropped) worst=\(Int(self.statWorstMs))ms contentLen=\(self.contentLenProvider?() ?? -1) bodyEvals=\(self.bodyEvalCount)")
            statWindowStart = link.timestamp
            statFrames = 0
            statDropped = 0
            statWorstMs = 0
        }
        if let c = collapsedAt, link.timestamp - c > Self.collapsedGraceSeconds {
            hardStop()
        }
    }
}

struct ThinkingBlockView: View {
    @ObservedObject var block: AssistantBlock
    let isStreaming: Bool
    let thinkingLevel: ThinkingLevel

    /// Bind to block.isThinkingExpanded so state survives cell reuse and triggers cell re-sizing.
    private var isExpanded: Binding<Bool> {
        Binding(
            get: { block.isThinkingExpanded },
            set: { block.isThinkingExpanded = $0 }
        )
    }

    init(block: AssistantBlock, isStreaming: Bool, thinkingLevel: ThinkingLevel = .off) {
        self.block = block
        self.isStreaming = isStreaming
        self.thinkingLevel = thinkingLevel
        // Auto-expand-on-stream is handled in `.onAppear` (gated by block.id)
        // rather than from `init`. Mutating @Published from a SwiftUI view
        // initializer fires for every cell-reuse pass and was reaching the
        // wrong block when the cell was being recycled between an earlier
        // (frozen) thinking block and the currently-streaming one — manifesting
        // as "tap an old thinking block, see the streaming block's content."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChatColors.secondaryText)
                ChatShimmerText(
                    text: thinkingHeaderTitle,
                    font: .system(size: 13, weight: .semibold),
                    color: ChatColors.secondaryText,
                    isActive: isStreaming
                )
                ThinkingDurationLabel(block: block, isStreaming: isStreaming)
                if thinkingLevel.isEnabled {
                    Text(thinkingLevelCompactLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ChatColors.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(ChatColors.primaryText.opacity(0.09))
                        .clipShape(Capsule())
                        .accessibilityLabel("思考强度 \(thinkingLevelCompactLabel)")
                }
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ChatColors.secondaryText)
                }
                if block.content.count > 0 || block.thinkingContentBuffer.count > 0 {
                    let charCount = max(block.content.count, block.thinkingContentBuffer.count)
                    Text(charCount > 1000 ? "\(charCount / 1000)K" : "\(charCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ChatColors.tertiaryText)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture {
                // Mark before flipping so any concurrent stream-end collapse
                // observer in this view sees `thinkingUserToggled = true`
                // and bails out instead of stomping the user's choice.
                // The collection view's cached height is invalidated by the
                // `onChange(of: isThinkingExpanded)` observer below — single
                // source of truth so the auto-collapse path stays in sync.
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] tap block=\(block.id.uuidString.prefix(8)) wasExpanded=\(isExpanded.wrappedValue) streaming=\(isStreaming) contentLen=\(block.content.count)")
                block.thinkingUserToggled = true
                if !isExpanded.wrappedValue {
                    block.flushThinkingBuffer()
                }
                isExpanded.wrappedValue.toggle()
            }

            // Content — only visible when expanded, windowed to the tail
            // to prevent UI freeze on very long thinking (T-thinking-render-perf-ios).
            if isExpanded.wrappedValue, !block.content.isEmpty {
                let windowSize = 8000
                let total = block.content.count
                let isTruncated = total > windowSize
                let displayContent: String = {
                    // [T-thinking-stream-jank] Time the tail-window slice and count
                    // body re-evals. This closure runs on EVERY body evaluation of
                    // an expanded thinking block — if body re-evals track the
                    // per-token contentUpdateSeq rather than the 0.3s flush, the
                    // eval counter in the 1s summary exposes it directly.
                    let t0 = CFAbsoluteTimeGetCurrent()
                    defer {
                        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                        ThinkingHitchMonitor.shared.bodyEvalCount += 1
                        if ms > 4 {
                            AppLogger(category: "ThinkPerf").info("[ThinkPerf] slice SLOW total=\(total) took=\(String(format: "%.1f", ms))ms eval#\(ThinkingHitchMonitor.shared.bodyEvalCount)")
                        }
                    }
                    guard isTruncated else { return block.content }
                    let startIdx = block.content.index(block.content.endIndex, offsetBy: -windowSize)
                    let cleanStart = block.content[startIdx...].firstIndex(of: "\n")
                        .map { block.content.index(after: $0) } ?? startIdx
                    return String(block.content[cleanStart...])
                }()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if isTruncated {
                                Text("仅显示最后 \(displayContent.count / 1000)K / \(total / 1000)K 个字符", comment: "Thinking window truncation hint")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 4)
                            }
                            ThinkingContentText(
                                text: displayContent,
                                isStreaming: isStreaming
                            )
                                .textSelection(.enabled)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 10)
                                .id("thinkingBottom")
                        }
                    }
                    .frame(maxHeight: 300)
                    // [T-thinking-stream-jank] Follow the tail at FLUSH pace
                    // (content updates every 0.3s), not per token. The old
                    // trigger was the per-delta contentUpdateSeq — with it
                    // @Published, an expanded block re-ran body + an animated
                    // scrollTo for every delta (~60-105/s measured); the flush
                    // pace is ~3-4/s for the same visual result.
                    .onChange(of: block.content.count) { len in
                        guard isStreaming else { return }
                        AppLogger(category: "ThinkPerf").debug("[ThinkPerf] scrollTo(flush) contentLen=\(len) seq=\(block.contentUpdateSeq)")
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo("thinkingBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        // [T-thinking-stream-jank] Hitch monitor runs while this block is
        // EXPANDED — streaming or static. The refined report says the jank is
        // tied to the expanded state itself (collapse instantly recovers), so
        // the monitor must also capture expanded-static interactions (list
        // scrolling, new messages arriving) to compare against collapsed.
        .task(id: isExpanded.wrappedValue) {
            if isExpanded.wrappedValue {
                ThinkingHitchMonitor.shared.contentLenProvider = { [weak block] in
                    block?.thinkingContentBuffer.count ?? -1
                }
                ThinkingHitchMonitor.shared.start(owner: block.id)
            } else {
                ThinkingHitchMonitor.shared.stop(owner: block.id)
            }
        }
        .onDisappear {
            ThinkingHitchMonitor.shared.stop(owner: block.id)
        }
        .task(id: block.id) {
            // One-shot per-block auto-expand. Runs when this cell first hosts
            // a given thinking block (block.id is stable across content
            // updates) and only flips state if the user hasn't taken control.
            // [T-thinking-auto-expand-toggle] Gated on the Appearance setting
            // (default ON = historical behavior). When the user turned it off,
            // new streaming thinking blocks stay collapsed; a manual tap still
            // expands them (and sets thinkingUserToggled, so nothing here
            // fights the user either way).
            let autoExpand = (UserDefaults.standard.object(forKey: "chat.autoExpandThinking") as? Bool) ?? true
            if autoExpand, isStreaming, !block.thinkingUserToggled, !block.isThinkingExpanded {
                block.isThinkingExpanded = true
            }
        }
        .onChange(of: isStreaming) { streaming in
            // Auto-collapse when streaming for THIS block ends, but only if
            // the user hasn't manually toggled it. Without the user-touched
            // gate, the streaming-end transition stomped a tap the user did
            // on an earlier thinking block while a later one was still live.
            if !streaming, !block.thinkingUserToggled {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] auto-collapse block=\(block.id.uuidString.prefix(8)) streaming→false userToggled=false contentLen=\(block.content.count)")
                block.isThinkingExpanded = false
            } else if !streaming {
                AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] stream-end-skip block=\(block.id.uuidString.prefix(8)) userToggled=\(block.thinkingUserToggled) currentlyExpanded=\(block.isThinkingExpanded)")
            }
        }
        .onChange(of: block.isThinkingExpanded) { newValue in
            // Single source of truth for cell-height invalidation: fires
            // for BOTH manual taps and the stream-end auto-collapse path
            // above. Previously only the tap gesture posted this, so when
            // a long thinking block auto-collapsed at stream end, the
            // UICollectionView kept the expanded cell height (~300pt) and
            // rendered a tall empty gap below the pill — see 2026-05-17
            // screenshot bug.
            AppLogger(category: "ThinkingCollapse").info("[ThinkingCollapse] post block=\(block.id.uuidString.prefix(8)) expanded=\(newValue) userToggled=\(block.thinkingUserToggled) streaming=\(isStreaming)")
            NotificationCenter.default.post(name: .thinkingBlockToggled,
                                            object: block.id)
        }
    }

    private var thinkingLevelCompactLabel: String {
        switch thinkingLevel {
        case .off: return ""
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "超高"
        case .max: return "最高"
        case .ultra: return "极限"
        }
    }

    private var thinkingHeaderTitle: String {
        isStreaming ? "思考中" : "思考了"
    }
}

/// Live elapsed label for a thinking block; finished blocks use the frozen
/// duration so collapsed rows remain stable and cheap to render.
private struct ThinkingDurationLabel: View {
    @ObservedObject var block: AssistantBlock
    let isStreaming: Bool

    var body: some View {
        if let duration = block.thinkingDuration {
            Text(Self.format(duration))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(ChatColors.secondaryText)
        } else if isStreaming, let start = block.thinkingStartTime {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(Self.format(max(0, timeline.date.timeIntervalSince(start))))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChatColors.secondaryText)
            }
        } else {
            Text("0s")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(ChatColors.secondaryText)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let remaining = total % 60
        return remaining == 0 ? "\(minutes)m" : "\(minutes)m \(remaining)s"
    }
}

// MARK: - Typing Indicator

/// A compact 60 FPS jelly glyph. The footprint stays square so the shape
/// morphs from a circle into a rounded square instead of stretching into a
/// pill. Each morph transition makes one complete turn, keeping both directions of
/// the morph visually connected while invalidating only this tiny view.
private struct JellyThinkingGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()

    private let size: CGFloat = 12
    private let transitionDuration: TimeInterval = 0.675
    private let holdDuration: TimeInterval = 0.25

    private var cycleDuration: TimeInterval {
        transitionDuration * 2 + holdDuration * 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let state = reduceMotion
                ? (morphPhase: CGFloat(0), rotationDegrees: 0.0)
                : animationState(at: timeline.date)
            let phase = state.morphPhase
            // 0 and 1 are circles; 0.5 is a rounded square. The icon holds
            // each endpoint for 0.25s, so rotation only happens during a morph.
            let morph = 0.5 - 0.5 * cos(phase * 2 * .pi)
            let corner = size * (0.5 - 0.25 * morph)
            let rotation = Angle(degrees: state.rotationDegrees)
            // The rounded square gently grows by 8% through the morph, then
            // settles back to the circle's original footprint on the return.
            let lift = 1.0 + 0.08 * morph

            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(currentGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(purpleGradient)
                            .opacity(morph)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(currentRimGradient, lineWidth: 0.9)
                            .overlay {
                                RoundedRectangle(cornerRadius: corner, style: .continuous)
                                    .strokeBorder(purpleRimGradient, lineWidth: 0.9)
                                    .opacity(morph)
                            }
                    }
                    .frame(width: size, height: size)
                    .shadow(color: shadowColor.opacity(0.22), radius: 3, y: 1)
                    .scaleEffect(lift)
                    .rotationEffect(rotation)
            }
            .frame(width: size, height: size)
            .compositingGroup()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { startedAt = Date() }
    }

    private var currentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.34 : 0.74),
                Color.cyan.opacity(colorScheme == .dark ? 0.30 : 0.43),
                Color.blue.opacity(colorScheme == .dark ? 0.18 : 0.26)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var purpleGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.36 : 0.68),
                Color(red: 0.78, green: 0.70, blue: 1.0).opacity(colorScheme == .dark ? 0.34 : 0.68),
                Color(red: 0.62, green: 0.48, blue: 0.94).opacity(colorScheme == .dark ? 0.22 : 0.50)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var currentRimGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(colorScheme == .dark ? 0.84 : 0.92),
                .cyan.opacity(colorScheme == .dark ? 0.48 : 0.66),
                Color(red: 0.42, green: 0.67, blue: 0.93).opacity(colorScheme == .dark ? 0.34 : 0.54)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var purpleRimGradient: LinearGradient {
        LinearGradient(
            colors: [
                .white.opacity(colorScheme == .dark ? 0.88 : 0.94),
                Color(red: 0.68, green: 0.56, blue: 0.98).opacity(colorScheme == .dark ? 0.62 : 0.88),
                Color(red: 0.46, green: 0.34, blue: 0.82).opacity(colorScheme == .dark ? 0.40 : 0.72)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var shadowColor: Color {
        let purple = Color(red: 0.62, green: 0.48, blue: 0.94)
        return purple
    }

    private func animationState(at date: Date) -> (morphPhase: CGFloat, rotationDegrees: Double) {
        let elapsed = date.timeIntervalSince(startedAt)
            .truncatingRemainder(dividingBy: cycleDuration)
        let forwardEnd = holdDuration + transitionDuration
        let squareHoldEnd = forwardEnd + holdDuration

        // Hold the blue circle before the forward morph.
        if elapsed < holdDuration {
            return (0, 0)
        }
        // Circle → rounded square: exactly one full turn.
        if elapsed < forwardEnd {
            let progress = (elapsed - holdDuration) / transitionDuration
            let eased = easedRotationProgress(progress)
            return (CGFloat(progress * 0.5), eased * 360.0)
        }
        // Hold the light-purple rounded square before returning.
        if elapsed < squareHoldEnd {
            return (0.5, 360.0)
        }
        // Rounded square → circle: another full turn.
        let progress = (elapsed - squareHoldEnd) / transitionDuration
        let eased = easedRotationProgress(progress)
        return (CGFloat(0.5 + progress * 0.5), 360.0 + eased * 360.0)
    }

    /// Cosine easing gives the rotation zero velocity at both ends of each
    /// morph, so it settles into the 0.25s hold instead of snapping or turning
    /// at a constant, mechanical speed.
    private func easedRotationProgress(_ progress: TimeInterval) -> Double {
        let clamped = min(1.0, max(0.0, progress))
        return 0.5 - 0.5 * cos(clamped * .pi)
    }
}

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()

    private static let label = "Ze正在思考中"
    // Keep the thinking-label sweep in lockstep with the tool-step shimmer.
    // Both use a time-driven 1.65 s pass with a narrow 42%-of-width
    // highlight (minimum 52 pt); using the same values makes the two effects
    // read as one shared UI treatment.
    private var peakOpacity: CGFloat {
        // The capsule shines over a dark gray surface, so 0.25 is enough
        // there. This label uses `secondaryLabel`, which is already bright
        // in dark mode, so its sweep needs a stronger white band to remain
        // visibly distinct.
        colorScheme == .light ? 0.75 : 0.75
    }

    var body: some View {
        HStack(spacing: 4) {
            JellyThinkingGlyph()
            ZStack(alignment: .leading) {
                labelText
                    .foregroundStyle(ChatColors.secondaryText)

                if !reduceMotion {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    let phase = CGFloat((elapsed / ChatShimmerStyle.sweepDuration).truncatingRemainder(dividingBy: 1.0))

                    labelText
                        // Match ShimmerOverlay: a white highlight whose alpha
                        // is supplied by the moving gradient mask.
                        .foregroundStyle(Color.white)
                        .mask(sweepMask(phase: phase))
                        .accessibilityHidden(true)
                }
            }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Ze正在思考中"))
        .onAppear { startedAt = Date() }
    }

    private var labelText: some View {
        Text(Self.label)
            .font(.callout.weight(.medium))
            .lineLimit(1)
    }

    /// The same narrow, time-driven band used by ShimmerOverlay. The gradient
    /// is used as a mask so the highlight exists only inside the glyphs.
    private func sweepMask(phase: CGFloat) -> some View {
        GeometryReader { proxy in
            let bandWidth = max(52, proxy.size.width * 0.42)
            LinearGradient(
                colors: [
                    .white.opacity(0),
                    .white.opacity(peakOpacity),
                    .white.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth, height: proxy.size.height)
            .offset(x: -bandWidth + phase * (proxy.size.width + bandWidth))
        }
    }
}

// MARK: - Thinking Level Sheet

struct ThinkingLevelSheetView: View {
    let currentLevel: ThinkingLevel
    let availableLevels: [ThinkingLevel]
    let onSelect: (ThinkingLevel) -> Void

    var body: some View {
        NavigationStack {
            List {
                thinkingRow(level: .off, isSelected: !currentLevel.isEnabled)
                Section {
                    ForEach(availableLevels, id: \.self) { level in
                        thinkingRow(level: level, isSelected: currentLevel == level)
                    }
                }
            }
            .navigationTitle("思考过程强度")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func thinkingRow(level: ThinkingLevel, isSelected: Bool) -> some View {
        Button {
            onSelect(level)
        } label: {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 16, weight: .semibold))
                    .opacity(level == .off ? 0.4 : 1.0)
                Text(level.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                    .foregroundStyle(.purple)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Tool Copy Button

private struct ToolCopyButton: View {
    var accentColor: Color = .green
    let content: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = content()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .frame(width: 16, height: 16)
                .foregroundStyle(copied ? accentColor : accentColor.opacity(0.4))
        }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}
