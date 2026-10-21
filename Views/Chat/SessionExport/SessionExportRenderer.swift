//
//  SessionExportRenderer.swift
//  ZeApp
//
//  [T-session-share] CoreText-based layout + raster (long image) and vector
//  (PDF) output for the "Share Session" feature.
//
//  Why CoreText and not ImageRenderer over the chat views: the chat's
//  markdown surface is a UITextView-backed UIViewRepresentable whose layout
//  depends on being in a window, so rendering it off-screen is unreliable
//  and cannot be paginated. Laying the document out ourselves gives exact
//  block heights, real PDF text (selectable, vector), and deterministic
//  pagination for arbitrarily long conversations.
//

import CoreText
import Foundation
import UIKit

// MARK: - Metrics

struct SessionExportMetrics {
    let pageWidth: CGFloat
    var horizontalInset: CGFloat = 20
    var verticalInset: CGFloat = 24

    var contentWidth: CGFloat { max(pageWidth - horizontalInset * 2, 120) }
}

// MARK: - Prepared block

struct SessionExportBlockStyle {
    var fillColor: UIColor? = nil
    var borderColor: UIColor? = nil
    var cornerRadius: CGFloat = 0
    var padding: UIEdgeInsets = .zero
    var trailingAligned: Bool = false
    /// Caps a hugging bubble; nil = full content width.
    var maxWidth: CGFloat? = nil
}

struct SessionExportPreparedBlock {
    enum Kind {
        case text
        case header(SessionExportHeader)
    }

    let kind: Kind
    let text: NSAttributedString
    let textSize: CGSize
    let style: SessionExportBlockStyle
    let spacingAfter: CGFloat
    let boxWidth: CGFloat

    var boxHeight: CGFloat {
        textSize.height + style.padding.top + style.padding.bottom
    }
}

// MARK: - Layout

final class SessionExportLayout {
    let metrics: SessionExportMetrics
    let palette: SessionExportPalette
    private(set) var prepared: [SessionExportPreparedBlock] = []
    private(set) var totalHeight: CGFloat = 0

    init(blocks: [SessionExportBlock],
         palette: SessionExportPalette,
         metrics: SessionExportMetrics) {
        self.metrics = metrics
        self.palette = palette
        prepare(blocks)
    }

    private func prepare(_ blocks: [SessionExportBlock]) {
        var y = metrics.verticalInset
        for block in blocks {
            let prepared = prepare(block)
            self.prepared.append(prepared)
            y += prepared.boxHeight + prepared.spacingAfter
        }
        totalHeight = y + metrics.verticalInset
    }

    // MARK: Block preparation

    private func prepare(_ block: SessionExportBlock) -> SessionExportPreparedBlock {
        switch block {
        case .header(let header):
            return headerBlock(header)

        case .user(let text, let attachments, _):
            return userBlock(text: text, attachments: attachments)

        case .prose(let markdown):
            let attr = SessionExportMarkdown.attributed(markdown, palette: palette)
            return textBlock(attr,
                             style: SessionExportBlockStyle(padding: .zero),
                             spacingAfter: 10)

        case .code(let text, let language):
            return codeBlock(text: text, language: language)

        case .thinking(let text, let duration):
            return thinkingBlock(text: text, duration: duration)

        case .tool(let tool):
            return toolBlock(tool)

        case .note(let text):
            return noteBlock(text)
        }
    }

    private func headerBlock(_ header: SessionExportHeader) -> SessionExportPreparedBlock {
        let style = SessionExportBlockStyle(padding: .zero)
        return SessionExportPreparedBlock(
            kind: .header(header),
            text: NSAttributedString(),
            textSize: CGSize(width: metrics.contentWidth, height: 58),
            style: style,
            spacingAfter: 18,
            boxWidth: metrics.contentWidth
        )
    }

    private func userBlock(text: String, attachments: [String]) -> SessionExportPreparedBlock {
        var markdown = text
        if !attachments.isEmpty {
            let names = attachments.map { "📎 \($0)" }.joined(separator: "\n")
            markdown += markdown.isEmpty ? names : "\n\n\(names)"
        }

        let attr = SessionExportMarkdown.attributed(markdown, palette: palette)
        let padding = UIEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
        let maxWidth = metrics.contentWidth * 0.86

        // Hug the text: measure unconstrained first, then re-measure at the
        // clamped width so the bubble never exceeds the page.
        let natural = measure(attr, width: .greatestFiniteMagnitude)
        let boxWidth = min(max(natural.width + padding.left + padding.right, 96), maxWidth)
        let textWidth = boxWidth - padding.left - padding.right
        let size = measure(attr, width: textWidth)

        let style = SessionExportBlockStyle(
            fillColor: palette.userBubbleFill,
            cornerRadius: 14,
            padding: padding,
            trailingAligned: true,
            maxWidth: maxWidth
        )

        return SessionExportPreparedBlock(
            kind: .text,
            text: attr,
            textSize: size,
            style: style,
            spacingAfter: 12,
            boxWidth: boxWidth
        )
    }

