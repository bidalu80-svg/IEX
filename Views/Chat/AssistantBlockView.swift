import SwiftUI
import Combine

// MARK: - Assistant Block View (individual block — isolated invalidation)

struct AssistantBlockView: View {
    @Environment(\.chatSearchMessageId) private var searchMessageId
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
            } else if block.kind.isSubAgentTool {
                ZeSubAgentInlineRow(block: block, detailBlock: $detailBlock)
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
                ForEach(Array(displayReasons.enumerated()), id: \.offset) { index, line in
                    SearchHighlightText(line, blockId: block.id, field: .line(index), messageId: message.id)
                        .font(.system(size: 10))
                        .foregroundStyle(ChatColors.primaryText.opacity(0.45))
                        .lineLimit(2)
                }
                if let switchedLine {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.8))
                        SearchHighlightText(switchedLine, blockId: block.id, field: .title, messageId: message.id)
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
            onSpeakText: onSpeakText,
            allowsSearchHighlight: true,
            visualizationOwner: block
        )
        .fixedSize(horizontal: false, vertical: true)
        .modifier(ZeOpenURLHandler())
    }
}

/// A delegation finishes immediately, but its child can keep working. Read
/// the linked child's lifecycle for the transcript badge instead of showing
/// the spawn tool's green completion check for the whole run.
private struct ZeSubAgentInlineRow: View {
    @Environment(\.chatSearchMessageId) private var searchMessageId
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var coordinator = ZeSubAgentCoordinator.shared
    @Environment(\.chatSessionId) private var sessionId
    @Binding var detailBlock: AssistantBlock?

