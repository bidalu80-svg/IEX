import UIKit

final class ZeVisualizationInteractionState {
    var seriesIndex: Int?
    var lastHalf = false
    var selectedText: String?
}

/// One bounded component per attachment keeps TextKit's line fragments small.
/// No view, bitmap or hosting controller is retained by a history message.
final class ZeVisualizationAttachment: NSTextAttachment {
    let component: ZeVisualizationComponent
    let fontSize: CGFloat
    private let interaction = ZeVisualizationInteractionState()
    var plainText: String { component.plainText }
    init(component: ZeVisualizationComponent, fontSize: CGFloat) {
        self.component = component
        self.fontSize = fontSize
        super.init(data: nil, ofType: nil)
        image = Self.blank
        _ = ZeVisualizationLifecycle.shared
    }
    required init?(coder: NSCoder) { return nil }
    private static let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = max(1, min(lineFrag.width, textContainer?.size.width ?? lineFrag.width))
        return CGRect(x: 0, y: 0, width: width, height: ZeVisualizationCardView.height(component, width: width, font: fontSize))
    }
    func makeView(width: CGFloat) -> UIView {
        let view = ZeVisualizationCardView(component: component, fontSize: fontSize, interaction: interaction)
        view.frame = CGRect(x: 0, y: 0, width: width, height: ZeVisualizationCardView.height(component, width: width, font: fontSize))
        return view
    }
}

