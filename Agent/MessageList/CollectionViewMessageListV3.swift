import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

private enum FooterTextContent: Equatable {
    case empty, whitespace, reply

    init(_ text: String) {
        if text.isEmpty {
            self = .empty
        } else {
            self = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) == nil ? .whitespace : .reply
        }
    }
}

/// Shared by snapshot retention, rendering and footer estimates.
private func reservesCompletionActionSpace(_ message: ChatMessage) -> Bool {
    message.role == .assistant && !message.isCompactedHistory && message.error == nil
        && message.blocks.contains { block in
            guard case .text = block.kind else { return false }
            return FooterTextContent(block.content) == .reply
        }
}

struct AssistantFooterPresentation: Equatable {
    let messageObject: ObjectIdentifier
    let showsTyping: Bool
    let showsResume: Bool
    let error: String?
    let interruptCount: Int
    let showsUsage: Bool
    let hasUsage: Bool
    let reservesActions: Bool
    let prominent: Bool

    @MainActor init(_ message: ChatMessage, isActive: Bool, canResume: Bool, showsUsage: Bool,
                    mode: ChatTranscriptDisplayMode = .standard) {
        messageObject = ObjectIdentifier(message)
        let hasVisibleContent = message.blocks.contains { $0.kind != .text || !$0.content.isEmpty }
        showsTyping = isActive && (mode == .simple ? SimpleTranscript.showsWaiting(message)
                                   : (!hasVisibleContent || message.isAwaitingModelResponse))
        error = message.error
        showsResume = canResume && message.error == nil
        interruptCount = mode == .standard ? message.streamInterruptCount : 0
        self.showsUsage = mode == .standard && showsUsage
        hasUsage = self.showsUsage && message.usage != nil
        reservesActions = mode == .standard && reservesCompletionActionSpace(message)
        prominent = message.error != nil || showsResume || isActive
    }

    var needsItem: Bool {
        showsTyping || showsResume || error != nil || interruptCount > 0 || showsUsage || reservesActions
    }
}

// MARK: - CollectionViewMessageListV3

/// V3 message list: builds on V2's cell-per-block model but simplifies
/// the scroll stability architecture:
///
/// - **Single height source**: UIKit self-sizing only (no GeometryReader)
/// - **3-tier height resolution**: measured cache → precalc (NSAttributedString) → estimate
/// - **2-state scroll model**: autoScrolling / userBrowsing (replaces V2's 6+ mechanisms)
/// - **O(1) message lookup**: UUID index rebuilt on each snapshot
struct CollectionViewMessageListV3: UIViewControllerRepresentable {
    @AppStorage(ConsecutiveToolCallsPolicy.preferenceKey) private var collapseConsecutiveToolCalls = ConsecutiveToolCallsPolicy.defaultEnabled
    @ObservedObject var vm: AIChatViewModel
    var inputFocused: Bool
    var transcriptDisplayMode: ChatTranscriptDisplayMode = .standard
    var onRetryMessage: ((UUID) -> Void)?
    var onRetryLast: (() -> Void)?
    var onReplyMessage: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onDismissSystemInfo: ((UUID) -> Void)?
    var onWithdraw: ((UUID) -> Void)?
    var onResume: (() -> Void)?
    var onStop: (() -> Void)?
    var onCompact: ((UUID) -> Void)?
    var onRevertCompact: (() -> Void)?
    var onForceSync: (() -> Void)?
    var onScreenshotImage: ((UIImage) -> Void)?
    var onShareMessage: ((UUID) -> Void)?
    var maxContentWidth: CGFloat
    var floatingBarHeight: CGFloat
    var inputBarHeight: CGFloat
    /// Which conversation this list is showing, used to key the saved scroll
    /// anchor. [T-foldable-scroll]
    var scrollMemoryKey: String? = nil
    /// Height of the floating chat header below the native navigation bar.
    var topOverlayInset: CGFloat = 0
    var geometryContext: ChatListGeometryContext? = nil
    var allowsCompletionGlow = false

    func makeUIViewController(context: Context) -> MessageListViewController {
        let vc = MessageListViewController()
        context.coordinator.updateScrollMemoryKey(scrollMemoryKey)
        if geometryContext == nil {
            context.coordinator.fallbackBottomInset = inputBarHeight + floatingBarHeight + 8
            context.coordinator.fallbackTopOverlayInset = max(0, topOverlayInset)
        }
        context.coordinator.setInitialTranscriptMode(transcriptDisplayMode)
        vm.chatSearch.updateTranscriptMode(transcriptDisplayMode)
        context.coordinator.attach(to: vc, vm: vm)
        context.coordinator.bindGeometry(geometryContext)
        // Drops are handled exclusively by the SwiftUI `.onDrop` on the chat
        // root view. Previously a UIDropInteraction here intercepted drops on
        // top of the collection view, which (a) suppressed SwiftUI's
        // isTargeted highlight on the first drop and (b) on iPadOS 26.5 left
        // SwiftUI's drop session state half-tracked, sticking the highlight
        // on the second drag. See T-filedrop GH#12.
        return vc
    }

    static func dismantleUIViewController(_ vc: MessageListViewController, coordinator: Coordinator) {
        coordinator.setAllowsCompletionGlow(false)
        coordinator.stopSimpleProjection()
        coordinator.detachGeometry()
    }

    func updateUIViewController(_ vc: MessageListViewController, context: Context) {
        let coord = context.coordinator
        // [T-ios-scrollbtn-vm-split] The coordinator captured `vm` once in
        // makeUIViewController → attach. SwiftUI reuses this representable's
        // platform VC (and coordinator) across AIChatView re-creations, so when
        // the ViewModelCache hands the re-created view a NEW AIChatViewModel
        // instance for the same session, the coordinator kept driving the OLD
        // one: every isNearBottom write landed on a VM nothing was observing,
        // while the overlay's VM stayed at its initial isNearBottom=true — the
        // floating ↑/↓ buttons never appeared again for the whole session
        // (device ring trace: coordinator vm read false at every sync while
        // the buttons stayed hidden at diff≈2700pt from the bottom).
        coord.updateScrollMemoryKey(scrollMemoryKey)
        coord.rebindViewModelIfNeeded(vm)
        coord.setAllowsCompletionGlow(allowsCompletionGlow)
        coord.onRetryMessage = onRetryMessage
        coord.onRetryLast = onRetryLast
        coord.onReplyMessage = onReplyMessage
        coord.onEdit = onEdit
        coord.onDelete = onDelete
        coord.onDismissSystemInfo = onDismissSystemInfo
        coord.onWithdraw = onWithdraw
        coord.onResume = onResume
        coord.onStop = onStop
        coord.onCompact = onCompact
        coord.onRevertCompact = onRevertCompact
        coord.onForceSync = onForceSync
        coord.onScreenshotImage = onScreenshotImage
        coord.onShareMessage = onShareMessage
        coord.keepSearchAfterWidthChange(vc.collectionView.bounds.width)
        coord.maxContentWidth = maxContentWidth
        coord.updateToolGroupingPreference(collapseConsecutiveToolCalls)

        coord.bindGeometry(geometryContext)
        if geometryContext == nil {
            coord.fallbackBottomInset = inputBarHeight + floatingBarHeight + 8
            coord.fallbackTopOverlayInset = max(0, topOverlayInset)
        }
        coord.refreshAfterForegroundIfNeeded()
        coord.applyViewportGeometry()
        coord.requestTranscriptMode(transcriptDisplayMode)

        // [T-message-list-empty-on-foreground] Backstop: if a snapshot was
        // deferred during a load (bind1) but binding 3's true→false edge was
        // missed (removeDuplicates collapse, or $isLoadingSession settling in
        // the same runloop cycle the snapshot was deferred), the list would be
        // stranded empty while the VM has messages. updateUIViewController runs
        // on every SwiftUI re-render (e.g. the toolbar updating — exactly the
        // observed "toolbar updates, list blank" symptom), so flush here once
        // loading has finished. Gated on NOT being in a streaming-suspend window
        // so we never pre-empt the suspend-resume machinery (which intentionally
        // holds hasPendingSnapshot during scroll-settle / background streaming);
        // that path has its own flush on resume. flushPendingSnapshotIfNeeded
        // no-ops when nothing is pending, so this is free on the happy path.
        if !vm.isLoadingSession && !vm.streamingUIUpdatesSuspended {
            coord.flushPendingSnapshotIfNeeded(caller: "updateUIVC-backstop")
        }
        coord.scheduleFooterReconciliation()

        // Viewport changes preserve the bottom or reading position in the
        // collection view's own layout pass. Focus is not a geometry clock;
        // a delayed scroll here used to fight dismissal and user gestures.

    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    enum Section { case main }
}

// MARK: - V3 Bridged Cell Views (no GeometryReader)

/// Header avatar and Ze label at the top of each assistant turn.
/// Name comes from SOUL.md (user-editable in Soul Settings); the
/// assistant avatar is fixed for a consistent Ze identity.
fileprivate struct BridgedAssistantHeaderV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat = 0
    /// [T-collapse-steps] Flips `isStepsCollapsed` and re-applies the snapshot.
    var onToggleSteps: (() -> Void)?
    /// True when the appearance setting is on and the turn has finished, which
    /// is the only time the disclosure glyph is meaningful.
    var stepsToggleEnabled: Bool = false
    @State private var soulMeta: SoulMetadata = SoulStore.cachedMetadata
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SoulAvatarView(size: 22)
                Text(soulMeta.name.isEmpty ? "Ze" : soulMeta.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ChatColors.primaryText)
                if let firstTokenLatency = message.firstTokenLatency {
                    FirstTokenLatencyPill(seconds: firstTokenLatency)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                }
            }
            if bridge.isActiveMessage, let startTime = message.taskDurationStartTime {
                AssistantTaskDurationView(liveStartTime: startTime)
            } else if !message.isAwaitingModelResponse,
                      message.error == nil,
                      let duration = message.taskDuration {
                AssistantTaskDurationView(
                    duration: duration,
                    onToggle: stepsToggleEnabled ? onToggleSteps : nil,
                    isCollapsed: message.isStepsCollapsed
                )
            }
        }
        .transaction { $0.disablesAnimations = false }
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), value: message.firstTokenLatency)
        .onAppear {
            // Reused/offscreen headers may have missed a Soul Settings change.
            soulMeta = SoulStore.cachedMetadata
        }
        .onReceive(NotificationCenter.default.publisher(for: .soulMdChanged)) { _ in
            soulMeta = SoulStore.cachedMetadata
        }
        .padding(.top, 4)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: maxWidth > 0 ? maxWidth : .infinity, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantHeader")
    }
}

struct FirstTokenLatencyPill: View {
    let seconds: TimeInterval

    private var durationText: String {
        seconds < 0.1 ? "<0.1秒" : String(format: "%.1f秒", seconds)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "timer")
                .font(.system(size: 9, weight: .medium))
            Text("首字 \(durationText)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(ChatColors.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel("首字耗时 \(durationText)")
    }
}

/// Disclosure header observing live membership as calls append to a group.
fileprivate struct BridgedAssistantToolGroupV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var firstBlock: AssistantBlock
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat
    var onToggle: () -> Void

    var body: some View {
        ConsecutiveToolCallsHeader(
            blocks: AssistantBlockPresentationSegment.tools(startingAt: firstBlock.id, in: message.blocks),
            isExpanded: firstBlock.isToolGroupExpanded,
            onToggle: onToggle,
            onCopyScreenshot: bridge.onCopyScreenshot,
            onCopyText: {
                UIPasteboard.general.string = message.blocks
                    .filter { $0.kind == .text }.map(\.content).joined(separator: "\n\n")
            }
        )
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .opacity(message.isCompactedHistory ? 0.5 : 1)
        .accessibilityIdentifier("assistantToolGroup")
    }
}

