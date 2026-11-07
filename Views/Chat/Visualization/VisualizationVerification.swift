#if DEBUG
import SwiftUI
import UIKit
import PDFKit

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
            guard condition else { throw NSError(domain: "VisualizationVerification", code: checks.count, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks.append(message)
        }
        func descendants(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(descendants) }
        let document = try ZeVisualizationParser.parse(fixture).get()
        let markdown = "```ze-visualization\n" + fixture + "\n```"
        let previous = window.rootViewController
        let previousStyle = window.overrideUserInterfaceStyle
        defer { window.rootViewController = previous; window.overrideUserInterfaceStyle = previousStyle }
        let started = CFAbsoluteTimeGetCurrent()
        for dark in [false, true] {
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            let host = UIHostingController(rootView: ScrollView {
                SelectableMarkdownView(markdown: markdown).padding(16)
            }.background(Color(uiColor: .systemBackground)))
            window.rootViewController = host
            try await Task.sleep(nanoseconds: 350_000_000)
            host.view.layoutIfNeeded()
            let cards = descendants(host.view).compactMap { $0 as? ZeVisualizationCardView }
            try check(cards.count == 8, "All eight component types rendered in actual TextKit")
            try check(cards.allSatisfy { $0.bounds.width > 100 && $0.bounds.height > 50 }, "Nonzero attachment geometry")
            let textViews = descendants(host.view).compactMap { $0 as? SelectableMarkdownTextView }
            try check(textViews.contains { ChatSearchComposite.build($0.textStorage).text.contains("VISUAL_LAST") }, "Search projection includes data outside inline preview")
            try check(!textViews.contains { ChatSearchComposite.build($0.textStorage).text.contains("schemaVersion") }, "Search does not expose protocol JSON")
            if let canvas = descendants(host.view).compactMap({ $0 as? ZeVisualizationPlotCanvas }).first {
                _ = UIGraphicsImageRenderer(bounds: canvas.bounds).image { _ in canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true) }
                canvas.select(at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
                try check(canvas.accessibilityValue?.isEmpty == false, "Chart selection produces a real value")
            } else { try check(false, "Chart missing") }
            if let control = descendants(host.view).compactMap({ $0 as? UISegmentedControl }).first {
                control.selectedSegmentIndex = 1; control.sendActions(for: .valueChanged)
                try check(control.selectedSegmentIndex == 1, "Range control action delivered")
            }
            if let tableCard = cards.first(where: { $0.component.type == .table }),
               let button = tableCard.subviews.compactMap({ $0 as? UIButton }).first {
                button.sendActions(for: .touchUpInside)
                try await Task.sleep(nanoseconds: 400_000_000)
                let navigation = host.presentedViewController as? UINavigationController
                let detail = navigation?.topViewController as? ZeVisualizationDetailController
                try check(detail != nil, "Expand opens real detail controller")
                if let detail, let search = detail.navigationItem.searchController {
                    search.searchBar.text = "VISUAL_LAST"
                    detail.updateSearchResults(for: search)
                    try check(detail.tableView.numberOfRows(inSection: 0) == 1, "Detail filter finds non-preview row")
                    detail.tableView(detail.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
                    try check(UIPasteboard.general.string?.contains("VISUAL_LAST") == true, "Copy row preserves original value")
                }
                host.dismiss(animated: false)
            } else { try check(false, "Table expand control missing") }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: directory.appendingPathComponent("visualization-\(dark ? "dark" : "light").png"))
            ZeVisualizationCache.shared.clear()
            SelectableMarkdownView.clearVisualizationCaches()
            try check(ZeVisualizationCache.shared.statistics.count == 0, "Explicit cache clear")
            try check(cards.count == 8 && cards[0].component.items?.first?.value == 8.91, "Visible snapshot survives cache clear")
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
        for marker in ["VISUAL_BEGIN", "VISUAL_LAST", "VISUAL_SOURCE", "VISUAL_DETAIL"] {
            try check(pdf?.string?.contains(marker) == true, "PDF includes searchable \(marker)")
        }
        try Data(contentsOf: result.url).write(to: directory.appendingPathComponent("visualization.pdf"))
        let report: [String: Any] = ["success": true, "checks": checks, "elapsedSeconds": CFAbsoluteTimeGetCurrent() - started,
                                    "systemVersion": UIDevice.current.systemVersion, "cacheCount": ZeVisualizationCache.shared.statistics.count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("visualization-result.json"))
    }
}
#endif
