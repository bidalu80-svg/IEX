// Adapted from OpenMinis/OpenMinis 1a71df0f381cefde80bf912b723de6f9831bc177.
// GPL-3.0; see docs/third-party/card-source-attribution.md and OpenMinis-LICENSE.
import SwiftUI
import UIKit
import PDFKit
import CoreText

private let logger = AppLogger(category: "ChatExport")

private struct ChatSnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var chatSnapshotRendering: Bool {
        get { self[ChatSnapshotRenderingKey.self] }
        set { self[ChatSnapshotRenderingKey.self] = newValue }
    }
}

private func isShareCallback(_ message: ChatMessage) -> Bool {
    message.role == .user && (message.content.hasPrefix("[子代理任务结束 · ")
        || message.content.hasPrefix("[子代理进度 · "))
}

/// Freeze both levels of reference models before opening the picker. Streaming,
/// search navigation and disclosure changes in the live chat cannot alter exports.
@MainActor enum ChatShareSnapshot {
    static func request(messages: [ChatMessage], title: String, vm: AIChatViewModel,
                        messageId: UUID? = nil) -> ChatShareRequest {
        let frozen = messages.map(copy)
        let enabled = (UserDefaults.standard.object(forKey: ConsecutiveToolCallsPolicy.preferenceKey) as? Bool)
            ?? ConsecutiveToolCallsPolicy.defaultEnabled
        let cells = ChatExportContent.cells(for: frozen)
        let folded = ChatExportContent.cells(for: frozen, foldTools: true)
        let visible = ChatExportContent.cells(for: frozen, foldTools: enabled, preserveDisclosure: true, disclosureEnabled: enabled)
        let startsFolded = visible.contains { $0.kind == .taskHeader && $0.stepsCollapsed }
        let unit = visible.first(where: { $0.messageId == messageId })?.unitId
        return ChatShareRequest(cells: cells, foldedCells: folded, initialCells: visible, startsFolded: startsFolded,
                                messages: frozen, initialSelection: ChatShareCells.roundSelection(unit: unit, in: visible),
                                title: title, vm: vm)
    }

    static func copy(_ source: ChatMessage) -> ChatMessage {
        let blocks = source.blocks.map { source -> AssistantBlock in
            let block = AssistantBlock(kind: source.kind, content: source.content,
                                       toolStatus: source.toolStatus, toolUseId: source.toolUseId, id: source.id)
            block.imageFilePath = source.imageFilePath
            block.visualizationSelections = source.visualizationSelections
            block.browserURL = source.browserURL
            block.toolSummary = source.toolSummary
            block.toolDuration = source.toolDuration
            block.toolInputArgs = source.toolInputArgs
            block.questionCard = source.questionCard
            block.isQuestionCardExpanded = source.isQuestionCardExpanded
            block.streamingFileContent = source.streamingFileContent
            block.isThinkingExpanded = source.isThinkingExpanded
            block.thinkingDuration = source.thinkingDuration
            block.thinkingStartTime = nil
            block.isToolGroupExpanded = source.isToolGroupExpanded
            return block
        }
        let result = ChatMessage(role: source.role, content: source.content, blocks: blocks,
                                 isQueued: source.isQueued, timestamp: source.timestamp, id: source.id)
        result.error = source.error
        result.attachments = source.attachments
        result.inputAttachments = source.inputAttachments
        result.usage = source.usage
        result.firstTokenLatency = source.firstTokenLatency
        result.taskDuration = source.taskDuration
        result.streamInterruptCount = source.streamInterruptCount
        result.isCompactedHistory = source.isCompactedHistory
        result.isAwaitingModelResponse = source.isAwaitingModelResponse
        result.isUserTextExpanded = true
        result.isStepsCollapsed = source.isStepsCollapsed
        return result
    }
}

extension TableAttachment {
    /// Uses the same font and padding measurement as the live table layout.
    func naturalTableWidth() -> CGFloat {
        var widths = [CGFloat](repeating: 80, count: alignments.count)
        for (rowIndex, row) in rows.enumerated() {
            let font = UIFont.systemFont(ofSize: theme.baseFontSize, weight: rowIndex == 0 ? .semibold : .regular)
            for (index, cell) in row.cells.enumerated() where widths.indices.contains(index) {
                let width = (ChatSearchMarkdownText.inlineText(cell.content) as NSString).size(withAttributes: [.font: font]).width
                widths[index] = max(widths[index], ceil(width) + Self.cellPaddingH * 2 + 12)
            }
        }
        return widths.reduce(0, +)
    }
}

// [T-multi-select-share] Renders the selected cells of a chat into one long PNG or a
// paged, vector PDF.
//
// Each group of selected cells (one question, or the selected pieces of one reply) is
// laid out offscreen in its own hosting view using the chat's OWN row views
// (ChatShareCellContent → ChatMessageRow / AssistantBlockView), so the export looks
// like the session list; it is rendered and thrown away before the next group. That
// lets any selection be shared (the old "Copy Screenshot" stitched a live scroll of
// one question + answer), keeps peak memory to one group, and lets the PDF draw text
// as vector glyphs (drawVector).

struct ChatExportOptions: Equatable {
    enum Format: String, CaseIterable { case image, pdf }
    var format: Format = .image
    /// Lay the chat out at iPad width instead of the phone's, so wide tables get room
    /// (they plan their columns exactly as the chat does at that width).
    var wideLayout = false
    /// Dark appearance; the preview starts from the app's current one.
    var dark = false
    /// Adaptive table width: each table at its natural width, the page widening to
    /// the widest (capped); independent of the phone / iPad reading width.
    var adaptiveTables = false
    /// [T-share-hide-title] No title header: the export starts at the first message,
    /// and the title is left out of the PDF footer, its metadata and the file name.
    var hideHeader = false
}

