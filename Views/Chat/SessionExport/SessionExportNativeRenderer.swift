//
//  SessionExportNativeRenderer.swift
//  ZeApp
//
//  Export-only native layout with a bounded long image and paged vector text.
//  Vector text-layer separation adapted from OpenMinis 1.15 ChatExportRenderer
//  License text: docs/licenses/OpenMinis-GPL-3.0.txt
//  (GPL-3.0): https://github.com/OpenMinis/OpenMinis/blob/
//  6eda5523a9c14fa8edc4fd9fb72e643fe47f23be/src/ios/Views/Chat/ChatExportRenderer.swift
//  Ze's MarkdownRenderView uses its own TextKit 1 stack, handled explicitly below.
//  SwiftUI-only chrome and media remain raster; Markdown, UIKit labels and
//  TextKit 1 text views are drawn as real PDF glyphs, not an invisible OCR layer.


import SwiftUI
import UIKit

// BEGIN SESSION_SHARE_RENDER_POLICY — extract with `import Foundation` only.
/// Pure geometry used by the production renderer, not a test-side reimplementation.
enum SessionShareRenderPolicy {
    /// One share image up to 16,000 physical pixels at 2x. Larger transcripts
    /// use PDF instead of silently changing the user's image into an image set.
    static let sliceHeight: CGFloat = 8_000
    static let imageScale: CGFloat = 2
    static let imageBudgetBytes: CGFloat = 128 * 1_024 * 1_024
    static let maxCanvasWidth: CGFloat = 2_048

    static func fitsImageBudget(width: CGFloat, height: CGFloat) -> Bool {
        guard width.isFinite, height.isFinite, width > 0, height > 0, height <= sliceHeight else { return false }
        // Reserve two full surfaces for the renderer/result handoff. Rows are
        // still hosted one at a time; there is no retained array of row bitmaps.
        return height * width * imageScale * imageScale * 4 * 2 <= imageBudgetBytes
    }

    static func pageCount(height: CGFloat, contentHeight: CGFloat) -> Int {
        guard height.isFinite, contentHeight.isFinite, height > 0, contentHeight > 0 else { return 0 }
        let count = ceil(height / contentHeight)
        guard count < CGFloat(Int.max) else { return 0 }
        return Int(count)
    }

    static func nextSliceHeight(total: CGFloat, offset: CGFloat) -> CGFloat {
        guard total.isFinite, offset.isFinite, total > 0, offset >= 0, offset < total else { return 0 }
        return min(sliceHeight, total - offset)
    }

    static func overlaps(start: CGFloat, height: CGFloat, pageTop: CGFloat, pageHeight: CGFloat) -> Bool {
        guard start.isFinite, height.isFinite, pageTop.isFinite, pageHeight.isFinite,
              height > 0, pageHeight > 0 else { return false }
        return start < pageTop + pageHeight && start + height > pageTop
    }

    static func tableCanvasWidth(base: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard base.isFinite, contentWidth.isFinite, viewportWidth.isFinite,
              base > 0, contentWidth >= 0, viewportWidth > 0 else { return base }
        return min(maxCanvasWidth, max(base, base + max(0, contentWidth - viewportWidth)))
    }

    static func tableScale(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard contentWidth.isFinite, viewportWidth.isFinite, contentWidth > 0, viewportWidth > 0 else { return 1 }
        return min(1, viewportWidth / contentWidth)
    }
}
// END SESSION_SHARE_RENDER_POLICY

@MainActor
final class SessionExportNativeRenderer {

    private static let maxRowHeight: CGFloat = 20_000
    private static let imageScale = SessionShareRenderPolicy.imageScale
    private(set) var failureReason: String?

    private let messages: [ChatMessage]
    private let scope: SessionExportScope
    private let options: SessionExportOptions
    private let header: SessionExportHeader?
    private let vm: AIChatViewModel
    private var pageWidth: CGFloat

    private let background: UIColor
    private let scheme: ColorScheme