    var body: some View {
        let records = ZeSubAgentBlockLink.records(for: block, rootSessionId: sessionId, coordinator: coordinator)
        let record = records.first(where: { $0.status.isActive }) ?? records.first
        if let record {
            ZeSubAgentCompactCard(record: record, open: { detailBlock = block },
                                  stop: { coordinator.cancelRunGroup(id: record.id) },
                                  resume: { _ = coordinator.resume(id: record.id) })
                .environment(\.chatSearchBlockId, block.id)
        } else {
            Button { detailBlock = block } label: {
                HStack(spacing: 12) {
                    Image(systemName: ZeSubAgentTheme.glyph)
                        .font(.system(size: 13)).foregroundStyle(ZeSubAgentTheme.purple)
                        .frame(width: 34, height: 34)
                        .background(ZeSubAgentTheme.purple.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 5) {
                        SearchHighlightText(block.toolDescription, blockId: block.id, field: .title, messageId: searchMessageId).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(fallbackStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(ZeSubAgentTheme.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ZeSubAgentTheme.purple.opacity(0.35), lineWidth: 0.8))
            }.buttonStyle(.plain)
        }
    }

    private var fallbackStatus: String {
        switch block.toolStatus {
        case .streaming, .running: return String(localized: "调度中")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已停止")
        default: return String(localized: "查看记录")
        }
    }
}

private struct SearchableToolLabel: View {
    @ObservedObject var token: ChatSearchHighlightToken
    let text: String
    let active: Bool
    var body: some View {
        if let state = token.state {
            Text(SearchHighlightText.attributed(text, searchOffset: 0, state: state, dimmed: false))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(ChatColors.secondaryText)
        } else {
            ChatShimmerText(text: text, font: .system(size: 13, weight: .medium), color: ChatColors.secondaryText, isActive: active, usesIntrinsicWidth: false)
        }
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
    @Environment(\.chatSearchMessageId) private var searchMessageId
    @Environment(\.chatSearchHighlights) private var searchCenter
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
    private var displayText: String { ChatSearchDisplayText.toolCapsule(block) }

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
                    if let searchCenter, let searchMessageId {
                        SearchableToolLabel(token: searchCenter.token(for: .init(messageId: searchMessageId, blockId: block.id, field: .body)), text: displayText, active: isActive)
                    } else {
                        ChatShimmerText(text: displayText, font: .system(size: 13, weight: .medium), color: ChatColors.secondaryText, isActive: isActive, usesIntrinsicWidth: false)
                    }
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

/// Shared compact question-card palette for the chat and host sheet.
enum QuestionCardTheme {
    static let accent = Color.accentColor
    static let positive = Color.green
    static let warning = Color.orange
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let radius: CGFloat = 12
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

/// This card uses the same localized labels across chat and tool detail.
private func QuestionAskLocalized(_ key: String) -> String {
    guard Locale.current.languageCode == "zh" else { return NSLocalizedString(key, comment: "") }
    let labels: [String: String] = [
        "Needs your answer": "需要你回答", "Needs your approval": "需要你授权",
        "High-risk action": "高风险操作", "Recommended": "推荐", "Other…": "其他…",
        "Type your answer…": "输入你的回答…", "You decide": "你看着办",
        "Add a note": "补充说明", "Cancel with a reason / do this instead": "取消并说明原因 / 改成这样做",
        "Previous": "上一个", "Next": "下一步", "Submit": "提交", "Cancel": "取消", "Allow": "允许",
        "Show less": "收起", "Show more": "展开", "Answered": "已回答", "Skipped": "已跳过",
        "Cancelled": "已取消", "Timed out": "已超时", "Allowed once": "已允许一次",
        "Your answer": "你的回答", "Reason / do this instead": "原因 / 改成这样做",
        "Stop dictation": "停止听写", "Dictate": "听写", "Done": "完成", "Edit": "编辑",
        "Time left": "剩余时间", "option": "选项",
        "Question for you": "向你提问", "Waiting for your answer…": "等待你的回答…", "Could not ask": "无法提问"
    ]
    return labels[key] ?? NSLocalizedString(key, comment: "")
}

struct QuestionAskTypography: Equatable {
    /// Chat body size at the default scale (ChatMessageViews / markdown).
    static let bodyReference: CGFloat = 16.5
    /// Minimum height of every tappable button on the card.
    static let minTapHeight: CGFloat = 44

    /// The chat body size the card derives from (already scaled).
    let body: CGFloat

    /// Rounded to half points so a scale change cannot produce 16.005-style
    /// sizes that re-measure without visibly changing.
    private func size(_ ratio: CGFloat, floor: CGFloat) -> CGFloat {
        max(floor, (body * ratio * 2).rounded() / 2)
    }
    var question: CGFloat { size(1.0, floor: 13) }
    var optionTitle: CGFloat { size(0.97, floor: 13) }
    var optionDetail: CGFloat { size(0.82, floor: 12) }
    /// Note / cancel-reason rows, impact line, the confirm command.
    var secondary: CGFloat { size(0.88, floor: 12.5) }
    var title: CGFloat { size(0.91, floor: 13) }
    /// Countdown, progress, timeout hint, status lines.
    var meta: CGFloat { size(0.76, floor: 11) }
    /// Header tag and "Recommended" badges.
    var chip: CGFloat { size(0.66, floor: 10) }
    var button: CGFloat { size(0.97, floor: 14) }
    /// Radio / checkbox glyphs.
    var icon: CGFloat { size(1.03, floor: 15) }
    var resolvedTopic: CGFloat { size(0.88, floor: 13) }
    var resolvedDetail: CGFloat { size(0.79, floor: 12) }
    /// [T-user-ask-thumbnail] The mini preview tile above the composer is a
    /// fixed 100x65pt picture, so its text follows the setting only inside a
    /// narrow band that still fits the tile: 7 / 5.5 at the default step.
    var thumbTitle: CGFloat { min(8, size(0.42, floor: 6)) }
    var thumbLine: CGFloat { min(6.5, size(0.34, floor: 5)) }
}
// END QuestionAskTypography

extension QuestionAskTypography {
    /// The current chat body size (live: views observe FontSettings).
    @MainActor static var current: QuestionAskTypography {
        QuestionAskTypography(body: FontSettings.shared.scaledMessage(bodyReference))
    }
}

enum QuestionPendingLayoutCache {
    private struct Measurement {
        let height: CGFloat
        let width: CGFloat
        let bodyFont: CGFloat
    }
    private static var bodyHeights: [String: Measurement] = [:]
    private static var expanded: Set<String> = []
    private static let limit = 256

    static func key(_ requestId: String, _ index: Int) -> String { "\(requestId)#\(index)" }

    /// Width is the actual scroll content proposal, before any question-only
    /// padding. Neither the host sheet nor a split-screen window is assumed.
    static func bodyHeight(_ key: String, width: CGFloat, bodyFont: CGFloat) -> CGFloat {
        guard let value = bodyHeights[key], abs(value.width - width) <= 0.5,
              abs(value.bodyFont - bodyFont) <= 0.01 else { return 0 }
        return value.height
    }
    static func setBodyHeight(_ height: CGFloat, _ key: String, width: CGFloat, bodyFont: CGFloat) {
        guard height > 0, width > 0 else { return }
        if bodyHeights[key] == nil && bodyHeights.count >= limit { bodyHeights.removeAll() }
        bodyHeights[key] = Measurement(height: height, width: width, bodyFont: bodyFont)
    }

    static func isExpanded(_ key: String) -> Bool { expanded.contains(key) }
    static func setExpanded(_ value: Bool, _ key: String) {
        if !expanded.contains(key) && expanded.count >= limit { expanded.removeAll() }
        if value { expanded.insert(key) } else { expanded.remove(key) }
    }
}
// END QuestionPendingLayoutCache


private enum QuestionAskType { case options, confirm }
private enum QuestionAskRisk { case normal, high }
private struct QuestionAskOption { let label: String; let description: String? }
private struct QuestionAskQuestion {
    let raw: QuestionCardQuestion
    init(_ raw: QuestionCardQuestion) { self.raw = raw }
    var type: QuestionAskType { raw.isConfirmation ? .confirm : .options }
    var question: String { raw.prompt }
    var header: String? { raw.header }
    var options: [QuestionAskOption]? {
        raw.options.enumerated().map { index, label in
            QuestionAskOption(label: label, description: raw.optionDescriptions.indices.contains(index) ? raw.optionDescriptions[index] : nil)
        }
    }
    var multiSelect: Bool { raw.multiSelect }
    var impact: String? { raw.impact }
    var risk: QuestionAskRisk { raw.risk == "high" ? .high : .normal }
    var isOpenEnded: Bool { !raw.isConfirmation && raw.options.isEmpty }
}
private struct QuestionAskAnswer {
    var selected: [Int] = []
    var otherText: String?
    var note: String?
    var delegated = false
    init() {}
    init(_ draft: QuestionCardDraft) {
        selected = draft.selectedIndices; otherText = draft.otherText
        note = draft.note; delegated = draft.delegated
    }
    var draft: QuestionCardDraft {
        QuestionCardDraft(selectedIndices: selected, otherText: otherText ?? "", note: note ?? "", delegated: delegated)
    }
    func isComplete(for question: QuestionAskQuestion) -> Bool { draft.isComplete(for: question.raw) }
}

@MainActor
private struct QuestionCardView: View {
    @ObservedObject var block: AssistantBlock
    @State private var draft = QuestionCardDraft()
    @State private var requestIsLive = true
    @State private var isSubmitting = false
    private var coordinator: QuestionCardCoordinator { .shared }

    var body: some View {
        Group {
            if let card = block.questionCard {
                if card.status == .pending {
                    QuestionPendingCard(ask: card, blockId: block.id, draft: $draft,
                        onDraft: { value in draft = value; saveDraft() },
                        onSubmit: { submitCurrentAnswer() },
                        onConfirm: { confirmChoice($0) },
                        onPrevious: {
                            saveDraft()
                            if coordinator.navigate(requestId: card.requestId, index: card.currentIndex - 1) {
                                synchronizeState(requestId: card.requestId)
                            }
                        }, onInput: { QuestionInputPresenter.present(kind: $0, card: card) })
                        .disabled(!requestIsLive)
                } else {
                    QuestionResolvedCard(block: block, card: card, onToggle: {
                        setExpanded(!block.isQuestionCardExpanded, haptic: true)
                    })
                }
            }
        }
        .task(id: block.questionCard?.requestId) {
            restoreDraft()
            guard let card = block.questionCard else { return }
            await monitorLiveness(card)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ZeQuestionDraftChanged"))) { event in
            guard event.object as? String == block.questionCard?.requestId else { return }
            restoreDraft()
        }
        .onChange(of: block.questionCard?.currentIndex) { _ in
            restoreDraft()
        }
        .onChange(of: block.questionCard) { newValue in
            guard let newValue else { return }
            if newValue.status != .pending {
                    setExpanded(false, haptic: false)
            } else if coordinator.isPending(requestId: newValue.requestId) {
                requestIsLive = true
            }
        }
    }
    private func setExpanded(_ expanded: Bool, haptic: Bool) {
        guard block.isQuestionCardExpanded != expanded else { return }
        if haptic { AppFeedback.haptic() }
        block.isQuestionCardExpanded = expanded
        if let card = block.questionCard {
            QuestionCardExpansionStore.setExpanded(expanded, for: card.requestId, status: card.status)
        }
        notifyLayout()
    }

    private func notifyLayout() {
        let id = block.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .questionCardToggled, object: id)
        }
    }

    private func confirmChoice(_ index: Int) {
        draft.selectedIndices = [index]
        draft.otherText = ""
        draft.delegated = false
        submitCurrentAnswer()
    }

    private func submitCurrentAnswer() {
        guard let card = block.questionCard, let question = card.currentQuestion,
              card.status == .pending, !isSubmitting,
              let answer = draft.answer(for: question) else { return }
        isSubmitting = true
        saveDraft()
        let accepted = coordinator.submitAnswer(requestId: card.requestId, answer: answer, questionIndex: card.currentIndex)
        if accepted {
            AppFeedback.haptic()
            synchronizeState(requestId: card.requestId)
        } else {
            requestIsLive = coordinator.isPending(requestId: card.requestId)
            synchronizeState(requestId: card.requestId)
            AppFeedback.haptic()
        }
        isSubmitting = false
    }

    private func synchronizeState(requestId: String) {
        if let updated = coordinator.currentState(requestId: requestId) {
            block.questionCard = updated
            block.content = updated.summaryText
            block.toolSummary = updated.chromeTitle
            if updated.status != .pending { setExpanded(false, haptic: false) }
        }
        restoreDraft()
        notifyLayout()
    }

    private func restoreDraft() {
        guard let card = block.questionCard else { return }
        draft = coordinator.draft(requestId: card.requestId, questionIndex: card.currentIndex)
    }

    private func saveDraft() {
        guard let card = block.questionCard, card.status == .pending else { return }
        coordinator.saveDraft(requestId: card.requestId, questionIndex: card.currentIndex, draft: draft)
        NotificationCenter.default.post(name: Notification.Name("ZeQuestionDraftChanged"), object: card.requestId)
    }

    private func monitorLiveness(_ card: QuestionCardState) async {
        guard card.status == .pending else { return }
        for delay in [200_000_000, 600_000_000, 1_500_000_000] as [UInt64] {
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            requestIsLive = coordinator.isPending(requestId: card.requestId)
            if requestIsLive { break }
        }
        if !requestIsLive { synchronizeState(requestId: card.requestId) }
        while requestIsLive && !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            guard block.questionCard?.status == .pending else { return }
            requestIsLive = coordinator.isPending(requestId: card.requestId)
            if let latest = coordinator.currentState(requestId: card.requestId), latest != block.questionCard {
                synchronizeState(requestId: card.requestId)
            }
            if let index = block.questionCard?.currentIndex {
                let latestDraft = coordinator.draft(requestId: card.requestId, questionIndex: index)
                if latestDraft != draft { draft = latestDraft }
            }
        }
    }

}
@MainActor
private struct QuestionPendingCard: View {
    let ask: QuestionCardState
    @Binding var draft: QuestionCardDraft
    let onDraft: (QuestionCardDraft) -> Void
    let onSubmit: () -> Void
    let onConfirm: (Int) -> Void
    let onPrevious: () -> Void
    let onInput: (QuestionInputKind) -> Void
    let blockId: UUID
    @ObservedObject private var fonts = FontSettings.shared
    private var t: QuestionAskTypography { .current }
    @State private var measuredBody: CGSize = .zero
    @State private var measuredFont: CGFloat = 0
    @State private var questionExpanded: Bool
    /// [T-user-ask-expand-measured] Heights of the question laid out with the
    /// 3-line limit and without it (hidden probes, see `questionText`). The
    /// Show more / Show less toggle exists only when the full text is taller,
    /// i.e. when the collapsed text really is truncated.
    @State private var questionClampedHeight: CGFloat = 0
    @State private var questionFullHeight: CGFloat = 0

    init(ask: QuestionCardState, blockId: UUID, draft: Binding<QuestionCardDraft>,
         onDraft: @escaping (QuestionCardDraft) -> Void, onSubmit: @escaping () -> Void,
         onConfirm: @escaping (Int) -> Void, onPrevious: @escaping () -> Void,
         onInput: @escaping (QuestionInputKind) -> Void) {
        _draft = draft
        self.onDraft = onDraft; self.onSubmit = onSubmit; self.onConfirm = onConfirm
        self.onPrevious = onPrevious; self.onInput = onInput
        self.ask = ask
        self.blockId = blockId
        // Restore per-question disclosure independently from the geometry cache.
        // The custom layout validates geometry against its actual width proposal.
        let key = QuestionPendingLayoutCache.key(ask.requestId, min(ask.currentIndex, ask.questions.count - 1))
        _questionExpanded = State(initialValue: QuestionPendingLayoutCache.isExpanded(key))
    }

    private var layoutKey: String { QuestionPendingLayoutCache.key(ask.requestId, index) }

    private var index: Int { min(ask.currentIndex, ask.questions.count - 1) }
    private var q: QuestionAskQuestion { QuestionAskQuestion(ask.questions[index]) }
    private var answer: QuestionAskAnswer { QuestionAskAnswer(draft) }
    private var tint: Color { q.type == .confirm ? (q.risk == .high ? .red : .orange) : .accentColor }
    /// ~50% of the screen for the whole card; header and action bar are
    /// outside the scroll area, so the body gets that minus ~120pt.
    private var bodyCap: CGFloat { max(160, UIScreen.main.bounds.height * 0.5 - 120) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            QuestionPendingBodyLayout(key: layoutKey, bodyFont: t.body, cap: bodyCap, measuredBody: measuredBody) {
                ScrollView(.vertical, showsIndicators: measuredBody.height > bodyCap) {
                    content
                        .background(GeometryReader { g in
                            Color.clear.preference(key: QuestionBodyHeightKey.self,
                                                   value: QuestionBodyMeasurement(size: g.size, bodyFont: t.body))
                        })
                }
            }
            .onPreferenceChange(QuestionBodyHeightKey.self) { measurement in
                let size = measurement.size
                let font = measurement.bodyFont
                guard size.width > 0, size.height > 0 else { return }
                guard abs(size.height - measuredBody.height) > 0.5 || abs(size.width - measuredBody.width) > 0.5 || abs(font - measuredFont) > 0.01 else { return }
                measuredBody = size
                measuredFont = font
                QuestionPendingLayoutCache.setBodyHeight(size.height, layoutKey, width: size.width, bodyFont: font)
                DispatchQueue.main.async { NotificationCenter.default.post(name: .questionCardToggled, object: blockId) }
            }
            actionBar
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.45), lineWidth: 1))
        .onChange(of: ask.currentIndex) { _ in
            // The new question starts from its own remembered state (collapsed
            // unless the user opened it earlier in this card).
            questionExpanded = QuestionPendingLayoutCache.isExpanded(layoutKey)
            measuredBody = .zero
            measuredFont = 0
            DispatchQueue.main.async { NotificationCenter.default.post(name: .questionCardToggled, object: blockId) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: q.type == .confirm ? "exclamationmark.shield.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: t.title, weight: .semibold))
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(1)
            if let h = q.header, !h.isEmpty {
                Text(h)
                    .font(.system(size: t.chip, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(tint.opacity(0.15), in: Capsule())
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if ask.questions.count > 1 {
                Text("\(index + 1)/\(ask.questions.count)")
                    .font(.system(size: t.meta, weight: .medium).monospacedDigit())
                    .foregroundStyle(ChatColors.secondaryText)
            }
            if ask.timeoutAt > Date() {
                let expires = ask.timeoutAt
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(expires.timeIntervalSince(ctx.date)))
                    Label(String(format: "%d:%02d", left / 60, left % 60), systemImage: "timer")
                        .font(.system(size: t.meta, weight: .medium).monospacedDigit())
                        .foregroundStyle(left <= 30 ? Color.orange : ChatColors.secondaryText)
                        .accessibilityLabel(left <= 30 ? QuestionAskLocalized("\(left) seconds left") : QuestionAskLocalized("Time left"))
                }
            }
        }
    }

    private var title: String {
        switch q.type {
        case .options: return QuestionAskLocalized("Needs your answer")
        case .confirm: return q.risk == .high ? QuestionAskLocalized("High-risk action") : QuestionAskLocalized("Needs your approval")
        }
    }

    // MARK: Body

    /// The question with its type's font - one definition for the visible
    /// text and both measuring probes, so they always wrap identically.
    private var questionText: Text {
        Text(q.question)
            .font(q.type == .confirm ? .system(size: t.secondary, design: .monospaced) : .system(size: t.question, weight: .medium))
    }

    /// [T-user-ask-expand-measured] True when the 3-line layout cuts the
    /// question off. Independent of `questionExpanded`, so an expanded
    /// question keeps its Show less.
    private var questionOverflows: Bool {
        questionFullHeight > questionClampedHeight + 1
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText
                .foregroundStyle(ChatColors.primaryText)
                .lineLimit(questionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                // [T-user-ask-expand-measured] Two hidden copies at the same
                // width and font - capped at 3 lines and uncapped - measure
                // whether the collapsed text is cut off. They sit in the
                // background, so they never change the card's layout.
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        questionText
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: QuestionClampedHeightKey.self, value: g.size.height)
                            })
                        questionText
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: QuestionFullHeightKey.self, value: g.size.height)
                            })
                    }
                    .hidden()
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(QuestionClampedHeightKey.self) { h in
                    if abs(h - questionClampedHeight) > 0.5 { questionClampedHeight = h }
                }
                .onPreferenceChange(QuestionFullHeightKey.self) { h in
                    if abs(h - questionFullHeight) > 0.5 { questionFullHeight = h }
                }
                .padding(q.type == .confirm ? 8 : 0)
                .background(q.type == .confirm ? AnyShapeStyle(Color(UIColor.tertiarySystemFill)) : AnyShapeStyle(Color.clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)
                .padding(.bottom, 6)
            // [T-user-ask-expand-measured] Shown when the collapsed question
            // is actually truncated. It used to be `question.count > 140`,
            // which missed the common confirm case: monospaced text in a
            // padded box fits ~60 mixed CJK/Latin characters in 3 lines, so a
            // 61-140 character question was cut to "…" with no way to open it
            // (and a long one that fit got a useless toggle).
            if questionOverflows {
                Button {
                    questionExpanded.toggle()
                    QuestionPendingLayoutCache.setExpanded(questionExpanded, layoutKey)
                    // Expanding the text does not submit an answer.
                } label: {
                    Text(questionExpanded ? QuestionAskLocalized("Show less") : QuestionAskLocalized("Show more"))
                        .font(.system(size: t.secondary, weight: .medium))
                        .foregroundStyle(tint)
                        // A full-height row like every other control on this
                        // card; it was a bare ~26x15pt label.
                        .padding(.trailing, 16)
                        .frame(minHeight: QuestionAskTypography.minTapHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            switch q.type {
            case .options: optionsBody
            case .confirm: confirmBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var optionsBody: some View {
        if let options = q.options, !options.isEmpty {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                optionRow(i, o)
            }
        }
        otherRow
        if !q.isOpenEnded {
            choiceRow(icon: answer.delegated ? "checkmark.circle.fill" : "circle",
                      label: QuestionAskLocalized("You decide"), selected: answer.delegated) {
                var a = QuestionAskAnswer(); a.delegated = true; a.note = answer.note
                draft = a.draft
                onDraft(a.draft)
                haptic()
            }
        }
        noteRow
    }

    private func optionRow(_ i: Int, _ o: QuestionAskOption) -> some View {
        let selected = answer.selected.contains(i) && !answer.delegated
        let icon = q.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
        return Button {
            var a = answer
            a.delegated = false
            if q.multiSelect {
                if let pos = a.selected.firstIndex(of: i) { a.selected.remove(at: pos) } else { a.selected.append(i) }
            } else {
                a.selected = [i]
                a.otherText = nil
            }
            draft = a.draft
            onDraft(a.draft)
            haptic()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: t.icon))
                    .foregroundStyle(selected ? tint : ChatColors.tertiaryText)
                    .frame(width: t.icon + 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(o.label)
                            .font(.system(size: t.optionTitle, weight: selected ? .semibold : .regular))
                            .foregroundStyle(ChatColors.primaryText)
                        if i == 0 {
                            Text(QuestionAskLocalized("Recommended"))
                                .font(.system(size: t.chip, weight: .semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(tint.opacity(0.14), in: Capsule())
                        }
                    }
                    if let d = o.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: t.optionDetail))
                            .foregroundStyle(ChatColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .frame(minHeight: QuestionAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(o.label), \(QuestionAskLocalized("option")) \(i + 1)/\(q.options?.count ?? 0)\(i == 0 ? ", " + QuestionAskLocalized("Recommended") : "")"))
    }

    private var otherRow: some View {
        let text = answer.otherText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = !text.isEmpty && !answer.delegated
        return choiceRow(icon: q.isOpenEnded ? "text.cursor" : (selected ? "largecircle.fill.circle" : "circle"),
                         label: selected ? text : (q.isOpenEnded ? QuestionAskLocalized("Type your answer…") : QuestionAskLocalized("Other…")),
                         selected: selected, trailingIcon: "mic") {
            onInput(.answer)
        }
    }

    private var noteRow: some View {
        let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Button {
            onInput(.note)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: note.isEmpty ? "plus" : "note.text")
                Text(note.isEmpty ? QuestionAskLocalized("Add a note") : note)
                    .lineLimit(1)
            }
            .font(.system(size: t.secondary))
            .foregroundStyle(note.isEmpty ? ChatColors.secondaryText : ChatColors.primaryText)
            .padding(.vertical, 7)
            .frame(minHeight: QuestionAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choiceRow(icon: String, label: String, selected: Bool, trailingIcon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: t.icon))
                    .foregroundStyle(selected ? tint : ChatColors.tertiaryText)
                    .frame(width: t.icon + 4)
                Text(label)
                    .font(.system(size: t.optionTitle, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? ChatColors.primaryText : ChatColors.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: t.secondary))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
            }
            .padding(.vertical, 7)
            .frame(minHeight: QuestionAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var confirmBody: some View {
        if let impact = q.impact, !impact.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: t.meta))
                    .foregroundStyle(tint)
                Text(impact)
                    .font(.system(size: t.secondary))
                    .foregroundStyle(ChatColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        let reason = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Button {
            onInput(.denyReason)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: reason.isEmpty ? "plus" : "arrow.uturn.backward")
                Text(reason.isEmpty ? QuestionAskLocalized("Cancel with a reason / do this instead") : reason)
                    .lineLimit(2)
            }
            .font(.system(size: t.secondary))
            .foregroundStyle(ChatColors.secondaryText)
            .padding(.vertical, 7)
            .frame(minHeight: QuestionAskTypography.minTapHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Action bar

    @ViewBuilder
    private var actionBar: some View {
        switch q.type {
        case .options:
            // Previous and Next/Submit share the row equally; alone, the
            // primary button spans it.
            HStack(spacing: 10) {
                if index > 0 {
                    previousButton(fill: true)
                }
                let last = !(0..<ask.questions.count).contains { $0 != index && !(ask.answers.indices.contains($0) && ask.answers[$0] != nil) }
                Button(last ? QuestionAskLocalized("Submit") : QuestionAskLocalized("Next")) {
                    onSubmit()
                    haptic()
                }
                .buttonStyle(QuestionAskButtonStyle(kind: .primary, tint: tint, fill: true, fontSize: t.button))
                .disabled(!answer.isComplete(for: q))
            }
        case .confirm:
            // [T-user-ask-confirm-row] One row: Previous on the left, Cancel and
            // Allow together on the right. A confirm button acts on one tap,
            // so Previous is kept apart from them by the flexible gap rather than
            // sitting next to one; without Previous the pair is still right-aligned.
            // [T-user-ask-no-policy] Two choices only - Cancel and Allow;
            // the app records no "always" rule.
            // A long locale at a large font falls back to the pair on its own
            // right-aligned row with Previous below on the left, then to a stack.
            let showsPrevious = index > 0
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if showsPrevious {
                        previousButton(fill: false)
                    }
                    Spacer(minLength: 12)
                    cancelButton
                    allowOnceButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        cancelButton
                        allowOnceButton
                    }
                    if showsPrevious {
                        previousButton(fill: false)
                    }
                }
                VStack(alignment: .trailing, spacing: 8) {
                    cancelButton
                    allowOnceButton
                    if showsPrevious {
                        previousButton(fill: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Back to the previous question - the same string and secondary style as
    /// on an options card. Only shows it; submits and changes nothing.
    private func previousButton(fill: Bool) -> some View {
        Button(QuestionAskLocalized("Previous")) {
            onPrevious()
        }
        .buttonStyle(QuestionAskButtonStyle(kind: .secondary, tint: tint, fill: fill, fontSize: t.button))
    }

    private var cancelButton: some View {
        // Cancel first: the safe choice sits where the thumb lands.
        Button(QuestionAskLocalized("Cancel")) {
            onConfirm(0)
            haptic()
        }
        .buttonStyle(QuestionAskButtonStyle(kind: .primary, tint: .gray, fontSize: t.button))
        .accessibilitySortPriority(2)
    }

    private var allowOnceButton: some View {
        // [T-user-ask-allow-label] "Allow", not "Allow once": the app keeps no
        // "always" rule ([T-user-ask-no-policy]), so there is nothing to contrast with.
        Button(QuestionAskLocalized("Allow")) {
            onConfirm(1)
            haptic()
        }
        .buttonStyle(QuestionAskButtonStyle(kind: .secondary, tint: tint, fontSize: t.button))
    }

    // MARK: Helpers

    private func haptic() {
        AppFeedback.haptic()
    }
}

/// [T-user-ask-expand-measured] Hidden question probes (3-line and full).
private struct QuestionClampedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct QuestionFullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Uses SwiftUI's actual width proposal to validate the cached natural height.
/// On a new width/font, measure at the cap once rather than reuse stale geometry.
private struct QuestionPendingBodyLayout: Layout {
    let key: String
    let bodyFont: CGFloat
    let cap: CGFloat
    let measuredBody: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? max(measuredBody.width, 1)
        let natural = QuestionPendingLayoutCache.bodyHeight(key, width: width, bodyFont: bodyFont)
        return CGSize(width: width, height: natural > 0 ? min(natural, cap) : cap)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

private struct QuestionBodyMeasurement: Equatable {
    var size: CGSize = .zero
    var bodyFont: CGFloat = 0
}

private struct QuestionBodyHeightKey: PreferenceKey {
    static var defaultValue = QuestionBodyMeasurement()
    static func reduce(value: inout QuestionBodyMeasurement, nextValue: () -> QuestionBodyMeasurement) {
        let next = nextValue()
        if next.size.width > 0 && next.size.height > 0 { value = next }
    }
}

private struct QuestionAskButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    let kind: Kind
    let tint: Color
    /// Stretch to the width the row offers (shared equally with siblings).
    var fill: Bool = false
    /// QuestionAskTypography.button of the view using the style.
    var fontSize: CGFloat = QuestionAskTypography(body: QuestionAskTypography.bodyReference).button
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(minWidth: 72, maxWidth: fill ? .infinity : nil, minHeight: QuestionAskTypography.minTapHeight)
            .foregroundStyle(kind == .primary ? Color.white : tint)
            .background(
                Capsule(style: .continuous)
                    .fill(kind == .primary ? tint : tint.opacity(0.14))
            )
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}


@MainActor
private struct QuestionResolvedCard: View {
    @Environment(\.chatSearchMessageId) private var searchMessageId
    @ObservedObject var block: AssistantBlock
    let card: QuestionCardState
    let onToggle: () -> Void
    @ObservedObject private var fonts = FontSettings.shared
    private var t: QuestionAskTypography { .current }
    private var first: QuestionCardQuestion? { card.questions.first }
    private var isConfirm: Bool { first?.isConfirmation == true }
    private var tint: Color {
        if card.status == .unconfirmed, card.resolutionSource != "timeout" { return .gray }
        return isConfirm ? (first?.risk == "high" ? .red : .orange) : .accentColor
    }
    private var denied: Bool { card.questions.indices.contains { card.confirmationDecision(at: $0) == "deny" } }
    private var glyph: String {
        if card.resolutionSource == "timeout" { return "timer" }
        return card.status == .unconfirmed || denied ? "xmark" : "checkmark"
    }
    private var statusColor: Color { card.status == .unconfirmed || denied ? ChatColors.secondaryText : tint }
    private var badge: String? { card.questions.count == 1 ? first?.header : nil }
    private var topic: String { ChatSearchQuestionText.questionTopic(card) }
    private var status: String {
        if card.questions.count > 1 { return "\(card.answeredCount)/\(card.questions.count) " + QuestionAskLocalized("Answered") }
        if card.status == .unconfirmed {
            return QuestionAskLocalized(card.resolutionSource == "timeout" ? "Timed out" : "Skipped")
        }
        if isConfirm {
            guard let decision = card.confirmationDecision(at: 0) else { return QuestionAskLocalized("Skipped") }
            return QuestionAskLocalized(decision == "deny" ? "Cancelled" : "Allowed once")
        }
        return QuestionAskLocalized("Answered")
    }
    private var digest: String { ChatSearchQuestionText.questionDigest(card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle().fill(tint.opacity(0.15)).frame(width: 34, height: 34)
                        Image(systemName: glyph)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            if let badge, !badge.isEmpty {
                                Text(badge)
                                    .font(.system(size: t.chip, weight: .semibold))
                                    .foregroundStyle(tint)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(tint.opacity(0.15))
                                    .clipShape(Capsule())
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            SearchHighlightText(topic, blockId: block.id, field: .title, messageId: searchMessageId)
                                .font(isConfirm ? .system(size: t.resolvedTopic - 1, weight: .medium, design: .monospaced)
                                                : .system(size: t.resolvedTopic, weight: .medium))
                                .foregroundStyle(ChatColors.primaryText)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text(status)
                                .font(.system(size: t.meta, weight: .semibold))
                                .foregroundStyle(statusColor)
                                .lineLimit(1)
                                .layoutPriority(1)
                            if !digest.isEmpty {
                                SearchHighlightText(digest, blockId: block.id, field: .activity, messageId: searchMessageId)
                                    .font(.system(size: t.meta))
                                    .foregroundStyle(ChatColors.secondaryText)
                                    .lineLimit(1)
                                    .frame(minWidth: 60, alignment: .leading)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: block.isQuestionCardExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ChatColors.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if block.isQuestionCardExpanded {
                answerSheet(card)
                    .padding(.leading, 46)
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 0.8))
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func answerSheet(_ card: QuestionCardState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.questions.indices, id: \.self) { index in
                resolvedQuestionRow(card, index: index)
            }
        }
    }

    private func resolvedQuestionRow(_ card: QuestionCardState, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SearchHighlightText(card.questions[index].prompt, blockId: block.id, field: .question(index), messageId: searchMessageId)
                .font(.system(size: t.resolvedDetail))
                .foregroundStyle(ChatColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if card.answers.indices.contains(index) {
                Text(card.answers[index] ?? QuestionAskLocalized("Skipped"))
                    .font(.system(size: t.secondary, weight: .medium))
                    .foregroundStyle(ChatColors.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum QuestionInputKind: String, Identifiable {
    case answer, note, denyReason
    var id: String { rawValue }
}

@MainActor
private enum QuestionInputPresenter {
    static func present(kind: QuestionInputKind, card: QuestionCardState) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top, let question = card.currentQuestion else { return }
        let requestId = card.requestId
        let index = card.currentIndex
        let draft = QuestionCardCoordinator.shared.draft(requestId: requestId, questionIndex: index)
        weak var hostRef: UIViewController?
        let close = {
            guard let host = hostRef, host.presentingViewController != nil, !host.isBeingDismissed else { return }
            host.presentingViewController?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: QuestionAnswerInputSheet(
            title: kind == .answer ? "Your answer" : (kind == .note ? "Add a note" : "Reason / do this instead"),
            question: question.prompt,
            initialText: kind == .answer ? draft.otherText : draft.note,
            onChange: { save($0, kind: kind, requestId: requestId, index: index, commit: false) },
            onDone: { text in save(text, kind: kind, requestId: requestId, index: index, commit: true); close() },
            onCancel: close, requestId: requestId, questionIndex: index))
        hostRef = host
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        top.present(host, animated: true)
    }

    private static func save(_ text: String, kind: QuestionInputKind, requestId: String, index: Int, commit: Bool) {
        let center = QuestionCardCoordinator.shared
        guard let state = center.currentState(requestId: requestId), state.status == .pending,
              state.currentIndex == index, let question = state.currentQuestion else { return }
        var draft = center.draft(requestId: requestId, questionIndex: index)
        let clipped = String(text.prefix(1000))
        if kind == .answer {
            draft.otherText = clipped
            if commit, !clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !question.multiSelect { draft.selectedIndices = [] }
                draft.delegated = false
            }
        } else { draft.note = clipped }
        center.saveDraft(requestId: requestId, questionIndex: index, draft: draft)
        NotificationCenter.default.post(name: Notification.Name("ZeQuestionDraftChanged"), object: requestId)
    }
}

@MainActor
private struct QuestionAnswerInputSheet: View {
    let title: String
    let question: String
    let onChange: (String) -> Void
    let onDone: ((String) -> Void)?
    let onCancel: (() -> Void)?
    let requestId: String?
    let questionIndex: Int?
    private let initialText: String
    @State private var text: String
    @FocusState private var focused: Bool
    @ObservedObject private var fonts = FontSettings.shared
    private var t: QuestionAskTypography { .current }
    @StateObject private var voiceVM = VoiceInputViewModel()
    @State private var voiceActive = false
    @State private var savedVoiceExpanded: Bool?
    @Environment(\.dismiss) private var dismiss

    init(title: String, question: String, initialText: String, onChange: @escaping (String) -> Void, onDone: ((String) -> Void)? = nil,
         onCancel: (() -> Void)? = nil, requestId: String? = nil, questionIndex: Int? = nil) {
        self.title = title; self.question = question; self.onChange = onChange; self.onDone = onDone
        self.onCancel = onCancel; self.requestId = requestId; self.questionIndex = questionIndex
        self.initialText = initialText
        _text = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(question)
                    .font(.system(size: t.resolvedDetail))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: t.question))
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(UIColor.separator), lineWidth: 0.5))
                    .allowsHitTesting(!voiceActive)
                    .overlay {
                        if voiceActive {
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture(count: 2) { editFromVoice() }
                                .accessibilityElement()
                                .accessibilityLabel(Text(text.isEmpty ? title : text))
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction(named: Text(QuestionAskLocalized("Edit"))) { editFromVoice() }
                        }
                    }
                HStack {
                    Button { voiceActive ? leaveVoice() : enterVoice() } label: {
                        Label(voiceActive ? QuestionAskLocalized("Stop dictation") : QuestionAskLocalized("Dictate"),
                              systemImage: voiceActive ? "keyboard" : "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text("\(text.count)/\(1000)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if voiceActive {
                    InlineVoiceInputView(viewModel: voiceVM, inputText: $text)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(UIColor.separator), lineWidth: 0.5))
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .animation(.easeOut(duration: 0.2), value: voiceActive)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(UIColor.systemBackground).ignoresSafeArea())
            .onChange(of: text) { value in
                let clipped = String(value.prefix(1000))
                if text != clipped { text = clipped }
                onChange(clipped)
            }
            .navigationTitle(QuestionAskLocalized(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(QuestionAskLocalized("Cancel")) { leaveVoice(); if let onCancel { onCancel() } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(QuestionAskLocalized("Done")) { leaveVoice(); onChange(text); if let onDone { onDone(text) } else { dismiss() } }
                }
            }
        }
        .onAppear { text = initialText; focused = true }
        .onDisappear { leaveVoice() }
        .task {
            guard let requestId, let questionIndex else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                let state = QuestionCardCoordinator.shared.currentState(requestId: requestId)
                if state?.status != .pending || state?.currentIndex != questionIndex {
                    leaveVoice()
                    if let onCancel { onCancel() } else { dismiss() }
                    return
                }
            }
        }
    }

    private func enterVoice() {
        focused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let mode = VoiceModePreference.shared
        if savedVoiceExpanded == nil { savedVoiceExpanded = mode.expanded }
        mode.enteredFromText = false
        mode.expanded = false
        voiceActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard voiceActive, voiceVM.state == .waiting else { return }
            voiceVM.handleMainButtonTap()
        }
    }

    private func leaveVoice() {
        guard voiceActive else { return }
        voiceVM.stopListening()
        voiceActive = false
        if let saved = savedVoiceExpanded { VoiceModePreference.shared.expanded = saved; savedVoiceExpanded = nil }
    }

    private func editFromVoice() {
        leaveVoice()
        DispatchQueue.main.async { focused = true }
    }
}


// MARK: - Question card detail (Ze 主机 preview)

/// The host and chat share the same question interaction and persisted drafts.
/// This also keeps resolved summaries and expansion behaviour identical.
@MainActor
struct QuestionCardDetailView: View {
    @ObservedObject var block: AssistantBlock

    var body: some View {
        ScrollView {
            Group {
                if block.questionCard != nil {
                    QuestionCardView(block: block)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("提问卡片").font(.headline)
                        Text(block.content).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            guard block.questionCard == nil, block.kind.isQuestionCardTool,
                  let raw = block.toolInputArgs, let data = raw.data(using: .utf8),
                  let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var card = QuestionCardParser.state(requestId: block.toolUseId ?? "question-card-preview",
                                                      arguments: arguments, timeout: 900) else { return }
            if let state = QuestionCardCoordinator.shared.currentState(requestId: card.requestId) {
                card = state
            } else if block.content.contains("\"answers\"") || block.content.contains("\"confirmed\"") {
                QuestionCardParser.apply(resultJSON: block.content, to: &card)
            }
            block.questionCard = card
            block.isQuestionCardExpanded = QuestionCardExpansionStore.isExpanded(for: card.requestId, status: card.status)
        }
    }
}


private enum QuestionTileResultStatus { case answered, other, delegated, approved, denied, timeout, dismissed, unavailable }
private struct QuestionTileSummaryRow: Equatable {
    var topic: String
    var value: String
    /// Not the user's own choice (timed out, skipped, cancelled, …): drawn
    /// in a neutral colour instead of the accent.
    var muted: Bool
}

private enum QuestionTileSummary {
    /// The tile is 100pt wide: a topic longer than a header chip (max 12)
    /// pushes the answer off the line. The sheet has room for more.
    static let tileTopicLimit = 14
    static let sheetTopicLimit = 80

    static func topic(_ q: QuestionAskQuestion, limit: Int = tileTopicLimit) -> String {
        if let h = q.header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { return h }
        let flat = q.question.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func value(_ status: QuestionTileResultStatus, answer: [String]) -> (text: String, muted: Bool) {
        let given = answer.filter { !$0.isEmpty }.joined(separator: ", ")
        switch status {
        case .answered, .other: return (given.isEmpty ? QuestionAskLocalized("Answered") : given, false)
        case .delegated: return (QuestionAskLocalized("You decide"), false)
        case .approved: return (QuestionAskLocalized("Allow"), false)
        case .denied: return (QuestionAskLocalized("Cancel"), true)
        case .timeout: return (QuestionAskLocalized("Timed out"), true)
        case .dismissed: return (QuestionAskLocalized("Skipped"), true)
        case .unavailable: return (QuestionAskLocalized("Could not ask"), true)
        }
    }

    /// Still waiting: the waiting line, then each question's topic.
    static func pendingRows(_ questions: [QuestionAskQuestion], topicLimit: Int = tileTopicLimit) -> [QuestionTileSummaryRow] {
        [QuestionTileSummaryRow(topic: QuestionAskLocalized("Waiting for your answer…"), value: "", muted: false)]
            + questions.map { QuestionTileSummaryRow(topic: topic($0, limit: topicLimit), value: "", muted: true) }
    }

    /// Resolved: one row per question, in order. A question with no result
    /// entry (a dismissal that recorded none) reads as skipped.
    static func resolvedRows(_ questions: [QuestionAskQuestion],
                             results: [(status: QuestionTileResultStatus, answer: [String])],
                             topicLimit: Int = tileTopicLimit) -> [QuestionTileSummaryRow] {
        questions.enumerated().map { i, q in
            let v = i < results.count ? value(results[i].status, answer: results[i].answer)
                                      : value(.dismissed, answer: [])
            return QuestionTileSummaryRow(topic: topic(q, limit: topicLimit), value: v.text, muted: v.muted)
        }
    }

    /// One muted row titled `title` (QuestionTileSummary.notSentTitle).
    static func notAskedRows(title: String) -> [QuestionTileSummaryRow] {
        [QuestionTileSummaryRow(topic: title, value: "", muted: true)]
    }

    /// How many rows fit under the title on the fixed tile, from the two
    /// derived sizes; line height ≈ 1.25 × size plus 1pt row spacing.
    static func capacity(tileHeight: Double, titleSize: Double, lineSize: Double) -> Int {
        let usable = tileHeight - 4 - 3 - (titleSize * 1.25 + 1)
        return max(1, Int(usable / (lineSize * 1.25 + 1)))
    }

    /// Rows that fit; when they do not all fit the last slot becomes "+N".
    static func fit(_ rows: [QuestionTileSummaryRow], capacity: Int) -> (rows: [QuestionTileSummaryRow], more: Int) {
        guard rows.count > capacity else { return (rows, 0) }
        let shown = max(0, capacity - 1)
        return (Array(rows.prefix(shown)), rows.count - shown)
    }
}

/// [T-user-ask-tile-rich] What the 100x65pt mini preview tile shows: a
/// miniature of the card, not just a list of header chips. Pending: the
/// question the user is on - card title with its header chip and progress,
/// the question (the command, for a confirm), the impact line or the
/// options with what is picked so far. Resolved: each question's text with
/// its answer under it.
private struct QuestionTileLine: Equatable {
    enum Kind: Equatable {
        case question, command, impact, topic
        case option(marker: String, selected: Bool)
        case answer(muted: Bool)
    }
    var kind: Kind
    var text: String
    /// Lines this entry may wrap to (and what it costs in the line budget).
    var maxLines: Int
}

private struct QuestionTileContent: Equatable {
    var title: String
    /// "1/3" on a multi-question ask, else empty.
    var trailing: String
    var lines: [QuestionTileLine]
}

private extension QuestionTileSummary {
    /// The card's own title for question `q` ([T-user-ask-card] wording).
    static func cardTitle(_ q: QuestionAskQuestion) -> String {
        switch q.type {
        case .options: return QuestionAskLocalized("Needs your answer")
        case .confirm: return q.risk == .high ? QuestionAskLocalized("High-risk action") : QuestionAskLocalized("Needs your approval")
        }
    }

    private static func flat(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Waiting for an answer: question `current` as a miniature card.
    static func pendingTile(questions: [QuestionAskQuestion], current: Int,
                            answer: QuestionAskAnswer?) -> QuestionTileContent {
        guard questions.indices.contains(current) else {
            return QuestionTileContent(title: QuestionAskLocalized("Question for you"), trailing: "", lines: [])
        }
        let q = questions[current]
        var title = cardTitle(q)
        if let h = q.header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty { title += " · " + h }
        let trailing = questions.count > 1 ? "\(current + 1)/\(questions.count)" : ""
        var lines: [QuestionTileLine] = []
        let text = flat(q.question)
        if !text.isEmpty {
            lines.append(QuestionTileLine(kind: q.type == .confirm ? .command : .question, text: text, maxLines: 2))
        }
        switch q.type {
        case .confirm:
            if let impact = q.impact.map(flat), !impact.isEmpty {
                lines.append(QuestionTileLine(kind: .impact, text: impact, maxLines: 2))
            }
        case .options:
            let picked = Set(answer?.selected ?? [])
            for (i, option) in (q.options ?? []).enumerated() {
                let on = picked.contains(i)
                let marker = q.multiSelect ? (on ? "☑" : "☐") : (on ? "●" : "○")
                lines.append(QuestionTileLine(kind: .option(marker: marker, selected: on), text: flat(option.label), maxLines: 1))
            }
            if let other = answer?.otherText.map(flat), !other.isEmpty {
                lines.append(QuestionTileLine(kind: .option(marker: q.multiSelect ? "☑" : "●", selected: true),
                                             text: other, maxLines: 1))
            }
        }
        return QuestionTileContent(title: title, trailing: trailing, lines: lines)
    }

    /// Answered (or otherwise settled): each question's text, then its answer.
    static func resolvedTile(_ questions: [QuestionAskQuestion],
                             results: [(status: QuestionTileResultStatus, answer: [String])]) -> QuestionTileContent {
        var lines: [QuestionTileLine] = []
        for (i, q) in questions.enumerated() {
            let text = flat(q.question)
            let header = q.header?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let topicText = text.isEmpty ? header : text
            if !topicText.isEmpty {
                lines.append(QuestionTileLine(kind: .topic, text: topicText, maxLines: questions.count == 1 ? 2 : 1))
            }
            let v = i < results.count ? value(results[i].status, answer: results[i].answer) : value(.dismissed, answer: [])
            lines.append(QuestionTileLine(kind: .answer(muted: v.muted), text: v.text, maxLines: 1))
        }
        return QuestionTileContent(title: QuestionAskLocalized("Question for you"), trailing: "", lines: lines)
    }

    /// Entries that fit `capacity` lines (each costs its maxLines; a
    /// two-line entry squeezed into the last free line keeps one). What
    /// does not fit becomes "+N", which needs a line of its own.
    static func fitTile(_ lines: [QuestionTileLine], capacity: Int) -> (lines: [QuestionTileLine], more: Int) {
        let total = lines.reduce(0) { $0 + $1.maxLines }
        guard total > capacity else { return (lines, 0) }
        var budget = max(0, capacity - 1)
        var shown: [QuestionTileLine] = []
        for line in lines {
            guard budget > 0 else { break }
            var l = line
            l.maxLines = min(l.maxLines, budget)
            budget -= l.maxLines
            shown.append(l)
        }
        return (shown, lines.count - shown.count)
    }
}

/// A miniature of the actual question, inside the existing floating tool shell.
@MainActor
struct QuestionCardThumbnail: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject private var fonts = FontSettings.shared
    @State private var revision = 0
    private var t: QuestionAskTypography { .current }
    static let tileSize = CGSize(width: 100, height: 65)

    private var card: QuestionCardState? {
        _ = revision
        guard let stored = block.questionCard else { return nil }
        return QuestionCardCoordinator.shared.currentState(requestId: stored.requestId) ?? stored
    }

    var body: some View {
        Group {
            if let card {
                let questions = card.questions.map(QuestionAskQuestion.init)
                if card.status == .pending, let question = card.currentQuestion {
                    let draft = QuestionCardCoordinator.shared.draft(requestId: card.requestId, questionIndex: card.currentIndex)
                    richTile(QuestionTileSummary.pendingTile(questions: questions, current: card.currentIndex, answer: QuestionAskAnswer(draft)),
                             tint: question.isConfirmation ? (question.risk == "high" ? .red : .orange) : .accentColor)
                } else {
                    richTile(QuestionTileSummary.resolvedTile(questions, results: card.questions.indices.map { index in
                        (resultStatus(card, index: index), card.displayAnswerValues(at: index))
                    }), tint: .accentColor)
                }
            } else {
                richTile(QuestionTileContent(title: QuestionAskLocalized("Question for you"), trailing: "",
                                             lines: [QuestionTileLine(kind: .answer(muted: true), text: QuestionAskLocalized("Waiting for your answer…"), maxLines: 2)]), tint: .accentColor)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .questionCardToggled)) { notification in
            guard notification.object as? UUID == block.id else { return }
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ZeQuestionDraftChanged"))) { notification in
            guard notification.object as? String == block.questionCard?.requestId else { return }
            revision &+= 1
        }
    }

    private func resultStatus(_ card: QuestionCardState, index: Int) -> QuestionTileResultStatus {
        guard card.answers.indices.contains(index), card.answers[index] != nil else {
            return card.resolutionSource == "timeout" ? .timeout : .dismissed
        }
        if card.questions[index].isConfirmation {
            guard let decision = card.confirmationDecision(at: index) else { return .dismissed }
            return decision == "allow" ? .approved : .denied
        }
        if card.submittedDraft(at: index)?.delegated == true { return .delegated }
        return .answered
    }
    private func richTile(_ content: QuestionTileContent, tint: Color) -> some View {
        let capacity = QuestionTileSummary.capacity(tileHeight: Self.tileSize.height,
                                               titleSize: t.thumbTitle, lineSize: t.thumbLine)
        let fitted = QuestionTileSummary.fitTile(content.lines, capacity: capacity)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                Text(content.title)
                    .font(.system(size: t.thumbTitle, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !content.trailing.isEmpty {
                    Spacer(minLength: 2)
                    Text(verbatim: content.trailing)
                        .font(.system(size: t.thumbLine, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        .fixedSize()
                }
            }
            .padding(.bottom, 1)
            ForEach(Array(fitted.lines.enumerated()), id: \.offset) { _, line in
                tileLineText(line, tint: tint)
                    .lineLimit(line.maxLines)
                    .truncationMode(.tail)
            }
            if fitted.more > 0 {
                Text(verbatim: "+\(fitted.more)")
                    .font(.system(size: t.thumbLine, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(width: Self.tileSize.width, height: Self.tileSize.height, alignment: .topLeading)
        .clipped()
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
    }

    private func tileLineText(_ line: QuestionTileLine, tint: Color) -> Text {
        let size = t.thumbLine
        switch line.kind {
        case .question:
            return Text(line.text).font(.system(size: size, weight: .medium)).foregroundColor(Color.white.opacity(0.9))
        case .command:
            return Text(line.text).font(.system(size: size, design: .monospaced)).foregroundColor(Color.white.opacity(0.85))
        case .impact:
            return Text(verbatim: "⚠ ").font(.system(size: size)).foregroundColor(tint)
                + Text(line.text).font(.system(size: size)).foregroundColor(Color.white.opacity(0.6))
        case .topic:
            return Text(line.text).font(.system(size: size)).foregroundColor(Color.white.opacity(0.6))
        case let .option(marker, selected):
            return Text(verbatim: marker + " ").font(.system(size: size)).foregroundColor(selected ? tint : Color.white.opacity(0.45))
                + Text(line.text).font(.system(size: size, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? tint : Color.white.opacity(0.7))
        case let .answer(muted):
            return Text(verbatim: "→ ").font(.system(size: size)).foregroundColor(Color.white.opacity(0.35))
                + Text(line.text).font(.system(size: size, weight: .medium))
                    .foregroundColor(muted ? Color.white.opacity(0.45) : tint)
        }
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

/// The complete recorded entrance and six observed layer turns, in cube-local
/// coordinates. Global rotation keeps advancing when the local layer cycle wraps.
/// The recording ends mid-turn; only its completion is reconstructed offline.
private enum CubeThinkingGlyphAnimation {
    static let framesPerSecond: Double = 60
    static let introFrameCount = 16
    static let loopFrameCount = 108
    static let frameCount = 124
    static let tileSide = 56
    static let atlasColumns = 8
    static let decodedMemoryBudget = 4 * 1024 * 1024
    static let loopStartFrameIndex = introFrameCount
    static let globalDegreesPerSourceFrame = 0.919341504573822
    // OpenCV indexes pixel centers at integers. Canvas measures from the image
    // edge, so add half a source pixel before restoring the recorded pose.
    static let pivotX: CGFloat = 29.0 / 56.0
    static let pivotY: CGFloat = 28.0 / 56.0
    static var introDuration: TimeInterval { Double(introFrameCount) / framesPerSecond }
    static var loopDuration: TimeInterval { Double(loopFrameCount) / framesPerSecond }
    static var initialPlaybackDuration: TimeInterval { Double(frameCount) / framesPerSecond }

    private static let scaleKeyframes: [(frame: Double, scale: Double)] = [
        (8, 1), (17, 1.0036402940750122), (26, 0.9911999388661918),
        (35, 0.9646904525861668), (43, 0.9361779693449992),
        (52, 0.9070229325033577), (61, 0.9)
    ]

    static func frameIndex(elapsed: TimeInterval, reducedMotion: Bool = false) -> Int {
        if reducedMotion { return loopStartFrameIndex }
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        if elapsed < introDuration {
            return min(introFrameCount - 1, Int((elapsed * framesPerSecond).rounded(.down)))
        }
        let phase = (elapsed - introDuration).truncatingRemainder(dividingBy: loopDuration)
        let offset = min(loopFrameCount - 1, Int((phase * framesPerSecond + 0.00000001).rounded(.down)))
        return loopStartFrameIndex + offset
    }

    static func globalRotationDegrees(elapsed: TimeInterval, reducedMotion: Bool = false) -> Double {
        let sourceFrame = sampledSourceFrame(elapsed: elapsed, reducedMotion: reducedMotion)
        // Canvas uses a downward y axis, opposite the offline OpenCV rotation.
        return -globalDegreesPerSourceFrame * (sourceFrame - 8)
    }

    static func globalScale(elapsed: TimeInterval, reducedMotion: Bool = false) -> CGFloat {
        let sourceFrame = sampledSourceFrame(elapsed: elapsed, reducedMotion: reducedMotion)
        guard sourceFrame > 8 else { return 1 }
        for index in 1..<scaleKeyframes.count {
            let left = scaleKeyframes[index - 1]
            let right = scaleKeyframes[index]
            if sourceFrame <= right.frame {
                let fraction = (sourceFrame - left.frame) / (right.frame - left.frame)
                // The clip stops before the scale settles. Finish that small
                // change once, then retain the settled scale for further turns.
                let progress = index == scaleKeyframes.count - 1
                    ? fraction * fraction * (3 - 2 * fraction) : fraction
                return CGFloat(left.scale + (right.scale - left.scale) * progress)
            }
        }
        return CGFloat(scaleKeyframes[scaleKeyframes.count - 1].scale)
    }

    private static func sampledSourceFrame(elapsed: TimeInterval, reducedMotion: Bool) -> Double {
        if reducedMotion { return 8 }
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed * 30
    }
}

private enum TypingIndicatorAnimation {
    static let labelDelay: TimeInterval = 14.0 / 30.0
    static let labelDuration: TimeInterval = 0.2
    static let labelInitialOffsetY: CGFloat = 9.0 * 24.0 / 56.0

    struct LabelState {
        let opacity: Double
        let offsetY: CGFloat
    }

    static func labelState(elapsed: TimeInterval, reducedMotion: Bool = false) -> LabelState {
        if reducedMotion { return LabelState(opacity: 1, offsetY: 0) }
        let time = elapsed.isFinite ? elapsed : 0
        let fraction = min(1, max(0, (time - labelDelay) / labelDuration))
        let remaining = (1 - fraction) * (1 - fraction)
        return LabelState(opacity: 1 - remaining,
                          offsetY: labelInitialOffsetY * CGFloat(remaining))
    }
}

/// One shared, bounded decoded set. NSCache can discard it under memory pressure;
/// the explicit warning hook also removes it. No frame decoding happens per tick.
private final class CubeThinkingGlyphFrames: NSObject {
    let frames: [CGImage]
    let decodedByteCount: Int
    private static let key: NSString = "thinking-cube"
    private static let cache: NSCache<NSString, CubeThinkingGlyphFrames> = {
        let value = NSCache<NSString, CubeThinkingGlyphFrames>()
        value.countLimit = 1
        value.totalCostLimit = CubeThinkingGlyphAnimation.decodedMemoryBudget
        return value
    }()
    private static let warningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in purgeCache() }

    private init(frames: [CGImage], decodedByteCount: Int) {
        self.frames = frames
        self.decodedByteCount = decodedByteCount
    }

    static func purgeCache() { cache.removeAllObjects() }

    static func load() -> CubeThinkingGlyphFrames? {
        _ = warningObserver
        if let existing = cache.object(forKey: key) { return existing }
        guard let atlas = UIImage(named: "ThinkingCubeAtlas")?.cgImage else { return nil }
        let side = CubeThinkingGlyphAnimation.tileSide
        let columns = CubeThinkingGlyphAnimation.atlasColumns
        let count = CubeThinkingGlyphAnimation.frameCount
        let rows = (count + columns - 1) / columns
        guard atlas.width == side * columns, atlas.height == side * rows else { return nil }
        var decoded: [CGImage] = []
        decoded.reserveCapacity(count)
        let space = CGColorSpaceCreateDeviceRGB()
        for index in 0..<count {
            let rect = CGRect(x: (index % columns) * side, y: (index / columns) * side,
                              width: side, height: side)
            guard let cropped = atlas.cropping(to: rect),
                  let bitmap = CGContext(data: nil, width: side, height: side,
                                         bitsPerComponent: 8, bytesPerRow: side * 4,
                                         space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
            guard let frame = bitmap.makeImage() else { return nil }
            decoded.append(frame)
        }
        // Include the source atlas as well as the tightly decoded frame buffers.
        let bytes = atlas.width * atlas.height * 4 + decoded.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        let result = CubeThinkingGlyphFrames(frames: decoded, decodedByteCount: bytes)
        cache.setObject(result, forKey: key, cost: bytes)
        return result
    }
}

/// The small Canvas restores the recorded camera pose from local dot frames.
/// Its global angle is sampled from elapsed time, never from the local loop phase.
private struct CubeThinkingGlyphFrame: View {
    @Environment(\.colorScheme) private var colorScheme
    let elapsed: TimeInterval
    var reducedMotion: Bool = false

    var body: some View {
        let animation = CubeThinkingGlyphAnimation.self
        let index = animation.frameIndex(elapsed: elapsed, reducedMotion: reducedMotion)
        Canvas { context, size in
            guard let resources = CubeThinkingGlyphFrames.load() else { return }
            var image = context.resolve(Image(decorative: resources.frames[index], scale: 1, orientation: .up))
            image.shading = .color(colorScheme == .dark ? .white : .black)
            let pivot = CGPoint(x: size.width * animation.pivotX, y: size.height * animation.pivotY)
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: .degrees(animation.globalRotationDegrees(elapsed: elapsed, reducedMotion: reducedMotion)))
            let scale = animation.globalScale(elapsed: elapsed, reducedMotion: reducedMotion)
            context.scaleBy(x: scale, y: scale)
            context.draw(image, in: CGRect(x: -pivot.x, y: -pivot.y, width: size.width, height: size.height))
        }
        .frame(width: 24, height: 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Deterministic production row: the icon and label share one elapsed time.
private struct TypingIndicatorFrame: View {
    let elapsed: TimeInterval
    var reducedMotion: Bool = false

    private static let label = "Ze正在思考中"

    var body: some View {
        let entry = TypingIndicatorAnimation.labelState(elapsed: elapsed, reducedMotion: reducedMotion)
        HStack(spacing: 4) {
            CubeThinkingGlyphFrame(elapsed: elapsed, reducedMotion: reducedMotion)
            ZStack(alignment: .leading) {
                labelText.foregroundStyle(ChatColors.secondaryText)
                if !reducedMotion {
                    let phase = CGFloat((max(0, elapsed) / ChatShimmerStyle.sweepDuration)
                        .truncatingRemainder(dividingBy: 1.0))
                    labelText
                        .foregroundStyle(Color.white)
                        .mask(sweepMask(phase: phase))
                        .accessibilityHidden(true)
                }
            }
            .opacity(entry.opacity)
            .offset(y: entry.offsetY)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Ze正在思考中"))
    }

    private var labelText: some View {
        Text(Self.label)
            .font(.callout.weight(.medium))
            .lineLimit(1)
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

struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: reduceMotion || scenePhase != .active)) { timeline in
            let elapsed = startedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
            TypingIndicatorFrame(elapsed: elapsed, reducedMotion: reduceMotion)
        }
        .onAppear {
            if startedAt == nil { startedAt = Date() }
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