/// Installed once, no observer per message. Clearing releases derived decode
/// data; visible cards and the SQLite message snapshots remain intact.
final class ZeVisualizationLifecycle {
    static let shared = ZeVisualizationLifecycle()
    private var observers: [NSObjectProtocol] = []
    private init() {
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification, Notification.Name("sessionDidDelete")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                ZeVisualizationCache.shared.clear()
                Task { @MainActor in SelectableMarkdownView.clearVisualizationCaches() }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// UIKit labels deliberately remain real subviews for the existing PDF exporter.
/// No per-frame work: paths draw only when data, selection, traits or size change.
final class ZeVisualizationCardView: UIView {
    let component: ZeVisualizationComponent
    private let fontSize: CGFloat
    private let heading = UILabel()
    private let action = UIButton(type: .system)
    private let bodyContainer = UIView()
    private var chart: ZeVisualizationPlotView?
    private var lastWidth: CGFloat = 0
    private var metricLabels: [UILabel] = []
    static func height(_ c: ZeVisualizationComponent, width: CGFloat, font: CGFloat) -> CGFloat {
        let scale = max(1, font / 16.5)
        if c.type.isChart { return 350 * scale }
        if c.type == .table { return (106 + CGFloat(min(5, c.rows?.count ?? 0)) * 36) * scale }
        let columns = width < 260 || font > 25 || c.type == .info ? 1 : 2
        let rows = (min(6, c.items?.count ?? 0) + columns - 1) / columns
        return (74 + CGFloat(rows) * (c.type == .info ? 64 : 92)) * scale
    }
    init(component: ZeVisualizationComponent, fontSize: CGFloat, interaction: ZeVisualizationInteractionState = ZeVisualizationInteractionState()) {
        self.component = component
        self.fontSize = fontSize
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 16
        layer.borderWidth = 0.5
        clipsToBounds = true
        accessibilityIdentifier = "ze.visualization.\(component.id)"
        heading.font = .systemFont(ofSize: fontSize, weight: .semibold)
        heading.text = [component.title, component.unit].compactMap { $0 }.joined(separator: " · ")
        heading.numberOfLines = 2
        addSubview(heading)
        action.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        action.accessibilityLabel = String(localized: "Open visualization details")
        action.addAction(UIAction { [weak self] _ in self?.openDetails() }, for: .touchUpInside)
        addSubview(action)
        addSubview(bodyContainer)
        if component.type.isChart {
            let plot = ZeVisualizationPlotView(component: component, fontSize: fontSize, interaction: interaction)
            chart = plot
            addSubview(plot)
        }
    }
    required init?(coder: NSCoder) { return nil }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        heading.frame = CGRect(x: 16, y: 12, width: max(1, bounds.width - 76), height: 46 * max(1, fontSize / 16.5))
        action.frame = CGRect(x: bounds.width - 52, y: 10, width: 44, height: 44)
        let top = heading.frame.maxY + 8
        chart?.frame = CGRect(x: 12, y: top, width: bounds.width - 24, height: bounds.height - top - 12)
        bodyContainer.frame = CGRect(x: 16, y: top, width: bounds.width - 32, height: bounds.height - top - 14)
        if abs(lastWidth - bounds.width) > 0.5 {
            lastWidth = bounds.width
            rebuildBody()
        }
    }
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, secondary: Bool = false) -> UILabel {
        let l = UILabel(); l.text = text; l.numberOfLines = 2
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = secondary ? .secondaryLabel : .label
        l.adjustsFontSizeToFitWidth = false
        return l
    }
    private func rebuildBody() {
        guard !component.type.isChart else { return }
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        metricLabels.removeAll()
        let width = bodyContainer.bounds.width
        let height = bodyContainer.bounds.height
        guard width > 0, height > 0 else { return }
        if component.type == .table {
            let rows = [component.headers ?? []] + (component.rows ?? []).prefix(5).map { $0.map(\.text) }
            let rowHeight = height / CGFloat(max(1, rows.count))
            for (rowIndex, cells) in rows.enumerated() {
                let columns = min(3, cells.count)
                let columnWidth = (width - CGFloat(max(0, columns - 1)) * 8) / CGFloat(max(1, columns))
                for (column, text) in cells.prefix(3).enumerated() {
                    let value = label(text, size: fontSize * 0.8, weight: rowIndex == 0 ? .semibold : .regular)
                    value.frame = CGRect(x: CGFloat(column) * (columnWidth + 8), y: CGFloat(rowIndex) * rowHeight,
                                         width: columnWidth, height: rowHeight - 4)
                    bodyContainer.addSubview(value)
                }
            }
            return
        }
        let items = Array((component.items ?? []).prefix(6))
        let columns = bounds.width < 260 || fontSize > 25 || component.type == .info ? 1 : 2
        let rows = (items.count + columns - 1) / columns
        let rowHeight = height / CGFloat(max(1, rows))
        let columnWidth = (width - CGFloat(columns - 1) * 16) / CGFloat(columns)
        for (index, item) in items.enumerated() {
            let cell = UIView(frame: CGRect(x: CGFloat(index % columns) * (columnWidth + 16), y: CGFloat(index / columns) * rowHeight,
                                            width: columnWidth, height: rowHeight - 6))
            let name = label(item.label, size: fontSize * 0.85, secondary: true)
            let value = label(item.displayValue, size: component.type == .info ? fontSize : fontSize * 1.65, weight: .semibold)
            let nameHeight = min(cell.bounds.height * 0.4, fontSize * 1.8)
            name.frame = CGRect(x: 0, y: 0, width: columnWidth, height: nameHeight)
            value.frame = CGRect(x: 0, y: nameHeight + 2, width: columnWidth, height: max(1, cell.bounds.height - nameHeight - 2))
            value.accessibilityIdentifier = "ze.visualization.value.\(item.id)"
            cell.addSubview(name); cell.addSubview(value)
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = "\(item.label), \(item.displayValue), \(component.unit ?? "")"
            cell.accessibilityTraits = .staticText
            bodyContainer.addSubview(cell)
            metricLabels += [name, value]
        }
    }
    private func openDetails() {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController {
                guard vc.presentedViewController == nil else { return }
                vc.present(UINavigationController(rootViewController: ZeVisualizationDetailController(component: component)), animated: true)
                return
            }
            responder = r.next
        }
    }
}