/// Single original block; existing text selection and context menu are retained.
fileprivate struct BridgedAssistantBlockV3: View {
    @ObservedObject var block: AssistantBlock
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat
    var simpleRow: SimpleTranscript.Row? = nil
    var segmentID: SimpleSegmentID? = nil
    var glow: CompletionGlow? = nil
    var onSegmentResize: ((SimpleSegmentID) -> Void)? = nil
    @State private var selectedImageID: SimpleSegmentID? = nil

    private var blockAccessibilityId: String {
        switch block.kind {
        case .text: return "assistantTextBlock"
        case .thinking: return "assistantThinkingBlock"
        case .shellTool: return "assistantShellBlock"
        case .fileReadTool: return "assistantFileReadBlock"
        case .fileWriteTool: return "assistantFileWriteBlock"
        case .fileEditTool: return "assistantFileEditBlock"
        case .browserTool: return "assistantBrowserBlock"
        case .readImageTool: return "assistantReadImageBlock"
        case .memoryTool: return "assistantMemoryBlock"
        case .info: return "assistantInfoBlock"
        }
    }

    var body: some View {
        Group {
            if let simpleRow {
                simpleContent(simpleRow)
                    .contentShape(Rectangle())
                    .contextMenu { simpleMessageActions }
                    .accessibilityActions { simpleMessageActions }
                    .frame(width: segmentID == nil ? nil : max(1, maxWidth), alignment: .leading)
                    .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .opacity(message.isCompactedHistory ? 0.5 : 1.0)
                    .accessibilityIdentifier(blockAccessibilityId)
            } else {
                standardContent
            }
        }
    }

    private var blockContent: some View {
        AssistantBlockView(
            block: block,
            message: message,
            isActiveMessage: bridge.isActiveMessage,
            thinkingLevel: bridge.thinkingLevel,
            commandStartTime: bridge.isActiveMessage ? bridge.commandStartTime : nil,
            onStop: bridge.isActiveMessage ? bridge.onStop : nil,
            onTapBlank: simpleRow == nil ? { _ in
                toggleUsage()
            } : nil,
            onCopyScreenshot: { bridge.onCopyScreenshot?() },
            // [T-selection-menu-ze-tts] Selection-menu TTS: whole-reply
            // replay is suppressed while this reply is still streaming (same
            // rule as the overlay context menu); Read Selection stays available.
            onReadAloud: simpleRow == nil ? (bridge.isStreaming ? nil : bridge.onReadAloud) : simpleReadAloud,
            onSpeakText: bridge.onSpeakText,
            browserPool: bridge.browserPool,
            toolSnapshots: bridge.toolSnapshots,
            highlightedBlockId: .constant(nil),
            detailBlock: $bridge.detailBlock,
            fitTextWidth: false
        )
    }

    @ViewBuilder private func simpleContent(_ row: SimpleTranscript.Row) -> some View {
        switch row {
        case .text, .standalone:
            if let segmentID {
                SimpleAssistantSegmentView(bodyModel: block.simpleBody, message: message, block: block,
                                           id: segmentID, width: max(1, maxWidth), bridge: bridge, glow: glow,
                                           selectedImageID: $selectedImageID,
                                           onResize: onSegmentResize)
                    .id(ChatSearchUnitKey(messageId: message.id, blockId: block.id, field: .body, segmentID: segmentID))
            }
        case .question:
            QuestionCardView(block: block).padding(.vertical, 4)
        }
    }

    private var simpleReadAloud: (() -> Void)? {
        guard !bridge.isStreaming, let read = bridge.onReadAloud,
              message.blocks.contains(where: { $0.kind == .text && SimpleTranscript.hasText($0.content) }) else { return nil }
        return read
    }

    @ViewBuilder private var simpleMessageActions: some View {
        let text = message.blocks.filter { $0.kind == .text }.map(\.content).joined(separator: "\n\n")
        if SimpleTranscript.hasText(text) {
            Button("Copy All") { UIPasteboard.general.string = ZeVisualizationStreaming.prepare(text, readable: true) }
            let members = segmentID.map { block.simpleBody.segments(inRow: $0) } ?? []
            if let segment = members.first(where: { $0.id == selectedImageID }) ?? members.first, let media = segment.media {
                Button("Copy Markdown") { UIPasteboard.general.string = block.simpleBody.markdownForCopy(segment) }
                if let link = media.linkDestination {
                    Button("Copy Link") { UIPasteboard.general.string = link }
                }
            } else {
                Button("Copy Markdown") { UIPasteboard.general.string = text }
            }
        }
        if let share = bridge.onCopyScreenshot { Button("Copy Screenshot", action: share) }
        if let retry = bridge.onRetry { Button("Retry", action: retry) }
        if let reply = bridge.onReply { Button("回复", action: reply) }
        if let read = simpleReadAloud { Button("Read from Start", action: read) }
        if let sync = bridge.onForceSync { Button("Force Sync", action: sync) }
        if let compact = bridge.onCompact { Button("Compact Above", role: .destructive, action: compact) }
    }

    private var standardContent: some View {
        blockContent
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier(blockAccessibilityId)
        // Context menu on zero-size overlay so it doesn't inflate self-sizing
        // (same pattern as BridgedAssistantFooterV3).
        .overlay {
            Color.clear.frame(width: 0, height: 0)
                .contextMenu {
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = ZeVisualizationStreaming.prepare(text, readable: true)
                    } label: {
                        Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                    }
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy Markdown"), systemImage: "text.quote")
                    }
                    if let onReply = bridge.onReply {
                        Button {
                            onReply()
                        } label: {
                            Label(String(localized: "回复"), systemImage: "arrowshape.turn.up.left")
                        }
                    }
                    if let onReadAloud = bridge.onReadAloud {
                        Button {
                            onReadAloud()
                        } label: {
                            Label(String(localized: "Read from Start"), systemImage: "play.circle")
                        }
                        // Greyed out while streaming so it can't clash with the
                        // live streaming TTS of the same reply.
                        .disabled(bridge.isStreaming)
                    }
                    if let onCopyScreenshot = bridge.onCopyScreenshot {
                        Button {
                            onCopyScreenshot()
                        } label: {
                            Label(String(localized: "Copy Screenshot"), systemImage: "camera.viewfinder")
                        }
                    }
                    if let onForceSync = bridge.onForceSync {
                        Divider()
                        Button {
                            onForceSync()
                        } label: {
                            Label(String(localized: "Force Sync"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(String(localized: "Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] This .contextMenu
                    // is on a zero-size Color.clear overlay (kept zero-size to
                    // avoid inflating self-sizing), so without an explicit preview
                    // SwiftUI snapshots that transparent overlay → see-through
                    // preview. Supply an opaque card of the message text.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    private func toggleUsage() {
        guard message.usage != nil else { return }
        if bridge.showUsage {
            withAnimation(.easeInOut(duration: 0.15)) { bridge.usageContentVisible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bridge.showUsage = false
            }
        } else {
            bridge.showUsage = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeInOut(duration: 0.2)) { bridge.usageContentVisible = true }
            }
        }
    }
}

private struct SimpleAssistantSegmentView: View {
    @ObservedObject var bodyModel: SimpleTranscript.Body
    let message: ChatMessage
    let block: AssistantBlock
    let id: SimpleSegmentID
    let width: CGFloat
    let bridge: CellStateBridgeV2
    let glow: CompletionGlow?
    @Binding var selectedImageID: SimpleSegmentID?
    let onResize: ((SimpleSegmentID) -> Void)?

    var body: some View {
        let members = bodyModel.segments(inRow: id)
        if members.count > 1 {
            SimpleImageGroup(segments: members, width: width, message: message, blockID: block.id,
                             selectedImageID: $selectedImageID)
        } else if let segment = members.first {
            let key = ChatSearchUnitKey(messageId: message.id, blockId: block.id, field: .body, segmentID: id)
            let copyMarkdown = { bodyModel.markdownForCopy(segment) }
            if let media = segment.media {
                SimpleStandaloneMedia(media: media, segmentID: id, key: key, width: width, bodyModel: bodyModel, message: message) { onResize?($0) }
                    .id(media)
            } else if case .table(let alignments, let rows)? = segment.blocks.first, id.kind == .table {
                SimpleStandaloneTable(alignments: alignments, rows: rows, width: width, key: key, bodyModel: bodyModel)
            } else {
                SelectableMarkdownView(markdown: "\(segment.hashValue):\(segment.searchText)", cachedContent: MarkdownContent(blocks: segment.blocks),
                                       messageId: message.id, blockId: block.id,
                                       onCopyScreenshot: bridge.onCopyScreenshot,
                                       onReadAloud: bridge.isStreaming ? nil : bridge.onReadAloud, onSpeakText: bridge.onSpeakText,
                                       allowsSearchHighlight: true, visualizationOwner: block, fitTextWidth: true,
                                       searchSegmentID: id, copyMarkdownSource: copyMarkdown)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: ChatBubbleStyle.cornerRadius))
                    .overlay {
                        if let glow {
                            CompletionGlowAnchor(glow: glow)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .modifier(ZeOpenURLHandler())
            }
        }
    }
}

/// Footer: typing indicator, error, resume banner, token usage, reply actions.
/// V3: No GeometryReader. Sheet moved to zero-size overlay to prevent
/// inflated self-sizing from sheet-capable view modifiers.
fileprivate struct BridgedAssistantFooterV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat
    var transcriptDisplayMode: ChatTranscriptDisplayMode = .standard
    @State private var transientCompletionAction: CompletionAction?

    private enum CompletionAction: Equatable {
        case copy
        case reply
        case play
        case retry
    }

    // showUsage and usageContentVisible are on bridge, toggled by double-tap on block cells.

    private var replyText: String {
        message.blocks
            .compactMap { block in
                if case .text = block.kind { return block.content }
                return nil
            }
            .joined(separator: "\n\n")
    }

    var body: some View {
        let footer = transcriptDisplayMode == .simple ? bridge.simpleFooter ?? AssistantFooterPresentation(
            message, isActive: false, canResume: false, showsUsage: false, mode: .simple)
            : AssistantFooterPresentation(message, isActive: bridge.isActiveMessage,
                                          canResume: bridge.canResume, showsUsage: bridge.showUsage)
        VStack(alignment: .leading, spacing: 8) {
            // Typing indicator
            if footer.showsTyping {
                AssistantReplyWaitingIndicator()
            }

            // Inline error
            if let error = footer.error {
                inlineError(error)
            }

            // Resume banner
            if footer.showsResume {
                resumeBanner
            }

            // Token usage
            if footer.interruptCount > 0 || footer.showsUsage {
                HStack(spacing: 6) {
                    if footer.interruptCount > 0 {
                        streamInterruptBadge(footer.interruptCount)
                    }
                    if footer.hasUsage, let usage = message.usage {
                        usageCapsule(usage)
                            .opacity(bridge.usageContentVisible ? 1 : 0)
                    }
                    Spacer()
                }
            }

            if footer.reservesActions {
                completionActionBar
                    .opacity(bridge.showsCompletionActions ? 1 : 0)
                    .allowsHitTesting(bridge.showsCompletionActions)
                    .accessibilityHidden(!bridge.showsCompletionActions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, footer.needsItem ? 16 : 0)
        .padding(.vertical, footer.needsItem ? 2 : 0)
        .opacity(message.isCompactedHistory ? 0.5 : 1.0)
        .accessibilityIdentifier("assistantFooter")
        // Sheet + contextMenu on zero-size overlay so they don't inflate self-sizing.
        // Both .sheet and .contextMenu wrap the view in interaction containers that
        // report inflated heights to systemLayoutSizeFitting, causing height oscillation.
        .overlay {
            Color.clear.frame(width: 0, height: 0)
                .contextMenu {
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = ZeVisualizationStreaming.prepare(text, readable: true)
                    } label: {
                        Label(String(localized: "Copy All"), systemImage: "doc.on.doc")
                    }
                    Button {
                        let text = message.blocks
                            .filter { if case .text = $0.kind { return true }; return false }
                            .map(\.content).joined(separator: "\n\n")
                        UIPasteboard.general.string = text
                    } label: {
                        Label(String(localized: "Copy Markdown"), systemImage: "text.quote")
                    }
                    if let onReply = bridge.onReply {
                        Button {
                            onReply()
                        } label: {
                            Label(String(localized: "回复"), systemImage: "arrowshape.turn.up.left")
                        }
                    }
                    if let onReadAloud = bridge.onReadAloud {
                        Button {
                            onReadAloud()
                        } label: {
                            Label(String(localized: "Read from Start"), systemImage: "play.circle")
                        }
                        // Greyed out while streaming so it can't clash with the
                        // live streaming TTS of the same reply.
                        .disabled(bridge.isStreaming)
                    }
                    if let onCopyScreenshot = bridge.onCopyScreenshot {
                        Button {
                            onCopyScreenshot()
                        } label: {
                            Label(String(localized: "Copy Screenshot"), systemImage: "camera.viewfinder")
                        }
                    }
                    if let onForceSync = bridge.onForceSync {
                        Divider()
                        Button {
                            onForceSync()
                        } label: {
                            Label(String(localized: "Force Sync"), systemImage: "arrow.triangle.2.circlepath.icloud")
                        }
                    }
                    if let onCompact = bridge.onCompact {
                        Divider()
                        Button(role: .destructive) {
                            onCompact()
                        } label: {
                            Label(String(localized: "Compact Above"), systemImage: "arrow.down.right.and.arrow.up.left")
                        }
                    }
                } preview: {
                    // [T-ios-longpress-menu-preview-background] Opaque preview
                    // for the footer's zero-size Color.clear contextMenu overlay.
                    MessageContextMenuPreview(text: message.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content).joined(separator: "\n\n"))
                }
        }
    }

    // MARK: - Footer sub-views

    private var completionActionBar: some View {
        HStack(spacing: 2) {
            // Reply first: the most-used action sits at the leading edge.
            completionActionEntry(index: 0) {
                completionActionButton(
                    systemImage: transientCompletionAction == .reply ? "checkmark" : "arrowshape.turn.up.left",
                    isSelected: transientCompletionAction == .reply,
                    selectedColor: .accentColor,
                    accessibilityLabel: String(localized: "回复"),
                    action: {
                        flashCompletionAction(.reply)
                        bridge.onReply?()
                    }
                )
                .disabled(bridge.onReply == nil)
            }

            completionActionEntry(index: 1) {
                completionActionButton(
                systemImage: transientCompletionAction == .copy ? "checkmark" : "rectangle.on.rectangle",
                isSelected: transientCompletionAction == .copy,
                selectedColor: .green,
                accessibilityLabel: String(localized: "Copy")
                ) {
                    UIPasteboard.general.string = ZeVisualizationStreaming.prepare(replyText, readable: true)
                    flashCompletionAction(.copy)
                    AppFeedback.haptic()
                }
            }

            completionActionEntry(index: 2) {
                completionActionButton(
                    systemImage: "play",
                    symbolSize: 17,
                    isSelected: transientCompletionAction == .play,
                    accessibilityLabel: String(localized: "Read from Start"),
                    action: {
                        flashCompletionAction(.play)
                        bridge.onReadAloud?()
                    }
                )
                .disabled(bridge.onReadAloud == nil || bridge.isStreaming)
            }


            completionActionEntry(index: 3) {
                completionActionButton(
                    systemImage: "arrow.clockwise",
                    isSelected: transientCompletionAction == .retry,
                    accessibilityLabel: String(localized: "Retry"),
                    action: {
                        flashCompletionAction(.retry)
                        bridge.onRetry?()
                    }
                )
                .disabled(bridge.onRetry == nil)
            }

            Spacer(minLength: 6)

            Text(String(localized: "AI-generated content may not always be accurate",
                        comment: "Disclaimer shown beside assistant reply actions"))
                .font(.system(size: 10, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(ChatColors.tertiaryText)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.62)
                .layoutPriority(-1)
                .accessibilityLabel(String(localized: "AI-generated content may not always be accurate",
                                            comment: "Disclaimer shown beside assistant reply actions"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 1)
    }

    /// Visibility may fade, but the real action row remains in the layout.
    private func completionActionEntry<Content: View>(
        index: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .animation(
                .easeOut(duration: 0.28).delay(Double(index) * 0.07),
                value: bridge.showsCompletionActions
            )
    }

    private func completionActionButton(
        systemImage: String,
        symbolSize: CGFloat = 14,
        isSelected: Bool = false,
        selectedColor: Color = .accentColor,
        accessibilityLabel: String,
        action: (() -> Void)?
    ) -> some View {
        Button {
            action?()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .medium))
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? selectedColor : ChatColors.secondaryText)
        .accessibilityLabel(accessibilityLabel)
    }

    private func flashCompletionAction(_ action: CompletionAction) {
        withAnimation(.easeOut(duration: 0.12)) {
            transientCompletionAction = action
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard transientCompletionAction == action else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                transientCompletionAction = nil
            }
        }
    }

    @ViewBuilder
    private func inlineError(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                SearchHighlightText(error, key: .init(messageId: message.id, blockId: nil, field: .footerError)).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = error
                } label: {
                    Label(String(localized: "Copy Error"), systemImage: "doc.on.doc")
                }
            }
            Spacer()
            if bridge.autoRetryAttempt > 0 {
                Text("将在 \(bridge.autoRetryCountdown) 秒后重试（\(bridge.autoRetryAttempt)/\(AIChatViewModel.retryDelays.count)）")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12)).clipShape(Capsule())
            } else if let onRetry = bridge.onRetry {
                Button(action: onRetry) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                        Text(String(localized: "Retry")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(ChatColors.primaryText)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(ChatColors.primaryText.opacity(0.15)).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var resumeBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill").font(.caption).foregroundStyle(.orange)
                Text(String(localized: "Interrupted — tap Resume to continue")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let onResume = bridge.onResume {
                Button(action: onResume) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.caption.weight(.semibold))
                        Text(String(localized: "Resume")).font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.orange).clipShape(Capsule())
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func usageCapsule(_ usage: TokenUsage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer").font(.system(size: 9))
            Text(usageSummary(usage)).font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(ChatColors.tertiaryText)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(ChatColors.userBubble.opacity(0.6)).clipShape(Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    @ViewBuilder
    private func streamInterruptBadge(_ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
            Text("\(count)").font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(Color.orange.opacity(0.8))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
    }

    private func usageSummary(_ u: TokenUsage) -> String {
        var parts: [String] = []
        if u.latestContextTokens > 0 { parts.append("上下文 \(fmtTok(u.latestContextTokens))") }
        parts.append("输入 \(fmtTok(u.inputTokens))")
        parts.append("输出 \(fmtTok(u.outputTokens))")
        if u.cacheReadTokens > 0 { parts.append("缓存读取 \(fmtTok(u.cacheReadTokens))") }
        if u.cacheCreationTokens > 0 { parts.append("缓存写入 \(fmtTok(u.cacheCreationTokens))") }
        return parts.joined(separator: " · ")
    }
    private func fmtTok(_ c: Int) -> String {
        c >= 1000 ? (c >= 10000 ? "\(c/1000)k" : String(format: "%.1fk", Double(c)/1000)) : "\(c)"
    }
}

/// Wraps the existing ChatMessageRow for user / compactDivider / systemInfo messages.
/// V3: No GeometryReader.
private struct BridgedWholeMessageV3: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    /// Dismisses this browser-control systemInfo row; only wired for capsule rows.
    var onDismissSystemInfo: (() -> Void)?
    var maxWidth: CGFloat

    var body: some View {
        ChatMessageRow(
            message: message,
            isActiveMessage: false,
            commandStartTime: nil,
            onStop: nil,
            onRetry: bridge.onRetry,
            onReply: bridge.onReply,
            onOpenQuote: bridge.onShowQuotePreview,
            onEdit: bridge.onEdit,
            onDelete: bridge.onDelete,
            onWithdraw: bridge.onWithdraw,
            autoRetryAttempt: 0,
            autoRetryCountdown: 0,
            canResume: false,
            onResume: nil,
            onCompact: bridge.onCompact,
            onCopyScreenshot: bridge.onCopyScreenshot,
            onShowCompactSummary: bridge.onShowCompactSummary,
            onDismissSystemInfo: onDismissSystemInfo,
            onToggleUserMessageExpansion: bridge.onToggleUserMessageExpansion,
            browserPool: nil,
            toolSnapshots: [],
            maxWidth: maxWidth
        )
        .frame(maxWidth: maxWidth > 0 ? maxWidth : nil)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(message.role == .user ? "userMessage" : "wholeMessage")
    }
}

// MARK: - Session export turn

/// [T-session-share-native] One assistant reply, composed from the SAME three
/// views the message list uses. `ChatMessageRow` alone only covers the blocks,
/// so exports built from it lost the avatar/name row, the first-token pill,
/// the task duration, the token capsule and the copy/play/retry bar that the
/// copy-screenshot path shows.
struct SessionExportAssistantTurn: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var bridge: CellStateBridgeV2
    var maxWidth: CGFloat = 0

    private var segments: [AssistantBlockPresentationSegment] {
        AssistantBlockPresentationSegment.make(message.blocks, enabled: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BridgedAssistantHeaderV3(message: message, bridge: bridge, maxWidth: maxWidth)

            ForEach(segments) { segment in
                if segment.isToolGroup {
                    BridgedAssistantToolGroupV3(message: message,
                                                firstBlock: segment.blocks[0],
                                                bridge: bridge,
                                                maxWidth: maxWidth,
                                                onToggle: {})
                } else if let block = segment.blocks.first {
                    BridgedAssistantBlockV3(block: block,
                                            message: message,
                                            bridge: bridge,
                                            maxWidth: maxWidth)
                }
            }

            BridgedAssistantFooterV3(message: message, bridge: bridge, maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Per-type Cell Subclasses (enable correct reuse)

private final class WholeMessageCellV3: SelfSizingCell {}
private final class AssistantHeaderCellV3: SelfSizingCell {}
private final class AssistantBlockCellV3: SelfSizingCell {
    let completionGlow = CompletionGlow()
    var glowItem: MessageListItem?

    override func prepareForReuse() {
        super.prepareForReuse()
        glowItem = nil
        completionGlow.reset()
    }
}
private final class AssistantFooterCellV3: SelfSizingCell {}

private struct CompletionGlowAnchor: UIViewRepresentable {
    let glow: CompletionGlow

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        glow.anchor = view
    }
}

@MainActor
fileprivate final class CompletionGlow {
    weak var anchor: UIView?
    private weak var pulse: CALayer?

    func reset() {
        clear()
        anchor = nil
    }

    func clear() {
        pulse?.removeFromSuperlayer()
        pulse = nil
    }

    func play(in cell: UICollectionViewCell, collectionView: UICollectionView) {
        guard let anchor, anchor.window != nil, anchor.isDescendant(of: cell), !anchor.bounds.isEmpty,
              anchor.convert(anchor.bounds, to: collectionView).intersects(collectionView.bounds.inset(by: collectionView.adjustedContentInset)) else { return }
        clear()
        let frame = anchor.convert(anchor.bounds, to: cell)
        let outline = UIBezierPath(roundedRect: frame, cornerRadius: ChatBubbleStyle.cornerRadius).cgPath
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let rise = NSNumber(value: 100.0 / 550.0)
        let pulse = CALayer()
        pulse.frame = cell.bounds
        pulse.opacity = 0
        let stroke = CAShapeLayer()
        stroke.frame = pulse.bounds
        stroke.path = outline
        stroke.fillColor = nil
        stroke.strokeColor = UIColor.systemBlue.cgColor
        stroke.lineWidth = 1
        pulse.addSublayer(stroke)

        if !reduceMotion {
            let haze = CAShapeLayer()
            haze.frame = pulse.bounds
            haze.path = outline
            haze.fillColor = nil
            haze.strokeColor = UIColor.systemBlue.cgColor
            haze.lineWidth = 1
            haze.shadowColor = UIColor.systemBlue.cgColor
            haze.shadowOpacity = 1
            haze.shadowOffset = .zero
            haze.shadowRadius = 2
            pulse.addSublayer(haze)

            let expanded = UIBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -3),
                                        cornerRadius: ChatBubbleStyle.cornerRadius + 3).cgPath
            let expansion = CAKeyframeAnimation(keyPath: "path")
            expansion.values = [outline, outline, expanded]
            expansion.keyTimes = [0, rise, 1]
            expansion.duration = 0.55
            haze.add(expansion, forKey: "path")
            let blur = CAKeyframeAnimation(keyPath: "shadowRadius")
            blur.values = [2, 2, 5]
            blur.keyTimes = expansion.keyTimes
            blur.duration = expansion.duration
            haze.add(blur, forKey: "shadowRadius")
        }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = reduceMotion ? [0.18, 0] : [0, 0.35, 0]
        opacity.keyTimes = reduceMotion ? [0, 1] : [0, rise, 1]
        opacity.duration = 0.55
        self.pulse = pulse
        CATransaction.begin()
        CATransaction.setCompletionBlock { pulse.removeFromSuperlayer() }
        cell.layer.addSublayer(pulse)
        pulse.add(opacity, forKey: "opacity")
        CATransaction.commit()
    }
}

// MARK: - V3 Coordinator

extension CollectionViewMessageListV3 {

    /// Scroll mode: the only two states V3 needs.
    enum ScrollMode {
        /// Content growth pins offset to bottom. Self-sizing accepted normally.
        case autoScrolling
        /// User is reading above the bottom. Layout changes preserve offset.
        case userBrowsing
    }

    final class Coordinator: NSObject, UICollectionViewDelegate, UIScrollViewDelegate, UICollectionViewDataSourcePrefetching {
        // Callbacks
        var onRetryMessage: ((UUID) -> Void)?
        var onRetryLast: (() -> Void)?
        var onReplyMessage: ((UUID) -> Void)?
        var onEdit: ((UUID) -> Void)?
        var onDelete: ((UUID) -> Void)?
        var onDismissSystemInfo: ((UUID) -> Void)?
        var onWithdraw: ((UUID) -> Void)?
        var onResume: (() -> Void)?
        var onStop: (() -> Void)?
        var onCompact: ((UUID) -> Void)?
        var onRevertCompact: (() -> Void)?
        var onForceSync: (() -> Void)?
        var onScreenshotImage: ((UIImage) -> Void)?
        var onShareMessage: ((UUID) -> Void)?
        var maxContentWidth: CGFloat = 0
        private var collapseConsecutiveToolCalls = (UserDefaults.standard.object(forKey: ConsecutiveToolCallsPolicy.preferenceKey) as? Bool) ?? ConsecutiveToolCallsPolicy.defaultEnabled
        private var forceUncollapsedToolsForScreenshot = false

        // [T-ios-user-collapse-smooth] Long-user-message disclosure transaction.
        /// Master switch for the animated disclosure pass. Flip to false to
        /// fall back to the historical instant pass (also used automatically
        /// while the user is actively scrolling or Reduce Motion is on).
        private var disclosureAnimationEnabled = true
        private static let disclosureAnimationDuration: TimeInterval = 0.28
        /// Cell momentarily clipped while the disclosure morphs, so the
        /// already-final SwiftUI content wipes behind the animating bubble
        /// edge instead of overflowing the still-growing box.
        private weak var disclosureClippedCell: SelfSizingCell?
        private var disclosureClippedCellRestore: (cell: Bool, content: Bool)?

        func updateToolGroupingPreference(_ enabled: Bool) {
            guard collapseConsecutiveToolCalls != enabled else { return }
            collapseConsecutiveToolCalls = enabled
            guard let vm else { return }
            applySnapshot(messages: vm.messages, caller: "tool-group-preference")
        }

        private func toggleUserMessageExpansion(messageId: UUID) {
            guard let vm,
                  let message = vm.messages.first(where: { $0.id == messageId }),
                  message.role == .user,
                  !message.isQueued else { return }

            // Keep the viewport transaction synchronous and mutate the canonical
            // VM message, rather than the UIHostingConfiguration's captured
            // reference. This prevents the first tap from being consumed by a
            // stale host and prevents the following tap from appearing inverted.
            NotificationCenter.default.post(
                name: .userMessageExpansionWillToggle,
                object: messageId,
                userInfo: ["expanded": message.isUserTextExpanded]
            )
            message.isUserTextExpanded.toggle()
            NotificationCenter.default.post(
                name: .userMessageExpansionToggled,
                object: messageId,
                userInfo: ["expanded": message.isUserTextExpanded]
            )
        }

        private func toggleToolGroup(messageId: UUID, firstBlockId: UUID) {
            guard !forceUncollapsedToolsForScreenshot, let vm,
                  let message = vm.messages.first(where: { $0.id == messageId }),
                  let first = message.blocks.first(where: { $0.id == firstBlockId }),
                  let cv = viewController?.collectionView else { return }
            let item = MessageListItem.assistantToolGroup(messageId, firstBlockId)
            let oldY = dataSource?.indexPath(for: item).flatMap {
                cv.layoutAttributesForItem(at: $0)?.frame.minY
            }
            let offset = cv.contentOffset
            scrollMode = .userBrowsing
            first.isToolGroupExpanded.toggle()
            applySnapshot(messages: vm.messages, caller: "tool-group-toggle")
            cv.layoutIfNeeded()
            if let oldY, let index = dataSource?.indexPath(for: item),
               let newY = cv.layoutAttributesForItem(at: index)?.frame.minY {
                let minimum = -cv.adjustedContentInset.top
                let maximum = max(minimum, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
                cv.setContentOffset(CGPoint(x: offset.x, y: min(maximum, max(minimum, offset.y + newY - oldY))), animated: false)
            }
        }

        /// [T-collapse-steps] Folds or unfolds a finished turn's reasoning and
        /// tool trail. Keeps the header anchored so the chevron does not jump
        /// under the finger.
        private func toggleStepsCollapsed(messageId: UUID) {
            guard !forceUncollapsedToolsForScreenshot, let vm,
                  let message = vm.messages.first(where: { $0.id == messageId }),
                  let cv = viewController?.collectionView else { return }
            let item = MessageListItem.assistantHeader(messageId)
            let oldY = dataSource?.indexPath(for: item).flatMap {
                cv.layoutAttributesForItem(at: $0)?.frame.minY
            }
            let offset = cv.contentOffset
            scrollMode = .userBrowsing
            message.isStepsCollapsed.toggle()
            applySnapshot(messages: vm.messages, caller: "steps-collapse-toggle")
            cv.layoutIfNeeded()
            if let oldY, let index = dataSource?.indexPath(for: item),
               let newY = cv.layoutAttributesForItem(at: index)?.frame.minY {
                let minimum = -cv.adjustedContentInset.top
                let maximum = max(minimum, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
                cv.setContentOffset(CGPoint(x: offset.x, y: min(maximum, max(minimum, offset.y + newY - oldY))), animated: false)
            }
        }

        #if DEBUG
        deinit {
            // [DecelDisplayLink] CADisplayLink retains its target — must
            // invalidate on Coordinator teardown to break the cycle.
            decelDisplayLink?.invalidate()
        }
        #endif

        // === Scroll mode (replaces V2's 6+ mechanisms) ===
        var scrollMode: ScrollMode = .autoScrolling {
            didSet {
                // Explicit browsing (including search/restoration/disclosure)
                // supersedes the temporary session-load follow intent.
                if scrollMode != oldValue { invalidatePositionRequests() }
                if scrollMode == .userBrowsing { clampAfterSessionLoad = false }
                // Mirror to the layout so its invalidationContext can glue the
                // streaming cell's bottom to the viewport while pinned (smooth
                // grow) and skip that adjustment while the user browses.
                // [T-ios-stream-natural-transitions]
                viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            }
        }
        /// True during settleAfterInteraction flush — suppresses contentSize KVO offset changes.
        private var isFlushing = false
        private var geometryContext: ChatListGeometryContext?
        private var geometryMountGeneration: UInt?
        private var viewportGeometryCommitDepth = 0
        private enum PositionReason: String, Hashable {
            case geometry, resize, keyboardEnd, snapshot, snapshotShrink, measurement, contentSize, contentGrowth
            case signal, coalesced, foreground, attachment, disclosure, explicit, sendEnded, transcriptMode

            static let passiveMeasurement: Set<PositionReason> = [.measurement, .contentSize, .contentGrowth]
            static let streamingGrowth = passiveMeasurement.union([.signal])
            static let keyboardSettlement = streamingGrowth.union([
                .keyboardEnd, .geometry, .resize, .snapshot, .snapshotShrink
            ])
        }
        private struct PositionStamp: Equatable {
            let view: ObjectIdentifier
            let window: ObjectIdentifier
            let vm: ObjectIdentifier
            let mount: UInt?
            let generation: UInt
        }
        private struct PositionAnchor {
            let readingItem: MessageListItem?
            let readingY: CGFloat
            let tailItem: MessageListItem?
            let tailGap: CGFloat
            let wasNearBottom: Bool
        }
        private enum SendPosition {
            case inserting(acceptedUser: UUID?, anchor: PositionAnchor?)
            case reveal(MessageListItem)
            case waiting(MessageListItem)
        }
        private var positionGeneration: UInt = 0
        private var positionOwnerGeneration: UInt = 0
        private var settledPlacementGeneration: UInt?
        private var positionReasons: Set<PositionReason> = []
        private var positionAnchor: PositionAnchor?
        private var foregroundAnchor: PositionAnchor?
        private var keyboardAnchor: PositionAnchor?
        private var keyboardInFlight = false
        private var sendPosition: SendPosition?
        private var growingItems: Set<MessageListItem> = []
        private var layoutAdjustedStreamingGrowth = false
        private var resolvingPosition = false
        private var lastPositionSources = ""
        private var lastPositionTarget: CGFloat?
        var fallbackBottomInset: CGFloat = 0
        var fallbackTopOverlayInset: CGFloat = 0

        func bindGeometry(_ context: ChatListGeometryContext?) {
            guard geometryContext !== context || geometryMountGeneration != context?.mountGeneration else { return }
            detachGeometry()
            geometryContext = context
            geometryMountGeneration = context?.mountGeneration
            guard let cv = viewController?.collectionView else { return }
            context?.registerList(cv, reconcile: { [weak self] in self?.applyViewportGeometry() },
                                  keyboard: { [weak self] active in self?.keyboardPositionTransition(active) },
                                   commit: { [weak self] finishing, changes in
                if let self { self.performViewportGeometryCommit(finishing: finishing, changes) } else { changes() }
            })
        }

        func detachGeometry() {
            if let cv = viewController?.collectionView { geometryContext?.unregisterList(cv) }
            geometryContext = nil
            geometryMountGeneration = nil
            keyboardInFlight = false
            invalidatePositionRequests()
        }

        func performViewportGeometryCommit(finishing: Bool = true, _ changes: () -> Void) {
            let layout = viewController?.messageListLayout
            let cv = viewController?.collectionView
            enqueuePosition(finishing ? .keyboardEnd : .geometry)
            viewportGeometryCommitDepth += 1
            layout?.viewportGeometryCommitDepth += 1
            defer {
                layout?.viewportGeometryCommitDepth -= 1
                viewportGeometryCommitDepth -= 1
                if viewportGeometryCommitDepth == 0 {
                    if !positionReasons.isEmpty {
                        cv?.setNeedsLayout()
                        cv?.layoutIfNeeded()
                    }
                    schedulePendingSearchPlacement()
                }
            }
            if finishing { UIView.performWithoutAnimation(changes) } else { changes() }
        }

        #if DEBUG
        func sessionLoadClampEvidence() -> (pending: Bool, deadline: Date) {
            // Read raw state, without consuming/expiring it before the test.
            (clampAfterSessionLoad, clampDeadline)
        }

        func completionActionEvidence(for messageID: UUID) -> (reservesSpace: Bool, visible: Bool, hasBody: Bool, footerHeight: CGFloat?) {
            guard let message = vm?.messages.first(where: { $0.id == messageID }),
                  let source = dataSource, let cv = viewController?.collectionView else {
                return (false, false, false, nil)
            }
            let items = source.snapshot().itemIdentifiers
            let hasBody = items.contains { item in
                if case .assistantBlock(let id, _, _) = item { return id == messageID }
                return false
            }
            let footerHeight = source.indexPath(for: .assistantFooter(messageID))
                .flatMap { cv.layoutAttributesForItem(at: $0)?.frame.height }
            return (reservesCompletionActionSpace(message), cellBridges[messageID]?.showsCompletionActions == true,
                    hasBody, footerHeight)
        }

        func sendLayoutGeometryEvidence() -> [String: Any] {
            let configuration = geometryContext?.configuration
            return ["effectiveInputHeight": geometryContext?.effectiveInputHeight ?? 0,
                    "reservedInputHeight": baseBottomInset - (configuration?.attachmentHeight ?? 0)
                        - (configuration?.floatingHeight ?? 0) - 8,
                    "baseBottomInset": baseBottomInset, "commitDepth": viewportGeometryCommitDepth,
                    "positionGeneration": positionGeneration, "positionSources": lastPositionSources,
                    "positionTarget": lastPositionTarget.map { Double($0) } ?? 0,
                    "hasPositionTarget": lastPositionTarget != nil, "auto": scrollMode == .autoScrolling,
                    "keyboardInFlight": keyboardInFlight, "hasPlacedList": didRestoreScroll,
                    "sessionID": vm?.sessionId ?? "", "sendPosition": sendPositionEvidence]
        }

        private var sendPositionEvidence: String {
            switch sendPosition {
            case .inserting?: return "inserting"
            case .reveal?: return "reveal"
            case .waiting?: return "waiting"
            case nil: return "none"
            }
        }
        #endif

        func applyViewportGeometry() {
            guard let cv = viewController?.collectionView else { return }
            geometryContext?.reportSearchContentBounds()
            defer { schedulePendingSearchPlacement() }
            let bottom = geometryContext?.baseBottomInset ?? fallbackBottomInset
            let top = geometryContext?.configuration.topOverlayInset ?? fallbackTopOverlayInset
            let topChanged = abs(topOverlayInset - top) > 0.5
            guard abs(baseBottomInset - bottom) > 0.5 || topChanged
                || abs(cv.contentInset.top - baseContentInsetTop) > 0.5 else { return }
            enqueuePosition(.geometry)
            if viewportGeometryCommitDepth == 0 { cv.layoutIfNeeded() }
        }

        private func positionStamp() -> PositionStamp? {
            positionStamp(generation: positionGeneration)
        }

        private func positionStamp(generation: UInt) -> PositionStamp? {
            guard let cv = viewController?.collectionView, let window = cv.window, let vm else { return nil }
            return PositionStamp(view: ObjectIdentifier(cv), window: ObjectIdentifier(window),
                                 vm: ObjectIdentifier(vm), mount: geometryMountGeneration,
                                 generation: generation)
        }

        private func supersedeOrdinaryPositionRequests() {
            positionGeneration &+= 1
            positionReasons.removeAll()
            positionAnchor = nil
            foregroundAnchor = nil
            keyboardAnchor = nil
            growingItems.removeAll()
            layoutAdjustedStreamingGrowth = false
            pendingScrollWork?.cancel()
            pendingScrollWork = nil
        }

        private func invalidatePositionRequests() {
            positionOwnerGeneration &+= 1
            supersedeOrdinaryPositionRequests()
            searchPositionOwner = nil
            cancelSearchPlacement()
            sendPosition = nil
            isAnimatingScrollToBottom = false
        }

        private func beginDirectScroll() -> PositionStamp? {
            invalidatePositionRequests()
            return positionStamp(generation: positionOwnerGeneration)
        }

        private func ownsDirectScroll(_ stamp: PositionStamp) -> Bool {
            stamp == positionStamp(generation: positionOwnerGeneration)
        }

        private func prepareDirectScroll(ownedBy stamp: PositionStamp) -> Bool {
            guard ownsDirectScroll(stamp) else { return false }
            // A retry can discard ordinary work, but cannot claim new ownership.
            supersedeOrdinaryPositionRequests()
            return true
        }

        private func positionIsAvailable(in cv: UICollectionView) -> Bool {
            cv.window != nil && !cv.isTracking && !cv.isDragging && !cv.isDecelerating
                && !isFlushing && !isAnimatingScrollToBottom && userMessageViewportAnchor == nil
        }

        private func itemFrame(_ item: MessageListItem?, in cv: UICollectionView) -> CGRect? {
            guard let item, let index = dataSource?.indexPath(for: item) else { return nil }
            return cv.collectionViewLayout.layoutAttributesForItem(at: index)?.frame
        }

        private func capturePosition(in cv: UICollectionView, presented: Bool = false,
                                     wasNearBottom: Bool? = nil) -> PositionAnchor? {
            guard let window = cv.window, cv.bounds.height > 0, didRestoreScroll else { return nil }
            let origin = cv.convert(cv.bounds, to: window).minY
            let top = cv.contentOffset.y + cv.adjustedContentInset.top
            let reading = cv.indexPathsForVisibleItems.sorted().first { index in
                (cv.collectionViewLayout.layoutAttributesForItem(at: index)?.frame.maxY ?? -.infinity) > top
            }
            let item = reading.flatMap { dataSource?.itemIdentifier(for: $0) }
            let bottom = cv.bounds.height - baseBottomInset - cv.safeAreaInsets.bottom
            let tail = previousSnapshotIds.last
            let readingY = origin + (itemFrame(item, in: cv)?.minY ?? cv.contentOffset.y) - cv.contentOffset.y
            let displayReadingY = presented ? reading.flatMap { index -> CGFloat? in
                guard let layer = cv.cellForItem(at: index)?.layer.presentation() else { return nil }
                return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).minY
            } : nil
            return PositionAnchor(readingItem: item,
                                  readingY: displayReadingY ?? readingY,
                                  tailItem: tail,
                                  tailGap: cv.contentOffset.y + bottom - (itemFrame(tail, in: cv)?.maxY ?? cv.contentSize.height),
                                  wasNearBottom: wasNearBottom ?? isNearBottom())
        }

        private func enqueuePosition(_ reason: PositionReason, anchor: PositionAnchor? = nil, scheduleLayout: Bool = true) {
            guard let cv = viewController?.collectionView, !resolvingPosition || reason == .explicit else { return }
            if let anchor, reason == .foreground {
                positionAnchor = anchor
            } else if positionAnchor == nil, positionIsAvailable(in: cv) {
                positionAnchor = anchor ?? keyboardAnchor ?? capturePosition(in: cv)
            }
            positionReasons.insert(reason)
            if scheduleLayout { cv.setNeedsLayout() }
        }

        private func keyboardPositionTransition(_ active: Bool) {
            let interrupting = keyboardInFlight && active
            let previousNearBottom = keyboardAnchor?.wasNearBottom
            keyboardInFlight = active
            if active {
                // Drop pre-keyboard anchors, including the deferred foreground
                // pass. Keep the send and explicit-scroll ownership unchanged.
                supersedeOrdinaryPositionRequests()
                if let cv = viewController?.collectionView, positionIsAvailable(in: cv) {
                    keyboardAnchor = capturePosition(in: cv, presented: interrupting, wasNearBottom: previousNearBottom)
                    positionAnchor = keyboardAnchor
                }
            }
        }

        private func beginPositionLayout() -> Bool {
            layoutAdjustedStreamingGrowth = false
            guard let cv = viewController?.collectionView else { return false }
            if positionIsAvailable(in: cv), positionAnchor == nil {
                positionAnchor = keyboardAnchor ?? capturePosition(in: cv)
            }
            if viewportGeometryCommitDepth == 0, canUseKeyboardLayoutTarget(in: cv, reasons: positionReasons) {
                UIView.performWithoutAnimation {
                    prepareViewportInsets(caller: PositionReason.keyboardEnd.rawValue,
                                          forceRelax: positionReasons.contains(.snapshotShrink))
                }
            }
            return keyboardInFlight && didRestoreScroll
                && !positionReasons.contains(.foreground) && !positionReasons.contains(.keyboardEnd)
        }

        private func isPresentableBlock(_ item: MessageListItem) -> Bool {
            if transcriptMode == .simple { return simpleRows[item] != nil }
            guard case .assistantBlock(let id, let blockID, _) = item,
                  let index = messageIndex[id], snapshotMessages.indices.contains(index),
                  let block = snapshotMessages[index].blocks.first(where: { $0.id == blockID }) else { return false }
            switch block.kind {
            case .text, .thinking: return !block.content.isEmpty
            default: return true
            }
        }

        private func positionForMeasuredHeight(index: Int, delta: CGFloat) -> Bool {
            guard let cv = viewController?.collectionView, positionIsAvailable(in: cv) else { return false }
            enqueuePosition(.measurement, scheduleLayout: (cv as? NoAnimationCollectionView)?.isInPositionLayout != true)
            if delta > 0.5, viewController?.messageListLayout?.isStreamingCell(index) == true,
               let item = dataSource?.itemIdentifier(for: IndexPath(item: index, section: 0)),
               isPresentableBlock(item) {
                growingItems.insert(item)
                if let list = cv as? NoAnimationCollectionView, list.streamingGrowthStart != nil,
                   canUseLayoutStreamingTarget(in: list, reasons: positionReasons) {
                    layoutAdjustedStreamingGrowth = true
                    return false
                }
            }
            if viewportGeometryCommitDepth == 0 {
                if canUseKeyboardLayoutTarget(in: cv, reasons: positionReasons) { return false }
                if keepsSettledPlacement(reasons: positionReasons, grew: hasLaidOutGrowth(in: cv)) { return false }
            }
            return true
        }

        private func canUseLayoutStreamingTarget(in list: NoAnimationCollectionView, reasons: Set<PositionReason>) -> Bool {
            guard let layout = viewController?.messageListLayout else { return false }
            return didRestoreScroll && scrollMode == .autoScrolling && sendPosition == nil
                && !keyboardInFlight && !layout.isKeyboardTransitioning && viewportGeometryCommitDepth == 0
                && !layout.suppressContentOffsetAdjustment && !list.offsetLocked
                && reasons.isSubset(of: PositionReason.streamingGrowth)
                && abs(list.contentInset.bottom - baseBottomInset) <= 0.5
        }

        private func canUseKeyboardLayoutTarget(in cv: UICollectionView, reasons: Set<PositionReason>) -> Bool {
            didRestoreScroll && !keyboardInFlight && sendPosition == nil && positionIsAvailable(in: cv)
                && reasons.contains(.keyboardEnd) && reasons.isSubset(of: PositionReason.keyboardSettlement)
        }

        private func hasLaidOutGrowth(in cv: UICollectionView) -> Bool {
            growingItems.contains { (itemFrame($0, in: cv)?.height ?? 0) > 0.5 }
        }

        private func keepsSettledPlacement(reasons: Set<PositionReason>, grew: Bool) -> Bool {
            didRestoreScroll && settledPlacementGeneration == positionGeneration
                && sendPosition == nil && !grew && reasons.isSubset(of: PositionReason.passiveMeasurement)
        }

        private func finishPositionLayout() -> Bool {
            guard viewportGeometryCommitDepth == 0, !isFlushing, !resolvingPosition,
                  let cv = viewController?.collectionView, let window = cv.window else { return false }
            let finalOffset = cv.contentOffset
            let reasons = positionReasons
            let anchor = positionAnchor
            let keyboardFollowsBottom = scrollMode == .autoScrolling && keyboardAnchor?.wasNearBottom == true
            let keyboardEnd = reasons.contains(.keyboardEnd)
            let grew = hasLaidOutGrowth(in: cv)
            let layoutAdjustedGrowth = layoutAdjustedStreamingGrowth
            positionReasons.removeAll()
            positionAnchor = nil
            growingItems.removeAll()
            layoutAdjustedStreamingGrowth = false
            guard !reasons.isEmpty || !didRestoreScroll else { return false }

            resolvingPosition = true
            defer {
                if keyboardEnd { keyboardAnchor = nil }
                resolvingPosition = false
            }
            if canUseKeyboardLayoutTarget(in: cv, reasons: reasons) {
                let target = keyboardFollowsBottom ? scrollableBottom(in: cv) : finalOffset.y
                lastPositionSources = reasons.map(\.rawValue).sorted().joined(separator: "+")
                lastPositionTarget = target
                supersedeOrdinaryPositionRequests()
                settledPlacementGeneration = positionGeneration
                if target.isFinite, abs(target - finalOffset.y) > 0.5 {
                    UIView.performWithoutAnimation {
                        cv.setContentOffset(CGPoint(x: finalOffset.x, y: target), animated: false)
                    }
                    (cv as? NoAnimationCollectionView)?.materializePositionWithoutResolving = true
                }
                if reasons.contains(.contentSize) || reasons.contains(.contentGrowth) {
                    positionReasons.insert(.contentSize)
                    cv.setNeedsLayout()
                }
                syncScrollFlags()
                return false
            }

            let maintainsSettledPlacement = keepsSettledPlacement(reasons: reasons, grew: grew)
            if !maintainsSettledPlacement { settledPlacementGeneration = nil }
            if layoutAdjustedGrowth, let list = cv as? NoAnimationCollectionView, let preOffset = list.streamingGrowthStart,
               positionIsAvailable(in: list), canUseLayoutStreamingTarget(in: list, reasons: reasons) {
                lastPositionSources = reasons.map(\.rawValue).sorted().joined(separator: "+")
                lastPositionTarget = finalOffset.y
                list.animateStreamingGrowth(from: preOffset, to: finalOffset)
                syncScrollFlags()
                return false
            }
            let inheritsKeyboard = keyboardInFlight && didRestoreScroll && !reasons.contains(.foreground)
                && !reasons.contains(.keyboardEnd)
            let prepare = {
                self.prepareViewportInsets(caller: reasons.map(\.rawValue).sorted().joined(separator: "+"),
                                           forceRelax: reasons.contains(.snapshotShrink))
            }
            if inheritsKeyboard { prepare() } else { UIView.performWithoutAnimation(prepare) }
            let followsMeasuredGrowth = didRestoreScroll && scrollMode == .autoScrolling && sendPosition == nil
                && !keyboardInFlight && reasons.contains(.contentGrowth)
                && reasons.isSubset(of: PositionReason.streamingGrowth)
                && !previousSnapshotIds.isEmpty && positionIsAvailable(in: cv)
            if followsMeasuredGrowth {
                let target = scrollableBottom(in: cv)
                lastPositionSources = reasons.map(\.rawValue).sorted().joined(separator: "+")
                lastPositionTarget = target
                if target.isFinite, target - cv.contentOffset.y > 0.5 {
                    UIView.performWithoutAnimation {
                        cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false)
                    }
                    (cv as? NoAnimationCollectionView)?.materializePositionWithoutResolving = true
                }
            }
            if maintainsSettledPlacement || followsMeasuredGrowth {
                syncScrollFlags()
                return false
            }
            guard !previousSnapshotIds.isEmpty, positionIsAvailable(in: cv) else { return false }

            let origin = cv.convert(cv.bounds, to: window).minY
            let bottom = cv.bounds.height - baseBottomInset - cv.safeAreaInsets.bottom
            let followsBottom = scrollMode == .autoScrolling
            let geometryChanged = reasons.contains(.geometry) || reasons.contains(.resize) || keyboardEnd
            let usesKeyboardAnchor = inheritsKeyboard && keyboardAnchor != nil
                && reasons.isSubset(of: PositionReason.keyboardSettlement)
            var desired = cv.contentOffset.y
            var useVisualBottom = followsBottom
            var sendCanHandOff = false
            let initial = !didRestoreScroll
            let settlesRecovery = sendPosition == nil && reasons.isDisjoint(with: [.explicit, .disclosure, .sendEnded])
                && (initial || reasons.contains(.foreground))
            if initial && reasons.contains(.explicit) {
                didRestoreScroll = true
                useVisualBottom = true
            } else if initial {
                didRestoreScroll = true
                if let key = scrollMemoryKey, let saved = ChatScrollMemory.shared.anchor(for: key) {
                    let savedFrame = itemFrame(saved.item, in: cv)
                    let fallback = savedFrame == nil
                        ? (transcriptMode == .simple ? transcriptFallback(for: saved.item, in: previousSnapshotIds, messages: snapshotMessages)
                           : previousSnapshotIds.first(where: { $0.messageId == saved.item.messageId })) : nil
                    if let frame = savedFrame ?? itemFrame(fallback, in: cv) {
                        scrollMode = .userBrowsing
                        useVisualBottom = false
                        if savedFrame == nil && transcriptMode == .simple {
                            desired = frame.minY - cv.adjustedContentInset.top
                        } else {
                            desired = frame.minY - (saved.offset.isFinite ? saved.offset : 0)
                        }
                    } else {
                        ChatScrollMemory.shared.clear(key)
                        scrollMode = .autoScrolling
                        useVisualBottom = true
                    }
                } else {
                    scrollMode = .autoScrolling
                    useVisualBottom = true
                }
                if useVisualBottom, sendPosition == nil {
                    clampAfterSessionLoad = true
                    clampDeadline = Date().addingTimeInterval(8)
                    desired = scrollableBottom(in: cv)
                    useVisualBottom = false
                }
            } else if reasons.contains(.transcriptMode), !reasons.contains(.explicit) {
                useVisualBottom = false
                if followsBottom { desired = scrollableBottom(in: cv) }
                else if let anchor, let frame = itemFrame(anchor.readingItem, in: cv) {
                    let readingY = max(anchor.readingY, origin + cv.adjustedContentInset.top - max(0, frame.height - 1))
                    desired = origin + frame.minY - readingY
                }
            } else if reasons.contains(.foreground), let anchor {
                useVisualBottom = false
                if anchor.wasNearBottom {
                    desired = scrollableBottom(in: cv)
                } else if let frame = itemFrame(anchor.readingItem, in: cv) {
                    desired = origin + frame.minY - anchor.readingY
                }
            } else if usesKeyboardAnchor && keyboardFollowsBottom {
                desired = scrollableBottom(in: cv)
                useVisualBottom = false
            } else if !followsBottom || usesKeyboardAnchor {
                if let anchor, let frame = itemFrame(anchor.readingItem, in: cv) {
                    desired = origin + frame.minY - anchor.readingY
                }
                useVisualBottom = false
            } else if geometryChanged, let anchor, let tail = anchor.tailItem,
                      tail == previousSnapshotIds.last, abs(anchor.tailGap) <= 0.5,
                      let frame = itemFrame(tail, in: cv) {
                desired = frame.maxY - bottom + anchor.tailGap
                useVisualBottom = false
            }

            if scrollMode == .autoScrolling, let send = sendPosition {
                useVisualBottom = false
                switch send {
                case .inserting(_, let before):
                    if let before = before ?? anchor, let reading = itemFrame(before.readingItem, in: cv) {
                        desired = origin + reading.minY - before.readingY
                    }
                case .reveal(let user), .waiting(let user):
                    desired = scrollableBottom(in: cv)
                    sendPosition = .waiting(user)
                    let hasAssistantContent = previousSnapshotIds.firstIndex(of: user).map { index in
                        previousSnapshotIds.dropFirst(index + 1).contains { item in
                            if case .assistantFooter = item {
                                return item == previousSnapshotIds.last && (itemFrame(item, in: cv)?.height ?? 0) > 0.5
                            }
                            return isPresentableBlock(item) && (itemFrame(item, in: cv)?.height ?? 0) > 0.5
                        }
                    } ?? false
                    let queuedDuringReply = grew && (messageIndex[user.messageId].map { snapshotMessages[$0].isQueued } == true)
                    sendCanHandOff = !keyboardInFlight && (hasAssistantContent || queuedDuringReply)
                }
            }

            let target = boundedPosition(desired, followsBottom: useVisualBottom, in: cv)
            lastPositionSources = reasons.map(\.rawValue).sorted().joined(separator: "+")
            lastPositionTarget = target
            defer { syncScrollFlags() }
            if settlesRecovery {
                supersedeOrdinaryPositionRequests()
                settledPlacementGeneration = positionGeneration
            }
            guard target.isFinite else { return false }
            let needsMove = abs(target - cv.contentOffset.y) > 0.5
            if sendCanHandOff, !needsMove { sendPosition = nil }
            guard needsMove else { return false }
            let update = { cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: target), animated: false) }
            if inheritsKeyboard, !initial { update() } else { UIView.performWithoutAnimation(update) }
            if sendCanHandOff, abs(target - cv.contentOffset.y) <= 0.5 { sendPosition = nil }
            if settlesRecovery, let list = cv as? NoAnimationCollectionView {
                list.materializePositionWithoutResolving = true
                return false
            }
            return true
        }

        private func boundedPosition(_ desired: CGFloat, followsBottom: Bool, in cv: UICollectionView) -> CGFloat {
            ChatListScrollTarget.resolve(contentHeight: cv.contentSize.height, viewportHeight: cv.bounds.height,
                adjustedTop: cv.adjustedContentInset.top, adjustedBottom: cv.adjustedContentInset.bottom,
                baseBottom: baseBottomInset, safeAreaBottom: cv.safeAreaInsets.bottom,
                current: desired, followsBottom: followsBottom)
        }

        private func scrollableBottom(in cv: UICollectionView) -> CGFloat {
            max(-cv.adjustedContentInset.top, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
        }

        // === [T-foldable-scroll] Reader's place, across a pane-layout change ===
        /// Conversation this list belongs to; keys the saved scroll anchor.
        private var scrollMemoryKey: String?
        /// One restore per list instance — a second pass would fight the user.
        private var didRestoreScroll = false
        /// Throttle for the per-frame anchor write in `scrollViewDidScroll`.
        private var lastAnchorItem: MessageListItem?
        private var lastAnchorOffset: CGFloat = .nan        /// True while an animated setContentOffset is in flight. KVO grow events must not
        /// directly mutate contentOffset during this window — UIKit animation interpolation
        /// can produce a corrupted final offset. Instead, defer via scheduleCoalescedScroll().
        private var isAnimatingScrollToBottom = false

        /// Viewport coordinate captured immediately before a user-message
        /// disclosure mutates. The generation prevents delayed self-sizing
        /// passes from an older tap from overriding a newer tap.
        private struct UserMessageViewportAnchor {
            let messageId: UUID
            let screenMinY: CGFloat
            let generation: UUID
            let wasExpanded: Bool?
            let initialOffsetY: CGFloat
            let initialContentHeight: CGFloat
        }
        private var userMessageViewportAnchor: UserMessageViewportAnchor?

        // === O(1) Lookup Indices ===
        private var messageIndex: [UUID: Int] = [:]
        private var itemToIndex: [MessageListItem: Int] = [:]

        // === Snapshot State ===
        private var previousSnapshotIds: [MessageListItem] = []
        private var snapshotMessages: [ChatMessage] = []

        // === Bridges ===
        private var cellBridges: [UUID: CellStateBridgeV2] = [:]

        // === Height Measurement Cache ===
        /// Caches measureAttributedStringHeight results by NSAttributedString identity.
        /// Avoids redundant TextKit layout on repeated snapshots for the same content.
        private var attrStringHeightCache: [ObjectIdentifier: CGFloat] = [:]
        /// [T-ios-user-msg-estimate-tail-jitter] Caches accurate user-bubble
        /// heights keyed by "content|width|fontsize" (user text has no
        /// cachedAttributedString identity to key on). Cleared alongside
        /// attrStringHeightCache on session change / font change.
        private var userBubbleHeightCache: [String: CGFloat] = [:]

        // === Thinking Block Toggle ===
        private var thinkingToggleSub: AnyCancellable?

        // === Async attachment size invalidate ===
        // [T-attachment-size-invalidate 2026-05-21] Image / video / thumbnail
        // async loads cause cell SwiftUI body to grow from placeholder to fit
        // size, but SelfSizingCell's broad-width cache short-circuits
        // preferredLayoutAttributesFitting so the cell never re-measures —
        // bottom of content gets clipped until the chat is re-entered.
        private var attachmentSizeChangedSub: AnyCancellable?

        // A foreground refresh may have to wait for an in-flight session load.
        private var needsForegroundRefresh = false

        // === Streaming ===
        private var lastMessageId: UUID?
        private var lastMessageSub: AnyCancellable?
        private var lastMessageBlockCountSub: AnyCancellable?

        /// [T-ios-ui-blocks-lost-suspend-resume] Last observed value of the vm's
        /// `streamingUIUpdatesSuspended`, tracked so the vm-state subscription can
        /// detect a true→false transition and flush a snapshot deferred during the
        /// suspend window (see `suspendResumeSub`).
        private var lastSuspendedValue: Bool = false
        /// [T-ios-ui-blocks-lost-suspend-resume] Watches the vm for the moment
        /// `streamingUIUpdatesSuspended` clears, then flushes the pending snapshot.
        private var suspendResumeSub: AnyCancellable?
        /// [T-ios-footer-stale-height] Last observed vm.isProcessing, used by
        /// the state-bridge subscription to edge-detect the task-end
        /// (true→false) transition whose footer content change must re-measure.
        private var lastProcessingValue: Bool = false

        /// Adaptive streaming throttle: last time flushStreamingLayout actually ran.
        private var lastStreamingLayoutTime: Date = .distantPast
        /// Trailing-edge work item so the final streaming update isn't lost.
        private var pendingStreamingLayout: DispatchWorkItem?


        /// Scroll coalescing: batches rapid scroll signals into one 80ms action.
        private var pendingScrollWork: DispatchWorkItem?

        // === Session Load ===
        /// When true, contentSize KVO keeps pinning to bottom until layout stabilizes.
        private var clampAfterSessionLoad: Bool = false
        /// Hard deadline to stop clamping (8s after session load).
        private var clampDeadline: Date = .distantPast

        /// Every consumer checks expiry, including geometry-only commits that
        /// never receive contentSize KVO. A load pin cannot override browsing.
        private func consumeSessionLoadClamp() -> Bool {
            if clampAfterSessionLoad,
               scrollMode != .autoScrolling || Date() >= clampDeadline {
                clampAfterSessionLoad = false
            }
            return clampAfterSessionLoad
        }

        // === Sheet Presenters ===
        private let sheetPresenter = ToolSheetPresenter()
        private let compactSummaryPresenter = CompactSummaryPresenter()
        private let quotePreviewPresenter = QuotePreviewPresenter()
        private var sheetOverlayHost: UIHostingController<SheetOverlayView>?

        // === References ===
        private weak var viewController: MessageListViewController?
        private weak var vm: AIChatViewModel?
        private var dataSource: UICollectionViewDiffableDataSource<Section, MessageListItem>!
        private var subscriptions = Set<AnyCancellable>()
        private var contentSizeObservation: NSKeyValueObservation?

        // MARK: - Setup

        // MARK: [T-foldable-scroll] Anchor memory

        /// Point the list at a conversation. A different key means a different
        /// anchor, and this instance starts at the bottom again.
        func updateScrollMemoryKey(_ key: String?) {
            guard key != scrollMemoryKey else { return }
            clearCompletionGlows()
            let promotingDraft = didRestoreScroll && vm?.sessionId == key && scrollMemoryKey == vm?.draftId && sendPosition != nil
            let activeSend = sendPosition
            invalidatePositionRequests()
            scrollMemoryKey = key
            didRestoreScroll = promotingDraft
            if promotingDraft { sendPosition = activeSend }
            lastAnchorItem = nil
            lastAnchorOffset = .nan
        }

        /// Remember the top row while the reader browses. At the bottom the
        /// default behaviour is already correct, so the anchor is dropped.
        private func rememberScrollAnchor() {
            rememberScrollAnchor(preservingBrowseIntent: transcriptMode == .simple)
        }

        private func rememberScrollAnchor(preservingBrowseIntent: Bool) {
            guard let key = scrollMemoryKey, didRestoreScroll, !isFlushing, !resolvingPosition else { return }
            guard let cv = viewController?.collectionView else { return }
            if isNearBottom(), !(preservingBrowseIntent && scrollMode == .userBrowsing) {
                ChatScrollMemory.shared.clear(key)
                lastAnchorItem = nil
                lastAnchorOffset = .nan
                return
            }
            guard let indexPath = cv.indexPathsForVisibleItems.min(),
                  let item = dataSource?.itemIdentifier(for: indexPath),
                  let frame = cv.layoutAttributesForItem(at: indexPath)?.frame else { return }
            let offset = frame.minY - cv.contentOffset.y
            if lastAnchorItem == item, abs(offset - lastAnchorOffset) < 8 { return }
            lastAnchorItem = item
            lastAnchorOffset = offset
            ChatScrollMemory.shared.save(.init(item: item, offset: offset), for: key)
        }

        func attach(to vc: MessageListViewController, vm: AIChatViewModel) {
            self.viewController = vc
            self.vm = vm
            vc.loadViewIfNeeded()
            guard let collectionView = vc.collectionView else { return }
            collectionView.delegate = self
            vc.onListDisappearance = { [weak self] in self?.clearCompletionGlows() }
            ReplyCompletionGlowEvents.shared.events
                .sink { [weak self] event in self?.showCompletionGlow(event) }
                .store(in: &completionGlowSubscriptions)
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
                .sink { [weak self] _ in self?.clearCompletionGlows() }
                .store(in: &completionGlowSubscriptions)
            collectionView.prefetchDataSource = self
            (collectionView as? NoAnimationCollectionView)?.viewportWillResize = { [weak self] in
                self?.enqueuePosition(.resize)
            }
            (collectionView as? NoAnimationCollectionView)?.beginPositionLayout = { [weak self] in
                guard let self else { return false }
                self.scheduleTranscriptUpdate()
                self.scheduleFooterReconciliation()
                return self.beginPositionLayout()
            }
            (collectionView as? NoAnimationCollectionView)?.finishPositionLayout = { [weak self] in
                self?.finishPositionLayout() ?? false
            }
            vc.messageListLayout?.positionForMeasuredHeight = { [weak self] index, delta in
                self?.positionForMeasuredHeight(index: index, delta: delta) ?? false
            }
            // Disable UIKit's main-thread cell prefetch. Profile (Time Profiler)
            // showed -[UICollectionView _prefetchItemsForPrefetchingContext:]
            // chains through _createPreparedCellForItemAtIndexPath → +UIView
            // performWithoutAnimation → _checkForPreferredAttributesInView →
            // SelfSizingCell.preferredLayoutAttributesFitting →
            // UIHostingContentView.systemLayoutSizeFitting, eating ~44ms (30%)
            // of one main-thread sample for a single off-screen BIG-CELL.
            // That's the 2-3 frame hitch users perceive as a sudden stutter
            // right before scrolling exposes a large text/table cell.
            // Disabling prefetch lets cells be sized only when they actually
            // come on-screen. Heights are still pre-estimated via setEstimatedHeight
            // in applySnapshot / configureCell, so layout positions don't shift.
            collectionView.isPrefetchingEnabled = false

            let wholeReg = UICollectionView.CellRegistration<WholeMessageCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let headerReg = UICollectionView.CellRegistration<AssistantHeaderCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let blockReg = UICollectionView.CellRegistration<AssistantBlockCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }
            let footerReg = UICollectionView.CellRegistration<AssistantFooterCellV3, MessageListItem> {
                [weak self] cell, indexPath, item in
                self?.configureCell(cell, item: item, indexPath: indexPath)
            }

            dataSource = UICollectionViewDiffableDataSource<Section, MessageListItem>(
                collectionView: collectionView
            ) { cv, indexPath, item in
                switch item {
                case .wholeMessage:
                    return cv.dequeueConfiguredReusableCell(using: wholeReg, for: indexPath, item: item)
                case .assistantHeader:
                    return cv.dequeueConfiguredReusableCell(using: headerReg, for: indexPath, item: item)
                case .assistantBlock, .assistantToolGroup:
                    return cv.dequeueConfiguredReusableCell(using: blockReg, for: indexPath, item: item)
                case .assistantFooter:
                    return cv.dequeueConfiguredReusableCell(using: footerReg, for: indexPath, item: item)
                }
            }

            // Install sheet overlay (outside UIHostingConfiguration cell tree)
            if sheetOverlayHost == nil {
                let overlay = SheetOverlayView(toolPresenter: sheetPresenter,
                                               compactPresenter: compactSummaryPresenter,
                                               quotePresenter: quotePreviewPresenter)
                let host = UIHostingController(rootView: overlay)
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = true
                host.view.frame = .zero
                vc.addChild(host)
                vc.view.addSubview(host.view)
                host.didMove(toParent: vc)
                sheetOverlayHost = host

                sheetPresenter.onDismiss = { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "sheetDismiss")
                }
            }

            // ContentSize KVO — pin to bottom during autoScrolling
            contentSizeObservation = collectionView.observe(\.contentSize, options: [.new, .old]) {
                [weak self] cv, change in
                guard let self else { return }
                guard !self.isFlushing || self.viewportGeometryCommitDepth > 0 else { return }
                let newH = change.newValue?.height ?? 0
                let oldH = change.oldValue?.height ?? 0
                guard newH != oldH else { return }
                let delta = newH - oldH

                if self.isAnimatingScrollToBottom {
                    self.scheduleCoalescedScroll()
                }
                self.vm?.contentSizeDeltaSignal.send(delta)
                self.enqueuePosition(delta > 0 ? .contentGrowth : .contentSize,
                                     scheduleLayout: (cv as? NoAnimationCollectionView)?.isInPositionLayout != true)
            }

            bindViewModel(vm)
        }

        // MARK: - Cell Configuration

        private func currentIndex(for item: MessageListItem) -> Int? {
            return itemToIndex[item]
        }

        private static let cellLogger = AppLogger(category: "CellPerf")
        private let screenshotLogger = AppLogger(category: "TurnScreenshot")
        /// [T-ios-copy-screenshot-diag-logs] Verbose stage-by-stage trace of
        /// captureScrollingTurnScreenshot used to chase the "top blank when
        /// long-press from middle/bottom" symptom that the first repair
        /// (5e3c6160) didn't fully eliminate. Separate category from
        /// TurnScreenshot so users can `grep ChatScreenshot` cleanly to
        /// pull just the diagnostic frames without the noisier turn-level
        /// summary lines.
        private let chatScreenshotLogger = AppLogger(category: "ChatScreenshot")
        /// Counts cells configured since last applySnapshot to detect first-cell timing.
        private var cellConfigCount: Int = 0
        private var firstCellConfigTime: CFAbsoluteTime = 0

        private func configureCell(_ cell: SelfSizingCell, item: MessageListItem, indexPath: IndexPath) {
            guard let vm else { return }
            cell.transcriptGeneration = transcriptGeneration
            let configStart = CACurrentMediaTime()
            cellConfigCount += 1
            if cellConfigCount == 1 {
                firstCellConfigTime = CFAbsoluteTimeGetCurrent()
            }
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth

            // [T-viewgraph-race-lifetime 2026-05-20] All 4 cell config sites
            // route through `cell.applyContentConfiguration(_:)` (not raw
            // `cell.contentConfiguration =`) so the SelfSizingCell bumps its
            // configGeneration and clears the height cache when the hosting
            // configuration is swapped. Without it, the preferredLayoutAttributesFitting
            // generation guard never trips (gen never changes) and the
            // broad cache may return a stale height for the swapped content.
            // Both reduce the window for the ViewGraphGeometryObservers race.
            let searchHighlights = forceUncollapsedToolsForScreenshot ? nil : vm.chatSearch.highlights
            switch item {
            case .wholeMessage(let msgId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message, in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedWholeMessageV3(
                        message: message,
                        bridge: bridge,
                        onDismissSystemInfo: message.browserControlInfo == true
                            ? { [weak self] in self?.onDismissSystemInfo?(message.id) }
                            : nil,
                        maxWidth: width
                    )
                    // Suppress SwiftUI async display-link geometry observation
                    // to prevent use-after-free in ViewGraphGeometryObservers
                    // when UICollectionView recycles the cell.
                    .environment(\.chatTranscriptDisplayMode, transcriptMode)
                    .transaction { $0.disablesAnimations = true }
                    // UIHostingConfiguration creates an independent SwiftUI
                    // environment — it does NOT inherit EnvironmentObjects
                    // from the outer AIChatView. Descendant views inside the
                    // cell (notably ToolCapsuleView, which reads
                    // `@EnvironmentObject vm: AIChatViewModel` for its long-
                    // press menu's `vm.isProcessing` check) would trigger
                    // SwiftUI's "No ObservableObject of type AIChatViewModel
                    // found" fatal (EXC_BREAKPOINT) the moment the body
                    // evaluates — symptom: app crashes when waking from
                    // lock + tapping a session-complete notification, since
                    // the deep-link forces an immediate cell rebuild before
                    // any other view layer can re-inject the vm. Re-inject
                    // explicitly on every hosting config.
                    // [T-ios-tool-capsule-vm-envobject-crash]
                    .environmentObject(vm)
                    .environment(\.chatSearchHighlights, searchHighlights)
                    .environment(\.chatSearchMessageId, message.id)
                    .environment(\.chatSearchDimmed, message.isCompactedHistory)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantHeader(let msgId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message, in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantHeaderV3(message: message,
                                             bridge: bridge,
                                             maxWidth: width,
                                             onToggleSteps: { [weak self] in
                        self?.toggleStepsCollapsed(messageId: msgId)
                    },
                                             stepsToggleEnabled: collapseConsecutiveToolCalls
                                                && message.taskDuration != nil)
                        .transaction { $0.disablesAnimations = true }
                        .environmentObject(vm)
                    .environment(\.chatSearchHighlights, searchHighlights)
                    .environment(\.chatSearchMessageId, message.id)
                    .environment(\.chatSearchDimmed, message.isCompactedHistory)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantBlock(let msgId, let blockId, let segmentID):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else {
                    AppLogger(category: "SnapshotDiag").warning("[SnapshotDiag] configureCell MISS msgId=\(msgId.uuidString.prefix(8)) — messageIndex miss or OOB")
                    return
                }
                let message = messages[msgIdx]
                guard let block = message.blocks.first(where: { $0.id == blockId }) else {
                    AppLogger(category: "SnapshotDiag").warning("[SnapshotDiag] configureCell MISS blockId=\(blockId.uuidString.prefix(8)) in msg blocks=\(message.blocks.count) — block ID mismatch (vm.messages mutated since snapshot?)")
                    return
                }
                let bridge = getOrCreateBridge(for: message, in: messages)
                if block.kind.isSubAgentTool { observeInlineSubAgentRows(in: message) }
                cell.backgroundColor = .clear
                let simpleRow = simpleRows[item]
                let blockCell = cell as? AssistantBlockCellV3
                let glowItem = simpleRow == .text ? item : nil
                if blockCell?.glowItem != glowItem {
                    blockCell?.completionGlow.reset()
                    blockCell?.glowItem = glowItem
                }
                let glow = glowItem == nil ? nil : blockCell?.completionGlow
                let columnWidth = segmentID == nil ? width : max(1, min(width > 0 ? width : .greatestFiniteMagnitude,
                                                                        (viewController?.collectionView.bounds.width ?? 390) - 32))
                let config = UIHostingConfiguration {
                    BridgedAssistantBlockV3(
                        block: block,
                        message: message,
                        bridge: bridge,
                        maxWidth: columnWidth,
                        simpleRow: simpleRow,
                        segmentID: segmentID,
                        glow: glow,
                        onSegmentResize: { [weak self, weak block] id in
                            guard let block else { return }
                            self?.invalidateSimpleSegment(.assistantBlock(msgId, blockId, id), ownedBy: block)
                        }
                    )
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                    .environment(\.chatSearchHighlights, searchHighlights)
                    .environment(\.chatSearchMessageId, message.id)
                    .environment(\.chatSearchDimmed, message.isCompactedHistory)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantToolGroup(let msgId, let firstBlockId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                guard let first = message.blocks.first(where: { $0.id == firstBlockId }) else { return }
                let bridge = getOrCreateBridge(for: message, in: messages)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantToolGroupV3(message: message, firstBlock: first, bridge: bridge, maxWidth: width) { [weak self] in
                        self?.toggleToolGroup(messageId: msgId, firstBlockId: firstBlockId)
                    }
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                    .environment(\.chatSearchHighlights, searchHighlights)
                    .environment(\.chatSearchMessageId, message.id)
                    .environment(\.chatSearchDimmed, message.isCompactedHistory)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)

            case .assistantFooter(let msgId):
                guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { return }
                let message = messages[msgIdx]
                let bridge = getOrCreateBridge(for: message, in: messages)
                syncFooterBridge(bridge, message: message, vm: vm, lastMessageID: messages.last?.id)
                cell.backgroundColor = .clear
                let config = UIHostingConfiguration {
                    BridgedAssistantFooterV3(
                        message: message,
                        bridge: bridge,
                        maxWidth: width,
                        transcriptDisplayMode: transcriptMode
                    )
                    .transaction { $0.disablesAnimations = true }
                    .environmentObject(vm)
                    .environment(\.chatSearchHighlights, searchHighlights)
                    .environment(\.chatSearchMessageId, message.id)
                    .environment(\.chatSearchDimmed, message.isCompactedHistory)
                }.minSize(width: 0, height: 0).margins(.all, 0)
                cell.applyContentConfiguration(config)
            }

            // [T-ios-scroll-decel-height-drift] Seed this cell with the real
            // height the SAME content measured on a prior appearance (if any),
            // so its first self-size after reuse skips the 2.5–3.8ms
            // systemLayoutSizeFitting that produced the decel "settle jitter".
            // Must run AFTER applyContentConfiguration (which clears the seed).
            // Width-matched inside the memo so a stale portrait height isn't
            // reused after rotation. No measurement is performed here.
            if let layout = viewController?.messageListLayout {
                let cvW = viewController?.collectionView.bounds.width ?? 390
                let key = transcriptContentKey(for: item, messages: messages, width: cvW)

                // [T-ios-scroll-decel-height-drift] Register the index→key map
                // on EVERY cell config, not just snapshot apply. The memo write
                // in invalidationContext keys off contentKeyByIndex[index]; if
                // it's only set during updateMessages (snapshot change), then
                // pure scrolling — where snapshot is unchanged and the jitter
                // actually happens — leaves the map stale/empty, so the measured
                // height is never memoized (observed: memoForKey=none on every
                // re-entry). Setting it here, where index↔item is authoritative
                // for the cell about to be measured, makes the memo actually
                // capture the self-size that follows.
                layout.setContentKey(key, at: indexPath.item)

                #if DEBUG
                // [T-ios-scroll-metrics-ring] Stamp the stable cell tag on the
                // cell and the layout's index map (only while recording — the
                // hash costs a string scan per configure).
                if ScrollMetricsRecorder.shared.isEnabled {
                    let tag = Self.stableCellTag(for: item, messages: messages, messageIndex: messageIndex)
                    cell.metricsTag = tag
                    layout.setMetricsTag(tag, at: indexPath.item)
                }
                #endif

                // [T-ios-scroll-decel-height-drift] STREAMING EXCLUSION. A cell
                // belonging to the actively-streaming (last assistant) message
                // changes height every token (tool capsule + code block grow as
                // output arrives). It must NEVER be seeded or memoized: a seed
                // would short-circuit self-size and freeze the cell at a stale
                // mid-stream height, leaving the tool cell / code block overlapping
                // adjacent content until the NEXT turn reconfigures it (observed
                // regression). The content-length key already differs per token,
                // but seeding ANY prior length is wrong while it's still growing —
                // so gate it out entirely. Non-streaming history cells keep the
                // seed benefit. Clearing contentKey also disables the memo write
                // on this cell's self-size path.
                let itemMsgId = Self.messageId(of: item)
                let isStreamingCell = vm.isProcessing && itemMsgId != nil
                    && itemMsgId == messages.last?.id && messages.last?.role == .assistant
                if isStreamingCell {
                    cell.contentKey = nil
                    layout.invalidateMemo(forKey: key)
                }

                let memo = isStreamingCell ? nil : layout.measuredHeight(forKey: key, width: cvW)
                if !isStreamingCell {
                    cell.contentKey = key
                }
                if let memo {
                    cell.seedMeasuredHeight(memo, width: cvW)
                }
                // [T-ios-user-msg-truncate-seed-starve] DO NOT seed from precalc.
                //
                // The seed short-circuit in SelfSizingCell.preferredLayoutAttributes-
                // Fitting RETURNS the seeded height and SKIPS the real
                // systemLayoutSizeFitting — so the seed value becomes the cell's
                // hard height. That is only safe for a height we ACTUALLY MEASURED
                // before (the `memo` above, from a prior real self-size at this
                // width). `precalcHeight` is an ESTIMATE (boundingRect /
                // char-count) that runs ~4-7pt SHORT of the real height for user
                // bubbles (TextKit line height is tighter than SwiftUI Text's
                // rendered line box). Seeding it locked
                // the cell at the short value, so the SwiftUI Text inside was
                // clipped to "…" while processing, and only expanded once a later
                // reconfigure forced a real measure — exactly the user-reported
                // truncate-then-expand. precalc still serves as prepare()'s
                // layout height (set via setPrecalcHeight in applySnapshot) so the
                // cell's initial POSITION is approximately right, but the cell's
                // real height is always decided by an actual measure, never frozen
                // at an estimate. (The first-mount-measure-storm 方案 D was trading
                // correctness for fewer measures here; correctness wins — a too-
                // short estimate that truncates content is worse than a measure.)
            }

            // Height estimation for items not yet measured — skip if we already
            // have a measured height OR a precalculated height from applySnapshot.
            if let layout = viewController?.messageListLayout,
               layout.cachedHeight(at: indexPath.item) == nil,
               !layout.hasPrecalcHeight(at: indexPath.item) {
                let est = Self.estimateItemHeight(item, messages: messages,
                                                  width: viewController?.collectionView.bounds.width ?? 390,
                                                  maxContentWidth: maxContentWidth, simpleRow: simpleRows[item])
                layout.setEstimatedHeight(est, at: indexPath.item)
            }
        }

        /// Subscriptions for bridge detailBlock → sheet presenter forwarding.
        private var bridgeSheetSubs: [UUID: AnyCancellable] = [:]
        private var footerUsageSubs: [UUID: AnyCancellable] = [:]
        private var inlineSubAgentSubs: [UUID: (message: ObjectIdentifier, subscription: AnyCancellable)] = [:]

        private func observeInlineSubAgentRows(in message: ChatMessage) {
            let identity = ObjectIdentifier(message)
            guard inlineSubAgentSubs[message.id]?.message != identity else { return }
            let subscription = message.inlineSubAgentCards.changedRows.sink { [weak self, weak message] blockIDs in
                guard let self, let message,
                      let index = self.messageIndex[message.id], self.snapshotMessages.indices.contains(index),
                      self.snapshotMessages[index] === message,
                      let cv = self.viewController?.collectionView, let layout = self.viewController?.messageListLayout,
                      let source = self.dataSource else { return }
                let paths = blockIDs.compactMap { source.indexPath(for: .assistantBlock(message.id, $0)) }
                for path in paths {
                    layout.invalidateContentHeight(at: path.item)
                    (cv.cellForItem(at: path) as? SelfSizingCell)?.clearCachedHeight()
                }
                if !paths.isEmpty {
                    layout.invalidateLayout()
                    cv.setNeedsLayout()
                }
            }
            inlineSubAgentSubs[message.id] = (identity, subscription)
        }

        private func getOrCreateBridge(for message: ChatMessage, in messages: [ChatMessage]) -> CellStateBridgeV2 {
            if let existing = cellBridges[message.id] {
                observeFooterUsage(for: message.id, bridge: existing)
                refreshCompletionActions(existing, message: message)
                return existing
            }
            let bridge = CellStateBridgeV2()
            cellBridges[message.id] = bridge
            updateBridge(bridge, message: message, in: messages)
            // Forward detailBlock changes to the VC-level sheet presenter
            bridgeSheetSubs[message.id] = bridge.$detailBlock
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] block in
                    guard let self else { return }
                    if let block {
                        let toolBlocks = message.blocks.filter { $0.toolStatus != nil }
                        self.sheetPresenter.sheetData = ToolSheetPresenter.SheetData(
                            id: block.id,
                            block: block,
                            toolBlocks: toolBlocks,
                            toolSnapshots: bridge.toolSnapshots,
                            browserPool: bridge.browserPool,
                            sessionId: self.vm?.sessionId,
                            onBrowserTakeover: { [weak self] in self?.vm?.browserTakeoverActive = true },
                            onTakeoverDone: { [weak self] in self?.vm?.resumeFromBrowserTakeover() }
                        )
                    }
                    // Dismiss is handled by sheetPresenter.onDismiss (set in attach)
                }
            observeFooterUsage(for: message.id, bridge: bridge)
            return bridge
        }

        private func observeFooterUsage(for messageID: UUID, bridge: CellStateBridgeV2) {
            guard footerUsageSubs[messageID] == nil, let vm else { return }
            footerUsageSubs[messageID] = bridge.$showUsage
                .removeDuplicates()
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak vm, weak bridge] _ in
                    guard let self, let vm, self.vm === vm,
                          let bridge, self.cellBridges[messageID] === bridge else { return }
                    self.markFooterDirty(messageID)
                }
        }

        // MARK: - Bridge Updates

        private func updateBridge(_ bridge: CellStateBridgeV2, message: ChatMessage, in messages: [ChatMessage]) {
            updateBridge(bridge, message: message, lastMessageID: messages.last?.id)
        }

        private func updateBridge(_ bridge: CellStateBridgeV2, message: ChatMessage, lastMessageID: UUID?) {
            guard let vm else { return }
            let isLast = message.id == lastMessageID
            let isActive = isLast && vm.isProcessing

            bridge.isActiveMessage = isActive
            bridge.thinkingLevel = vm.currentThinkingLevel
            bridge.commandStartTime = vm.commandStartTime
            bridge.onStop = isActive ? { [weak self] in self?.onStop?() } : nil
            bridge.browserPool = vm.browserTabPool
            bridge.toolSnapshots = vm.toolSnapshots
            bridge.autoRetryAttempt = isLast ? vm.autoRetryAttempt : 0
            bridge.autoRetryCountdown = isLast ? vm.autoRetryCountdown : 0
            refreshCompletionActions(bridge, message: message)
            // [T-ios-session-status-mismatch] Defense-in-depth: even if vm.canResume
            // is somehow stale-true and vm.isProcessing hasn't flipped yet, do NOT
            // show the "Interrupted — tap Resume" banner while SessionActivityTracker
            // still lists this session as active (same signal the home list spinner
            // reads). This closes the residual gap where a new/reloaded VM sees a
            // toolResult-tail during a live loop's tool_result → next-model-call gap.
            bridge.canResume = canResumeFooter(vm: vm, isLast: isLast)
            bridge.onResume = isLast ? { [weak self] in self?.onResume?() } : nil
            bridge.onWithdraw = message.isQueued ? { [weak self] in self?.onWithdraw?(message.id) } : nil
            bridge.onToggleUserMessageExpansion = message.role == .user && !message.isQueued
                ? { [weak self] in self?.toggleUserMessageExpansion(messageId: message.id) }
                : nil
            bridge.onDelete = (message.role == .user && !message.isQueued && !vm.isProcessing)
                ? { [weak self, weak message] in
                    guard let id = message?.id else { return }
                    self?.onDelete?(id)
                }
                : nil
            // "Read from Start": replay this whole reply via TTS. Only for assistant
            // messages; disabled while it's the actively-streaming reply.
            bridge.isStreaming = isActive
            bridge.onReadAloud = (message.role == .assistant)
                ? { [weak vm] in vm?.readReplyFromStart(message) }
                : nil
            // [T-selection-menu-ze-tts] "Read Selection" from the text
            // selection menu — speaks the selected snippet via the Ze TTS
            // stack (sanitizer + provider voices + fail-over).
            bridge.onSpeakText = { [weak vm] text in vm?.speakText(text) }
            bridge.onCopyScreenshot = { [weak self, weak vm] in
                guard let self, let vm else { return }
                if let onShareMessage = self.onShareMessage { onShareMessage(message.id); return }
                let msgs = vm.messages
                guard let anchorIdx = msgs.firstIndex(where: { $0.id == message.id }) else { return }
                let anchor = msgs[anchorIdx]
                let userId: UUID?
                let assistantId: UUID?
                switch anchor.role {
                case .user:
                    userId = anchor.id
                    assistantId = msgs[(anchorIdx + 1)...]
                        .first(where: { $0.role == .assistant && !$0.isInternalBridge })?.id
                case .assistant:
                    userId = msgs[..<anchorIdx].reversed().first(where: { $0.role == .user })?.id
                    assistantId = anchor.id
                default:
                    return
                }
                guard let userId else { return }
                let turn = msgs.filter { $0.id == userId || $0.id == assistantId }
                let request = ChatShareSnapshot.request(messages: turn, title: "", vm: vm, messageId: userId)
                let dark = self.viewController?.traitCollection.userInterfaceStyle == .dark
                Task { @MainActor [weak self, weak vm] in
                    guard let self, let vm, self.vm === vm else { return }
                    do {
                        let image = try await ChatShareSnapshot.renderTurnImage(request, dark: dark)
                        if self.vm === vm { self.onScreenshotImage?(image) }
                    } catch {
                        self.chatScreenshotLogger.error("Frozen screenshot failed: \(error.localizedDescription)")
                    }
                }
            }

            let retryMsg = onRetryMessage
            let retryLast = onRetryLast
            let replyMsg = onReplyMessage
            let edit = onEdit
            let compact = onCompact
            let forceSync = onForceSync
            bridge.onForceSync = forceSync

            bridge.onShowCompactSummary = { [weak self] summary in
                guard let self else { return }
                // Update the presenter's revert callback every time the sheet
                // opens so it always points at the current vm. Captured weakly
                // so a closed-over coordinator that's been discarded can't
                // pin the view-model's lifetime.
                self.compactSummaryPresenter.onRevert = { [weak self] in
                    self?.onRevertCompact?()
                }
                self.compactSummaryPresenter.summary = summary
            }

            // [T-chat-quote-reply] Resolve the original message at tap time,
            // against the current session, then fall back to the stored
            // snapshot when it has been deleted/compacted away.
            bridge.onShowQuotePreview = { [weak self] quote in
                guard let self else { return }
                self.quotePreviewPresenter.preview = QuotePreviewPresenter.Preview(
                    text: Self.quotePreviewText(for: quote, in: self.vm?.messages ?? []))
            }

            if message.isCompactedHistory || message.role == .compactDivider || message.role == .systemInfo {
                bridge.onRetry = nil; bridge.onReply = nil; bridge.onEdit = nil; bridge.onCompact = nil
            } else if !vm.isProcessing && !vm.isCompacting {
                if message.role == .user {
                    bridge.onRetry = { retryMsg?(message.id) }
                } else if isLast {
                    bridge.onRetry = { retryLast?() }
                } else {
                    bridge.onRetry = nil
                }
                bridge.onReply = { replyMsg?(message.id) }
                bridge.onEdit = message.role == .user ? { edit?(message.id) } : nil
                bridge.onCompact = { compact?(message.id) }
            } else {
                bridge.onRetry = nil; bridge.onReply = nil; bridge.onEdit = nil; bridge.onCompact = nil
            }
        }

        /// [T-chat-quote-reply] Full text of the quoted original when it is
        /// still in this session; otherwise the quote's own snapshot.
        private static func quotePreviewText(for quote: MessageQuote, in messages: [ChatMessage]) -> String {
            if let original = messages.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(quote.targetMessageId) == .orderedSame
            }) {
                let text: String
                switch original.role {
                case .user:
                    text = ChatSearchDisplayText.userBubble(original.content)
                case .assistant:
                    let blocks = original.blocks
                        .filter { if case .text = $0.kind { return true }; return false }
                        .map(\.content)
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: "\n\n")
                    text = blocks.isEmpty ? original.content : blocks
                case .compactDivider, .systemInfo:
                    text = original.content
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return quote.text
        }

        private func refreshCompletionActions(_ bridge: CellStateBridgeV2, message: ChatMessage,
                                              processing: Bool? = nil) {
            let visible = reservesCompletionActionSpace(message) && !(processing ?? (vm?.isProcessing == true))
            if bridge.showsCompletionActions != visible { bridge.showsCompletionActions = visible }
        }

        private func updateLastCellBridge() {
            guard let vm else { return }
            let messages = vm.messages
            guard let lastMsg = messages.last(where: { !$0.isInternalBridge }) else { return }
            if let bridge = cellBridges[lastMsg.id] {
                updateBridge(bridge, message: lastMsg, lastMessageID: lastMsg.id)
            }
            if messages.count >= 2 {
                let prev = messages[messages.count - 2]
                if prev.id != lastMsg.id, let prevBridge = cellBridges[prev.id], prevBridge.canResume {
                    prevBridge.canResume = false
                    prevBridge.onResume = nil
                }
            }
            for msg in messages where msg.id != lastMsg.id {
                if msg.role == .assistant, let b = cellBridges[msg.id], b.isActiveMessage {
                    b.isActiveMessage = false
                }
            }
            for msg in messages where msg.role == .user {
                if let b = cellBridges[msg.id] {
                    updateBridge(b, message: msg, lastMessageID: lastMsg.id)
                }
            }
        }

        // MARK: - Bindings

        /// [T-ios-scrollbtn-vm-split] Re-point the coordinator at a NEW view
        /// model instance when SwiftUI hands the (reused) representable a
        /// different AIChatViewModel for the same mounted chat view. All
        /// Combine subscriptions live in bindViewModel and are keyed to the
        /// old instance — cancel them wholesale and re-subscribe, then push
        /// the current snapshot + scroll flags into the new VM so its
        /// isNearBottom/messages state reflects reality instead of the
        /// initial defaults nobody would otherwise ever update.
        func rebindViewModelIfNeeded(_ newVM: AIChatViewModel) {
            if let current = vm, current === newVM { return }
            clearCompletionGlows()
            let hadOld = vm != nil
            invalidatePositionRequests()
            #if DEBUG
            ScrollMetricsRecorder.shared.record(
                kind: "rebind", a: hadOld ? 1 : 0,
                note: Self.nbDump(viewController?.collectionView))
            #endif
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][rebind] coordinator vm \(hadOld ? "changed" : "was nil") → rebinding subscriptions + resyncing flags")
            subscriptions.removeAll()
            lastMessageSub?.cancel(); lastMessageSub = nil
            lastMessageBlockCountSub?.cancel(); lastMessageBlockCountSub = nil
            lastMessageId = nil
            let previousFooterTailID = footerTail?.id
            footerTailSub = nil
            footerTail = nil
            stopSimpleProjection()
            footerUsageSubs.removeAll()
            pendingFooterIDs.removeAll()
            if let previousFooterTailID { pendingFooterIDs.insert(previousFooterTailID) }
            footerReconciliationScheduled = false
            vm = newVM
            newVM.chatSearch.updateTranscriptMode(transcriptMode)
            for (messageID, bridge) in cellBridges {
                observeFooterUsage(for: messageID, bridge: bridge)
            }
            bindViewModel(newVM)
            // Re-apply from the new VM's authoritative messages (identity may
            // be equal content-wise; applySnapshot no-ops on identical ids)
            // and push the CURRENT geometry into the new VM's published flags.
            if !newVM.isLoadingSession {
                applySnapshot(messages: newVM.messages, caller: "rebind")
            }
            syncScrollFlags()
        }

        private func bindViewModel(_ vm: AIChatViewModel) {
            // [T-ios-footer-stale-height] Seed the task-end edge detector with
            // the VM's current value so subscribing is not mistaken for a flip.
            lastProcessingValue = vm.isProcessing
            // 1. Messages → snapshot
            //    Skip while isLoadingSession — binding 3 handles the post-load apply.
            //    This prevents a redundant apply when $messages and $isLoadingSession
            //    dispatch to main queue in the same runloop cycle.
            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    guard let self else { return }
                    if let vm = self.vm { self.bindFooterTail(vm) }
                    self.scheduleFooterReconciliation()
                    // [T-message-list-empty-on-foreground] If a load is in flight,
                    // DON'T silently drop this update — applySnapshot would no-op
                    // (it early-returns while isLoadingSession). Record it as
                    // pending so binding 3's true→false edge flushes it. Dropping
                    // it was the empty-list bug: when $messages changed during a
                    // foreground-recovery reload but binding 3's edge was collapsed
                    // by removeDuplicates (or $messages landed just after loading
                    // flipped false in the same cycle), nothing ever re-applied —
                    // the list stayed on its stale/empty snapshot while the VM
                    // (and toolbar) had the full messages.
                    if self.vm?.isLoadingSession == true {
                        self.hasPendingSnapshot = true
                        return
                    }
                    self.flushPendingSnapshotIfNeeded(caller: "bind1-messages")
                    self.applySnapshot(messages: msgs, caller: "bind1-messages")
                }
                .store(in: &subscriptions)

            // 1c. [T-ios-ui-blocks-lost-suspend-resume] Suspend-resume flush.
            //     `streamingUIUpdatesSuspended` is a plain (private(set)) var on
            //     the vm — not @Published — but every state change that clears it
            //     (scroll-settle resume, session-transition resume, the SSE final
            //     flush) runs through the vm's @Published/objectWillChange surface.
            //     We piggy-back on `vm.objectWillChange` and edge-detect the
            //     true→false transition ourselves via `lastSuspendedValue`.
            //
            //     Why this is the missing path: during a long multi-tool agent
            //     loop, blocks appended while suspended only set
            //     `hasPendingSnapshot = true` (bind4b); the stream then ends and
            //     cancels the per-message subs, and the terminal rescue at
            //     stream-end skips the flush because suspend is still true (see
            //     the "STREAM-END left pending (still suspended)" log). After that
            //     nothing re-applies — `$messages` won't fire (blocks grew, the
            //     array didn't) and the block-count sub is gone. This hook fires
            //     the instant suspend lifts. Gated on `!isProcessing` so a
            //     mid-stream resume is left to the live subscriptions / settle
            //     path; only the stranded post-stream case is rescued here.
            lastSuspendedValue = vm.streamingUIUpdatesSuspended
            suspendResumeSub = vm.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, let vm = self.vm else { return }
                    self.scheduleFooterReconciliation()
                    let now = vm.streamingUIUpdatesSuspended
                    let was = self.lastSuspendedValue
                    self.lastSuspendedValue = now
                    // Only act on a genuine true→false transition.
                    guard was, !now else { return }
                    // [T-ios-ui-frozen-on-tool-while-loop-runs] Flush REGARDLESS
                    // of isProcessing. The old `isProcessing == false` guard left
                    // a mid-loop foreground-resume unflushed: when the app returns
                    // to foreground (resumeAllStreamingUI clears the flag) while
                    // the agent loop is STILL running, the deferred snapshot was
                    // skipped and — because the loop never hits stream-end — the
                    // UI stayed frozen on the last-rendered tool for minutes while
                    // many loop turns ran un-rendered, until an unrelated
                    // sheetDismiss/settle happened to flush. Resume always runs
                    // foreground, so applying the snapshot here is safe.
                    guard self.hasPendingSnapshot else { return }
                    AppLogger(category: "PendingSnap").info("[PendingSnap] suspend-resume flush applied (hasPendingSnapshot=true, isProcessing=\(vm.isProcessing))")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
            suspendResumeSub?.store(in: &subscriptions)

            // 1c. [T-ios-ui-blocks-lost-suspend-resume] Resume hook. When the vm
            //     clears `streamingUIUpdatesSuspended` (true→false) from ANY path,
            //     rebuild a snapshot that was deferred during the suspend window.
            //     Failure chain this fixes: during a multi-tool agent loop, new
            //     blocks append while suspended → blockCountSub only sets
            //     hasPendingSnapshot=true; the stream then ends and cancels the
            //     per-message subs; the terminal rescue sees still-suspended and
            //     skips the flush; nothing else can fire it. This hook is the
            //     missing trigger when suspend finally lifts. Only flush when the
            //     loop is no longer processing (a mid-stream resume is handled by
            //     the live subscriptions / settle path).
            vm.onStreamingUIUpdatesResumed = { [weak self, weak vm] in
                // Always main-thread: the chokepoint runs on the main actor, but
                // hop defensively so flush never races a background caller.
                let work = {
                    guard let self, let vm, self.vm === vm else { return }
                    self.scheduleFooterReconciliation()
                    // [T-ios-ui-frozen-on-tool-while-loop-runs] Flush regardless
                    // of isProcessing — see the objectWillChange sub above. A
                    // foreground-resume while the loop is still running must
                    // re-apply the deferred snapshot, or the UI freezes on the
                    // last-rendered tool until an unrelated sheetDismiss/settle.
                    guard self.hasPendingSnapshot else { return }
                    AppLogger(category: "PendingSnap").info("[PendingSnap] suspend-resume flush (hasPendingSnapshot=true, isProcessing=\(self.vm?.isProcessing == true))")
                    self.flushPendingSnapshotIfNeeded(caller: "suspend-resume")
                }
                if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
            }

            // 1b. Retry truncation signal — `retryFromToolBlock`'s sub-message
            //     path mutates `messages[i].blocks` in place without changing
            //     the messages array count, so `$messages` won't fire and the
            //     diffable snapshot keeps its pre-cut block identifiers.
            //     This signal forces a re-apply so stale blocks are removed.
            vm.retrySnapshotReloadSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self, let msgs = self.vm?.messages else { return }
                    let oldCount = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                    self.applySnapshot(messages: msgs, caller: "retrySnapshotReload")
                    let newCount = self.dataSource?.snapshot().itemIdentifiers.count ?? 0
                    if newCount != oldCount {
                        let totalBlocks = msgs.reduce(0) { $0 + $1.blocks.count }
                        AppLogger(category: "BlocksLost").info("[BlocksLost] SNAPSHOT REBUILT snapshotItems \(oldCount)→\(newCount) memoryBlocks=\(totalBlocks)")
                    }
                }
                .store(in: &subscriptions)

            // Capture before keyboard dismissal; only a committed user item
            // changes follow mode or survives the synchronous composer attempt.
            vm.composerWillSend
                .sink { [weak self] in
                    guard let self else { return }
                    let anchor = (self.viewController?.collectionView).flatMap { self.capturePosition(in: $0) }
                    let keyboardAnchor = self.keyboardAnchor
                    self.invalidatePositionRequests()
                    self.keyboardAnchor = keyboardAnchor
                    self.clampAfterSessionLoad = false
                    self.clampDeadline = .distantPast
                    self.sendPosition = .inserting(acceptedUser: nil, anchor: anchor)
                }
                .store(in: &subscriptions)

            vm.composerDidResolveSend
                .sink { [weak self] acceptedID in
                    guard let self, case .inserting(nil, let anchor)? = self.sendPosition else { return }
                    guard let acceptedID else { self.sendPosition = nil; return }
                    self.scrollMode = .autoScrolling
                    self.sendPosition = .inserting(acceptedUser: acceptedID, anchor: anchor)
                    self.vm?.setStreamingUIUpdatesSuspended(false)
                }
                .store(in: &subscriptions)

            // 2. Scroll signals
            vm.scrollToBottomSignal
                .map { [weak self] in self?.positionStamp() }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] stamp in
                    guard let self, let stamp, stamp == self.positionStamp(), self.scrollMode == .autoScrolling else { return }
                    self.enqueuePosition(.signal)
                }
                .store(in: &subscriptions)

            // 2b. Force scroll
            vm.forceScrollToBottom
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    guard let self else { return }
                    let cv = self.viewController?.collectionView
                    let layout = self.viewController?.messageListLayout
                    let cachedCount = layout?.debugCachedHeightCount ?? 0
                    let precalcCount = layout?.debugPrecalcHeightCount ?? 0
                    AppLogger(category: "ScrollDiag").info("[ScrollDiag][forceScrollToBottom] window=\(cv?.window != nil) contentSize=\(String(format: "%.0f", cv?.contentSize.height ?? 0)) bounds=\(String(format: "%.0f", cv?.bounds.height ?? 0)) adjInsetBot=\(String(format: "%.0f", cv?.adjustedContentInset.bottom ?? 0)) heightCache=\(cachedCount) precalc=\(precalcCount) visibleCells=\(cv?.visibleCells.count ?? 0)")
                    self.vm?.setStreamingUIUpdatesSuspended(false)
                    self.scrollMode = .autoScrolling
                    self.scrollToBottomNow(animated: true)
                }
                .store(in: &subscriptions)

            // 2d. [T-chat-search] Reveal a search hit. A browse action: do NOT
            // touch scrollMode, otherwise streaming would yank the viewport
            // back to the bottom right after the jump.
            NotificationCenter.default.publisher(for: .chatSearchJump)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] note in
                    guard let self, let vm = self.vm, note.object as AnyObject? === vm.chatSearch,
                          let hit = note.userInfo?["hit"] as? ChatSearchHit,
                          vm.chatSearch.isActive, vm.chatSearch.current?.match == hit.match,
                          vm.chatSearch.current?.keyword == hit.keyword else { return }
                    self.revealSearchHit(hit)
                }
                .store(in: &subscriptions)

            // 3. Session load
            vm.$isLoadingSession
                .removeDuplicates()
                .dropFirst()   // skip initial false — only react to true→false after actual load
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLoading in
                    guard let self, !isLoading else { return }
                    // Only clear caches when items will actually change — prevents
                    // a duplicate dispatch from clearing caches that won't be rebuilt.
                    if let msgs = self.vm?.messages {
                        self.viewController?.messageListLayout?.clearHeightCache()
                        self.attrStringHeightCache.removeAll()
                        self.userBubbleHeightCache.removeAll()
                        // This is the authoritative post-load apply; it carries the
                        // latest messages, so any snapshot deferred during the load
                        // window (bind1 set hasPendingSnapshot) is now satisfied.
                        // [T-message-list-empty-on-foreground]
                        self.hasPendingSnapshot = false
                        self.applySnapshot(messages: msgs, caller: "bind3-sessionLoad")
                    }
                    self.refreshAfterForegroundIfNeeded()
                    self.scheduleFooterReconciliation()
                    // Sync reload: keep current scroll position, just update data
                }
                .store(in: &subscriptions)

            // 4. Streaming: subscribe to last assistant message + block count changes.
            // Use the last assistant message (not msgs.last) because queued user
            // messages can be appended while an assistant is still streaming.
            vm.$messages
                .receive(on: DispatchQueue.main)
                .sink { [weak self] msgs in
                    let lastAssistant = msgs.last(where: { $0.role == .assistant })
                    self?.subscribeToLastMessage(lastAssistant)
                }
                .store(in: &subscriptions)

            // 4b. Re-subscribe when isProcessing transitions to true (retry/resume).
            // Retry reuses the existing assistant message without mutating the messages
            // array, so $messages won't fire. The block-count subscription was torn down
            // when processing stopped; re-establish it here.
            vm.$isProcessing
                .removeDuplicates()
                .filter { $0 }   // only on false → true transition
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.lastMessageId = nil  // force re-subscribe
                    let lastAssistant = self.vm?.messages.last(where: { $0.role == .assistant })
                    self.subscribeToLastMessage(lastAssistant)
                }
                .store(in: &subscriptions)

            // 5. State changes → bridge updates
            Publishers.CombineLatest4(
                vm.$isProcessing, vm.$autoRetryAttempt,
                vm.$autoRetryCountdown, vm.$canResume
            )
            .removeDuplicates { a, b in a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let wasProcessing = self.lastProcessingValue
                self.lastProcessingValue = state.0
                self.updateLastCellBridge()
                if wasProcessing != state.0, let messages = self.vm?.messages {
                    for message in messages where message.role == .assistant {
                        if let bridge = self.cellBridges[message.id] {
                            self.refreshCompletionActions(bridge, message: message, processing: state.0)
                        }
                    }
                }
                if wasProcessing, !state.0 {
                    if self.vm?.isProcessing == false, self.sendPosition != nil {
                        self.sendPosition = nil
                        self.enqueuePosition(.sendEnded)
                    }
                }
            }
            .store(in: &subscriptions)

            vm.$isProcessing.combineLatest(vm.$canResume)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak vm] _ in
                    guard let self, let vm, self.vm === vm else { return }
                    self.markFooterTailDirty(vm)
                }
                .store(in: &subscriptions)

            let tracker = SessionActivityTracker.shared
            tracker.$activeSessions.combineLatest(tracker.$draftAliases)
                .receive(on: DispatchQueue.main)
                .map { [weak vm] sessions, aliases in
                    guard let sessionID = vm?.sessionId else { return false }
                    return sessions.contains(sessionID) || aliases[sessionID].map(sessions.contains) == true
                }
                .removeDuplicates()
                .sink { [weak self, weak vm] _ in
                    guard let self, let vm, self.vm === vm else { return }
                    self.updateLastCellBridge()
                    self.markFooterTailDirty(vm)
                }
                .store(in: &subscriptions)

            // 6. Compact finished → reconfigure all cells to update opacity/divider
            vm.$isCompacting
                .removeDuplicates()
                .dropFirst()   // skip initial value — only react to actual true→false transitions
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isCompacting in
                    guard let self, !isCompacting else { return }
                    // Compact just ended — apply snapshot for new divider/removed messages,
                    // then reconfigure visible cells so opacity updates. Do NOT clear height
                    // cache — compacted messages retain their measured heights to prevent
                    // scroll jitter when scrolling back into the compacted zone.
                    if let msgs = self.vm?.messages { self.applySnapshot(messages: msgs, caller: "bind6-compact") }
                    self.reconfigureVisibleCells()
                }
                .store(in: &subscriptions)

            // 7. Font size changes
            NotificationCenter.default.publisher(for: .fontSettingsMessageBaseChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.vm?.invalidateAttributedStringCaches()
                    self.reconfigureAllCells()
                }
                .store(in: &subscriptions)

            // 8. Recover after the app is active, not willEnterForeground:
            // deferred model text must be released before rebuilding cells.
            NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.rememberScrollAnchor()
                    let anchor = (self.viewController?.collectionView).flatMap { self.capturePosition(in: $0) }
                    self.invalidatePositionRequests()
                    self.foregroundAnchor = anchor
                    self.needsForegroundRefresh = true
                }
                .store(in: &subscriptions)

            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.needsForegroundRefresh = true
                    self.refreshAfterForegroundIfNeeded()
                    self.scheduleFooterReconciliation()
                }
                .store(in: &subscriptions)

            // 9. Text block filled — reconfigure the cell so UIHostingConfiguration
            //    re-measures height after transitioning from empty to non-empty.
            vm.blockContentFilledSignal
                .receive(on: DispatchQueue.main)
                .sink { [weak self] (messageId, blockId) in
                    guard let self,
                          let ds = self.dataSource else { return }
                    let item = MessageListItem.assistantBlock(messageId, blockId)
                    var snapshot = ds.snapshot()
                    let items = snapshot.itemIdentifiers
                    guard let idx = items.firstIndex(of: item) else { return }

                    // Invalidate the height cache BEFORE reconfiguring so the
                    // layout doesn't reuse the stale empty-content height.
                    // Without this, the cell briefly keeps its ~0pt height from
                    // the empty block, causing overlap with the tool block above.
                    self.viewController?.messageListLayout?.invalidateHeight(at: idx)

                    snapshot.reconfigureItems([item])
                    ds.apply(snapshot, animatingDifferences: false)
                }
                .store(in: &subscriptions)

            // 10a. Capture the tapped message's viewport position synchronously,
            // BEFORE @Published changes its SwiftUI body. Do not add receive(on:)
            // here: NotificationCenter delivery from the main-thread tap must
            // remain synchronous so bottom pinning is disabled before mutation.
            NotificationCenter.default.publisher(for: .userMessageExpansionWillToggle)
                .sink { [weak self] notification in
                    self?.beginUserMessageExpansionToggle(notification)
                }
                .store(in: &subscriptions)

            // 10b. A long user bubble was expanded/collapsed. Re-measure it and
            // explicitly restore the pre-toggle viewport anchor after both the
            // immediate and deferred UIHostingConfiguration sizing passes.
            NotificationCenter.default.publisher(for: .userMessageExpansionToggled)
                .sink { [weak self] notification in
                    self?.finishUserMessageExpansionToggle(notification)
                }
                .store(in: &subscriptions)
        }

        /// Begins a manual disclosure transaction. Expansion/collapse is a
        /// browsing action, even if the list happened to be pinned at bottom:
        /// automatic following resumes only after the user explicitly returns
        /// to the bottom (or uses the jump-to-bottom action).
        private func beginUserMessageExpansionToggle(_ notification: Notification) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard let messageId = notification.object as? UUID,
                  let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else { return }

            let item = MessageListItem.wholeMessage(messageId)
            guard let index = ds.snapshot().itemIdentifiers.firstIndex(of: item) else { return }

            let oldMode = scrollMode
            scrollMode = .userBrowsing
            clampAfterSessionLoad = false
            // [T-ios-user-collapse-smooth] Silence the contentSize-KVO side
            // effects (bottom pin / overscroll clamp) for the whole
            // transaction — the settle probes own the offset until the
            // finalize below releases this.
            isFlushing = true
            pendingScrollWork?.cancel()
            pendingScrollWork = nil
            isAnimatingScrollToBottom = false
            cv.setContentOffset(cv.contentOffset, animated: false)

            // Generic visible-cell compensation preserves content below a cell;
            // disclosure instead preserves the tapped cell itself explicitly.
            layout.suppressContentOffsetAdjustment = true
            cv.layoutIfNeeded()

            let indexPath = IndexPath(item: index, section: 0)
            guard let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else {
                layout.suppressContentOffsetAdjustment = false
                // [T-ios-user-collapse-smooth] This bail must release every
                // piece of state the transaction set above it — including the
                // KVO flush gate added for the disclosure — or a rare missing
                // frame would leave the list permanently muted.
                isFlushing = false
                return
            }

            let anchor = UserMessageViewportAnchor(
                messageId: messageId,
                screenMinY: frame.minY - cv.contentOffset.y,
                generation: UUID(),
                wasExpanded: notification.userInfo?["expanded"] as? Bool,
                initialOffsetY: cv.contentOffset.y,
                initialContentHeight: cv.contentSize.height
            )
            userMessageViewportAnchor = anchor

            AppLogger(category: "UserMessageCollapse").info(
                "[ToggleWill] id=\(messageId.uuidString.prefix(8)) expanded=\(anchor.wasExpanded.map { String(describing: $0) } ?? "unknown") mode=\(oldMode == .autoScrolling ? "auto" : "browse")→browse offset=\(String(format: "%.1f", anchor.initialOffsetY)) screenY=\(String(format: "%.1f", anchor.screenMinY)) contentH=\(String(format: "%.1f", anchor.initialContentHeight))"
            )
        }

        private func finishUserMessageExpansionToggle(_ notification: Notification) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard let messageId = notification.object as? UUID,
                  let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else { return }

            // Defensive fallback for any caller that posts only the historical
            // did-toggle notification. In the normal path the synchronous will
            // notification has already captured the still-collapsed frame.
            if userMessageViewportAnchor?.messageId != messageId {
                beginUserMessageExpansionToggle(notification)
            }
            guard let anchor = userMessageViewportAnchor,
                  anchor.messageId == messageId else { return }

            let item = MessageListItem.wholeMessage(messageId)
            var snapshot = ds.snapshot()
            guard let index = snapshot.itemIdentifiers.firstIndex(of: item) else {
                cancelUserMessageExpansionAnchor(anchor.generation)
                return
            }

            let indexPath = IndexPath(item: index, section: 0)
            (cv.cellForItem(at: indexPath) as? SelfSizingCell)?.clearCachedHeight()
            layout.invalidateHeight(at: index)

            // [T-ios-user-collapse-smooth] Refresh the layout metadata for the
            // NEW disclosure state before the invalidation below. Without this
            // the next pass still consulted the pre-toggle precalc/estimate —
            // `invalidateHeight` only drops the real-height cache — so the cell
            // was laid out at the old height first and needed a second
            // self-size correction; together with the deferred restores that
            // was the visible multi-step "jelly" on every toggle.
            let messages = snapshotMessages.isEmpty ? (vm?.messages ?? []) : snapshotMessages
            if let msgIdx = messageIndex[messageId], msgIdx < messages.count {
                let message = messages[msgIdx]
                if message.role == .user, !message.isQueued {
                    let cvW = cv.bounds.width
                    let key = transcriptContentKey(for: item, messages: messages, width: cvW)
                    layout.setContentKey(key, at: index)
                    let effWidth = maxContentWidth > 0 ? min(cvW, maxContentWidth) : cvW
                    if let h = Self.measureUserBubbleHeight(
                        for: message,
                        cvWidth: effWidth,
                        cache: &userBubbleHeightCache
                    ) {
                        layout.setPrecalcHeight(h, at: index)
                        layout.setEstimatedHeight(h, at: index)
                    }
                }
            }

            snapshot.reconfigureItems([item])

            let expanded = notification.userInfo?["expanded"] as? Bool
            AppLogger(category: "UserMessageCollapse").info(
                "[ToggleDid] id=\(messageId.uuidString.prefix(8)) expanded=\(expanded.map { String(describing: $0) } ?? "unknown") invalidateIndex=\(index)"
            )

            ds.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                // [T-ios-user-collapse-smooth] One coordinated pass replaces the
                // old instant pass + apply/nextRunloop/+0.08s snap sequence: the
                // pass either animates (normal case) or falls back to the
                // historical instant behavior, then the settle probes below
                // re-anchor silently until the disclosure is stable (or the
                // window ends).
                self.runUserMessageExpansionLayoutPass(anchor: anchor, index: index)
            }
        }

        /// [T-ios-user-collapse-smooth] Runs the post-toggle layout pass for the
        /// tapped bubble. In the normal case the pass animates inside
        /// `UIView.animate` (the NoAnimation collection view skips its
        /// performWithoutAnimation strip for exactly this pass via
        /// `disclosureAnimationInFlight`), so the bubble's height and the
        /// positions of the items below it interpolate as one coordinated move.
        /// While the user is scrolling, while Reduce Motion is on, or when the
        /// cell is off-screen, it falls back to the historical instant pass.
        /// Either way the settle probes are scheduled afterwards, and the
        /// offset compensation stays anchored to the tapped bubble's top edge
        /// (captured in `beginUserMessageExpansionToggle`).
        private func runUserMessageExpansionLayoutPass(
            anchor: UserMessageViewportAnchor,
            index: Int
        ) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout else { return }

            let indexPath = IndexPath(item: index, section: 0)
            let animatingCV = cv as? NoAnimationCollectionView
            let canAnimate = disclosureAnimationEnabled
                && animatingCV != nil
                && !UIAccessibility.isReduceMotionEnabled
                && !cv.isTracking
                && !cv.isDecelerating
                && cv.window != nil
                && cv.cellForItem(at: indexPath) != nil

            if canAnimate, let animatingCV {
                beginDisclosureClip(cv.cellForItem(at: indexPath) as? SelfSizingCell)
                AppLogger(category: "UserMessageCollapse").info(
                    "[ToggleAnim] id=\(anchor.messageId.uuidString.prefix(8)) mode=animated dur=\(Self.disclosureAnimationDuration)"
                )
                UIView.animate(
                    withDuration: Self.disclosureAnimationDuration,
                    delay: 0,
                    options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
                ) {
                    layout.invalidateLayout()
                    cv.setNeedsLayout()
                    // [T-ios-user-collapse-smooth] The flag is confined to
                    // exactly this synchronous pass: implicit animations are
                    // created while it is true, then it is cleared immediately
                    // so any later pass during the animation tail keeps the
                    // historical instant path.
                    animatingCV.disclosureAnimationInFlight = true
                    cv.layoutIfNeeded()
                    animatingCV.disclosureAnimationInFlight = false
                    if let solution = self.solveDisclosureAnchor(anchor),
                       abs(solution.target - cv.contentOffset.y) > 0.5 {
                        cv.setContentOffset(
                            CGPoint(x: cv.contentOffset.x, y: solution.target),
                            animated: false
                        )
                    }
                } completion: { [weak self] _ in
                    guard let self else { return }
                    animatingCV.disclosureAnimationInFlight = false
                    self.endDisclosureClip()
                    self.scheduleUserMessageExpansionSettles(anchor.generation)
                }
                return
            }

            AppLogger(category: "UserMessageCollapse").info(
                "[ToggleAnim] id=\(anchor.messageId.uuidString.prefix(8)) mode=instant animEnabled=\(disclosureAnimationEnabled) reduceMotion=\(UIAccessibility.isReduceMotionEnabled) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) visibleCell=\(cv.cellForItem(at: indexPath) != nil)"
            )
            layout.invalidateLayout()
            cv.setNeedsLayout()
            cv.layoutIfNeeded()
            restoreUserMessageExpansionAnchor(anchor.generation, phase: "apply", finalize: false)
            scheduleUserMessageExpansionSettles(anchor.generation)
        }

        /// [T-ios-user-collapse-smooth] Shared anchoring equation: given the
        /// pre-toggle anchor, where should the collection view's offset sit for
        /// the CURRENT layout so the tapped bubble's top edge lands back at its
        /// preserved screen Y? Used by the animated pass, every settle probe,
        /// and the stability check — one equation, no drift between them.
        private func solveDisclosureAnchor(
            _ anchor: UserMessageViewportAnchor
        ) -> DisclosureAnchorSolution? {
            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout,
                  let ds = dataSource else { return nil }
            let item = MessageListItem.wholeMessage(anchor.messageId)
            guard let index = ds.snapshot().itemIdentifiers.firstIndex(of: item) else { return nil }
            let indexPath = IndexPath(item: index, section: 0)
            guard let frame = layout.layoutAttributesForItem(at: indexPath)?.frame else { return nil }

            let minimumOffset = -cv.adjustedContentInset.top
            let maximumOffset = max(
                minimumOffset,
                cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            )
            let desiredOffset = frame.minY - anchor.screenMinY
            let targetOffset = CGFloat(UserMessageCollapsePolicy.viewportOffset(
                itemMinY: Double(frame.minY),
                preservedScreenMinY: Double(anchor.screenMinY),
                minimumOffset: Double(minimumOffset),
                maximumOffset: Double(maximumOffset)
            ))
            return DisclosureAnchorSolution(
                index: index,
                frameMinY: frame.minY,
                frameHeight: frame.height,
                target: targetOffset,
                desired: desiredOffset,
                minimum: minimumOffset,
                maximum: maximumOffset
            )
        }

        private struct DisclosureAnchorSolution {
            let index: Int
            let frameMinY: CGFloat
            let frameHeight: CGFloat
            let target: CGFloat
            let desired: CGFloat
            let minimum: CGFloat
            let maximum: CGFloat
        }

        private func restoreUserMessageExpansionAnchor(
            _ generation: UUID,
            phase: String,
            finalize: Bool,
            correct: Bool = true
        ) {
            dispatchPrecondition(condition: .onQueue(.main))
            guard let anchor = userMessageViewportAnchor,
                  anchor.generation == generation,
                  let cv = viewController?.collectionView else { return }

            cv.layoutIfNeeded()
            guard let solution = solveDisclosureAnchor(anchor) else {
                if finalize { cancelUserMessageExpansionAnchor(generation) }
                return
            }

            let drift = solution.target - cv.contentOffset.y
            if correct, abs(drift) > 0.5 {
                // [T-ios-user-collapse-smooth] Only ever move the offset for a
                // real (>0.5pt) drift; unconditional sub-pixel writes were one
                // source of the visible settle "twitch".
                UIView.performWithoutAnimation {
                    cv.setContentOffset(
                        CGPoint(x: cv.contentOffset.x, y: solution.target),
                        animated: false
                    )
                    cv.layoutIfNeeded()
                }
            }

            AppLogger(category: "UserMessageCollapse").info(
                "[ToggleAnchor] id=\(anchor.messageId.uuidString.prefix(8)) phase=\(phase) frameY=\(String(format: "%.1f", solution.frameMinY)) frameH=\(String(format: "%.1f", solution.frameHeight)) desired=\(String(format: "%.1f", solution.desired)) target=\(String(format: "%.1f", solution.target)) drift=\(String(format: "%+.1f", drift)) bounds=[\(String(format: "%.1f", solution.minimum)),\(String(format: "%.1f", solution.maximum))] contentH=\(String(format: "%.1f", cv.contentSize.height))"
            )

            if finalize {
                viewController?.messageListLayout?.suppressContentOffsetAdjustment = false
                endDisclosureClip()
                userMessageViewportAnchor = nil
                isFlushing = false
                syncScrollFlags()
                enqueuePosition(.disclosure)
            }
        }

        /// [T-ios-user-collapse-smooth] Post-toggle stability sequence. The
        /// hosting measure of the swapped SwiftUI content can publish its new
        /// intrinsic size one or more runloop turns after the reconfiguration,
        /// so each probe re-anchors the tapped bubble's top edge (silently,
        /// >0.5pt drift only) and watches the item's frame. The transaction
        /// closes as soon as two consecutive probes see a frozen frame AND the
        /// real self-sized height is in the layout cache (from step 0.2 on), or
        /// at the final probe (0.4s) at the latest. While the user drags or
        /// decelerates, the probes stop correcting immediately and just
        /// release. Known residual: a late self-size that lands between probes
        /// is consumed by the next probe without animation (one small snap) —
        /// same class of behavior as the previous implementation, but bounded
        /// to a single step inside this window.
        private func scheduleUserMessageExpansionSettles(_ generation: UUID) {
            let probes: [Double] = [0, 0.08, 0.2, 0.4]
            var previousHeight: CGFloat?
            for (step, delay) in probes.enumerated() {
                let isLast = step == probes.count - 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self,
                          let anchor = self.userMessageViewportAnchor,
                          anchor.generation == generation,
                          let cv = self.viewController?.collectionView,
                          let layout = self.viewController?.messageListLayout else { return }

                    if cv.isTracking || cv.isDecelerating {
                        // User took over the scroll — release without touching
                        // the offset (a correction here would fight the gesture).
                        self.restoreUserMessageExpansionAnchor(
                            generation,
                            phase: "userTakeover",
                            finalize: true,
                            correct: false
                        )
                        return
                    }

                    self.restoreUserMessageExpansionAnchor(
                        generation,
                        phase: "settle\(step)",
                        finalize: false
                    )

                    guard let solution = self.solveDisclosureAnchor(anchor) else {
                        if isLast {
                            self.restoreUserMessageExpansionAnchor(
                                generation,
                                phase: "settleFinal",
                                finalize: true
                            )
                        }
                        return
                    }

                    let frozen = previousHeight.map { abs(solution.frameHeight - $0) < 0.5 } ?? false
                    previousHeight = solution.frameHeight

                    if isLast {
                        self.restoreUserMessageExpansionAnchor(
                            generation,
                            phase: "settleFinal",
                            finalize: true
                        )
                        return
                    }

                    let heightLanded = layout.cachedHeight(at: solution.index) != nil
                    let drift = abs(solution.target - cv.contentOffset.y)
                    if step >= 2, frozen, heightLanded, drift < 0.5 {
                        AppLogger(category: "UserMessageCollapse").info(
                            "[ToggleSettle] id=\(anchor.messageId.uuidString.prefix(8)) stable step=\(step) frameH=\(String(format: "%.1f", solution.frameHeight))"
                        )
                        self.restoreUserMessageExpansionAnchor(
                            generation,
                            phase: "settleStable",
                            finalize: true
                        )
                    }
                }
            }
        }

        /// [T-ios-user-collapse-smooth] The toggled cell is clipped for the
        /// duration of the animated pass so the already-final SwiftUI content
        /// wipes behind the animating bubble edge instead of overflowing the
        /// still-growing box; the original clip state is restored right after.
        private func beginDisclosureClip(_ cell: SelfSizingCell?) {
            guard disclosureClippedCell == nil, let cell else { return }
            disclosureClippedCell = cell
            disclosureClippedCellRestore = (cell.clipsToBounds, cell.contentView.clipsToBounds)
            cell.clipsToBounds = true
            cell.contentView.clipsToBounds = true
        }

        private func endDisclosureClip() {
            defer {
                disclosureClippedCell = nil
                disclosureClippedCellRestore = nil
            }
            guard let cell = disclosureClippedCell,
                  let restore = disclosureClippedCellRestore else { return }
            cell.clipsToBounds = restore.cell
            cell.contentView.clipsToBounds = restore.content
        }

        private func cancelUserMessageExpansionAnchor(_ generation: UUID) {
            guard userMessageViewportAnchor?.generation == generation else { return }
            viewController?.messageListLayout?.suppressContentOffsetAdjustment = false
            endDisclosureClip()
            userMessageViewportAnchor = nil
            isFlushing = false
        }

        // MARK: - Foreground Presentation Recovery

        fileprivate func refreshAfterForegroundIfNeeded() {
            guard needsForegroundRefresh,
                  UIApplication.shared.applicationState == .active,
                  let vm, !vm.isLoadingSession, !vm.transitionSuspended,
                  let cv = viewController?.collectionView, cv.window != nil,
                  let layout = viewController?.messageListLayout else { return }
            needsForegroundRefresh = false
            let anchor = foregroundAnchor ?? capturePosition(in: cv)
            foregroundAnchor = nil
            let generation = transcriptGeneration
            // Rebuild and reconfigure before exposing the recovery target.
            performPositionBatch {
                self.enqueuePosition(.foreground, anchor: anchor)
                self.rebuildForegroundPresentation(vm: vm, cv: cv, layout: layout)
            }
            // Hosting configuration publishes one more real measurement after
            // the new bodies mount. Keep the measurement, not a second restore.
            DispatchQueue.main.async { [weak self, weak vm, weak cv] in
                guard let self, let vm, let cv, self.vm === vm,
                      self.transcriptGeneration == generation,
                      self.viewController?.collectionView === cv,
                      UIApplication.shared.applicationState == .active,
                      !vm.isLoadingSession, !vm.transitionSuspended, cv.window != nil,
                      let layout = self.viewController?.messageListLayout else { return }
                for indexPath in cv.indexPathsForVisibleItems {
                    (cv.cellForItem(at: indexPath) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateContentHeight(at: indexPath.item)
                }
                UIView.performWithoutAnimation {
                    layout.invalidateLayout()
                    cv.setNeedsLayout()
                }
            }
            AppLogger(category: "FGLayout").info("[FGLayout] recovered current VM: messages=\(vm.messages.count) items=\(dataSource.snapshot().numberOfItems)")
        }

        private func performPositionBatch(_ changes: () -> Void) {
            viewportGeometryCommitDepth += 1
            defer {
                viewportGeometryCommitDepth -= 1
                if viewportGeometryCommitDepth == 0, let cv = viewController?.collectionView {
                    cv.setNeedsLayout()
                    cv.layoutIfNeeded()
                }
            }
            UIView.performWithoutAnimation(changes)
        }

        private func rebuildForegroundPresentation(vm: AIChatViewModel, cv: UICollectionView, layout: MessageListLayout) {
            pendingStreamingLayout?.cancel()
            pendingStreamingLayout = nil
            // The mounted VM is authoritative, including an uncached draft.
            // Clear a scroll defer left behind when background interrupted it.
            layout.deferSelfSizing = false
            layout.applyDeferredHeights()
            vm.setStreamingUIUpdatesSuspended(false)
            lastMessageId = nil
            subscribeToLastMessage(vm.messages.last(where: { $0.role == .assistant }))
            hasPendingSnapshot = false
            layout.clearHeightCache()
            attrStringHeightCache.removeAll()
            userBubbleHeightCache.removeAll()
            for cell in cv.visibleCells { (cell as? SelfSizingCell)?.clearCachedHeight() }
            applySnapshot(messages: vm.messages, caller: "foreground")
            // IDs can be unchanged while text, tools, footer or observed
            // objects changed. A snapshot no-op must not skip reconfiguration.
            reconfigureVisibleCells()
        }

        private var transcriptMode: ChatTranscriptDisplayMode = .standard
        private var requestedTranscriptMode: ChatTranscriptDisplayMode = .standard
        private var transcriptGeneration: UInt = 0
        private var transcriptUpdateScheduled = false
        private var simpleRows: [MessageListItem: SimpleTranscript.Row] = [:]
        private var simpleBlockObjects: [MessageListItem: ObjectIdentifier] = [:]
        private var simpleProjectionDirty = false
        private var simpleMessageSubs: [UUID: (ObjectIdentifier, AnyCancellable)] = [:]
        private var simpleContentSubs: [UUID: AnyCancellable] = [:]
        private var completionGlowSubscriptions = Set<AnyCancellable>()
        private var allowsCompletionGlow = false

        func setAllowsCompletionGlow(_ allowed: Bool) {
            allowsCompletionGlow = allowed
            if !allowed { clearCompletionGlows() }
        }

        private func showCompletionGlow(_ event: ReplyCompletionGlowEvent) {
            guard allowsCompletionGlow, vm?.sessionId == event.sessionID,
                  transcriptMode == .simple, requestedTranscriptMode == .simple,
                  UIApplication.shared.applicationState == .active,
                  !SessionLockStore.shared.appIsLocked, !SessionLockStore.shared.isVisuallyLocked(event.sessionID),
                  let vc = viewController, vc.isListOnScreen, let cv = vc.collectionView,
                  let window = cv.window, window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
                  let message = vm?.messages.first(where: { $0.id == event.messageID }) else { return }
            let target = message.blocks.reversed().lazy.compactMap { block -> MessageListItem? in
                guard SimpleTranscript.row(for: block) == .text,
                      let id = SimpleBodySegment.parse(block.content, finalised: true).last(where: \.hasVisibleText)?.id else { return nil }
                return .assistantBlock(message.id, block.id, id)
            }.first
            guard let item = target, simpleRows[item] == .text,
                  let indexPath = dataSource?.indexPath(for: item),
                  cv.indexPathsForVisibleItems.contains(indexPath),
                  let cell = cv.cellForItem(at: indexPath) as? AssistantBlockCellV3,
                  cell.glowItem == item else { return }
            cell.completionGlow.play(in: cell, collectionView: cv)
        }

        private func clearCompletionGlows() {
            for case let cell as AssistantBlockCellV3 in viewController?.collectionView?.visibleCells ?? [] {
                cell.completionGlow.clear()
            }
        }

        func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
            (cell as? AssistantBlockCellV3)?.completionGlow.clear()
        }

        func setInitialTranscriptMode(_ mode: ChatTranscriptDisplayMode) {
            transcriptMode = mode
            requestedTranscriptMode = mode
        }

        func requestTranscriptMode(_ mode: ChatTranscriptDisplayMode) {
            if mode != requestedTranscriptMode { clearCompletionGlows() }
            requestedTranscriptMode = mode
            scheduleTranscriptUpdate()
        }

        private func scheduleTranscriptUpdate() {
            guard (requestedTranscriptMode != transcriptMode || simpleProjectionDirty), !transcriptUpdateScheduled,
                  let vm, canReconcileFooters(vm), let cv = viewController?.collectionView,
                  requestedTranscriptMode == transcriptMode || positionIsAvailable(in: cv) else { return }
            transcriptUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.transcriptUpdateScheduled = false
                guard let vm = self.vm, self.canReconcileFooters(vm), let cv = self.viewController?.collectionView else { return }
                let changesMode = self.requestedTranscriptMode != self.transcriptMode
                guard !changesMode || self.positionIsAvailable(in: cv) else { return }
                guard changesMode || self.simpleProjectionDirty else { return }
                self.simpleProjectionDirty = false
                let before = changesMode ? self.capturePosition(in: cv) : nil
                if changesMode {
                    self.cancelSearchPlacement()
                    self.searchPositionOwner = nil
                    self.positionOwnerGeneration &+= 1
                    self.positionGeneration &+= 1
                    self.pendingScrollWork?.cancel()
                    self.pendingScrollWork = nil
                    self.pendingStreamingLayout?.cancel()
                    self.pendingStreamingLayout = nil
                    self.transcriptMode = self.requestedTranscriptMode
                    if self.transcriptMode == .standard { self.stopSimpleProjection() }
                    self.transcriptGeneration &+= 1
                    self.viewController?.messageListLayout?.beginTranscriptGeneration(self.transcriptGeneration)
                    self.userBubbleHeightCache.removeAll()
                    self.attrStringHeightCache.removeAll()
                    self.appliedFooters.removeAll()
                    for case let cell as SelfSizingCell in cv.visibleCells { cell.clearCachedHeight() }
                }
                self.applySnapshot(messages: vm.messages, caller: changesMode ? "transcript-mode" : "simple-projection",
                                   modeChanged: changesMode, modeAnchor: before)
                vm.chatSearch.updateTranscriptMode(self.transcriptMode)
                if changesMode, !self.previousSnapshotIds.isEmpty { self.rememberScrollAnchor(preservingBrowseIntent: true) }
            }
        }

        private typealias Edge = AnyPublisher<Void, Never>

        private static func contentEdges(_ block: AssistantBlock) -> Edge {
            let body = block.simpleBody
            let updates = body.observe(block)
            let states = body.$segments.map { $0.map(\.id) }.removeDuplicates().dropFirst().map { _ in () }
            return Publishers.Merge(states, updates).eraseToAnyPublisher()
        }

        private func invalidateSimpleSegment(_ item: MessageListItem, ownedBy block: AssistantBlock) {
            guard transcriptMode == .simple, simpleBlockObjects[item] == ObjectIdentifier(block),
                  let path = dataSource?.indexPath(for: item), let vc = viewController,
                  let layout = vc.messageListLayout else { return }
            enqueuePosition(.attachment, scheduleLayout: false)
            (vc.collectionView.cellForItem(at: path) as? SelfSizingCell)?.clearCachedHeight()
            layout.invalidateContentHeight(at: path.item)
            layout.setContentKey(transcriptContentKey(for: item, messages: snapshotMessages, width: vc.collectionView.bounds.width), at: path.item)
            layout.setEstimatedHeight(Self.estimateItemHeight(item, messages: snapshotMessages, width: vc.collectionView.bounds.width,
                                                              maxContentWidth: maxContentWidth, simpleRow: simpleRows[item]), at: path.item)
            layout.invalidateLayout()
        }

        private func itemsReferencingAttachment(_ source: String, in items: [MessageListItem]) -> [MessageListItem] {
            let canonical = ImageAttachment.canonicalizeMarkdownImageSource(source)
            func matches(_ candidate: String) -> Bool {
                ImageAttachment.canonicalizeMarkdownImageSource(candidate) == canonical
            }
            func containsImage(_ inline: InlineNode) -> Bool {
                if case .image(let source, _) = inline { return matches(source) }
                return inline.children.contains(where: containsImage)
            }
            func containsImageBlock(_ block: BlockNode) -> Bool {
                switch block {
                case .heading(_, let content), .paragraph(let content): return content.contains(where: containsImage)
                default: return block.children.contains(where: containsImageBlock)
                }
            }
            return items.filter { item in
                guard let index = messageIndex[item.messageId], snapshotMessages.indices.contains(index) else { return false }
                let message = snapshotMessages[index]
                switch item {
                case .wholeMessage:
                    return message.attachments.contains { matches($0.zeURL) }
                case .assistantBlock(_, let blockID, let segmentID):
                    guard let block = message.blocks.first(where: { $0.id == blockID }) else { return false }
                    if let segmentID {
                        guard transcriptMode == .simple else { return false }
                        return block.simpleBody.segments(inRow: segmentID).contains { segment in
                            guard let media = segment.media else { return false }
                            return matches(media.source)
                        }
                    }
                    guard transcriptMode == .standard, block.content.contains("![") else { return false }
                    let markdown = block.cachedMarkdown ?? MarkdownContent(prepareMarkdownForRender(block.content))
                    return markdown.blocks.contains(where: containsImageBlock)
                default: return false
                }
            }
        }

        private func attachmentSizeChanged(_ source: String) {
            guard !source.isEmpty, let dataSource, let vc = viewController,
                  let cv = vc.collectionView, let layout = vc.messageListLayout else { return }
            var snapshot = dataSource.snapshot()
            let affected = itemsReferencingAttachment(source, in: snapshot.itemIdentifiers)
            guard !affected.isEmpty else { return }
            enqueuePosition(.attachment, scheduleLayout: false)
            for item in affected {
                guard let path = dataSource.indexPath(for: item) else { continue }
                (cv.cellForItem(at: path) as? SelfSizingCell)?.clearCachedHeight()
                layout.invalidateContentHeight(at: path.item)
            }
            snapshot.reconfigureItems(affected)
            dataSource.apply(snapshot, animatingDifferences: false)
            let stamp = positionStamp()
            let generation = transcriptGeneration
            DispatchQueue.main.async { [weak self, weak cv, weak layout] in
                guard let self, let cv, let layout, self.viewController?.collectionView === cv,
                      self.transcriptGeneration == generation else { return }
                for item in affected {
                    guard let path = self.dataSource?.indexPath(for: item) else { continue }
                    (cv.cellForItem(at: path) as? SelfSizingCell)?.clearCachedHeight()
                    layout.invalidateContentHeight(at: path.item)
                }
                layout.invalidateLayout()
                if let stamp, self.positionStamp() == stamp, self.consumeSessionLoadClamp() { self.enqueuePosition(.attachment) }
            }
        }

        private func observeSimpleContent(_ message: ChatMessage) -> AnyCancellable {
            message.$blocks.removeDuplicates { $0.elementsEqual($1, by: { $0 === $1 }) }
                .map { blocks -> AnyPublisher<(AssistantBlock, [SimpleSegmentID]), Never> in
                    Publishers.MergeMany(blocks.map { block in
                        block.$kind.removeDuplicates().map { kind -> AnyPublisher<(AssistantBlock, [SimpleSegmentID]), Never> in
                            guard kind == .text else { return Empty().eraseToAnyPublisher() }
                            return block.simpleBody.contentChanges.compactMap { [weak block] changes in
                                block.map { ($0, changes) }
                            }.eraseToAnyPublisher()
                        }.switchToLatest()
                    }).eraseToAnyPublisher()
                }
                .switchToLatest()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak message] change in
                    guard let self, let message, self.simpleMessageSubs[message.id]?.0 == ObjectIdentifier(message) else { return }
                    let (block, ids) = change
                    for id in ids { self.invalidateSimpleSegment(.assistantBlock(message.id, block.id, id), ownedBy: block) }
                }
        }

        private static func textEdges(_ block: AssistantBlock) -> Edge {
            let isText: AnyPublisher<Bool, Never> = block.$kind.map { $0 == .text }.removeDuplicates().eraseToAnyPublisher()
            let sources: AnyPublisher<Edge, Never> = isText.map { isText -> Edge in
                guard isText else { return Empty<Void, Never>().eraseToAnyPublisher() }
                return Self.contentEdges(block)
            }.eraseToAnyPublisher()
            return sources.switchToLatest().eraseToAnyPublisher()
        }

        private static func normalizedStatus(_ status: ToolBlockStatus?) -> ToolBlockStatus? {
            if case .streaming(_)? = status { return .streaming(bytes: 0) }
            return status
        }

        private static func blockEdges(_ block: AssistantBlock) -> [Edge] {
            let text: Edge = Self.textEdges(block)
            let kind: Edge = block.$kind.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
            let question: Edge = block.$questionCard.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
            let status: Edge = block.$toolStatus.map { Self.normalizedStatus($0) }
                .removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
            return [text, kind, question, status]
        }

        private static func edgesForBlocks(_ blocks: [AssistantBlock]) -> Edge {
            let edges: [Edge] = blocks.flatMap { Self.blockEdges($0) }
            return Publishers.MergeMany(edges).prepend(()).eraseToAnyPublisher()
        }

        private static func messageBlockEdges(_ message: ChatMessage) -> Edge {
            let sources: AnyPublisher<Edge, Never> = message.$blocks
                .removeDuplicates { $0.elementsEqual($1, by: { $0 === $1 }) }
                .map { blocks -> Edge in Self.edgesForBlocks(blocks) }
                .eraseToAnyPublisher()
            return sources.switchToLatest().dropFirst().eraseToAnyPublisher()
        }

        func stopSimpleProjection() {
            simpleMessageSubs.removeAll()
            simpleContentSubs.removeAll()
        }

        private func observeSimpleProjection(_ messages: [ChatMessage], vm: AIChatViewModel) {
            guard transcriptMode == .simple else { return }
            let assistants = messages.filter { $0.role == .assistant }
            let live = Set(assistants.map(\.id))
            simpleMessageSubs = simpleMessageSubs.filter { live.contains($0.key) }
            simpleContentSubs = simpleContentSubs.filter { live.contains($0.key) }
            for message in assistants where simpleMessageSubs[message.id]?.0 != ObjectIdentifier(message) {
                let blocks: Edge = Self.messageBlockEdges(message)
                let errors: Edge = message.$error.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
                let sub = Publishers.Merge(blocks, errors)
                    .receive(on: DispatchQueue.main).sink { [weak self, weak vm, weak message] _ in
                        guard let self, let vm, self.vm === vm, let message,
                              self.simpleMessageSubs[message.id]?.0 == ObjectIdentifier(message) else { return }
                        self.markSimpleProjectionDirty()
                        self.markFooterDirty(message.id)
                    }
                simpleMessageSubs[message.id] = (ObjectIdentifier(message), sub)
                simpleContentSubs[message.id] = observeSimpleContent(message)
            }
        }

        private func markSimpleProjectionDirty() {
            guard transcriptMode == .simple else { return }
            simpleProjectionDirty = true
            scheduleTranscriptUpdate()
        }

        private func transcriptContentKey(for item: MessageListItem, messages: [ChatMessage], width: CGFloat) -> String {
            let key = Self.contentKey(for: item, messages: messages, messageIndex: messageIndex)
            guard transcriptMode == .simple else { return key }
            let contentWidth = min(max(0, width - 32), maxContentWidth > 0 ? maxContentWidth : width)
            let role = simpleRows[item]
            let width = role == .text ? max(0, contentWidth - 24) : contentWidth
            return "\(key):simple:\(width):\(String(describing: role))"
        }

        private func sameMessageTranscriptRow(for removed: MessageListItem, in items: [MessageListItem],
                                              messages: [ChatMessage]) -> MessageListItem? {
            let sameTurn = items.filter { $0.messageId == removed.messageId }
            if sameTurn.contains(removed) { return removed }
            if case .assistantBlock(_, let blockID, _) = removed {
                if let sameBlock = sameTurn.first(where: {
                    if case .assistantBlock(_, let id, _) = $0 { return id == blockID }
                    return false
                }) { return sameBlock }
                let blocks = messages.first(where: { $0.id == removed.messageId })?.blocks ?? []
                let order = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($0.element.id, $0.offset) })
                if let old = order[blockID] {
                    let ranked = sameTurn.compactMap { item -> (MessageListItem, Int)? in
                        guard case .assistantBlock(_, let id, _) = item, let index = order[id] else { return nil }
                        return (item, abs(index - old))
                    }
                    if let nearest = ranked.min(by: { $0.1 < $1.1 }) { return nearest.0 }
                }
            }
            return sameTurn.first
        }

        private func transcriptFallback(for removed: MessageListItem, in items: [MessageListItem],
                                        messages: [ChatMessage]) -> MessageListItem? {
            if let sameTurn = sameMessageTranscriptRow(for: removed, in: items, messages: messages) { return sameTurn }
            if let current = messages.firstIndex(where: { $0.id == removed.messageId }) {
                for message in messages[..<current].reversed() where message.role == .user {
                    let item = MessageListItem.wholeMessage(message.id)
                    if items.contains(item) { return item }
                }
                let prior = Set(messages[..<current].map(\.id))
                if let item = items.last(where: { prior.contains($0.messageId) }) { return item }
            }
            return items.first
        }

        private func transcriptAnchor(_ before: PositionAnchor?, items: [MessageListItem],
                                      messages: [ChatMessage], in cv: UICollectionView) -> PositionAnchor? {
            guard let before, let window = cv.window, scrollMode == .userBrowsing else { return before }
            let membership = Set(items)
            if let original = before.readingItem,
               let sameTurn = sameMessageTranscriptRow(for: original, in: items, messages: messages) {
                if sameTurn == original { return before }
                return PositionAnchor(readingItem: sameTurn, readingY: before.readingY, tailItem: before.tailItem,
                                      tailGap: before.tailGap, wasNearBottom: false)
            }
            let origin = cv.convert(cv.bounds, to: window).minY
            let top = cv.contentOffset.y + cv.adjustedContentInset.top
            for path in cv.indexPathsForVisibleItems.sorted() {
                guard let item = dataSource.itemIdentifier(for: path), membership.contains(item),
                      let frame = itemFrame(item, in: cv), frame.maxY > top else { continue }
                return PositionAnchor(readingItem: item, readingY: origin + frame.minY - cv.contentOffset.y,
                                      tailItem: before.tailItem, tailGap: before.tailGap, wasNearBottom: false)
            }
            let fallback = before.readingItem.flatMap { transcriptFallback(for: $0, in: items, messages: messages) }
            return PositionAnchor(readingItem: fallback, readingY: origin + cv.adjustedContentInset.top,
                                  tailItem: before.tailItem, tailGap: before.tailGap, wasNearBottom: false)
        }

        // MARK: - Live Assistant Footers

        private weak var footerTail: ChatMessage?
        private var footerTailSub: AnyCancellable?
        private var pendingFooterIDs: Set<UUID> = []
        private var footerReconciliationScheduled = false
        private var appliedFooters: [UUID: AssistantFooterPresentation] = [:]

        private func canResumeFooter(vm: AIChatViewModel, isLast: Bool) -> Bool {
            guard isLast, vm.canResume, !vm.isProcessing else { return false }
            return vm.sessionId.map { !SessionActivityTracker.shared.isActive($0) } ?? true
        }

        private func footerPresentation(for message: ChatMessage, vm: AIChatViewModel,
                                        lastMessageID: UUID?) -> AssistantFooterPresentation {
            let isLast = message.id == lastMessageID
            return AssistantFooterPresentation(message, isActive: isLast && vm.isProcessing,
                                               canResume: canResumeFooter(vm: vm, isLast: isLast),
                                               showsUsage: cellBridges[message.id]?.showUsage == true,
                                               mode: transcriptMode)
        }

        private func syncFooterBridge(_ bridge: CellStateBridgeV2, message: ChatMessage,
                                      vm: AIChatViewModel, lastMessageID: UUID?) {
            let isLast = message.id == lastMessageID
            if bridge.isActiveMessage != (isLast && vm.isProcessing)
                || bridge.canResume != canResumeFooter(vm: vm, isLast: isLast) {
                updateBridge(bridge, message: message, lastMessageID: lastMessageID)
            }
            if transcriptMode == .simple {
                let footer = footerPresentation(for: message, vm: vm, lastMessageID: lastMessageID)
                if bridge.simpleFooter != footer { bridge.simpleFooter = footer }
            }
        }

        private func bindFooterTail(_ vm: AIChatViewModel) {
            let last = vm.messages.last(where: { !$0.isInternalBridge })
            let tail = last?.role == .assistant ? last : nil
            guard footerTail !== tail else { return }
            if let previous = footerTail { markFooterDirty(previous.id) }
            footerTailSub = nil
            footerTail = tail
            guard let tail else { return }

            let contentEdges = tail.$blocks
                .removeDuplicates { $0.elementsEqual($1, by: { $0 === $1 }) }
                .map { blocks -> AnyPublisher<Void, Never> in
                    let edges = blocks.map { block in
                        block.$kind.map { $0 == .text }.removeDuplicates()
                            .map { isText -> AnyPublisher<Void, Never> in
                                guard isText else { return Just(()).eraseToAnyPublisher() }
                                return block.$content.map { FooterTextContent($0) }.removeDuplicates()
                                    .map { _ in () }.eraseToAnyPublisher()
                            }
                            .switchToLatest()
                            .dropFirst()
                            .eraseToAnyPublisher()
                    }
                    return Publishers.MergeMany(edges).prepend(()).eraseToAnyPublisher()
                }
                .switchToLatest()
                .eraseToAnyPublisher()
            footerTailSub = Publishers.MergeMany([
                contentEdges,
                tail.$isAwaitingModelResponse.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                tail.$isCompactedHistory.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                tail.$error.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                tail.$streamInterruptCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                tail.$usage.map { $0 != nil }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                tail.$taskDuration.map { $0 != nil }.removeDuplicates().dropFirst()
                    .filter { [weak self] _ in self?.transcriptMode == .simple }
                    .map { _ in () }.eraseToAnyPublisher()
            ])
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak vm, weak tail] _ in
                guard let self, let vm, self.vm === vm, let tail, self.footerTail === tail else { return }
                self.markFooterDirty(tail.id)
            }
            markFooterDirty(tail.id)
        }

        private func markFooterTailDirty(_ vm: AIChatViewModel) {
            bindFooterTail(vm)
            if let tail = footerTail { markFooterDirty(tail.id) }
        }

        private func markFooterDirty(_ messageID: UUID) {
            pendingFooterIDs.insert(messageID)
            scheduleFooterReconciliation()
        }

        private func canReconcileFooters(_ vm: AIChatViewModel) -> Bool {
            UIApplication.shared.applicationState == .active && !needsForegroundRefresh
                && !vm.isLoadingSession && !vm.transitionSuspended && !vm.streamingUIUpdatesSuspended
                && !keyboardInFlight && viewportGeometryCommitDepth == 0 && !isFlushing
                && viewController?.collectionView.window != nil
        }

        fileprivate func scheduleFooterReconciliation() {
            guard !pendingFooterIDs.isEmpty, !footerReconciliationScheduled,
                  let vm, canReconcileFooters(vm) else { return }
            footerReconciliationScheduled = true
            DispatchQueue.main.async { [weak self, weak vm] in
                guard let self, let vm, self.vm === vm else { return }
                self.footerReconciliationScheduled = false
                guard self.canReconcileFooters(vm) else { return }
                self.reconcileFooters(vm)
            }
        }

        private func reconcileFooters(_ vm: AIChatViewModel) {
            guard let ds = dataSource, let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout else { return }
            bindFooterTail(vm)
            let messageIDs = pendingFooterIDs
            pendingFooterIDs.removeAll()
            let lastMessageID = footerTail?.id
            let candidates = vm.messages.filter {
                messageIDs.contains($0.id) && $0.role == .assistant && !$0.isInternalBridge
            }
            var expected: [UUID: AssistantFooterPresentation] = [:]
            for message in candidates {
                if let bridge = cellBridges[message.id] {
                    syncFooterBridge(bridge, message: message, vm: vm, lastMessageID: lastMessageID)
                }
                expected[message.id] = footerPresentation(for: message, vm: vm, lastMessageID: lastMessageID)
            }

            if messageIDs.contains(where: { messageID in
                let exists = ds.indexPath(for: .assistantFooter(messageID)) != nil
                return exists != (expected[messageID]?.needsItem == true)
            }) {
                applySnapshot(messages: vm.messages, caller: "footer-membership")
            }

            var itemsToReconfigure: [MessageListItem] = []
            for (messageID, presentation) in expected where presentation.needsItem {
                let item = MessageListItem.assistantFooter(messageID)
                guard let indexPath = ds.indexPath(for: item), appliedFooters[messageID] != presentation else { continue }
                appliedFooters[messageID] = presentation
                layout.invalidateContentHeight(at: indexPath.item)
                layout.setFooterHug(!presentation.prominent, at: indexPath.item)
                layout.setEstimatedHeight(estimatedFooterHeight(presentation), at: indexPath.item)
                (cv.cellForItem(at: indexPath) as? SelfSizingCell)?.clearCachedHeight()
                itemsToReconfigure.append(item)
            }
            guard !itemsToReconfigure.isEmpty else { return }
            var snapshot = ds.snapshot()
            snapshot.reconfigureItems(itemsToReconfigure)
            ds.apply(snapshot, animatingDifferences: false)
            layout.invalidateLayout()
        }

        private func estimatedFooterHeight(_ footer: AssistantFooterPresentation) -> CGFloat {
            footer.prominent ? 48 : (footer.reservesActions ? 36 : 4)
        }

        // MARK: - Streaming Subscription

        private func subscribeToLastMessage(_ message: ChatMessage?) {
            guard let message, message.id != lastMessageId else { return }
            lastMessageId = message.id
            lastMessageSub?.cancel()
            lastMessageBlockCountSub?.cancel()

            guard vm?.isProcessing == true else { return }

            // Watch objectWillChange for content updates (text streaming)
            lastMessageSub = message.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak message] _ in
                    guard let self else { return }
                    guard self.vm?.isProcessing == true else {
                        // [DIAG-SUB-END] Streaming ended — this is the last
                        // objectWillChange notification. Cancel subs and do final flush.
                        // If flushStreamingLayout() is throttled here, the pending
                        // work item fires later but no more objectWillChange comes,
                        // so it's the very last chance to invalidate layout.
                        AppLogger(category: "StreamDiag").info("[StreamSub] END — isProcessing=false, cancelling subs, final flush. pendingLayout=\(self.pendingStreamingLayout != nil) tracking=\(self.viewController?.collectionView?.isTracking ?? false) decel=\(self.viewController?.collectionView?.isDecelerating ?? false)")
                        self.lastMessageSub?.cancel()
                        self.lastMessageSub = nil
                        self.lastMessageBlockCountSub?.cancel()
                        self.lastMessageBlockCountSub = nil
                        self.flushStreamingLayout()
                        // [T-ios-tooluibatch-stuck-pending-snapshot] Terminal
                        // rescue for a snapshot deferred during a streaming-UI
                        // suspend window. While `streamingUIUpdatesSuspended` was
                        // true, the blocks.count sub (bind4b) only set
                        // `hasPendingSnapshot = true` without rebuilding the
                        // diffable snapshot, so blocks added during the suspend
                        // (e.g. tools 63–80 of a long agent loop) had no cells.
                        // flushStreamingLayout() above tries to flush it, but if
                        // it is still throttled (its trailing work item) OR the
                        // suspend overlapped this terminal tick, the pending
                        // snapshot could be stranded forever once these subs are
                        // cancelled (no further objectWillChange will arrive).
                        // Force one direct flush here — this fires exactly once
                        // at stream end, so there is no per-tick / large-data
                        // cost, and applySnapshot rebuilds from the authoritative
                        // current `messages`, so no row mix-up. No-op unless a
                        // snapshot is actually pending. Gated on NOT-suspended:
                        // applying a snapshot during an active session-transition
                        // suspend is exactly what the suspend guards against, so
                        // if we're still suspended we leave `hasPendingSnapshot`
                        // set for the resume path / next $messages apply to clear.
                        AppLogger(category: "PendingSnap").info("[PendingSnap] STREAM-END terminal rescue check — hasPendingSnapshot=\(self.hasPendingSnapshot) suspended=\(self.vm?.streamingUIUpdatesSuspended == true)")
                        if self.hasPendingSnapshot, self.vm?.streamingUIUpdatesSuspended != true {
                            self.flushPendingSnapshotIfNeeded(caller: "stream-end")
                        } else if self.hasPendingSnapshot {
                            // Still suspended at stream-end: cannot safely apply here.
                            // Left for the resume path; flag it so the freeze is traceable.
                            // [T-ios-scroll-suspend-leak] This is the key symptom line:
                            // content is written to DB but the UI is waiting on a
                            // suspend that must be released (scroll settle / foreground
                            // return / the new openSession clear) before it flushes.
                            AppLogger(category: "PendingSnap").warning("[PendingSnap] ⚠️ STREAM-END left pending (still suspended) — content in DB, UI frozen until suspend-resume (or next openSession clears it)")
                        }
                        return
                    }
                    self.flushStreamingLayout()
                }

            // Watch blocks.count → rebuild snapshot when new blocks appear
            lastMessageBlockCountSub = message.$blocks
                .map(\.count)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .dropFirst()
                .sink { [weak self] count in
                    guard let self, let msgs = self.vm?.messages else { return }
                    if self.vm?.streamingUIUpdatesSuspended == true {
                        // [PendingSnap] Deferring snapshot rebuild while suspended;
                        // blocks added now (count) won't get cells until a flush.
                        AppLogger(category: "PendingSnap").info("[PendingSnap] DEFER blockCount=\(count) — suspended, set hasPendingSnapshot=true (was \(self.hasPendingSnapshot))")
                        self.hasPendingSnapshot = true
                        return
                    }
                    self.applySnapshot(messages: msgs, caller: "bind4b-blockCount")
                }
        }

        /// Flush any snapshot that was deferred while streaming UI updates were suspended.
        // fileprivate so updateUIViewController (struct, same file) can use it as
        // a backstop flush. [T-message-list-empty-on-foreground]
        fileprivate func flushPendingSnapshotIfNeeded(caller: String = "?") {
            guard hasPendingSnapshot,
                  let currentVM = vm, !currentVM.isLoadingSession,
                  !currentVM.streamingUIUpdatesSuspended else { return }
            hasPendingSnapshot = false
            let blocks = vm?.messages.last(where: { $0.role == .assistant })?.blocks.count ?? -1
            // [T-ios-scroll-suspend-leak] Include blockCount + isProcessing so a
            // FLUSH can be matched against the DEFER that queued it — a DEFER with
            // no corresponding FLUSH (see the [SessionLoad] stale-suspend clear) is
            // the leak signature.
            AppLogger(category: "PendingSnap").info("[PendingSnap] FLUSH caller=\(caller) blockCount=\(blocks) isProcessing=\(vm?.isProcessing == true) — applying deferred snapshot")
            if let msgs = vm?.messages { applySnapshot(messages: msgs, caller: "flushPending(\(caller))") }
        }

        private func flushStreamingLayout() {
            // Check if a deferred snapshot can now be applied (sheet dismissed).
            flushPendingSnapshotIfNeeded(caller: "flushStreamingLayout")

            guard let cv = viewController?.collectionView,
                  let layout = viewController?.messageListLayout else { return }

            // Adaptive throttle: 100ms when auto-scrolling (user watching),
            // 3s when user has scrolled away (reading earlier content).
            let interval: TimeInterval = scrollMode == .autoScrolling ? 0.1 : 3.0
            let now = Date()
            if now.timeIntervalSince(lastStreamingLayoutTime) < interval {
                // Schedule a trailing fire so the final update isn't lost.
                if pendingStreamingLayout == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.pendingStreamingLayout = nil
                        self?.doFlushStreamingLayout()
                    }
                    pendingStreamingLayout = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
                }
                return
            }
            pendingStreamingLayout?.cancel()
            pendingStreamingLayout = nil
            doFlushStreamingLayout()
        }

        /// Actually perform the streaming layout flush + scroll.
        private func doFlushStreamingLayout() {
            lastStreamingLayoutTime = Date()
            guard let layout = viewController?.messageListLayout else { return }
            // Always invalidate layout — even during scrolling. The layout's
            // invalidationContext already skips contentOffsetAdjustment when
            // isTracking/isDecelerating, so this won't cause scroll jitter.
            // Skipping invalidation entirely caused text blocks that transitioned
            // from empty to non-empty (via streaming bypass) to stay at ~0 height.
            let list = viewController?.collectionView as? NoAnimationCollectionView
            let usesLayoutTarget = list.map {
                layout.hasActiveStreaming && $0.canAnimateStreamingGrowth && positionIsAvailable(in: $0)
                    && canUseLayoutStreamingTarget(in: $0, reasons: positionReasons)
            } ?? false
            layout.invalidateLayout()
            if !usesLayoutTarget { enqueuePosition(.measurement) }
        }

        /// Coalesce rapid scroll signals into a single scroll action.
        /// Uses a short 80ms delay — just enough to batch multiple near-simultaneous
        /// signals without noticeable visual lag during streaming.
        private func scheduleCoalescedScroll() {
            guard let stamp = positionStamp(), scrollMode == .autoScrolling else { return }
            pendingScrollWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.positionStamp() == stamp, self.scrollMode == .autoScrolling,
                      let cv = self.viewController?.collectionView, self.positionIsAvailable(in: cv) else { return }
                self.enqueuePosition(.coalesced)
            }
            pendingScrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        // MARK: - Snapshot

        /// When a snapshot is deferred (e.g. streaming UI updates suspended),
        /// set to true so we know to re-apply later.
        private var hasPendingSnapshot: Bool = false

        private func applySnapshot(messages rawMessages: [ChatMessage], caller: String = "?",
                                   modeChanged: Bool = false, modeAnchor: PositionAnchor? = nil) {
            guard let vm, !vm.isLoadingSession else { return }
            let before = (viewController?.collectionView).flatMap { capturePosition(in: $0) }

            // [T-bridge-message-ui-leak] Single UI-collection sink for EVERY
            // path that pushes messages to the list (loadSession, live inject,
            // compact rebuild, snapshot reload, rebind…). Filter the internal
            // role-alternation bridge (#579) here so it can never surface as a
            // chat bubble regardless of which path produced it — replacing the
            // former reliance on a single filter inside loadSession, which other
            // rebuild paths bypassed (the leak seen 2026-07-24).
            let messages = rawMessages.contains(where: { $0.isInternalBridge })
                ? rawMessages.filter { !$0.isInternalBridge }
                : rawMessages

            // Subscribe to thinking block toggle notifications (once)
            if attachmentSizeChangedSub == nil {
                attachmentSizeChangedSub = NotificationCenter.default.publisher(for: .zeAttachmentSizeChanged)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        guard let source = notification.object as? String else { return }
                        self?.attachmentSizeChanged(source)
                    }
            }

            if thinkingToggleSub == nil {
                thinkingToggleSub = NotificationCenter.default.publisher(for: .thinkingBlockToggled)
                    .merge(with: NotificationCenter.default.publisher(for: .questionCardToggled))
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] notification in
                        let tlog = AppLogger(category: "BlockHeightChange")
                        guard let self else {
                            tlog.warning("[ThinkingCollapse] sink fired but self gone")
                            return
                        }
                        guard let blockId = notification.object as? UUID else {
                            tlog.warning("[ThinkingCollapse] notif object not UUID: \(String(describing: notification.object))")
                            return
                        }
                        if self.transcriptMode == .simple, notification.name == .questionCardToggled,
                           let tail = self.footerTail, tail.blocks.contains(where: { $0.id == blockId }) {
                            self.markFooterDirty(tail.id)
                        }
                        guard let cv = self.viewController?.collectionView,
                              let layout = cv.collectionViewLayout as? MessageListLayout,
                              let snapshot = self.dataSource?.snapshot() else {
                            tlog.warning("[ThinkingCollapse] block=\(blockId.uuidString.prefix(8)) infra missing: cv=\(self.viewController?.collectionView != nil) ds=\(self.dataSource != nil)")
                            return
                        }
                        // [T-thinking-collapse-blank] The layout-side
                        // `invalidateHeight` only wipes the MessageListLayout
                        // `heightCache`, not the per-cell `lastComputedHeight`
                        // on SelfSizingCell. Without also clearing the
                        // cell-side cache, the next
                        // `preferredLayoutAttributesFitting` short-circuits
                        // via the broad-width cache and returns the OLD
                        // expanded height (~300pt) for a cell whose SwiftUI
                        // body now renders just the 36pt header — producing
                        // a tall empty gap below the collapsed pill (user
                        // screenshot 2026-05-19). Clear both caches here
                        // and reconfigure so UIHostingConfiguration
                        // re-measures from scratch. Trace each step so a
                        // future report can be diagnosed from logs alone.
                        var matched = false
                        for (i, item) in snapshot.itemIdentifiers.enumerated() {
                            if case .assistantBlock(_, let bid, _) = item, bid == blockId {
                                matched = true
                                let beforeLayout = layout.cachedHeight(at: i)
                                let beforePrecalc = layout.precalcHeight(at: i)
                                let ip = IndexPath(item: i, section: 0)
                                let cellOpt = cv.cellForItem(at: ip) as? SelfSizingCell
                                let frameH = cellOpt?.frame.size.height ?? -1
                                if let cell = cellOpt {
                                    cell.clearCachedHeight()
                                }
                                layout.invalidateHeight(at: i)
                                var snap = snapshot
                                snap.reconfigureItems([item])
                                self.dataSource?.apply(snap, animatingDifferences: false)
                                layout.invalidateLayout()
                                tlog.info("[ThinkingCollapse] HIT block=\(blockId.uuidString.prefix(8)) idx=\(i) cellFound=\(cellOpt != nil) frameH=\(String(format: "%.1f", frameH)) beforeLayout=\(beforeLayout.map { String(format: "%.1f", $0) } ?? "nil") beforePrecalc=\(beforePrecalc.map { String(format: "%.1f", $0) } ?? "nil")")
                                // Defer one runloop tick to capture the
                                // post-reconfigure measurement and confirm
                                // the cell actually shrank/grew. If the
                                // delta is small the cache invalidation
                                // didn't take — that's the case to escalate.
                                DispatchQueue.main.async { [weak cv, weak layout] in
                                    let cv = cv
                                    let layout = layout
                                    let after = cv?.cellForItem(at: ip)?.frame.size.height ?? -1
                                    let afterLayout = layout?.cachedHeight(at: i)
                                    tlog.info("[ThinkingCollapse] POST block=\(blockId.uuidString.prefix(8)) idx=\(i) frameH=\(String(format: "%.1f", after)) layoutCache=\(afterLayout.map { String(format: "%.1f", $0) } ?? "nil") delta=\(String(format: "%.1f", after - frameH))")
                                }
                                break
                            }
                        }
                        if !matched {
                            tlog.warning("[ThinkingCollapse] MISS block=\(blockId.uuidString.prefix(8)) not in snapshot (items=\(snapshot.itemIdentifiers.count))")
                        }
                    }
            }

            // Rebuild O(1) lookup indices
            messageIndex.removeAll(keepingCapacity: true)
            for (i, msg) in messages.enumerated() {
                messageIndex[msg.id] = i
            }

            // Clean up bridges
            let currentIds = Set(messages.map(\.id))
            let removedIds = Set(cellBridges.keys).subtracting(currentIds)
            for id in removedIds {
                bridgeSheetSubs.removeValue(forKey: id)
                footerUsageSubs.removeValue(forKey: id)
                inlineSubAgentSubs.removeValue(forKey: id)
            }
            cellBridges = cellBridges.filter { currentIds.contains($0.key) }

            // Build items
            var newItems: [MessageListItem] = []
            var newFooters: [UUID: AssistantFooterPresentation] = [:]
            let priorRoles = simpleRows
            let priorObjects = simpleBlockObjects
            simpleRows.removeAll(keepingCapacity: true)
            simpleBlockObjects.removeAll(keepingCapacity: true)
            observeSimpleProjection(messages, vm: vm)
            let lastMessageID = messages.last?.id
            for message in messages {
                switch message.role {
                case .user:
                    newItems.append(.wholeMessage(message.id))
                case .compactDivider, .systemInfo:
                    if transcriptMode == .standard { newItems.append(.wholeMessage(message.id)) }
                case .assistant:
                    if transcriptMode == .simple {
                        for block in message.blocks {
                            guard let role = SimpleTranscript.row(for: block) else { continue }
                            let ids: [SimpleSegmentID?] = role == .question ? [nil] : block.simpleBody.rowIDs.map { $0 }
                            for id in ids {
                                let item = MessageListItem.assistantBlock(message.id, block.id, id)
                                newItems.append(item)
                                simpleRows[item] = id.map { $0.kind == .text ? .text : .standalone } ?? role
                                simpleBlockObjects[item] = ObjectIdentifier(block)
                            }
                        }
                        let footer = footerPresentation(for: message, vm: vm, lastMessageID: lastMessageID)
                        if footer.needsItem {
                            newItems.append(.assistantFooter(message.id))
                            newFooters[message.id] = footer
                        }
                        continue
                    }
                    newItems.append(.assistantHeader(message.id))
                    // [T-collapse-steps] Folded behind the appearance setting
                    // "连续折叠工具调用". While it is on, a finished turn keeps only
                    // its final reply; the old per-group disclosure row is gone,
                    // and live streaming still lists every step.
                    //
                    // The "still running" test is per-message (`taskDuration`
                    // is only set when the turn ends). Using the global
                    // `vm.isProcessing` here unfolded *every* earlier turn for
                    // as long as any turn was streaming.
                    let stepsCollapsed = collapseConsecutiveToolCalls
                        && message.isStepsCollapsed
                        && message.taskDuration != nil
                    if stepsCollapsed {
                        if let finalText = message.blocks.last(where: { $0.kind == .text }) {
                            newItems.append(.assistantBlock(message.id, finalText.id))
                        }
                    } else {
                        // No tool-group items: the disclosure row was the old
                        // fold and is replaced by the header glyph.
                        for segment in AssistantBlockPresentationSegment.make(
                            message.blocks,
                            enabled: false
                        ) {
                            newItems.append(contentsOf: segment.blocks.map { .assistantBlock(message.id, $0.id) })
                        }
                    }
                    let footer = footerPresentation(for: message, vm: vm, lastMessageID: lastMessageID)
                    if footer.needsItem {
                        newItems.append(.assistantFooter(message.id))
                        newFooters[message.id] = footer
                    }
                }
            }

            let oldMembership = Set(previousSnapshotIds)
            let reconfigured: [MessageListItem]
            if modeChanged { reconfigured = newItems.filter(oldMembership.contains) }
            else if transcriptMode == .simple {
                reconfigured = newItems.filter { item in
                    oldMembership.contains(item) && (priorRoles[item] != simpleRows[item] || priorObjects[item] != simpleBlockObjects[item])
                }
            } else { reconfigured = [] }
            let reconfiguredSet = Set(reconfigured)
            if modeChanged, let cv = viewController?.collectionView {
                positionAnchor = transcriptAnchor(modeAnchor, items: newItems, messages: messages, in: cv)
            }

            // Remap height cache + set accurate estimates for ALL item types
            if let layout = viewController?.messageListLayout {
                layout.updateCacheForSnapshot(oldIds: previousSnapshotIds, newIds: newItems)
                layout.simpleSegmentGaps = Set(newItems.indices.dropLast().filter { index in
                    newItems[index].segmentID != nil && newItems[index + 1].segmentID != nil
                        && newItems[index].messageId == newItems[index + 1].messageId
                })

                let cvWidth = viewController?.collectionView.bounds.width ?? 390
                for (i, item) in newItems.enumerated() {
                    // [T-ios-scroll-decel-height-drift] Register the stable
                    // content key for this index so a later self-size writes the
                    // real height back under the key, and seed precalc from any
                    // previously-measured real height. This kills the estimate→
                    // real "settle jitter" for .wholeMessage (user) cells, whose
                    // estimate is a coarse char-count heuristic (±13–52pt off),
                    // on every re-entry after the first measurement. NO new
                    // measurement happens here — we reuse the height UIKit
                    // already computed (see MessageListLayout.invalidationContext).
                    let contentKey = transcriptContentKey(for: item, messages: messages, width: cvWidth)
                    if reconfiguredSet.contains(item) { layout.invalidateContentHeight(at: i) }
                    layout.setContentKey(contentKey, at: i)

                    // [T-ios-footer-hug] Content-aware spacing policy — must run
                    // BEFORE the cachedHeight guard below, or footers that
                    // already measured would skip it and fall back to the
                    // default hug, re-gluing a prominent banner on the next
                    // prepare(). Hug ONLY when the footer shows the quiet
                    // meta/usage row (or nothing); error banner / resume banner
                    // / typing indicator keep the full itemSpacing (user report
                    // 2026-07-21). Mirrors BridgedAssistantFooterV3's sections.
                    if case .assistantFooter(let footerID) = item, let footer = newFooters[footerID] {
                        let applied = appliedFooters[footerID]
                        layout.setFooterHug(!(applied ?? footer).prominent, at: i)
                        if applied == nil {
                            layout.invalidateContentHeight(at: i)
                        } else if layout.cachedHeight(at: i) == nil,
                                  let memo = layout.measuredHeight(forKey: contentKey, width: cvWidth) {
                            layout.setPrecalcHeight(memo, at: i)
                        }
                        layout.setEstimatedHeight(estimatedFooterHeight(applied ?? footer), at: i)
                        continue
                    }

                    guard layout.cachedHeight(at: i) == nil else { continue }
                    if let role = simpleRows[item] {
                        let estimate = Self.estimateItemHeight(item, messages: messages, width: cvWidth,
                                                              maxContentWidth: maxContentWidth, simpleRow: role)
                        layout.setEstimatedHeight(estimate, at: i)
                        continue
                    }

                    // Re-entry seed: if we have a real measured height for this
                    // exact content key at this width, use it as precalc — the
                    // cell lands at its true height with zero on-screen jump.
                    if let memo = layout.measuredHeight(forKey: contentKey, width: cvWidth) {
                        layout.setPrecalcHeight(memo, at: i)
                        continue
                    }

                    switch item {
                    case .assistantToolGroup:
                        layout.setEstimatedHeight(48, at: i)

                    case .assistantHeader:
                        // Header is always a fixed "sparkles Ze" label row (measured: 28pt)
                        layout.setEstimatedHeight(28, at: i)

                    case .assistantFooter:
                        break

                    case .assistantBlock(let msgId, let blockId, _):
                        guard let msgIdx = messageIndex[msgId], msgIdx < messages.count else { continue }
                        let msg = messages[msgIdx]
                        guard let block = msg.blocks.first(where: { $0.id == blockId }) else { continue }

                        switch block.kind {
                        case .text:
                            // Use TextKit layout for accurate height pre-calculation.
                            // Results are cached by NSAttributedString identity to avoid
                            // redundant TextKit layout on repeated snapshots.
                            if let attrStr = block.cachedAttributedString {
                                let textWidth = max(cvWidth - 32, 100)
                                let key = ObjectIdentifier(attrStr)
                                let height: CGFloat
                                if let cached = attrStringHeightCache[key] {
                                    height = cached
                                } else {
                                    height = Self.measureAttributedStringHeight(attrStr, width: textWidth)
                                    attrStringHeightCache[key] = height
                                }
                                // height includes the text view's 8pt insets;
                                // +4 = the SwiftUI wrapper's .padding(.vertical, 2)
                                // that the historical "+8" never accounted for
                                // (the constant +5 first-measure growth in the
                                // debug.scrollMetrics traces = this 4pt + ceil).
                                layout.setPrecalcHeight(height + 4, at: i)
                                #if DEBUG
                                // [T-ios-scroll-metrics-ring] Record content
                                // features at the seed site (the only place the
                                // block object and its precalc height coexist) so
                                // the pulled trace can attribute ct-precalc
                                // mismatches to specific markdown constructs.
                                if ScrollMetricsRecorder.shared.isEnabled {
                                    let c = block.content
                                    let feats = "code=\(c.contains("```") ? 1 : 0)|tbl=\(c.contains("|") ? 1 : 0)|list=\(c.range(of: #"(?m)^\s*[-*+] "#, options: .regularExpression) != nil ? 1 : 0)|head=\(c.range(of: #"(?m)^#{1,6} "#, options: .regularExpression) != nil ? 1 : 0)|icode=\(c.contains("`") ? 1 : 0)|bold=\(c.contains("**") ? 1 : 0)|nl=\(c.filter { $0 == "\n" }.count)|n=\(c.count)"
                                    ScrollMetricsRecorder.shared.record(
                                        kind: "seed", idx: i, a: height + 4,
                                        key: contentKey, src: "tv", note: feats,
                                        tag: Self.stableCellTag(for: item, messages: messages, messageIndex: messageIndex))
                                }
                                #endif
                            } else if block.content.isEmpty {
                                // [T-ios-empty-textblock-gap] A content-less text
                                // block renders EmptyView (AssistantBlockView gates
                                // on !content.isEmpty), so it must occupy 0pt — the
                                // heuristic's one-line floor made it a phantom
                                // blank row above the next tool capsule while
                                // streaming defers the corrective measure. When
                                // content arrives, blockContentFilledSignal
                                // invalidates the height and reconfigures the cell.
                                layout.setEstimatedHeight(0, at: i)
                            } else {
                                // Streaming text — no cachedAttributedString yet,
                                // so use the char-count heuristic.
                                //
                                // [T-ios-stream-bubble-spacing] The measured path
                                // above adds +8 (the bubble's .padding(.vertical, 2)
                                // plus the TextKit↔SwiftUI line-height delta). The
                                // heuristic's estimateTextBlockHeight only seeds
                                // `total = 4`, so a streaming text cell came out
                                // ~4pt short on its vertical padding — the bubble
                                // looked cramped/edge-to-edge until a later layout
                                // pass ran the real systemLayoutSizeFitting measure
                                // (which includes the padding) and "snapped" the
                                // spacing back. Add the same +4 here so the first
                                // streamed frame already reserves that padding.
                                // The +4 padding compensation now lives inside
                                // estimateTextBlockHeight, so all estimate paths
                                // agree — no per-call-site fudge here.
                                let est = Self.estimateItemHeight(item, messages: messages, width: cvWidth, maxContentWidth: maxContentWidth)
                                layout.setEstimatedHeight(est, at: i)
                            }
                        case .thinking:
                            // Estimator returns 36pt collapsed (matches header-only rendering),
                            // or header + capped content height when expanded. Hard-coded 88
                            // caused a -48pt correction per cell on first render, producing a
                            // contentSize-shrink jitter chain when scrolling through history.
                            let est = Self.estimateItemHeight(item, messages: messages, width: cvWidth, maxContentWidth: maxContentWidth)
                            layout.setEstimatedHeight(est, at: i)
                        case .readImageTool:
                            // In V3 block cells, readImageTool renders as a
                            // ToolCapsuleView (36pt), same as other tool types.
                            layout.setEstimatedHeight(36, at: i)
                        case .info:
                            let infoLines = max(1, block.content.components(separatedBy: "\n").count)
                            layout.setEstimatedHeight(CGFloat(20 + infoLines * 16), at: i)
                        default:
                            // Tool capsules (execute, browser, etc.) are 36pt
                            layout.setEstimatedHeight(36, at: i)
                        }

                    case .wholeMessage(let msgId):
                        // [T-ios-user-msg-estimate-tail-jitter] Accurate TextKit
                        // precalc for USER message bubbles. The "stops then
                        // twitches" decel-tail jank traced to user (wholeMessage)
                        // cells whose coarse
                        // char-count estimate was ~10pt short (idx150: est 77 →
                        // real 87): when such a cell scrolled into view during the
                        // decel tail it re-measured taller, grew contentSize, and
                        // misaligned UIKit's already-computed decel target → 30fps
                        // micro-correction near the stop + a POST-SETTLE offset
                        // jump. The user bubble is a plain SwiftUI Text (no
                        // cachedAttributedString), so it never got the accurate
                        // precalc the .text blocks do. Measure it with the SAME
                        // font + wrap width + paddings as the real render so the
                        // cell lands at its true height and contentSize stays
                        // stable through the glide. Falls back to the coarse
                        // estimator for compactDivider / systemInfo / empty.
                        if let msg = messages.first(where: { $0.id == msgId }),
                           msg.role == .user {
                            // Real wrap is bounded by maxContentWidth (the
                            // .frame(maxWidth:) on BridgedWholeMessageV3); using
                            // the wider cvWidth would under-wrap → under-estimate
                            // on iPad. Use the effective width.
                            let effWidth = maxContentWidth > 0 ? min(cvWidth, maxContentWidth) : cvWidth
                            let h = Self.measureUserBubbleHeight(for: msg, cvWidth: effWidth,
                                                                 cache: &userBubbleHeightCache)
                            if let h {
                                layout.setPrecalcHeight(h, at: i)
                                #if DEBUG
                                // [T-ios-scroll-metrics-ring] Feature capture for
                                // the +7 user-bubble subset attribution.
                                if ScrollMetricsRecorder.shared.isEnabled {
                                    let c = msg.content
                                    let cjk = c.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
                                    let feats = "cjk=\(cjk ? 1 : 0)|nl=\(c.filter { $0 == "\n" }.count)|n=\(c.count)|att=\(msg.attachments.count)|inAtt=\(msg.inputAttachments.count)|tag=\(c.contains("<user-attached-files>") ? 1 : 0)"
                                    ScrollMetricsRecorder.shared.record(
                                        kind: "seed", idx: i, a: h,
                                        key: Self.contentKey(for: item, messages: messages, messageIndex: messageIndex),
                                        src: "bubble", note: feats,
                                        tag: Self.stableCellTag(for: item, messages: messages, messageIndex: messageIndex))
                                }
                                #endif
                            } else {
                                // empty text (attachment-only) — coarse estimate
                                layout.setEstimatedHeight(
                                    Self.estimateItemHeight(item, messages: messages, width: cvWidth, maxContentWidth: maxContentWidth), at: i)
                            }
                        } else {
                            // compactDivider / systemInfo — coarse estimate is fine
                            let est = Self.estimateItemHeight(item, messages: messages, width: cvWidth, maxContentWidth: maxContentWidth)
                            layout.setEstimatedHeight(est, at: i)
                        }
                    }
                }
            }

            // Rebuild item→index lookup
            itemToIndex.removeAll(keepingCapacity: true)
            for (i, item) in newItems.enumerated() {
                itemToIndex[item] = i
            }

            // Track streaming cell ranges so layout doesn't adjust offset for
            // them. [T-stream-hover-earlier-streaming] Not just the LAST
            // assistant message: with queued-turn interrupts an EARLIER
            // assistant message can still be receiving content (running /
            // streaming tool blocks) while the newest turn streams text. Every
            // such message's item span must be excluded from the visible-cell
            // offset adjustment, or browse-mode hovering over it gets dragged
            // down by each flush's growth delta.
            if vm.isProcessing {
                var streamingIds: [UUID] = []
                if let lastMsg = messages.last, lastMsg.role == .assistant {
                    streamingIds.append(lastMsg.id)
                }
                for msg in messages where msg.role == .assistant && msg.id != messages.last?.id {
                    let hasLiveTool = msg.blocks.contains { blk in
                        switch blk.toolStatus {
                        case .running, .streaming: return true
                        default: return false
                        }
                    }
                    if hasLiveTool { streamingIds.append(msg.id) }
                }
                var ranges: [Range<Int>] = []
                for id in streamingIds {
                    guard let start = (transcriptMode == .simple ? newItems.firstIndex(where: { $0.messageId == id })
                                       : newItems.firstIndex(of: .assistantHeader(id))) else { continue }
                    var end = start + 1
                    while end < newItems.count, Self.item(newItems[end], belongsTo: id) {
                        end += 1
                    }
                    ranges.append(start..<end)
                }
                ranges.sort { $0.lowerBound < $1.lowerBound }
                viewController?.messageListLayout?.streamingCellRanges = ranges
            } else {
                viewController?.messageListLayout?.streamingCellRanges = []
            }
            // Keep the layout's pin flag in sync here too — the scrollMode
            // didSet may have fired before the layout existed (initial value).
            // [T-ios-stream-natural-transitions]
            viewController?.messageListLayout?.isAutoScrollPinning = (scrollMode == .autoScrolling)
            let oldCount = previousSnapshotIds.count
            // Lock the messages array the snapshot (and messageIndex, rebuilt
            // above) was built from. configureCell / prefetch MUST read this
            // same array: reading vm.messages there instead can race a
            // concurrent loadSession() that replaced the array with freshly
            // created ChatMessage/AssistantBlock objects (new UUIDs) — the
            // snapshot's block IDs then match nothing and the cell configures
            // EMPTY (silent `guard ... else return`). Updated BEFORE the
            // skip-return below so it stays in lockstep with messageIndex.
            // [T-ios-blocks-lost-render]
            snapshotMessages = messages
            switch sendPosition {
            case .reveal(let item)?, .waiting(let item)?:
                if !newItems.contains(item) { sendPosition = nil }
            default: break
            }
            // Skip diffable-data-source apply when items haven't changed —
            // avoids expensive UIKit cell creation/layout on redundant snapshots.
            if newItems == previousSnapshotIds && reconfigured.isEmpty && !modeChanged {
                AppLogger(category: "SnapshotDiag").info("[SnapshotDiag] SKIP caller=\(caller) items unchanged (count=\(newItems.count)) — no re-apply")
                return
            }
            let oldSet = Set(previousSnapshotIds)
            let inserted = newItems.filter { !oldSet.contains($0) }
            appliedFooters = newFooters.merging(appliedFooters) { _, applied in applied }
                .filter { newFooters[$0.key] != nil }
            if modeChanged {
                if newItems.count < oldCount { positionReasons.insert(.snapshotShrink) }
                positionReasons.insert(.transcriptMode)
            } else {
                enqueuePosition(newItems.count < oldCount ? .snapshotShrink : .snapshot, anchor: before)
            }
            if case .inserting(let acceptedID?, _)? = sendPosition,
               inserted.contains(.wholeMessage(acceptedID)) {
                sendPosition = .reveal(.wholeMessage(acceptedID))
            }
            previousSnapshotIds = newItems

            let snapLog = AppLogger(category: "SnapshotDiag")
            let blockItems = newItems.filter { if case .assistantBlock = $0 { return true }; return false }
            if let lastAssistant = messages.last(where: { $0.role == .assistant }) {
                snapLog.info("[SnapshotDiag] caller=\(caller) totalItems=\(newItems.count) blockItems=\(blockItems.count) lastAssistantBlocks=\(lastAssistant.blocks.count) msgCount=\(messages.count)")
                for (i, block) in lastAssistant.blocks.enumerated() {
                    let contentLen = block.content.count
                    let tail = String(block.content.suffix(20))
                    snapLog.info("[SnapshotDiag]   block[\(i)] kind=\(block.kind) id=\(block.id.uuidString.prefix(8)) contentLen=\(contentLen) tail=\"\(tail)\"")
                }
            }

            var snapshot = NSDiffableDataSourceSnapshot<Section, MessageListItem>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newItems, toSection: .main)
            if !reconfigured.isEmpty { snapshot.reconfigureItems(reconfigured) }
            // Suppress contentOffsetAdjustment during snapshot application so that
            // rapid cell self-sizing doesn't cause visible content jumps. After layout
            // settles, pin to bottom if autoScrolling.
            let snapshotLayout = viewController?.messageListLayout
            snapshotLayout?.suppressContentOffsetAdjustment = true
            isFlushing = true
            cellConfigCount = 0
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            UIView.performWithoutAnimation { dataSource.apply(snapshot, animatingDifferences: false) }
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
            // [ToolLifecycle] Stage 5: log newly-inserted tool blocks now in the
            // applied snapshot. Only fires for inserts, so volume stays proportional
            // to actual new tool blocks appearing in the chat UI.
            if !inserted.isEmpty {
                let sid = vm.sessionId?.prefix(8) ?? "nil"
                let appState = UIApplication.shared.applicationState == .active ? "fg" : "bg"
                let suspended = vm.streamingUIUpdatesSuspended
                let processing = vm.isProcessing
                for item in inserted {
                    if case .assistantBlock(let msgId, let blockId, _) = item,
                       let msgIdx = messageIndex[msgId],
                       msgIdx < messages.count,
                       let block = messages[msgIdx].blocks.first(where: { $0.id == blockId }),
                       block.toolUseId != nil {
                        let toolName: String = switch block.kind {
                        case .shellTool: "shell_execute"
                        case .fileReadTool: "file_read"
                        case .fileWriteTool: "file_write"
                        case .fileEditTool: "file_edit"
                        case .browserTool: "browser_use"
                        case .readImageTool: "read_image"
                        case .memoryTool: "memory"
                        default: "unknown"
                        }
                        AppLogger(category: "ToolLC").info("[ToolLifecycle] RENDERED_CHATUI toolId=\(block.toolUseId?.prefix(20) ?? "nil") tool=\(toolName) sid=\(sid) appState=\(appState) suspended=\(suspended) isProcessing=\(processing) caller=\(caller)")
                    }
                }
            }
            // Re-mark layout dirty: isApplyingSnapshot suppressed the layoutSubviews()
            // that dataSource.apply() triggered internally, so UIKit thinks layout is
            // already done. Without this, layoutIfNeeded() below is a no-op and cells
            // won't be created until the next touch/scroll.
            viewController?.collectionView.setNeedsLayout()

            if let cv = viewController?.collectionView {
                // Clear stale height cache for newly inserted items. During
                // dataSource.apply(), UIKit may trigger preferredLayoutAttributesFitting
                // on OLD cells still occupying the indices where new items will go,
                // writing the old cell's height into heightCache at the new item's index.
                // This causes the new cell to inherit the old cell's height (e.g. a 28pt
                // footer height applied to a new text block), leading to overlap.
                if !inserted.isEmpty, let layout = snapshotLayout {
                    for item in inserted {
                        if let idx = newItems.firstIndex(of: item) {
                            layout.invalidateHeight(at: idx)
                        }
                    }
                }

                snapshotLayout?.suppressContentOffsetAdjustment = false
                isFlushing = false
                cv.setNeedsLayout()
                if viewportGeometryCommitDepth == 0 { cv.layoutIfNeeded() }
                // Sync isNearBottom after snapshot apply. applySnapshot runs
                // under isFlushing=true, which suppresses the contentSize KVO
                // observer — so the KVO-side sync we added doesn't run here.
                // Without this, contentSize can grow past the visible area
                // (sub-viewport overflow) without anyone updating vm.isNearBottom,
                // leaving the scroll-to-bottom button hidden when it should appear.
                if let vm = self.vm {
                    let nb = isNearBottom()
                    if vm.isNearBottom != nb {
                        vm.isNearBottom = nb
                    }
                }
                syncScrollFlags()
            } else {
                snapshotLayout?.suppressContentOffsetAdjustment = false
                isFlushing = false
            }
        }

        private func reconfigureAllCells() {
            viewController?.messageListLayout?.clearHeightCache()
            attrStringHeightCache.removeAll()
            userBubbleHeightCache.removeAll()
            reconfigureVisibleCells()
        }

        /// Reconfigure all cells without clearing the height cache.
        /// Used after compact to update opacity without losing measured heights.
        private func reconfigureVisibleCells() {
            var snapshot = dataSource.snapshot()
            let items = snapshot.itemIdentifiers
            guard !items.isEmpty else { return }
            snapshot.reconfigureItems(items)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = true
            dataSource.apply(snapshot, animatingDifferences: false)
            (viewController?.collectionView as? NoAnimationCollectionView)?.isApplyingSnapshot = false
        }

        // MARK: - Accurate Height Measurement

        /// Measure the rendered height of an NSAttributedString using TextKit's
        /// full layout engine (NSLayoutManager + NSTextContainer). This correctly
        /// handles NSTextAttachment subclasses (tables, code blocks, images) by
        /// calling attachmentBounds() during layout, unlike boundingRect() which
        /// uses the attachment's 1×1px placeholder image.
        /// [T-ios-decel-inv-estimate-calibration] Measure with the REAL render
        /// engine: an offscreen SelectableMarkdownTextView (ZeLayoutManager +
        /// 4/4 textContainerInset), exactly what the live cell hosts. The
        /// previous bare-NSLayoutManager measure drifted +4..+21pt on ~30% of
        /// blocks (multi-paragraph / emoji-heading content) — debug.measureCompare
        /// ground truth showed the drift is engine-internal (usesFontLeading was
        /// ruled out: identical results), so no formula over the bare engine can
        /// close it. Measuring with the same engine is exact BY CONSTRUCTION.
        /// Cost: avg 1.4ms/block (vs 0.67ms bare), cached per attributed string
        /// in attrStringHeightCache, main-thread only (seed loop already is).
        ///
        /// RETURNS the full text-view height INCLUDING its 8pt vertical insets
        /// (4 top + 4 bottom) — callers add only the SwiftUI wrapper's
        /// .padding(.vertical, 2) (+4), NOT the historical +8.
        static func measureAttributedStringHeight(_ attrStr: NSAttributedString, width: CGFloat) -> CGFloat {
            // Watchdog guard: UITextView.sizeThatFits is near-O(n²) in line
            // count (the 29k-char / 8-10s SLOW MEASURE history,
            // T-ios-longreply-boundingRect-watchdog). Above the cap, fall back
            // to the linear bare-NSLayoutManager measure and accept its small
            // drift — on a 10000pt+ cell a ±20pt error is invisible.
            guard attrStr.length <= 8000 else {
                let storage = NSTextStorage(attributedString: attrStr)
                let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                let lm = NSLayoutManager()
                lm.addTextContainer(container)
                storage.addLayoutManager(lm)
                lm.ensureLayout(for: container)
                // +8 = the text view insets the tv path includes natively.
                return ceil(lm.usedRect(for: container).height) + 8
            }
            measureTextView.attributedText = attrStr
            let size = measureTextView.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude))
            return ceil(size.height)
        }

        /// Shared offscreen measurement text view (main-thread only).
        private static let measureTextView = SelectableMarkdownTextView()

        /// [T-ios-user-msg-estimate-tail-jitter] Accurate height for a USER
        /// message cell, measured with the SAME font / wrap width / paddings as
        /// `ChatMessageRow.userRow` renders, so the precalc lands the cell at its
        /// true height (the coarse char-count estimator was ~10pt short, which
        /// grew contentSize mid-decel and caused the stop-then-twitch tail jank).
        /// Returns nil for attachment-only / empty text (caller falls back to the
        /// coarse estimate). Cached by content|width|fontsize.
        ///
        /// Layout constants mirror AIChatView.userRow:
        ///   - font: .system(size: scaledMessage(16.5))
        ///   - bubble: .padding(.horizontal,14) .padding(.vertical,10)  → +20 height, -28 width
        ///   - row:   HStack { Spacer(minLength: 60); VStack(spacing:6){ attachments?; bubble } }
        ///   - cell:  .padding(.horizontal, 16) on the whole row
        /// No on-screen view is touched; pure TextKit measurement (usedRect).
        static func measureUserBubbleHeight(for message: ChatMessage, cvWidth: CGFloat,
                                            cache: inout [String: CGFloat]) -> CGFloat? {
            // userDisplayText: strip the <user-attached-files> block, trim.
            var text = message.content
            if let start = text.range(of: "<user-attached-files>") {
                let end = text.range(of: "</user-attached-files>")
                let endBound = end?.upperBound ?? text.endIndex
                text = String(text[text.startIndex..<start.lowerBound] + text[endBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let attachCount = message.attachments.isEmpty
                ? message.inputAttachments.count : message.attachments.count

            // Attachment tiles (70pt rows) sit above the bubble with 6pt spacing.
            // Reuses the same formula as estimateItemHeight(.user).
            let fontSize = FontSettings.shared.scaledMessage(16.5)
            let usableTextWidth = max(cvWidth - 32 /*cell*/ - 60 /*Spacer*/ - 28 /*bubble pad*/, 80)

            var attachH: CGFloat = 0
            if attachCount > 0 {
                let tilesPerRow = max(1, Int((cvWidth - 32 - 60) / 70))
                let rows = ceil(CGFloat(attachCount) / CGFloat(tilesPerRow))
                attachH = rows * 70 + 6 /*VStack spacing*/
            }

            // Queued prompts render as the compact inline insertion indicator
            // in ChatMessageRow, never as a wrapped user bubble. Keeping this
            // estimate in sync prevents a queued append from briefly allocating
            // the old multi-line bubble height and shifting the message list.
            if message.isQueued {
                return attachH + 24
            }

            guard !text.isEmpty else {
                // Attachment-only message: return tiles height if any, else nil
                // so the caller uses the coarse estimate (covers oddball cases).
                return attachCount > 0 ? attachH : nil
            }

            let collapsible = UserMessageCollapsePolicy.shouldCollapse(text)
            let collapsed = collapsible && !message.isUserTextExpanded
            let quoteKey = message.quote.map { "\($0.targetMessageId):\($0.text.count)" } ?? "none"
            let key = "\(text.count)|\(Int(usableTextWidth))|\(Int(fontSize))|\(attachCount)|collapsed:\(collapsed)|quote:\(quoteKey)|\(text.hashValue)"
            if let cached = cache[key] { return cached }

            // [T-ios-user-msg-estimate-tail-jitter] Measure with UILabel, NOT raw
            // NSLayoutManager.usedRect. SwiftUI `Text` lays each line at the
            // font's full line-height box (with default leading); a bare
            // NSLayoutManager usedRect is ~2-3pt/line TIGHTER, so it
            // under-estimated by ~7pt on a multi-line bubble — and an
            // UNDER-estimate is exactly what makes the cell lay out short, so
            // SwiftUI Text truncates with "..." during scroll then visibly
            // expands at settle (the user-reported symptom). UILabel
            // (numberOfLines=0, byWordWrapping) reproduces SwiftUI Text's
            // Cheap TextKit measurement (boundingRect). NOTE: this gives the
            // font's TextKit line height (~fontSize×1.21), which is ~2.4pt/line
            // SHORTER than SwiftUI Text's rendered line box — so it slightly
            // under-estimates multi-line bubbles. We accept that here because the
            // real "…→expand" jitter is NOT primarily this residual (proven: every
            // measurement engine still left the symptom); the actual cause is
            // being investigated separately. Keep the measurement cheap.
            let font = UIFont.systemFont(ofSize: fontSize)
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let bounds = attr.boundingRect(
                with: CGSize(width: usableTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let fullTextH = ceil(bounds.height)
            let collapsedTextH = ceil(
                font.lineHeight * CGFloat(UserMessageCollapsePolicy.collapsedLineLimit)
            )
            let textH = collapsed ? min(fullTextH, collapsedTextH) : fullTextH
            // [T-ios-decel-inv-estimate-calibration] CJK bubble correction: all
            // five first-measure samples in the debug.scrollMetrics trace showed
            // CJK bubbles landing +6.3–7.0 taller than this boundingRect-based
            // estimate (SwiftUI Text gives PingFang-fallback lines a taller
            // box), independent of line count in the observed 1–4 line range.
            // Latin-only bubbles were exact, so gate on CJK presence. ALSO gated
            // to attachment-free bubbles: the one attachment bubble in the
            // trace (att=1) measured exactly at the UNcorrected estimate — the
            // +7 overshot it to a -6.7 shrink correction — while all five
            // validated +7 samples were att=0.
            let cjk = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x30FF).contains($0.value) }
            // Both collapsed and expanded long bubbles include the control:
            // 8pt VStack spacing + roughly one caption line (15pt).
            let disclosureH: CGFloat = collapsible ? 23 : 0
            // [T-chat-quote-reply] Quote header: 2-line caption block (~33pt),
            // 14pt vertical padding, 8pt VStack spacing, 1pt safety.
            let quoteH: CGFloat = message.quote == nil ? 0 : 56
            // bubble vertical padding (10*2) + attachment block + 1pt safety.
            let total = textH + disclosureH + quoteH + 20 + attachH + 1
                + (cjk && attachCount == 0 ? 7 : 0)
            cache[key] = total
            return total
        }

        // MARK: - Height Estimation

        /// [T-ios-scroll-decel-height-drift] The owning message id for a list
        /// item (used to detect the actively streaming message so its cells are
        /// excluded from the height memo).
        static func messageId(of item: MessageListItem) -> UUID? {
            switch item {
            case .wholeMessage(let id): return id
            case .assistantHeader(let id): return id
            case .assistantFooter(let id): return id
            case .assistantBlock(let mid, _, _), .assistantToolGroup(let mid, _): return mid
            }
        }

        /// [T-ios-scroll-decel-height-drift] Stable per-content key for the
        /// measured-height memo, keyed by item identity AND a cheap content
        /// fingerprint (content length / attachment count). The fingerprint makes
        /// the key CHANGE when the content changes height without changing
        /// identity — streaming append, async image/attachment load, tool output
        /// growth — so a stale (shorter, mid-stream) height can't be seeded onto
        /// a now-taller cell. Combined with the width-gated lookup (rotation) and
        /// clearHeightCache (session switch / font-size change), this closes the
        /// memo's staleness paths. Font size is NOT in the key because a font
        /// change routes through clearHeightCache (wipes the whole memo).
        #if DEBUG
        /// [T-ios-scroll-metrics-ring] Stable content-hash identity for a cell.
        /// Unlike contentKey (built on runtime UUIDs, regenerated when history
        /// paging reloads message objects), this survives object regeneration:
        /// same rendered content → same tag. Used ONLY by the scroll-metrics
        /// ring so one cell's height trajectory can be followed across
        /// seed/measure/inv/flush events and across reload generations.
        static func stableCellTag(for item: MessageListItem, messages: [ChatMessage], messageIndex: [UUID: Int]) -> String {
            func digest(_ s: String) -> String {
                var h: UInt32 = 5381
                for b in s.prefix(96).utf8 { h = (h &* 33) &+ UInt32(b) }
                return String(h, radix: 36)
            }
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let c = msg(id)?.content ?? ""
                return "w#\(digest(c))#\(c.count)"
            case .assistantHeader(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "h#\(digest(c))"
            case .assistantFooter(let id):
                let c = msg(id)?.blocks.first?.content ?? ""
                return "f#\(digest(c))"
            case .assistantToolGroup(let mid, let bid):
                return "g#\(mid.uuidString)#\(bid.uuidString)"
            case .assistantBlock(let mid, let bid, let segmentID):
                if let segmentID { return "s#\(bid)#\(segmentID)" }
                guard let b = msg(mid)?.blocks.first(where: { $0.id == bid }) else { return "b#?" }
                let c = b.content
                return "b#\(digest(c))#\(c.count)#\(b.kind)"
            }
        }
        #endif

        static func contentKey(for item: MessageListItem, messages: [ChatMessage], messageIndex: [UUID: Int]) -> String {
            func msg(_ id: UUID) -> ChatMessage? {
                guard let i = messageIndex[id], i < messages.count else { return nil }
                return messages[i]
            }
            switch item {
            case .wholeMessage(let id):
                let n = msg(id)?.content.count ?? 0
                let a = msg(id)?.attachments.count ?? 0
                let x = msg(id)?.isUserTextExpanded == true ? 1 : 0
                let q = msg(id)?.quote?.text.count ?? -1
                return "w:\(id.uuidString):\(n):\(a):x\(x):q\(q)"
            case .assistantHeader(let id):
                return "h:\(id.uuidString)"
            case .assistantFooter(let id):
                return "f:\(id.uuidString)"
            case .assistantToolGroup(let mid, let bid):
                let blocks = AssistantBlockPresentationSegment.tools(startingAt: bid, in: msg(mid)?.blocks ?? [])
                return "g:\(mid.uuidString):\(bid.uuidString):\(blocks.count):\(blocks.first?.isToolGroupExpanded == true)"
            case .assistantBlock(let mid, let bid, let segmentID):
                let block = msg(mid)?.blocks.first(where: { $0.id == bid })
                if let segmentID, let block {
                    let members = block.simpleBody.segments(inRow: segmentID)
                    if let segment = members.first {
                        let size = segment.media.flatMap { block.simpleBody.mediaSize(for: segmentID, media: $0) }
                        return "s:\(mid):\(bid):\(segmentID):\(members.hashValue):\(String(describing: size))"
                    }
                }
                let n = block?.content.count ?? 0
                return "b:\(mid.uuidString):\(bid.uuidString):\(n)"
            }
        }

        static func estimateItemHeight(_ item: MessageListItem, messages: [ChatMessage], width: CGFloat,
                                       maxContentWidth: CGFloat, questionContainerWidth: CGFloat? = nil,
                                       simpleRow: SimpleTranscript.Row? = nil) -> CGFloat {
            if case .assistantBlock(let mid, let bid, let id?) = item,
               let block = messages.first(where: { $0.id == mid })?.blocks.first(where: { $0.id == bid }) {
                let members = block.simpleBody.segments(inRow: id)
                guard let segment = members.first else { return 44 }
                let column = max(1, min(width - 32, maxContentWidth > 0 ? maxContentWidth : width))
                switch id.kind {
                case .image:
                    return ImageAttachment.thumbnailSize(availableWidth: column, isGroup: members.count > 1).height
                case .video:
                    let size = segment.media.flatMap { block.simpleBody.mediaSize(for: id, media: $0) }
                    return VideoAttachment.thumbnailSize(availableWidth: column, imageSize: size).height
                case .audio: return SimpleStandaloneMedia.audioHeight
                case .file: return 56
                case .table:
                    if case .table(_, let rows)? = segment.blocks.first { return CGFloat(rows.count) * TableAttachment.minRowHeight }
                    return TableAttachment.minRowHeight
                case .text:
                    let scale = FontSettings.shared.scaledMessage(16)
                    return Self.estimateTextBlockHeight(segment.searchText, width: max(1, column - 24), scale: scale, lineHeight: scale * 1.4) + 12
                }
            }
            let estimate = baseItemHeight(item, messages: messages, width: width, maxContentWidth: maxContentWidth,
                                          questionContainerWidth: questionContainerWidth)
            return estimate + (simpleRow == .text ? 12 : 0)
        }

        private static func baseItemHeight(_ item: MessageListItem, messages: [ChatMessage], width: CGFloat,
                                           maxContentWidth: CGFloat, questionContainerWidth: CGFloat?) -> CGFloat {
            let scale = FontSettings.shared.scaledMessage(16)
            let lineHeight = scale * 1.4
            let hPad: CGFloat = 80

            switch item {
            case .assistantToolGroup: return 48
            case .wholeMessage(let msgId):
                guard let msg = messages.first(where: { $0.id == msgId }) else { return 44 }
                switch msg.role {
                case .compactDivider: return 44
                case .systemInfo: return 36
                case .user:
                    // [T-ios-user-msg-estimate-tail-jitter] Use the SAME accurate
                    // UILabel-based measurement as the precalc path, NOT the coarse
                    // char-count heuristic. The heuristic (cpl = tw/(scale*0.55))
                    // under-counts lines — a 3-line message estimated as 2 lines —
                    // so when this estimate is the height used during a fast scroll
                    // / offscreen pass (before precalc lands, or via the
                    // configureCell/prefetch estimate fallback), the
                    // UIHostingConfiguration lays the Text into a 2-line box and
                    // SwiftUI truncates it to "2 lines + …"; at settle the real
                    // measure returns 3 lines and the cell visibly expands, jolting
                    // the whole page. Routing the estimate through the accurate
                    // measurement makes the offscreen height already 3 lines, so the
                    // Text never truncates and there is nothing to expand.
                    var throwaway: [String: CGFloat] = [:]
                    if let h = Self.measureUserBubbleHeight(for: msg, cvWidth: width, cache: &throwaway) {
                        return h
                    }
                    // Fallback (empty/attachment-only): coarse heuristic.
                    let tw = max(width - hPad, 100)
                    let attachCount = msg.attachments.count
                    let imgH: CGFloat
                    if attachCount > 0 {
                        let tilesPerRow = max(1, Int(tw / 70))
                        let rows = ceil(CGFloat(attachCount) / CGFloat(tilesPerRow))
                        imgH = rows * 70
                    } else {
                        imgH = 0
                    }
                    return imgH + 44
                case .assistant: return 200
                }
            case .assistantHeader:
                return 28
            case .assistantBlock(let msgId, let blockId, _):
                guard let msg = messages.first(where: { $0.id == msgId }),
                      let block = msg.blocks.first(where: { $0.id == blockId }) else { return 44 }
                switch block.kind {
                case .text:
                    if let attrStr = block.cachedAttributedString {
                        let textWidth = max(width - 32, 100)
                        // [T-ios-longreply-boundingRect-watchdog] CTFramesetter instead
                        // of NSAttributedString.boundingRect. estimateItemHeight runs
                        // in prefetch/scroll-back for every not-yet-measured cell;
                        // boundingRect's TextKit1 layout is near-O(n²) in line count
                        // and could burn hundreds of ms per cell (watchdog risk on
                        // long history). CTFramesetter is 70–700× faster with the same
                        // height (±1pt). This is only a layout ESTIMATE, and the .text
                        // block's cachedAttributedString is attachment-free markdown
                        // text (attachments render as separate blocks), so it's safe.
                        let textH = SelectableMarkdownView.ctFramesetterHeight(for: attrStr, width: textWidth)
                        // +12 = text view insets (8) + SwiftUI wrapper vertical
                        // padding (4). This CT path is the coarse prefetch
                        // fallback; the seed loop's precalc uses the exact
                        // render-engine measure (measureAttributedStringHeight).
                        return textH + 12
                    }
                    return Self.estimateTextBlockHeight(block.content, width: width, scale: scale, lineHeight: lineHeight)
                case .thinking:
                    // Header (icon 14pt or label 13pt) + vPad 10·2 + capsule border ≈ 36pt,
                    // + 4pt block-wrapper vertical padding = 40 (same calibration as tool
                    // capsules, [T-ios-decel-inv-estimate-calibration]).
                    // When expanded, content area adds up to 300pt of inner text + 10pt bottom pad.
                    let headerH: CGFloat = 40
                    guard block.isThinkingExpanded, !block.content.isEmpty else {
                        return headerH
                    }
                    let innerWidth = max(width - 24, 100)         // 12pt horizontal pad each side
                    let innerLineHeight: CGFloat = 13 * 1.4 + 3   // .lineSpacing(3) on 13pt font
                    let lines = block.content.split(separator: "\n", omittingEmptySubsequences: false)
                    var textH: CGFloat = 0
                    let cpl = max(1, innerWidth / 7)              // ~7pt per CJK/wide glyph at 13pt
                    for line in lines {
                        let wrapped = max(1, ceil(CGFloat(line.count) / cpl))
                        textH += wrapped * innerLineHeight
                    }
                    let contentH = min(textH + 10, 300)            // ScrollView capped at 300pt
                    let total = headerH + contentH
                    return total
                // [T-ios-decel-inv-estimate-calibration] Tool capsules measure exactly
                // 36pt: ToolCapsuleView has NO vertical padding (unlike .text/.thinking,
                // which add .padding(.vertical, 2) → +4). The debug.scrollMetrics ring
                // proved the split: with 40 here, every real tool capsule corrected
                // 40→36 (-4) mid-decel; the +4 growths that motivated 40 were actually
                // collapsed THINKING blocks (handled above with headerH = 40).
                case .readImageTool: return 36
                case .memoryTool:
                    guard let card = block.questionCard else { return block.kind.isSubAgentTool ? 58 : 36 }
                    return Self.estimateQuestionCardHeight(
                        card,
                        expanded: block.isQuestionCardExpanded,
                        width: questionContainerWidth ?? width,
                        maxContentWidth: maxContentWidth
                    )
                case .info:
                    let lineCount = max(1, block.content.components(separatedBy: "\n").count)
                    return CGFloat(20 + lineCount * 16)
                default: return 36  // Tool capsules (execute, browser, etc.): no wrapper pad
                }
            case .assistantFooter:
                return 4
            }
        }

        static func questionCardContentWidth(containerWidth: CGFloat, maxContentWidth: CGFloat) -> CGFloat {
            // BridgedAssistantBlockV3 applies outer padding before its bounded
            // frame; the card's own horizontal padding is inside that frame.
            let available = max(containerWidth - 32, 0)
            let cardWidth = maxContentWidth > 0 ? min(available, maxContentWidth) : available
            return max(cardWidth - 28, 1)
        }

        static func estimateQuestionCardHeight(_ card: QuestionCardState, expanded: Bool, width: CGFloat, maxContentWidth: CGFloat) -> CGFloat {
            let t = QuestionAskTypography.current
            let textWidth = questionCardContentWidth(containerWidth: width, maxContentWidth: maxContentWidth)
            if card.status == .pending, let question = card.currentQuestion {
                let key = QuestionPendingLayoutCache.key(card.requestId, card.currentIndex)
                let cap = max(160, UIScreen.main.bounds.height * 0.5 - 120)
                let cached = QuestionPendingLayoutCache.bodyHeight(key, width: textWidth, bodyFont: t.body)
                let chrome: CGFloat = 24 + 28 + 20 + 44
                if cached > 0 { return chrome + min(cached, cap) }
                let font = question.isConfirmation
                    ? UIFont.monospacedSystemFont(ofSize: t.secondary, weight: .medium)
                    : UIFont.systemFont(ofSize: t.question, weight: .medium)
                let fullQuestion = questionTextHeight(question.prompt, font: font, width: textWidth - (question.isConfirmation ? 16 : 0))
                let isExpanded = QuestionPendingLayoutCache.isExpanded(key)
                var body = (isExpanded ? fullQuestion : min(fullQuestion, font.lineHeight * 3)) + 6
                if question.isConfirmation { body += 16 }
                if fullQuestion > font.lineHeight * 3 { body += 44 + 6 }
                let optionFont = UIFont.systemFont(ofSize: t.optionTitle)
                let detailFont = UIFont.systemFont(ofSize: t.optionDetail)
                for (index, option) in question.options.enumerated() where !question.isConfirmation {
                    var row = questionTextHeight(option, font: optionFont, width: max(textWidth - t.icon - 24, 40))
                    if index < question.optionDescriptions.count, let description = question.optionDescriptions[index] {
                        row += 2 + questionTextHeight(description, font: detailFont, width: max(textWidth - t.icon - 24, 40))
                    }
                    body += max(44, row + 14) + 6
                }
                if !question.isConfirmation {
                    body += 50 // Other answer.
                    if !question.options.isEmpty { body += 50 } // Delegate.
                }
                for detail in [question.impact, question.risk].compactMap({ $0 }) where !detail.isEmpty {
                    body += questionTextHeight(detail, font: detailFont, width: textWidth) + 6
                }
                body += 50 // Note / cancellation reason.
                return chrome + min(body, cap)
            }
            var total: CGFloat = 24 + max(34, t.resolvedTopic + t.meta + 9)
            guard expanded else { return total }
            let detailWidth = max(40, textWidth - 46)
            let font = UIFont.systemFont(ofSize: t.resolvedDetail)
            total += 10
            for (index, question) in card.questions.enumerated() {
                if card.questions.count > 1 {
                    total += questionTextHeight(question.prompt, font: font, width: detailWidth) + 4
                }
                let answer = index < card.answers.count ? card.answers[index] : nil
                total += questionTextHeight(answer ?? String(localized: "No answer"), font: font, width: detailWidth) + 8
            }
            return total
        }

        private static func questionTextHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            let rect = (text as NSString).boundingRect(
                with: CGSize(width: max(width, 40), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return ceil(rect.height)
        }

        static func estimateTextBlockHeight(_ content: String, width: CGFloat, scale: CGFloat, lineHeight: CGFloat) -> CGFloat {
            // [T-ios-empty-textblock-gap] An empty text block renders nothing
            // (EmptyView) — the one-line floor below is only for non-empty
            // streaming placeholders whose first delta is about to land.
            guard !content.isEmpty else { return 0 }
            let hPad: CGFloat = 80
            let tw = max(width - hPad, 100)
            let cpl = tw / (scale * 0.5)
            var total: CGFloat = 4

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var i = 0
            while i < lines.count {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Fenced code block
                if trimmed.hasPrefix("```") {
                    var codeLines = 0
                    i += 1
                    while i < lines.count {
                        let cl = lines[i].trimmingCharacters(in: .whitespaces)
                        if cl.hasPrefix("```") { i += 1; break }
                        codeLines += 1
                        i += 1
                    }
                    total += 32 + CGFloat(max(codeLines, 1)) * 18 + 24
                    continue
                }

                // Table
                if trimmed.hasPrefix("|") && trimmed.contains("|") {
                    var tableRows = 0
                    while i < lines.count {
                        let tl = lines[i].trimmingCharacters(in: .whitespaces)
                        if tl.hasPrefix("|") && tl.contains("|") {
                            if !tl.contains("---") { tableRows += 1 }
                            i += 1
                        } else {
                            break
                        }
                    }
                    total += CGFloat(max(tableRows, 1)) * 36 + 16
                    continue
                }

                // Horizontal rule
                if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                    total += 16
                    i += 1
                    continue
                }

                // Image
                if trimmed.hasPrefix("![") && trimmed.contains("](") {
                    total += Self.estimateMarkdownImageHeight(line: trimmed, containerWidth: tw)
                    i += 1
                    continue
                }

                // Math block
                if trimmed == "$$" {
                    i += 1
                    while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "$$" {
                        i += 1
                    }
                    i += 1
                    total += 80
                    continue
                }

                // Regular text
                if trimmed.isEmpty {
                    total += lineHeight * 0.5
                } else {
                    let charCount = CGFloat(trimmed.count)
                    let wrappedLines = max(1, ceil(charCount / cpl))
                    total += wrappedLines * lineHeight
                }
                i += 1
            }

            // [T-ios-stream-bubble-spacing] +4 to match the measured-path baseline
            // (cachedAttributedString branch returns usedRect + 8; this heuristic
            // seeds total = 4, so it ran 4pt short). Centralizing the compensation
            // HERE — rather than at one applySnapshot call site — means EVERY
            // consumer (applySnapshot precalc, configureCell's estimate, and the
            // prefetch estimate) gets the padded height. The earlier per-call-site
            // +4 didn't stick because configureCell re-set the estimate from this
            // function WITHOUT the +4, overwriting it; a streaming cell then laid
            // out ~4pt short and SwiftUI clipped the bubble's .padding(.vertical, 2),
            // so the text looked glued to the bubble edges until a real measure ran.
            return max(total, lineHeight + 4) + 4
        }

        /// Estimate height for a Markdown image line by checking the image cache.
        /// Falls back to 200pt placeholder if the image hasn't been loaded yet.
        private static func estimateMarkdownImageHeight(line: String, containerWidth: CGFloat) -> CGFloat {
            let maxImageWidth: CGFloat = 400
            // Extract URL from ![alt](url)
            guard let openParen = line.range(of: "]("),
                  let closeParen = line.range(of: ")", range: openParen.upperBound..<line.endIndex) else {
                return 200
            }
            let src = String(line[openParen.upperBound..<closeParen.lowerBound])
            if let cached = NativeMediaImageCache.shared.image(for: src) {
                let imgWidth = min(min(containerWidth, cached.size.width), maxImageWidth)
                let aspect = cached.size.height / max(cached.size.width, 1)
                let maxH = UIScreen.main.bounds.height / 2
                return min(imgWidth * aspect, maxH) + 6
            }
            return 200
        }

        // MARK: - Scroll

        private let nearBottomThreshold: CGFloat = 20

        /// Tighter threshold for *re-acquiring* `.autoScrolling` after a
        /// deliberate user interaction settles. `nearBottomThreshold` (20pt)
        /// is right for *maintaining* the bottom-pin during streaming, but
        /// reusing it to re-arm auto-scroll caused trackpad jitter on iPad:
        /// a tiny two-finger scroll up leaves the offset well within 20pt of
        /// the bottom, so settle flipped straight back to `.autoScrolling`,
        /// the contentSize KVO re-pinned to the bottom, and that fought the
        /// next small scroll — the scrollbar darted up and down. Requiring the
        /// content to be essentially flush with the bottom (≤4pt) means a
        /// deliberate small scroll stays in `.userBrowsing`, while a scroll
        /// that genuinely lands at the bottom still resumes follow-along.
        /// [T-ios-trackpad-scroll-jitter]
        private let reacquireAutoScrollThreshold: CGFloat = 4

        /// Whether a list item is part of the given assistant message's span
        /// (block or footer — the header is the span's start, matched
        /// separately). [T-stream-hover-earlier-streaming]
        static func item(_ item: MessageListItem, belongsTo messageId: UUID) -> Bool {
            switch item {
            case .assistantBlock(let mid, _, _), .assistantToolGroup(let mid, _): return mid == messageId
            case .assistantFooter(let mid): return mid == messageId
            case .wholeMessage, .assistantHeader: return false
            }
        }

        func isNearBottom() -> Bool {
            return isWithinBottom(nearBottomThreshold)
        }

        /// True when the content offset is within `threshold` pt of the
        /// maximum (bottom) offset.
        func isWithinBottom(_ threshold: CGFloat) -> Bool {
            guard let cv = viewController?.collectionView else { return true }
            // Use adjustedContentInset to account for input bar + tool bar overlay insets.
            let maxOffset = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            return maxOffset - cv.contentOffset.y < threshold
        }

        // MARK: - Search

        private var searchViewportWidth: CGFloat = 0
        private var searchPositionOwner: (hit: ChatSearchHit, stamp: PositionStamp)?
        private struct SearchPlacement {
            let stamp: PositionStamp
            let model: ObjectIdentifier
            let hit: ChatSearchHit
            let item: MessageListItem
            let readyAfter: CFTimeInterval
        }

        private var pendingSearchPlacement: SearchPlacement?
        private var searchPlacementWork: DispatchWorkItem?

        func keepSearchAfterWidthChange(_ width: CGFloat) {
            let old = searchViewportWidth
            searchViewportWidth = width
            guard old > 0, abs(old - width) > 1, requestedTranscriptMode == transcriptMode,
                  let vm, vm.chatSearch.isActive,
                  let hit = vm.chatSearch.current, let item = searchItem(for: hit),
                  let owner = searchPositionOwner, owner.hit.match == hit.match, owner.hit.keyword == hit.keyword,
                  ownsDirectScroll(owner.stamp) else { return }
            queueSearchPlacement(hit, item: item, model: vm.chatSearch, ownedBy: owner.stamp)
        }

        func revealSearchHit(_ hit: ChatSearchHit) {
            guard let vm, let cv = viewController?.collectionView, let ds = dataSource,
                  let message = vm.messages.first(where: { $0.id == hit.messageId }) else { return }
            guard requestedTranscriptMode == transcriptMode, vm.chatSearch.transcriptMode == transcriptMode,
                  transcriptMode == .standard || searchItem(for: hit) != nil else { return }
            scrollMode = .userBrowsing
            guard let owner = beginDirectScroll() else { return }
            searchPositionOwner = (hit, owner)
            if message.role == .user, !message.isUserTextExpanded, transcriptMode == .standard || !message.isQueued {
                toggleUserMessageExpansion(messageId: message.id)
            }
            if transcriptMode == .standard, let blockId = hit.blockId {
                if message.isStepsCollapsed { message.isStepsCollapsed = false }
                for segment in AssistantBlockPresentationSegment.make(message.blocks, enabled: collapseConsecutiveToolCalls)
                where segment.blocks.contains(where: { $0.id == blockId }) && segment.isToolGroup {
                    segment.blocks.first?.isToolGroupExpanded = true
                }
                applySnapshot(messages: vm.messages, caller: "search-expand")
            }
            guard let item = searchItem(for: hit), let ip = ds.indexPath(for: item) else { return }
            if cv.cellForItem(at: ip) == nil {
                guard prepareDirectScroll(ownedBy: owner) else { return }
                cv.scrollToItem(at: ip, at: .centeredVertically, animated: false)
                cv.layoutIfNeeded()
            }
            placeSearchHit(hit, item: item, ownedBy: owner)
            queueSearchPlacement(hit, item: item, model: vm.chatSearch, ownedBy: owner)
        }

        private func searchItem(for hit: ChatSearchHit) -> MessageListItem? {
            guard let items = dataSource?.snapshot().itemIdentifiers else { return nil }
            let preferred: MessageListItem?
            if hit.match.key.field == .footerError { preferred = .assistantFooter(hit.messageId) }
            else if let blockID = hit.blockId {
                let segmentID = hit.match.key.segmentID
                if transcriptMode == .simple, let segmentID {
                    guard let block = vm?.messages.first(where: { $0.id == hit.messageId })?.blocks.first(where: { $0.id == blockID }),
                          let rowID = block.simpleBody.rowID(for: segmentID) else { return nil }
                    preferred = .assistantBlock(hit.messageId, blockID, rowID)
                } else {
                    preferred = .assistantBlock(hit.messageId, blockID, segmentID)
                }
            }
            else { preferred = transcriptMode == .simple ? .wholeMessage(hit.messageId) : nil }
            if transcriptMode == .simple { return items.first { $0 == preferred } }
            return items.first { $0 == preferred } ?? items.first { $0.messageId == hit.messageId }
        }

        private func cancelSearchPlacement() {
            searchPlacementWork?.cancel()
            searchPlacementWork = nil
            pendingSearchPlacement = nil
        }

        private func queueSearchPlacement(_ hit: ChatSearchHit, item: MessageListItem, model: ChatSearchModel, ownedBy stamp: PositionStamp) {
            guard ownsDirectScroll(stamp) else { return }
            cancelSearchPlacement()
            pendingSearchPlacement = SearchPlacement(stamp: stamp, model: ObjectIdentifier(model), hit: hit, item: item,
                                                     readyAfter: CACurrentMediaTime() + 0.25)
            schedulePendingSearchPlacement()
        }

        private var searchPlacementGeometryReady: Bool {
            viewportGeometryCommitDepth == 0 && !keyboardInFlight
                && viewController?.messageListLayout?.isKeyboardTransitioning != true
                && (geometryContext?.onSearchContentBounds == nil || geometryContext?.configuration.searchTopIsMeasured == true)
        }

        private func schedulePendingSearchPlacement() {
            guard let placement = pendingSearchPlacement, searchPlacementWork == nil, searchPlacementGeometryReady else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.searchPlacementWork = nil
                guard self.searchPlacementGeometryReady else { return }
                self.pendingSearchPlacement = nil
                guard self.ownsDirectScroll(placement.stamp),
                      let model = self.vm?.chatSearch, ObjectIdentifier(model) == placement.model, model.isActive,
                      self.requestedTranscriptMode == self.transcriptMode, model.transcriptMode == self.transcriptMode,
                      model.current?.match == placement.hit.match, model.current?.keyword == placement.hit.keyword,
                      let cv = self.viewController?.collectionView, cv.window != nil,
                      !cv.isTracking, !cv.isDragging, !cv.isDecelerating else { return }
                self.placeSearchHit(placement.hit, item: placement.item, ownedBy: placement.stamp, onlyIfObscured: true)
            }
            searchPlacementWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, placement.readyAfter - CACurrentMediaTime()), execute: work)
        }

        private func placeSearchHit(_ hit: ChatSearchHit, item: MessageListItem, ownedBy owner: PositionStamp, onlyIfObscured: Bool = false) {
            guard ownsDirectScroll(owner), let cv = viewController?.collectionView, let ip = dataSource?.indexPath(for: item),
                  let frame = cv.layoutAttributesForItem(at: ip)?.frame else { return }
            var rect = frame
            if let cell = cv.cellForItem(at: ip), let tableCell = Self.currentSimpleTableCell(in: cell.contentView) {
                var parent = tableCell.superview
                while let view = parent, !(view is TableScrollView) { parent = view.superview }
                if let scroll = parent as? TableScrollView {
                    scroll.scrollRectToVisible(tableCell.convert(tableCell.bounds, to: scroll), animated: false)
                }
                rect = tableCell.convert(tableCell.bounds, to: cv)
            } else if let cell = cv.cellForItem(at: ip), let textView = Self.searchTextViews(in: cell.contentView).first(where: { $0.searchUnitKey == hit.match.key }),
               let local = textView.searchMatchRect(ordinal: hit.match.ordinal) { rect = textView.convert(local, to: cv) }
            else if hit.blockId == nil, hit.match.key.field == .body, frame.height > cv.bounds.height * 0.8 {
                let ranges = ChatSearchMatcher.ranges(of: hit.keyword, in: hit.text, limit: hit.match.ordinal + 1)
                if ranges.indices.contains(hit.match.ordinal) {
                    let offset = hit.text.distance(from: hit.text.startIndex, to: ranges[hit.match.ordinal].lowerBound)
                    rect = CGRect(x: frame.minX, y: frame.minY + frame.height * CGFloat(offset) / CGFloat(max(1, hit.text.count)), width: frame.width, height: 24)
                }
            }
            let top = cv.contentOffset.y + cv.adjustedContentInset.top
            let height = cv.bounds.height - cv.adjustedContentInset.top - cv.adjustedContentInset.bottom
            guard height > 40 else { return }
            let margin: CGFloat = onlyIfObscured ? 0 : 40
            if rect.minY >= top + margin && rect.maxY <= top + height - margin { return }
            let minimum = -cv.adjustedContentInset.top
            let maximum = max(minimum, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let target = rect.minY - cv.adjustedContentInset.top - height * 0.3
            guard prepareDirectScroll(ownedBy: owner) else { return }
            cv.setContentOffset(CGPoint(x: cv.contentOffset.x, y: min(maximum, max(minimum, target))), animated: false)
        }
        private static func searchTextViews(in view: UIView) -> [SelectableMarkdownTextView] {
            (view as? SelectableMarkdownTextView).map { [$0] } ?? view.subviews.flatMap { searchTextViews(in: $0) }
        }

        private static func currentSimpleTableCell(in view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "simpleTableCurrentMatch" { return view }
            return view.subviews.lazy.compactMap { currentSimpleTableCell(in: $0) }.first
        }

        /// [T-chat-search] The transient ring drawn around the row a search hit
        /// landed on. Held so a second jump replaces it instead of stacking.
        private var searchHighlightView: UIView?

        /// Diagnostics: which user turn the current viewport TOP is in.
        /// Returns (turnIndex, totalTurns); turnIndex is 0-based into the ordered
        /// list of user messages, -1 if unresolved. Cheap enough to call from a
        /// throttled scroll sampler.
        func currentViewportUserTurn() -> (index: Int, total: Int) {
            guard let cv = viewController?.collectionView,
                  let vm, let ds = dataSource else { return (-1, 0) }
            let msgs = vm.messages
            let userIds = msgs.compactMap { $0.role == .user ? $0.id : nil }
            guard !userIds.isEmpty else { return (-1, 0) }
            let topItemMsgId: UUID? = cv.indexPathsForVisibleItems.min()
                .flatMap { ds.itemIdentifier(for: $0) }
                .flatMap { Self.messageId(of: $0) }
            let topMsgIdx = topItemMsgId.flatMap { id in msgs.firstIndex(where: { $0.id == id }) } ?? 0
            let anchor = msgs[...topMsgIdx].reversed().first(where: { $0.role == .user })?.id ?? userIds.first!
            return (userIds.firstIndex(of: anchor) ?? -1, userIds.count)
        }

        /// Compact dump of the isWithinBottom inputs for ScrollDiag logs.
        static func nbDump(_ cv: UICollectionView?) -> String {
            guard let cv else { return "cv=nil→isWithinBottom RETURNS TRUE" }
            let maxOff = cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom
            let diff = maxOff - cv.contentOffset.y
            return "off=\(String(format: "%.0f", cv.contentOffset.y)) cs=\(String(format: "%.0f", cv.contentSize.height)) bh=\(String(format: "%.0f", cv.bounds.height)) adjBot=\(String(format: "%.0f", cv.adjustedContentInset.bottom)) maxOff=\(String(format: "%.0f", maxOff)) diff=\(String(format: "%.0f", diff))"
        }

        /// Base contentInset.top (without sub-viewport overflow compensation).
        /// iOS 26+ relies on system; older iOS uses an 8pt manual padding.
        var topOverlayInset: CGFloat = 0
        var baseContentInsetTop: CGFloat {
            if #available(iOS 26, *) { return topOverlayInset } else { return 8 + topOverlayInset }
        }

        /// Base contentInset.bottom = inputBarHeight + floatingBarHeight + 8.
        /// Resolved from the instance geometry context (or standalone fallback);
        /// the actual inset adds the current sub-viewport compensation, if any.
        /// `prepareViewportInsets` is the only place that writes
        /// contentInset.bottom — it reads this base and adds overflow.
        var baseBottomInset: CGFloat = 0

        /// When content overflows the visible area but is still smaller than the
        /// UIKit-scrollable threshold, UIKit clamps maxOffset at 0 and the
        /// bottom of the content gets hidden behind the bottom overlay.
        ///
        /// Compensate by inflating `contentInset.bottom` by the overflow
        /// amount so UIKit's natural maxOffset moves down (= contentSize -
        /// bounds + bottomInset becomes positive). The user can then scroll
        /// up to reveal the bottom rows that were hidden by the floating bar.
        /// `contentInset.top` stays at `baseContentInsetTop` so the first row
        /// is always glued to the safe area — no blank above the user message.
        ///
        /// `prepareViewportInsets` is the only writer of
        /// `cv.contentInset.bottom`. It resolves the current shared geometry
        /// before applying
        /// `baseBottomInset + (needs ? overflow : 0)`.
        private func prepareViewportInsets(caller: String, forceRelax: Bool = false) {
            _ = consumeSessionLoadClamp()
            guard let cv = viewController?.collectionView else { return }
            let previousBase = baseBottomInset
            baseBottomInset = geometryContext?.baseBottomInset ?? fallbackBottomInset
            topOverlayInset = geometryContext?.configuration.topOverlayInset ?? fallbackTopOverlayInset
            if abs(cv.contentInset.top - baseContentInsetTop) > 0.5 {
                cv.contentInset.top = baseContentInsetTop
            }
            let safeAreaTop = cv.safeAreaInsets.top
            // Use the resolved baseBottomInset as the truth
            // for the non-compensated bottom. Reading cv.adjustedContentInset.bottom
            // here would create a feedback loop: we'd be measuring the inset we
            // just inflated and concluding we don't need to inflate any more.
            let bottomInsetBase = baseBottomInset
            let visibleH = cv.bounds.height - safeAreaTop - bottomInsetBase
            let overflow = cv.contentSize.height - visibleH
            // Active compensation: content overflows but UIKit thinks no scroll
            // is needed. UIKit's natural maxContentOffset is
            //   contentSize - bounds + adjustedContentInset.top + adjustedContentInset.bottom
            // safeAreaTop becomes adjustedContentInset.top, so include it here —
            // omitting it under-counts maxOffset by safeAreaTop (~116pt) and
            // wrongly engages compensation when content already fits naturally.
            let rawMaxOff = cv.contentSize.height - cv.bounds.height
                          + bottomInsetBase + safeAreaTop
            let needsCompensation = overflow > 0 && rawMaxOff <= 0
            // A changed composer base is not accumulated compensation. Carry
            // only the prior algorithm's inflation across this base update.
            let prevBottomInset = max(bottomInsetBase, cv.contentInset.bottom + bottomInsetBase - previousBase)

            // [B-fix] Monotonic compensation: during streaming, contentSize
            // grows token-by-token. The naive `desired = needs ? base+overflow
            // : base` jumps the inset back to base the moment `rawMaxOff`
            // crosses 0 (~content reaches bounds.height), and the PIN below
            // chases the inset down — visually the streaming cell snaps from
            // mid-screen back to the bottom by ~overflow pt (observed: 114pt
            // jump at 17:35:39, log [CHANGE] bottomInset 302.7→188.4 RELAX).
            //
            // Hold the inflated inset until either (a) caller explicitly asks
            // for a RELAX (e.g. mode change, snapshot-shrink, clear), or (b)
            // the cell can naturally scroll past `prevBottomInset - base` —
            // i.e. rawMaxOff has caught up to the existing inflation, so
            // releasing it produces no geometric jump.
            let priorInflation = max(0, prevBottomInset - bottomInsetBase)
            let canSafelyRelax = rawMaxOff >= priorInflation - 0.5
            let desiredBottomInset: CGFloat
            if needsCompensation {
                // Grow only — never let the inset shrink mid-stream.
                desiredBottomInset = max(prevBottomInset, bottomInsetBase + overflow)
            } else if forceRelax || canSafelyRelax {
                desiredBottomInset = bottomInsetBase
            } else {
                desiredBottomInset = prevBottomInset
            }
            let bottomInsetWillChange = abs(cv.contentInset.bottom - desiredBottomInset) > 0.5
            if bottomInsetWillChange {
                let reason: String
                if desiredBottomInset < prevBottomInset {
                    reason = forceRelax ? "RELAX-FORCED" : "RELAX-SAFE (rawMaxOff≥priorInfl)"
                } else if needsCompensation && prevBottomInset <= bottomInsetBase + 0.5 {
                    reason = "ENGAGE (overflow=\(String(format: "%.0f", overflow)))"
                } else {
                    reason = "GROW (overflow=\(String(format: "%.0f", overflow)))"
                }
                AppLogger(category: "SubViewport").info("[CHANGE] from=\(caller) bottomInset \(String(format: "%.1f", prevBottomInset))→\(String(format: "%.1f", desiredBottomInset)) Δ\(String(format: "%+.1f", desiredBottomInset - prevBottomInset)) — \(reason)")
                cv.contentInset.bottom = desiredBottomInset
            }
        }

        private func scrollToBottomNow(animated: Bool = false) {
            guard let cv = viewController?.collectionView else { return }
            invalidatePositionRequests()
            if viewportGeometryCommitDepth > 0 {
                enqueuePosition(.explicit)
                return
            }
            UIView.performWithoutAnimation { prepareViewportInsets(caller: "explicit") }
            if !previousSnapshotIds.isEmpty { didRestoreScroll = true }
            let y = boundedPosition(cv.contentOffset.y, followsBottom: true, in: cv)
            guard abs(y - cv.contentOffset.y) > 0.5 else { syncScrollFlags(); return }
            let target = CGPoint(x: cv.contentOffset.x, y: y)
            if animated {
                isAnimatingScrollToBottom = true
                cv.setContentOffset(target, animated: true)
                // The animated set's final scrollViewDidScroll should land within
                // the near-bottom threshold, but an interrupted animation or
                // sub-pixel/inset rounding can leave vm.isNearBottom stuck false,
                // so the scroll-to-bottom button keeps showing while already at
                // the bottom. Re-sync once the animation settles.
                DispatchQueue.main.async { [weak self] in self?.syncScrollFlags() }
            } else {
                cv.contentOffset = target
                syncScrollFlags()
            }
        }

        /// Re-sync the scroll-to-bottom button after a programmatic jump,
        /// whose terminal scrollViewDidScroll may not fire at the settled offset.
        func syncScrollFlags() {
            guard let vm else { return }
            let nb = isNearBottom()
            if vm.isNearBottom != nb {
                AppLogger(category: "ScrollDiag").info("[ScrollDiag][syncScrollFlags] isNearBottom \(vm.isNearBottom)→\(nb) \(Self.nbDump(viewController?.collectionView))")
                vm.isNearBottom = nb
            }
        }

        // MARK: - Scrolling Screenshot Capture

        /// [T-ios-copy-screenshot-diag-logs] Locate the UITextView descendant
        /// (if any) that currently holds an active text-range selection in
        /// the collection view subtree. Used only by the screenshot
        /// diagnostic trace — non-destructive (does NOT clear selection).
        /// Returns the first textView found with a non-zero selectedRange,
        /// matching the depth-first walk order of `clearTextSelection`.
        @MainActor
        private func activeSelectableTextView(in cv: UICollectionView) -> UITextView? {
            var found: UITextView? = nil
            func walk(_ view: UIView) {
                if found != nil { return }
                if let tv = view as? UITextView, tv.selectedRange.length > 0 {
                    found = tv
                    return
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
            return found
        }

        /// Walk all subviews of `cv` and clear any active text selection so
        /// selection handles, magnifier loupes, focus rings and tinted ranges
        /// don't show up in screenshots.
        @MainActor
        private func clearTextSelection(in cv: UICollectionView) {
            // Dismiss keyboard / global edit menu first.
            cv.window?.endEditing(true)
            UIMenuController.shared.hideMenu()

            func walk(_ view: UIView) {
                if let tv = view as? UITextView {
                    if tv.isFirstResponder { tv.resignFirstResponder() }
                    // Collapse selection to a zero-length range (nil doesn't
                    // always clear UITextView's internal selection state).
                    if let start = tv.position(from: tv.beginningOfDocument, offset: 0) {
                        tv.selectedTextRange = tv.textRange(from: start, to: start)
                    }
                    tv.selectedTextRange = nil
                }
                for sub in view.subviews { walk(sub) }
            }
            walk(cv)
        }

        /// Capture a conversation turn by scrolling the live collection view
        /// page by page and stitching the snapshots into a single image.
        ///
        /// Uses fixed-height pages (`usableH`). Each page is cropped to
        /// exclude the nav bar (top) and input bar (bottom) overlay areas.
        /// Original `contentOffset` is restored before returning.
        @MainActor
        func captureScrollingTurnScreenshot(userMessageId: UUID, assistantMessageId: UUID?) -> UIImage? {
            guard !forceUncollapsedToolsForScreenshot, let vm, !vm.isLoadingSession,
                  let cv = viewController?.collectionView else { return nil }
            let savedOffset = cv.contentOffset
            let savedMode = scrollMode
            let savedClamp = clampAfterSessionLoad
            // Capture the original block cells, never just a folded header. Do
            // not mutate preferences or per-group disclosure state.
            forceUncollapsedToolsForScreenshot = true
            scrollMode = .userBrowsing
            clampAfterSessionLoad = false
            defer {
                forceUncollapsedToolsForScreenshot = false
                applySnapshot(messages: vm.messages, caller: "screenshot-restore-tool-groups")
                cv.layoutIfNeeded()
                let minimum = -cv.adjustedContentInset.top
                let maximum = max(minimum, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
                cv.setContentOffset(CGPoint(x: savedOffset.x, y: min(maximum, max(minimum, savedOffset.y))), animated: false)
                scrollMode = savedMode
                clampAfterSessionLoad = savedClamp
            }
            applySnapshot(messages: vm.messages, caller: "screenshot-unfold-tools")
            cv.layoutIfNeeded()
            return captureUncollapsedScrollingTurnScreenshot(userMessageId: userMessageId, assistantMessageId: assistantMessageId)
        }

        @MainActor
        private func captureUncollapsedScrollingTurnScreenshot(userMessageId: UUID, assistantMessageId: UUID?) -> UIImage? {
            // [T-ios-copy-screenshot-diag-logs] All ChatScreenshot logs share
            // this monotonic anchor so users can read elapsed-ms deltas
            // between stages without reasoning about wall-clock timestamps.
            let t0 = CACurrentMediaTime()
            func ms() -> String { String(format: "%6.1fms", (CACurrentMediaTime() - t0) * 1000) }

            guard let cv = viewController?.collectionView,
                  let snapshot = dataSource?.snapshot() else {
                screenshotLogger.info("captureScrolling: no cv or snapshot")
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) ABORT — no cv or snapshot")
                return nil
            }
            let items = snapshot.itemIdentifiers

            guard let startIdx = items.firstIndex(where: {
                if case .wholeMessage(let id) = $0, id == userMessageId { return true }
                return false
            }) else {
                screenshotLogger.info("captureScrolling: user item not found")
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) ABORT — user message id=\(userMessageId.uuidString.prefix(8)) not found in snapshot")
                return nil
            }

            let endIdx: Int
            if let assistantMessageId,
               let i = items.lastIndex(where: {
                   $0.messageId == assistantMessageId
               }) {
                endIdx = i
            } else {
                endIdx = startIdx
            }

            guard endIdx >= startIdx else { return nil }

            // [Stage1-Entry] full pre-capture state dump. The most important
            // fields for the top-blank symptom are contentOffset.y vs the
            // measured user-message frame.minY — if these don't align after
            // the warming pass, the page loop's first iteration crops from
            // the wrong starting Y.
            let savedOffset = cv.contentOffset
            // [T-ios-copy-screenshot-top-blank] Suspend the auto-scroll
            // pinning machinery for the duration of the capture. When
            // the session is in `.autoScrolling` mode, the contentSize
            // KVO observer (around line 695) reacts to any layout
            // change — including the stream-driven cell-height
            // measurements that fire while we hold the runloop — by
            // resetting `cv.contentOffset.y = max(cv.contentOffset.y,
            // maxOff)`. That silently undoes our setContentOffset
            // writes during the page loop and the top of the turn
            // ends up missing from the canvas. Switch to
            // `.userBrowsing` for the capture (the same flag scrollViewWillBeginDragging
            // uses) and also clear `clampAfterSessionLoad`.
            // Restored before returning.
            let savedScrollMode = self.scrollMode
            let savedClampAfterSessionLoad = self.clampAfterSessionLoad
            self.scrollMode = .userBrowsing
            self.clampAfterSessionLoad = false
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMsg=\(userMessageId.uuidString.prefix(8)) startIdx=\(startIdx) endIdx=\(endIdx) totalItems=\(items.count) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse")→browse(suspended) clampAfterSessionLoad=\(savedClampAfterSessionLoad)→false")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.contentOffset=(\(String(format: "%.1f", savedOffset.x)),\(String(format: "%.1f", savedOffset.y)))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.bounds=\(String(format: "%.0fx%.0f", cv.bounds.width, cv.bounds.height)) cv.contentSize=\(String(format: "%.0fx%.0f", cv.contentSize.width, cv.contentSize.height))")
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) cv.adjustedContentInset=(t=\(String(format: "%.1f", cv.adjustedContentInset.top)) b=\(String(format: "%.1f", cv.adjustedContentInset.bottom)))")
            // Pre-warming frame readback — these may be ESTIMATED if the
            // user-message cell was off-screen at long-press time.
            let entryFirstFrame = cv.layoutAttributesForItem(at: IndexPath(item: startIdx, section: 0))?.frame
            let entryLastFrame = cv.layoutAttributesForItem(at: IndexPath(item: endIdx, section: 0))?.frame
            chatScreenshotLogger.info("[Stage1-Entry] \(ms()) PRE-warm firstFrame=\(entryFirstFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil") lastFrame=\(entryLastFrame.map { String(format: "y=%.1f h=%.1f", $0.minY, $0.height) } ?? "nil")")
            // Is the user message currently visible? If yes, no scroll
            // adjustment needed; if not, warming has to do real work.
            let visibleRange: ClosedRange<CGFloat>? = {
                let bounds = cv.bounds
                return savedOffset.y...(savedOffset.y + bounds.height)
            }()
            if let f = entryFirstFrame, let vr = visibleRange {
                let onScreen = f.maxY >= vr.lowerBound && f.minY <= vr.upperBound
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) userMessage visibleAtLongPress=\(onScreen) frameRange=[\(String(format: "%.1f", f.minY)),\(String(format: "%.1f", f.maxY))] viewportRange=[\(String(format: "%.1f", vr.lowerBound)),\(String(format: "%.1f", vr.upperBound))]")
            }
            // Active text selection state — text-selection menu path enters
            // here with selection ranges held by some UITextView descendant.
            // Knowing whether selection is held and which direction it was
            // dragged is the spec's prime suspect for the top-blank symptom.
            let activeSel = self.activeSelectableTextView(in: cv)
            if let tv = activeSel {
                let r = tv.selectedRange
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) selection ACTIVE on textView=\(String(format: "%p", Int(bitPattern: Unmanaged.passUnretained(tv).toOpaque()))) range=(loc=\(r.location), len=\(r.length)) textLen=\(tv.textStorage.length)")
            } else {
                chatScreenshotLogger.info("[Stage1-Entry] \(ms()) no active text selection")
            }

            clearTextSelection(in: cv)
            cv.layoutIfNeeded()
            // [T-ios-copy-screenshot-top-blank] After clearing the active
            // text selection, give UIKit one runloop tick to finish
            // releasing the selection state. Without this short wait,
            // scrollToItem below sometimes no-ops or partial-commits — the
            // cv is still inside its selection-locked autoscroll state from
            // the long-press gesture that opened the menu — and the
            // measured firstFrame.minY ends up offset from where the
            // page-loop expects it, dropping the top of the user message
            // off the final canvas.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            let viewportH = cv.bounds.height
            let bottomMask = max(0, cv.adjustedContentInset.bottom)
            let topMask = max(0, cv.adjustedContentInset.top)
            let navSafetyGap: CGFloat = 10
            let cropTop = topMask + navSafetyGap
            let usableH = max(1, viewportH - cropTop - bottomMask)

            chatScreenshotLogger.info("[Stage2-Warming] \(ms()) BEGIN viewportH=\(String(format: "%.1f", viewportH)) topMask=\(String(format: "%.1f", topMask)) bottomMask=\(String(format: "%.1f", bottomMask)) cropTop=\(String(format: "%.1f", cropTop)) usableH=\(String(format: "%.1f", usableH))")
            // --- Warming pass ---
            // On first session load, cells above the viewport haven't been
            // configured yet (UICollectionView lazy-loads). First scroll the
            // user message into view so its cell is created and measured,
            // then scroll page-by-page through the assistant response.
            // After this pass all layout frames reflect measured heights.
            do {
                // Step 1: bring the user message cell on screen.
                let beforeStep1 = cv.contentOffset.y
                cv.scrollToItem(at: IndexPath(item: startIdx, section: 0), at: .top, animated: false)
                cv.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                let afterStep1 = cv.contentOffset.y
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP1 scrollToItem(startIdx) offset: \(String(format: "%.1f", beforeStep1)) → \(String(format: "%.1f", afterStep1)) Δ=\(String(format: "%.1f", afterStep1 - beforeStep1))")

                // Step 2: scroll through the rest of the turn so all cells
                // between startIdx and endIdx are configured.
                let estLast = cv.layoutAttributesForItem(at: IndexPath(item: endIdx, section: 0))?.frame.maxY
                    ?? (cv.contentOffset.y + viewportH * 3)
                var warmY = cv.contentOffset.y + cropTop
                var warmCount = 0
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) STEP2 begin estLast=\(String(format: "%.1f", estLast)) initialWarmY=\(String(format: "%.1f", warmY))")
                while warmY < estLast && warmCount < 200 {
                    warmCount += 1
                    cv.contentOffset = CGPoint(x: 0, y: warmY - cropTop)
                    cv.layoutIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    let actual = cv.contentOffset.y + cropTop
                    if actual + usableH >= estLast { break }
                    if actual <= warmY - 0.5 && warmCount > 1 { break }
                    warmY = actual + usableH
                }
                cv.layoutIfNeeded()
                screenshotLogger.info("captureScrolling: warming pass complete (\(warmCount) steps)")
                chatScreenshotLogger.info("[Stage2-Warming] \(ms()) END steps=\(warmCount) finalOffset=\(String(format: "%.1f", cv.contentOffset.y)) estLast=\(String(format: "%.1f", estLast))")
            }

            // [T-ios-copy-screenshot-top-blank] After the warming pass
            // re-anchor scroll to the user message's measured top. The
            // warming pass advances contentOffset turn-by-turn, leaving
            // the cv parked deep in the assistant response. Subsequent
            // page-loop code reads `firstAttrs.frame` for turnTopY but
            // never repositions the scroll view — so the first page
            // capture would start from wherever the warming pass left
            // off (= bottom of the turn) rather than from the user
            // message top. The page loop's per-page scrollToY corrects
            // this once it iterates, but the first frame readback
            // happens before that and prior code paths assumed
            // contentOffset already matched. Make the assumption hold
            // by explicitly scrolling startIdx back to top here.
            let beforeReAnchor = cv.contentOffset.y
            cv.scrollToItem(at: IndexPath(item: startIdx, section: 0), at: .top, animated: false)
            cv.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) scrollToItem(startIdx, .top) offset: \(String(format: "%.1f", beforeReAnchor)) → \(String(format: "%.1f", cv.contentOffset.y)) Δ=\(String(format: "%.1f", cv.contentOffset.y - beforeReAnchor))")

            // --- Read final layout frames (now measured, not estimated) ---
            let firstAttrs = cv.layoutAttributesForItem(at: IndexPath(item: startIdx, section: 0))
            let lastAttrs = cv.layoutAttributesForItem(at: IndexPath(item: endIdx, section: 0))
            guard let firstFrame = firstAttrs?.frame, let lastFrame = lastAttrs?.frame else {
                screenshotLogger.info("captureScrolling: missing layout attributes")
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ABORT — missing layout attributes (firstAttrs=\(firstAttrs == nil ? "nil" : "ok") lastAttrs=\(lastAttrs == nil ? "nil" : "ok"))")
                cv.contentOffset = savedOffset
                self.scrollMode = savedScrollMode
                self.clampAfterSessionLoad = savedClampAfterSessionLoad
                return nil
            }
            let turnTopY = firstFrame.minY - 10
            let turnBottomY = lastFrame.maxY
            let totalH = turnBottomY - turnTopY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) MEASURED firstFrame=\(String(format: "y=%.1f h=%.1f maxY=%.1f", firstFrame.minY, firstFrame.height, firstFrame.maxY)) lastFrame=\(String(format: "y=%.1f h=%.1f maxY=%.1f", lastFrame.minY, lastFrame.height, lastFrame.maxY))")
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) DERIVED turnTopY=\(String(format: "%.1f", turnTopY)) turnBottomY=\(String(format: "%.1f", turnBottomY)) totalH=\(String(format: "%.1f", totalH))")
            // KEY DIAGNOSTIC: alignment of cv.contentOffset.y vs turnTopY
            // matters because the first iteration of the page loop ASSUMES
            // a scroll has placed nextContentY (= turnTopY) at the cropTop
            // line. If contentOffset.y is far off from (turnTopY - cropTop),
            // the first scrollToY may clamp or no-op and the top of the
            // capture starts from elsewhere.
            let expectedOffsetY = turnTopY - cropTop
            let offsetDelta = cv.contentOffset.y - expectedOffsetY
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) ALIGN cv.contentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) expected=(turnTopY - cropTop)=\(String(format: "%.1f", expectedOffsetY)) DELTA=\(String(format: "%.1f", offsetDelta)) (positive=scrolled past top)")
            // [T-ios-copy-screenshot-top-blank] Diagnostic dump of every
            // mechanism that could be pinning the cv to bottom and
            // overriding our setContentOffset writes — without these
            // we cannot tell whether scrollMode/autoScrolling, the
            // clamp-after-session-load timer, an in-flight animated
            // scroll, an active gesture, deceleration, or some other
            // observer is rejecting the offset write.
            let maxOff = max(0, cv.contentSize.height - cv.bounds.height + cv.adjustedContentInset.bottom)
            let nearBottom = (maxOff - cv.contentOffset.y) < 60
            chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) PIN-STATE scrollMode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") clampAfterSessionLoad=\(self.clampAfterSessionLoad) isAnimatingScrollToBottom=\(self.isAnimatingScrollToBottom) maxOff=\(String(format: "%.1f", maxOff)) currentOffset.y=\(String(format: "%.1f", cv.contentOffset.y)) nearBottom=\(nearBottom) tracking=\(cv.isTracking) decel=\(cv.isDecelerating) dragging=\(cv.isDragging) GRs=\((cv.gestureRecognizers ?? []).map { "\(type(of: $0)):\($0.state.rawValue)" }.joined(separator: ","))")
            // [T-ios-copy-screenshot-top-blank] Probe each scroll write
            // separately so the log records which one (if any) actually
            // moves the offset. Reading cv.contentOffset.y BEFORE every
            // setter + RIGHT AFTER (no runloop) shows whether UIKit
            // accepted the write synchronously; one runloop hop later
            // tells whether some observer rewrote it. Without this
            // breakdown we can't distinguish "setter rejected" from
            // "setter accepted but reverted".
            if abs(offsetDelta) > 1 {
                self.clearTextSelection(in: cv)
                // Disable scroll gestures temporarily — these are the
                // most visible suspect for blocking writes during a
                // selection long-press.
                let savedGRStates: [(UIGestureRecognizer, Bool)] = (cv.gestureRecognizers ?? []).map { ($0, $0.isEnabled) }
                for (gr, _) in savedGRStates { gr.isEnabled = false }

                // Attempt A: setContentOffset(animated:false)
                let pA0 = cv.contentOffset.y
                cv.setContentOffset(CGPoint(x: 0, y: max(0, expectedOffsetY)), animated: false)
                let pA1 = cv.contentOffset.y     // immediate readback (pre-runloop)
                cv.layoutIfNeeded()
                let pA2 = cv.contentOffset.y     // after layoutIfNeeded
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                let pA3 = cv.contentOffset.y     // after one runloop hop — if pA3 != pA2 someone wrote it back

                // Attempt B (only if A didn't reach target): direct assignment + runloop
                var pB0: CGFloat = -1, pB1: CGFloat = -1, pB2: CGFloat = -1
                if abs(pA3 - expectedOffsetY) > 1 {
                    pB0 = cv.contentOffset.y
                    cv.contentOffset = CGPoint(x: 0, y: max(0, expectedOffsetY))
                    pB1 = cv.contentOffset.y
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    pB2 = cv.contentOffset.y
                }

                for (gr, wasEnabled) in savedGRStates { gr.isEnabled = wasEnabled }
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT-A setContentOffset(animated:false) target=\(String(format: "%.1f", expectedOffsetY)) trace: pre=\(String(format: "%.1f", pA0)) postSet=\(String(format: "%.1f", pA1)) postLayout=\(String(format: "%.1f", pA2)) postRunloop=\(String(format: "%.1f", pA3))")
                if pB0 >= 0 {
                    chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT-B contentOffset= assignment target=\(String(format: "%.1f", expectedOffsetY)) trace: pre=\(String(format: "%.1f", pB0)) postSet=\(String(format: "%.1f", pB1)) postRunloop=\(String(format: "%.1f", pB2))")
                }
                // Final state for the page loop
                let postFinal = cv.contentOffset.y
                let postDelta = postFinal - expectedOffsetY
                chatScreenshotLogger.info("[Stage3-ReAnchor] \(ms()) FORCE-COMMIT FINAL offset=\(String(format: "%.1f", postFinal)) postDelta=\(String(format: "%.1f", postDelta)) (postDelta=0 means commit succeeded)")
            }
            guard totalH > 0 else {
                cv.contentOffset = savedOffset
                self.scrollMode = savedScrollMode
                self.clampAfterSessionLoad = savedClampAfterSessionLoad
                return nil
            }

            screenshotLogger.info("captureScrolling: turn=[\(Int(turnTopY)),\(Int(turnBottomY))] totalH=\(Int(totalH)) usableH=\(Int(usableH))")

            let scale = UIScreen.main.scale
            let cvWidth = cv.bounds.width

            // --- DEBUG: log appearance state ---
            let currentStyle = cv.traitCollection.userInterfaceStyle
            let windowStyle = cv.window?.traitCollection.userInterfaceStyle
            let windowOverride = cv.window?.overrideUserInterfaceStyle
            let cvOverride = cv.overrideUserInterfaceStyle
            screenshotLogger.info("captureScrolling [DEBUG] cv.traitCollection.userInterfaceStyle=\(currentStyle.rawValue) (0=unspec,1=light,2=dark)")
            screenshotLogger.info("captureScrolling [DEBUG] window.traitCollection.userInterfaceStyle=\(windowStyle?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] window.overrideUserInterfaceStyle=\(windowOverride?.rawValue ?? -1)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.overrideUserInterfaceStyle=\(cvOverride.rawValue)")
            screenshotLogger.info("captureScrolling [DEBUG] cv.backgroundColor=\(String(describing: cv.backgroundColor))")

            // Check superview/host backgrounds
            var sv = cv.superview
            var depth = 0
            while let v = sv, depth < 5 {
                let resolvedBg = v.backgroundColor?.resolvedColor(with: v.traitCollection)
                screenshotLogger.info("captureScrolling [DEBUG] superview[\(depth)] \(type(of: v)) bg=\(String(describing: resolvedBg)) overrideStyle=\(v.overrideUserInterfaceStyle.rawValue)")
                sv = v.superview
                depth += 1
            }

            // Resolve bg color and log it
            let bgResolved = UIColor.systemBackground.resolvedColor(with: cv.traitCollection)
            var bgR: CGFloat = 0; var bgG: CGFloat = 0; var bgB: CGFloat = 0; var bgA: CGFloat = 0
            bgResolved.getRed(&bgR, green: &bgG, blue: &bgB, alpha: &bgA)
            screenshotLogger.info("captureScrolling [DEBUG] resolved systemBackground RGBA=(\(bgR),\(bgG),\(bgB),\(bgA))")

            // Lock the collection view's appearance to its current mode
            let savedOverride = cv.overrideUserInterfaceStyle
            cv.overrideUserInterfaceStyle = currentStyle == .dark ? .dark : .light

            // The CV and its immediate parent have backgroundColor set to
            // black-transparent (UIColor(white:0, alpha:0)). On screen this
            // is invisible because the SwiftUI HostingView behind it provides
            // the real background. But drawHierarchy renders the CV subtree
            // in isolation — the black bg composites on top of our white fill,
            // producing a black screenshot. Temporarily swap to the correct
            // background color for the capture.
            let savedCvBg = cv.backgroundColor
            let savedParentBg = cv.superview?.backgroundColor
            cv.backgroundColor = bgResolved
            cv.superview?.backgroundColor = bgResolved

            // Final canvas — Use standard-range sRGB (8 bpc) — the default
            // UIGraphicsImageRendererFormat creates a wide-color
            // ExtendedSRGB 16 bpc bitmap, and many apps (WeChat, etc.)
            // render 16 bpc PNGs as black/white.
            // opaque = true ensures a solid background (no alpha channel)
            // so pasted images don't show as transparent/white.
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let finalSize = CGSize(width: cvWidth, height: totalH)
            let bg = bgResolved

            // Scroll through the turn range one page at a time. Each page:
            //   1. Scroll so `nextContentY` lands at the `cropTop` line
            //      (= topMask + navSafetyGap from the viewport top).
            //   2. Snapshot the full cv bounds.
            //   3. Crop the snapshot to [cropTop, cropTop + sliceH].
            //   4. Blit the crop into the final canvas at dstY.
            //   5. Advance by `usableH`.
            //
            // `cropTop` is the y-coordinate inside the viewport where the
            // usable (nav-bar-free) area starts. By scrolling so that
            // `nextContentY` sits exactly at `cropTop`, the crop always
            // starts exactly where the previous page's crop ended — no gap,
            // no overlap.
            // Snapshot each page into memory BEFORE entering the final
            // canvas renderer. Nesting `drawHierarchy(afterScreenUpdates:true)`
            // inside an outer `UIGraphicsImageRenderer.image { }` block can
            // produce black snapshots: the outer context is the current
            // graphics context, and `afterScreenUpdates:true` defers
            // rendering to a screen-update cycle that doesn't reliably
            // complete inside the nested renderer. Symptom was a stitched
            // image whose top pages were solid bg-color/black with only the
            // last page (drawn via the tail-clamp recovery path) showing
            // real content. Decouple the two phases: pass 1 collects page
            // snapshots with no outer graphics context active; pass 2
            // composites the collected snapshots into the final canvas.
            struct PageSlice {
                let snap: UIImage
                let viewportContentY: CGFloat
                let contentStart: CGFloat
                let contentEnd: CGFloat
            }
            var slices: [PageSlice] = []
            var drawnEndY: CGFloat = turnTopY

            /// Snapshot the current cv viewport, fill bg first.
            func snapshotViewport() -> UIImage {
                let pageSize = cv.bounds.size
                let pageFmt = UIGraphicsImageRendererFormat()
                pageFmt.scale = scale; pageFmt.opaque = true
                pageFmt.preferredRange = .standard
                let pr = UIGraphicsImageRenderer(size: pageSize, format: pageFmt)
                return pr.image { snapCtx in
                    bg.setFill()
                    snapCtx.fill(CGRect(origin: .zero, size: pageSize))
                    cv.drawHierarchy(in: CGRect(origin: .zero, size: pageSize), afterScreenUpdates: true)
                }
            }

            chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) BEGIN turnTopY=\(String(format: "%.1f", turnTopY)) turnBottomY=\(String(format: "%.1f", turnBottomY)) finalCanvas=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height)) scale=\(scale)")
            do {
                var nextContentY = turnTopY
                var lastActualY: CGFloat = -.greatestFiniteMagnitude
                var pageCount = 0

                while nextContentY < turnBottomY && pageCount < 200 {
                    pageCount += 1
                    let pageStart = CACurrentMediaTime()

                    // Place nextContentY at the cropTop line in the viewport.
                    let targetOffset = nextContentY - cropTop
                    let beforeOffset = cv.contentOffset.y
                    cv.contentOffset = CGPoint(x: 0, y: targetOffset)
                    cv.layoutIfNeeded()
                    cv.layer.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                    self.clearTextSelection(in: cv)

                    // Read back actual offset (UIKit clamps near scroll edges).
                    let actualY = cv.contentOffset.y + cropTop
                    let clampDelta = (cv.contentOffset.y) - targetOffset
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) nextContentY=\(String(format: "%.1f", nextContentY)) target=(offset=\(String(format: "%.1f", targetOffset))) before=\(String(format: "%.1f", beforeOffset)) after=\(String(format: "%.1f", cv.contentOffset.y)) clampDelta=\(String(format: "%.1f", clampDelta)) actualY=\(String(format: "%.1f", actualY))")
                    if actualY <= lastActualY + 0.5 && pageCount > 1 {
                        chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) BREAK — actualY=\(String(format: "%.1f", actualY)) <= lastActualY=\(String(format: "%.1f", lastActualY))+0.5 (no progress)")
                        break
                    }
                    lastActualY = actualY

                    let pageEndY = min(turnBottomY, actualY + usableH)
                    let sliceH = pageEndY - actualY
                    if sliceH <= 0 {
                        chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) BREAK — sliceH=\(String(format: "%.1f", sliceH)) <= 0")
                        break
                    }

                    let snapStart = CACurrentMediaTime()
                    let snap = snapshotViewport()
                    let snapMs = (CACurrentMediaTime() - snapStart) * 1000
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) page=\(pageCount) slice=[\(String(format: "%.1f", actualY)),\(String(format: "%.1f", pageEndY))] sliceH=\(String(format: "%.1f", sliceH)) snap=\(String(format: "%.0fx%.0f", snap.size.width, snap.size.height)) snapTime=\(String(format: "%.1f", snapMs))ms pageTime=\(String(format: "%.1f", (CACurrentMediaTime() - pageStart) * 1000))ms")

                    if pageCount <= 2, let cg = snap.cgImage,
                       let dp = cg.dataProvider, let data = dp.data,
                       let ptr = CFDataGetBytePtr(data) {
                        let bpp = cg.bitsPerPixel / 8
                        let bpr = cg.bytesPerRow
                        let sampleY = Int((cropTop + 10) * scale)
                        let sampleX = Int(10 * scale)
                        if sampleY < cg.height && sampleX < cg.width {
                            let offset = sampleY * bpr + sampleX * bpp
                            let r = ptr[offset]; let g = ptr[offset+1]; let b = ptr[offset+2]
                            let a = bpp >= 4 ? ptr[offset+3] : 255
                            self.screenshotLogger.info("captureScrolling [DEBUG] page\(pageCount) snap pixel(\(sampleX),\(sampleY)) RGBA=(\(r),\(g),\(b),\(a)) bpp=\(bpp) size=\(cg.width)x\(cg.height) colorSpace=\(String(describing: cg.colorSpace?.name))")
                        }
                    }

                    slices.append(PageSlice(snap: snap, viewportContentY: actualY - cropTop,
                                            contentStart: actualY, contentEnd: pageEndY))
                    drawnEndY = max(drawnEndY, pageEndY)

                    if pageEndY >= turnBottomY { break }
                    nextContentY = actualY + usableH
                }

                // Tail-clamp recovery (see commit 97af7f35): if contentOffset
                // clamping prevented the loop from reaching turnBottomY,
                // scroll to maxScrollY and snapshot the missing range.
                if drawnEndY < turnBottomY - 0.5 {
                    let maxScrollY = max(0, cv.contentSize.height - cv.bounds.height)
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) tail-clamp NEEDED drawnEndY=\(String(format: "%.1f", drawnEndY)) < turnBottomY=\(String(format: "%.1f", turnBottomY)) maxScrollY=\(String(format: "%.1f", maxScrollY))")
                    cv.contentOffset = CGPoint(x: 0, y: maxScrollY)
                    cv.layoutIfNeeded()
                    cv.layer.displayIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                    self.clearTextSelection(in: cv)

                    let snap = snapshotViewport()
                    let tailContentEnd = min(turnBottomY, maxScrollY + cv.bounds.height)
                    slices.append(PageSlice(snap: snap, viewportContentY: maxScrollY,
                                            contentStart: drawnEndY, contentEnd: tailContentEnd))
                    self.screenshotLogger.info("captureScrolling: tail-clamp recovery added [\(Int(drawnEndY)),\(Int(tailContentEnd))] (was missing)")
                    drawnEndY = max(drawnEndY, tailContentEnd)
                }

                self.screenshotLogger.info("captureScrolling: \(pageCount) pages → \(Int(finalSize.width))x\(Int(finalSize.height)) drawnEnd=\(Int(drawnEndY))/turnBottom=\(Int(turnBottomY))")
                chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) END pages=\(pageCount) slices=\(slices.count) drawnEnd=\(String(format: "%.1f", drawnEndY)) turnBottom=\(String(format: "%.1f", turnBottomY)) coverageGap=\(String(format: "%.1f", turnBottomY - drawnEndY))")
                // SLICE-LEVEL DIAGNOSTIC: dump every slice's content
                // start/end + viewport origin. If the symptom is top-blank,
                // the first slice's contentStart should equal turnTopY. If
                // it's > turnTopY, we know the gap exactly.
                for (i, s) in slices.enumerated() {
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) slice[\(i)] contentStart=\(String(format: "%.1f", s.contentStart)) contentEnd=\(String(format: "%.1f", s.contentEnd)) viewportContentY=\(String(format: "%.1f", s.viewportContentY)) snap=\(String(format: "%.0fx%.0f", s.snap.size.width, s.snap.size.height))")
                }
                if let firstSlice = slices.first {
                    let topGap = firstSlice.contentStart - turnTopY
                    chatScreenshotLogger.info("[Stage4-PageLoop] \(ms()) TOP-GAP=\(String(format: "%.1f", topGap)) (first slice content start minus turnTopY; positive = top of turn missing from canvas)")
                }
            }

            // Pass 2: composite the collected page snapshots into the final
            // canvas. All page bitmaps already exist as independent
            // UIImages — no nested drawHierarchy here.
            chatScreenshotLogger.info("[Stage5-Composite] \(ms()) BEGIN finalCanvas=\(String(format: "%.0fx%.0f", finalSize.width, finalSize.height)) sliceCount=\(slices.count)")
            let image = renderer(size: finalSize, format: format, bg: bg) { _ in
                for (i, slice) in slices.enumerated() {
                    let sliceH = slice.contentEnd - slice.contentStart
                    guard sliceH > 0, let cg = slice.snap.cgImage else {
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] SKIP sliceH=\(String(format: "%.1f", sliceH)) hasCG=\(slice.snap.cgImage != nil)")
                        continue
                    }
                    let viewportYStart = slice.contentStart - slice.viewportContentY
                    let srcPx = CGRect(
                        x: 0,
                        y: viewportYStart * scale,
                        width: cvWidth * scale,
                        height: sliceH * scale
                    )
                    let dstY = slice.contentStart - turnTopY
                    if let cropped = cg.cropping(to: srcPx) {
                        let dst = CGRect(x: 0, y: dstY,
                                         width: cvWidth, height: sliceH)
                        UIImage(cgImage: cropped, scale: scale, orientation: .up).draw(in: dst)
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] BLIT viewportYStart=\(String(format: "%.1f", viewportYStart)) srcPx=\(String(format: "%.0fx%.0f@%.0f,%.0f", srcPx.width, srcPx.height, srcPx.minX, srcPx.minY)) dstY=\(String(format: "%.1f", dstY)) dstH=\(String(format: "%.1f", sliceH))")
                    } else {
                        self.chatScreenshotLogger.info("[Stage5-Composite] \(ms()) slice[\(i)] CROP FAILED srcPx=\(String(format: "%.0fx%.0f@%.0f,%.0f", srcPx.width, srcPx.height, srcPx.minX, srcPx.minY)) cgSize=\(cg.width)x\(cg.height)")
                    }
                }
            }
            chatScreenshotLogger.info("[Stage5-Composite] \(ms()) END image=\(String(format: "%.0fx%.0f", image.size.width, image.size.height)) scale=\(image.scale)")

            cv.overrideUserInterfaceStyle = savedOverride
            cv.backgroundColor = savedCvBg
            cv.superview?.backgroundColor = savedParentBg

            // DEBUG: sample final image pixel
            if let cg = image.cgImage,
               let dp = cg.dataProvider, let data = dp.data,
               let ptr = CFDataGetBytePtr(data) {
                let bpp = cg.bitsPerPixel / 8
                let bpr = cg.bytesPerRow
                // Sample at (10, 10) — should be the background
                let offset = 10 * bpr + 10 * bpp
                let r = ptr[offset]; let g = ptr[offset+1]; let b = ptr[offset+2]
                let a = bpp >= 4 ? ptr[offset+3] : 255
                screenshotLogger.info("captureScrolling [DEBUG] FINAL image pixel(10,10) RGBA=(\(r),\(g),\(b),\(a)) bpp=\(bpp) size=\(cg.width)x\(cg.height)")
            }

            cv.contentOffset = savedOffset
            cv.layoutIfNeeded()
            self.scrollMode = savedScrollMode
            self.clampAfterSessionLoad = savedClampAfterSessionLoad
            chatScreenshotLogger.info("[Stage6-Exit] \(ms()) restored cv.contentOffset=\(String(format: "%.1f", savedOffset.y)) scrollMode=\(savedScrollMode == .autoScrolling ? "auto" : "browse") returning image=\(String(format: "%.0fx%.0f", image.size.width, image.size.height))")

            return image
        }

        private func renderer(size: CGSize, format: UIGraphicsImageRendererFormat, bg: UIColor,
                              actions: @escaping (UIGraphicsImageRendererContext) -> Void) -> UIImage {
            let r = UIGraphicsImageRenderer(size: size, format: format)
            return r.image { ctx in
                bg.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                actions(ctx)
            }
        }

        // MARK: - UICollectionViewDataSourcePrefetching

        func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
            guard let vm, let layout = viewController?.messageListLayout else { return }
            // Items below come from previousSnapshotIds (snapshot-locked) — the
            // messages they're resolved against must be the SAME locked array,
            // or a concurrent loadSession() swap makes every lookup miss and
            // estimates collapse to the 44pt fallback. [T-ios-blocks-lost-render]
            let messages = snapshotMessages.isEmpty ? vm.messages : snapshotMessages
            let width = maxContentWidth
            for indexPath in indexPaths {
                let index = indexPath.item
                // Skip if we already have a measured or precalculated height.
                // estimateItemHeight calls NSAttributedString.boundingRect which invokes
                // CoreText font shaping (GSUB lookups) — for complex markdown blocks this
                // can take hundreds of ms per cell and accumulate into a watchdog crash
                // when the user scrolls back through long history. See 3a9fb98 for the
                // matching configureCell guard.
                guard layout.cachedHeight(at: index) == nil,
                      !layout.hasPrecalcHeight(at: index) else { continue }
                guard index < previousSnapshotIds.count else { continue }
                let item = previousSnapshotIds[index]
                let est = Self.estimateItemHeight(item, messages: messages, width: item.segmentID == nil ? width : collectionView.bounds.width,
                                                  maxContentWidth: maxContentWidth,
                                                  questionContainerWidth: collectionView.bounds.width,
                                                  simpleRow: simpleRows[item])
                layout.setEstimatedHeight(est, at: index)
            }
        }

        // MARK: - UIScrollViewDelegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            invalidatePositionRequests()
            AppLogger(category: "ScrollDiag").info("[ScrollDiag][willBeginDragging] offset=\(String(format: "%.0f", scrollView.contentOffset.y)) contentSize=\(String(format: "%.0f", scrollView.contentSize.height)) visibleCells=\(viewController?.collectionView?.visibleCells.count ?? -1)")
            #if DEBUG
            // [DecelDisplayLink] Safety: if the user grabs again mid-decel, stop
            // the previous link so it doesn't keep ticking under the new gesture.
            stopDecelDisplayLink()
            #endif
            scrollMode = .userBrowsing
            // Cancel session-load clamp immediately — user has started interacting.
            clampAfterSessionLoad = false
            viewController?.messageListLayout?.deferSelfSizing = true
            vm?.setStreamingUIUpdatesSuspended(true)
        }

        func scrollViewWillEndDragging(
            _ scrollView: UIScrollView,
            withVelocity velocity: CGPoint,
            targetContentOffset: UnsafeMutablePointer<CGPoint>
        ) {
            // [ScrollDecel] Fires the instant the finger lifts and UIKit has
            // projected where the deceleration will land. Logs the launch
            // velocity + projected target so the upcoming decel can be
            // correlated to the content region it's about to render.
            decelTargetOffset = targetContentOffset.pointee.y
            #if DEBUG
            AppLogger(category: "ScrollDecel").info("[ScrollDecel][willEndDragging] vy=\(String(format: "%.0f", velocity.y))pt/s offset=\(String(format: "%.0f", scrollView.contentOffset.y)) → target=\(String(format: "%.0f", decelTargetOffset)) projDist=\(String(format: "%.0f", decelTargetOffset - scrollView.contentOffset.y)) cs=\(String(format: "%.0f", scrollView.contentSize.height))")
            #endif
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                settleAfterInteraction(scrollView)
            }
        }

        func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
            // [ScrollDecel] DECELERATION START — the marker the analysis hangs
            // off. Every subsequent slow frame is logged as "+Xms into decel".
            let now = CACurrentMediaTime()
            decelStartTime = now
            decelLastFrameTime = now
            decelStartOffset = scrollView.contentOffset.y
            decelFrameCount = 0
            decelSlowFrameCount = 0
            #if DEBUG
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ScrollDecel").info("[ScrollDecel][BEGIN] offset=\(String(format: "%.0f", decelStartOffset)) target=\(String(format: "%.0f", decelTargetOffset)) decelDist=\(String(format: "%.0f", decelTargetOffset - decelStartOffset)) visibleCells=\(visibleN) deferSelfSizing=\((viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
            // [DecelDisplayLink] Start the real-frame-rate meter only for this
            // decel phase. Drops/summary go to the log; CADisplayLink is removed
            // in scrollViewDidEndDecelerating below.
            startDecelDisplayLink()
            #endif
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            // [ScrollDecel] DECELERATION END — summarize the phase: total
            // duration, frames, how many were slow (dropped), final offset.
            if decelStartTime > 0 {
                #if DEBUG
                let dur = (CACurrentMediaTime() - decelStartTime) * 1000
                AppLogger(category: "ScrollDecel").info("[ScrollDecel][END] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelFrameCount) slowFrames=\(self.decelSlowFrameCount) offset \(String(format: "%.0f→%.0f", self.decelStartOffset, scrollView.contentOffset.y)) (target was \(String(format: "%.0f", self.decelTargetOffset)))")
                // [DecelDisplayLink] Print the REAL frame-rate summary for this
                // decel and stop the link. If actualFps≈vsync and drops=0 the
                // visual "jitter" wasn't a dropped frame at all.
                logDecelDisplayLinkSummary()
                stopDecelDisplayLink()
                #endif
                decelStartTime = 0
            }
            DispatchQueue.main.async { [weak self] in
                self?.settleAfterInteraction(scrollView)
            }
        }

        /// [ScrollDecel] Called from scrollViewDidScroll. While decelerating,
        /// measures the gap since the previous frame; a gap above the threshold
        /// is a dropped/janky frame and gets logged with how far into the decel
        /// it happened, the current offset/scroll direction, and how many cells
        /// are on screen (heavy cells = expensive sizeThatFits). This is the
        /// "which stage of the decel started the costly render" signal.
        private func logDecelFrameIfSlow(_ scrollView: UIScrollView) {
            #if DEBUG
            guard decelStartTime > 0, scrollView.isDecelerating else { return }
            let now = CACurrentMediaTime()
            let gap = now - decelLastFrameTime
            decelLastFrameTime = now
            decelFrameCount += 1
            guard gap > decelSlowFrameThreshold else { return }
            decelSlowFrameCount += 1
            let sinceStart = (now - decelStartTime) * 1000
            let off = scrollView.contentOffset.y
            let dir = off >= decelStartOffset ? "↓" : "↑"
            let visibleN = viewController?.collectionView?.visibleCells.count ?? -1
            AppLogger(category: "ScrollDecel").warning("[ScrollDecel][SLOW-FRAME] +\(String(format: "%.0f", sinceStart))ms into decel gap=\(String(format: "%.0f", gap * 1000))ms offset=\(String(format: "%.0f", off))\(dir) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - off)) visibleCells=\(visibleN) frame#\(self.decelFrameCount)")
            #endif
        }

        // MARK: - [DecelDisplayLink] CADisplayLink frame meter (DEBUG only)
        //
        // The existing `[ScrollDecel] SLOW-FRAME` log measures the wall-clock gap
        // between consecutive `scrollViewDidScroll` callbacks. That is NOT the
        // same as a real dropped frame: during the tail of a decel UIKit stops
        // calling scrollViewDidScroll for the frames where contentOffset doesn't
        // visually change (snap-to-target), so a 250ms "gap" can happen with the
        // main thread completely idle and CADisplayLink ticking 16.7ms steady —
        // a false positive for jank. Run a CADisplayLink only during the decel
        // and measure actual frame intervals; >1.5× the expected vsync interval
        // is a real dropped frame.
        #if DEBUG
        private var decelDisplayLink: CADisplayLink?
        private var decelDLLastTimestamp: CFTimeInterval = 0
        private var decelDLFrames: Int = 0
        private var decelDLDrops: Int = 0
        private var decelDLMinGapMs: Double = .infinity
        private var decelDLMaxGapMs: Double = 0
        private var decelDLExpectedMs: Double = 16.67

        @objc private func decelDisplayLinkTick(_ link: CADisplayLink) {
            // The first tick has no prior timestamp — establish the baseline + expected interval.
            if decelDLLastTimestamp == 0 {
                decelDLLastTimestamp = link.timestamp
                decelDLExpectedMs = (link.targetTimestamp - link.timestamp) * 1000
                return
            }
            let gapMs = (link.timestamp - decelDLLastTimestamp) * 1000
            decelDLLastTimestamp = link.timestamp
            decelDLFrames += 1
            if gapMs < decelDLMinGapMs { decelDLMinGapMs = gapMs }
            if gapMs > decelDLMaxGapMs { decelDLMaxGapMs = gapMs }
            // A real dropped frame: gap exceeds 1.5× the expected vsync interval.
            // At 120Hz expected≈8.33ms → threshold≈12.5ms; at 60Hz ≈16.67ms → 25ms.
            let dropThreshold = decelDLExpectedMs * 1.5
            if gapMs > dropThreshold {
                decelDLDrops += 1
                let cv = viewController?.collectionView
                let off = cv?.contentOffset.y ?? 0
                let sinceStart = (CACurrentMediaTime() - decelStartTime) * 1000
                let dropped = Int((gapMs / decelDLExpectedMs).rounded()) - 1
                AppLogger(category: "ScrollDecel").warning("[DecelDisplayLink][DROP] +\(String(format: "%.0f", sinceStart))ms into decel gap=\(String(format: "%.1f", gapMs))ms (expected \(String(format: "%.1f", self.decelDLExpectedMs))ms, ~\(dropped) frame(s) dropped) offset=\(String(format: "%.0f", off)) remainToTarget=\(String(format: "%.0f", self.decelTargetOffset - off)) frame#\(self.decelDLFrames)")
            }
        }

        private func startDecelDisplayLink() {
            stopDecelDisplayLink()
            decelDLLastTimestamp = 0
            decelDLFrames = 0
            decelDLDrops = 0
            decelDLMinGapMs = .infinity
            decelDLMaxGapMs = 0
            let link = CADisplayLink(target: self, selector: #selector(decelDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            decelDisplayLink = link
        }

        private func stopDecelDisplayLink() {
            decelDisplayLink?.invalidate()
            decelDisplayLink = nil
        }

        private func logDecelDisplayLinkSummary() {
            guard decelDLFrames > 0 else { return }
            let dur = (CACurrentMediaTime() - decelStartTime) * 1000
            let actualFps = decelDLFrames > 0 ? Double(decelDLFrames) / (dur / 1000) : 0
            let minGap = decelDLMinGapMs.isFinite ? decelDLMinGapMs : 0
            AppLogger(category: "ScrollDecel").info("[DecelDisplayLink][SUMMARY] dur=\(String(format: "%.0f", dur))ms frames=\(self.decelDLFrames) drops=\(self.decelDLDrops) actualFps=\(String(format: "%.1f", actualFps)) gapRange=[\(String(format: "%.1f", minGap))..\(String(format: "%.1f", self.decelDLMaxGapMs))]ms expected=\(String(format: "%.1f", self.decelDLExpectedMs))ms")
        }
        #endif

        /// Track last logged offset to detect jumps after settle.
        private var lastLoggedOffset: CGFloat = 0
        private var settleJustFinished = false

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // [ScrollDecel] Detect dropped frames during the deceleration phase
            // (cheap: early-returns unless decelerating + frame gap exceeded).
            logDecelFrameIfSlow(scrollView)
            #if DEBUG
            // [T-ios-scroll-metrics-ring] Per-frame offset/contentSize sample —
            // lets the pulled trace reconstruct exactly when visible content
            // shifted vs when the offset moved (jitter = the two disagreeing).
            ScrollMetricsRecorder.shared.record(
                kind: "scroll", a: scrollView.contentOffset.y,
                b: scrollView.contentSize.height,
                pos: scrollView.isDecelerating ? "decel" : (scrollView.isTracking ? "drag" : "idle"),
                offset: scrollView.contentOffset.y)
            #endif
            if let vm {
                // IMPORTANT: only write when the value actually changes.
                // `isNearBottom` is `@Published`, and every write broadcasts
                // `objectWillChange` to every SwiftUI view observing the VM —
                // triggering a full AttributeGraph invalidation+re-evaluation
                // pass on the SwiftUI update thread. On iPhone 8 this was
                // burning 100% of one CPU core every scroll frame.
                let nb = isNearBottom()
                if vm.isNearBottom != nb {
                    #if DEBUG
                    // Diagnostics: record every isNearBottom TRANSITION with the
                    // scroll position and the user-turn the viewport is in, plus
                    // the resulting scroll-to-bottom visibility (!messages.empty &&
                    // !isNearBottom). Only fires on change, so it stays off the
                    // per-frame hot path. ScrollMetricsRecorder is DEBUG-only.
                    let turn = currentViewportUserTurn()
                    ScrollMetricsRecorder.shared.record(kind: "nbChange",
                        idx: turn.index, a: nb ? 1 : 0, b: Double(turn.total),
                        pos: "buttonsVisible=\(!vm.messages.isEmpty && !nb)",
                        offset: Double(scrollView.contentOffset.y),
                        note: Self.nbDump(viewController?.collectionView))
                    #endif
                    vm.isNearBottom = nb
                }
                vm.contentOffsetYSignal.send(scrollView.contentOffset.y)
            }
            // Detect offset jumps right after settle
            if settleJustFinished {
                let delta = scrollView.contentOffset.y - lastLoggedOffset
                if abs(delta) > 2 {
                    AppLogger(category: "Settle").debug("[Settle] POST-SETTLE JUMP offset \(String(format: "%.1f→%.1f", lastLoggedOffset, scrollView.contentOffset.y)) delta=\(String(format: "%.1f", delta)) tracking=\(scrollView.isTracking) decel=\(scrollView.isDecelerating) contentSize=\(String(format: "%.1f", scrollView.contentSize.height))")
                    settleJustFinished = false
                }
            }
            // [ScrollStall] Per-second scroll trajectory: offset, distance moved
            // since last flush, mode, tracking/decel state. Helps correlate
            // hitches with offset bursts.
            scrollSamples += 1
            let now = CACurrentMediaTime()
            if now - lastScrollFlush > 1.0 {
                let off = scrollView.contentOffset.y
                let dist = abs(off - lastScrollFlushOffset)
                AppLogger(category: "ScrollStall").debug("[SCR] last1s samples=\(scrollSamples) offset=\(String(format: "%.0f", off)) Δdist=\(String(format: "%.0f", dist)) cs=\(String(format: "%.0f", scrollView.contentSize.height)) mode=\(self.scrollMode == .autoScrolling ? "auto" : "browse") tracking=\(scrollView.isTracking ? 1 : 0) decel=\(scrollView.isDecelerating ? 1 : 0) deferred=\((self.viewController?.messageListLayout?.deferSelfSizing ?? false) ? 1 : 0)")
                scrollSamples = 0
                lastScrollFlushOffset = off
                lastScrollFlush = now
            }
            // [T-foldable-scroll] Keep the reader's place current.
            rememberScrollAnchor()
        }
        private var scrollSamples = 0
        private var lastScrollFlushOffset: CGFloat = 0
        private var lastScrollFlush: CFTimeInterval = 0

        // [ScrollDecel] Deceleration-phase instrumentation. Lets us pin a
        // dropped frame to "Xms into the decel, at offset Y" so the
        // scroll-jank trace's micro-hangs can be aligned to the exact moment
        // and content region where the costly render started.
        private var decelStartTime: CFTimeInterval = 0
        private var decelStartOffset: CGFloat = 0
        private var decelTargetOffset: CGFloat = 0
        private var decelLastFrameTime: CFTimeInterval = 0
        private var decelFrameCount = 0
        private var decelSlowFrameCount = 0
        /// A frame gap above this (seconds) during deceleration is a dropped
        /// frame worth logging. ~32ms ≈ two missed frames at 60Hz / several at
        /// 120Hz — low enough to catch the jitter, high enough to stay quiet
        /// on smooth scrolls.
        private let decelSlowFrameThreshold: CFTimeInterval = 0.032

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard isAnimatingScrollToBottom, let cv = viewController?.collectionView, scrollView === cv else { return }
            isAnimatingScrollToBottom = false
            guard scrollMode == .autoScrolling, cv.window != nil,
                  !cv.isTracking, !cv.isDragging, !cv.isDecelerating, userMessageViewportAnchor == nil else { return }
            // The explicit follow remains owed until the animation ends, even
            // if every height update and coalesced request arrived mid-flight.
            enqueuePosition(.explicit)
            if viewportGeometryCommitDepth == 0, !isFlushing, !resolvingPosition { cv.layoutIfNeeded() }
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            scrollMode = .userBrowsing
        }

        private func settleAfterInteraction(_ scrollView: UIScrollView) {
            defer { scheduleTranscriptUpdate() }
            // Re-acquire auto-scroll only when the user settled essentially at
            // the bottom (tight threshold), not merely "near" it. This stops
            // small trackpad scrolls on iPad from snapping back to the bottom
            // and jittering. [T-ios-trackpad-scroll-jitter]
            let atBottom = isWithinBottom(reacquireAutoScrollThreshold)
            let nearBottom = isNearBottom()
            if atBottom {
                scrollMode = .autoScrolling
            }
            guard let layout = viewController?.messageListLayout,
                  let cv = viewController?.collectionView else { return }

            let deferredCount = layout.deferredHeightCount
            AppLogger(category: "Settle").debug("[Settle] BEGIN mode=\(scrollMode == .autoScrolling ? "auto" : "browse") nearBottom=\(nearBottom) offset=\(String(format: "%.1f", cv.contentOffset.y)) contentSize=\(String(format: "%.1f", cv.contentSize.height)) deferredHeights=\(deferredCount) hasPendingSnapshot=\(hasPendingSnapshot)")

            // Re-enable self-sizing so future layout passes use real heights.
            layout.deferSelfSizing = false

            // [SettleJitter] Evidence capture (H1): the flush below re-flows
            // frames from corrected heights but restores only the numeric
            // offset — if cells ABOVE the viewport changed height, the same
            // offset now shows different content. Anchor on the top visible
            // cell's screen-relative y before/after to quantify the jump the
            // user actually sees at decel end.
            let anchorIP = cv.indexPathsForVisibleItems.min()
            let anchorPreY = anchorIP.flatMap { layout.layoutAttributesForItem(at: $0)?.frame.minY }

            let savedOffset = cv.contentOffset.y
            isFlushing = true
            layout.applyDeferredHeights()

            layout.suppressContentOffsetAdjustment = true
            layout.invalidateLayout()
            layout.suppressContentOffsetAdjustment = false
            isFlushing = false

            // Restore offset
            if scrollMode == .userBrowsing {
                cv.contentOffset.y = savedOffset
            }

            // [SettleJitter] Post-flush: same anchor item, new frame. screenΔ
            // is the on-screen displacement of the content the user is looking
            // at (0 = no visible jitter from the settle flush).
            if let ip = anchorIP, let preY = anchorPreY {
                cv.layoutIfNeeded()
                let postY = layout.layoutAttributesForItem(at: ip)?.frame.minY ?? preY
                let screenDelta = (postY - cv.contentOffset.y) - (preY - savedOffset)
                #if DEBUG
                // [T-ios-scroll-metrics-ring]
                ScrollMetricsRecorder.shared.record(
                    kind: "settle", idx: ip.item, a: screenDelta, b: postY - preY,
                    offset: Double(cv.contentOffset.y),
                    note: String(format: "savedOff=%.0f", savedOffset))
                #endif
                if abs(screenDelta) > 0.5 {
                    AppLogger(category: "SettleJitter").info("[SettleJitter][settle-shift] anchor=idx\(ip.item) screenΔ=\(String(format: "%+.1f", screenDelta)) frameY \(String(format: "%.0f", preY))→\(String(format: "%.0f", postY)) offset \(String(format: "%.0f", savedOffset))→\(String(format: "%.0f", cv.contentOffset.y))")
                }
            }

            vm?.setStreamingUIUpdatesSuspended(false)

            if hasPendingSnapshot {
                DispatchQueue.main.async { [weak self] in
                    self?.flushPendingSnapshotIfNeeded(caller: "settle")
                }
            }

            lastLoggedOffset = cv.contentOffset.y
            settleJustFinished = true
            // Auto-clear after 500ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.settleJustFinished = false
            }
            AppLogger(category: "Settle").debug("[Settle] END offset=\(String(format: "%.1f", cv.contentOffset.y)) contentSize=\(String(format: "%.1f", cv.contentSize.height))")
        }

    }
}

