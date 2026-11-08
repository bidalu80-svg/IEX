import UIKit
import SwiftUI

// Only the application's cache-clear boundary is stubbed. The component model,
// custom preview, geometry-backed selection view and gestures are production.
@MainActor enum SelectableMarkdownView {
    static func clearVisualizationCaches() {}
}

@main struct SelectionDiagnosticHarness {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                          NSStringFromClass(SelectionDiagnosticAppDelegate.self))
    }
}

@MainActor final class SelectionDiagnosticAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var diagnostic: SelectionDiagnosticController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let flag = arguments.firstIndex(of: "--case")
        let name = flag.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "plain-long"
        let controller = SelectionDiagnosticController(caseName: name)
        diagnostic = controller
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return true
    }
}

/// This case isolates only the production Markdown text-view's custom-region
/// policy. It deliberately does not claim to mount the full Markdown renderer.
@MainActor final class SelectionDiagnosticGuardedTextView: UITextView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer !== panGestureRecognizer {
            let point = gestureRecognizer.location(in: self)
            var touched = hitTest(point, with: nil)
            while let view = touched, view !== self {
                if view is ZeCustomVisualizationPreview { return false }
                touched = view.superview
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// Copies only the production tracker/inline-code recognizer construction and
/// delegate decisions relevant to an embedded custom attachment. The real
/// Markdown parser, collection auto-scroll and attachment layout are outside
/// this focused policy fixture and are not simulated here.
@MainActor final class SelectionDiagnosticTrackedTextView: UITextView, UIGestureRecognizerDelegate {
    private weak var selectionDragTracker: UILongPressGestureRecognizer?
    private weak var inlineCodeTapGesture: UITapGestureRecognizer?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        let codeTap = UITapGestureRecognizer(target: self, action: #selector(observedAction(_:)))
        codeTap.delegate = self
        addGestureRecognizer(codeTap)
        inlineCodeTapGesture = codeTap
        let tracker = UILongPressGestureRecognizer(target: self, action: #selector(observedAction(_:)))
        tracker.minimumPressDuration = 0
        tracker.cancelsTouchesInView = false
        tracker.delaysTouchesBegan = false
        tracker.delaysTouchesEnded = false
        tracker.delegate = self
        addGestureRecognizer(tracker)
        selectionDragTracker = tracker
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func observedAction(_ gesture: UIGestureRecognizer) {}

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer !== panGestureRecognizer && gestureRecognizer !== selectionDragTracker {
            let point = gestureRecognizer.location(in: self)
            var touched = hitTest(point, with: nil)
            while let view = touched, view !== self {
                if view is ZeCustomVisualizationPreview { return false }
                touched = view.superview
            }
        }
        if gestureRecognizer === inlineCodeTapGesture {
            if let selection = selectedTextRange, !selection.isEmpty { return false }
            let point = gestureRecognizer.location(in: self)
            // The only attachment in this fixture is the custom preview.
            if subviews.contains(where: { $0 is ZeCustomVisualizationPreview && $0.frame.contains(point) }) { return false }
            return false // no inline-code or blank-area handler in this fixture
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === selectionDragTracker || otherGestureRecognizer === selectionDragTracker { return true }
        if gestureRecognizer === inlineCodeTapGesture { return otherGestureRecognizer is UITapGestureRecognizer }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === inlineCodeTapGesture, otherGestureRecognizer is UILongPressGestureRecognizer {
            if otherGestureRecognizer === selectionDragTracker { return false }
            return true
        }
        return false
    }
}

@MainActor private struct SelectionDiagnosticContainer: UIViewRepresentable {
    let content: UIView
    func makeUIView(context: Context) -> UIView { content }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor final class SelectionDiagnosticController: UIViewController {
    private let caseName: String
    private var preview: ZeCustomVisualizationPreview?
    private var native: UITextView?
    private var observed: [UIGestureRecognizer] = []
    private var events: [[String: Any]] = []
    private var samples: [[String: Any]] = []
    private var started = false
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(caseName: String) { self.caseName = caseName; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel(frame: CGRect(x: 20, y: 74, width: 350, height: 40))
        title.text = caseName
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        view.addSubview(title)

        let region = CGRect(x: 20, y: 140, width: 360, height: 220)
        if caseName.hasPrefix("native-") {
            let text = UITextView(usingTextLayoutManager: false)
            text.frame = region
            text.isEditable = false
            text.isSelectable = true
            text.isScrollEnabled = false
            text.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            text.font = .systemFont(ofSize: 20)
            text.text = "Selectable custom text\nLine two: SVG geometry\nSOURCE_END"
            text.accessibilityIdentifier = "ze.selection.native"
            view.addSubview(text)
            native = text
            return
        }

        let parent: UIView
        let tracked = caseName.hasPrefix("tracked-") || caseName.hasPrefix("combined-")
        let swiftUIScroll = caseName.hasPrefix("swiftui-") || caseName.hasPrefix("combined-")
        let dragDisabled = caseName.hasPrefix("nodrag-") || caseName.hasPrefix("combined-")
        if caseName.hasPrefix("textview-") || caseName.hasPrefix("guarded-") || tracked || swiftUIScroll || dragDisabled {
            let text: UITextView
            if tracked { text = SelectionDiagnosticTrackedTextView(usingTextLayoutManager: false) }
            else if caseName.hasPrefix("guarded-") { text = SelectionDiagnosticGuardedTextView(usingTextLayoutManager: false) }
            else { text = UITextView(usingTextLayoutManager: false) }
            text.isEditable = false
            text.isSelectable = true
            text.isScrollEnabled = false
            text.contentInsetAdjustmentBehavior = .never
            text.textContainerInset = .zero
            text.textContainer.lineFragmentPadding = 0
            if dragDisabled { text.textDragInteraction?.isEnabled = false }
            let attachment = NSTextAttachment()
            attachment.bounds = CGRect(x: 0, y: 0, width: 360, height: 180)
            text.attributedText = NSAttributedString(attachment: attachment)
            parent = text
        } else if caseName.hasPrefix("scroll-") {
            let scroll = UIScrollView()
            scroll.contentSize = CGSize(width: 360, height: 800)
            parent = scroll
        } else { parent = UIView() }
        parent.frame = region
        parent.accessibilityIdentifier = "ze.selection.container"
        if !swiftUIScroll { view.addSubview(parent) }

        do {
            let raw = #"{"schemaVersion":1,"id":"selection-probe","title":"Selection probe","components":[{"id":"custom","type":"custom","height":180,"html":"<p>Selection probe</p>","fallbackText":"Selection probe"}]}"#
            let component = try ZeVisualizationParser.parse(raw).get().components[0]
            let state = ZeVisualizationInteractionState()
            let snapshot = Self.makeSnapshot()
            // Seed before mounting so this test never creates a WKWebView.
            ZeCustomVisualizationRenderer.shared.store(snapshot, component: component, state: nil, dark: false)
            let preview = ZeCustomVisualizationPreview(component: component, interaction: state)
            preview.frame = CGRect(x: 0, y: 0, width: 360, height: 180)
            preview.apply(snapshot)
            parent.addSubview(preview)
            self.preview = preview
            if swiftUIScroll {
                let host = UIHostingController(rootView: ScrollView {
                    SelectionDiagnosticContainer(content: parent).frame(width: 360, height: 220)
                    Color.clear.frame(height: 700)
                })
                addChild(host)
                host.view.frame = CGRect(x: 20, y: 140, width: 360, height: 500)
                view.addSubview(host.view)
                host.didMove(toParent: self)
            }
        } catch {
            events.append(["event": "setupError", "error": error.localizedDescription])
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        observeGestureChain()
        sample("ready")
        for delay in [0.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.observeGestureChain()
                self?.sample("sample-\(delay)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish() }
    }

    private static func makeSnapshot() -> ZeCustomVisualizationSnapshot {
        let lines = ["Selectable custom text", "Line two: SVG geometry", "SOURCE_END"]
        let font = UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let text = lines.joined(separator: "\n")
        var glyphs: [ZeCustomVisualizationTextLayout.Glyph] = []
        var offset = 0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 180), format: format).image { context in
            UIColor(red: 0.07, green: 0.14, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 180))
            for (row, line) in lines.enumerated() {
                let y = CGFloat(16 + row * 48)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                (line as NSString).draw(at: CGPoint(x: 16, y: y), withAttributes: attributes)
                var prefix = ""
                for character in line {
                    let x = (prefix as NSString).size(withAttributes: [.font: font]).width
                    let value = String(character)
                    prefix += value
                    let end = (prefix as NSString).size(withAttributes: [.font: font]).width
                    glyphs.append(.init(range: NSRange(location: offset, length: value.utf16.count),
                        rect: CGRect(x: 16 + x, y: y, width: max(1, end - x), height: font.lineHeight)))
                    offset += value.utf16.count
                }
                offset += 1
            }
        }
        return ZeCustomVisualizationSnapshot(image: image,
            textLayout: ZeCustomVisualizationTextLayout(text: text, glyphs: glyphs))
    }

    private func observeGestureChain() {
        var current: UIView? = (preview as UIView?) ?? native
        while let view = current {
            for gesture in view.gestureRecognizers ?? [] where !observed.contains(where: { $0 === gesture }) {
                gesture.addTarget(self, action: #selector(gestureChanged(_:)))
                observed.append(gesture)
            }
            current = view.superview
        }
    }

    @objc private func gestureChanged(_ gesture: UIGestureRecognizer) {
        var value = describe(gesture)
        value["event"] = "targetAction"
        value["time"] = ProcessInfo.processInfo.systemUptime - startedAt
        events.append(value)
    }

    private func describe(_ gesture: UIGestureRecognizer) -> [String: Any] {
        ["type": String(describing: type(of: gesture)), "state": gesture.state.rawValue,
         "name": gesture.name ?? "", "view": String(describing: gesture.view),
         "delegate": String(describing: gesture.delegate), "enabled": gesture.isEnabled,
         "cancelsTouches": gesture.cancelsTouchesInView,
         "delaysBegan": gesture.delaysTouchesBegan, "delaysEnded": gesture.delaysTouchesEnded]
    }

    private func sample(_ label: String) {
        let selected = (preview?.activeSelectionView as UITextView?) ?? native
        samples.append(["label": label, "time": ProcessInfo.processInfo.systemUptime - startedAt,
            "gestures": observed.map(describe), "hasSelectionView": preview?.activeSelectionView != nil,
            "firstResponder": selected?.isFirstResponder ?? false,
            "selectedRange": selected.map { "\($0.selectedRange)" } ?? "none"])
    }

    private func finish() {
        observeGestureChain()
        sample("final")
        let selected = (preview?.activeSelectionView as UITextView?) ?? native
        let range = selected?.selectedRange ?? NSRange(location: 0, length: 0)
        let text = (selected?.text ?? "") as NSString
        let selectedText = range.location <= text.length && range.length <= text.length - range.location
            ? text.substring(with: range) : ""
        let target: UIView? = (preview as UIView?) ?? native
        let point = target?.convert(CGPoint(x: 28, y: 28), to: view.window)
        let result: [String: Any] = ["case": caseName,
            "success": selected?.isFirstResponder == true && range.length > 0,
            "firstResponder": selected?.isFirstResponder ?? false,
            "selectedText": selectedText, "selectedRange": "\(range)",
            "gestureEvents": preview?.verificationGestureEvents ?? [],
            "targetActions": events, "samples": samples,
            "targetFrame": target.map { NSCoder.string(for: $0.frame) } ?? "missing",
            "hitView": point.map { String(describing: view.window?.hitTest($0, with: nil)) } ?? "missing",
            "systemVersion": UIDevice.current.systemVersion]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stem = directory.appendingPathComponent("selection-diagnostic-\(caseName)")
        do {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: stem.appendingPathExtension("json"))
            let shot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            try shot.pngData()?.write(to: stem.appendingPathExtension("png"))
            let recorded = UILabel(frame: CGRect(x: 20, y: 400, width: 350, height: 40))
            recorded.text = caseName
            recorded.accessibilityIdentifier = "ze.selection.recorded"
            view.addSubview(recorded)
        } catch { NSLog("SelectionDiagnostic write failure: %@", error.localizedDescription) }
    }
}