/// Native vector chart usable on iOS 16, including pie/donut. Selection uses a
/// tap, so dragging vertically continues scrolling the conversation normally.
final class ZeVisualizationPlotView: UIView {
    let component: ZeVisualizationComponent
    private let fontSize: CGFloat
    private let drawing = ZeVisualizationPlotCanvas()
    let readout = UILabel()
    private let legend = UISegmentedControl(items: [])
    private let range = UISegmentedControl(items: [String(localized: "All"), String(localized: "Last half")])
    private var selectedSeries: Int? = nil
    private var half = false
    private let interaction: ZeVisualizationInteractionState
    init(component: ZeVisualizationComponent, fontSize: CGFloat, interaction: ZeVisualizationInteractionState = ZeVisualizationInteractionState()) {
        self.component = component; self.fontSize = fontSize
        self.interaction = interaction
        super.init(frame: .zero)
        readout.font = .systemFont(ofSize: fontSize * 0.8)
        readout.numberOfLines = 3
        readout.text = String(localized: "Tap the chart to inspect a value")
        readout.accessibilityIdentifier = "ze.visualization.readout"
        addSubview(readout); addSubview(drawing)
        drawing.component = component
        drawing.seriesIndex = interaction.seriesIndex
        drawing.lastHalf = interaction.lastHalf
        if let selected = interaction.selectedText { readout.text = selected }
        drawing.onSelection = { [weak self] text in self?.readout.text = text; self?.interaction.selectedText = text }
        drawing.accessibilityLabel = component.title ?? String(localized: "Chart")
        drawing.accessibilityHint = String(localized: "Open details for all data values")
        let series = component.series ?? []
        if series.count > 1 {
            legend.insertSegment(withTitle: String(localized: "All"), at: 0, animated: false)
            for (i, s) in series.enumerated() { legend.insertSegment(withTitle: s.label, at: i + 1, animated: false) }
            legend.selectedSegmentIndex = interaction.seriesIndex.map { $0 + 1 } ?? 0
            legend.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.selectedSeries = self.legend.selectedSegmentIndex == 0 ? nil : self.legend.selectedSegmentIndex - 1
                self.drawing.seriesIndex = self.selectedSeries
                self.interaction.seriesIndex = self.selectedSeries
                self.interaction.selectedText = nil
                self.readout.text = String(localized: "Tap the chart to inspect a value")
            }, for: .valueChanged)
            addSubview(legend)
        }
        if !series.isEmpty {
            range.selectedSegmentIndex = interaction.lastHalf ? 1 : 0
            range.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.half = self.range.selectedSegmentIndex == 1
                self.drawing.lastHalf = self.half
                self.interaction.lastHalf = self.half
                self.interaction.selectedText = nil
                self.readout.text = String(localized: "Tap the chart to inspect a value")
            }, for: .valueChanged)
            addSubview(range)
        } else if component.type == .pie || component.type == .donut {
            // Labels remain available without relying on color or sight.
            readout.text = (component.items ?? []).prefix(4).map { "\($0.label): \($0.displayValue)" }.joined(separator: " · ")
        }
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        let row: CGFloat = 32
        var top: CGFloat = 0
        if range.superview != nil { range.frame = CGRect(x: 0, y: top, width: min(200, bounds.width), height: row); top += row + 6 }
        if legend.superview != nil { legend.frame = CGRect(x: 0, y: top, width: bounds.width, height: row); top += row + 6 }
        readout.frame = CGRect(x: 0, y: bounds.height - 52, width: bounds.width, height: 52)
        drawing.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(50, readout.frame.minY - top))
    }
}