    init(messages: [ChatMessage],
         scope: SessionExportScope,
         options: SessionExportOptions,
         header: SessionExportHeader?,
         vm: AIChatViewModel,
         adaptiveWidth: CGFloat) {
        self.messages = messages
        self.scope = scope
        self.options = options
        self.header = header
        self.vm = vm
        self.pageWidth = options.width.pageWidth(adaptiveWidth: adaptiveWidth)
        self.scheme = options.theme == .dark ? .dark : .light
        self.background = options.theme == .dark
            ? UIColor(white: 0.07, alpha: 1)
            : UIColor.white
    }

    // MARK: - Public entry points

    /// A single bounded long image, painted row-by-row straight into the final
    /// canvas. No intermediate row bitmaps or full-size stitch copy are retained.
    /// Beyond the height/memory guard, fail explicitly so the UI can offer PDF.
    func makeImages() -> [UIImage] {
        failureReason = nil
        guard let layout = prepareLayout() else { return [] }
        guard SessionShareRenderPolicy.fitsImageBudget(width: pageWidth, height: layout.totalHeight) else {
            failureReason = "会话超出单张长图的高度或内存上限，请改用 PDF。"
            return []
        }
        return renderImages(layout: layout, height: layout.totalHeight)
    }

    func makePreviewImage(maxHeight: CGFloat = 900) -> UIImage? {
        failureReason = nil
        guard let layout = prepareLayout() else { return nil }
        return renderImages(layout: layout, height: min(max(1, maxHeight), min(900, layout.totalHeight))).first
    }

    /// PDF pages are drawn directly from one hosted row at a time. The glyph
    /// drawing below is the visible text itself; no raster transcript is made.
    func makePDFData() -> Data? {
        failureReason = nil
        guard let layout = prepareLayout(),
              let host = OffscreenHost(width: pageWidth, background: background, scheme: scheme)
        else { return nil }
        defer { host.tearDown() }
        let pageSize = CGSize(width: pageWidth, height: (pageWidth * 1.4142).rounded())
        let footerHeight: CGFloat = 26
        let contentHeight = pageSize.height - footerHeight
        let pageCount = SessionShareRenderPolicy.pageCount(height: layout.totalHeight, contentHeight: contentHeight)
        let format = UIGraphicsPDFRendererFormat()
        var metadata: [String: Any] = [kCGPDFContextCreator as String: "Ze"]
        if options.includeHeader, let header { metadata[kCGPDFContextTitle as String] = header.title }
        format.documentInfo = metadata
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        var loadedRow: Int?
        var failed = false
        let data = renderer.pdfData { pdf in
            for page in 0..<pageCount {
                autoreleasepool {
                    pdf.beginPage()
                    background.setFill()
                    pdf.cgContext.fill(CGRect(origin: .zero, size: pageSize))
                    let top = CGFloat(page) * contentHeight
                    for index in layout.rows.indices where SessionShareRenderPolicy.overlaps(
                        start: layout.starts[index], height: layout.heights[index], pageTop: top, pageHeight: contentHeight) {
                        if loadedRow != index {
                            guard host.layout(layout.rows[index], maxHeight: Self.maxRowHeight) != nil else {
                                failed = true
                                continue
                            }
                            if options.adaptiveTables { host.fitTables() }
                            loadedRow = index
                        }
                        pdf.cgContext.saveGState()
                        pdf.cgContext.clip(to: CGRect(x: 0, y: 0, width: pageWidth, height: contentHeight))
                        pdf.cgContext.translateBy(x: 0, y: layout.starts[index] - top)
                        drawVector(host.view, in: pdf.cgContext)
                        pdf.cgContext.restoreGState()
                    }
                    drawFooter(page: page + 1, total: pageCount, pageSize: pageSize, footerHeight: footerHeight)
                }
            }
        }
        if failed {
            failureReason = "导出布局失败，未生成不完整文件。"
            return nil
        }
        return data
    }

    private struct Layout {
        let rows: [AnyView]
        let heights: [CGFloat]
        let starts: [CGFloat]
        let totalHeight: CGFloat
    }

