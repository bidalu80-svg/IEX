import UIKit
import WebKit

/// Labels stay inexpensive during scrolling. A native selectable text view is
/// created only for the label the user double-taps or holds, then released when
/// selection ends. The glyphs, selection handles and edit menu remain UIKit's.
final class ZeVisualizationSelectableLabel: UILabel, UIGestureRecognizerDelegate {
    var selectionAttributedText: NSAttributedString?
    private(set) weak var activeSelectionView: UITextView?
    private var dismissTap: UITapGestureRecognizer?
    var onSelectionEnded: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.4
        addGestureRecognizer(hold)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { return nil }
    deinit { if let tap = dismissTap { tap.view?.removeGestureRecognizer(tap) } }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        beginTextSelection(at: gesture.location(in: self))
    }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        beginTextSelection(at: gesture.location(in: self))
    }
    func beginTextSelection(at point: CGPoint? = nil) {
        guard let parent = superview, activeSelectionView == nil else { return }
        let content = selectionAttributedText ?? attributedText ?? NSAttributedString(string: text ?? "", attributes: [
            .font: font ?? UIFont.systemFont(ofSize: 16), .foregroundColor: textColor ?? UIColor.label
        ])
        guard content.length > 0 else { return }
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer()
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        let selection = ZeVisualizationSelectionTextView(frame: .zero, textContainer: container)
        selection.isEditable = false; selection.isSelectable = true; selection.isScrollEnabled = false
        selection.backgroundColor = .clear
        selection.textContainer.lineFragmentPadding = 0
        selection.textContainer.maximumNumberOfLines = numberOfLines
        selection.textContainer.lineBreakMode = lineBreakMode
        let displayed = textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        let padding: CGFloat = 12
        selection.frame = frame.insetBy(dx: 0, dy: -padding)
        selection.textContainerInset = UIEdgeInsets(top: padding + max(0, displayed.minY), left: 0, bottom: padding, right: 0)
        selection.attributedText = content
        selection.accessibilityIdentifier = "ze.visualization.textSelection"
        selection.onResign = { [weak self] in self?.endTextSelection() }
        activeSelectionView = selection
        isHidden = true
        parent.addSubview(selection)
        selection.layoutIfNeeded()
        DispatchQueue.main.async { [weak self, weak selection] in
            guard let self, let selection, selection.superview != nil else { return }
            selection.becomeFirstResponder()
            if let point, let position = selection.closestPosition(to: CGPoint(x: point.x, y: point.y + padding)),
               let word = selection.tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)),
               selection.offset(from: word.start, to: word.end) > 0 {
                selection.selectedTextRange = word
            } else { selection.selectedRange = NSRange(location: 0, length: content.length) }
            UIMenuController.shared.showMenu(from: selection, rect: selection.bounds)
            // A hold still has its finger down when it begins. Install only
            // after that initiating gesture has ended so it cannot dismiss itself.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.installDismissTap() }
        }
    }
    func endTextSelection() {
        guard activeSelectionView != nil || dismissTap != nil else { return }
        if let tap = dismissTap { tap.view?.removeGestureRecognizer(tap) }
        dismissTap = nil
        let selection = activeSelectionView as? ZeVisualizationSelectionTextView
        selection?.onResign = nil
        selection?.resignFirstResponder(); selection?.removeFromSuperview()
        activeSelectionView = nil; isHidden = false
        onSelectionEnded?()
    }
    private func installDismissTap() {
        guard let window = activeSelectionView?.window, dismissTap == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
        tap.cancelsTouchesInView = false; tap.delegate = self
        window.addGestureRecognizer(tap); dismissTap = tap
    }
    @objc private func tappedOutside(_ gesture: UITapGestureRecognizer) { activeSelectionView?.resignFirstResponder() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissTap else { return true }
        // Keep selection-handle drags and menu actions in their original chain.
        if let selection = activeSelectionView, let touched = touch.view,
           touched === selection || touched.isDescendant(of: selection) { return false }
        var ancestor = touch.view
        while let view = ancestor {
            let name = String(describing: type(of: view))
            if name.contains("Menu") || name.contains("Callout") { return false }
            ancestor = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === dismissTap || otherGestureRecognizer === dismissTap
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endTextSelection() }
    }
}

private final class ZeVisualizationSelectionTextView: UITextView {
    var onResign: (() -> Void)?
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onResign?() }
        return result
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let name = NSStringFromSelector(action)
        if ["paste:", "cut:", "delete:", "_addShortcut:"].contains(name) || name.localizedCaseInsensitiveContains("image") { return false }
        return super.canPerformAction(action, withSender: sender)
    }
    override func addInteraction(_ interaction: any UIInteraction) {
        if #unavailable(iOS 17.0), interaction is UIContextMenuInteraction { return }
        super.addInteraction(interaction)
    }
}

final class ZeVisualizationInteractionState {
    var value: ZeVisualizationSelection { didSet { onChange?(value) } }
    var onLayoutChange: (() -> Void)?
    var onChange: ((ZeVisualizationSelection) -> Void)?
    init(value: ZeVisualizationSelection = ZeVisualizationSelection(), onChange: ((ZeVisualizationSelection) -> Void)? = nil) {
        self.value = value; self.onChange = onChange
    }
    var seriesIndex: Int? { get { value.seriesIndex } set { value.seriesIndex = newValue } }
    var lastHalf: Bool { get { value.lastHalf } set { value.lastHalf = newValue } }
    var selectedText: String? { get { value.selectedText } set { value.selectedText = newValue } }
}

/// One bounded component per attachment keeps TextKit's line fragments small.
/// No view, bitmap or hosting controller is retained by a history message.
final class ZeVisualizationAttachment: NSTextAttachment {
    let component: ZeVisualizationComponent
    let fontSize: CGFloat
    private let interaction: ZeVisualizationInteractionState
    static let verticalInset: CGFloat = 8
    var onLayoutChange: (() -> Void)? {
        get { interaction.onLayoutChange }
        set { interaction.onLayoutChange = newValue }
    }
    func cardHeight(width: CGFloat) -> CGFloat {
        ZeVisualizationCardView.height(component, width: width, font: fontSize,
                                       customHeight: interaction.value.customContentHeight)
    }
    var plainText: String { component.plainText }
    init(component: ZeVisualizationComponent, fontSize: CGFloat, selection: ZeVisualizationSelection = ZeVisualizationSelection(), onChange: ((ZeVisualizationSelection) -> Void)? = nil) {
        self.component = component
        self.fontSize = fontSize
        self.interaction = ZeVisualizationInteractionState(value: selection, onChange: onChange)
        super.init(data: nil, ofType: nil)
        image = Self.blank
        _ = ZeVisualizationLifecycle.shared
    }
    required init?(coder: NSCoder) { return nil }
    private static let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = max(1, min(lineFrag.width, textContainer?.size.width ?? lineFrag.width))
        return CGRect(x: 0, y: 0, width: width, height: cardHeight(width: width) + Self.verticalInset * 2)
    }
    func makeView(width: CGFloat) -> UIView {
        let height = cardHeight(width: width)
        let view = ZeVisualizationCardView(component: component, fontSize: fontSize, interaction: interaction)
        let container = ZeVisualizationAttachmentContainer(card: view)
        container.frame = CGRect(x: 0, y: 0, width: width, height: height + Self.verticalInset * 2)
        view.frame = CGRect(x: 0, y: Self.verticalInset, width: width, height: height)
        return container
    }
}