final class ZeVisualizationPlotCanvas: UIView {
    var component: ZeVisualizationComponent? { didSet { setNeedsDisplay() } }
    var seriesIndex: Int? { didSet { selected = nil; setNeedsDisplay() } }
    var lastHalf = false { didSet { selected = nil; setNeedsDisplay() } }
    var onSelection: ((String) -> Void)?
    private var hits: [(CGPoint, String)] = []
    private var sectors: [(CGFloat, CGFloat, String)] = []
    private var selected: CGPoint?
    private let colors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo, .systemBrown]
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; contentMode = .redraw
        isAccessibilityElement = true; accessibilityTraits = .image
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }
    required init?(coder: NSCoder) { return nil }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); setNeedsDisplay() }
    private func text(_ value: String, at point: CGPoint) {
        (value as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.secondaryLabel])
    }
    override func draw(_ rect: CGRect) {
        guard let c = component, bounds.width > 60, bounds.height > 40 else { return }
        hits.removeAll(keepingCapacity: true); sectors.removeAll(keepingCapacity: true)
        if c.type == .pie || c.type == .donut { drawPie(c); return }
        let all = c.series ?? []
        let candidates = all.enumerated().filter { seriesIndex == nil || $0.offset == seriesIndex }
        let originalPoints = all.flatMap(\.points)
        let minX = originalPoints.map(\.x).min() ?? 0, maxX = originalPoints.map(\.x).max() ?? 1
        let lower = lastHalf ? minX + (maxX - minX) / 2 : minX
        let visible = candidates.map { (index: $0.offset, series: $0.element, points: $0.element.points.filter { $0.x >= lower }) }
        let points = visible.flatMap(\.points)
        let values = points.compactMap(\.y)
        guard !values.isEmpty else { text(String(localized: "No data in this range"), at: CGPoint(x: 10, y: 20)); return }
        let low = min(values.min() ?? 0, 0), high = max(values.max() ?? 1, 0)
        let span = max(high - low, 0.000001), xspan = max(maxX - lower, 0.000001)
        let plot = CGRect(x: 48, y: 8, width: bounds.width - 60, height: bounds.height - 34)
        func position(_ p: ZeVisualizationPoint, _ y: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((p.x - lower) / xspan) * plot.width,
                    y: plot.maxY - CGFloat((y - low) / span) * plot.height)
        }
        let grid = UIBezierPath()
        for i in 0...2 {
            let y = plot.minY + CGFloat(i) * plot.height / 2
            grid.move(to: CGPoint(x: plot.minX, y: y)); grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            text(ZeVisualizationFormat.number(high - Double(i) * span / 2), at: CGPoint(x: 0, y: y - 6))
        }
        UIColor.separator.setStroke(); grid.lineWidth = 0.5; grid.stroke()
        if let first = points.min(by: { $0.x < $1.x }), let last = points.max(by: { $0.x < $1.x }) {
            text(c.xLabel(first), at: CGPoint(x: plot.minX, y: plot.maxY + 5))
            let end = c.xLabel(last)
            let w = (end as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 10)]).width
            text(end, at: CGPoint(x: max(plot.minX, plot.maxX - w), y: plot.maxY + 5))
        }
        for (order, entry) in visible.enumerated() {
            let color = colors[entry.index % colors.count]
            let path = UIBezierPath(); path.lineWidth = 2
            var run: [CGPoint] = []
            func fillRun() {
                guard c.type == .area, let first = run.first, let last = run.last else { run.removeAll(keepingCapacity: true); return }
                let baseline = plot.maxY - CGFloat((0 - low) / span) * plot.height
                let area = UIBezierPath(); area.move(to: CGPoint(x: first.x, y: baseline))
                run.forEach { area.addLine(to: $0) }; area.addLine(to: CGPoint(x: last.x, y: baseline)); area.close()
                color.withAlphaComponent(0.12).setFill(); area.fill(); run.removeAll(keepingCapacity: true)
            }
            var connected = false
            for p in entry.points {
                guard let y = p.y else { connected = false; fillRun(); continue }
                let pt = position(p, y)
                hits.append((pt, "\(entry.series.label) · \(c.xLabel(p)): \(ZeVisualizationFormat.number(y)) \(c.unit ?? "")"))
                if c.type == .bar {
                    let group = max(2, min(32, plot.width / CGFloat(max(1, entry.points.count))))
                    let width = max(1, group * 0.8 / CGFloat(visible.count))
                    let zero = position(p, 0).y
                    let x = min(plot.maxX - width, max(plot.minX, pt.x - group * 0.4 + CGFloat(order) * width))
                    color.setFill(); UIBezierPath(rect: CGRect(x: x, y: min(zero, pt.y), width: width, height: max(1, abs(zero - pt.y)))).fill()
                } else {
                    if connected { path.addLine(to: pt) } else { path.move(to: pt) }
                    connected = true; run.append(pt)
                    if entry.points.count <= 60 { color.setFill(); UIBezierPath(ovalIn: CGRect(x: pt.x - 2, y: pt.y - 2, width: 4, height: 4)).fill() }
                }
            }
            fillRun(); color.setStroke(); path.stroke()
        }
        if let selected { UIColor.label.setStroke(); let p = UIBezierPath(ovalIn: CGRect(x: selected.x - 5, y: selected.y - 5, width: 10, height: 10)); p.lineWidth = 2; p.stroke() }
    }
    private func drawPie(_ c: ZeVisualizationComponent) {
        let items = (c.items ?? []).filter { ($0.value ?? 0) > 0 }
        let sum = items.reduce(0) { $0 + ($1.value ?? 0) }
        guard sum > 0 else { text(String(localized: "No positive values"), at: CGPoint(x: 12, y: 24)); return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.43
        var angle = -CGFloat.pi / 2
        for (i, item) in items.enumerated() {
            let end = angle + CGFloat((item.value ?? 0) / sum) * .pi * 2
            let p = UIBezierPath(); p.move(to: center); p.addArc(withCenter: center, radius: radius, startAngle: angle, endAngle: end, clockwise: true); p.close()
            colors[i % colors.count].setFill(); p.fill()
            sectors.append((angle, end, "\(item.label): \(item.displayValue) \(c.unit ?? "") (\(ZeVisualizationFormat.number((item.value ?? 0) / sum * 100, precision: 1))%)"))
            angle = end
        }
        if c.type == .donut {
            UIColor.secondarySystemGroupedBackground.setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - radius * 0.55, y: center.y - radius * 0.55, width: radius * 1.1, height: radius * 1.1)).fill()
        }
        accessibilityValue = sectors.map { $0.2 }.joined(separator: "; ")
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        select(at: gesture.location(in: self))
    }
    func select(at p: CGPoint) {
        if !sectors.isEmpty {
            let dx = p.x - bounds.midX, dy = p.y - bounds.midY
            let radius = min(bounds.width, bounds.height) * 0.43
            let distance = hypot(dx, dy)
            guard distance <= radius, component?.type != .donut || distance >= radius * 0.55 else { return }
            var angle = atan2(dy, dx); if angle < -.pi / 2 { angle += .pi * 2 }
            if let sector = sectors.first(where: { angle >= $0.0 && angle <= $0.1 }) { onSelection?(sector.2); accessibilityValue = sector.2 }
        } else if let hit = hits.min(by: { hypot($0.0.x - p.x, $0.0.y - p.y) < hypot($1.0.x - p.x, $1.0.y - p.y) }) {
            selected = hit.0; onSelection?(hit.1); accessibilityValue = hit.1; setNeedsDisplay()
        }
    }
}