    /// Measure without retaining any row's bitmap. One host is reused and then
    /// discarded before output allocation. Over-limit rows fail, never truncate.
    private func prepareLayout() -> Layout? {
        var rows = makeRowViews()
        guard !rows.isEmpty else { failureReason = "没有可分享的内容。"; return nil }
        if options.adaptiveTables {
            guard let probe = OffscreenHost(width: pageWidth, background: background, scheme: scheme) else {
                failureReason = "无法创建导出窗口。"; return nil
            }
            var naturalWidth = pageWidth
            for row in rows {
                if probe.layout(row, maxHeight: Self.maxRowHeight) != nil {
                    naturalWidth = max(naturalWidth, probe.requiredTableCanvasWidth)
                }
            }
            probe.tearDown()
            pageWidth = min(SessionShareRenderPolicy.maxCanvasWidth, naturalWidth)
            rows = makeRowViews()
        }
        guard let host = OffscreenHost(width: pageWidth, background: background, scheme: scheme) else {
            failureReason = "无法创建导出窗口。"; return nil
        }
        defer { host.tearDown() }
        var heights: [CGFloat] = []
        var starts: [CGFloat] = []
        var y: CGFloat = 0
        for row in rows {
            guard let height = autoreleasepool(invoking: { host.layout(row, maxHeight: Self.maxRowHeight) }) else {
                failureReason = "单个内容块过长，无法完整导出；请缩小选择范围。"
                return nil
            }
            starts.append(y)
            heights.append(height)
            y += height
        }
        return Layout(rows: rows, heights: heights, starts: starts, totalHeight: y)
    }

    private func renderImages(layout: Layout, height: CGFloat) -> [UIImage] {
        guard let host = OffscreenHost(width: pageWidth, background: background, scheme: scheme) else {
            failureReason = "无法创建导出窗口。"; return []
        }
        defer { host.tearDown() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.imageScale
        format.opaque = true
        format.preferredRange = .standard
        var result: [UIImage] = []
        var top: CGFloat = 0
        var loadedRow: Int?
        var failed = false
        while top < height {
            let sliceHeight = SessionShareRenderPolicy.nextSliceHeight(total: height, offset: top)
            let image: UIImage = autoreleasepool {
                UIGraphicsImageRenderer(size: CGSize(width: pageWidth, height: sliceHeight), format: format).image { output in
                    background.setFill()
                    output.fill(CGRect(x: 0, y: 0, width: pageWidth, height: sliceHeight))
                    for index in layout.rows.indices where SessionShareRenderPolicy.overlaps(
                        start: layout.starts[index], height: layout.heights[index], pageTop: top, pageHeight: sliceHeight) {
                        if loadedRow != index {
                            guard host.layout(layout.rows[index], maxHeight: Self.maxRowHeight) != nil else {
                                failed = true
                                continue
                            }
                            if options.adaptiveTables { host.fitTables() }
                            loadedRow = index
                        }
                        output.cgContext.saveGState()
                        output.cgContext.translateBy(x: 0, y: layout.starts[index] - top)
                        drawVector(host.view, in: output.cgContext)
                        output.cgContext.restoreGState()
                    }
                }
            }
            if failed { failureReason = "导出布局失败，未生成不完整文件。"; return [] }
            result.append(image)
            top += sliceHeight
        }
        return result
    }

    /// Rule + "3 / 12" in the reserved band. The number is right-aligned and
    /// monospaced so it stays put as the total crosses 9 → 10 → 100.
    private func drawFooter(page: Int, total: Int, pageSize: CGSize, footerHeight: CGFloat) {
        let ruleY = pageSize.height - footerHeight
        (scheme == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08)).setFill()
        UIRectFill(CGRect(x: 0, y: ruleY, width: pageSize.width, height: 0.5))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: scheme == .dark
                ? UIColor(white: 0.62, alpha: 1)
                : UIColor(white: 0.42, alpha: 1)
        ]

        let number = "\(page) / \(total)" as NSString
        let numberSize = number.size(withAttributes: attributes)
        number.draw(at: CGPoint(x: pageSize.width - numberSize.width - 20,
                                y: ruleY + (footerHeight - numberSize.height) / 2),
                    withAttributes: attributes)

