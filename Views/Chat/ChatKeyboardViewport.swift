import Foundation
import SwiftUI
import UIKit

/// UIKit moves the composer as a separate view, so SwiftUI never has to
/// interpolate its bottom alignment while the conversation changes height.
struct ChatKeyboardViewport: UIViewControllerRepresentable {
    let content: AnyView
    let composer: AnyView
    @Environment(\.scenePhase) private var scenePhase

    // The roots explicitly capture EnvironmentValues. A display key match
    // must not retain an inactive/background environment on foreground return.
    private struct EnvironmentRenderKey: Hashable {
        let display: AnyHashable
        let phase: ScenePhase
    }

    private func environmentRenderKey(_ key: AnyHashable?) -> AnyHashable? {
        key.map { AnyHashable(EnvironmentRenderKey(display: $0, phase: scenePhase)) }
    }
    /// [T-keyboard-hang-1253] Changes only when the content host's actual
    /// display inputs change (messages/overlays/committed composer inset).
    /// Pure geometry-only body passes (latestInputBarFrameH and friends) must
    /// not replace `host.rootView`.
    /// `nil` keeps the legacy behaviour (replace on every update) for
    /// standalone harnesses that do not supply a render key.
    var contentRenderKey: AnyHashable? = nil
    /// [T-keyboard-hang-1253] Changes only when the composer's display
    /// content or chrome layout version changes. Interrupted per-frame
    /// geometry (`latestInputBarFrameH`) is deliberately absent; the
    /// settled `inputBarHeight` only appears because the popup overlay
    /// consumes it, and it changes at most once per keyboard transition.
    var composerRenderKey: AnyHashable? = nil
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
            contentRenderKey: environmentRenderKey(contentRenderKey),
            composerRenderKey: environmentRenderKey(composerRenderKey),
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
    static let keyboardTransitionFallbackDelay: TimeInterval = 0.6
    static let keyboardTransitionDidEndNotification = Notification.Name("ChatKeyboardViewportTransitionDidEnd")
    // Only list content waits for settle; composer display state stays live.
    private var pendingUpdate: (() -> Void)?

    // [T-keyboard-hang-1253] Render-key gates for the two hosting roots.
    // A nil key means "never rendered from an update yet".
    private var lastContentRenderKey: AnyHashable?
    private var lastComposerRenderKey: AnyHashable?
    private var hasRenderedContentRoot = false
    private var hasRenderedComposerRoot = false

    // [T-keyboard-hang-1253] Dirty tracking for hosted layout. `layoutIfNeeded`
    // must never be an unconditional per-layout tax: only a root replacement
    // or an actual bounds change needs a synchronous hosting layout. During a
    // keyboard transition host layout is authored once after the transaction
    // settles; composer layout is still resolved synchronously when its own
    // bounds change (fe75410's bottom-alignment contract), but a keyplane-only
    // pass with unchanged bounds does no hosted layout at all.
    private var lastHostLaidOutSize = CGSize.zero
    private var lastComposerLaidOutSize = CGSize.zero
    private var hostLayoutNeedsUpdate = true
    private var composerLayoutNeedsUpdate = true
    private var pendingHostSettleLayout = false

