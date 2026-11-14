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

    func makeUIViewController(context: Context) -> ChatKeyboardViewportController {
        ChatKeyboardViewportController(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard,
            fadeCompleteY: fadeCompleteY)
    }

    func updateUIViewController(_ controller: ChatKeyboardViewportController, context: Context) {
        controller.update(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard,
            fadeCompleteY: fadeCompleteY)
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
    private let fadeMask = CAGradientLayer()
    private var fadeCompleteY: CGFloat

    init(content: AnyView, composer: AnyView, avoidsKeyboard: Bool, fadeCompleteY: CGFloat = 0) {
        self.host = UIHostingController(rootView: Self.root(content))
        self.composerHost = UIHostingController(rootView: Self.composerRoot(composer))
        self.avoidsKeyboard = avoidsKeyboard
        self.fadeCompleteY = fadeCompleteY
        super.init(nibName: nil, bundle: nil)
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
        view.addSubview(host.view)
        // Undocked iPad keyboards should not collapse the whole conversation.
        // UIKit still tracks docked/split keyboards and their interactive motion.
        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        keyboardBottom = host.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        restingBottom = host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
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
        applyFadeMask()
    }

    /// Dissolve the conversation under the header: a gradient mask on the
    /// content host, transparent at the top and fully opaque at
    /// fadeCompleteY. Applied here — in the one layout pass that is
    /// guaranteed to run for the conversation's own container — so it
    /// cannot land on another screen or silently never run.
    private func applyFadeMask() {
        let bounds = host.view.bounds
        guard fadeCompleteY > 0, bounds.height > 0,
              !UIAccessibility.isReduceTransparencyEnabled else {
            if host.view.layer.mask === fadeMask { host.view.layer.mask = nil }
            return
        }
        let band = min(1, fadeCompleteY / bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        fadeMask.colors = [0.05, 0.30, 0.55, 1.0, 1.0].map {
            UIColor.black.withAlphaComponent($0).cgColor
        }
        fadeMask.locations = [0, 0.45, 0.75, 1].map {
            NSNumber(value: Double($0) * Double(band))
        } + [NSNumber(value: 1.0)]
        CATransaction.commit()
        if host.view.layer.mask !== fadeMask { host.view.layer.mask = fadeMask }
    }

    func update(content: AnyView, composer: AnyView, avoidsKeyboard: Bool, fadeCompleteY: CGFloat = 0) {
        self.fadeCompleteY = fadeCompleteY
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
