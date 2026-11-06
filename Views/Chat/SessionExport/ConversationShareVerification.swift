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
    }

    static func run() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
                let image = try await ChatExportRenderer(vm: vm).render(groups: groups, messages: request.messages,
                    title: "分享验证 Share Verification", options: imageOptions, progress: { _, _ in })
                let imageURL = try save(image.url, name: "export-\(name).png")
                guard let decoded = UIImage(contentsOfFile: imageURL.path) else { throw ChatExportError.writeFailed }
                try require(decoded.size.width > 1000 && decoded.size.height > 1000, "\(name) PNG has complete measured dimensions")
                try require(hasFixtureImage(decoded), "\(name) PNG contains the asynchronously loaded red image")

                var pdfOptions = imageOptions
                pdfOptions.format = .pdf
                let pdf = try await ChatExportRenderer(vm: vm).render(groups: groups, messages: request.messages,
                    title: "分享验证 Share Verification", options: pdfOptions, progress: { _, _ in })
                let pdfURL = try save(pdf.url, name: "export-\(name).pdf")
                guard let document = PDFDocument(url: pdfURL) else { throw ChatExportError.writeFailed }
                let text = document.string ?? ""
                try require(document.pageCount > 1, "\(name) PDF paginates the complete long reply")
                for marker in ["SHARE_BEGIN", "SHARE_END", "CODE_MARKER", "TABLE_LAST"] {
                    try require(text.contains(marker), "\(name) PDF has searchable \(marker) without truncation")
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
                window.rootViewController = preview
                for _ in 0..<400 {
                    if finished != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(finished != nil, "\(name) complete preview renders without a manual export action")
                let cachedImageURL = finished
                try await Task.sleep(nanoseconds: 250_000_000)
                try capture(window, name: "preview-\(name).png")
                finished = nil
                UserDefaults.standard.set("pdf", forKey: "chatShare.format")
                for _ in 0..<400 {
                    if finished?.pathExtension == "pdf" { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(finished?.pathExtension == "pdf", "\(name) format change produces current PDF preview")
                try await Task.sleep(nanoseconds: 250_000_000)
                try capture(window, name: "preview-pdf-\(name).png")
                finished = nil
                UserDefaults.standard.set("image", forKey: "chatShare.format")
                for _ in 0..<30 {
                    if finished != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try require(finished == cachedImageURL, "\(name) switching back reuses the exact finished render")
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
            "scope": "Full production app: native Markdown, table, code, local asynchronous image and tools; actual PNG/PDF, text extraction, snapshot isolation, cancellation, picker/preview screenshots. No credentialed tool actions or device FPS assertion."]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
}
#endif