    private var appliedFadeCompleteY: CGFloat?
    private var appliedUsesWindowHeaderFade: Bool?

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
        center.addObserver(self, selector: #selector(applicationDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        // [T-keyboard-hang-1253] A keyplane/input-method swap can drive a
        // window layout without any keyboard frame/visibility notification.
        // Treat it as the same keyboard transaction so the hosted-tree layout
        // gate below also covers that system path.
        center.addObserver(self, selector: #selector(inputModeDidChange),
                           name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        keyboardTransitionEndWork?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if DEBUG
        KeyboardHangProbe.recordViewDidLayoutSubviewsCall()
        #endif
        conversationContainer.updateMask()

        let hostSize = host.view.bounds.size
        let composerSize = composerHost.view.bounds.size
        let hostSizeChanged = Self.sizeChanged(hostSize, from: lastHostLaidOutSize)
        let composerSizeChanged = Self.sizeChanged(composerSize, from: lastComposerLaidOutSize)

        if isKeyboardTransitioning {
            // [T-keyboard-hang-1253] The keyboard transaction owns this pass.
            // Only a hosting view whose own bounds actually changed is laid
            // out synchronously; that preserves fe75410's in-transaction
            // bottom alignment (and the keyboard's intermediate positions)
            // without re-entering a hosting tree on a keyplane-only pass whose
            // bounds did not move. List root replacements wait for settle;
            // composer display changes must enter layout immediately.
            if hostSizeChanged {
                performHostLayout()
            } else if hostLayoutNeedsUpdate {
                pendingHostSettleLayout = true
            }
            if composerSizeChanged || composerLayoutNeedsUpdate {
                performComposerLayout()
            }
            return
        }

        if hostLayoutNeedsUpdate || hostSizeChanged { performHostLayout() }
        if composerLayoutNeedsUpdate || composerSizeChanged { performComposerLayout() }
        if pendingHostSettleLayout { performHostLayout() }
    }

    private static func sizeChanged(_ current: CGSize, from previous: CGSize) -> Bool {
        // Sub-point churn from fractional keyboard frames is not a content
        // bounds change; a half-point threshold keeps the dirty gate stable
        // across 2x/3x screens.
        abs(current.width - previous.width) > 0.5 || abs(current.height - previous.height) > 0.5
    }

    private func performHostLayout() {
        #if DEBUG
        KeyboardHangProbe.recordHostLayoutIfNeededCall()
        #endif
        host.view.layoutIfNeeded()
        lastHostLaidOutSize = host.view.bounds.size
        hostLayoutNeedsUpdate = false
        pendingHostSettleLayout = false
    }

    private func performComposerLayout() {
        #if DEBUG
        KeyboardHangProbe.recordComposerHostLayoutIfNeededCall()
        #endif
        composerHost.view.layoutIfNeeded()
        lastComposerLaidOutSize = composerHost.view.bounds.size
        composerLayoutNeedsUpdate = false
    }

    @objc private func applicationDidBecomeActive() {
        // An interrupted keyboard transaction must not strand pending content
        // until another keyboard notification or a postponed fallback arrives.
        endKeyboardTransition()
    }

    @objc private func keyboardWillChangeFrame() { beginKeyboardTransition() }
    @objc private func inputModeDidChange() { beginKeyboardTransition() }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyboardTransitionFallbackDelay, execute: fallback)
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