enum ChatExportError: LocalizedError {
    case noWindow
    case nothingToExport
    case imageTooLarge
    case writeFailed
    case attachmentNotReady

    var errorDescription: String? {
        switch self {
        case .noWindow, .writeFailed: return ShareLocalized("Couldn't create the file.")
        case .nothingToExport: return ShareLocalized("Nothing to share in the selected messages.")
        case .imageTooLarge: return ShareLocalized("Too long for one image. Share it as a PDF instead.")
        case .attachmentNotReady: return "图片尚未载入，请稍后重试。"
        }
    }
}

extension ChatShareUnitSource {
    init(message m: ChatMessage) {
        let role: Role
        switch m.role {
        case .user: role = .user
        case .assistant: role = .assistant
        default: role = .other
        }
        self.init(id: m.id, role: role, isCallback: isShareCallback(m),
                  isHidden: m.isQueued || m.isInternalBridge)
    }
}

/// A text block's markdown split for adaptive tables: prose at the reading width,
/// each table at its own width.
struct ChatShareTableChunk: Equatable {
    let text: String
    let width: CGFloat
    var isTable = false
}

enum ChatExportContent {
    /// The chunks of a text block for adaptive tables, or nil when it has no table
    /// (then it renders exactly as in the chat).
    @MainActor
    static func tableChunks(_ markdown: String, contentWidth: CGFloat, base: CGFloat) -> [ChatShareTableChunk]? {
        // Keep visualization slot identities and their frozen selections intact
        // when a reply also contains ordinary Markdown tables.
        if MarkdownContent(markdown).blocks.contains(where: { block in
            if case .codeBlock(let info, _) = block { return ZeVisualizationParser.isFence(info) }
            return false
        }) { return nil }
        let chunks = ChatShareMarkdownChunker.split(markdown)
        guard chunks.contains(where: \.isTable) else { return nil }
        let theme = SelectableMarkdownTheme(baseFontSize: FontSettings.shared.scaledMessage(16.5))
        return chunks.map { chunk in
            guard chunk.isTable,
                  case .table(let alignments, let rows)? = MarkdownContent(chunk.text).blocks.first
            else { return ChatShareTableChunk(text: chunk.text, width: contentWidth) }
            let natural = TableAttachment(alignments: alignments, rows: rows, theme: theme).naturalTableWidth()
            return ChatShareTableChunk(
                text: chunk.text,
                width: ChatShareGeometry.tableWidth(natural: natural, contentWidth: contentWidth, base: base),
                isTable: true)
        }
    }

    /// What the height estimate needs about the selected cells (their text).
    @MainActor
    static func estimateInputs(_ groups: [[ChatShareCell]], messages byId: [UUID: ChatMessage]) -> [ChatShareEstimateInput] {
        groups.joined().compactMap { cell in
            guard let m = byId[cell.messageId] else { return nil }
            let text: String
            switch cell.kind {
            case .user: text = m.content
            case .text, .thinking, .tool:
                text = m.blocks.first(where: { $0.id == cell.blockId })?.content ?? ""
            case .callback: text = m.content
            case .note: text = m.error ?? ""
            case .toolGroup, .taskHeader: text = ""
            }
            return ChatShareEstimateInput(kind: cell.kind, text: text)
        }
    }

    /// The one-line title a tool capsule shows.
    static func toolTitle(_ block: AssistantBlock) -> String {
        (block.toolSummary?.isEmpty == false ? block.toolSummary : nil) ?? block.toolDescription
    }

    /// The picker's cells for a chat, from its messages as they are now.
    ///
    /// Completed-turn folding matches the live list: one task-duration
    /// disclosure followed by the final text block. Active turns retain every
    /// step; preserving disclosure captures individually opened history turns.
    @MainActor
    static func cells(for messages: [ChatMessage], foldTools: Bool = false,
                      preserveDisclosure: Bool = false,
                      disclosureEnabled: Bool = true,
                      runningMessageId: UUID? = nil,
                      separators: [UUID: Set<UUID>] = [:]) -> [ChatShareCell] {
        let units = ChatShareUnits.group(messages.map(ChatShareUnitSource.init(message:)))
        var blocks: [UUID: [ChatShareBlockSource]] = [:]
        var errors: Set<UUID> = []
        for m in messages where m.role == .assistant {
            blocks[m.id] = m.blocks.map { b in
                let kind: ChatShareBlockSource.Kind
                switch b.kind {
                case .text: kind = .text
                case .thinking: kind = .thinking
                case .info: kind = .hidden
                default: kind = .tool
                }
                let empty = kind == .tool
                    ? toolTitle(b).isEmpty
                    : b.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return ChatShareBlockSource(id: b.id, kind: kind, isEmpty: empty)
            }
            if m.error?.isEmpty == false { errors.insert(m.id) }
        }
        let taskHeaders = Set(messages.filter { $0.role == .assistant }.map(\.id))
        let collapsed = Set(messages.filter { message in
            message.role == .assistant && foldTools && message.taskDuration != nil
                && (!preserveDisclosure || message.isStepsCollapsed)
        }.map(\.id))
        let collapsible = Set(messages.filter { disclosureEnabled && $0.role == .assistant && $0.taskDuration != nil && $0.error == nil }.map(\.id))
        return ChatShareCells.cells(units: units, blocks: blocks, errors: errors,
                                    taskHeaders: taskHeaders, collapsedMessages: collapsed,
                                    collapsibleMessages: collapsible)
    }

}

