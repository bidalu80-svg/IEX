import SwiftUI
import UIKit

/// UIKit moves the composer as a separate view, so SwiftUI never has to
/// interpolate its bottom alignment while the conversation changes height.
struct ChatKeyboardViewport: UIViewControllerRepresentable {
    let content: AnyView
    let composer: AnyView
    var avoidsKeyboard: Bool = true

    func makeUIViewController(context: Context) -> ChatKeyboardViewportController {
        ChatKeyboardViewportController(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard)
    }

    func updateUIViewController(_ controller: ChatKeyboardViewportController, context: Context) {
        controller.update(
            content: AnyView(content.environment(\.self, context.environment)),
            composer: AnyView(composer.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard)
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

    init(content: AnyView, composer: AnyView, avoidsKeyboard: Bool) {
        self.host = UIHostingController(rootView: Self.root(content))
        self.composerHost = UIHostingController(rootView: Self.composerRoot(composer))
        self.avoidsKeyboard = avoidsKeyboard
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
    }

    func update(content: AnyView, composer: AnyView, avoidsKeyboard: Bool) {
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
