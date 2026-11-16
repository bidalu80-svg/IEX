import Foundation
import SwiftUI
import UIKit

/// UIKit moves the composer as a separate view, so SwiftUI never has to
/// interpolate its bottom alignment while the conversation changes height.
struct ChatKeyboardViewport: UIViewControllerRepresentable {
    let content: AnyView
    let composer: AnyView
    var avoidsKeyboard: Bool = true
    /// Screen-space Y where the header dissolve completes (0 = no dissolve).
    /// The mask lives HERE, on the conversation's own container: the earlier
    /// nav-bar-side version masked whatever view controller happened to be
    /// on top of the nav stack, so on device it dissolved the model picker's
    /// top instead of the conversation (and the flat CI harness, where the
    /// two coincide, stayed green). Device-verified 2026-11-15.
    var fadeCompleteY: CGFloat = 0
    /// Production uses the attached window's status-bar safe area, not a
    /// navigation-bar frame reported through a different coordinate space.
    var usesWindowHeaderFade: Bool = true

    func makeUIViewController(context: Context) -> ChatKeyboardViewportController {
        ChatKeyboardViewportController(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard,
            fadeCompleteY: fadeCompleteY,
            usesWindowHeaderFade: usesWindowHeaderFade)
    }

    func updateUIViewController(_ controller: ChatKeyboardViewportController, context: Context) {
        controller.update(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard,
            fadeCompleteY: fadeCompleteY,
            usesWindowHeaderFade: usesWindowHeaderFade)
    }
}

final class ChatKeyboardViewportController: UIViewController {
    private let host: UIHostingController<AnyView>
    private let composerHost: UIHostingController<AnyView>
    private var avoidsKeyboard: Bool
    private var keyboardBottom: NSLayoutConstraint!
    private var restingBottom: NSLayoutConstraint!
    private var composerKeyboardBottom: NSLayoutConstraint!
    private var composerRestingBottom: NSLayoutConstraint!
    private let conversationContainer = ChatConversationFadeView()
    /// True from the first keyboard will-change until the show/hide animation
    /// has settled. MessageListLayout uses it to keep serving its last
    /// same-width measurements instead of re-entering SwiftUI/TextKit for
    /// every bounds-change pass UIKit runs while the list height follows the
    /// keyboard.
    private var isKeyboardTransitioning = false
    private var keyboardTransitionEndWork: DispatchWorkItem?
    private static let keyboardTransitionSettleDelay: TimeInterval = 0.12