/// TextKit can briefly resize an attachment to its provisional glyph bounds.
/// Always lay out the child from the measured content, rather than stretching
/// its previous height with autoresizing (which centers/crops custom previews).
// Keep a regular Objective-C runtime name: the PDF exporter hides TextKit's
// underscore-prefixed private drawing views, and Swift private classes mangle
// to an underscore-prefixed name as well.
final class ZeVisualizationAttachmentContainer: UIView {
    private let card: ZeVisualizationCardView
    init(card: ZeVisualizationCardView) {
        self.card = card; super.init(frame: .zero); addSubview(card)
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = CGRect(x: 0, y: ZeVisualizationAttachment.verticalInset, width: bounds.width,
                            height: card.fittingHeight(width: bounds.width))
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
                Task { @MainActor in
                    SelectableMarkdownView.clearVisualizationCaches()
                }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// UIKit labels deliberately remain real subviews for the existing PDF exporter.
/// No per-frame work: paths draw only when data, selection, traits or size change.
final class ZeVisualizationCardView: UIView {
#if DEBUG
    static var verificationOnLayout: ((ZeVisualizationCardView) -> Void)?
#endif
    let component: ZeVisualizationComponent
    private let fontSize: CGFloat
    private let heading = ZeVisualizationSelectableLabel()
    private let action = UIButton(type: .system)
    private let bodyContainer = UIView()
    private var chart: ZeVisualizationPlotView?
    private var lastWidth: CGFloat = 0
    private var metricLabels: [UILabel] = []
    private var custom: ZeCustomVisualizationPreview?
    private let interaction: ZeVisualizationInteractionState
    func fittingHeight(width: CGFloat) -> CGFloat {
        Self.height(component, width: width, font: fontSize, customHeight: interaction.value.customContentHeight)
    }
    static func customHeaderHeight(_ c: ZeVisualizationComponent, width: CGFloat, font: CGFloat) -> CGFloat {
        let title = [c.title, c.unit].compactMap { $0 }.joined(separator: " · ")
        let face = UIFont.systemFont(ofSize: font, weight: .semibold)
        let rect = (title as NSString).boundingRect(with: CGSize(width: max(1, width - 76), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: face], context: nil)
        return max(52, ceil(min(rect.height, face.lineHeight * 2)) + 24)
    }
    static func height(_ c: ZeVisualizationComponent, width: CGFloat, font: CGFloat, customHeight: Double? = nil) -> CGFloat {
        let scale = max(1, font / 16.5)
        if c.type == .custom {
            let content = CGFloat(customHeight ?? Double(c.height ?? 360))
            return customHeaderHeight(c, width: width, font: font) + max(1, width - 24) / 360 * content + 12
        }
        if c.type.isChart { return 350 * scale }
        if c.type == .table { return (106 + CGFloat(min(5, c.rows?.count ?? 0)) * 36) * scale }
        let columns = width < 260 || font > 25 || c.type == .info ? 1 : 2
        let rows = (min(6, c.items?.count ?? 0) + columns - 1) / columns
        return (74 + CGFloat(rows) * (c.type == .info ? 64 : 92)) * scale
    }
    init(component: ZeVisualizationComponent, fontSize: CGFloat, interaction: ZeVisualizationInteractionState = ZeVisualizationInteractionState()) {
        self.component = component
        self.fontSize = fontSize
        self.interaction = interaction
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
        action.tintColor = .systemBlue
        action.accessibilityLabel = String(localized: "Open visualization details")
        action.addAction(UIAction { [weak self] _ in self?.openDetails() }, for: .touchUpInside)
        addSubview(action)
        addSubview(bodyContainer)
        if component.type == .custom {
            let preview = ZeCustomVisualizationPreview(component: component, interaction: interaction)
            custom = preview; addSubview(preview)
        }
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
        if let custom {
            let customTop = Self.customHeaderHeight(component, width: bounds.width, font: fontSize)
            heading.frame.size.height = customTop - 24
            custom.frame = CGRect(x: 12, y: customTop, width: max(1, bounds.width - 24), height: max(1, bounds.height - customTop - 12))
        }
        if abs(lastWidth - bounds.width) > 0.5 {
            lastWidth = bounds.width
            rebuildBody()
        }
#if DEBUG
        Self.verificationOnLayout?(self)
#endif
    }
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular, secondary: Bool = false) -> UILabel {
        let l = ZeVisualizationSelectableLabel(); l.text = text; l.numberOfLines = 2
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = secondary ? .secondaryLabel : .label
        l.adjustsFontSizeToFitWidth = false
        return l
    }
    private func rebuildBody() {
        guard !component.type.isChart, component.type != .custom else { return }
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
            cell.isAccessibilityElement = false
            cell.shouldGroupAccessibilityChildren = true
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
                let detail: UIViewController
                if component.type == .custom {
                    detail = ZeCustomVisualizationController(component: component, interaction: interaction, preview: custom)
                } else { detail = ZeVisualizationDetailController(component: component) }
                vc.present(UINavigationController(rootViewController: detail), animated: true)
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
    let readout = ZeVisualizationSelectableLabel()
    private let legend = UISegmentedControl(items: [])
    private let range = UISegmentedControl(items: [String(localized: "All"), String(localized: "Last half")])
    private var selectedSeries: Int? = nil
    private var half = false
    private let interaction: ZeVisualizationInteractionState
    private weak var controlSelectionLabel: ZeVisualizationSelectableLabel?
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
        drawing.selectedPointIndex = interaction.value.selectedPointIndex
        if let selected = interaction.selectedText { readout.text = selected }
        drawing.onSelection = { [weak self] text in
            guard let self else { return }
            self.readout.text = text
            self.interaction.value.selectedPointIndex = self.drawing.selectedPointIndex
            self.interaction.selectedText = text
        }
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
                self.interaction.value.selectedPointIndex = nil
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
                self.interaction.value.selectedPointIndex = nil
                self.readout.text = String(localized: "Tap the chart to inspect a value")
            }, for: .valueChanged)
            addSubview(range)
        } else if component.type == .pie || component.type == .donut {
            // Labels remain available without relying on color or sight.
            readout.text = interaction.selectedText ?? (component.items ?? []).prefix(4).map { "\($0.label): \($0.displayValue)" }.joined(separator: " · ")
        }
        for control in [legend, range] where control.superview != nil {
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(selectControlText(_:)))
            hold.minimumPressDuration = 0.4; control.addGestureRecognizer(hold)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(selectControlText(_:)))
            doubleTap.numberOfTapsRequired = 2; control.addGestureRecognizer(doubleTap)
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
    @objc private func selectControlText(_ gesture: UIGestureRecognizer) {
        guard (gesture is UILongPressGestureRecognizer && gesture.state == .began) ||
                (gesture is UITapGestureRecognizer && gesture.state == .ended),
              let control = gesture.view as? UISegmentedControl, control.numberOfSegments > 0 else { return }
        let segmentWidth = control.bounds.width / CGFloat(control.numberOfSegments)
        let index = max(0, min(control.numberOfSegments - 1, Int(gesture.location(in: control).x / max(1, segmentWidth))))
        guard let text = control.titleForSegment(at: index), !text.isEmpty else { return }
        controlSelectionLabel?.endTextSelection(); controlSelectionLabel?.removeFromSuperview()
        let rect = control.convert(CGRect(x: CGFloat(index) * segmentWidth + 4, y: 0,
                                          width: max(1, segmentWidth - 8), height: control.bounds.height), to: self)
        let label = ZeVisualizationSelectableLabel(frame: rect)
        label.font = .systemFont(ofSize: 13, weight: .medium); label.text = text; label.textColor = .clear
        label.textAlignment = .center
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        label.selectionAttributedText = NSAttributedString(string: text, attributes: [
            .font: label.font!, .foregroundColor: UIColor.clear, .paragraphStyle: paragraph
        ])
        label.onSelectionEnded = { [weak label] in label?.removeFromSuperview() }
        controlSelectionLabel = label; addSubview(label); label.beginTextSelection()
    }
}

