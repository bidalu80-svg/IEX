import SwiftUI
import UIKit
import PDFKit

// Only the renderer's row factory is replaced by this fixture VM. The temporary
// compiled renderer retains production offscreen hosting, measurement, PDF page
// loop, vector glyph drawing, image slicing, memory guards, and metadata.
@MainActor final class AIChatViewModel: ObservableObject {
    var fixtureRows: [AnyView] = []
}
// These types only satisfy production type tests. The checks below exercise
// real UILabel and TextKit 1 UITextView branches, NOT Ze Markdown/tables.
final class MarkdownRenderView: UIView {
    let textLayoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(size: .zero)
}
final class TableScrollView: UIScrollView {}

private struct FixtureText: UIViewRepresentable {
    let text: String
    let textKit: Bool
    func makeUIView(context: Context) -> UIView {
        if textKit {
            let view = UITextView(usingTextLayoutManager: false)
            view.isScrollEnabled = false
            view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            view.font = .systemFont(ofSize: 16)
            view.text = text
            view.textColor = .black
            view.backgroundColor = .white
            return view
        }
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16)
        label.textColor = .black
        label.backgroundColor = .white
        return label
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

enum SessionShareRenderChecks {
    @MainActor static func run(documents: URL) throws -> [String] {
        var checks: [String] = []
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) throws {
            if value { checks.append(label) } else { failures.append(label) }
        }
        let vm = AIChatViewModel()
        // PDFKit evidence from the underscore fixture was "ZE\nBODY\nALPHA\n_\n_",
        // while pypdf extracted the original token contiguously. This fixture
        // triggered baseline-based run grouping, not missing/duplicate glyphs.
        // Use one alphabetic word for the glyph-presence regression; underscore
        // copy ordering remains an unresolved PDFKit interoperability limitation.
        // Passing this check does NOT establish identical extraction for all text.
        let sentinels = ["ZeBodyAlpha", "ZeBodyBravo", "ZeBodyCharlie"]
        vm.fixtureRows = sentinels.enumerated().map { index, text in
            AnyView(FixtureText(text: text, textKit: index != 1).frame(height: 900))
        }
        var options = SessionExportOptions()
        options.includeHeader = false
        options.width = .phone
        let title = "ZE_PRIVATE_TITLE"
        let header = SessionExportHeader(title: title, modelName: "Fixture", providerName: nil, date: Date(timeIntervalSince1970: 0), avatar: nil, avatarEmoji: nil)
        func renderer(_ settings: SessionExportOptions? = nil) -> SessionExportNativeRenderer {
            SessionExportNativeRenderer(messages: [], scope: .all, options: settings ?? options, header: header, vm: vm, adaptiveWidth: 393)
        }
        let exporter = renderer()
        guard let data = exporter.makePDFData(), let pdf = PDFDocument(data: data) else {
            throw NSError(domain: "SessionShareRender", code: 2, userInfo: [NSLocalizedDescriptionKey: exporter.failureReason ?? "Production renderer returned no PDF"])
        }
        try data.write(to: documents.appendingPathComponent("share-render.pdf"))
        try check(pdf.pageCount >= 5, "Production page loop paginates 2700pt transcript")
        let extracted = pdf.string ?? ""
        // Preserve PDFKit's exact output before assertions: some PDF readers
        // differ on run ordering/whitespace, and missing vs duplicated glyphs
        // must be diagnosed from evidence rather than weakened expectations.
        let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        func canonical(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        func counts(_ value: String) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: sentinels.map { ($0, value.components(separatedBy: $0).count - 1) })
        }
        try extracted.write(to: documents.appendingPathComponent("share-render-extracted-raw.txt"), atomically: true, encoding: .utf8)
        let extraction: [String: Any] = [
            "documentText": extracted, "documentDebugDescription": String(reflecting: extracted),
            "pageTexts": pages, "counts": counts(extracted),
            "pageCounts": pages.map { counts($0) },
            "canonicalCounts": counts(canonical(extracted)),
            "canonicalPageCounts": pages.map { counts(canonical($0)) }
        ]
        try JSONSerialization.data(withJSONObject: extraction, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("share-render-extracted-text.json"))
        for token in sentinels {
            try check(extracted.components(separatedBy: token).count == 2, "Actual PDF body glyphs extract exactly once: \(token); raw=\(counts(extracted)[token] ?? -1), whitespaceCanonical=\(counts(canonical(extracted))[token] ?? -1)")
            try check(canonical(extracted).components(separatedBy: token).count == 2, "Whitespace-canonical PDF body still contains exactly one complete token: \(token)")
        }
        try check(!extracted.contains(title) && !String(describing: pdf.documentAttributes ?? [:]).contains(title), "Hidden title absent from actual PDF content and metadata")
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { throw NSError(domain: "SessionShareRender", code: 3) }
            let box = page.bounds(for: .mediaBox)
            try check(abs(box.width - 393) < 0.6 && abs(box.height - 556) < 0.6, "Actual PDF media box is phone-sized page \(index + 1)")
        }
        let images = exporter.makeImages()
        try check(images.count == 1, "Bounded transcript produces one long image, not a slice collection")
        var height: CGFloat = 0
        for (index, image) in images.enumerated() {
            guard let cg = image.cgImage else { throw NSError(domain: "SessionShareRender", code: 4) }
            let maxPixels = Int(SessionShareRenderPolicy.sliceHeight * SessionShareRenderPolicy.imageScale)
            try check(cg.width == 786 && cg.height > 0 && cg.height <= maxPixels, "Actual image \(index) respects production physical-pixel limit")
            if let png = image.pngData() { try png.write(to: documents.appendingPathComponent("share-render-\(index).png")) }
            height += image.size.height
        }
        let manifest: [String: Any] = [
            "pdf": "share-render.pdf", "minimumPages": 5, "pageWidth": 393, "pageHeight": 556,
            "requiredText": sentinels, "forbiddenText": ["UNSELECTED_BODY_SENTINEL"],
            "hiddenTitle": title, "images": images.indices.map { "share-render-\($0).png" },
            "imagePixelWidth": 786, "maximumImagePixelHeight": Int(SessionShareRenderPolicy.sliceHeight * SessionShareRenderPolicy.imageScale)
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("share-render-manifest.json"))
        try check(abs(height - 2700) < 2, "Image slices cover the complete measured transcript")
        var dark = options
        dark.theme = .dark
        dark.width = .pad
        let darkExporter = renderer(dark)
        guard let darkPDF = darkExporter.makePDFData(), let document = PDFDocument(data: darkPDF) else { throw NSError(domain: "SessionShareRender", code: 5) }
        try check(sentinels.allSatisfy { (document.string ?? "").contains($0) }, "Dark iPad rendering retains real body text")
        vm.fixtureRows = []
        let empty = renderer()
        try check(empty.makePDFData() == nil && empty.makeImages().isEmpty, "Empty export fails without blank artifacts")
        vm.fixtureRows = [AnyView(FixtureText(text: "TOO_TALL", textKit: true).frame(height: 25000))]
        let tall = renderer()
        try check(tall.makePDFData() == nil && tall.failureReason != nil, "Over-height row fails rather than truncates")
        vm.fixtureRows = (0..<35).map { _ in AnyView(FixtureText(text: "BUDGET", textKit: false).frame(height: 900)) }
        let large = renderer()
        try check(large.makeImages().isEmpty && large.failureReason != nil, "Production bitmap budget rejects oversized transcript before output allocation")
        try JSONSerialization.data(withJSONObject: ["passed": checks, "failed": failures], options: [.prettyPrinted, .sortedKeys])
            .write(to: documents.appendingPathComponent("share-render-checks.json"))
        if !failures.isEmpty {
            throw NSError(domain: "SessionShareRender", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")])
        }
        return checks
    }
}