    init(content: AnyView, composer: AnyView, avoidsKeyboard: Bool, fadeCompleteY: CGFloat = 0,
         usesWindowHeaderFade: Bool = false) {
        self.host = UIHostingController(rootView: Self.root(content))
        self.composerHost = UIHostingController(rootView: Self.composerRoot(composer))
        self.avoidsKeyboard = avoidsKeyboard
        super.init(nibName: nil, bundle: nil)
        conversationContainer.configure(completeY: fadeCompleteY, usesWindowSafeArea: usesWindowHeaderFade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private static func root(_ content: AnyView) -> AnyView {
        AnyView(content.ignoresSafeArea(.keyboard, edges: .bottom))
    }

    private static func composerRoot(_ content: AnyView) -> AnyView {
        AnyView(content.fixedSize(horizontal: false, vertical: true)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .ignoresSafeArea(.keyboard, edges: .bottom))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        conversationContainer.translatesAutoresizingMaskIntoConstraints = false
        conversationContainer.backgroundColor = .clear
        view.addSubview(conversationContainer)
        conversationContainer.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: conversationContainer.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: conversationContainer.bottomAnchor)
        ])
        // Undocked iPad keyboards should not collapse the whole conversation.
        // UIKit still tracks docked/split keyboards and their interactive motion.
        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        keyboardBottom = conversationContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        restingBottom = conversationContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            conversationContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            conversationContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            conversationContainer.topAnchor.constraint(equalTo: view.topAnchor),
            avoidsKeyboard ? keyboardBottom : restingBottom
        ])
        host.didMove(toParent: self)

        addChild(composerHost)
        composerHost.sizingOptions = .intrinsicContentSize
        composerHost.view.backgroundColor = .clear
        composerHost.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerHost.view)
        composerKeyboardBottom = composerHost.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        composerRestingBottom = composerHost.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            composerHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            avoidsKeyboard ? composerKeyboardBottom : composerRestingBottom
        ])
        composerHost.didMove(toParent: self)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidShow),
                           name: UIResponder.keyboardDidShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide),
                           name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        keyboardTransitionEndWork?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        host.view.layoutIfNeeded()
        composerHost.view.layoutIfNeeded()
        conversationContainer.updateMask()
    }

    @objc private func keyboardWillChangeFrame() { beginKeyboardTransition() }
    @objc private func keyboardWillHide() { beginKeyboardTransition() }
    @objc private func keyboardDidShow() { scheduleKeyboardTransitionEnd() }
    @objc private func keyboardDidHide() { scheduleKeyboardTransitionEnd() }

    private func beginKeyboardTransition() {
        keyboardTransitionEndWork?.cancel()
        // Fallback for a will-change that never gets a matching did-show
        // (hardware keyboard frame changes, interrupted transitions).
        let fallback = DispatchWorkItem { [weak self] in
            self?.endKeyboardTransition()
        }
        keyboardTransitionEndWork = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)
        guard !isKeyboardTransitioning else { return }
        isKeyboardTransitioning = true
        applyKeyboardTransitionFlag(true)
        // The collection view can finish mounting one runloop after the
        // will-change notification; catch it without walking the tree every
        // animation frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isKeyboardTransitioning else { return }
            self.applyKeyboardTransitionFlag(true)
        }
    }

    private func scheduleKeyboardTransitionEnd() {
        keyboardTransitionEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.endKeyboardTransition()
        }
        keyboardTransitionEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyboardTransitionSettleDelay, execute: work)
    }

    /// One authoritative post-transition pass. Cached cells keep returning
    /// their same-width heights, so this settles frames/contentSize without
    /// asking any visible cell to re-enter SwiftUI/TextKit.
    private func endKeyboardTransition() {
        keyboardTransitionEndWork?.cancel()
        keyboardTransitionEndWork = nil
        guard isKeyboardTransitioning else { return }
        isKeyboardTransitioning = false
        for layout in messageListLayouts(in: host.view) {
            layout.isKeyboardTransitioning = false
            layout.invalidateLayout()
        }
    }

    private func applyKeyboardTransitionFlag(_ active: Bool) {
        for layout in messageListLayouts(in: host.view) {
            if layout.isKeyboardTransitioning != active {
                layout.isKeyboardTransitioning = active
            }
        }
    }

    private func messageListLayouts(in view: UIView) -> [MessageListLayout] {
        var layouts: [MessageListLayout] = []
        func walk(_ current: UIView) {
            if let collection = current as? UICollectionView,
               let layout = collection.collectionViewLayout as? MessageListLayout {
                layouts.append(layout)
            }
            for subview in current.subviews { walk(subview) }
        }
        walk(view)
        return layouts
    }

    func update(content: AnyView, composer: AnyView, avoidsKeyboard: Bool, fadeCompleteY: CGFloat = 0,
                usesWindowHeaderFade: Bool = false) {
        #if DEBUG
        KeyboardHangProbe.recordViewportUpdate()
        #endif
        // Refresh even when keyboard avoidance did not change (e.g. rotation,
        // navigation transition or a SwiftUI parameter update).
        conversationContainer.configure(completeY: fadeCompleteY, usesWindowSafeArea: usesWindowHeaderFade)
        host.rootView = Self.root(content)
        composerHost.rootView = Self.composerRoot(composer)
        // A rootView replacement can mount a fresh collection view while the
        // keyboard is still moving. Carry the frozen-measurement window over
        // to it until the deferred settle pass runs.
        if isKeyboardTransitioning { applyKeyboardTransitionFlag(true) }
        guard self.avoidsKeyboard != avoidsKeyboard else { return }
        self.avoidsKeyboard = avoidsKeyboard
        guard isViewLoaded else { return }
        // Voice input without its transcript editor deliberately opts out of
        // avoidance, including transient accessory insets on background return.
        keyboardBottom.isActive = false
        restingBottom.isActive = false
        composerKeyboardBottom.isActive = false
        composerRestingBottom.isActive = false
        (avoidsKeyboard ? keyboardBottom : restingBottom).isActive = true
        (avoidsKeyboard ? composerKeyboardBottom : composerRestingBottom).isActive = true
        view.setNeedsLayout()
    }
}

/// Own the mask on a plain UIKit view. SwiftUI owns the hosting view's layer
/// and may change its rendering state; it must not own this effect as well.
final class ChatConversationFadeView: UIView {
    private let fadeMask = CAGradientLayer()
    private var completeY: CGFloat = 0
    private var usesWindowSafeArea = false

    func configure(completeY: CGFloat, usesWindowSafeArea: Bool) {
        self.completeY = completeY
        self.usesWindowSafeArea = usesWindowSafeArea
        setNeedsLayout()
        updateMask()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMask()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMask()
    }

