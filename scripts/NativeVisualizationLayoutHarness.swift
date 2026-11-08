import UIKit

/// Focused production UIKit checks. No model provider, browser or system share UI.
@MainActor private final class NativeVisualizationLayoutDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    private let fixture = #"""
    {"schemaVersion":1,"id":"native-layout","title":"原生卡片换行验收","components":[
      {"id":"weather","type":"info","title":"未来一周天气变化与出行提醒：降温、降雨和阵风都要完整阅读","items":[
        {"id":"cold","label":"冷空气提醒","text":"11-09 起明显降温，11-10～11-11 最低仅 12°C；早晚出门记得增加外套，老人和儿童请留意体感变化。"},
        {"id":"rain","label":"降雨与连续阴雨天气提醒","text":"今明两天降雨概率 80%+（毛毛雨转小雨），通勤请携带雨具，雨后道路湿滑，骑车与步行都要注意。","detail":"Forecast source: https://open-meteo.com/en/docs/weather-forecast-api — Read every final word: RAIN_DETAIL_END"},
        {"id":"wind","label":"风力","text":"11-09 最大阵风 21 km/h，体感偏凉，注意防风保暖；沿江和高处风力更明显。WIND_LAST"}
      ]},
      {"id":"metrics","type":"metric_grid","title":"较长指标标题在窄屏和大字号下也应完整显示","unit":"今日快照","items":[
        {"id":"temperature","label":"白天最高温度及户外体感参考","value":22.875,"precision":3,"detail":"温度来源完整说明 TEMP_END"},
        {"id":"outlook","label":"Upcoming weather changes and travel advice","text":"Cloudy with occasional light rain; carry a jacket and an umbrella. OUTLOOK_END"},
        {"id":"missing","label":"当前观测数据状态","missingReason":"本时段暂未取得可核对的数据，请稍后刷新。MISSING_END"}
      ]},
      {"id":"table","type":"table","title":"长表格单元格也应逐行展示","headers":["日期及天气现象","出行建议与注意事项"],"rows":[
        ["11-09 冷空气到达，气温开始明显下降","早晚增加外套并携带雨具；这段中文需要跨多行完整显示。TABLE_CHINESE_END"],
        ["11-10 to 11-11: cloudy with rain","Long English table content wraps without losing the last word or clipping its descenders. TABLE_ENGLISH_END"]
      ]}
    ]}
    """#

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .systemBackground
        self.window = window
        window.makeKeyAndVisible()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await run()
        }
        return true
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func layout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        for child in view.subviews { layout(child) }
    }

    private func labels(_ view: UIView) -> [ZeVisualizationSelectableLabel] {
        descendants(view).compactMap { $0 as? ZeVisualizationSelectableLabel }
    }

    private func makeCard(_ component: ZeVisualizationComponent, width: CGFloat, font: CGFloat) -> ZeVisualizationCardView {
        let card = ZeVisualizationCardView(component: component, fontSize: font)
        card.frame = CGRect(x: 0, y: 0, width: width,
                            height: ZeVisualizationCardView.height(component, width: width, font: font))
        layout(card)
        return card
    }

    private func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        var screenshots: [String] = []
        var geometry: [[String: Any]] = []
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "NativeVisualizationLayout", code: checks.count,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            checks.append(message)
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "NativeVisualizationLayout", code: checks.count,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        do {
            guard let window, let host = window.rootViewController?.view else {
                throw NSError(domain: "NativeVisualizationLayout", code: -1)
            }
            let document = try ZeVisualizationParser.parse(fixture).get()
            try check(document.components.count == 3, "Weather, metrics and table fixtures use the production parser")
            var matrixCount = 0
            for dark in [false, true] {
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                for width: CGFloat in [240, 280, 390, 700] {
                    for font: CGFloat in [16.5, 28] {
                        for component in document.components {
                            let card = makeCard(component, width: width, font: font)
                            card.overrideUserInterfaceStyle = dark ? .dark : .light
                            host.addSubview(card)
                            layout(card)
                            let context = "\(component.id), width \(width), font \(font), dark \(dark)"
                            let text = labels(card)
                            try require(!text.isEmpty && card.bounds.height.isFinite, "Missing text or invalid height: \(context)")
                            for label in text {
                                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                                try require(label.numberOfLines == 0 && required.height <= label.bounds.height + 1,
                                            "Text does not fit: \(context), \(label.text ?? ""), needs \(required.height), has \(label.bounds.height)")
                                let frame = label.convert(label.bounds, to: card)
                                try require(card.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Text outside card: \(context)")
                                if let parent = label.superview {
                                    try require(parent.bounds.insetBy(dx: -1, dy: -1).contains(label.frame), "Text outside its row: \(context)")
                                }
                            }
                            for parent in descendants(card) {
                                let siblings = parent.subviews.compactMap { $0 as? ZeVisualizationSelectableLabel }
                                for (index, first) in siblings.enumerated() {
                                    for second in siblings.dropFirst(index + 1) {
                                        try require(!first.frame.insetBy(dx: 0.5, dy: 0.5).intersects(second.frame.insetBy(dx: 0.5, dy: 0.5)),
                                                    "Text fields overlap: \(context)")
                                    }
                                }
                            }
                            let attachment = ZeVisualizationAttachment(component: component, fontSize: font)
                            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
                            let bounds = attachment.attachmentBounds(for: container,
                                proposedLineFragment: CGRect(x: 0, y: 0, width: width, height: 20), glyphPosition: .zero, characterIndex: 0)
                            let mounted = attachment.makeView(width: width)
                            layout(mounted)
                            try require(abs(bounds.height - mounted.bounds.height) < 1 &&
                                        abs(bounds.height - card.bounds.height - ZeVisualizationAttachment.verticalInset * 2) < 1,
                                        "TextKit and rendered attachment heights differ: \(context)")
                            geometry.append(["component": component.id, "width": width, "font": font, "dark": dark,
                                             "height": card.bounds.height, "labelCount": text.count])
                            matrixCount += 1
                            card.removeFromSuperview()
                        }
                    }
                }
            }
            try check(matrixCount == 48, "All three card kinds fit at 240/280/390/700pt, normal/large fonts and both appearances")
            try check(true, "Every native label fits its full text and remains inside its row and card")
            try check(true, "Sibling text fields do not overlap")
            try check(true, "TextKit attachment bounds match the measured production card and mounted view")
            let weather = makeCard(document.components[0], width: 390, font: 16.5)
            let weatherText = labels(weather).compactMap(\.text).joined(separator: "\n")
            try check(weatherText.contains("RAIN_DETAIL_END") && weatherText.contains("WIND_LAST"),
                      "Long Chinese weather values and the English source detail remain visible")
            let resize = makeCard(document.components[0], width: 700, font: 16.5)
            let wideHeight = resize.bounds.height
            resize.frame.size = CGSize(width: 240, height: resize.fittingHeight(width: 240))
            layout(resize)
            try check(resize.bounds.height > wideHeight && labels(resize).allSatisfy {
                $0.sizeThatFits(CGSize(width: $0.bounds.width, height: .greatestFiniteMagnitude)).height <= $0.bounds.height + 1
            }, "An existing card reflows to its new width without clipping")
            host.addSubview(weather)
            guard let selectable = labels(weather).first(where: { $0.accessibilityIdentifier == "ze.visualization.value.rain" }) else {
                throw NSError(domain: "NativeVisualizationLayout", code: -2)
            }
            let fullText = selectable.text
            selectable.beginTextSelection()
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(selectable.activeSelectionView?.text == fullText && selectable.activeSelectionView?.textContainer.maximumNumberOfLines == 0,
                      "Native text selection retains the complete wrapped value")
            selectable.endTextSelection()
            try check(selectable.activeSelectionView == nil && !selectable.isHidden,
                      "Ending native text selection releases its temporary text view")
            weather.removeFromSuperview()
            for dark in [false, true] {
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                let content = UIView()
                content.backgroundColor = .systemBackground
                content.overrideUserInterfaceStyle = dark ? .dark : .light
                var y: CGFloat = 16
                for component in document.components {
                    let card = makeCard(component, width: 358, font: 16.5)
                    card.frame.origin = CGPoint(x: 16, y: y)
                    content.addSubview(card)
                    y = card.frame.maxY + 16
                }
                content.frame = CGRect(x: 0, y: 0, width: 390, height: y)
                host.addSubview(content)
                layout(content)
                try await Task.sleep(nanoseconds: 100_000_000)
                let image = UIGraphicsImageRenderer(bounds: content.bounds).image { context in
                    content.layer.render(in: context.cgContext)
                }
                let name = "native-layout-\(dark ? "dark" : "light").png"
                try require(image.pngData() != nil, "Could not render \(name)")
                try image.pngData()?.write(to: directory.appendingPathComponent(name))
                screenshots.append(name)
                content.removeFromSuperview()
            }
            try check(screenshots.count == 2, "Production native cards render in light and dark appearance")
            let report: [String: Any] = ["success": true, "checks": checks, "screenshots": screenshots,
                "geometry": geometry, "systemVersion": UIDevice.current.systemVersion,
                "scope": "Production parser, native cards and TextKit attachment sizing; iOS 16 target. Direct native selection entry, no automated touch assertion and no system share regression."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("native-layout-result.json"))
        } catch {
            let report: [String: Any] = ["success": false, "checks": checks, "screenshots": screenshots,
                "error": error.localizedDescription, "geometry": geometry]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("native-layout-result.json"))
        }
    }
}

@main private enum NativeVisualizationLayoutMain {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(NativeVisualizationLayoutDelegate.self))
    }
}
