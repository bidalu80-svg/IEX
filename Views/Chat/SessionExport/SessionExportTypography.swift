//
//  SessionExportTypography.swift
//  ZeApp
//
//  [T-session-share] Palette + markdown → NSAttributedString for the export
//  renderer. Deliberately independent of the chat UI's UIKit views: the
//  export must be layoutable off-screen (ImageRenderer / CGPDFContext),
//  where UITextView-backed markdown views do not lay out reliably.
//

import Foundation
import UIKit

// MARK: - Palette

struct SessionExportPalette {
    let isDark: Bool

    let background: UIColor
    let primaryText: UIColor
    let secondaryText: UIColor
    let tertiaryText: UIColor

    let userBubbleFill: UIColor
    let userBubbleText: UIColor

    let cardFill: UIColor
    let cardBorder: UIColor
    let codeFill: UIColor
    let codeText: UIColor
    let inlineCodeFill: UIColor
    let inlineCodeText: UIColor

    let thinkingFill: UIColor
    let accent: UIColor
    let danger: UIColor
    let divider: UIColor
    let quoteBar: UIColor

    static func palette(for theme: SessionExportTheme) -> SessionExportPalette {
        switch theme {
        case .light:
            return SessionExportPalette(
                isDark: false,
                background: UIColor.white,
                primaryText: UIColor(white: 0.07, alpha: 1),
                secondaryText: UIColor(white: 0.40, alpha: 1),
                tertiaryText: UIColor(white: 0.55, alpha: 1),
                userBubbleFill: UIColor(red: 0.87, green: 0.94, blue: 0.99, alpha: 1),
                userBubbleText: UIColor(red: 0.02, green: 0.33, blue: 0.60, alpha: 1),
                cardFill: UIColor(white: 0.965, alpha: 1),
                cardBorder: UIColor(white: 0.89, alpha: 1),
                codeFill: UIColor(white: 0.955, alpha: 1),
                codeText: UIColor(white: 0.13, alpha: 1),
                inlineCodeFill: UIColor(white: 0.92, alpha: 1),
                inlineCodeText: UIColor(red: 0.62, green: 0.16, blue: 0.24, alpha: 1),
                thinkingFill: UIColor(red: 0.96, green: 0.95, blue: 1.0, alpha: 1),
                accent: UIColor(red: 0.04, green: 0.40, blue: 0.76, alpha: 1),
                danger: UIColor(red: 0.83, green: 0.20, blue: 0.16, alpha: 1),
                divider: UIColor(white: 0.88, alpha: 1),
                quoteBar: UIColor(white: 0.78, alpha: 1)
            )
        case .dark:
            return SessionExportPalette(
                isDark: true,
                background: UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1),
                primaryText: UIColor(white: 0.92, alpha: 1),
                secondaryText: UIColor(white: 0.63, alpha: 1),
                tertiaryText: UIColor(white: 0.48, alpha: 1),
                userBubbleFill: UIColor(red: 0.09, green: 0.21, blue: 0.32, alpha: 1),
                userBubbleText: UIColor(red: 0.85, green: 0.93, blue: 1.0, alpha: 1),
                cardFill: UIColor(white: 0.13, alpha: 1),
                cardBorder: UIColor(white: 0.21, alpha: 1),
                codeFill: UIColor(white: 0.11, alpha: 1),
                codeText: UIColor(white: 0.87, alpha: 1),
                inlineCodeFill: UIColor(white: 0.20, alpha: 1),
                inlineCodeText: UIColor(red: 1.0, green: 0.60, blue: 0.62, alpha: 1),
                thinkingFill: UIColor(red: 0.12, green: 0.11, blue: 0.19, alpha: 1),
                accent: UIColor(red: 0.36, green: 0.66, blue: 1.0, alpha: 1),
                danger: UIColor(red: 1.0, green: 0.45, blue: 0.40, alpha: 1),
                divider: UIColor(white: 0.22, alpha: 1),
                quoteBar: UIColor(white: 0.35, alpha: 1)
            )
        }
    }
}

// MARK: - Fonts

enum SessionExportFonts {
    static let bodySize: CGFloat = 15
    static let codeSize: CGFloat = 12.5
    static let metaSize: CGFloat = 11.5
    static let titleSize: CGFloat = 17

    static var body: UIFont { .systemFont(ofSize: bodySize) }
    static var bodyMedium: UIFont { .systemFont(ofSize: bodySize, weight: .medium) }
    static var bodyBold: UIFont { .systemFont(ofSize: bodySize, weight: .semibold) }
    static var meta: UIFont { .systemFont(ofSize: metaSize) }
    static var metaBold: UIFont { .systemFont(ofSize: metaSize, weight: .semibold) }
    static var title: UIFont { .systemFont(ofSize: titleSize, weight: .semibold) }
    static var code: UIFont { .monospacedSystemFont(ofSize: codeSize, weight: .regular) }
    static var codeSmall: UIFont { .monospacedSystemFont(ofSize: codeSize - 0.5, weight: .regular) }
}

