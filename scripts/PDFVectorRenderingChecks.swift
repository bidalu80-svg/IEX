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

    private func fixture() -> UIView {
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
            view.attributedText = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: UIColor.black])
            view.frame = CGRect(x: 20, y: y, width: 640, height: 150)
            view.layoutManager.ensureLayout(for: view.textContainer)
            root.addSubview(view)
        }
        text("SHARE_BEGIN\n真实 Markdown 与 link。", y: 20, font: .systemFont(ofSize: 24.75))
        let label = UILabel(frame: CGRect(x: 20, y: 200, width: 500, height: 30))
        label.font = .systemFont(ofSize: 16.5)
        label.textColor = .black
        label.text = "TABLE_LAST"
        root.addSubview(label)
        text("let CODE_MARKER = 42", y: 250, font: .monospacedSystemFont(ofSize: 16.5, weight: .regular))
        text("SHARE_END", y: 720, font: .systemFont(ofSize: 16.5))
        root.layoutIfNeeded()
        return root
    }

    private func render(_ root: UIView, fixed: Bool) throws -> PDFDocument {
        let name = fixed ? "fixed" : "baseline"
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
