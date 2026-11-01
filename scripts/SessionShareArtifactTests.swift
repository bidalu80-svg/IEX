// Validates ACTUAL exported files; never synthesizes a replacement PDF/image.
// macOS: xcrun swiftc scripts/SessionShareArtifactTests.swift -o /tmp/share-artifacts
//        /tmp/share-artifacts /path/to/manifest.json
// Manifest (paths relative to manifest):
// {"pdf":"export.pdf","minimumPages":2,"pageWidth":393,"pageHeight":556,
//  "requiredText":["BODY_FIRST_SENTINEL","BODY_LAST_SENTINEL"],
//  "forbiddenText":["UNSELECTED_TOOL_SENTINEL"],"hiddenTitle":"PRIVATE_TITLE_SENTINEL",
//  "images":["export-1.png"],"imagePixelWidth":786,"maximumImagePixelHeight":16000}
// Every required sentinel must appear exactly once in PDFKit's extracted text.
// Use distinct short ASCII body sentinels, not headers/footer (those alone can
// remain extractable in a PDF whose entire conversation is still rasterized).
import Foundation
import PDFKit
import ImageIO

private struct Manifest: Decodable {
    let pdf: String
    let minimumPages: Int
    let pageWidth: Double
    let pageHeight: Double
    let requiredText: [String]
    let forbiddenText: [String]
    let hiddenTitle: String?
    let images: [String]
    let imagePixelWidth: Int
    let maximumImagePixelHeight: Int
}

@main
struct SessionShareArtifactTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw failure("Usage: share-artifacts /path/to/manifest.json")
        }
        let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let directory = manifestURL.deletingLastPathComponent()
        func require(_ value: Bool, _ label: String) throws {
            guard value else { throw failure(label) }
            print("PASS: \(label)")
        }
        try require(!manifest.requiredText.isEmpty, "Manifest requires actual body text evidence")
        try require(manifest.minimumPages >= 1, "Manifest requires at least one PDF page")
        let pdfURL = directory.appendingPathComponent(manifest.pdf)
        guard let pdf = PDFDocument(url: pdfURL) else { throw failure("Exported PDF is unreadable") }
        try require(pdf.pageCount >= manifest.minimumPages, "PDF page count \(pdf.pageCount) >= \(manifest.minimumPages)")
        let text = pdf.string ?? ""
        for token in manifest.requiredText {
            try require(!token.isEmpty && text.components(separatedBy: token).count == 2,
                        "Selected body text is extractable exactly once: \(token)")
        }
        for token in manifest.forbiddenText {
            try require(!token.isEmpty && !text.contains(token), "Unselected body content excluded: \(token)")
        }
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { throw failure("Missing PDF page \(index)") }
            let bounds = page.bounds(for: .mediaBox)
            try require(abs(bounds.width - manifest.pageWidth) < 0.6 && abs(bounds.height - manifest.pageHeight) < 0.6,
                        "PDF page \(index + 1) has expected media box")
        }
        if let title = manifest.hiddenTitle, !title.isEmpty {
            try require(!text.contains(title), "Hidden session title absent from page content and footer")
            let metadata = String(describing: pdf.documentAttributes ?? [:])
            try require(!metadata.contains(title), "Hidden session title absent from PDF metadata")
            try require(!pdfURL.lastPathComponent.contains(title), "Hidden session title absent from filename")
        }
        try require(!manifest.images.isEmpty, "Manifest requires actual image exports")
        for path in manifest.images {
            let url = directory.appendingPathComponent(path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw failure("Unreadable exported image: \(path)")
            }
            try require(width.intValue == manifest.imagePixelWidth, "Image \(path) has expected actual pixel width")
            try require(height.intValue > 0 && height.intValue <= manifest.maximumImagePixelHeight,
                        "Image \(path) stays within pixel-height limit")
        }
        print("ALL PASS: exported artifact text, pagination, privacy and image dimensions")
    }

    private static func failure(_ label: String) -> NSError {
        NSError(domain: "SessionShareArtifactTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
    }
}