final class ZeVisualizationPlotCanvas: UIView {
    var component: ZeVisualizationComponent? { didSet { setNeedsDisplay() } }
    var seriesIndex: Int? { didSet { selectedPointIndex = nil; setNeedsDisplay() } }
    var lastHalf = false { didSet { selectedPointIndex = nil; setNeedsDisplay() } }
    var onSelection: ((String) -> Void)?
    private var hits: [(CGPoint, String)] = []
    private var sectors: [(CGFloat, CGFloat, String)] = []
    private var textHits: [(CGRect, String)] = []
    private weak var axisSelectionLabel: ZeVisualizationSelectableLabel?
    // Index into the filtered data, not a view coordinate: survives new widths.
    var selectedPointIndex: Int? { didSet { setNeedsDisplay() } }
    private let colors: [UIColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo, .systemBrown]
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; contentMode = .redraw
        isAccessibilityElement = true; accessibilityTraits = .image
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdText(_:)))
        hold.minimumPressDuration = 0.4
        addGestureRecognizer(hold)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapText(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { return nil }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); setNeedsDisplay() }
    private func text(_ value: String, at point: CGPoint) {
        let face = UIFont.systemFont(ofSize: 10)
        let size = (value as NSString).size(withAttributes: [.font: face])
        textHits.append((CGRect(origin: point, size: size), value))
        (value as NSString).draw(at: point, withAttributes: [.font: face, .foregroundColor: UIColor.secondaryLabel])
    }
    override func draw(_ rect: CGRect) {
        guard let c = component, bounds.width > 60, bounds.height > 40 else { return }
        hits.removeAll(keepingCapacity: true); sectors.removeAll(keepingCapacity: true); textHits.removeAll(keepingCapacity: true)
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
        if let index = selectedPointIndex, hits.indices.contains(index) {
            let selected = hits[index].0
            UIColor.label.setStroke(); let p = UIBezierPath(ovalIn: CGRect(x: selected.x - 5, y: selected.y - 5, width: 10, height: 10)); p.lineWidth = 2; p.stroke()
        }
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
    @objc private func holdText(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        beginAxisTextSelection(at: gesture.location(in: self))
    }
    @objc private func doubleTapText(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        beginAxisTextSelection(at: gesture.location(in: self))
    }
    func beginAxisTextSelection(at point: CGPoint) {
        guard let hit = textHits.first(where: { $0.0.insetBy(dx: -7, dy: -7).contains(point) }) else { return }
        axisSelectionLabel?.endTextSelection(); axisSelectionLabel?.removeFromSuperview()
        let label = ZeVisualizationSelectableLabel(frame: hit.0)
        label.font = .systemFont(ofSize: 10); label.text = hit.1; label.textColor = .clear
        label.selectionAttributedText = NSAttributedString(string: hit.1, attributes: [.font: label.font!, .foregroundColor: UIColor.clear])
        label.onSelectionEnded = { [weak label] in label?.removeFromSuperview() }
        axisSelectionLabel = label; addSubview(label)
        label.beginTextSelection(at: CGPoint(x: point.x - hit.0.minX, y: point.y - hit.0.minY))
    }
    func select(at p: CGPoint) {
        if !sectors.isEmpty {
            let dx = p.x - bounds.midX, dy = p.y - bounds.midY
            let radius = min(bounds.width, bounds.height) * 0.43
            let distance = hypot(dx, dy)
            guard distance <= radius, component?.type != .donut || distance >= radius * 0.55 else { return }
            var angle = atan2(dy, dx); if angle < -.pi / 2 { angle += .pi * 2 }
            if let sector = sectors.first(where: { angle >= $0.0 && angle <= $0.1 }) { onSelection?(sector.2); accessibilityValue = sector.2 }
        } else if let hit = hits.enumerated().min(by: { hypot($0.element.0.x - p.x, $0.element.0.y - p.y) < hypot($1.element.0.x - p.x, $1.element.0.y - p.y) }) {
            selectedPointIndex = hit.offset; onSelection?(hit.element.1); accessibilityValue = hit.element.1
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

// MARK: - Model-authored visualizations

/// Text geometry belongs to the exact captured pixels, including the current
/// filter/slider state. It is transient and shares the bitmap's cache lifetime.
struct ZeCustomVisualizationTextLayout {
    struct Glyph {
        let range: NSRange
        let rect: CGRect
    }
    let text: String
    let glyphs: [Glyph]
    var byteCost: Int { text.utf16.count * 2 + glyphs.count * 64 }
    static let empty = Self(text: "", glyphs: [])
    init(text: String, glyphs: [Glyph]) { self.text = text; self.glyphs = glyphs }
    init(payload: Any?) {
        guard let value = payload as? [String: Any], let text = value["text"] as? String,
              text.utf16.count <= 8192, let rows = value["glyphs"] as? [[NSNumber]], rows.count <= 8192 else {
            self = .empty; return
        }
        let length = text.utf16.count
        self.text = text
        glyphs = rows.compactMap { row in
            guard row.count == 6 else { return nil }
            let start = row[0].intValue, count = row[1].intValue
            let values = row.dropFirst(2).map(\.doubleValue)
            guard start >= 0, count > 0, start <= length - count,
                  values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
            return Glyph(range: NSRange(location: start, length: count),
                         rect: CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
        }
    }
}

struct ZeCustomVisualizationSnapshot {
    let image: UIImage
    let textLayout: ZeCustomVisualizationTextLayout
    var byteCost: Int { (image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0) + textLayout.byteCost }
}

/// Generated interfaces run without the app's browser sessions, network or native
/// tool bridge. The CSP is installed before model markup and cannot be relaxed by it.
@MainActor enum ZeCustomVisualizationRuntime {
    static let width: CGFloat = 360
#if DEBUG
    static var verificationOnCapture: (([String: Any]) -> Void)?
    private static func recordCapture(_ web: WKWebView, phase: String) {
        let inset = web.scrollView.contentInset, adjusted = web.scrollView.adjustedContentInset
        verificationOnCapture?(["phase": phase, "frame": NSCoder.string(for: web.frame),
            "contentInset": [inset.top, inset.left, inset.bottom, inset.right],
            "adjustedContentInset": [adjusted.top, adjusted.left, adjusted.bottom, adjusted.right],
            "contentOffset": [web.scrollView.contentOffset.x, web.scrollView.contentOffset.y]])
    }
#endif
    static func webView(component: ZeVisualizationComponent, state: String?, dark: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let encodedState = (state.flatMap { $0.data(using: .utf8) }).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        let stateData = (try? JSONSerialization.data(withJSONObject: encodedState, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        let base64 = stateData.base64EncodedString()
        let bootstrap = """
        (() => {
          const saved = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), c => c.charCodeAt(0))));
          let value = saved.value || {};
          Object.defineProperty(window, 'ZeVisualization', {value: Object.freeze({
            get state() { return value; },
            setState(next) { const json=JSON.stringify(next); if(json.length<=16384) value=JSON.parse(json); }
          })});
          window.__zeCapture = () => JSON.stringify({value, inputs:Array.from(document.querySelectorAll('input,select,textarea')).slice(0,100).map((el,i)=>({i,value:el.value,checked:el.checked}))});
          // Canvas has no text DOM. Record only bounded, current text draws so
          // its labels can use the same native selection as HTML and SVG.
          const canvasText = new WeakMap();
          window.__zeCanvasText = canvasText;
          const proto = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
          for(const key of ['width','height']) {
            const descriptor=Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype,key);
            if(descriptor?.set) Object.defineProperty(HTMLCanvasElement.prototype,key,{...descriptor,set(next){canvasText.delete(this);descriptor.set.call(this,next);}});
          }
          if(proto) for(const name of ['fillText','strokeText','clearRect','fillRect']) {
            const original=proto[name];
            proto[name]=function(...args) {
              const result=original.apply(this,args);
              if(name==='clearRect'||name==='fillRect') {
                const m=this.getTransform();
                const a=m.transformPoint(new DOMPoint(args[0],args[1])),b=m.transformPoint(new DOMPoint(args[0]+args[2],args[1]+args[3]));
                if(m.b===0&&m.c===0&&Math.min(a.x,b.x)<=0&&Math.min(a.y,b.y)<=0&&Math.max(a.x,b.x)>=this.canvas.width&&Math.max(a.y,b.y)>=this.canvas.height&&
                    (name==='clearRect'||(this.globalAlpha===1&&typeof this.fillStyle==='string'&&!this.fillStyle.includes('rgba')))) canvasText.delete(this.canvas);
              } else {
                let list=canvasText.get(this.canvas)||[];
                if(list.length<256 && String(args[0]).length<=1024 && list.reduce((n,r)=>n+r.text.length,0)+String(args[0]).length<=8192) {
                  const text=String(args[0]), metrics=this.measureText(text), m=this.getTransform();
                  const width=Math.min(metrics.width,Number(args[3])||metrics.width);
                  const rtl=this.direction==='rtl'; let x=Number(args[1]),y=Number(args[2]);
                  if(this.textAlign==='center') x-=width/2;
                  else if(this.textAlign==='right'||(this.textAlign==='end'&&!rtl)||(this.textAlign==='start'&&rtl)) x-=width;
                  const ascent=metrics.actualBoundingBoxAscent||parseFloat(this.font)||15;
                  const descent=metrics.actualBoundingBoxDescent||3;
                  if(this.textBaseline==='top'||this.textBaseline==='hanging') y+=ascent;
                  else if(this.textBaseline==='middle') y+=(ascent-descent)/2;
                  const glyphs=[];let prefix='',offset=0;const ratio=metrics.width?width/metrics.width:1;
                  for(const ch of text) {
                    const from=this.measureText(prefix).width*ratio;prefix+=ch;const to=this.measureText(prefix).width*ratio;
                    const corners=[[x+from,y-ascent],[x+to,y-ascent],[x+from,y+descent],[x+to,y+descent]].map(p=>m.transformPoint(new DOMPoint(...p)));
                    const xs=corners.map(p=>p.x),ys=corners.map(p=>p.y);
                    glyphs.push({i:offset,n:ch.length,x:Math.min(...xs),y:Math.min(...ys),w:Math.max(...xs)-Math.min(...xs),h:Math.max(...ys)-Math.min(...ys)});
                    offset+=ch.length;
                  }
                  list.push({text,glyphs});
                  canvasText.set(this.canvas,list);
                }
              }
              return result;
            };
          }
          window.addEventListener('DOMContentLoaded', () => {
            const fields=document.querySelectorAll('input,select,textarea');
            for(const s of saved.inputs || []) { const el=fields[s.i]; if(!el) continue;
              el.value=s.value; if('checked' in el) el.checked=!!s.checked;
              el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));
            }
          }, {once:true});
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: CGFloat(component.height ?? 360)), configuration: configuration)
        web.uiDelegate = ZeCustomVisualizationUIDelegate.shared
        web.overrideUserInterfaceStyle = dark ? .dark : .light
        web.isOpaque = false
        web.backgroundColor = .secondarySystemGroupedBackground
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.accessibilityLabel = component.fallbackText
        return web
    }
    static func html(_ component: ZeVisualizationComponent) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>:root{color-scheme:light dark}*{box-sizing:border-box}html,body{margin:0;width:100%;font:15px -apple-system,sans-serif}body{padding:8px;overflow-wrap:anywhere}svg,canvas{max-width:100%}svg{overflow:visible}button,input,select{font:inherit}*:focus-visible{outline:2px solid #1685fb}</style>
        </head><body>\(component.html ?? "")
        <style>html,body{height:auto!important;min-height:0!important;max-height:none!important;overflow:visible!important}body{margin:0!important}body>svg{display:block}</style></body></html>
        """
    }
    // Measure the natural document, not scrollHeight's viewport-sized minimum.
    // One bounded DOM walk per capture; no observers/timers running in chat cells.
    static let measureScript = """
    (() => {
      // Recover text at SVG edges without clipping the last tick or footnote.
      for(const svg of Array.from(document.querySelectorAll('svg[viewBox]')).slice(0,32)) {
        try {
          const v=svg.viewBox.baseVal, b=svg.getBBox();
          if(!v.width || !v.height || !b.width || !b.height) continue;
          const left=Math.min(v.x,b.x-2), top=Math.min(v.y,b.y-2);
          const right=Math.max(v.x+v.width,b.x+b.width+2), bottom=Math.max(v.y+v.height,b.y+b.height+2);
          if(right-left<=v.width*2 && bottom-top<=v.height*2)
            svg.setAttribute('viewBox',[left,top,right-left,bottom-top].join(' '));
        } catch(_) {}
      }
      const body=document.body, root=body.getBoundingClientRect();
      let bottom=root.bottom+window.scrollY;
      for(const el of Array.from(body.querySelectorAll('*')).slice(0,6000)) {
        if(['SCRIPT','STYLE','META','LINK'].includes(el.tagName)) continue;
        const r=el.getBoundingClientRect();
        if(r.width && r.height) bottom=Math.max(bottom,r.bottom+window.scrollY);
      }
      return Math.ceil(Math.max(40,bottom+parseFloat(getComputedStyle(body).paddingBottom||0)));
    })()
    """
    static let textLayoutScript = """
    (() => {
      let text='',glyphs=[],visited=0,lastRect=null;
      const add=(value,rects)=>{
        if(!value || text.length+value.length+1>8192 || glyphs.length+rects.length>8192) return;
        const first=rects[0],last=rects[rects.length-1];
        if(lastRect&&first&&Math.abs(lastRect.y+lastRect.h/2-first.y-first.h/2)>Math.min(lastRect.h,first.h)*0.65) text+='\\n';
        const start=text.length;text+=value;
        for(const r of rects) if(r.w>0 && r.h>0) glyphs.push([start+r.i,r.n,r.x,r.y,r.w,r.h]);
        if(last) lastRect=last;
      };
      const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
      while(walker.nextNode() && ++visited<=6000 && glyphs.length<8192) {
        const node=walker.currentNode, el=node.parentElement;
        if(!el || el.closest('script,style,noscript,template,[aria-hidden="true"]') || !node.textContent.trim()) continue;
        const css=getComputedStyle(el);
        if(css.display==='none'||css.visibility==='hidden'||Number(css.opacity)===0) continue;
        const value=node.textContent,rects=[];let i=0;
        if(text.length+value.length+1>8192) continue;
        for(const ch of value) {
          const range=document.createRange();range.setStart(node,i);range.setEnd(node,i+ch.length);
          const r=range.getBoundingClientRect();
          if(r.width>0 && r.height>0 && r.bottom>0 && r.top<1600)
            rects.push({i,n:ch.length,x:r.x+window.scrollX,y:r.y+window.scrollY,w:r.width,h:r.height});
          i+=ch.length;
        }
        if(rects.length) add(value,rects);
      }
      for(const canvas of Array.from(document.querySelectorAll('canvas')).slice(0,16)) {
        const box=canvas.getBoundingClientRect(),sx=box.width/canvas.width,sy=box.height/canvas.height;
        const css=getComputedStyle(canvas);
        if(!box.width||!box.height||css.display==='none'||css.visibility==='hidden'||Number(css.opacity)===0||canvas.closest('[aria-hidden="true"]')) continue;
        for(const run of (window.__zeCanvasText?.get(canvas)||[])) {
          if(!run.text.trim()) continue;
          const rects=run.glyphs.map(r=>({...r,x:box.x+window.scrollX+r.x*sx,y:box.y+window.scrollY+r.y*sy,w:r.w*sx,h:r.h*sy}));
          add(run.text,rects);
        }
      }
      return {text,glyphs};
    })()
    """
    static func capture(_ web: WKWebView, completion: @escaping (ZeCustomVisualizationSnapshot?) -> Void) {
        web.evaluateJavaScript(measureScript) { [weak web] result, _ in
            guard let web, let number = result as? NSNumber else { completion(nil); return }
            let height = CGFloat(number.doubleValue)
            // Oversized documents remain scrollable in details; avoid huge bitmaps.
            guard height.isFinite, height > 0, height <= 1600 else { completion(nil); return }
#if DEBUG
            recordCapture(web, phase: "beforeNormalization")
#endif
            web.transform = .identity
            // DOM geometry starts at document zero. Window safe-area insets
            // must not shift snapshot pixels away from those captured glyphs.
            web.scrollView.contentInsetAdjustmentBehavior = .never
            web.scrollView.contentInset = .zero
            web.scrollView.scrollIndicatorInsets = .zero
            web.scrollView.setContentOffset(.zero, animated: false)
            web.frame.size = CGSize(width: width, height: height)
            web.setNeedsLayout(); web.layoutIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak web] in
                guard let web, web.superview != nil else { completion(nil); return }
                web.scrollView.setContentOffset(.zero, animated: false)
#if DEBUG
                recordCapture(web, phase: "snapshot")
#endif
                let config = WKSnapshotConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: width, height: height)
                config.snapshotWidth = NSNumber(value: Double(540 / web.traitCollection.displayScale))
                web.evaluateJavaScript(textLayoutScript) { [weak web] payload, _ in
                    guard let web, web.superview != nil else { completion(nil); return }
                    let layout = ZeCustomVisualizationTextLayout(payload: payload)
                    web.takeSnapshot(with: config) { image, _ in
                        completion(image.map { ZeCustomVisualizationSnapshot(image: $0, textLayout: layout) })
                    }
                }
            }
        }
    }
    static func key(_ component: ZeVisualizationComponent, state: String?, dark: Bool) -> String {
        "\(component.hashValue):\(state ?? "{}"): \(dark)"
    }
}

/// Generated content has no permission prompts, popups or blocking JS dialogs.
@MainActor final class ZeCustomVisualizationUIDelegate: NSObject, WKUIDelegate {
    static let shared = ZeCustomVisualizationUIDelegate()
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

/// One preview web process at a time, at most eight queued cards, eight cached
/// images / 8 MiB decoded cost. Cells retain UIImage previews, never web views.
@MainActor final class ZeCustomVisualizationRenderer: NSObject, WKNavigationDelegate {
    static let shared = ZeCustomVisualizationRenderer()
    static let loadingTimeoutNanoseconds: UInt64 = 20_000_000_000
    static let captureTimeoutNanoseconds: UInt64 = 4_000_000_000
    static let maximumRenderSeconds: Double = 24
    private struct Job {
        let component: ZeVisualizationComponent
        let state: String?
        let dark: Bool
        let completion: (ZeCustomVisualizationSnapshot?) -> Void
    }
    private var queue: [Job] = []
    private var current: Job?
    private var web: WKWebView?
    private var timeout: Task<Void, Never>?
    private var cache: [String: ZeCustomVisualizationSnapshot] = [:]
    private var order: [String] = []
    private var generation = 0
    var cacheCount: Int { cache.count }
    func cached(_ component: ZeVisualizationComponent, state: String?, dark: Bool) -> UIImage? {
        cache[ZeCustomVisualizationRuntime.key(component, state: state, dark: dark)]?.image
    }
    func store(_ snapshot: ZeCustomVisualizationSnapshot, component: ZeVisualizationComponent, state: String?, dark: Bool) {
        let key = ZeCustomVisualizationRuntime.key(component, state: state, dark: dark)
        cache[key] = snapshot; order.removeAll { $0 == key }; order.append(key)
        func bytes() -> Int { cache.values.reduce(0) { $0 + $1.byteCost } }
        while order.count > 8 || bytes() > 8 * 1024 * 1024 {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
    func render(component: ZeVisualizationComponent, state: String?, dark: Bool, completion: @escaping (UIImage?) -> Void) {
        renderSnapshot(component: component, state: state, dark: dark) { completion($0?.image) }
    }
    func renderSnapshot(component: ZeVisualizationComponent, state: String?, dark: Bool, completion: @escaping (ZeCustomVisualizationSnapshot?) -> Void) {
        if let snapshot = cache[ZeCustomVisualizationRuntime.key(component, state: state, dark: dark)] { completion(snapshot); return }
        guard queue.count < 8 else { completion(nil); return }
        queue.append(Job(component: component, state: state, dark: dark, completion: completion))
        startNext()
    }
    func clear() {
        generation += 1
        timeout?.cancel(); timeout = nil
        web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
        let pending = queue; queue.removeAll()
        let active = current; current = nil
        cache.removeAll(); order.removeAll()
        active?.completion(nil); pending.forEach { $0.completion(nil) }
    }
    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst(); current = job
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { finish(nil); return }
        let view = ZeCustomVisualizationRuntime.webView(component: job.component, state: job.state, dark: job.dark)
        web = view; view.navigationDelegate = self
        view.frame.origin = CGPoint(x: -20000, y: 0)
        window.addSubview(view)
        armTimeout(Self.loadingTimeoutNanoseconds)
        view.loadHTMLString(ZeCustomVisualizationRuntime.html(job.component), baseURL: nil)
    }
    private func armTimeout(_ nanoseconds: UInt64) {
        timeout?.cancel()
        let token = generation
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, token == self.generation else { return }
            self.finish(nil)
        }
    }
    private func finish(_ snapshot: ZeCustomVisualizationSnapshot?) {
        guard let job = current else { return }
        generation += 1
        timeout?.cancel(); timeout = nil
        web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
        current = nil
        if let snapshot { store(snapshot, component: job.component, state: job.state, dark: job.dark) }
        job.completion(snapshot)
        startNext()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard web === webView else { return }
        // Cold WebKit process launch can exceed the capture budget. Once the
        // document loads, bound measurement/snapshot separately so an actual
        // script or snapshot stall still releases the queue promptly.
        armTimeout(Self.captureTimeoutNanoseconds)
        let token = generation
        Task { [weak self, weak webView] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, let webView, self.web === webView, token == self.generation else { return }
            ZeCustomVisualizationRuntime.capture(webView) { [weak self, weak webView] image in
                guard let self, self.web === webView, token == self.generation else { return }
                self.finish(image)
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if web === webView { finish(nil) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if web === webView { finish(nil) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if web === webView { finish(nil) } }
}

private final class ZeCustomVisualizationSelectionRect: UITextSelectionRect {
    let region: CGRect
    let starts: Bool
    let ends: Bool
    init(_ rect: CGRect, starts: Bool, ends: Bool) { region = rect; self.starts = starts; self.ends = ends }
    override var rect: CGRect { region }
    override var writingDirection: NSWritingDirection { .natural }
    override var containsStart: Bool { starts }
    override var containsEnd: Bool { ends }
    override var isVertical: Bool { false }
}

/// Created only after a selection gesture. UITextView owns the native selection
/// handles and Copy menu; geometry comes from the captured document, not a
/// reflowed transcription. No text is painted over the original image.
final class ZeCustomVisualizationSelectionTextView: UITextView {
    let capturedLayout: ZeCustomVisualizationTextLayout
    var onDismiss: (() -> Void)?
    var coordinateScale: CGFloat { max(0.001, bounds.width / 360) }
    init(layout: ZeCustomVisualizationTextLayout) {
        capturedLayout = layout
        let storage = NSTextStorage(), manager = NSLayoutManager(), container = NSTextContainer()
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = true; isScrollEnabled = false
        backgroundColor = .clear; textColor = .clear; tintColor = .systemBlue
        textContainerInset = .zero; textContainer.lineFragmentPadding = 0
        text = layout.text; accessibilityIdentifier = "ze.visualization.custom.selection"
        contentInsetAdjustmentBehavior = .never
    }
    required init?(coder: NSCoder) { return nil }
    private func rect(_ glyph: ZeCustomVisualizationTextLayout.Glyph) -> CGRect {
        glyph.rect.applying(CGAffineTransform(scaleX: coordinateScale, y: coordinateScale))
    }
    private func nearest(_ point: CGPoint) -> ZeCustomVisualizationTextLayout.Glyph? {
        capturedLayout.glyphs.min { a, b in
            func distance(_ glyph: ZeCustomVisualizationTextLayout.Glyph) -> CGFloat {
                let r = rect(glyph)
                let dx = max(0, max(r.minX - point.x, point.x - r.maxX))
                let dy = max(0, max(r.minY - point.y, point.y - r.maxY))
                return dx * dx + dy * dy * 4
            }
            return distance(a) < distance(b)
        }
    }
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let glyph = nearest(point) else { return super.closestPosition(to: point) }
        let offset = glyph.range.location + (point.x > rect(glyph).midX ? glyph.range.length : 0)
        return position(from: beginningOfDocument, offset: offset)
    }
    override func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        guard let found = closestPosition(to: point) else { return nil }
        let offset = self.offset(from: beginningOfDocument, to: found)
        return position(from: beginningOfDocument, offset: min(max(offset,
            self.offset(from: beginningOfDocument, to: range.start)), self.offset(from: beginningOfDocument, to: range.end)))
    }
    override func characterRange(at point: CGPoint) -> UITextRange? {
        guard let glyph = nearest(point), let start = position(from: beginningOfDocument, offset: glyph.range.location),
              let end = position(from: start, offset: glyph.range.length) else { return nil }
        return textRange(from: start, to: end)
    }
    override func caretRect(for position: UITextPosition) -> CGRect {
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard let glyph = capturedLayout.glyphs.first(where: { NSMaxRange($0.range) > offset }) ?? capturedLayout.glyphs.last else { return .zero }
        let r = rect(glyph)
        return CGRect(x: offset >= NSMaxRange(glyph.range) ? r.maxX : r.minX, y: r.minY, width: 2, height: r.height)
    }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        let start = offset(from: beginningOfDocument, to: range.start), end = offset(from: beginningOfDocument, to: range.end)
        let selected = NSRange(location: start, length: max(0, end - start))
        var rows: [(rect: CGRect, start: Int, end: Int)] = []
        for glyph in capturedLayout.glyphs where NSIntersectionRange(selected, glyph.range).length > 0 {
            let r = rect(glyph)
            if let last = rows.last, abs(last.rect.midY - r.midY) < min(last.rect.height, r.height) * 0.4,
               r.minX >= last.rect.minX, r.minX - last.rect.maxX < 16 * coordinateScale {
                rows[rows.count - 1] = (last.rect.union(r), last.start, NSMaxRange(glyph.range))
            } else { rows.append((r, glyph.range.location, NSMaxRange(glyph.range))) }
        }
        return rows.map { ZeCustomVisualizationSelectionRect($0.rect, starts: $0.start <= start && $0.end > start,
                                                              ends: $0.start < end && $0.end >= end) }
    }
    override func firstRect(for range: UITextRange) -> CGRect { selectionRects(for: range).first?.rect ?? caretRect(for: range.start) }
    override func scrollRangeToVisible(_ range: NSRange) {}
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {}
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if ["paste:", "cut:", "delete:"].contains(NSStringFromSelector(action)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onDismiss?() }
        return result
    }
    func selectWord(at point: CGPoint) {
        guard let position = closestPosition(to: point) else { return }
        if let word = tokenizer.rangeEnclosingPosition(position, with: .word,
            inDirection: UITextDirection(rawValue: UITextStorageDirection.forward.rawValue)) {
            selectedTextRange = word
        } else { selectedTextRange = characterRange(at: point) }
        if let selectedTextRange { UIMenuController.shared.showMenu(from: self, rect: firstRect(for: selectedTextRange)) }
    }
}

#if DEBUG
/// Observes the recognizer arbitration without changing UIKit's decisions.
final class ZeCustomVisualizationDiagnosticHold: UILongPressGestureRecognizer {
    var record: ((String) -> Void)?
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        let decision = super.canPrevent(preventedGestureRecognizer)
        record?("canPrevent \(type(of: preventedGestureRecognizer)) state=\(preventedGestureRecognizer.state.rawValue) view=\(String(describing: preventedGestureRecognizer.view)) decision=\(decision)")
        return decision
    }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        let decision = super.canBePrevented(by: preventingGestureRecognizer)
        record?("canBePreventedBy \(type(of: preventingGestureRecognizer)) state=\(preventingGestureRecognizer.state.rawValue) view=\(String(describing: preventingGestureRecognizer.view)) decision=\(decision)")
        return decision
    }
    override func reset() {
        record?("reset state=\(state.rawValue)")
        super.reset()
    }
}
#endif

final class ZeCustomVisualizationPreview: UIView, UIGestureRecognizerDelegate {
#if DEBUG
    private(set) var verificationGestureEvents: [String] = []
    private func recordGesture(_ event: String) {
        verificationGestureEvents.append(event)
        if verificationGestureEvents.count > 32 { verificationGestureEvents.removeFirst() }
    }
#endif
    let component: ZeVisualizationComponent
    private let interaction: ZeVisualizationInteractionState
    private let picture = UIImageView()
    var renderedImage: UIImage? { picture.image }
    private let summary = ZeVisualizationSelectableLabel()
    private(set) var textLayout = ZeCustomVisualizationTextLayout.empty
    private(set) var activeSelectionView: ZeCustomVisualizationSelectionTextView?
    private var dismissTap: UITapGestureRecognizer?
    private var selectionGestures: [UIGestureRecognizer] = []
    private var requestedKey: String?
    private(set) var isPending = false
    init(component: ZeVisualizationComponent, interaction: ZeVisualizationInteractionState) {
        self.component = component; self.interaction = interaction
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFit
        accessibilityIdentifier = "ze.visualization.custom.preview"
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        summary.text = component.fallbackText; summary.numberOfLines = 0; summary.font = .systemFont(ofSize: 14); summary.textColor = .secondaryLabel
        addSubview(picture); addSubview(summary)
        accessibilityLabel = component.fallbackText
#if DEBUG
        let press = ZeCustomVisualizationDiagnosticHold(target: self, action: #selector(selectByPress(_:)))
        press.record = { [weak self] in self?.recordGesture($0) }
#else
        let press = UILongPressGestureRecognizer(target: self, action: #selector(selectByPress(_:)))
#endif
        press.minimumPressDuration = 0.4; press.delegate = self; addGestureRecognizer(press)
        let double = UITapGestureRecognizer(target: self, action: #selector(selectByTap(_:)))
        double.numberOfTapsRequired = 2; double.delegate = self; addGestureRecognizer(double)
        selectionGestures = [press, double]
    }
    required init?(coder: NSCoder) { return nil }
    var imageDisplayRect: CGRect {
        guard let image = picture.image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func layoutSubviews() {
        super.layoutSubviews(); picture.frame = bounds; summary.frame = bounds.insetBy(dx: 12, dy: 12)
        activeSelectionView?.frame = imageDisplayRect
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { prepare() } else { endTextSelection() }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) { super.traitCollectionDidChange(previousTraitCollection); if window != nil { prepare() } }
    func prepare() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let state = interaction.value.customStateJSON
        let key = ZeCustomVisualizationRuntime.key(component, state: state, dark: dark)
        guard requestedKey != key else { return }
        requestedKey = key; isPending = true
        ZeCustomVisualizationRenderer.shared.renderSnapshot(component: component, state: state, dark: dark) { [weak self] snapshot in
            guard let self, self.requestedKey == key else { return }
            self.isPending = false
            self.endTextSelection()
            self.picture.image = snapshot?.image; self.summary.isHidden = snapshot != nil
            self.textLayout = snapshot?.textLayout ?? .empty
            if let snapshot { self.updateHeight(snapshot.image) }
            if snapshot == nil { self.requestedKey = nil }
        }
    }
    func apply(_ snapshot: ZeCustomVisualizationSnapshot) {
        let dark = traitCollection.userInterfaceStyle == .dark
        endTextSelection()
        ZeCustomVisualizationRenderer.shared.store(snapshot, component: component, state: interaction.value.customStateJSON, dark: dark)
        requestedKey = ZeCustomVisualizationRuntime.key(component, state: interaction.value.customStateJSON, dark: dark)
        picture.image = snapshot.image; textLayout = snapshot.textLayout; summary.isHidden = true; isPending = false
        updateHeight(snapshot.image)
    }
    func showSummary() {
        endTextSelection(); textLayout = .empty
        picture.image = nil; summary.isHidden = false; isPending = false
        requestedKey = ZeCustomVisualizationRuntime.key(component, state: interaction.value.customStateJSON,
                                                       dark: traitCollection.userInterfaceStyle == .dark)
    }
    @objc private func selectByPress(_ sender: UILongPressGestureRecognizer) {
#if DEBUG
        recordGesture("press state=\(sender.state.rawValue) point=\(sender.location(in: self))")
#endif
        if sender.state == .began { beginTextSelection(at: sender.location(in: self)) }
    }
    @objc private func selectByTap(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended { beginTextSelection(at: sender.location(in: self)) }
    }
    func beginTextSelection(at point: CGPoint) {
#if DEBUG
        recordGesture("begin point=\(point) active=\(activeSelectionView != nil) glyphs=\(textLayout.glyphs.count)")
#endif
        guard activeSelectionView == nil, !textLayout.glyphs.isEmpty else { return }
        let imageRect = imageDisplayRect
        guard imageRect.contains(point) else { return }
        let text = ZeCustomVisualizationSelectionTextView(layout: textLayout)
        text.frame = imageRect
        text.onDismiss = { [weak self] in self?.endTextSelection() }
        isAccessibilityElement = false
        activeSelectionView = text; addSubview(text)
        text.layoutIfNeeded()
        let selectedPoint = CGPoint(x: point.x - imageRect.minX, y: point.y - imageRect.minY)
        // Match native label selection: let the long-press touch and TextKit
        // layout settle before transferring the responder to the new text view.
        DispatchQueue.main.async { [weak self, weak text] in
            guard let self, let text, self.activeSelectionView === text, text.window != nil else { return }
            var offsets: [(UIScrollView, CGPoint)] = []
            var ancestor = self.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { offsets.append((scroll, scroll.contentOffset)) }
                ancestor = view.superview
            }
            text.becomeFirstResponder(); text.selectWord(at: selectedPoint)
#if DEBUG
            self.recordGesture("focused=\(text.isFirstResponder) range=\(text.selectedRange)")
#endif
            // Focusing a nested read-only text view may try to scroll its parent
            // to its synthetic text layout; the captured card stays at its pixels.
            for (scroll, offset) in offsets where scroll.contentOffset != offset { scroll.setContentOffset(offset, animated: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak text] in
                guard let self, let text, self.activeSelectionView === text, let window = text.window else { return }
                let tap = UITapGestureRecognizer(target: self, action: #selector(self.dismissSelection(_:)))
                tap.cancelsTouchesInView = false; tap.delegate = self
                window.addGestureRecognizer(tap); self.dismissTap = tap
            }
        }
    }
    func endTextSelection() {
#if DEBUG
        if activeSelectionView != nil { recordGesture("end active selection mounted=\(window != nil)") }
#endif
        let active = activeSelectionView; activeSelectionView = nil
        active?.onDismiss = nil; active?.resignFirstResponder(); active?.removeFromSuperview()
        isAccessibilityElement = true
        if let tap = dismissTap { tap.view?.removeGestureRecognizer(tap) }; dismissTap = nil
    }
    @objc private func dismissSelection(_ gesture: UITapGestureRecognizer) { activeSelectionView?.resignFirstResponder() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
#if DEBUG
        if selectionGestures.contains(where: { $0 === gestureRecognizer }) {
            recordGesture("receive \(type(of: gestureRecognizer)) touch=\(touch.location(in: self)) view=\(String(describing: touch.view))")
        }
#endif
        guard gestureRecognizer === dismissTap, let activeSelectionView, let touched = touch.view else { return true }
        if touched === activeSelectionView || touched.isDescendant(of: activeSelectionView) { return false }
        var ancestor: UIView? = touched
        while let view = ancestor {
            let name = String(describing: type(of: view))
            if name.contains("Menu") || name.contains("Callout") { return false }
            ancestor = view.superview
        }
        return true
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let allowed = !selectionGestures.contains(where: { $0 === gestureRecognizer }) || activeSelectionView == nil
#if DEBUG
        recordGesture("shouldBegin \(type(of: gestureRecognizer)) allowed=\(allowed)")
#endif
        return allowed
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === dismissTap || otherGestureRecognizer === dismissTap
    }
    private func updateHeight(_ image: UIImage) {
        guard image.size.width > 0 else { return }
        let height = Double(image.size.height / image.size.width * 360)
        guard abs((interaction.value.customContentHeight ?? 0) - height) > 0.5 else { return }
        interaction.value.customContentHeight = height
        interaction.onLayoutChange?()
    }
}

/// Only the expanded card owns an interactive WKWebView. Closing waits for state
/// and screenshot together so the inline preview and a subsequent share agree.
final class ZeCustomVisualizationController: UIViewController, WKNavigationDelegate, UIAdaptivePresentationControllerDelegate {
    let component: ZeVisualizationComponent
    private let interaction: ZeVisualizationInteractionState
    private weak var preview: ZeCustomVisualizationPreview?
    private var web: WKWebView?
    private var deadline: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var closing = false
    init(component: ZeVisualizationComponent, interaction: ZeVisualizationInteractionState, preview: ZeCustomVisualizationPreview?) {
        self.component = component; self.interaction = interaction; self.preview = preview
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); title = component.title
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        let web = ZeCustomVisualizationRuntime.webView(component: component, state: interaction.value.customStateJSON, dark: traitCollection.userInterfaceStyle == .dark)
        self.web = web; web.navigationDelegate = self; web.scrollView.isScrollEnabled = true; view.addSubview(web)
        web.loadHTMLString(ZeCustomVisualizationRuntime.html(component), baseURL: nil)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didReceiveMemoryWarningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.releaseWeb(); self?.dismiss(animated: false) }
            })
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseWeb(); self?.showFallback()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let web, !closing else { return }
        let scale = min(1.6, max(0.5, (view.bounds.width - 32) / ZeCustomVisualizationRuntime.width))
        web.transform = .identity
        let available = max(120, view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom - 32)
        web.frame = CGRect(x: 0, y: 0, width: ZeCustomVisualizationRuntime.width, height: available / scale)
        web.transform = CGAffineTransform(scaleX: scale, y: scale)
        web.center = CGPoint(x: view.bounds.midX, y: view.safeAreaInsets.top + 16 + web.bounds.height * scale / 2)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.isModalInPresentation = true
        navigationController?.presentationController?.delegate = self
    }
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { false }
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { done() }
    private func showFallback() {
        let label = UILabel(frame: view.bounds.insetBy(dx: 24, dy: 100)); label.numberOfLines = 0
        label.text = component.fallbackText; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
    }
    private func releaseWeb() { deadline?.cancel(); deadline = nil; web?.stopLoading(); web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil }
    @objc func done() {
        guard !closing else { return }; closing = true
        guard let web else { dismiss(animated: true); return }
        navigationItem.leftBarButtonItem?.isEnabled = false
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.releaseWeb(); self?.dismiss(animated: true)
        }
        web.evaluateJavaScript("window.__zeCapture()") { [weak self, weak web] result, _ in
            guard let self, let web, self.web === web else { return }
            guard let state = result as? String, state.utf8.count <= 32768,
                  (try? JSONSerialization.jsonObject(with: Data(state.utf8))) != nil else {
                self.releaseWeb(); self.dismiss(animated: true); return
            }
            ZeCustomVisualizationRuntime.capture(web) { [weak self, weak web] image in
                guard let self, self.web === web else { return }
                self.interaction.value.customStateJSON = state
                if let image { self.preview?.apply(image) }
                else { self.preview?.showSummary() }
                self.releaseWeb(); self.dismiss(animated: true)
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        deadline?.cancel(); deadline = nil
        webView.evaluateJavaScript(ZeCustomVisualizationRuntime.measureScript, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { releaseWeb(); showFallback() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); releaseWeb() }
    deinit { deadline?.cancel(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