// MARK: - Views

/// Collects the bottom edge of every item (PDF break points) while the unit lays out.
final class ChatExportBreakSink {
    var itemBottoms: [Int: CGFloat] = [:]
}

/// One picker cell drawn with the chat's own views, so the picker and the export look
/// like the session list: user and callback rows are ChatMessageRow, reply pieces are
/// AssistantBlockView (same markdown renderer, tool capsules and thinking chip), with
/// the list's 16pt side padding. Callers disable hit testing — nothing here is
/// interactive. `tableChunks` (adaptive tables) swaps a text block for its prose and
/// tables laid out at their own widths.
struct ChatShareCellContent: View {
    let cell: ChatShareCell
    @ObservedObject var message: ChatMessage
    var tableChunks: [ChatShareTableChunk]? = nil
    var onToggleSteps: (() -> Void)? = nil

    private var block: AssistantBlock? {
        cell.blockId.flatMap { id in message.blocks.first { $0.id == id } }
    }

    var body: some View {
        switch cell.kind {
        case .user:
            ChatMessageRow(message: message, isActiveMessage: false)
        case .callback:
            // The list insets callback cards itself (BridgedWholeMessageV3); without
            // it the card ran edge to edge and was clipped on the right.
            ChatMessageRow(message: message, isActiveMessage: false)
                .padding(.horizontal, 16)
        case .text, .tool, .thinking:
            if let block {
                Group {
                    if let tableChunks {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(tableChunks.enumerated()), id: \.offset) { _, chunk in
                                SelectableMarkdownView(markdown: chunk.text)
                                    .frame(width: chunk.width, alignment: .leading)
                            }
                        }
                    } else {
                        AssistantBlockView(block: block, message: message, isActiveMessage: false,
                                           highlightedBlockId: .constant(nil), detailBlock: .constant(nil))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
        case .taskHeader:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SoulAvatarView(size: 22)
                    Text(SoulStore.cachedMetadata.name.isEmpty ? "Ze" : SoulStore.cachedMetadata.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ChatColors.primaryText)
                    if let latency = message.firstTokenLatency {
                        FirstTokenLatencyPill(seconds: latency)
                    }
                }
                if !message.isAwaitingModelResponse, message.error == nil, let duration = message.taskDuration {
                    AssistantTaskDurationView(duration: duration,
                        onToggle: cell.canToggleSteps ? (onToggleSteps ?? {}) : nil,
                        isCollapsed: cell.stepsCollapsed,
                        accessibilityIdentifier: "chatShare.taskToggle.\(message.id.uuidString)")
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(message.isCompactedHistory ? 0.5 : 1)
            // Keep the identifier on the duration Button. A container identifier
            // propagates to descendants and replaces the Button's ID.
        case .toolGroup:
            // [T-share-fold-tools] The chat's own folded row, closed.
            if let fold = cell.fold {
                ConsecutiveToolCallsHeader(blocks: message.blocks.filter { fold.memberIds.contains($0.id) },
                                           isExpanded: false, onToggle: {})
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
        case .note:
            Label(message.error ?? "", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        }
    }
}

/// One group of selected cells, as the export lays it out: the chat's rows at the
/// chosen reading width (phone, or iPad for the wide layout). With adaptive tables the
/// page can be wider than a row: the reply (prose, thinking, tools) re-wraps at the
/// page width so its text lines up with the tables, while user bubbles and callback
/// cards keep the reading width (a user bubble stays at the page's right edge).
private struct ChatExportGroupView: View {
    let cells: [ChatShareCell]
    let messages: [UUID: ChatMessage]
    let chunks: [String: [ChatShareTableChunk]]
    let rowWidth: CGFloat
    let canvasWidth: CGFloat
    let sink: ChatExportBreakSink

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                if let message = messages[cell.messageId] {
                    ChatShareCellContent(cell: cell, message: message, tableChunks: chunks[cell.id])
                        .frame(width: Self.keepsReadingWidth(cell) ? rowWidth : canvasWidth,
                               alignment: .leading)
                        .frame(width: cell.kind == .user ? canvasWidth : nil, alignment: .trailing)
                        .background(GeometryReader { g -> Color in
                            sink.itemBottoms[index] = g.frame(in: .named("exportUnit")).maxY
                            return Color.clear
                        })
                }
            }
        }
        .frame(width: canvasWidth, alignment: .leading)
        .coordinateSpace(name: "exportUnit")
        .background(Color(uiColor: .systemBackground))
    }

    /// Bubbles and cards are objects with a width of their own; stretching them
    /// across a wide page reads as a layout bug rather than more room.
    private static func keepsReadingWidth(_ cell: ChatShareCell) -> Bool {
        cell.kind == .user || cell.kind == .callback
    }
}

private struct ChatExportHeaderView: View {
    let title: String
    /// The parts of the line under the title (model, date), joined with " · ".
    let subtitle: [String]
    let width: CGFloat

    /// The app icon, loaded the way AboutView does (nil if the asset lookup fails;
    /// the brand name still shows).
    private static let appIcon = UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon")

    private static let avatarSize: CGFloat = 28

    /// The assistant's avatar as the chat header resolves it — the user's SOUL icon
    /// (image or emoji), else the default gradient sparkle — drawn as a ringed circle:
    /// an image fills it, a glyph sits centred on a light disc.
    @ViewBuilder
    private var avatar: some View {
        // Match the reference export header's disc and glyph geometry while
        // resolving Ze's existing image/emoji/logo sources.
        let size = Self.avatarSize
        let emoji = SoulStore.cachedMetadata.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        ZStack {
            Circle().fill(Color(uiColor: .secondarySystemBackground))
            if let image = SoulAvatarStore.load() {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
            } else if !emoji.isEmpty {
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                Image("ZeAssistantAvatar").resizable().scaledToFit()
                    .frame(width: size * 0.55, height: size * 0.55)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(uiColor: .separator), lineWidth: 0.5))
    }