// MARK: - Tool Detail Sheet Presenter

/// Holds the state for the tool detail sheet, presented from a transparent overlay
/// on MessageListViewController — outside the UIHostingConfiguration cell tree.
/// This avoids the cell's `.transaction { disablesAnimations = true }` which would
/// suppress the sheet's slide-up animation, and prevents the double-present crash
/// caused by multiple cell bindings re-evaluating on shared state changes.
private final class ToolSheetPresenter: ObservableObject {
    struct SheetData: Identifiable {
        let id: UUID
        let block: AssistantBlock
        let toolBlocks: [AssistantBlock]
        let toolSnapshots: [ToolSnapshotItem]
        let browserPool: BrowserTabPool?
        let sessionId: String?
        let onBrowserTakeover: () -> Void
        let onTakeoverDone: () -> Void
    }

    @Published var sheetData: SheetData?
    var onDismiss: (() -> Void)?
}

// MARK: - Compact Summary Sheet Presenter

/// Same overlay pattern as ToolSheetPresenter — presents the compact summary
/// sheet outside the cell tree so `.transaction { disablesAnimations }` does
/// not suppress the sheet's slide-up animation.
private final class CompactSummaryPresenter: ObservableObject {
    @Published var summary: String?
    /// Forwarded into CompactSummarySheet so its "Revert Compact" button can
    /// invoke the view-model's revertCompact() without the sheet importing it.
    var onRevert: (() -> Void)?
}

