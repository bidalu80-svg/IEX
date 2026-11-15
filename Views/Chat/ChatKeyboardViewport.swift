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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        host.view.layoutIfNeeded()
        composerHost.view.layoutIfNeeded()
        conversationContainer.updateMask()
    }

    func update(content: AnyView, composer: AnyView, avoidsKeyboard: Bool, fadeCompleteY: CGFloat = 0,
                usesWindowHeaderFade: Bool = false) {
        // Refresh even when keyboard avoidance did not change (e.g. rotation,
        // navigation transition or a SwiftUI parameter update).
        conversationContainer.configure(completeY: fadeCompleteY, usesWindowSafeArea: usesWindowHeaderFade)
        host.rootView = Self.root(content)
        composerHost.rootView = Self.composerRoot(composer)
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
    @ViewBuilder let status: () -> Status
    @ViewBuilder let preview: () -> Preview

    var body: some View {
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