    private func codeBlock(text: String, language: String?) -> SessionExportPreparedBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byCharWrapping

        let body = NSMutableAttributedString(string: text, attributes: [
            .font: SessionExportFonts.code,
            .foregroundColor: palette.codeText,
            .paragraphStyle: paragraph,
        ])

        let style = SessionExportBlockStyle(
            fillColor: palette.codeFill,
            cornerRadius: 9,
            padding: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        )

        guard let language, !language.isEmpty else {
            return textBlock(body, style: style, spacingAfter: 10)
        }

        let result = NSMutableAttributedString(string: "\(language)\n", attributes: [
            .font: SessionExportFonts.metaBold,
            .foregroundColor: palette.tertiaryText,
            .paragraphStyle: paragraph,
        ])
        result.append(body)
        return textBlock(result, style: style, spacingAfter: 10)
    }

    private func thinkingBlock(text: String, duration: TimeInterval?) -> SessionExportPreparedBlock {
        let title: String
        if let duration, duration > 0.5 {
            title = "\(String(localized: "Thinking")) · \(formatDuration(duration))"
        } else {
            title = String(localized: "Thinking")
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 0

        let result = NSMutableAttributedString(string: title + "\n", attributes: [
            .font: SessionExportFonts.metaBold,
            .foregroundColor: palette.secondaryText,
            .paragraphStyle: paragraph,
        ])
        let body = SessionExportMarkdown.attributed(text,
                                                    palette: palette,
                                                    fontSize: SessionExportFonts.bodySize - 1)
        result.append(body)

        return textBlock(result,
                         style: SessionExportBlockStyle(
                            fillColor: palette.thinkingFill,
                            cornerRadius: 9,
                            padding: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
                         ),
                         spacingAfter: 10)
    }

    private func toolBlock(_ tool: SessionExportTool) -> SessionExportPreparedBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0

        let result = NSMutableAttributedString()

        let titleColor = tool.isFailure ? palette.danger : palette.primaryText
        result.append(NSAttributedString(string: tool.name, attributes: [
            .font: SessionExportFonts.metaBold,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph,
        ]))

        if !tool.detail.isEmpty {
            let detail = tool.detail.count > 120 ? String(tool.detail.prefix(120)) + "…" : tool.detail
            result.append(NSAttributedString(string: "  \(detail)", attributes: [
                .font: SessionExportFonts.codeSmall,
                .foregroundColor: palette.secondaryText,
                .paragraphStyle: paragraph,
            ]))
        }

        var statusParts = [tool.status]
        if let duration = tool.duration, duration > 0.05 {
            statusParts.append(formatDuration(duration))
        }
        result.append(NSAttributedString(string: "\n" + statusParts.joined(separator: " · "), attributes: [
            .font: SessionExportFonts.meta,
            .foregroundColor: tool.isFailure ? palette.danger : palette.tertiaryText,
            .paragraphStyle: paragraph,
        ]))

        if let input = tool.input {
            result.append(sectionLabel(String(localized: "Input"), paragraph: paragraph))
            result.append(monospaced(input, paragraph: paragraph))
        }

        if let output = tool.output {
            result.append(sectionLabel(String(localized: "Result"), paragraph: paragraph))
            result.append(monospaced(output, paragraph: paragraph))
        }

        return textBlock(result,
                         style: SessionExportBlockStyle(
                            fillColor: palette.cardFill,
                            borderColor: palette.cardBorder,
                            cornerRadius: 9,
                            padding: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
                         ),
                         spacingAfter: 10)
    }

    private func noteBlock(_ text: String) -> SessionExportPreparedBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 1

        let attr = NSAttributedString(string: text, attributes: [
            .font: SessionExportFonts.meta,
            .foregroundColor: palette.tertiaryText,
            .paragraphStyle: paragraph,
        ])

        return textBlock(attr,
                         style: SessionExportBlockStyle(padding: UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)),
                         spacingAfter: 8)
    }

    // MARK: Helpers

    private func textBlock(_ attr: NSAttributedString,
                           style: SessionExportBlockStyle,
                           spacingAfter: CGFloat) -> SessionExportPreparedBlock {
        let boxWidth = min(style.maxWidth ?? metrics.contentWidth, metrics.contentWidth)
        let width = boxWidth - style.padding.left - style.padding.right
        let size = measure(attr, width: max(width, 40))
        return SessionExportPreparedBlock(
            kind: .text,
            text: attr,
            textSize: size,
            style: style,
            spacingAfter: spacingAfter,
            boxWidth: boxWidth
        )
    }

    private func sectionLabel(_ title: String, paragraph: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n\n\(title)", attributes: [
            .font: SessionExportFonts.metaBold,
            .foregroundColor: palette.tertiaryText,
            .paragraphStyle: paragraph,
        ])
    }

    private func monospaced(_ text: String, paragraph: NSParagraphStyle) -> NSAttributedString {
        let copy = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        copy.lineSpacing = 1
        return NSAttributedString(string: "\n" + text, attributes: [
            .font: SessionExportFonts.codeSmall,
            .foregroundColor: palette.codeText,
            .paragraphStyle: copy,
        ])
    }

    func measure(_ attr: NSAttributedString, width: CGFloat) -> CGSize {
        guard attr.length > 0 else { return .zero }
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        var fitRange = CFRange()
        let constraint = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            constraint,
            &fitRange
        )
        return CGSize(width: min(ceil(size.width), ceil(width)), height: ceil(size.height) + 1)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return String(format: "%.0f ms", duration * 1000) }
        if duration < 60 { return String(format: "%.1f s", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Renderer

final class SessionExportRenderer {

    /// A single image slice is capped so a 200-message session cannot ask for
    /// a 60 000 px bitmap (hundreds of MB, and the app gets killed). Longer
    /// documents are emitted as several images instead.
    private static let maxSliceHeight: CGFloat = 8_000

    let layout: SessionExportLayout
    let palette: SessionExportPalette
    let metrics: SessionExportMetrics

    init(layout: SessionExportLayout,
         palette: SessionExportPalette,
         metrics: SessionExportMetrics) {
        self.layout = layout
        self.palette = palette
        self.metrics = metrics
    }

    // MARK: Long image

    /// Renders just the top of the document for the live preview strip.
    /// Cheap enough to re-run on every option change: it stops after the
    /// first screenful instead of laying out the whole conversation.
    func makePreviewImage(maxHeight: CGFloat = 900) -> UIImage? {
        guard layout.totalHeight > 1, !layout.prepared.isEmpty else { return nil }
        let height = min(layout.totalHeight, maxHeight)
        guard height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: metrics.pageWidth, height: height),
            format: format
        )

        return renderer.image { context in
            let cg = context.cgContext
            cg.textMatrix = .identity
            cg.translateBy(x: 0, y: height)
            cg.scaleBy(x: 1, y: -1)

            cg.setFillColor(palette.background.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: metrics.pageWidth, height: height))

            var y = metrics.verticalInset
            for prepared in layout.prepared {
                if y > height { break }
                drawBlock(prepared, ctx: cg, y: y, textOffset: 0, height: nil)
                y += prepared.boxHeight + prepared.spacingAfter
            }
        }
    }

    func makeImages() -> [UIImage] {
        let total = layout.totalHeight
        guard total > 1, !layout.prepared.isEmpty else { return [] }

        // Cut only at block boundaries: slicing mid-paragraph leaves the last
        // line of one image and the first line of the next one visually
        // chopped. A single block taller than the cap still has to be cut.
        var boundaries: [CGFloat] = [0]
        var cursor = metrics.verticalInset
        for prepared in layout.prepared {
            cursor += prepared.boxHeight + prepared.spacingAfter
            if cursor - boundaries[boundaries.count - 1] >= Self.maxSliceHeight {
                boundaries.append(cursor)
            }
        }
        if let last = boundaries.last, total - last > 1 {
            boundaries.append(total)
        }
        if boundaries.count < 2 {
            boundaries = [0, total]
        }

        let scale: CGFloat = metrics.pageWidth > 500 ? 1.5 : 2
        var images: [UIImage] = []

        for sliceIndex in 0..<(boundaries.count - 1) {
            let start = boundaries[sliceIndex]
            let height = boundaries[sliceIndex + 1] - start
            guard height > 1 else { continue }

            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard

            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: metrics.pageWidth, height: height),
                format: format
            )

            let image = renderer.image { context in
                let cg = context.cgContext
                cg.textMatrix = .identity
                // Document space (y down) → bitmap space for this slice.
                cg.translateBy(x: 0, y: height + start)
                cg.scaleBy(x: 1, y: -1)

                cg.setFillColor(palette.background.cgColor)
                cg.fill(CGRect(x: 0, y: start, width: metrics.pageWidth, height: height))

                var y = metrics.verticalInset
                for prepared in layout.prepared {
                    drawBlock(prepared, ctx: cg, y: y, textOffset: 0, height: nil)
                    y += prepared.boxHeight + prepared.spacingAfter
                }
            }
            images.append(image)
        }

        return images
    }

    // MARK: PDF

    func makePDFData() -> Data? {
        guard layout.totalHeight > 1, !layout.prepared.isEmpty else { return nil }

        let pageWidth = metrics.pageWidth
        let pageHeight = (pageWidth * 1.4142).rounded()
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var pageTop: CGFloat = 0
        var docY = metrics.verticalInset
        var index = 0
        var textOffset = 0
        var pageNumber = 0
        var stagnantPages = 0

        while index < layout.prepared.count, pageNumber < 4_000 {
            pageNumber += 1
            ctx.beginPDFPage(nil)

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: pageHeight + pageTop)
            ctx.scaleBy(x: 1, y: -1)

            ctx.setFillColor(palette.background.cgColor)
            ctx.fill(CGRect(x: 0, y: pageTop, width: pageWidth, height: pageHeight))

            let contentBottom = pageTop + pageHeight - metrics.verticalInset
            let indexAtPageStart = index
            let offsetAtPageStart = textOffset
            var guardCounter = 0

            while index < layout.prepared.count, guardCounter < 400 {
                guardCounter += 1
                let prepared = layout.prepared[index]
                let available = contentBottom - docY
                if available <= 1 { break }

                let padding = prepared.style.padding

                if case .header = prepared.kind {
                    guard prepared.boxHeight <= available else { break }
                    drawBlock(prepared, ctx: ctx, y: docY, textOffset: 0, height: nil)
                    docY += prepared.boxHeight + prepared.spacingAfter
                    index += 1
                    textOffset = 0
                    continue
                }

                let textWidth = prepared.boxWidth - padding.left - padding.right
                let remainingRange = NSRange(location: textOffset,
                                             length: max(prepared.text.length - textOffset, 0))
                let remaining = remainingRange.length > 0
                    ? prepared.text.attributedSubstring(from: remainingRange)
                    : NSAttributedString()
                let textHeight = remaining.length > 0
                    ? layout.measure(remaining, width: max(textWidth, 40)).height
                    : 0
                let boxHeight = textHeight + padding.top + padding.bottom

                if boxHeight <= available + 0.5 {
                    drawBlock(prepared, ctx: ctx, y: docY, textOffset: textOffset, height: nil)
                    docY += boxHeight + prepared.spacingAfter
                    index += 1
                    textOffset = 0
                    continue
                }

                // Split this block across the page break.
                let sliceTextHeight = available - padding.top - padding.bottom
                if sliceTextHeight >= 22, remaining.length > 0 {
                    let consumed = drawBlock(prepared,
                                             ctx: ctx,
                                             y: docY,
                                             textOffset: textOffset,
                                             height: available)
                    textOffset += max(consumed, 1)
                    if textOffset >= prepared.text.length {
                        index += 1
                        textOffset = 0
                    }
                }
                break
            }

            drawPageFooter(pageNumber, pageTop: pageTop, pageHeight: pageHeight, ctx: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()

            if index == indexAtPageStart, textOffset == offsetAtPageStart {
                stagnantPages += 1
                if stagnantPages >= 2 { break }
            } else {
                stagnantPages = 0
            }

            pageTop += pageHeight
            docY = pageTop + metrics.verticalInset
        }

        ctx.closePDF()
        return data as Data
    }

    private func drawPageFooter(_ number: Int, pageTop: CGFloat, pageHeight: CGFloat, ctx: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: palette.tertiaryText,
        ]
        let attr = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = layout.measure(attr, width: 100)
        let rect = CGRect(x: metrics.pageWidth - metrics.horizontalInset - size.width,
                          y: pageTop + pageHeight - metrics.verticalInset + 6,
                          width: size.width,
                          height: size.height)
        drawText(attr, in: rect, ctx: ctx, constrained: false)
    }

    // MARK: Drawing

    /// Draws one prepared block. Returns the number of characters consumed
    /// when `height` is non-nil (a sliced PDF block), otherwise 0.
    @discardableResult
    private func drawBlock(_ prepared: SessionExportPreparedBlock,
                           ctx: CGContext,
                           y: CGFloat,
                           textOffset: Int,
                           height: CGFloat?) -> Int {
        let padding = prepared.style.padding
        let boxWidth = prepared.boxWidth
        let x = metrics.horizontalInset
            + (prepared.style.trailingAligned ? max(metrics.contentWidth - boxWidth, 0) : 0)

        let boxHeight = height ?? prepared.boxHeight
        let box = CGRect(x: x, y: y, width: boxWidth, height: boxHeight)

        if prepared.style.fillColor != nil || prepared.style.borderColor != nil {
            let path = UIBezierPath(roundedRect: box, cornerRadius: prepared.style.cornerRadius)
            if let fill = prepared.style.fillColor {
                ctx.setFillColor(fill.cgColor)
                ctx.addPath(path.cgPath)
                ctx.fillPath()
            }
            if let border = prepared.style.borderColor {
                ctx.setStrokeColor(border.cgColor)
                ctx.setLineWidth(0.6)
                ctx.addPath(path.cgPath)
                ctx.strokePath()
            }
        }

        if case .header(let header) = prepared.kind {
            drawHeader(header, ctx: ctx, rect: box)
            return 0
        }

        guard prepared.text.length > 0 else { return 0 }

        let textRect = CGRect(
            x: box.minX + padding.left,
            y: box.minY + padding.top,
            width: max(boxWidth - padding.left - padding.right, 20),
            height: max(boxHeight - padding.top - padding.bottom, 1)
        )

        let attr: NSAttributedString
        if textOffset > 0, textOffset < prepared.text.length {
            attr = prepared.text.attributedSubstring(
                from: NSRange(location: textOffset, length: prepared.text.length - textOffset)
            )
        } else if textOffset >= prepared.text.length {
            return 0
        } else {
            attr = prepared.text
        }

        return drawText(attr, in: textRect, ctx: ctx, constrained: height != nil)
    }

    @discardableResult
    private func drawText(_ attr: NSAttributedString,
                          in rect: CGRect,
                          ctx: CGContext,
                          constrained: Bool) -> Int {
        guard attr.length > 0, rect.height > 0.5 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attr.length),
            path,
            nil
        )
        CTFrameDraw(frame, ctx)
        let visible = CTFrameGetVisibleStringRange(frame)
        return constrained ? visible.length : attr.length
    }

    private func drawHeader(_ header: SessionExportHeader,
                            ctx: CGContext,
                            rect: CGRect) {
        let avatarSize: CGFloat = 44
        let avatarRect = CGRect(x: rect.minX, y: rect.minY + 2, width: avatarSize, height: avatarSize)
        drawAvatar(header, ctx: ctx, rect: avatarRect)

        let textX = rect.minX + avatarSize + 12
        let textWidth = max(rect.width - avatarSize - 12, 80)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: header.title + "\n", attributes: [
            .font: SessionExportFonts.title,
            .foregroundColor: palette.primaryText,
            .paragraphStyle: paragraph,
        ]))

        let meta = header.providerName.map { "\($0) · \(header.modelName)" } ?? header.modelName
        if !meta.isEmpty {
            result.append(NSAttributedString(string: meta + "\n", attributes: [
                .font: SessionExportFonts.meta,
                .foregroundColor: palette.secondaryText,
                .paragraphStyle: paragraph,
            ]))
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        result.append(NSAttributedString(string: formatter.string(from: header.date), attributes: [
            .font: SessionExportFonts.meta,
            .foregroundColor: palette.tertiaryText,
            .paragraphStyle: paragraph,
        ]))

        let textRect = CGRect(x: textX, y: rect.minY + 1, width: textWidth, height: avatarSize)
        drawText(result, in: textRect, ctx: ctx, constrained: false)

        // Hairline under the header.
        ctx.setStrokeColor(palette.divider.cgColor)
        ctx.setLineWidth(0.6)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY - 2))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 2))
        ctx.strokePath()
    }

    private func drawAvatar(_ header: SessionExportHeader,
                            ctx: CGContext,
                            rect: CGRect) {
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()

        if let image = header.avatar, let cgImage = image.cgImage {
            ctx.setFillColor(palette.cardFill.cgColor)
            ctx.fill(rect)
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
            return
        }

        ctx.setFillColor(palette.cardFill.cgColor)
        ctx.fill(rect)

        let text: String
        if let emoji = header.avatarEmoji, !emoji.isEmpty {
            text = emoji
        } else {
            text = "Z"
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attr = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: palette.secondaryText,
            .paragraphStyle: paragraph,
        ])
        let size = layout.measure(attr, width: rect.width)
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - size.height / 2,
            width: rect.width,
            height: size.height
        )
        drawText(attr, in: textRect, ctx: ctx, constrained: false)
        ctx.restoreGState()
    }
}