    /// "model · date" on one line when it fits; otherwise one part per line, so a
    /// narrow page never splits the date itself. Chosen by layout rather than by
    /// gluing characters: joiners inside a CJK date made the PDF's text layer map
    /// 月 / 日 to their Kangxi-radical look-alikes, breaking copy and search.
    @ViewBuilder
    private var subtitleLine: some View {
        let font = UIFont.systemFont(ofSize: 13)
        ViewThatFits(in: .horizontal) {
            ExportLabel(text: subtitle.joined(separator: " · "), font: font, color: .secondaryLabel, lines: 1)
                .fixedSize()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(subtitle.enumerated()), id: \.offset) { i, part in
                    ExportLabel(text: i < subtitle.count - 1 ? part + " ·" : part,
                                font: font, color: .secondaryLabel)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Avatar, title block and brand share one vertical centre line.
            HStack(alignment: .center, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    ExportLabel(text: title, font: .systemFont(ofSize: 16, weight: .semibold), lines: 2)
                    subtitleLine
                }
                // Measured before the Spacer, so "model · date" only wraps when it
                // truly runs into the brand, not when the Spacer claims a share.
                .layoutPriority(1)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    if let icon = Self.appIcon {
                        // The icon is a pale M on white: a hairline keeps its edge
                        // visible on the white page.
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5))
                    }
                    // Product name: not localized.
                    ExportLabel(text: "Ze", font: .systemFont(ofSize: 14, weight: .semibold),
                                color: .label, lines: 1)
                        .fixedSize()
                }
            }
            Divider()
        }
        .padding(.horizontal, 16)
        .frame(width: width, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
    }
}

/// A wrapping UILabel sized by SwiftUI: header text drawable as vector glyphs.
struct ExportLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    var color: UIColor = .label
    var lines = 0

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(size.width), width), height: ceil(size.height))
    }
}

// MARK: - Renderer

@MainActor
final class ChatExportRenderer {
    struct Result {
        let url: URL
        /// Long image: pixel size. PDF: page size in points.
        let size: CGSize
        /// Pixels per point of a long image (1 for a PDF): the preview shows it at 1:1.
        let scale: CGFloat
        let pageCount: Int
        let units: Int
    }

    static let margin: CGFloat = 8
    static let unitGap: CGFloat = 18
    /// The page's content width: the chat list's width on a phone (rows carry their
    /// own 16pt side padding), or a 13-inch iPad's portrait width for the wide layout
    /// (at the 11-inch 834pt a 7-column table still fell into the scrolling plan and
    /// was cut off at the page edge).
    static func rowWidth(wide: Bool) -> CGFloat {
        wide ? 1024 : min(max(UIScreen.main.bounds.width, 360), 460)
    }

    /// The appearance of the current render and its page colour.
    private var style: UIUserInterfaceStyle = .light
    private var pageColor: UIColor = .white
    private var adaptiveTables = false

    private let stage: UIView
    /// The chat's view model: the tool capsules read it from the environment.
    private let vm: AIChatViewModel

    init(vm: AIChatViewModel) throws {
        self.vm = vm
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first
        else { throw ChatExportError.noWindow }
        // Off to the left of the window: in the hierarchy (so text views and
        // attachments lay out as on screen) but never visible.
        stage = UIView(frame: CGRect(x: -30_000, y: 0, width: 1, height: 1))
        stage.isUserInteractionEnabled = false
        stage.clipsToBounds = false
        window.addSubview(stage)
    }

    deinit {
        let stage = stage
        Task { @MainActor in stage.removeFromSuperview() }
    }

    /// A laid-out unit, alive until the caller is done drawing it.
    private struct Laid {
        let host: UIHostingController<AnyView>
        let size: CGSize
        /// Clean places to cut a page inside the unit (item and text-line bottoms).
        let breaks: [CGFloat]
    }