// MARK: - Markdown

enum SessionExportMarkdown {

    /// Paragraph spacing used between logical blocks inside one prose run.
    private static let paragraphSpacing: CGFloat = 9

    static func attributed(_ markdown: String,
                           palette: SessionExportPalette,
                           fontSize: CGFloat = SessionExportFonts.bodySize) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        var index = 0
        var pendingParagraph: [String] = []

        func flushParagraph() {
            guard !pendingParagraph.isEmpty else { return }
            let text = pendingParagraph.joined(separator: "\n")
            pendingParagraph.removeAll()
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = paragraphSpacing
            paragraph.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: palette.primaryText,
                .paragraphStyle: paragraph,
            ]
            output.append(inline(text, attributes: attributes, palette: palette, fontSize: fontSize))
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: UIFont.systemFont(ofSize: 2),
                .paragraphStyle: paragraph,
            ]))
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            index += 1

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                output.append(horizontalRule(palette: palette))
                continue
            }

            if let heading = headingMatch(trimmed) {
                flushParagraph()
                output.append(headingAttributed(text: heading.text,
                                                level: heading.level,
                                                palette: palette,
                                                baseSize: fontSize))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                let quoteLines = [String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)]
                output.append(quote(quoteLines.joined(separator: "\n"),
                                    palette: palette,
                                    fontSize: fontSize))
                continue
            }

            if let bullet = bulletMatch(raw) {
                flushParagraph()
                output.append(listItem(marker: "•",
                                       text: bullet,
                                       palette: palette,
                                       fontSize: fontSize,
                                       indent: 16))
                continue
            }

            if let ordered = orderedMatch(raw) {
                flushParagraph()
                output.append(listItem(marker: ordered.marker,
                                       text: ordered.text,
                                       palette: palette,
                                       fontSize: fontSize,
                                       indent: 22))
                continue
            }

            if trimmed.contains("|"), trimmed.hasPrefix("|") {
                flushParagraph()
                output.append(tableRow(trimmed, palette: palette))
                continue
            }

            pendingParagraph.append(raw)
        }

        flushParagraph()
        trimTrailingNewline(output)
        return output
    }

    // MARK: - Block helpers

    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level > 0, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        return (level, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func bulletMatch(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedMatch(_ line: String) -> (marker: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var digits = ""
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
            digits.append(trimmed[cursor])
            cursor = trimmed.index(after: cursor)
        }
        guard !digits.isEmpty, cursor < trimmed.endIndex else { return nil }
        let separator = trimmed[cursor]
        guard separator == "." || separator == ")" else { return nil }
        let after = trimmed.index(after: cursor)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        let text = String(trimmed[trimmed.index(after: after)...])
        return ("\(digits).", text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" }
            || compact.allSatisfy { $0 == "*" }
            || compact.allSatisfy { $0 == "_" }
    }

    private static func headingAttributed(text: String,
                                          level: Int,
                                          palette: SessionExportPalette,
                                          baseSize: CGFloat) -> NSAttributedString {
        let size: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: size = baseSize + 6; weight = .bold
        case 2: size = baseSize + 4; weight = .bold
        case 3: size = baseSize + 2; weight = .semibold
        default: size = baseSize + 0.5; weight = .semibold
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacingBefore = 10
        paragraph.paragraphSpacing = 5

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: palette.primaryText,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(
            attributedString: inline(text, attributes: attributes, palette: palette, fontSize: size)
        )
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 2),
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    private static func listItem(marker: String,
                                 text: String,
                                 palette: SessionExportPalette,
                                 fontSize: CGFloat,
                                 indent: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = indent
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: palette.primaryText,
            .paragraphStyle: paragraph,
        ]

        let result = NSMutableAttributedString(string: "\(marker)\t", attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: palette.secondaryText,
            .paragraphStyle: paragraph,
        ])
        result.append(inline(text, attributes: attributes, palette: palette, fontSize: fontSize))
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 2),
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    private static func quote(_ text: String,
                              palette: SessionExportPalette,
                              fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        paragraph.headIndent = 12
        paragraph.firstLineHeadIndent = 12

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: palette.secondaryText,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: "▍ ", attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: palette.quoteBar,
            .paragraphStyle: paragraph,
        ])
        result.append(inline(text, attributes: attributes, palette: palette, fontSize: fontSize))
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: UIFont.systemFont(ofSize: 2),
            .paragraphStyle: paragraph,
        ]))
        return result
    }

    private static func tableRow(_ text: String, palette: SessionExportPalette) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: SessionExportFonts.codeSize, weight: .regular),
            .foregroundColor: palette.codeText,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        result.append(NSAttributedString(string: "\n", attributes: attributes))
        return result
    }

    private static func horizontalRule(palette: SessionExportPalette) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 8
        paragraph.paragraphSpacing = 8
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: palette.divider,
            .paragraphStyle: paragraph,
        ]
        return NSAttributedString(string: String(repeating: "─", count: 40) + "\n", attributes: attributes)
    }

    private static func trimTrailingNewline(_ string: NSMutableAttributedString) {
        while string.length > 0, string.string.hasSuffix("\n") {
            string.deleteCharacters(in: NSRange(location: string.length - 1, length: 1))
        }
    }

    // MARK: - Inline

    /// Handles `code`, **bold**, *italic*, ~~strike~~ and [links](url).
    /// A hand-rolled scanner instead of AttributedString(markdown:) because
    /// the Foundation bridge drops inline presentation intents when the
    /// value is converted back to NSAttributedString for CoreText.
    private static func inline(_ text: String,
                               attributes: [NSAttributedString.Key: Any],
                               palette: SessionExportPalette,
                               fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var buffer = ""
        var index = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: attributes))
            buffer.removeAll(keepingCapacity: true)
        }

        func boldFont() -> UIFont {
            let base = attributes[.font] as? UIFont
            let size = base?.pointSize ?? fontSize
            return UIFont.systemFont(ofSize: size, weight: .semibold)
        }

        func italicFont() -> UIFont {
            let base = attributes[.font] as? UIFont
            let size = base?.pointSize ?? fontSize
            let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits(.traitItalic)
            return descriptor.flatMap { UIFont(descriptor: $0, size: size) }
                ?? UIFont.italicSystemFont(ofSize: size)
        }

        while index < text.endIndex {
            let character = text[index]

            // Escaped marker.
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    buffer.append(text[next])
                    index = text.index(after: next)
                    continue
                }
            }

            if character == "`" {
                if let end = findClosing("`", in: text, from: text.index(after: index)) {
                    flush()
                    let code = String(text[text.index(after: index)..<end])
                    var codeAttributes = attributes
                    codeAttributes[.font] = UIFont.monospacedSystemFont(ofSize: fontSize * 0.92, weight: .regular)
                    codeAttributes[.foregroundColor] = palette.inlineCodeText
                    codeAttributes[.backgroundColor] = palette.inlineCodeFill
                    result.append(NSAttributedString(string: code, attributes: codeAttributes))
                    index = text.index(after: end)
                    continue
                }
            }

            if text[index...].hasPrefix("**") || text[index...].hasPrefix("__") {
                let marker = String(text[index...].prefix(2))
                let start = text.index(index, offsetBy: 2)
                if let end = findClosing(marker, in: text, from: start) {
                    flush()
                    var boldAttributes = attributes
                    boldAttributes[.font] = boldFont()
                    let inner = String(text[start..<end])
                    result.append(inline(inner, attributes: boldAttributes, palette: palette, fontSize: fontSize))
                    index = text.index(end, offsetBy: 2)
                    continue
                }
            }

            if character == "*" || character == "_" {
                let marker = String(character)
                let start = text.index(after: index)
                if let end = findClosing(marker, in: text, from: start), end > start {
                    flush()
                    var italicAttributes = attributes
                    italicAttributes[.font] = italicFont()
                    let inner = String(text[start..<end])
                    result.append(inline(inner, attributes: italicAttributes, palette: palette, fontSize: fontSize))
                    index = text.index(after: end)
                    continue
                }
            }

            if text[index...].hasPrefix("~~") {
                let start = text.index(index, offsetBy: 2)
                if let end = findClosing("~~", in: text, from: start) {
                    flush()
                    var strikeAttributes = attributes
                    strikeAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    let inner = String(text[start..<end])
                    result.append(NSAttributedString(string: inner, attributes: strikeAttributes))
                    index = text.index(end, offsetBy: 2)
                    continue
                }
            }

            if character == "[" {
                if let closeBracket = text.index(of: "]", after: index),
                   closeBracket < text.endIndex,
                   text.index(after: closeBracket) < text.endIndex,
                   text[text.index(after: closeBracket)] == "(",
                   let closeParen = text.index(of: ")", after: text.index(after: closeBracket)) {
                    flush()
                    let label = String(text[text.index(after: index)..<closeBracket])
                    var linkAttributes = attributes
                    linkAttributes[.foregroundColor] = palette.accent
                    linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    result.append(NSAttributedString(string: label, attributes: linkAttributes))
                    index = text.index(after: closeParen)
                    continue
                }
            }

            buffer.append(character)
            index = text.index(after: index)
        }

        flush()
        return result
    }

    private static func findClosing(_ marker: String,
                                    in text: String,
                                    from start: String.Index) -> String.Index? {
        guard start <= text.endIndex else { return nil }
        var cursor = start
        while cursor < text.endIndex {
            if text[cursor...].hasPrefix(marker) { return cursor }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}

private extension String {
    func index(of character: Character, after start: String.Index) -> String.Index? {
        var cursor = index(after: start)
        while cursor < endIndex {
            if self[cursor] == character { return cursor }
            cursor = index(after: cursor)
        }
        return nil
    }
}
