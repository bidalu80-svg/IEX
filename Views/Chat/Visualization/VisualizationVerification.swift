#if DEBUG
import SwiftUI
import UIKit
import PDFKit
import WebKit

/// Runs inside the real app's existing sharing verification, on its real window.
/// Uses shipping parser, TextKit attachments, native controls and PDF exporter.
@MainActor enum ZeVisualizationVerification {
    static let fixture = #"""
    {"schemaVersion":1,"id":"visual-fixture","title":"VISUAL_BEGIN 可视化演示","subtitle":"演示数据 · 非实时价格","sources":[{"id":"fixture","label":"VISUAL_SOURCE 用户数据"}],"components":[
    {"id":"metrics","type":"metric_grid","title":"今日指标","unit":"元/升","items":[{"id":"92","label":"92号汽油","value":8.91,"precision":2},{"id":"95","label":"95号汽油","value":9.65,"precision":2},{"id":"98","label":"98号汽油","missingReason":"暂无数据"},{"id":"diesel","label":"0号柴油","value":8.60,"precision":2}]},
    {"id":"trend","type":"line","title":"趋势","unit":"元","xAxis":"category","series":[{"id":"a","label":"A","points":[{"x":0,"y":2,"label":"周一"},{"x":1,"y":5,"label":"周二"},{"x":2,"y":null,"label":"周三"},{"x":3,"y":3,"label":"周四"}]},{"id":"b","label":"B","points":[{"x":0,"y":3},{"x":1,"y":4},{"x":2,"y":6},{"x":3,"y":4}]}]},
    {"id":"bars","type":"bar","title":"分类比较","series":[{"id":"a","label":"A","points":[{"x":0,"y":-2,"label":"甲"},{"x":1,"y":4,"label":"乙"}]}]},
    {"id":"area","type":"area","title":"面积趋势","series":[{"id":"a","label":"A","points":[{"x":1,"y":2},{"x":2,"y":5},{"x":3,"y":null},{"x":4,"y":3}]}]},
    {"id":"pie","type":"pie","title":"占比","items":[{"id":"a","label":"餐饮","value":30},{"id":"b","label":"交通","value":70}]},
    {"id":"donut","type":"donut","title":"环形占比","items":[{"id":"a","label":"餐饮","value":30},{"id":"b","label":"交通","value":70}]},
    {"id":"table","type":"table","title":"数据明细","headers":["Name","Value"],"rows":[["A",10],["B",2],["C",null],["D",4],["E",5],["VISUAL_LAST",6]]},
    {"id":"info","type":"info","title":"信息","items":[{"id":"note","label":"更新时间","text":"用户提供的快照","detail":"VISUAL_DETAIL"}]}
    ]}
    """#

    static func run(window: UIWindow, directory: URL) async throws {
        var checks: [String] = []
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else {
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try? shot.pngData()?.write(to: directory.appendingPathComponent("visualization-failure.png"))
                let report: [String: Any] = ["success": false, "checks": checks, "error": message]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("visualization-result.json"))
                throw NSError(domain: "VisualizationVerification", code: checks.count, userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks.append(message)
        }
        func descendants(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(descendants) }
        let document = try ZeVisualizationParser.parse(fixture).get()
        // The device incident returned a valid envelope as prose, without a
        // visualization fence. Exercise that actual boundary, not just ideal JSON.
        let markdown = "可以，直接在正文里给你：\n\n" + fixture + "\n\n数据说明。"
        let genericMarkdown = "```json\n" + fixture + "\n```"
        let explicitMarkdown = "```ze-visualization\n" + fixture + "\n```"
        for input in [markdown, genericMarkdown, explicitMarkdown] {
            let parsed = MarkdownContent(input)
            try check(parsed.blocks.contains { block in
                if case .codeBlock(let info, _) = block { return ZeVisualizationParser.isFence(info) }
                return false
            }, "Production Markdown parser recognizes bare, generic and explicit envelopes")
        }
        for opening in ["```ze-visualization", "```json", "~~~ze-visualization"] {
            let stream = opening + "\n" + fixture + "\n" + String(opening.prefix(3))
            let characters = Array(stream)
            let boundaries = Set(Array(0...min(40, characters.count)) + Array(stride(from: 40, to: characters.count, by: 97)) + Array(max(0, characters.count - 5)...characters.count))
            for offset in boundaries.sorted() {
                let parsed = MarkdownContent(String(characters.prefix(offset)))
                let rendered = renderMarkdownBlocks(parsed.blocks)
                var hasCodeCard = false
                rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
                    if value is CodeBlockAttachment { hasCodeCard = true }
                }
                try check(!hasCodeCard && !rendered.string.contains(ZeVisualizationError.incomplete.text), "Streaming prefix has no code card or incomplete-data error")
            }
        }
        let previous = window.rootViewController
        let previousStyle = window.overrideUserInterfaceStyle
        defer { window.rootViewController = previous; window.overrideUserInterfaceStyle = previousStyle }
        let started = CFAbsoluteTimeGetCurrent()
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            let liveBlock = AssistantBlock(kind: .text, content: dark ? genericMarkdown : markdown)
            let liveMessage = ChatMessage(role: .assistant, content: "", blocks: [liveBlock])
            func content(_ message: ChatMessage, snapshot: Bool) -> some View {
                ScrollView {
                    AssistantBlockView(block: message.blocks[0], message: message, isActiveMessage: false,
                                       highlightedBlockId: .constant(nil), detailBlock: .constant(nil)).padding(16)
                }.background(Color(uiColor: .systemBackground)).environment(\.chatSnapshotRendering, snapshot)
            }
            let host = UIHostingController(rootView: content(liveMessage, snapshot: false))
            host.view.tintAdjustmentMode = .normal
            window.rootViewController = host
            try await Task.sleep(nanoseconds: 350_000_000)
            host.view.layoutIfNeeded()
            let cards = descendants(host.view).compactMap { $0 as? ZeVisualizationCardView }
            try check(cards.count == 8, "All eight component types rendered in actual TextKit")
            try check(cards.allSatisfy { $0.bounds.width > 100 && $0.bounds.height > 50 }, "Nonzero attachment geometry")
            let ordered = cards.sorted { $0.convert($0.bounds, to: host.view).minY < $1.convert($1.bounds, to: host.view).minY }
            for pair in zip(ordered, ordered.dropFirst()) {
                let gap = pair.1.convert(pair.1.bounds, to: host.view).minY - pair.0.convert(pair.0.bounds, to: host.view).maxY
                try check(gap >= 15, "Adjacent cards have at least 16pt separation (rounding tolerance)")
            }
            let textViews = descendants(host.view).compactMap { $0 as? SelectableMarkdownTextView }
            if let tv = textViews.first, let first = ordered.first {
                let subtitle = (tv.textStorage.string as NSString).range(of: "演示数据 · 非实时价格")
                let glyphs = tv.layoutManager.glyphRange(forCharacterRange: subtitle, actualCharacterRange: nil)
                var rect = tv.layoutManager.boundingRect(forGlyphRange: glyphs, in: tv.textContainer)
                rect.origin.y += tv.textContainerInset.top
                let gap = first.convert(first.bounds, to: tv).minY - rect.maxY
                try check(gap >= 7, "Subtitle is separated from first card (gap=\(gap), subtitle=\(rect), card=\(first.convert(first.bounds, to: tv)))")
            }
            try check(textViews.contains { ChatSearchComposite.build($0.textStorage).text.contains("VISUAL_LAST") }, "Search projection includes data outside inline preview")
            try check(!textViews.contains { ChatSearchComposite.build($0.textStorage).text.contains("schemaVersion") }, "Search does not expose protocol JSON")
            if let trend = cards.first(where: { $0.component.id == "trend" }) {
                let controls = descendants(trend).compactMap { $0 as? UISegmentedControl }
                try check(controls.count == 2, "Series and range controls are present")
                for control in controls {
                    control.selectedSegmentIndex = control.numberOfSegments - 1
                    control.sendActions(for: .valueChanged)
                }
                if let canvas = descendants(trend).compactMap({ $0 as? ZeVisualizationPlotCanvas }).first {
                    _ = UIGraphicsImageRenderer(bounds: canvas.bounds).image { context in canvas.layer.render(in: context.cgContext) }
                    canvas.select(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
                    try check(canvas.accessibilityValue?.isEmpty == false, "Chart selection produces a real value")
                } else { try check(false, "Chart missing") }
                try check(liveBlock.visualizationSelections.values.contains { $0.seriesIndex == 1 && $0.lastHalf && $0.selectedText != nil && $0.selectedPointIndex != nil }, "Real chart interaction writes bounded message selection")
            }
            let metricLabels = descendants(cards[0]).compactMap { $0 as? UILabel }.filter { $0.accessibilityIdentifier?.hasPrefix("ze.visualization.value.") == true }
            try check(metricLabels.count == 4 && metricLabels.allSatisfy { $0.bounds.width > 20 && $0.bounds.height > 15 }, "Metric value labels have actual visible frames")
            for label in metricLabels {
                let rect = label.convert(label.bounds, to: cards[0])
                try check(cards[0].bounds.contains(rect), "Metric label lies inside card")
            }
            // Capture the body before opening any detail sheet.
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: directory.appendingPathComponent("visualization-\(dark ? "dark" : "light").png"))
            for card in cards {
                let shot = UIGraphicsImageRenderer(bounds: card.bounds).image { _ in card.drawHierarchy(in: card.bounds, afterScreenUpdates: true) }
                try shot.pngData()?.write(to: directory.appendingPathComponent("visualization-\(card.component.id)-\(dark ? "dark" : "light").png"))
            }
            ZeVisualizationCache.shared.clear()
            SelectableMarkdownView.clearVisualizationCaches()
            try check(ZeVisualizationCache.shared.statistics.count == 0, "Explicit cache clear")
            try check(cards.count == 8 && cards[0].component.items?.first?.value == 8.91, "Visible snapshot survives cache clear")
            // Compare actual card pixels at equal width/theme after real input.
            func pixels(_ card: ZeVisualizationCardView) -> Data? {
                card.setNeedsLayout(); card.layoutIfNeeded()
                return UIGraphicsImageRenderer(bounds: card.bounds).image { context in
                    card.layer.render(in: context.cgContext)
                }.pngData()
            }
            let livePixels = Dictionary(uniqueKeysWithValues: cards.map { ($0.component.id, pixels($0)) })
            let frozen = ChatShareSnapshot.copy(liveMessage)
            let capturedSelections = frozen.blocks[0].visualizationSelections
            liveBlock.visualizationSelections.removeAll()
            try check(!capturedSelections.isEmpty && frozen.blocks[0].visualizationSelections == capturedSelections, "Share freezes selections independently of later live changes")
            liveBlock.visualizationSelections = capturedSelections
            let shareHost = UIHostingController(rootView: content(frozen, snapshot: true))
            shareHost.view.tintAdjustmentMode = .normal
            window.rootViewController = shareHost
            try await Task.sleep(nanoseconds: 350_000_000)
            shareHost.view.layoutIfNeeded()
            let sharedCards = descendants(shareHost.view).compactMap { $0 as? ZeVisualizationCardView }
            try check(sharedCards.count == cards.count, "Share contains exactly the live cards")
            for card in sharedCards {
                let shared = pixels(card)
                try shared?.write(to: directory.appendingPathComponent("visualization-share-\(card.component.id)-\(dark ? "dark" : "light").png"))
                if let entry = livePixels[card.component.id], let data = entry {
                    try data.write(to: directory.appendingPathComponent("visualization-live-\(card.component.id)-\(dark ? "dark" : "light").png"))
                }
                try check(shared != nil && shared == livePixels[card.component.id]!, "Live/share pixels match for \(card.component.id) in \(dark ? "dark" : "light")")
            }
            let sharedText = descendants(shareHost.view).compactMap { $0 as? SelectableMarkdownTextView }.map { $0.textStorage.string }.joined()
            try check(!sharedText.contains("VISUAL_LAST") && !sharedText.contains("VISUAL_DETAIL"), "Share does not append invisible detail data")
            let shareShot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try shareShot.pngData()?.write(to: directory.appendingPathComponent("visualization-share-\(dark ? "dark" : "light").png"))
            let remount = UIHostingController(rootView: content(liveMessage, snapshot: false))
            remount.view.tintAdjustmentMode = .normal
            window.rootViewController = remount
            try await Task.sleep(nanoseconds: 250_000_000)
            remount.view.layoutIfNeeded()
            let remounted = descendants(remount.view).compactMap { $0 as? ZeVisualizationCardView }
            try check(remounted.count == cards.count, "All cards remount after cache clear")
            for card in remounted {
                try check(pixels(card) == livePixels[card.component.id]!, "Cache eviction preserves visible selection for \(card.component.id)")
            }
            // Open the modal only after live/share pixel comparisons. UIKit
            // dims the presenting controller's controls while a sheet is up;
            // that transient modal appearance is not the conversation snapshot.
            if let tableCard = remounted.first(where: { $0.component.type == .table }),
               let button = tableCard.subviews.compactMap({ $0 as? UIButton }).first {
                button.sendActions(for: .touchUpInside)
                try await Task.sleep(nanoseconds: 400_000_000)
                let navigation = remount.presentedViewController as? UINavigationController
                let detail = navigation?.topViewController as? ZeVisualizationDetailController
                try check(detail != nil, "Expand opens real detail controller")
                if let detail, let search = detail.navigationItem.searchController {
                    search.searchBar.text = "VISUAL_LAST"
                    detail.updateSearchResults(for: search)
                    try check(detail.tableView.numberOfRows(inSection: 0) == 1, "Detail filter finds non-preview row")
                    detail.tableView(detail.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
                    try check(UIPasteboard.general.string?.contains("VISUAL_LAST") == true, "Copy row preserves original value")
                }
                remount.dismiss(animated: false)
                try await Task.sleep(nanoseconds: 150_000_000)
            } else { try check(false, "Table expand control missing") }
            for width: CGFloat in [240, 390, 700] {
                let card = cards[0]
                card.frame.size = CGSize(width: width, height: ZeVisualizationCardView.height(card.component, width: width, font: 16.5))
                card.setNeedsLayout(); card.layoutIfNeeded()
                try check(card.bounds.height.isFinite, "Width change stays finite")
            }
        }
        let model = AIChatViewModel()
        let block = AssistantBlock(kind: .text, content: markdown)
        block.cachedMarkdown = MarkdownContent(markdown)
        let message = ChatMessage(role: .assistant, content: "", blocks: [block])
        let request = ChatShareSnapshot.request(messages: [message], title: document.title, vm: model)
        let groups = ChatShareCells.renderGroups(request.cells, selected: Set(request.cells.map(\.id)))
        var options = ChatExportOptions(); options.format = .pdf
        let result = try await ChatExportRenderer(vm: model).render(groups: groups, messages: request.messages, title: document.title, options: options, progress: { _, _ in })
        let pdf = PDFDocument(url: result.url)
        for marker in ["VISUAL_BEGIN", "VISUAL_SOURCE"] {
            try check(pdf?.string?.contains(marker) == true, "PDF includes searchable \(marker)")
        }
        let firstPage = pdf?.page(at: 0)
        try check(pdf?.string?.contains("VISUAL_LAST") == false && pdf?.string?.contains("VISUAL_DETAIL") == false, "PDF matches visible preview without duplicate data appendix")
        try check(document.components.first { $0.type == .table }?.csv.contains("VISUAL_LAST") == true, "Complete table remains available through CSV")
        let mixed = markdown + "\n\n| Key | Value |\n| --- | --- |\n| Test | 1 |\n"
        try check(ChatExportContent.tableChunks(mixed, contentWidth: 360, base: 390) == nil, "Mixed table and chart preserve original block selection identity")
        let numericSelections = pdf?.findString("8.91", withOptions: []) ?? []
        try check(numericSelections.contains { selection in
            guard let firstPage, selection.pages.contains(firstPage) else { return false }
            // The metric must appear inside the visible card on the first page.
            return selection.bounds(for: firstPage).midY > firstPage.bounds(for: .mediaBox).height * 0.42
        }, "PDF contains the metric inside the visible card")
        try Data(contentsOf: result.url).write(to: directory.appendingPathComponent("visualization.pdf"))
        checks += try await runCustom(window: window, directory: directory)
        let report: [String: Any] = ["success": true, "checks": checks, "elapsedSeconds": CFAbsoluteTimeGetCurrent() - started,
                                    "systemVersion": UIDevice.current.systemVersion, "cacheCount": ZeVisualizationCache.shared.statistics.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("visualization-result.json"))
    }

    private static func runCustom(window: UIWindow, directory: URL) async throws -> [String] {
        var checks: [String] = []
        func check(_ ok: Bool, _ text: String) throws {
            guard ok else { throw NSError(domain: "CustomVisualization", code: checks.count, userInfo: [NSLocalizedDescriptionKey: text]) }
            checks.append(text)
        }
        func descendants(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(descendants) }
        let html = ##"""
        <style>body{background:#13243d;color:#fff}h2{margin:8px 0}label{display:block}svg{width:100%;height:170px}button{border:0;border-radius:10px;padding:8px}</style>
        <h2>自由布局 · 交互几何</h2><label>角度 <input id="angle" type="range" min="10" max="90" value="30"></label><output id="value">30</output>
        <svg viewBox="0 0 340 170"><path id="shape" fill="#2bc9ac" stroke="#ffbd55" stroke-width="4" d="M20 145 L170 30 L320 145 Z"/><text x="20" y="165" fill="white">非固定图表组件</text></svg>
        <script>const slider=document.getElementById('angle');const output=document.getElementById('value');const shape=document.getElementById('shape');function draw(){output.textContent=slider.value;shape.setAttribute('d',`M20 145 L170 ${slider.value} L320 145 Z`);ZeVisualization.setState({angle:Number(slider.value),label:'角度'});}slider.value=ZeVisualization.state.angle||30;slider.addEventListener('input',draw);draw();window.networkBlocked=false;fetch('https://example.com/').catch(()=>window.networkBlocked=true);</script>
        """##
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": "custom-fixture", "title": "模型自由绘制",
            "components": [["id": "free", "type": "custom", "height": 320, "fallbackText": "可调角度的自定义三角形", "html": html]]])
        let markdown = "```ze-visualization\n" + String(decoding: data, as: UTF8.self) + "\n```"
        let block = AssistantBlock(kind: .text, content: markdown)
        let message = ChatMessage(role: .assistant, content: "", blocks: [block])
        func content(_ m: ChatMessage, snapshot: Bool) -> some View {
            ScrollView { AssistantBlockView(block: m.blocks[0], message: m, isActiveMessage: false,
                highlightedBlockId: .constant(nil), detailBlock: .constant(nil)).padding(16) }
                .environment(\.chatSnapshotRendering, snapshot)
        }
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: content(message, snapshot: false))
        window.rootViewController = host
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        for _ in 0..<50 {
            if descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first?.isPending == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let card = descendants(host.view).compactMap { $0 as? ZeVisualizationCardView }.first
        try check(card != nil, "Custom design is integrated in real chat Markdown")
        let previewImages = descendants(host.view).compactMap { ($0 as? UIImageView)?.image }
        try check(!previewImages.isEmpty, "Custom HTML/SVG renders a real inline image")
        try check(!descendants(host.view).contains { $0 is WKWebView }, "Inline chat does not retain a web view per card")
        card?.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
        try await Task.sleep(nanoseconds: 500_000_000)
        let detail = (host.presentedViewController as? UINavigationController)?.topViewController as? ZeCustomVisualizationController
        try check(detail != nil, "Custom preview opens its interactive runtime")
        if let detail, let web = descendants(detail.view).compactMap({ $0 as? WKWebView }).first {
            for _ in 0..<30 {
                if !web.isLoading { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let blocked = try await web.evaluateJavaScript("window.networkBlocked")
            try check(blocked as? Bool == true, "Generated runtime blocks external network requests")
            _ = try await web.evaluateJavaScript("document.getElementById('angle').value='75';document.getElementById('angle').dispatchEvent(new Event('input'));true")
            let output = try await web.evaluateJavaScript("document.getElementById('value').textContent")
            try check(output as? String == "75", "Model-authored slider changes custom SVG and readout")
            detail.done()
            for _ in 0..<30 {
                if block.visualizationSelections.values.contains(where: { $0.customStateJSON?.contains("75") == true }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try check(block.visualizationSelections.values.contains { $0.customStateJSON?.contains("75") == true }, "Closing atomically captures custom state and preview")
        try await Task.sleep(nanoseconds: 350_000_000)
        let liveImage = descendants(host.view).compactMap { ($0 as? UIImageView)?.image?.pngData() }.first
        try liveImage?.write(to: directory.appendingPathComponent("visualization-custom-live.png"))
        let frozen = ChatShareSnapshot.copy(message)
        let share = UIHostingController(rootView: content(frozen, snapshot: true))
        window.rootViewController = share
        try await Task.sleep(nanoseconds: 250_000_000)
        share.view.layoutIfNeeded()
        let sharedImage = descendants(share.view).compactMap { ($0 as? UIImageView)?.image?.pngData() }.first
        try check(liveImage != nil && sharedImage == liveImage, "Custom live/share previews use identical captured pixels")
        try sharedImage?.write(to: directory.appendingPathComponent("visualization-custom-share.png"))
        ZeCustomVisualizationRenderer.shared.clear()
        try check(ZeCustomVisualizationRenderer.shared.cacheCount == 0, "Custom preview cache releases all derived images")
        return checks
    }
}
#endif
