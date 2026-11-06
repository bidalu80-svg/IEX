#if DEBUG
import SwiftUI
import UIKit
import PDFKit

/// Launched only by --verify-conversation-share in the full simulator app.
/// It uses the production models, Markdown attachments, picker and exporter.
@MainActor enum ConversationShareVerification {
    private static var checks: [String] = []
    private static var files: [String] = []
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("share-verification", isDirectory: true)

    private static func require(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: "ConversationShareVerification", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: label]) }
        checks.append(label)
        checkpoint(label)
    }

    private static func checkpoint(_ label: String) {
        print("ConversationShareVerification: \(label)")
        try? label.write(to: directory.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
    }

    static func run() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            checkpoint("Waiting for application window")
            var window: UIWindow?
            for _ in 0..<100 {
                window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first(where: \.isKeyWindow)
                if window != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let window else { throw ChatExportError.noWindow }
            let previous = window.rootViewController
            let oldStyle = window.overrideUserInterfaceStyle
            defer { window.rootViewController = previous; window.overrideUserInterfaceStyle = oldStyle }
            window.overrideUserInterfaceStyle = .light
            let vm = AIChatViewModel()
            checkpoint("Creating production fixture")
            let messages = try fixture()
            let request = ChatShareSnapshot.request(messages: messages, title: "分享验证 Share Verification", vm: vm)
            try require(request.initialSelection.isEmpty, "Conversation menu starts with no selection")
            let first = messages[1].blocks[0]
            let frozen = request.messages[1].blocks[0]
            first.content = "MUTATED LIVE CONTENT"
            try require(frozen.content.contains("SHARE_BEGIN"), "Streaming snapshot freezes text and preserves block identity")
            try require(first.id == frozen.id && first !== frozen, "Snapshot models retain identities without sharing references")
            let all = Set(request.cells.map(\.id))
            let groups = ChatShareCells.renderGroups(request.cells, selected: all)
            try require(groups.count >= 3, "Selected block groups preserve user and reply ordering")
            let tool = request.cells.first { $0.kind == .tool }!
            let selected = all.subtracting([tool.id])
            try require(!ChatShareCells.renderGroups(request.cells, selected: selected).joined().contains(tool),
                        "Individual tool can be excluded while surrounding text remains selected")
            if let folded = request.foldedCells {
                let mapped = ChatShareCells.remapSelection(all, from: request.cells, to: folded)
                try require(ChatShareCells.remapSelection(mapped, from: folded, to: request.cells) == all,
                            "Production fold adapter preserves full selection through round trip")
            }

            for dark in [false, true] {
                let scheme: ColorScheme = dark ? .dark : .light
                let name = dark ? "dark" : "light"
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                let picker = UIHostingController(rootView: ChatShareSelectionView(request: request)
                    .environment(\.colorScheme, scheme))
                window.rootViewController = picker
                try await Task.sleep(nanoseconds: 500_000_000)
                try capture(window, name: "picker-\(name).png")
                let selectedRequest = ChatShareRequest(cells: request.cells, foldedCells: request.foldedCells,
                    startsFolded: false, messages: request.messages, initialSelection: all,
                    title: request.title, vm: vm)
                window.rootViewController = UIHostingController(rootView: ChatShareSelectionView(request: selectedRequest)
                    .environment(\.colorScheme, scheme))
                try await Task.sleep(nanoseconds: 500_000_000)
                try capture(window, name: "picker-selected-\(name).png")

                var imageOptions = ChatExportOptions()
                imageOptions.dark = dark
                imageOptions.adaptiveTables = true
                checkpoint("Rendering \(name) PNG")
                let image = try await ChatExportRenderer(vm: vm).render(groups: groups, messages: request.messages,
                    title: "分享验证 Share Verification", options: imageOptions, progress: { _, _ in })
                let imageURL = try save(image.url, name: "export-\(name).png")
                guard let decoded = UIImage(contentsOfFile: imageURL.path) else { throw ChatExportError.writeFailed }
                try require(decoded.size.width > 1000 && decoded.size.height > 1000, "\(name) PNG has complete measured dimensions")
                try require(hasFixtureImage(decoded), "\(name) PNG contains the asynchronously loaded red image")

                var pdfOptions = imageOptions
                pdfOptions.format = .pdf
                checkpoint("Rendering \(name) PDF")
                let pdf = try await ChatExportRenderer(vm: vm).render(groups: groups, messages: request.messages,
                    title: "分享验证 Share Verification", options: pdfOptions, progress: { _, _ in })
                let pdfURL = try save(pdf.url, name: "export-\(name).pdf")
                guard let document = PDFDocument(url: pdfURL) else { throw ChatExportError.writeFailed }
                let text = document.string ?? ""
                let markers = ["SHARE_BEGIN", "SHARE_END", "CODE_MARKER", "TABLE_LAST"]
                let matches = Dictionary(uniqueKeysWithValues: markers.map {
                    ($0, document.findString($0, withOptions: []))
                })
                // Persist extraction and actual PDFKit search separately: PDFKit may
                // insert layout whitespace in `string` that differs from findString.
                try saveText(text, name: "pdf-document-text-\(name).txt")
                let pageText = (0..<document.pageCount).map { index in
                    "--- Page \(index + 1) ---\n" + (document.page(at: index)?.string ?? "<nil>")
                }.joined(separator: "\n\n")
                try saveText(pageText, name: "pdf-page-text-\(name).txt")
                let searchReport: [String: Any] = Dictionary(uniqueKeysWithValues: markers.map { marker in
                    (marker, ["count": matches[marker]!.count,
                              "documentStringContains": text.contains(marker),
                              "selections": matches[marker]!.map { $0.string ?? "<nil>" }] as [String: Any])
                })
                let searchName = "pdf-search-\(name).json"
                try JSONSerialization.data(withJSONObject: searchReport, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(searchName), options: .atomic)
                files.append(searchName)
                try require(document.pageCount > 1, "\(name) PDF paginates the complete long reply")
                for marker in markers {
                    try require(!matches[marker]!.isEmpty, "\(name) PDF has searchable \(marker) without truncation")
                }
                try require(!text.contains("MUTATED LIVE CONTENT"), "\(name) export never reads later streaming changes")
                try capturePDF(document, name: "pdf-first-\(name).png", page: 0)
                try capturePDF(document, name: "pdf-last-\(name).png", page: document.pageCount - 1)

                UserDefaults.standard.set("image", forKey: "chatShare.format")
                var finished: URL?
                let preview = UIHostingController(rootView: ChatSharePreviewSheet(groups: groups,
                    count: all.count, messages: request.messages, title: "分享验证 Share Verification", vm: vm,
                    initialOptions: imageOptions, onRendered: { finished = $0 })
                    .environment(\.colorScheme, scheme))
                // Reproduce the modal ownership of the real flow: an application
                // root presents the selection sheet, which presents the preview.
                // The preview must present its activity controller from this nested
                // context, not from a convenient replacement root controller.
                let shareRoot = UIHostingController(rootView: Text("Share presentation verification"))
                let modalPicker = UIHostingController(rootView: ChatShareSelectionView(request: selectedRequest)
                    .environment(\.colorScheme, scheme))
                modalPicker.modalPresentationStyle = .pageSheet
                preview.modalPresentationStyle = .pageSheet
                window.rootViewController = shareRoot
                window.layoutIfNeeded()
                try await waitUntil("\(name) application root is visible") { shareRoot.viewIfLoaded?.window === window }
                shareRoot.present(modalPicker, animated: false)
                try await waitUntil("\(name) selection sheet is visible") {
                    modalPicker.presentingViewController != nil && modalPicker.viewIfLoaded?.window === window
                        && !modalPicker.isBeingPresented
                }
                modalPicker.present(preview, animated: false)
                try await waitUntil("\(name) preview is presented above the selection sheet") {
                    preview.presentingViewController != nil && preview.viewIfLoaded?.window === window
                        && !preview.isBeingPresented
                }
                try require(shareRoot.presentedViewController != nil && modalPicker.presentedViewController != nil,
                            "\(name) production preview has two real modal presentation levels")
                for _ in 0..<400 {
                    if finished != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(finished != nil, "\(name) complete preview renders without a manual export action")
                let cachedImageURL = finished
                try await Task.sleep(nanoseconds: 250_000_000)
                try capture(window, name: "preview-\(name).png")
                guard let renderedImage = finished else { throw ChatExportError.writeFailed }
                try await verifyActivityPresentation(window: window, root: shareRoot, preview: preview,
                    url: renderedImage, format: "png", name: "\(name)-png")
                finished = nil
                UserDefaults.standard.set("pdf", forKey: "chatShare.format")
                for _ in 0..<400 {
                    if finished?.pathExtension == "pdf" { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(finished?.pathExtension == "pdf", "\(name) format change produces current PDF preview")
                try await Task.sleep(nanoseconds: 250_000_000)
                try capture(window, name: "preview-pdf-\(name).png")
                guard let renderedPDF = finished else { throw ChatExportError.writeFailed }
                try await verifyActivityPresentation(window: window, root: shareRoot, preview: preview,
                    url: renderedPDF, format: "pdf", name: "\(name)-pdf")
                finished = nil
                UserDefaults.standard.set("image", forKey: "chatShare.format")
                for _ in 0..<30 {
                    if finished != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(finished == cachedImageURL, "\(name) switching back reuses the exact finished render")
                shareRoot.dismiss(animated: false)
                try await waitUntil("\(name) nested share flow closes cleanly") { shareRoot.presentedViewController == nil }
            }

            let cancelled = Task { @MainActor in
                try await ChatExportRenderer(vm: vm).render(groups: groups, messages: request.messages,
                    title: "Cancelled", options: ChatExportOptions(), progress: { _, _ in })
            }
            cancelled.cancel()
            do {
                _ = try await cancelled.value
                throw NSError(domain: "ConversationShareVerification", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Cancelled export produced a success result"])
            } catch is CancellationError { checks.append("Cancellation stops production export") }

            var hiddenOptions = ChatExportOptions()
            hiddenOptions.format = .pdf
            hiddenOptions.hideHeader = true
            let hidden = try await ChatExportRenderer(vm: vm).render(groups: Array(groups.prefix(1)),
                messages: request.messages, title: "PRIVATE_TITLE_SENTINEL", options: hiddenOptions, progress: { _, _ in })
            let hiddenURL = try save(hidden.url, name: "hidden-title.pdf")
            let hiddenDocument = PDFDocument(url: hiddenURL)
            try require(!(hiddenDocument?.string ?? "").contains("PRIVATE_TITLE_SENTINEL")
                && !hidden.url.lastPathComponent.contains("PRIVATE_TITLE_SENTINEL"), "Hidden title is absent from PDF and filename")
            try result(success: true)
        } catch {
            try? result(success: false, error: error.localizedDescription)
        }
    }

    /// The host-side XCTest runner drives real taps and interactive dismissals.
    /// The in-app oracle independently verifies the actual presented controllers.
    private static func verifyActivityPresentation(window: UIWindow, root: UIViewController,
                                                   preview: UIViewController, url: URL,
                                                   format: String, name: String) async throws {
        try require(url.isFileURL && url.pathExtension.lowercased() == format,
                    "\(name) current preview supplies a \(format.uppercased()) file URL")
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        try require(!bytes.isEmpty, "\(name) current preview file is readable and nonempty")
        if format == "pdf" {
            try require((PDFDocument(data: bytes)?.pageCount ?? 0) > 0, "\(name) current share file is a valid PDF")
        } else {
            try require(UIImage(data: bytes) != nil, "\(name) current share file is a valid PNG")
        }
        try saveText(url.lastPathComponent, name: "activity-file-\(name).txt")

        for attempt in 1...2 {
            try require(activityController(in: root) == nil, "\(name) attempt \(attempt) starts without an activity sheet")
            try await requestUIAction("open", details: ["identifier": "chatShare.export"])
            try await waitUntil("\(name) attempt \(attempt) production button presents a visible UIActivityViewController") {
                guard let activity = activityController(in: root), let view = activity.viewIfLoaded else { return false }
                return view.window === window && !view.isHidden && view.alpha > 0
                    && view.bounds.width > 0 && view.bounds.height > 0 && !activity.isBeingPresented
            }
            guard activityController(in: root) != nil else {
                throw verificationError("\(name) activity controller disappeared before inspection")
            }
            try require(preview.presentedViewController != nil,
                        "\(name) attempt \(attempt) activity presentation is owned by the existing preview")
            try await Task.sleep(nanoseconds: 350_000_000)
            try capture(window, name: "activity-\(name)-\(attempt).png")
            // The SwiftUI wrapper can cover the entire window even when the
            // remote activity UI is a bottom sheet. Let XCTest locate the actual
            // system Close button/sheet; wrapper geometry is not a touch target.
            try await requestUIAction("dismiss", details: [:])
            try await waitUntil("\(name) attempt \(attempt) dismissal returns to the same preview") {
                activityController(in: root) == nil && preview.presentedViewController == nil
                    && preview.presentingViewController != nil && preview.viewIfLoaded?.window === window
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try capture(window, name: "activity-dismissed-\(name).png")
    }

    /// JSON is exchanged through a loopback bridge by the simulator test runner.
    /// An acknowledgement only means the real tap/gesture was sent; controller
    /// visibility above remains the success oracle. Stale acknowledgements cannot
    /// complete a different action.
    private static func requestUIAction(_ action: String, details: [String: Any]) async throws {
        let sequence = UUID().uuidString
        var request = details
        request["sequence"] = sequence
        request["action"] = action
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("ui-request.json"), options: .atomic)
        checkpoint("Waiting for XCTest \(action) \(sequence)")
        for _ in 0..<450 {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: directory.appendingPathComponent("ui-ack.json")),
               let ack = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               ack["sequence"] as? String == sequence {
                guard ack["success"] as? Bool == true else {
                    throw verificationError("XCTest \(action) failed: \(ack["error"] as? String ?? "unknown error")")
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw verificationError("XCTest did not acknowledge \(action) within 45 seconds")
    }

    private static func activityController(in root: UIViewController) -> UIActivityViewController? {
        var visited = Set<ObjectIdentifier>()
        func find(_ controller: UIViewController, depth: Int) -> UIActivityViewController? {
            guard depth < 32, visited.insert(ObjectIdentifier(controller)).inserted else { return nil }
            if let activity = controller as? UIActivityViewController { return activity }
            if let presented = controller.presentedViewController,
               let activity = find(presented, depth: depth + 1) { return activity }
            for child in controller.children {
                if let activity = find(child, depth: depth + 1) { return activity }
            }
            return nil
        }
        return find(root, depth: 0)
    }

    private static func waitUntil(_ label: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if condition() { try require(true, label); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw verificationError(label + " (timed out; no success assumed)")
    }

    private static func verificationError(_ label: String) -> NSError {
        NSError(domain: "ConversationShareVerification", code: 3,
                userInfo: [NSLocalizedDescriptionKey: label])
    }

    private static func fixture() throws -> [ChatMessage] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100), format: format).image { context in
            UIColor(red: 0.95, green: 0.03, blue: 0.04, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        }
        let url = directory.appendingPathComponent("fixture-red.png")
        try image.pngData()!.write(to: url)
        let table = "| Name | Description | Last |\n| --- | --- | --- |\n| 中文表格 | A wide table with content that should remain visible | TABLE_LAST |\n"
        let intro = "# SHARE_BEGIN\n\n真实 **Markdown** 与 [link](https://example.com)。\n\n"
            + table + "\n```swift\nlet CODE_MARKER = 42\n```\n\n![红色图片](\(url.absoluteString))\n"
        let content = AssistantBlock(kind: .text, content: intro)
        let thought = AssistantBlock(kind: .thinking, content: "检查图片、表格与分页。")
        thought.thinkingDuration = 3
        thought.thinkingStartTime = nil
        let read = AssistantBlock(kind: .fileReadTool(path: "/tmp/config.json"), content: "Read config", toolStatus: .success)
        read.toolSummary = "读取配置"
        read.toolDuration = 0.3
        let shell = AssistantBlock(kind: .shellTool(command: "swift test"), content: "Tests passed", toolStatus: .success)
        shell.toolSummary = "检查导出结果"
        shell.toolDuration = 1.2
        let tail = AssistantBlock(kind: .text, content: (1...70).map { "Paragraph \($0): 完整导出，逐行保留，不截断内容。" }.joined(separator: "\n\n") + "\n\nSHARE_END")
        return [ChatMessage(role: .user, content: "请分享含表格、代码、图片与工具的对话。"),
                ChatMessage(role: .assistant, content: "", blocks: [content, thought, read, shell, tail]),
                ChatMessage(role: .user, content: "最后一条用户消息。")]
    }

    private static func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var success = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            success = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try require(success, "Visible full-app screenshot \(name)")
        try image.pngData()!.write(to: directory.appendingPathComponent(name))
        files.append(name)
    }

    private static func capturePDF(_ document: PDFDocument, name: String, page index: Int) throws {
        guard let page = document.page(at: index) else { throw ChatExportError.writeFailed }
        let image = page.thumbnail(of: CGSize(width: 900, height: 1300), for: .mediaBox)
        try image.pngData()!.write(to: directory.appendingPathComponent(name))
        files.append(name)
    }

    private static func saveText(_ text: String, name: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        files.append(name)
    }

    private static func save(_ source: URL, name: String) throws -> URL {
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: source, to: target)
        files.append(name)
        return target
    }

    private static func hasFixtureImage(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
        let width = 128, height = 512
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            let values = buffer.bindMemory(to: UInt8.self)
            var red = 0
            for i in stride(from: 0, to: values.count, by: 4) {
                if values[i] > 180 && values[i + 1] < 70 && values[i + 2] < 70 { red += 1 }
            }
            return red > 15
        }
    }

    private static func result(success: Bool, error: String? = nil) throws {
        let output: [String: Any] = ["success": success, "error": error ?? "", "checks": checks, "files": files,
            "scope": "Full production simulator app: native Markdown/table/code/image/tools, actual PNG/PDF files, extraction, snapshot isolation, cancellation and cache reuse. Real nested modal picker/preview; production share button tapped through external XCTest UI automation; visible UIActivityViewController, real system close action and repeat presentation for current PNG/PDF in light/dark appearance. Screenshots recorded. No physical-device touch, third-party recipient delivery, credentialed tool actions or device FPS assertion."]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
}
#endif