        let mark = "Ze" as NSString
        let markAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .heavy),
            .foregroundColor: UIColor(red: 0.35, green: 0.36, blue: 1.0, alpha: 0.55)
        ]
        let markSize = mark.size(withAttributes: markAttributes)
        mark.draw(at: CGPoint(x: 20,
                              y: ruleY + (footerHeight - markSize.height) / 2),
                  withAttributes: markAttributes)
    }

    // MARK: - Row rendering

    private func makeRowViews() -> [AnyView] {
        var views: [AnyView] = []

        if options.includeHeader, let header {
            views.append(AnyView(SessionExportHeaderCard(header: header, scheme: scheme)
                .environment(\.colorScheme, scheme).frame(width: pageWidth)))
        }

        for message in messages where scope.contains(message.id) {
            let copy = exportCopy(of: message)
            guard !copy.blocks.isEmpty || !copy.content.isEmpty else { continue }

            if message.role == .user {
                views.append(AnyView(
                    SessionExportUserRow(message: copy)
                        .environmentObject(vm)
                        .environment(\.colorScheme, scheme)
                        .frame(width: pageWidth)
                        .background(Color(background))
                ))
                continue
            }

            if message.role == .assistant {
                // The existing SessionExportAssistantTurn groups consecutive
                // tools into a disclosure header. Export each selected block as
                // its own row so no selected tool silently disappears and one
                // long reply cannot allocate a transcript-sized backing layer.
                views.append(AnyView(
                    SessionExportAssistantHeading(message: copy)
                        .environment(\.colorScheme, scheme)
                        .frame(width: pageWidth)
                ))
                for block in copy.blocks {
                    if block.kind == .thinking {
                        views.append(AnyView(
                            SessionExportThinkingContent(block: block)
                                .padding(.horizontal, 16)
                                .environment(\.colorScheme, scheme)
                                .frame(width: pageWidth)
                                .background(Color(background))
                        ))
                        continue
                    }
                    views.append(AnyView(
                        AssistantBlockView(block: block, message: copy, isActiveMessage: false,
                                           highlightedBlockId: .constant(nil), detailBlock: .constant(nil))
                            .padding(.horizontal, 16)
                            .environmentObject(vm)
                            .environment(\.colorScheme, scheme)
                            .frame(width: pageWidth)
                            .background(Color(background))
                    ))
                }
                if copy.blocks.isEmpty, !copy.content.isEmpty {
                    views.append(AnyView(
                        SelectableMarkdownView(markdown: copy.content)
                            .padding(.horizontal, 16)
                            .environment(\.colorScheme, scheme)
                            .frame(width: pageWidth)
                    ))
                }
                continue
            }

            views.append(AnyView(
                ChatMessageRow(
                    message: copy,
                    isActiveMessage: false,
                    commandStartTime: nil,
                    onStop: nil,
                    onRetry: nil,
                    onEdit: nil,
                    onDelete: nil,
                    onWithdraw: nil,
                    autoRetryAttempt: 0,
                    autoRetryCountdown: 0,
                    canResume: false,
                    onResume: nil,
                    onCompact: nil,
                    onCopyScreenshot: nil,
                    onReadAloud: nil,
                    onShowCompactSummary: nil,
                    onRevertCompact: nil,
                    onToggleUserMessageExpansion: nil,
                    browserPool: nil,
                    toolSnapshots: []
                )
                .environmentObject(vm)
                .environment(\.colorScheme, scheme)
                .frame(width: pageWidth)
                .background(Color(background))
            ))

        }

        return views
    }

    /// Builds the copy that gets rendered. Filtering blocks here (instead of
    /// inside the views) keeps the export path free of "screenshot mode"
    /// branches in the live chat UI.
    private func exportCopy(of message: ChatMessage) -> ChatMessage {
        let filtered = message.blocks.filter { block in
            switch block.kind {
            case .thinking:
                return options.includeThinking
            case .text, .info:
                return true
            default:
                return options.includeToolCalls
            }
        }

        // Explicitly selected blocks must not be discarded by the live chat's
        // finished-turn collapse preference.

        let copy = ChatMessage(role: message.role,
                               content: message.content,
                               blocks: filtered,
                               isQueued: false,
                               timestamp: message.timestamp)
        copy.usage = message.usage
        copy.firstTokenLatency = message.firstTokenLatency
        copy.taskDuration = message.taskDuration
        copy.streamInterruptCount = message.streamInterruptCount
        copy.attachments = message.attachments
        copy.inputAttachments = message.inputAttachments
        copy.isCompactedHistory = message.isCompactedHistory
        copy.systemIcon = message.systemIcon
        // The live bubble clamps long prompts behind a "show more" control;
        // an export must contain the whole prompt.
        copy.isUserTextExpanded = true
        return copy
    }

    // MARK: - Vector text

    private func drawVector(_ root: UIView, in context: CGContext) {
        root.traitCollection.performAsCurrent {
            var markdown: [MarkdownRenderView] = []
            var textViews: [UITextView] = []
            var labels: [UILabel] = []
            var hidden: [UIView] = []
            var contents: [(CALayer, Any?)] = []
            func walk(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                if let text = view as? MarkdownRenderView {
                    markdown.append(text)
                    // Its backing store contains glyphs and quote bars; preserve
                    // attachment subviews (tables/code/media) for separate drawing.
                    contents.append((text.layer, text.layer.contents))
                    text.layer.contents = nil
                } else if let text = view as? UITextView, text.textLayoutManager == nil {
                    textViews.append(text)
                    for child in text.subviews where NSStringFromClass(type(of: child)).hasPrefix("_") && !child.isHidden {
                        child.isHidden = true
                        hidden.append(child)
                    }
                } else if let label = view as? UILabel {
                    labels.append(label)
                    label.isHidden = true
                    hidden.append(label)
                    return
                }
                for child in view.subviews { walk(child) }
            }
            walk(root)
            defer {
                for view in hidden { view.isHidden = false }
                for (layer, content) in contents { layer.contents = content }
            }
            root.layer.render(in: context)

            func draw(_ view: UIView, _ body: (CGRect) -> Void) {
                var clip = view.convert(view.bounds, to: root).intersection(context.boundingBoxOfClipPath)
                var ancestor = view.superview
                var opacity = view.alpha
                while let parent = ancestor {
                    opacity *= parent.alpha
                    if parent.clipsToBounds { clip = clip.intersection(parent.convert(parent.bounds, to: root)) }
                    if parent === root { break }
                    ancestor = parent.superview
                }
                guard !clip.isEmpty else { return }
                // Three converted points preserve export-only table scaling.
                let origin = view.convert(CGPoint.zero, to: root)
                let x = view.convert(CGPoint(x: 1, y: 0), to: root)
                let y = view.convert(CGPoint(x: 0, y: 1), to: root)
                context.saveGState()
                context.clip(to: clip)
                context.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                                     c: y.x - origin.x, d: y.y - origin.y,
                                                     tx: origin.x, ty: origin.y))
                context.setAlpha(opacity)
                body(view.convert(clip, from: root))
                context.restoreGState()
            }
            for text in markdown {
                draw(text) { visible in
                    let manager = text.textLayoutManager
                    manager.ensureLayout(for: text.textContainer)
                    let glyphs = manager.glyphRange(forBoundingRect: visible, in: text.textContainer)
                    manager.drawBackground(forGlyphRange: glyphs, at: .zero)
                    manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
                }
            }
            for text in textViews {
                draw(text) { visible in
                    let manager = text.layoutManager
                    let inset = CGPoint(x: text.textContainerInset.left, y: text.textContainerInset.top)
                    let glyphs = manager.glyphRange(forBoundingRect: visible.offsetBy(dx: -inset.x, dy: -inset.y), in: text.textContainer)
                    manager.drawBackground(forGlyphRange: glyphs, at: inset)
                    manager.drawGlyphs(forGlyphRange: glyphs, at: inset)
                }
            }
            for label in labels {
                draw(label) { visible in
                    let rect = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
                    guard rect.intersects(visible) else { return }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = label.textAlignment
                    paragraph.lineBreakMode = label.lineBreakMode
                    let attributed = NSMutableAttributedString(string: label.text ?? "", attributes: [
                        .font: label.font ?? UIFont.systemFont(ofSize: 17),
                        .foregroundColor: label.textColor ?? UIColor.label, .paragraphStyle: paragraph
                    ])
                    if let source = label.attributedText {
                        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
                            attributed.addAttributes(attributes, range: range)
                        }
                    }
                    let storage = NSTextStorage(attributedString: attributed)
                    let manager = NSLayoutManager()
                    let container = NSTextContainer(size: rect.size)
                    container.lineFragmentPadding = 0
                    container.maximumNumberOfLines = label.numberOfLines
                    container.lineBreakMode = label.lineBreakMode
                    manager.addTextContainer(container)
                    storage.addLayoutManager(manager)
                    manager.ensureLayout(for: container)
                    let glyphs = manager.glyphRange(forBoundingRect: visible.offsetBy(dx: -rect.minX, dy: -rect.minY), in: container)
                    manager.drawBackground(forGlyphRange: glyphs, at: rect.origin)
                    manager.drawGlyphs(forGlyphRange: glyphs, at: rect.origin)
                }
            }
        }
    }
}