    /// One authoritative post-transition pass. Keyboard-only cached heights
    /// are released here so content that grew during the animation can size.
    private func endKeyboardTransition() {
        keyboardTransitionEndWork?.cancel()
        keyboardTransitionEndWork = nil
        guard isKeyboardTransitioning else { return }
        // Resolve the parent's latest keyboard constraints and the live
        // composer's target geometry while width/height publication is gated.
        // Laying out only composerHost can still use its old parent bounds.
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if composerLayoutNeedsUpdate
            || Self.sizeChanged(composerHost.view.bounds.size, from: lastComposerLaidOutSize) {
            performComposerLayout()
        }
        // The single end signal now commits width/height from that geometry,
        // before draining list content and doing its final layout.
        NotificationCenter.default.post(name: Self.keyboardTransitionDidEndNotification, object: self)
        isKeyboardTransitioning = false
        // Apply only the newest list update, with the transaction closed.
        let update = pendingUpdate
        pendingUpdate = nil
        update?()
        for layout in messageListLayouts(in: host.view) {
            layout.finishKeyboardTransition()
        }
        // [T-keyboard-hang-1253] One authoritative post-transaction pass.
        // During the animation we deliberately skipped re-entering the
        // hosting trees; resolve any owed work now, outside the keyboard's
        // UIKit transaction.
        if pendingHostSettleLayout || hostLayoutNeedsUpdate { performHostLayout() }
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

    func update(content: AnyView, composer: AnyView, contentRenderKey: AnyHashable?, composerRenderKey: AnyHashable?,
                avoidsKeyboard: Bool, fadeCompleteY: CGFloat = 0,
                usesWindowHeaderFade: Bool = false) {
        #if DEBUG
        KeyboardHangProbe.recordViewportUpdate()
        #endif
        applyUpdate(content: content, composer: composer,
                    contentRenderKey: contentRenderKey, composerRenderKey: composerRenderKey,
                    avoidsKeyboard: avoidsKeyboard, fadeCompleteY: fadeCompleteY,
                    usesWindowHeaderFade: usesWindowHeaderFade)
    }

    private func applyUpdate(content: AnyView, composer: AnyView,
                             contentRenderKey: AnyHashable?, composerRenderKey: AnyHashable?,
                             avoidsKeyboard: Bool, fadeCompleteY: CGFloat,
                             usesWindowHeaderFade: Bool) {
        // Fade configuration is just two scalars; only push it into the mask
        // owner when it actually changed. The old unconditional call did
        // `setNeedsLayout()` + `updateMask()` on every SwiftUI update.
        if appliedFadeCompleteY != fadeCompleteY || appliedUsesWindowHeaderFade != usesWindowHeaderFade {
            appliedFadeCompleteY = fadeCompleteY
            appliedUsesWindowHeaderFade = usesWindowHeaderFade
            conversationContainer.configure(completeY: fadeCompleteY, usesWindowSafeArea: usesWindowHeaderFade)
        }

        // [T-keyboard-hang-1253] Re-root only when the hosted view's own
        // display/layout version changed. Interrupted per-frame geometry
        // (`latestInputBarFrameH`) never rebuilds either hosting tree; the
        // settled `inputBarHeight` only appears in the caller's keys because
        // the popup/message inset consumes it, once per transition.
        if isKeyboardTransitioning {
            // Coalesce list content only. Keyboard visibility/focus changes in
            // the composer key must reach its root at transition start.
            pendingUpdate = { [weak self] in
                self?.applyContentUpdate(content: content, contentRenderKey: contentRenderKey)
            }
        } else {
            applyContentUpdate(content: content, contentRenderKey: contentRenderKey)
        }
        var rootsChanged = false
        let replaceComposer = composerRenderKey == nil
            || !hasRenderedComposerRoot
            || lastComposerRenderKey != composerRenderKey
        if replaceComposer {
            lastComposerRenderKey = composerRenderKey
            hasRenderedComposerRoot = true
            composerHost.rootView = Self.composerRoot(composer)
            composerLayoutNeedsUpdate = true
            rootsChanged = true
            #if DEBUG
            KeyboardHangProbe.recordComposerRootReplacement()
            #endif
        }
        if rootsChanged, isViewLoaded { view.setNeedsLayout() }
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

    private func applyContentUpdate(content: AnyView, contentRenderKey: AnyHashable?) {
        // A nil key keeps the standalone harness's replace-every-update path.
        let replaceContent = contentRenderKey == nil
            || !hasRenderedContentRoot
            || lastContentRenderKey != contentRenderKey
        guard replaceContent else { return }
        lastContentRenderKey = contentRenderKey
        hasRenderedContentRoot = true
        host.rootView = Self.root(content)
        hostLayoutNeedsUpdate = true
        #if DEBUG
        KeyboardHangProbe.recordContentRootReplacement()
        #endif
        if isKeyboardTransitioning { applyKeyboardTransitionFlag(true) }
        if isViewLoaded { view.setNeedsLayout() }
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
///
/// [T-keyboard-hang-1253] The probe separates the input-bar account from the
/// message-list account: viewDidLayoutSubviews / composerHost layout and the
/// composer's TextKit measurements are the crash path; SelfSizingCell counters
/// stay untouched for the other ledger.
enum KeyboardHangProbe {
    private static let lock = NSLock()
    private static var inputBarHeightWrites = 0
    private static var latestInputBarFrameHWrites = 0
    private static var selfSizingSuperCalls = 0
    private static var viewportUpdates = 0
    private static var badgeUpdates = 0
    private static var keyboardCacheHits = 0
    private static var viewDidLayoutSubviewsCalls = 0
    private static var hostLayoutIfNeededCalls = 0
    private static var composerHostLayoutIfNeededCalls = 0
    private static var contentRootReplacements = 0
    private static var composerRootReplacements = 0
    private static var composerIntrinsicSizeCalls = 0
    private static var composerSizeThatFitsCalls = 0
    private static var composerFullMeasurementCalls = 0
    private static var composerMeasurementCacheHits = 0
    private static var composerDuplicateMeasurementCalls = 0
    private static var composerMeasurementTotalMs: Double = 0
    private static var composerMeasurementMaxMs: Double = 0
    private static var composerMeasuredKeys = Set<String>()

    static func recordInputBarHeightWrite() {
        lock.lock(); inputBarHeightWrites += 1; lock.unlock()
    }
    static func recordLatestInputBarFrameHWrite() {
        lock.lock(); latestInputBarFrameHWrites += 1; lock.unlock()
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
    static func recordViewDidLayoutSubviewsCall() {
        lock.lock(); viewDidLayoutSubviewsCalls += 1; lock.unlock()
    }
    static func recordHostLayoutIfNeededCall() {
        lock.lock(); hostLayoutIfNeededCalls += 1; lock.unlock()
    }
    static func recordComposerHostLayoutIfNeededCall() {
        lock.lock(); composerHostLayoutIfNeededCalls += 1; lock.unlock()
    }
    static func recordContentRootReplacement() {
        lock.lock(); contentRootReplacements += 1; lock.unlock()
    }
    static func recordComposerRootReplacement() {
        lock.lock(); composerRootReplacements += 1; lock.unlock()
    }
    static func recordComposerIntrinsicSizeCall() {
        lock.lock(); composerIntrinsicSizeCalls += 1; lock.unlock()
    }
    static func recordComposerSizeThatFitsCall() {
        lock.lock(); composerSizeThatFitsCalls += 1; lock.unlock()
    }
    static func recordComposerMeasurementCacheHit() {
        lock.lock(); composerMeasurementCacheHits += 1; lock.unlock()
    }
    static func recordComposerFullMeasurement(key: String, durationMs: Double) {
        lock.lock()
        composerFullMeasurementCalls += 1
        composerMeasurementTotalMs += durationMs
        composerMeasurementMaxMs = max(composerMeasurementMaxMs, durationMs)
        if composerMeasuredKeys.contains(key) {
            composerDuplicateMeasurementCalls += 1
        } else {
            composerMeasuredKeys.insert(key)
        }
        lock.unlock()
    }

    struct Snapshot: Equatable {
        let inputBarHeightWrites: Int
        let latestInputBarFrameHWrites: Int
        let selfSizingSuperCalls: Int
        let viewportUpdates: Int
        let badgeUpdates: Int
        let keyboardCacheHits: Int
        let viewDidLayoutSubviewsCalls: Int
        let hostLayoutIfNeededCalls: Int
        let composerHostLayoutIfNeededCalls: Int
        let contentRootReplacements: Int
        let composerRootReplacements: Int
        let composerIntrinsicSizeCalls: Int
        let composerSizeThatFitsCalls: Int
        let composerFullMeasurementCalls: Int
        let composerMeasurementCacheHits: Int
        let composerDuplicateMeasurementCalls: Int
        let composerMeasurementTotalMs: Double
        let composerMeasurementMaxMs: Double
    }

    static func reset() {
        lock.lock()
        inputBarHeightWrites = 0
        latestInputBarFrameHWrites = 0
        selfSizingSuperCalls = 0
        viewportUpdates = 0
        badgeUpdates = 0
        keyboardCacheHits = 0
        viewDidLayoutSubviewsCalls = 0
        hostLayoutIfNeededCalls = 0
        composerHostLayoutIfNeededCalls = 0
        contentRootReplacements = 0
        composerRootReplacements = 0
        composerIntrinsicSizeCalls = 0
        composerSizeThatFitsCalls = 0
        composerFullMeasurementCalls = 0
        composerMeasurementCacheHits = 0
        composerDuplicateMeasurementCalls = 0
        composerMeasurementTotalMs = 0
        composerMeasurementMaxMs = 0
        composerMeasuredKeys.removeAll()
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(inputBarHeightWrites: inputBarHeightWrites,
                        latestInputBarFrameHWrites: latestInputBarFrameHWrites,
                        selfSizingSuperCalls: selfSizingSuperCalls,
                        viewportUpdates: viewportUpdates,
                        badgeUpdates: badgeUpdates,
                        keyboardCacheHits: keyboardCacheHits,
                        viewDidLayoutSubviewsCalls: viewDidLayoutSubviewsCalls,
                        hostLayoutIfNeededCalls: hostLayoutIfNeededCalls,
                        composerHostLayoutIfNeededCalls: composerHostLayoutIfNeededCalls,
                        contentRootReplacements: contentRootReplacements,
                        composerRootReplacements: composerRootReplacements,
                        composerIntrinsicSizeCalls: composerIntrinsicSizeCalls,
                        composerSizeThatFitsCalls: composerSizeThatFitsCalls,
                        composerFullMeasurementCalls: composerFullMeasurementCalls,
                        composerMeasurementCacheHits: composerMeasurementCacheHits,
                        composerDuplicateMeasurementCalls: composerDuplicateMeasurementCalls,
                        composerMeasurementTotalMs: composerMeasurementTotalMs,
                        composerMeasurementMaxMs: composerMeasurementMaxMs)
    }
}
#endif
