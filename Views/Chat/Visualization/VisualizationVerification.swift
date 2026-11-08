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
        let previous = window.rootViewController
        let previousStyle = window.overrideUserInterfaceStyle
        defer { window.rootViewController = previous; window.overrideUserInterfaceStyle = previousStyle }
        var nativeError: Error?
        var customError: Error?
        do { try await runNative(window: window, directory: directory) }
        catch { nativeError = error }
        window.rootViewController = previous
        window.overrideUserInterfaceStyle = previousStyle
        var customChecks: [String] = []
        do { customChecks = try await runCustom(window: window, directory: directory) }
        catch { customError = error }
        if customError == nil {
            try JSONSerialization.data(withJSONObject: ["success": true, "checks": customChecks], options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("visualization-custom-result.json"))
        }
        let report: [String: Any] = ["success": nativeError == nil && customError == nil,
            "nativeSuccess": nativeError == nil, "customSuccess": customError == nil,
            "nativeError": nativeError?.localizedDescription ?? "", "customError": customError?.localizedDescription ?? "",
            "systemVersion": UIDevice.current.systemVersion]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("visualization-result.json"))
        if let error = nativeError ?? customError { throw error }
    }

    private static func runNative(window: UIWindow, directory: URL) async throws {
        var checks: [String] = []
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else {
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try? shot.pngData()?.write(to: directory.appendingPathComponent("visualization-failure.png"))
                let report: [String: Any] = ["success": false, "checks": checks, "error": message]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("visualization-native-result.json"))
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
            if !dark, let metric = metricLabels.first as? ZeVisualizationSelectableLabel {
                try await ConversationShareVerification.requestUIAction("selectVisualization", details: [
                    "identifier": metric.accessibilityIdentifier ?? "ze.visualization.value.92",
                    "startX": 16, "startY": metric.bounds.midY, "endX": 2])
                try check(metric.activeSelectionView?.isFirstResponder == true,
                          "Actual double tap starts native metric text selection")
                if let selected = metric.activeSelectionView, let text = selected.text, (text as NSString).length >= 2 {
                    selected.selectedRange = NSRange(location: 0, length: 2); selected.copy(nil)
                    try check(UIPasteboard.general.string == (text as NSString).substring(with: selected.selectedRange),
                              "Native chart text copies only the selected substring")
                }
                let selectedImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try selectedImage.pngData()?.write(to: directory.appendingPathComponent("visualization-native-selection.png"))
                metric.endTextSelection()
                try check(metric.activeSelectionView == nil, "Native text selection releases its temporary text view")
                try await Task.sleep(nanoseconds: 200_000_000)
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
        var exportCardGeometry: [String: [String: Any]] = [:]
        ZeVisualizationCardView.verificationOnLayout = { card in
            var root: UIView = card
            while let parent = root.superview { root = parent }
            let values: [[String: Any]] = descendants(card).compactMap { view in
                guard let label = view as? UILabel,
                      label.accessibilityIdentifier?.hasPrefix("ze.visualization.value.") == true else { return nil }
                return ["text": label.text ?? "", "hidden": label.isHidden,
                    "bounds": NSCoder.string(for: label.bounds),
                    "frameInCard": NSCoder.string(for: label.convert(label.bounds, to: card)),
                    "textRect": NSCoder.string(for: label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines))]
            }
            exportCardGeometry[card.component.id] = ["cardBounds": NSCoder.string(for: card.bounds),
                "cardInRoot": NSCoder.string(for: card.convert(card.bounds, to: root)),
                "rootBounds": NSCoder.string(for: root.bounds), "metrics": values]
        }
        defer { ZeVisualizationCardView.verificationOnLayout = nil }
        let result = try await ChatExportRenderer(vm: model).render(groups: groups, messages: request.messages, title: document.title, options: options, progress: { _, _ in })
        ZeVisualizationCardView.verificationOnLayout = nil
        try Data(contentsOf: result.url).write(to: directory.appendingPathComponent("visualization.pdf"))
        let pdf = PDFDocument(url: result.url)
        let numericSelections = pdf?.findString("8.91", withOptions: []) ?? []
        let pages: [[String: Any]] = (0..<(pdf?.pageCount ?? 0)).compactMap { index in
            guard let page = pdf?.page(at: index) else { return nil }
            let selections = numericSelections.filter { $0.pages.contains(page) }.map { selection in
                ["text": selection.string ?? "", "bounds": NSCoder.string(for: selection.bounds(for: page))]
            }
            return ["index": index, "bounds": NSCoder.string(for: page.bounds(for: .mediaBox)),
                "text": page.string ?? "", "metricSelections": selections]
        }
        try JSONSerialization.data(withJSONObject: ["pages": pages, "cards": exportCardGeometry,
            "metricSelectionCount": numericSelections.count], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("visualization-pdf-layout.json"))
        for marker in ["VISUAL_BEGIN", "VISUAL_SOURCE"] {
            try check(pdf?.string?.contains(marker) == true, "PDF includes searchable \(marker)")
        }
        let firstPage = pdf?.page(at: 0)
        try check(pdf?.string?.contains("VISUAL_LAST") == false && pdf?.string?.contains("VISUAL_DETAIL") == false, "PDF matches visible preview without duplicate data appendix")
        try check(document.components.first { $0.type == .table }?.csv.contains("VISUAL_LAST") == true, "Complete table remains available through CSV")
        let mixed = markdown + "\n\n| Key | Value |\n| --- | --- |\n| Test | 1 |\n"
        try check(ChatExportContent.tableChunks(mixed, contentWidth: 360, base: 390) == nil, "Mixed table and chart preserve original block selection identity")
        try check(numericSelections.contains { selection in
            guard let firstPage, selection.pages.contains(firstPage) else { return false }
            // The metric must appear inside the visible card on the first page.
            return selection.bounds(for: firstPage).midY > firstPage.bounds(for: .mediaBox).height * 0.42
        }, "PDF contains the metric inside the visible card")
        let report: [String: Any] = ["success": true, "checks": checks, "elapsedSeconds": CFAbsoluteTimeGetCurrent() - started,
                                    "systemVersion": UIDevice.current.systemVersion, "cacheCount": ZeVisualizationCache.shared.statistics.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("visualization-native-result.json"))
    }

    private static func runCustom(window: UIWindow, directory: URL) async throws -> [String] {
        var checks: [String] = []
        var captureGeometry: [[String: Any]] = []
        ZeCustomVisualizationRuntime.verificationOnCapture = { geometry in
            captureGeometry.append(geometry)
            try? JSONSerialization.data(withJSONObject: captureGeometry, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("visualization-custom-capture-layout.json"))
        }
        defer { ZeCustomVisualizationRuntime.verificationOnCapture = nil }
        func check(_ ok: Bool, _ text: String) throws {
            guard ok else {
                let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try? shot.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-failure.png"))
                try? JSONSerialization.data(withJSONObject: ["success": false, "checks": checks, "error": text], options: [.prettyPrinted])
                    .write(to: directory.appendingPathComponent("visualization-custom-result.json"))
                throw NSError(domain: "CustomVisualization", code: checks.count, userInfo: [NSLocalizedDescriptionKey: text])
            }
            checks.append(text)
        }
        func descendants(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(descendants) }
        let html = ##"""
        <style>body{background:#13243d;color:#fff}h2{margin:8px 0}label{display:block}svg{width:100%;height:170px}button{border:0;border-radius:10px;padding:8px}</style>
        <h2>自由布局 · 交互几何</h2><label>角度 <input id="angle" type="range" min="10" max="90" value="30"></label><output id="value">30</output>
        <p style="margin:4px 0">Inline <strong>75</strong> pts</p>
        <svg viewBox="0 0 340 170"><path id="shape" fill="#2bc9ac" stroke="#ffbd55" stroke-width="4" d="M20 145 L170 30 L320 145 Z"/><text x="20" y="165" fill="white">非固定图表组件</text></svg>
        <section style="line-height:1.6;padding:8px 0"><p>这是用于检查正文高度的多行中文说明。完整来源应当出现在图形下方，不能因为模型低估高度而被裁切。</p><p>数据来自验收样例，数值仅用于交互测试，并非实时价格。展开页可以滚动查看所有说明。</p><p>图形、刻度、日期和来源都属于同一个内容区域。分享时应保留全部末行文字。</p></section>
        <svg id="edge-chart" viewBox="0 0 340 40" style="height:48px"><text x="320" y="30" fill="white">2026-11-07</text></svg>
        <footer id="last-source" style="line-height:1.6">完整来源：用户提供的验证数据。最后一行必须保留。SOURCE_END</footer>
        <div id="end-marker" style="height:6px;background:#ff00ff;margin-top:6px"></div>
        <script>const slider=document.getElementById('angle');const output=document.getElementById('value');const shape=document.getElementById('shape');function draw(){output.textContent=slider.value;shape.setAttribute('d',`M20 145 L170 ${slider.value} L320 145 Z`);ZeVisualization.setState({angle:Number(slider.value),label:'角度'});}slider.value=ZeVisualization.state.angle||30;slider.addEventListener('input',draw);draw();window.networkBlocked=false;fetch('https://example.com/').catch(()=>window.networkBlocked=true);</script>
        """##
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": "custom-fixture", "title": "模型自由绘制",
            "components": [["id": "free", "type": "custom", "height": 180, "fallbackText": "可调角度的自定义三角形", "html": html]]])
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
        let renderWaits = Int((ZeCustomVisualizationRenderer.maximumRenderSeconds + 1) / 0.1)
        for _ in 0..<renderWaits {
            if descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first?.isPending == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        host.view.layoutIfNeeded()
        var card = descendants(host.view).compactMap { $0 as? ZeVisualizationCardView }.first
        try check(card != nil, "Custom design is integrated in real chat Markdown")
        let previewImages = descendants(host.view).compactMap { ($0 as? ZeCustomVisualizationPreview)?.renderedImage }
        try check(!previewImages.isEmpty, "Custom HTML/SVG renders a real inline image")
        try previewImages.first?.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-initial.png"))
        let initialLayoutImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try initialLayoutImage.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-initial-layout.png"))
        try check(!descendants(host.view).contains { $0 is WKWebView }, "Inline chat does not retain a web view per card")
        if var preview = descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first,
           let glyph = preview.textLayout.glyphs.first {
            var imageRect = preview.imageDisplayRect
            var scale = imageRect.width / 360
            let initialImageHeight = imageRect.height
            let originalIdentity = String(describing: ObjectIdentifier(preview))
            let selectedPoint = CGPoint(x: imageRect.minX + glyph.rect.midX * scale, y: imageRect.minY + glyph.rect.midY * scale)
            let windowPoint = preview.convert(selectedPoint, to: window)
            var preselection: [String: Any] = ["preview": NSCoder.string(for: preview.frame), "image": NSCoder.string(for: imageRect),
                "card": card.map { NSCoder.string(for: $0.frame) } ?? "missing", "glyphs": preview.textLayout.glyphs.count,
                "naturalHeight": block.visualizationSelections.values.first?.customContentHeight ?? 0,
                "windowPoint": [windowPoint.x, windowPoint.y],
                "hitViewBefore": String(describing: window.hitTest(windowPoint, with: nil)),
                "pictureFrames": preview.subviews.compactMap { ($0 as? UIImageView).map { NSCoder.string(for: $0.frame) } }]
            try JSONSerialization.data(withJSONObject: preselection, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("visualization-custom-selection-layout.json"))
            try check(abs(imageRect.minY) < 1 && abs(imageRect.height - preview.bounds.height) < 2,
                      "New custom preview uses its natural height without centered blank margins")
            try check(preview.textLayout.text.contains("SOURCE_END") && preview.textLayout.text.contains("2026-11-07"),
                      "Custom snapshot contains exact selectable HTML and SVG text")
            try check(preview.textLayout.text.contains("Inline 75 pts"),
                      "Inline HTML emphasis does not insert artificial copied line breaks")
            try await ConversationShareVerification.requestUIAction("selectVisualization", details: [
                "identifier": "ze.visualization.custom.preview", "startX": imageRect.minX + glyph.rect.midX * scale,
                "startY": imageRect.minY + glyph.rect.midY * scale])
            for _ in 0..<20 {
                if let current = descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first(where: { $0.window === window }) {
                    preview = current
                }
                if preview.window === window && preview.activeSelectionView?.isFirstResponder == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            imageRect = preview.imageDisplayRect; scale = imageRect.width / 360
            card = descendants(host.view).compactMap { $0 as? ZeVisualizationCardView }.first
            preselection["gestureEvents"] = preview.verificationGestureEvents
            preselection["hitViewAfter"] = String(describing: window.hitTest(windowPoint, with: nil))
            preselection["previewInWindowAfter"] = NSCoder.string(for: preview.convert(preview.bounds, to: window))
            try JSONSerialization.data(withJSONObject: preselection, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("visualization-custom-selection-layout.json"))
            try check(preview.window === window && preview.activeSelectionView?.isFirstResponder == true,
                      "Actual long press starts native text selection over custom pixels (active=\(preview.activeSelectionView != nil), mounted=\(preview.window === window), original=\(originalIdentity), current=\(ObjectIdentifier(preview)), bounds=\(preview.bounds), image=\(imageRect))")
            try check(abs(imageRect.minY) < 1 && abs(imageRect.height - initialImageHeight) < 2 && abs(preview.bounds.height - imageRect.height) < 2,
                      "Focusing custom selection preserves its natural preview geometry")
            if let selected = preview.activeSelectionView {
                let full = (selected.text ?? "") as NSString
                if let initialRange = selected.selectedTextRange {
                    let before = selected.selectedRange
                    let targetText = full.range(of: "非固定图表组件")
                    if let targetGlyph = preview.textLayout.glyphs.last(where: { NSIntersectionRange($0.range, targetText).length > 0 }) {
                        let endCaret = selected.caretRect(for: initialRange.end)
                        try await ConversationShareVerification.requestUIAction("dragVisualizationSelection", details: [
                            "identifier": "ze.visualization.custom.selection", "startX": endCaret.midX,
                            "startY": endCaret.maxY + 5, "endX": targetGlyph.rect.maxX * scale - 1,
                            "endY": targetGlyph.rect.midY * scale])
                        try check(selected.selectedRange.length > before.length,
                                  "Real native selection-handle drag extends across custom text nodes")
                        selected.copy(nil)
                        try check(UIPasteboard.general.string?.contains("角度") == true,
                                  "Dragged custom selection copies the intervening visible text")
                    }
                }
                let source = full.range(of: "SOURCE_END")
                try check(source.location != NSNotFound, "Custom source text is selectable beyond the original viewport")
                selected.selectedRange = source
                selected.copy(nil)
                try check(UIPasteboard.general.string == "SOURCE_END", "Custom copy uses the selected exact text, not a summary")
                if let range = selected.selectedTextRange {
                    let regions = selected.selectionRects(for: range)
                    try check(!regions.isEmpty && regions.allSatisfy { $0.rect.maxY <= preview.bounds.height + 2 },
                              "Custom selection handles and highlight use captured footer geometry")
                }
                let first = full.range(of: "自由布局"), last = full.range(of: "非固定图表组件")
                if first.location != NSNotFound, last.location != NSNotFound {
                    selected.selectedRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                    selected.copy(nil)
                    try check(UIPasteboard.general.string?.contains("非固定图表组件") == true,
                              "One native custom selection spans multiple HTML and SVG text nodes")
                }
            }
            let selectedImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try selectedImage.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-selection.png"))
            preview.endTextSelection()
            try check(preview.activeSelectionView == nil, "Custom selection releases its temporary native text view")
            if let current = descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first(where: { $0.window === window }) { preview = current }
            imageRect = preview.imageDisplayRect; scale = imageRect.width / 360
            let doubleGlyph = preview.textLayout.glyphs.first ?? glyph
            try await ConversationShareVerification.requestUIAction("selectVisualization", details: [
                "identifier": "ze.visualization.custom.preview", "startX": imageRect.minX + doubleGlyph.rect.midX * scale,
                "startY": imageRect.minY + doubleGlyph.rect.midY * scale, "endX": 2])
            for _ in 0..<20 {
                if let current = descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first(where: { $0.window === window }) { preview = current }
                if preview.window === window && preview.activeSelectionView?.isFirstResponder == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(preview.window === window && preview.activeSelectionView?.isFirstResponder == true &&
                      (preview.activeSelectionView?.selectedRange.length ?? 0) > 0,
                      "Actual double tap also selects custom text after a prior selection closes (current=\(ObjectIdentifier(preview)), mounted=\(preview.window === window))")
            preview.endTextSelection()
        } else { try check(false, "Custom snapshot is missing text geometry") }
        card?.subviews.compactMap { $0 as? UIButton }.first?.sendActions(for: .touchUpInside)
        try await Task.sleep(nanoseconds: 500_000_000)
        let detail = (host.presentedViewController as? UINavigationController)?.topViewController as? ZeCustomVisualizationController
        try check(detail != nil, "Custom preview opens its interactive runtime")
        if let detail, let web = descendants(detail.view).compactMap({ $0 as? WKWebView }).first {
            for _ in 0..<30 {
                if !web.isLoading { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let actualHeight = try await web.evaluateJavaScript(ZeCustomVisualizationRuntime.measureScript)
            try check(((actualHeight as? NSNumber)?.doubleValue ?? 0) > 500, "Long document exceeds the model's initial height hint")
            try check(web.scrollView.isScrollEnabled, "Expanded custom content allows scrolling")
            let edgeFits = try await web.evaluateJavaScript("(() => {const s=document.getElementById('edge-chart'), b=s.getBBox(), v=s.viewBox.baseVal;return b.x+b.width<=v.x+v.width && b.y+b.height<=v.y+v.height})()")
            try check(edgeFits as? Bool == true, "Rightmost SVG date fits inside the captured viewBox")
            _ = try await web.evaluateJavaScript("window.scrollTo(0,document.body.scrollHeight);true")
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
        let livePreview = descendants(host.view).compactMap { ($0 as? ZeCustomVisualizationPreview)?.renderedImage }.first
        try livePreview?.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-live.png"))
        try check(livePreview?.cgImage.map { (500...600).contains($0.width) && $0.height >= 180 } == true, "Custom capture has bounded physical pixels, not a toolbar icon")
        if let cg = livePreview?.cgImage {
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let count = pixels.withUnsafeMutableBytes { buffer -> Int in
                guard let ctx = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let data = buffer.bindMemory(to: UInt8.self)
                return stride(from: 0, to: data.count, by: 4).filter { i in
                    data[i] < 100 && data[i + 1] > 140 && data[i + 2] > 100 && data[i + 3] > 200
                }.count
            }
            try check(count > 500, "Custom snapshot contains the actual teal SVG geometry")
        } else { try check(false, "Custom snapshot has pixels") }
        if let preview = descendants(host.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first,
           let card = descendants(host.view).compactMap({ $0 as? ZeVisualizationCardView }).first,
           let image = preview.renderedImage {
            let expected = preview.bounds.width * image.size.height / image.size.width
            try check(abs(preview.bounds.height - expected) < 2, "Custom body follows image aspect without centered vertical blank space")
            try check(preview.frame.minY <= 76 && card.bounds.maxY - preview.frame.maxY <= 13,
                      "Custom card has compact heading and bottom insets")
            let naturalHeight = image.size.height / image.size.width * 360
            try check(naturalHeight > 500 && naturalHeight < 1200, "Complete multiline document is captured beyond the height hint")
            if let cg = image.cgImage {
                var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let marker = pixels.withUnsafeMutableBytes { buffer -> Int in
                    guard let ctx = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    let bytes = buffer.bindMemory(to: UInt8.self)
                    return stride(from: 0, to: bytes.count, by: 4).filter { i in
                        bytes[i] > 220 && bytes[i + 1] < 40 && bytes[i + 2] > 220 && bytes[i + 3] > 220
                    }.count
                }
                try check(marker > 500, "Snapshot includes the final marker below all source text")
            }
        } else { try check(false, "Measured custom card remains mounted") }
        let cardShot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        try cardShot.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-layout.png"))
        let liveImage = livePreview?.pngData()
        try liveImage?.write(to: directory.appendingPathComponent("visualization-custom-live.png"))
        let frozen = ChatShareSnapshot.copy(message)
        let share = UIHostingController(rootView: content(frozen, snapshot: true))
        window.rootViewController = share
        try await Task.sleep(nanoseconds: 250_000_000)
        share.view.layoutIfNeeded()
        let sharedImage = descendants(share.view).compactMap { ($0 as? ZeCustomVisualizationPreview)?.renderedImage?.pngData() }.first
        try sharedImage?.write(to: directory.appendingPathComponent("visualization-custom-share.png"))
        try check(liveImage != nil && sharedImage == liveImage, "Custom live/share previews use identical captured pixels")
        let sharedLayout = descendants(share.view).compactMap { ($0 as? ZeCustomVisualizationPreview)?.textLayout }.first
        try check(sharedLayout?.text.contains("75") == true && sharedLayout?.text.contains("SOURCE_END") == true,
                  "Shared custom image retains exact current selectable text with frozen state")
        if var preview = descendants(share.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first,
           let glyph = preview.textLayout.glyphs.first {
            let rect = preview.imageDisplayRect, scale = rect.width / 360
            try check(abs(rect.minY) < 1 && abs(rect.height - preview.bounds.height) < 2,
                      "Remounted shared custom preview keeps the same complete natural height")
            try await ConversationShareVerification.requestUIAction("selectVisualization", details: [
                "identifier": "ze.visualization.custom.preview", "startX": rect.minX + glyph.rect.midX * scale,
                "startY": rect.minY + glyph.rect.midY * scale])
            for _ in 0..<20 {
                if let current = descendants(share.view).compactMap({ $0 as? ZeCustomVisualizationPreview }).first(where: { $0.window === window }) { preview = current }
                if preview.window === window && preview.activeSelectionView?.isFirstResponder == true { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(preview.window === window && preview.activeSelectionView?.isFirstResponder == true,
                      "Long press also selects exact custom text after share remount (current=\(ObjectIdentifier(preview)), mounted=\(preview.window === window))")
            preview.endTextSelection()
        }
        let compactData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": "compact", "title": "Compact",
            "components": [["id": "small", "type": "custom", "height": 600, "fallbackText": "Short content",
                            "html": "<p style='margin:0;line-height:24px'>Short content with a 600px hint</p>"]]])
        let compact = try ZeVisualizationParser.parse(String(decoding: compactData, as: UTF8.self)).get().components[0]
        let compactImage: UIImage? = await withCheckedContinuation { continuation in
            ZeCustomVisualizationRenderer.shared.render(component: compact, state: nil, dark: true) { continuation.resume(returning: $0) }
        }
        try check(compactImage.map { $0.size.height / $0.size.width * 360 < 100 } == true,
                  "Overestimated height hint does not create an empty 600px viewport")
        try compactImage?.pngData()?.write(to: directory.appendingPathComponent("visualization-custom-compact.png"))
        let canvasHTML = """
        <canvas id="labels" width="340" height="100" style="width:100%;height:100px"></canvas>
        <script>const c=document.getElementById('labels');let ctx=c.getContext('2d');ctx.font='18px sans-serif';ctx.fillText('STALE_OLD',10,24);c.width=680;c.height=200;ctx=c.getContext('2d');ctx.scale(2,2);ctx.font='18px sans-serif';ctx.fillStyle='#1668ca';ctx.fillText('Canvas III WWW 中文',10,30);ctx.fillText('Clear-old',10,65);ctx.clearRect(0,0,340,100);ctx.fillStyle='#1668ca';ctx.fillText('Canvas III WWW 中文',10,30);</script>
        """
        let canvasData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "id": "canvas", "title": "Canvas labels",
            "components": [["id": "drawn", "type": "custom", "height": 180, "fallbackText": "Canvas III WWW 中文", "html": canvasHTML]]])
        let canvas = try ZeVisualizationParser.parse(String(decoding: canvasData, as: UTF8.self)).get().components[0]
        let canvasSnapshot: ZeCustomVisualizationSnapshot? = await withCheckedContinuation { continuation in
            ZeCustomVisualizationRenderer.shared.renderSnapshot(component: canvas, state: nil, dark: true) { continuation.resume(returning: $0) }
        }
        let canvasText = canvasSnapshot?.textLayout.text ?? ""
        try check(canvasText.contains("Canvas III WWW 中文") && !canvasText.contains("STALE_OLD") && !canvasText.contains("Clear-old"),
                  "Canvas text remains selectable and drops labels erased or reset before capture")
        if let layout = canvasSnapshot?.textLayout {
            let text = layout.text as NSString
            let narrow = text.range(of: "III"), wide = text.range(of: "WWW")
            let narrowWidth = layout.glyphs.filter { NSIntersectionRange($0.range, narrow).length > 0 }.reduce(CGFloat(0)) { $0 + $1.rect.width }
            let wideWidth = layout.glyphs.filter { NSIntersectionRange($0.range, wide).length > 0 }.reduce(CGFloat(0)) { $0 + $1.rect.width }
            try check(wideWidth > narrowWidth * 1.5, "Canvas selection geometry measures proportional glyph widths")
        }
        ZeCustomVisualizationRenderer.shared.clear()
        try check(ZeCustomVisualizationRenderer.shared.cacheCount == 0, "Custom preview cache releases all derived images")
        return checks
    }
}
#endif
