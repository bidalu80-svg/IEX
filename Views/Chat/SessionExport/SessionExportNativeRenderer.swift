//
//  SessionExportNativeRenderer.swift
//  ZeApp
//
//  [T-session-share-native] Renders the export from the REAL chat views.
//
//  The first cut of this feature drew the transcript with CoreText, which
//  produced a document-looking page: no bubbles, no avatar row, no
//  "first token / task duration" pills, no collapsed tool steps. That is not
//  what "copy screenshot" produces, and it is not what users expect from
//  "share session".
//
//  This renderer instead hosts the same `ChatMessageRow` the message list
//  uses, offscreen, at the requested width / colour scheme, and snapshots it
//  with `drawHierarchy(afterScreenUpdates:)` — the same technique the
//  scrolling turn-screenshot uses. Options are applied by filtering the
//  message's blocks before handing it to the row, so the exported rows stay
//  pixel-identical to the live UI.
//

import SwiftUI
import UIKit

@MainActor
final class SessionExportNativeRenderer {

    /// A single output image is capped so a long session cannot ask for a
    /// 60 000 px bitmap. Longer transcripts become several images.
    private static let maxSliceHeight: CGFloat = 8_000
    /// Sanity cap for one offscreen row. A collapsed tool list keeps rows
    /// short, so this only guards against pathological text dumps.
    private static let maxRowHeight: CGFloat = 20_000

