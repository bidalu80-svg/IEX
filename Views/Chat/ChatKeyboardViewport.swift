import SwiftUI
import UIKit

/// One UIKit layout owns the viewport and its bottom-aligned composer. The
/// hosted SwiftUI tree must not apply a second keyboard safe-area adjustment.
struct ChatKeyboardViewport: UIViewControllerRepresentable {
    let content: AnyView
    var avoidsKeyboard: Bool = true

    func makeUIViewController(context: Context) -> ChatKeyboardViewportController {
        ChatKeyboardViewportController(
            content: AnyView(content.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard)
    }

    func updateUIViewController(_ controller: ChatKeyboardViewportController, context: Context) {
        controller.update(
            content: AnyView(content.environment(\.self, context.environment)),
            avoidsKeyboard: avoidsKeyboard)
    }
}

final class ChatKeyboardViewportController: UIViewController {
    private let host: UIHostingController<AnyView>
    private var avoidsKeyboard: Bool
    private var keyboardBottom: NSLayoutConstraint!
    private var restingBottom: NSLayoutConstraint!

    init(content: AnyView, avoidsKeyboard: Bool) {
        self.host = UIHostingController(rootView: Self.root(content))
        self.avoidsKeyboard = avoidsKeyboard
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private static func root(_ content: AnyView) -> AnyView {
        AnyView(content.ignoresSafeArea(.keyboard, edges: .bottom))
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Resolve SwiftUI's bottom alignment inside the keyboard's UIKit
        // layout transaction. Deferring the hosting view layout to the next
        // run-loop turn makes its children jump to the final bounds.
        host.view.layoutIfNeeded()
    }

    func update(content: AnyView, avoidsKeyboard: Bool) {
        host.rootView = Self.root(content)
        guard self.avoidsKeyboard != avoidsKeyboard else { return }
        self.avoidsKeyboard = avoidsKeyboard
        guard isViewLoaded else { return }
        // Voice input without its transcript editor deliberately opts out of
        // avoidance, including transient accessory insets on background return.
        keyboardBottom.isActive = false
        restingBottom.isActive = false
        (avoidsKeyboard ? keyboardBottom : restingBottom).isActive = true
        view.setNeedsLayout()
    }
}