// MARK: - Quoted Message Preview Presenter

/// [T-chat-quote-reply] Same overlay pattern as the compact summary: the
/// sheet lives outside the collection cell tree so its presentation is not
/// swallowed by the cell's disabled animations.
private final class QuotePreviewPresenter: ObservableObject {
    struct Preview: Identifiable {
        let id = UUID()
        let text: String
    }
    @Published var preview: Preview?
}

/// Transparent SwiftUI view that owns the .sheet() modifier.
/// Installed as a child UIHostingController on MessageListViewController,
/// outside any UIHostingConfiguration cell tree.
private struct SheetOverlayView: View {
    @ObservedObject var toolPresenter: ToolSheetPresenter
    @ObservedObject var compactPresenter: CompactSummaryPresenter
    @ObservedObject var quotePresenter: QuotePreviewPresenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $toolPresenter.sheetData) { data in
                ToolLiveSheet(
                    toolBlocks: data.toolBlocks,
                    initialIdx: data.toolBlocks.firstIndex(where: { $0.id == data.block.id }) ?? 0,
                    toolSnapshots: data.toolSnapshots,
                    browserPool: data.browserPool,
                    onBrowserTakeover: data.onBrowserTakeover,
                    onTakeoverDone: data.onTakeoverDone
                )
                .environment(\.chatSessionId, data.sessionId)
            }
            .onChange(of: toolPresenter.sheetData?.id) { newVal in
                if newVal == nil {
                    toolPresenter.onDismiss?()
                }
            }
            .sheet(isPresented: Binding(
                get: { compactPresenter.summary != nil },
                set: { if !$0 { compactPresenter.summary = nil } }
            )) {
                CompactSummarySheet(
                    summary: compactPresenter.summary ?? "",
                    onRevert: compactPresenter.onRevert
                )
            }
            .sheet(item: $quotePresenter.preview) { preview in
                QuotedMessagePreviewSheet(text: preview.text)
            }
    }
}
