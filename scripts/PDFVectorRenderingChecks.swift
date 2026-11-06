// Joined to the actual production drawing methods by test-pdf-vector-rendering.py.
@main @MainActor final class PDFVectorHarnessDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pdf-vector-harness", isDirectory: true)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        DispatchQueue.main.async { self.verify() }
        return true
    }

    private func fixture(variant: String = "original") -> UIView {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 680, height: 1200))
        root.backgroundColor = .white
        root.overrideUserInterfaceStyle = .light
        func text(_ value: String, y: CGFloat, font: UIFont) {
            let view = UITextView(usingTextLayoutManager: false)
            view.isScrollEnabled = false
            view.isEditable = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.attributedText = diagnosticText(value, font: font, variant: variant)
            view.frame = CGRect(x: 20, y: y, width: 640, height: 150)
            view.layoutManager.ensureLayout(for: view.textContainer)
            root.addSubview(view)
        }
        text("SHARE_BEGIN\n真实 Markdown 与 link。", y: 20, font: .systemFont(ofSize: 24.75))
        let label = UILabel(frame: CGRect(x: 20, y: 200, width: 500, height: 30))
        label.font = .systemFont(ofSize: 16.5)
        label.textColor = .black
        label.attributedText = diagnosticText("TABLE_LAST", font: label.font, variant: variant)
        root.addSubview(label)
        text("let CODE_MARKER = 42", y: 250, font: .monospacedSystemFont(ofSize: 16.5, weight: .regular))
        text("SHARE_END", y: 720, font: .systemFont(ofSize: 16.5))
        root.layoutIfNeeded()
        return root
    }

    /// Diagnostic-only variants; production fonts and content stay untouched.
    private func diagnosticText(_ value: String, font: UIFont, variant: String) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: value, attributes: [.font: font, .foregroundColor: UIColor.black])
        let range = NSRange(location: 0, length: attributed.length)
        var underscores: [NSRange] = []
        let raw = value as NSString
        for index in 0..<raw.length where raw.character(at: index) == 95 {
            underscores.append(NSRange(location: index, length: 1))
        }
        if variant.hasPrefix("offset:") {
            let amount = Double(variant.dropFirst("offset:".count))!
            for underscore in underscores {
                attributed.addAttribute(.baselineOffset, value: amount, range: underscore)
            }
        }
        if variant.hasPrefix("underscore:") || variant.hasPrefix("font:") {
            let name = String(variant.split(separator: ":")[1])
            let replacement = name == "mono"
                ? UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                : UIFont(name: name, size: font.pointSize)!
            if variant.hasPrefix("font:") {
                attributed.addAttribute(.font, value: replacement, range: range)
            } else {
                for underscore in underscores {
                    attributed.addAttribute(.font, value: replacement, range: underscore)
                }
            }
        }
        return attributed
    }

    private func render(_ root: UIView, fixed: Bool, outputName: String? = nil) throws -> PDFDocument {
        let name = outputName ?? (fixed ? "fixed" : "baseline")
        let url = directory.appendingPathComponent(name + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 680, height: 600)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw error("PDF context") }
        let renderer = ProductionRenderer()
        for page in 0..<2 {
            let slice = CGRect(x: 0, y: CGFloat(page) * 600, width: 680, height: 600)
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: 600)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -slice.minY)
            ctx.clip(to: slice)
            renderer.drawVector(root, in: ctx, visibleBounds: fixed ? slice : root.bounds, searchablePDF: fixed)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard let pdf = PDFDocument(url: url) else { throw error("Read generated PDF") }
        try (pdf.string ?? "<nil>").write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        for page in 0..<pdf.pageCount {
            let image = pdf.page(at: page)!.thumbnail(of: CGSize(width: 680, height: 600), for: .mediaBox)
            try image.pngData()!.write(to: directory.appendingPathComponent("\(name)-page-\(page).png"))
        }
        return pdf
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "PDFVectorHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func verify() {
        var report: [String: Any] = [:]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let root = fixture()
            let baseline = try render(root, fixed: false)
            let fixed = try render(root, fixed: true)
            let markers = ["SHARE_BEGIN", "TABLE_LAST", "CODE_MARKER", "SHARE_END"]
            report["baselineSearch"] = Dictionary(uniqueKeysWithValues: markers.map {
                ($0, baseline.findString($0, withOptions: []).count)
            })
            let hits = Dictionary(uniqueKeysWithValues: markers.map {
                ($0, fixed.findString($0, withOptions: []).count)
            })
            report["fixedSearch"] = hits
            // Run every candidate before enforcing the unchanged acceptance check,
            // so one simulator launch diagnoses both punctuation and pagination.
            var matrix: [[String: Any]] = []
            let variants = ["original", "offset:1", "offset:2", "offset:-1", "offset:-2",
                            "underscore:Helvetica", "underscore:ArialMT", "underscore:mono",
                            "font:Helvetica", "font:ArialMT", "font:mono"]
            for variant in variants {
                for coreText in [false, true] {
                    let name = "matrix-" + variant.replacingOccurrences(of: ":", with: "-") + (coreText ? "-coretext" : "-textkit")
                    let pdf = try render(fixture(variant: variant), fixed: coreText, outputName: name)
                    let counts = Dictionary(uniqueKeysWithValues: markers.map {
                        ($0, pdf.findString($0, withOptions: []).count)
                    })
                    let pageText = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "<nil>" }
                    // The words themselves remain searchable even when PDFKit
                    // places the underscore in a separate text line.
                    let pageIsolation = pageText[0].contains("BEGIN") && !pageText[0].contains("END")
                        && pageText[1].contains("END") && !pageText[1].contains("BEGIN")
                        && !pageText[1].contains("TABLE") && !pageText[1].contains("CODE")
                    matrix.append(["variant": variant, "renderer": coreText ? "CoreText" : "TextKit",
                                   "search": counts, "allMarkersSearchable": markers.allSatisfy { counts[$0] == 1 },
                                   "pageIsolation": pageIsolation, "pageText": pageText])
                }
            }
            report["diagnosticMatrix"] = matrix
            try JSONSerialization.data(withJSONObject: matrix, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("diagnostic-matrix.json"), options: .atomic)
            report["pageText"] = (0..<fixed.pageCount).map { fixed.page(at: $0)?.string ?? "<nil>" }
            guard markers.allSatisfy({ hits[$0] == 1 }) else {
                throw error("PDFKit must find each complete underscore marker exactly once")
            }
            let first = fixed.page(at: 0)!.string ?? ""
            let last = fixed.page(at: 1)!.string ?? ""
            report["pageText"] = [first, last]
            guard first.contains("SHARE_BEGIN"), !first.contains("SHARE_END"),
                  last.contains("SHARE_END"), !last.contains("SHARE_BEGIN"),
                  !last.contains("TABLE_LAST"), !last.contains("CODE_MARKER") else {
                throw error("PDFKit page text must exclude glyphs outside that page slice")
            }
            report["success"] = true
        } catch {
            report["success"] = false
            report["error"] = error.localizedDescription
        }
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
}