    private let messages: [ChatMessage]
    private let scope: SessionExportScope
    private let options: SessionExportOptions
    private let header: SessionExportHeader?
    private let vm: AIChatViewModel
    private let pageWidth: CGFloat

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
            : UIColor.systemBackground
    }

    // MARK: - Public entry points

    /// Long-image output. Returns one or more slices, top to bottom.
    func makeImages() -> [UIImage] {
        let rows = makeRowImages()
        guard !rows.isEmpty else { return [] }
        return Self.slice(Self.stitch(rows, background: background, width: pageWidth),
                          maxHeight: Self.maxSliceHeight,
                          scale: 2)
    }

    /// A short top-of-document image for the live preview strip.
    func makePreviewImage(maxHeight: CGFloat = 900) -> UIImage? {
        let rows = Array(makeRowImages(limit: 4).prefix(4))
        guard !rows.isEmpty else { return nil }
        let tall = Self.stitch(rows, background: background, width: pageWidth)
        let height = min(tall.size.height, maxHeight)
        guard height > 1 else { return nil }
        let rect = CGRect(x: 0, y: 0,
                          width: tall.size.width * tall.scale,
                          height: height * tall.scale)
        guard let cg = tall.cgImage?.cropping(to: rect) else { return tall }
        return UIImage(cgImage: cg, scale: tall.scale, orientation: .up)
    }

    /// Vector PDF: the rendered rows are drawn page by page. Text stays
    /// raster because the source is a snapshot of the live view hierarchy —
    /// that is the price of matching the chat UI pixel for pixel.
    /// Paginated PDF. The rows are already raster (they are snapshots of the
    /// live view hierarchy), so pages are drawn with `UIGraphicsPDFRenderer`:
    /// it owns the PDF y-up coordinate flip, which a raw `CGPDFContext` does
    /// not — drawing straight into `CGContext` produced an upside-down page.
    func makePDFData() -> Data? {
        let rows = makeRowImages()
        guard !rows.isEmpty else { return nil }
        let long = Self.stitch(rows, background: background, width: pageWidth)

        let pageSize = CGSize(width: pageWidth, height: (pageWidth * 1.4142).rounded())
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let scale = long.scale
        let pixelHeight = long.size.height * scale

        // [T-share-pdf-page-number] Reserve a footer band on every page so the
        // page number never lands on top of the transcript.
        let footerHeight: CGFloat = 26
        let contentHeight = pageSize.height - footerHeight
        let pixelPage = contentHeight * scale
        let pageCount = max(Int((pixelHeight / pixelPage).rounded(.up)), 1)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            for page in 0..<pageCount {
                ctx.beginPage()
                background.setFill()
                // `UIGraphicsPDFRendererContext` is not a CGContext; the fill
                // has to go through the context it wraps.
                ctx.cgContext.fill(pageRect)

                let offset = CGFloat(page) * pixelPage
                let sliceHeight = min(pixelPage, pixelHeight - offset)
                if sliceHeight > 0,
                   let slice = long.cgImage?.cropping(to: CGRect(x: 0,
                                                                 y: offset,
                                                                 width: long.size.width * scale,
                                                                 height: sliceHeight)) {
                    let image = UIImage(cgImage: slice, scale: scale, orientation: .up)
                    image.draw(in: CGRect(x: 0, y: 0,
                                          width: pageWidth,
                                          height: sliceHeight / scale))
                }

                drawFooter(page: page + 1,
                           total: pageCount,
                           pageSize: pageSize,
                           footerHeight: footerHeight)
                ctx.endPage()
            }
        }
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

    private func makeRowImages(limit: Int? = nil) -> [UIImage] {
        var views: [AnyView] = []

        if options.includeHeader, let header {
            views.append(AnyView(SessionExportHeaderCard(header: header, scheme: scheme)))
        }

        let scoped = messages.filter { scope.contains($0.id) }
        let picked = limit.map { Array(scoped.prefix($0)) } ?? scoped

        for message in picked {
            let copy = exportCopy(of: message)
            guard !copy.blocks.isEmpty || !copy.content.isEmpty else { continue }

            if message.role == .assistant {
                // The list renders an assistant reply as three separate cells.
                // Reusing that composition is what keeps the avatar/name row,
                // the first-token pill, the task duration, the token capsule
                // and the copy/play/retry bar in the export — exactly what the
                // copy-screenshot path captures.
                let bridge = CellStateBridgeV2()
                bridge.isActiveMessage = false
                bridge.showUsage = copy.usage != nil
                bridge.usageContentVisible = true
                bridge.showsCompletionActions = true
                // The bar disables these two buttons when their closures are
                // nil, which would export a greyed-out play/retry pair. The
                // closures never fire — the turn is rendered offscreen.
                bridge.onReadAloud = {}
                bridge.onRetry = {}

                views.append(AnyView(
                    SessionExportAssistantTurn(message: copy, bridge: bridge, maxWidth: 0)
                        .environmentObject(vm)
                        .environment(\.colorScheme, scheme)
                        .frame(width: pageWidth)
                        .background(Color(background))
                ))
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

        guard let host = OffscreenHost(width: pageWidth,
                                       background: background,
                                       scheme: scheme) else { return [] }

        var images: [UIImage] = []
        for view in views {
            if let image = host.snapshot(view, maxHeight: Self.maxRowHeight) {
                images.append(image)
            }
        }
        host.tearDown()
        return images
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

    // MARK: - Stitching

    private static func stitch(_ images: [UIImage], background: UIColor, width: CGFloat) -> UIImage {
        let scale: CGFloat = 2
        let heights = images.map { $0.size.height }
        let total = heights.reduce(0, +)
        let size = CGSize(width: width, height: max(total, 1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var y: CGFloat = 0
            for image in images {
                image.draw(in: CGRect(x: 0, y: y, width: width, height: image.size.height))
                y += image.size.height
            }
        }
    }

    private static func slice(_ image: UIImage, maxHeight: CGFloat, scale: CGFloat) -> [UIImage] {
        let pixelHeight = image.size.height * image.scale
        let maxPixel = maxHeight * scale
        guard pixelHeight > maxPixel, let cg = image.cgImage else { return [image] }

        var slices: [UIImage] = []
        var offset: CGFloat = 0
        while offset < pixelHeight {
            let height = min(maxPixel, pixelHeight - offset)
            if let crop = cg.cropping(to: CGRect(x: 0, y: offset,
                                                 width: image.size.width * image.scale,
                                                 height: height)) {
                slices.append(UIImage(cgImage: crop, scale: image.scale, orientation: .up))
            }
            offset += maxPixel
        }
        return slices.isEmpty ? [image] : slices
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

    func snapshot(_ view: AnyView, maxHeight: CGFloat) -> UIImage? {
        host.rootView = view

        let measured = host.sizeThatFits(in: CGSize(width: width, height: maxHeight))
        let height = max(min(ceil(measured.height), maxHeight), 1)

        // The window owns the root view's frame, so it has to be as tall as
        // the content — a shorter window would clip the row during layout.
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        CATransaction.flush()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            background.setFill()
            ctx.fill(bounds)
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
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