    func updateMask() {
        guard let window, bounds.height > 0,
              !UIAccessibility.isReduceTransparencyEnabled else {
            layer.mask = nil
            return
        }
        let endInWindow = usesWindowSafeArea ? window.safeAreaInsets.top + 8 : completeY
        // Window -> container conversion matters in navigation/split-view
        // layouts. Never interpret a navbar's maxY as the status-bar inset.
        let start = convert(CGPoint(x: 0, y: window.bounds.minY), from: window).y - bounds.minY
        let end = convert(CGPoint(x: 0, y: endInWindow), from: window).y - bounds.minY
        guard endInWindow > 0, end > 0, end > start else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.startPoint = CGPoint(x: 0.5, y: start / bounds.height)
        fadeMask.endPoint = CGPoint(x: 0.5, y: end / bounds.height)
        fadeMask.colors = [0.0, 0.30, 0.55, 1.0].map {
            UIColor.black.withAlphaComponent(CGFloat($0)).cgColor
        }
        fadeMask.locations = [0, 0.45, 0.75, 1]
        layer.mask = fadeMask
        CATransaction.commit()
    }
}

/// Both children contribute their true bounds to the composer. An overlay on
/// a 34pt (or zero-height) bar can draw a 65pt thumbnail outside the UIKit hit
/// region. Keep the same bottom/trailing alignment without that overflow.
struct ChatToolPreviewLayout<Status: View, Preview: View>: View {
    let showsStatus: Bool
    let showsPreview: Bool
    var attachments: AnyView? = nil
    @ViewBuilder let status: () -> Status
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        if let attachments {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    // Reserve the card's horizontal lane, not an extra row.
                    attachments.padding(.trailing, showsPreview ? 118 : 0)
                    if showsStatus { status().fixedSize(horizontal: false, vertical: true) }
                }
                // Match the original toolbar: the card and status share their
                // BOTTOM edge. Its upper part rises beside the attachments.
                if showsPreview { preview().padding(.trailing, 10) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            originalToolLayout
        }
    }

    private var originalToolLayout: some View {
        ZStack(alignment: .bottomTrailing) {
            // ZStack proposes the thumbnail's 65pt height to flexible children.
            // Resolve the status at its intrinsic height BEFORE that proposal;
            // its capsule must stay compact while the parent owns all hit bounds.
            if showsStatus { status().fixedSize(horizontal: false, vertical: true) }
            if showsPreview { preview().padding(.trailing, 10) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Keep probe identity independent of SwiftUI's accessibility propagation.
final class ChatLayoutGeometryUIView: UIView {
    var layoutRole = ""
}

/// Geometry-only marker for full-application regression capture.
struct ChatAccessoryGeometryMarker: UIViewRepresentable {
    let identifier: String
    func makeUIView(context: Context) -> UIView {
        let view = ChatLayoutGeometryUIView()
        view.isUserInteractionEnabled = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-chat-layout-only") {
            view.layoutRole = identifier
            view.accessibilityIdentifier = identifier
        }
        #endif
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}

#if DEBUG
/// Locked counters for the keyboard-hang reproducer. The self-sizing counter
/// can be bumped from a secondary layout thread, so every access takes the
/// same lock; snapshot/reset run on the main thread between keyboard cycles.
enum KeyboardHangProbe {
    private static let lock = NSLock()
    private static var inputBarHeightWrites = 0
    private static var selfSizingSuperCalls = 0
    private static var viewportUpdates = 0
    private static var badgeUpdates = 0
    private static var keyboardCacheHits = 0

    static func recordInputBarHeightWrite() {
        lock.lock(); inputBarHeightWrites += 1; lock.unlock()
    }
    static func recordSelfSizingSuperCall() {
        lock.lock(); selfSizingSuperCalls += 1; lock.unlock()
    }
    static func recordViewportUpdate() {
        lock.lock(); viewportUpdates += 1; lock.unlock()
    }
    static func recordBadgeUpdate() {
        lock.lock(); badgeUpdates += 1; lock.unlock()
    }
    static func recordKeyboardCacheHit() {
        lock.lock(); keyboardCacheHits += 1; lock.unlock()
    }

    struct Snapshot: Equatable {
        let inputBarHeightWrites: Int
        let selfSizingSuperCalls: Int
        let viewportUpdates: Int
        let badgeUpdates: Int
        let keyboardCacheHits: Int
    }

    static func reset() {
        lock.lock()
        inputBarHeightWrites = 0
        selfSizingSuperCalls = 0
        viewportUpdates = 0
        badgeUpdates = 0
        keyboardCacheHits = 0
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(inputBarHeightWrites: inputBarHeightWrites,
                        selfSizingSuperCalls: selfSizingSuperCalls,
                        viewportUpdates: viewportUpdates,
                        badgeUpdates: badgeUpdates,
                        keyboardCacheHits: keyboardCacheHits)
    }
}
#endif