// MARK: - Offscreen host

/// Hosts SwiftUI content in a window that sits *below* the app window, so it
/// is never visible but is still attached to a real scene (which is what
/// `drawHierarchy(afterScreenUpdates:)` needs in order to render UIKit-backed
/// views such as the markdown `UITextView`).
@MainActor
private final class OffscreenHost {
    private let window: UIWindow
    private let host: UIHostingController<AnyView>
    private let width: CGFloat
    private let background: UIColor

    init?(width: CGFloat, background: UIColor, scheme: ColorScheme) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else { return nil }

        self.width = width
        self.background = background

        let host = UIHostingController(rootView: AnyView(EmptyView()))
        // An export canvas is not a screen: scene safe areas must not add a
        // status-bar/home-indicator band to each independently measured row.
        // The CI PDF showed a 900pt fixture hosted in a 962pt root with its
        // first text shifted down 45pt. Remove those inherited scene insets.
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        host.view.backgroundColor = background
        self.host = host

        let window = UIWindow(windowScene: scene)
        // Below the app's own window: attached and renderable, never seen.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        window.isHidden = false
        self.window = window
    }

    var view: UIView { host.view }

    /// Returns nil instead of silently cropping a row that exceeds the guard.
    func layout(_ view: AnyView, maxHeight: CGFloat) -> CGFloat? {
        host.rootView = AnyView(view.ignoresSafeArea().id(UUID()))
        let measured = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        guard measured.height.isFinite, measured.height > 0, measured.height <= maxHeight else { return nil }
        let height = ceil(measured.height)
        // The image output budget alone cannot bound UIKit backing stores. Check
        // the hosted row too, before giving its window the measured tall frame.
        let backingScale = max(1, window.screen.scale)
        guard width * height * backingScale * backingScale * 4 <= 96 * 1_024 * 1_024 else { return nil }
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        CATransaction.flush()
        return height
    }

    private var tables: [TableScrollView] {
        var result: [TableScrollView] = []
        func walk(_ view: UIView) {
            if let table = view as? TableScrollView { result.append(table) }
            for child in view.subviews { walk(child) }
        }
        walk(host.view)
        return result
    }

    var requiredTableCanvasWidth: CGFloat {
        tables.reduce(width) { result, table in
            max(result, SessionShareRenderPolicy.tableCanvasWidth(base: width,
                contentWidth: table.contentSize.width, viewportWidth: table.bounds.width))
        }
    }

    /// Tables wider than the bounded canvas are scaled only inside this disposable
    /// host. All columns remain visible without changing live-chat attachments.
    /// The original row height is retained (may leave whitespace below the table).
    func fitTables() {
        for table in tables {
            table.contentOffset = .zero
            table.showsHorizontalScrollIndicator = false
            guard table.contentSize.width > table.bounds.width, table.bounds.width > 0 else { continue }
            let scale = SessionShareRenderPolicy.tableScale(contentWidth: table.contentSize.width,
                                                           viewportWidth: table.bounds.width)
            for child in table.subviews where child is UIStackView {
                let original = child.frame
                child.transform = CGAffineTransform(scaleX: scale, y: scale)
                child.frame.origin = CGPoint(x: original.minX * scale, y: original.minY * scale)
            }
        }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// The live ThinkingBlockView deliberately keeps only the last 8,000 characters
/// in a 300pt scroll viewport and starts a shared hitch monitor. A share must
/// instead show the complete selected text, without those live-view side effects.
struct SessionExportThinkingContent: View {
    let block: AssistantBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("思考", systemImage: "brain")
                .font(.caption)
                .foregroundStyle(ChatColors.secondaryText)
            SessionExportVectorLabel(text: block.content,
                                     font: .systemFont(ofSize: FontSettings.shared.scaledMessage(14)),
                                     color: UIColor(ChatColors.secondaryText))
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

private struct SessionExportAssistantHeading: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SoulAvatarView(size: 22)
                let name = SoulStore.cachedMetadata.name
                SessionExportVectorLabel(text: name.isEmpty ? "Ze" : name,
                                         font: .preferredFont(forTextStyle: .headline),
                                         color: UIColor(ChatColors.primaryText))
                Spacer(minLength: 0)
            }
            if let latency = message.firstTokenLatency {
                Text("首字 \(String(format: "%.1f", latency))秒")
                    .font(.caption2)
                    .foregroundStyle(ChatColors.secondaryText)
            }
            if let duration = message.taskDuration {
                AssistantTaskDurationView(duration: duration)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

// MARK: - Vector-compatible user bubble

/// ChatMessageRow's user body is SwiftUI Text (a raster display list). An export
/// label keeps the same bubble palette/spacing while emitting visible PDF text.
private struct SessionExportUserRow: View {
    let message: ChatMessage

    private var text: String {
        var value = message.content
        if let start = value.range(of: "<user-attached-files>") {
            let end = value.range(of: "</user-attached-files>")?.upperBound ?? value.endIndex
            value = String(value[..<start.lowerBound] + value[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    UserAttachmentList(attachments: message.attachments)
                } else if !message.inputAttachments.isEmpty {
                    QueuedAttachmentPreview(attachments: message.inputAttachments)
                }
                if !text.isEmpty {
                    SessionExportVectorLabel(text: text,
                                             font: .systemFont(ofSize: FontSettings.shared.scaledMessage(16.5)),
                                             color: UIColor(ChatColors.userMessageText))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 18).fill(ChatColors.userMessageBubble))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

private struct SessionExportVectorLabel: UIViewRepresentable {
    let text: String
    let font: UIFont
    let color: UIColor

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = font
        label.textColor = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

// MARK: - Header card

/// Avatar + model name + date, drawn with the same palette as the chat so the
/// export opens like a conversation rather than a printout.
///
/// Not `private`: the share sheet's picker renders it at the top of the
/// transcript so the header toggle is visible before exporting.
struct SessionExportHeaderCard: View {
    let header: SessionExportHeader
    let scheme: ColorScheme

    /// Sampled from ZeAssistantAvatar so the wordmark matches the mark:
    /// violet (#5A5CFF) on the left of the ghost, cyan (#239CF6) on the right.
    private var brandColor: Color { Color(red: 0.35, green: 0.36, blue: 1.0) }

    private var secondary: Color {
        scheme == .dark ? Color(white: 0.66) : Color(white: 0.38)
    }

    private var primaryText: Color {
        scheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                avatar

                VStack(alignment: .leading, spacing: 2) {
                    // Wordmark rides on the title line: a separate brand row
                    // pushed the first message too far down in the export.
                    titleLine
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(header.modelName)
                        if let provider = header.providerName, !provider.isEmpty {
                            Text("·")
                            Text(provider)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                }
                Spacer(minLength: 0)
            }

            Text(dateText)
                .font(.system(size: 11))
                .foregroundStyle(secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .frame(width: nil, alignment: .leading)
        .background(Color(UIColor.systemBackground))
    }

    private var titleLine: Text {
        Text("Ze")
            .font(.system(size: 17, weight: .heavy))
            .foregroundColor(brandColor)
        + Text(" · ")
            .font(.system(size: 17, weight: .regular))
            .foregroundColor(secondary)
        + Text(header.title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(primaryText)
    }

    @ViewBuilder
    private var avatar: some View {
        if let image = header.avatar {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(Circle())
        } else if let emoji = header.avatarEmoji, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: 24))
                .frame(width: 34, height: 34)
        } else {
            // The ghost mark itself carries the gradient; it has a transparent
            // interior, so it reads correctly on both export themes.
            Image("ZeAssistantAvatar")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityLabel("Ze")
        }
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: header.date)
    }
}