    private func layOut<V: View>(_ view: V, width: CGFloat, sink: ChatExportBreakSink?) async throws -> Laid {
        let host = UIHostingController(rootView: AnyView(
            view.environment(\.colorScheme, style == .dark ? .dark : .light)
                .environment(\.chatSnapshotRendering, true)
                .environment(\.chatSearchHighlights, nil)
                .environment(\.chatSessionId, vm.sessionId)
                .environmentObject(vm)))
        host.overrideUserInterfaceStyle = style
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.view.backgroundColor = pageColor
        stage.addSubview(host.view)
        func measure() -> CGSize {
            let s = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: max(1, ceil(s.height)))
        }
        var size = measure()
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        // Wait for actual asynchronous attachments and two stable layout passes.
        // Missing images produce an explicit retryable error rather than a blank export.
        var stable = 0
        // Custom previews use one bounded serial renderer. Include cold WebKit
        // launch and the separate capture budget for every queued component.
        func customCount(_ view: UIView) -> Int {
            (view is ZeCustomVisualizationPreview ? 1 : 0) + view.subviews.reduce(0) { $0 + customCount($1) }
        }
        let renderPasses = Int(ceil(ZeCustomVisualizationRenderer.maximumRenderSeconds / 0.05))
        let attachmentPasses = 100 + min(8, customCount(host.view)) * renderPasses
        do {
            for pass in 0..<attachmentPasses {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 50_000_000)
                let pending = prepareAttachments(in: host.view)
                let next = measure()
                stable = abs(next.height - size.height) < 0.5 && pending == 0 ? stable + 1 : 0
                size = next
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                if stable >= 2 { break }
                if pass == attachmentPasses - 1, pending > 0 { throw ChatExportError.attachmentNotReady }
            }
        } catch {
            host.view.removeFromSuperview()
            throw error
        }
        var breaks = Array((sink?.itemBottoms.values).map(Array.init) ?? [])
        collectLineBreaks(in: host.view, root: host.view, into: &breaks)
        return Laid(host: host, size: size, breaks: breaks)
    }

    private func prepareAttachments(in view: UIView) -> Int {
        var pending = 0
        if let custom = view as? ZeCustomVisualizationPreview, custom.isPending { pending += 1 }
        if let text = view as? UITextView {
            text.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.textStorage.length)) { value, range, _ in
                if let image = value as? ImageAttachment, image.loadedImage == nil { pending += 1 }
                if let table = value as? TableAttachment, adaptiveTables, !table.exportWrapToWidth {
                    table.exportWrapToWidth = true
                    table.needsViewRebuild = true
                    table.needsLayoutInvalidation = true
                    text.layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                    text.setNeedsLayout()
                }
            }
            (text as? SelectableMarkdownTextView)?.updateAttachmentViews()
        }
        for subview in view.subviews { pending += prepareAttachments(in: subview) }
        return pending
    }

    private func collectLineBreaks(in view: UIView, root: UIView, into breaks: inout [CGFloat]) {
        if let tv = view as? UITextView, tv.textLayoutManager == nil {
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(for: tv.textContainer)
            let inset = tv.textContainerInset.top
            var lineBottoms: [CGFloat] = []
            lm.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                lineBottoms.append(used.maxY + inset)
            }
            breaks += lineBottoms.map { tv.convert(CGPoint(x: 0, y: $0), to: root).y }
            return
        }
        for sub in view.subviews { collectLineBreaks(in: sub, root: root, into: &breaks) }
    }

    private func discard(_ laid: Laid) {
        laid.host.view.removeFromSuperview()
    }

    /// "<model> · <date>" under the title, so a shared export shows which model did
    /// the work. The model is the concrete one the session resolves to (not a group
    /// name); either part is dropped when unavailable.
    private static func subtitle(for messages: [ChatMessage], model: String?) -> [String] {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let date = messages.first.map { f.string(from: $0.timestamp) }
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [model, date].compactMap { $0?.isEmpty == false ? $0 : nil }
    }

    private static var exportRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ChatExport", isDirectory: true)
    }

    /// Drops earlier exports; the share preview calls it when it opens (its own
    /// renders stay until the next time, so switching format back reuses them).
    static func clearExports() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86400)
        for entry in entries {
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    private static func fileURL(title: String, ext: String) throws -> URL {
        // Its own folder per export, so the image and the PDF of one selection can
        // both be kept while the preview switches between them.
        let dir = exportRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")
        let clean = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(60)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return dir.appendingPathComponent("\(clean.isEmpty ? "Chat" : String(clean)) \(f.string(from: Date())).\(ext)")
    }

    /// Renders the selected cells. `groups` is `ChatShareCells.renderGroups`: each group
    /// is the selected part of one unit and is laid out (and page-broken) as one block.
    func render(groups: [[ChatShareCell]], messages: [ChatMessage], title: String,
                options: ChatExportOptions,
                progress: @escaping (Int, Int) -> Void) async throws -> Result {
        try Task.checkCancellation()
        let started = Date()
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        adaptiveTables = options.adaptiveTables
        style = options.dark ? .dark : .light
        pageColor = UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        let base = Self.rowWidth(wide: options.wideLayout)
        let groups = groups.map { $0.filter { byId[$0.messageId] != nil } }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { throw ChatExportError.nothingToExport }
        var chunks: [String: [ChatShareTableChunk]] = [:]
        if options.adaptiveTables {
            for cell in groups.joined() where cell.kind == .text {
                guard let block = byId[cell.messageId]?.blocks.first(where: { $0.id == cell.blockId }),
                      let split = ChatExportContent.tableChunks(
                        block.content, contentWidth: base - ChatShareGeometry.rowPadding, base: base)
                else { continue }
                chunks[cell.id] = split
            }
        }
        // The page follows the widest table, up to ChatShareGeometry.maxCanvasWidth;
        // a table capped below its natural width wraps its cells to fit.
        let canvas = ChatShareGeometry.canvasWidth(
            base: base, tableRowWidths: chunks.values.joined().map { $0.width + ChatShareGeometry.rowPadding })
        // Prose was split at the reading width only to find the table widths; once
        // the page is known it re-wraps at the page's content width, so the text
        // around a table is as wide as the widest table rather than a narrow column
        // beside it. Tables keep their own width (a narrow one is not stretched).
        let proseWidth = canvas - ChatShareGeometry.rowPadding
        chunks = chunks.mapValues { split in
            split.map { $0.isTable ? $0 : ChatShareTableChunk(text: $0.text, width: proseWidth) }
        }
        let contents: [(ChatExportBreakSink) -> AnyView] = groups.map { group in
            { sink in AnyView(ChatExportGroupView(cells: group, messages: byId, chunks: chunks,
                                                  rowWidth: base, canvasWidth: canvas, sink: sink)) }
        }
        let covered = groups.flatMap { $0.map(\.messageId) }.compactMap { byId[$0] }
        // [T-share-hide-title] Hidden: no header, and no title anywhere in the file
        // (an empty title names it "Chat <date>").
        let header = options.hideHeader ? nil
            : ChatExportHeaderView(title: title, subtitle: Self.subtitle(for: covered, model: vm.resolveCurrentEntry()?.model.displayName),
                                   width: canvas)
        let fileTitle = options.hideHeader ? "" : title
        logger.info("[ChatExport] start format=\(options.format.rawValue) groups=\(groups.count) cells=\(groups.joined().count) canvas=\(Int(canvas)) wide=\(options.wideLayout) dark=\(options.dark) adaptiveTables=\(options.adaptiveTables) splitBlocks=\(chunks.count) header=\(!options.hideHeader)")

        let result: Result
        switch options.format {
        case .image:
            result = try await renderImage(contents: contents, header: header, canvas: canvas,
                                           title: fileTitle, progress: progress)
        case .pdf:
            result = try await renderPDF(contents: contents, header: header, canvas: canvas,
                                         title: fileTitle, progress: progress)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        logger.info("[ChatExport] done format=\(options.format.rawValue) size=\(Int(result.size.width))x\(Int(result.size.height)) pages=\(result.pageCount) bytes=\(bytes) ms=\(ms)")
        return result
    }

    // MARK: Long image

    private func renderImage(contents: [(ChatExportBreakSink) -> AnyView], header: ChatExportHeaderView?,
                             canvas: CGFloat, title: String,
                             progress: @escaping (Int, Int) -> Void) async throws -> Result {
        // Each piece is rendered at 3x into a temp PNG right away, so only one hosting
        // view and one bitmap are alive at a time; the final image is composed after.
        // Text is drawn as glyphs (drawVector), not copied from the views' own
        // screen-scale bitmaps, which is what made a 2x image of a 2x device soft.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ChatExportParts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var parts: [(url: URL, size: CGSize)] = []

        func renderPart<V: View>(_ view: V, sink: ChatExportBreakSink?) async throws {
            let laid = try await layOut(view, width: canvas, sink: sink)
            defer { discard(laid) }
            let format = UIGraphicsImageRendererFormat()
            guard let partScale = ChatShareImageBudget.scale(width: laid.size.width, height: laid.size.height) else {
                throw ChatExportError.imageTooLarge
            }
            format.scale = partScale
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: laid.size, format: format).image { ctx in
                pageColor.setFill()
                ctx.fill(CGRect(origin: .zero, size: laid.size))
                drawVector(laid.host.view, in: ctx.cgContext)
            }
            let url = dir.appendingPathComponent("\(parts.count).png")
            try await Self.writePNG(image, to: url)
            parts.append((url, laid.size))
        }

        if let header { try await renderPart(header, sink: nil) }
        for (i, makeView) in contents.enumerated() {
            try Task.checkCancellation()
            let sink = ChatExportBreakSink()
            try await renderPart(makeView(sink), sink: sink)
            progress(i + 1, contents.count)
        }

        let m = Self.margin
        // [T-share-hide-title] With the header, part 0 is it (8pt gap after); without,
        // the first group starts at the top margin.
        let placement = ChatShareImageLayout.place(
            header: header == nil ? nil : parts.first?.size.height,
            groups: parts.dropFirst(header == nil ? 0 : 1).map(\.size.height),
            margin: m, headerGap: 8, unitGap: Self.unitGap)
        let size = CGSize(width: canvas + m * 2, height: ceil(placement.height))
        guard let scale = ChatShareImageBudget.scale(width: size.width, height: size.height) else {
            logger.warning("[ChatExport] image too large \(Int(size.width))x\(Int(size.height))pt")
            throw ChatExportError.imageTooLarge
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let url = try Self.fileURL(title: title, ext: "png")
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            pageColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (part, y) in zip(parts, placement.ys) {
                autoreleasepool {
                    UIImage(contentsOfFile: part.url.path)?.draw(in: CGRect(x: m, y: y, width: part.size.width, height: part.size.height))
                }
            }
        }
        try await Self.writePNG(image, to: url)
        return Result(url: url, size: CGSize(width: size.width * scale, height: size.height * scale),
                      scale: scale, pageCount: 1, units: contents.count)
    }

    // MARK: PDF

    /// Encoding large PNGs is CPU-heavy and must not stall option taps/scrolling.
    nonisolated private static func writePNG(_ image: UIImage, to url: URL) async throws {
        try Task.checkCancellation()
        try await Task.detached(priority: .userInitiated) {
            guard let data = image.pngData() else { throw ChatExportError.writeFailed }
            try data.write(to: url, options: .atomic)
        }.value
        try Task.checkCancellation()
    }

    private func renderPDF(contents: [(ChatExportBreakSink) -> AnyView], header: ChatExportHeaderView?,
                           canvas: CGFloat, title: String,
                           progress: @escaping (Int, Int) -> Void) async throws -> Result {
        let m = Self.margin
        let footer: CGFloat = 22
        let pageWidth = canvas + m * 2
        // A4 proportions at the export width; a full-width-table page grows with it.
        let pageHeight = (pageWidth * 297 / 210).rounded()
        let contentHeight = pageHeight - m * 2 - footer
        let url = try Self.fileURL(title: title, ext: "pdf")
        var box = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var infoDict: [String: Any] = [kCGPDFContextCreator as String: "Ze"]
        if !title.isEmpty { infoDict[kCGPDFContextTitle as String] = title }
        let info = infoDict as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info) else { throw ChatExportError.writeFailed }

        var openPage = -1
        func ensurePage(_ page: Int) {
            while openPage < page {
                if openPage >= 0 { closePage() }
                openPage += 1
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                // UIKit's top-left, y-down coordinates.
                ctx.translateBy(x: 0, y: pageHeight)
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(pageColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
            }
        }
        func closePage() {
            // [T-share-hide-title] Page number only when the title is hidden.
            let label = (title.isEmpty ? "\(openPage + 1)" : "\(title) · \(openPage + 1)") as NSString
            UIGraphicsPushContext(ctx)
            let footerColor = UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            label.draw(at: CGPoint(x: m, y: pageHeight - m - 12),
                       withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: footerColor])
            UIGraphicsPopContext()
            ctx.restoreGState()
            ctx.endPDFPage()
        }

        var cursor = ChatSharePagination.Cursor()
        func draw(_ laid: Laid) {
            let slices = ChatSharePagination.place(height: laid.size.height, breaks: laid.breaks,
                                                   pageHeight: contentHeight, gap: Self.unitGap, cursor: &cursor)
            for slice in slices {
                ensurePage(slice.page)
                ctx.saveGState()
                ctx.translateBy(x: m, y: m + slice.pageY - slice.unitY)
                ctx.clip(to: CGRect(x: 0, y: slice.unitY, width: laid.size.width, height: slice.height))
                drawVector(laid.host.view, in: ctx, visibleBounds: CGRect(x: 0, y: slice.unitY, width: laid.size.width, height: slice.height), searchablePDF: true)
                ctx.restoreGState()
            }
        }

        if let header {
            let head = try await layOut(header, width: canvas, sink: nil)
            draw(head)
            discard(head)
        }
        for (i, makeView) in contents.enumerated() {
            try Task.checkCancellation()
            let sink = ChatExportBreakSink()
            let laid = try await layOut(makeView(sink), width: canvas, sink: sink)
            draw(laid)
            discard(laid)
            progress(i + 1, contents.count)
        }
        if openPage >= 0 { closePage() }
        ctx.closePDF()
        return Result(url: url, size: CGSize(width: pageWidth, height: pageHeight),
                      scale: 1, pageCount: openPage + 1, units: contents.count)
    }

    /// Draws a laid-out unit into a PDF context with its TEXT as vector glyphs.
    ///
    /// `layer.render(in:)` alone copies each text view's already-rendered bitmap, so a
    /// PDF built that way is a picture of the chat: text not selectable, searchable or
    /// sharp when zoomed. Instead, two passes:
    /// 1. every TextKit 1 text view's private drawing subviews (its glyph canvas, scroll
    ///    indicators) and every label are hidden, and the layer tree is rendered —
    ///    backgrounds, borders, table rules and images, with no text;
    /// 2. each of those text views draws its glyphs through its layout manager, and each
    ///    label through `drawText(in:)`, straight into the context, clipped like on screen.
    /// App-added subviews of a text view (table, code and math attachment views) stay
    /// visible in pass 1, and their own text views are handled in pass 2 like any other.
    /// A text view on TextKit 2 is left alone and comes out as a bitmap, as before.
    private func drawVector(_ root: UIView, in ctx: CGContext, visibleBounds: CGRect? = nil, searchablePDF: Bool = false) {
        // Dynamic colours (text, code, table rules) resolve against the CURRENT trait
        // collection while drawing — the app's, not the export's. A dark app exporting
        // a light page drew white text on white. Draw under the hosting view's traits.
        root.traitCollection.performAsCurrent {
            drawVectorInCurrentTraits(root, in: ctx, visibleBounds: visibleBounds ?? root.bounds, searchablePDF: searchablePDF)
        }
    }

    private func drawVectorInCurrentTraits(_ root: UIView, in ctx: CGContext, visibleBounds: CGRect, searchablePDF: Bool) {
        var textViews: [UITextView] = []
        var labels: [UILabel] = []
        var hidden: [UIView] = []
        func isPrivate(_ v: UIView) -> Bool { NSStringFromClass(type(of: v)).hasPrefix("_") }
        func walk(_ v: UIView) {
            guard !v.isHidden, v.alpha > 0.01 else { return }
            if let tv = v as? UITextView, tv.textLayoutManager == nil {
                textViews.append(tv)
                for sub in tv.subviews where isPrivate(sub) && !sub.isHidden {
                    sub.isHidden = true
                    hidden.append(sub)
                }
            } else if let label = v as? UILabel {
                labels.append(label)
                label.isHidden = true
                hidden.append(label)
                return
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        defer { hidden.forEach { $0.isHidden = false } }

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        root.layer.render(in: ctx)

        /// The part of `view` its ancestors let show, in root coordinates.
        func visibleRect(_ view: UIView) -> CGRect {
            var rect = view.convert(view.bounds, to: root).intersection(visibleBounds)
            var v: UIView? = view.superview
            while let a = v, a !== root {
                if a.clipsToBounds { rect = rect.intersection(a.convert(a.bounds, to: root)) }
                v = a.superview
            }
            return rect
        }
        for tv in textViews {
            let clip = visibleRect(tv)
            guard !clip.isEmpty else { continue }
            let lm = tv.layoutManager
            let glyphs = lm.glyphRange(for: tv.textContainer)
            guard glyphs.length > 0 else { continue }
            ctx.saveGState()
            ctx.clip(to: clip)
            let origin = tv.convert(CGPoint.zero, to: root)
            ctx.translateBy(x: origin.x, y: origin.y)
            let inset = CGPoint(x: tv.textContainerInset.left, y: tv.textContainerInset.top)
            if searchablePDF {
                let localClip = tv.convert(clip, from: root)
                drawPDFText(tv, in: ctx, clip: localClip)
            } else {
                lm.drawBackground(forGlyphRange: glyphs, at: inset)
                lm.drawGlyphs(forGlyphRange: glyphs, at: inset)
            }
            ctx.restoreGState()
        }
        for label in labels {
            let clip = visibleRect(label)
            guard !clip.isEmpty else { continue }
            ctx.saveGState()
            ctx.clip(to: clip)
            let origin = label.convert(CGPoint.zero, to: root)
            ctx.translateBy(x: origin.x, y: origin.y)
            if searchablePDF {
                drawPDFLabel(label, in: ctx, clip: label.convert(clip, from: root))
            } else {
                label.drawText(in: label.bounds)
            }
            ctx.restoreGState()
        }
    }

    /// Draw only the current page's laid-out lines. TextKit chooses line breaks
    /// and baseline positions; CoreText draws copied attributed spans so PDF-only
    /// compatibility adjustments never mutate the screen or PNG layout. CoreText
    /// alone does not prevent PDFKit from splitting SF proportional underscores;
    /// the measured correction below keeps their visible glyph within its word.
    /// Attachment views retain their geometry in the background pass above.
    private func drawPDFText(_ textView: UITextView, in ctx: CGContext, clip: CGRect) {
        let lm = textView.layoutManager
        let storage = textView.textStorage
        let inset = textView.textContainerInset
        let containerClip = clip.offsetBy(dx: -inset.left, dy: -inset.top)
        let visibleGlyphs = lm.glyphRange(forBoundingRect: containerClip, in: textView.textContainer)
        guard visibleGlyphs.length > 0 else { return }
        lm.drawBackground(forGlyphRange: visibleGlyphs, at: CGPoint(x: inset.left, y: inset.top))
        lm.enumerateLineFragments(forGlyphRange: visibleGlyphs) { lineRect, usedRect, _, glyphRange, _ in
            guard usedRect.intersects(containerClip) else { return }
            let chars = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let raw = storage.string as NSString
            var start = chars.location
            func drawSpan(endingAt end: Int) {
                guard end > start else { return }
                let span = NSMutableAttributedString(attributedString: storage.attributedSubstring(
                    from: NSRange(location: start, length: end - start)))
                // Real UIKit/PDFKit matrix: SF proportional "SHARE_BEGIN" was
                // extracted as "SHARE\nBEGIN\n_". Raising only its underscore by
                // 2pt makes findString match while preserving the font, advance,
                // original line baseline, and any authored baseline offset.
                // SF Mono already searches correctly and must stay untouched.
                let spanText = span.string as NSString
                for index in 0..<span.length where spanText.character(at: index) == 0x5F {
                    guard let font = span.attribute(.font, at: index, effectiveRange: nil) as? UIFont,
                          font.fontName.hasPrefix(".SF"),
                          !font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace),
                          !font.fontName.localizedCaseInsensitiveContains("mono") else { continue }
                    let existing = (span.attribute(.baselineOffset, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                    span.addAttribute(.baselineOffset, value: existing + 2,
                                      range: NSRange(location: index, length: 1))
                }
                // CoreText requires CGColor rather than UIKit dynamic UIColor.
                span.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: span.length)) { value, range, _ in
                    let color = (value as? UIColor) ?? textView.textColor ?? .label
                    span.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                      value: color.resolvedColor(with: textView.traitCollection).cgColor, range: range)
                }
                let firstGlyph = lm.glyphIndexForCharacter(at: start)
                let location = lm.location(forGlyphAt: firstGlyph)
                let baseline = CGPoint(x: inset.left + lineRect.minX + location.x,
                                       y: inset.top + lineRect.minY + location.y)
                let line = CTLineCreateWithAttributedString(span)
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = CGPoint(x: baseline.x, y: -baseline.y)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            for index in chars.location..<NSMaxRange(chars) {
                let character = raw.character(at: index)
                if character == 0xFFFC || character == 0x0A || character == 0x0D {
                    drawSpan(endingAt: index)
                    start = index + 1
                }
            }
            drawSpan(endingAt: NSMaxRange(chars))
        }
    }

    private func drawPDFLabel(_ label: UILabel, in ctx: CGContext, clip: CGRect) {
        let value = label.attributedText ?? NSAttributedString(string: label.text ?? "")
        guard value.length > 0 else { return }
        let attributed = NSMutableAttributedString(attributedString: value)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange) { attrs, range, _ in
            if attrs[.font] == nil { attributed.addAttribute(.font, value: label.font ?? UIFont.systemFont(ofSize: UIFont.labelFontSize), range: range) }
            if attrs[.foregroundColor] == nil {
                attributed.addAttribute(.foregroundColor, value: label.textColor ?? UIColor.label, range: range)
            }
            if attrs[.paragraphStyle] == nil {
                let style = NSMutableParagraphStyle()
                style.alignment = label.textAlignment
                style.lineBreakMode = label.lineBreakMode
                attributed.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        let rect = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
        let textView = UITextView(usingTextLayoutManager: false)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.maximumNumberOfLines = label.numberOfLines
        textView.textContainer.lineBreakMode = label.lineBreakMode
        textView.frame = CGRect(origin: .zero, size: rect.size)
        textView.attributedText = attributed
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        drawPDFText(textView, in: ctx, clip: clip.offsetBy(dx: -rect.minX, dy: -rect.minY))
        ctx.restoreGState()
    }

    /// DEBUG aid: the text PDFKit extracts from a rendered PDF (proves text stayed vector).
    static func pdfTextSample(_ url: URL, limit: Int = 400) -> String {
        guard let doc = PDFDocument(url: url) else { return "" }
        return String((doc.string ?? "").prefix(limit))
    }
}