/// Full original data remains accessible even when the inline preview is capped.
/// UITableView reuses rows; at most the validated 200 rows / 2,000 points exist.
final class ZeVisualizationDetailController: UITableViewController, UISearchResultsUpdating {
    private let component: ZeVisualizationComponent
    private var rows: [[ZeVisualizationCell]] = []
    private var displayed: [[ZeVisualizationCell]] = []
    private var sortColumn = 0
    private var ascending = true
    private let search = UISearchController(searchResultsController: nil)
    init(component: ZeVisualizationComponent) { self.component = component; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = component.title ?? String(localized: "Visualization")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share))]
        if component.type == .table { rows = component.rows ?? [] }
        else if let series = component.series {
            rows = series.flatMap { s in s.points.map { [.text(s.label), .text(component.xLabel($0)), $0.y.map(ZeVisualizationCell.number) ?? .null] } }
        } else { rows = (component.items ?? []).map { [.text($0.label), $0.value.map(ZeVisualizationCell.number) ?? .text($0.displayValue), .text($0.detail ?? "")] } }
        displayed = rows
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 70
        if component.type == .table {
            let button = UIBarButtonItem(title: String(localized: "Sort"), style: .plain, target: self, action: #selector(sortMenu))
            navigationItem.rightBarButtonItems?.append(button)
        }
        if component.type.isChart {
            let plot = ZeVisualizationPlotView(component: component, fontSize: 18)
            plot.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 360)
            tableView.tableHeaderView = plot
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let header = tableView.tableHeaderView, abs(header.bounds.width - tableView.bounds.width) > 0.5 {
            header.frame.size.width = tableView.bounds.width; tableView.tableHeaderView = header
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "value") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "value")
        let row = displayed[indexPath.row]
        let headers = component.headers ?? []
        cell.textLabel?.text = row.first?.text; cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = row.enumerated().dropFirst().map { i, value in
            "\(i < headers.count ? headers[i] + ": " : "")\(value.text)"
        }.joined(separator: "\n")
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        UIPasteboard.general.string = displayed[indexPath.row].map(\.text).joined(separator: "\t")
        tableView.deselectRow(at: indexPath, animated: true)
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Copied"))
    }
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        displayed = query.isEmpty ? rows : rows.filter { $0.contains { $0.text.localizedCaseInsensitiveContains(query) } }
        tableView.reloadData()
    }
    @objc private func sortMenu() {
        let alert = UIAlertController(title: String(localized: "Sort by column"), message: nil, preferredStyle: .actionSheet)
        for (i, header) in (component.headers ?? []).enumerated() {
            alert.addAction(UIAlertAction(title: header, style: .default) { [weak self] _ in
                guard let self else { return }
                self.ascending = self.sortColumn == i ? !self.ascending : true; self.sortColumn = i
                let up = self.ascending
                self.rows = self.rows.enumerated().sorted { a, b in
                    let lhs = a.element[i], rhs = b.element[i]
                    if lhs == rhs { return a.offset < b.offset }
                    if lhs == .null { return false }; if rhs == .null { return true }
                    if case .number(let x) = lhs, case .number(let y) = rhs { return up ? x < y : x > y }
                    return up ? lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending : lhs.text.localizedStandardCompare(rhs.text) == .orderedDescending
                }.map(\.element)
                self.updateSearchResults(for: self.search)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last
        present(alert, animated: true)
    }
    @objc private func close() { dismiss(animated: true) }
    @objc private func share() {
        // Share CSV text directly: no export files accumulate in Caches/tmp.
        let vc = UIActivityViewController(activityItems: [component.csv], applicationActivities: nil)
        vc.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(vc, animated: true)
    }
}
