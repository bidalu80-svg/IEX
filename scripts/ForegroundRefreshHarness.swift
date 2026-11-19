import SwiftUI
import UIKit
import os

// Only the logger and ObjC exception bridge are fixtures. Host, cell and
// collection layout below are compiled from production sources without edits.
func AppLogger(category: String) -> Logger {
    Logger(subsystem: "com.ze.foreground-refresh-checks", category: category)
}
func noff_try_objc(_ body: () -> Void) -> Bool { body(); return true }

private final class RefreshInputs: ObservableObject {
    @Published var text = "short"
    @Published var phase = ScenePhase.inactive
}
private struct GrowingText: View {
    @ObservedObject var inputs: RefreshInputs
    var body: some View {
        Text(inputs.text).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
private struct PhaseLabel: UIViewRepresentable {
    @Environment(\.scenePhase) private var phase
    func makeUIView(context: Context) -> UILabel { UILabel() }
    func updateUIView(_ view: UILabel, context: Context) { view.text = String(describing: phase) }
}
private struct LiteralLabel: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UILabel { UILabel() }
    func updateUIView(_ view: UILabel, context: Context) { view.text = text }
}
private struct PhaseHost: View {
    @ObservedObject var inputs: RefreshInputs
    var body: some View {
        ChatKeyboardViewport(content: AnyView(PhaseLabel()), composer: AnyView(PhaseLabel()),
                             contentRenderKey: "constant-body", composerRenderKey: "constant-composer",
                             avoidsKeyboard: false, usesWindowHeaderFade: false)
            .environment(\.scenePhase, inputs.phase)
    }
}

@main
final class ForegroundRefreshHarness: UIResponder, UIApplicationDelegate, UICollectionViewDataSource {
    var window: UIWindow?
    private let inputs = RefreshInputs()
    private var checks: [String] = []

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        Task { @MainActor in
            await pause()
            await runChecks(window)
        }
        return true
    }

    @MainActor private func pause() async { try? await Task.sleep(nanoseconds: 150_000_000) }
    @MainActor private func require(_ condition: Bool, _ label: String) {
        guard condition else { finish(error: label); return }
        checks.append(label)
    }
    private func finish(error: String? = nil) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fg-refresh-result.json")
        let result: [String: Any] = ["success": error == nil, "checks": checks, "error": error ?? ""]
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        if error != nil { exit(1) }
    }
    private func labels(in view: UIView) -> [String] {
        (view as? UILabel).map { [$0.text ?? ""] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    @MainActor private func runChecks(_ window: UIWindow) async {
        // Same display keys, new scene environment: both roots must update.
        window.rootViewController = UIHostingController(rootView: PhaseHost(inputs: inputs))
        await pause()
        require(labels(in: window).filter { $0 == "inactive" }.count == 2, "initial inactive roots")
        inputs.phase = .active
        await pause()
        require(labels(in: window).filter { $0 == "active" }.count == 2, "both roots receive active with identical display keys")

        // Real keyboard controller: foreground closes an interrupted will-
        // change and drains pending content before the 600ms fallback.
        let host = ChatKeyboardViewportController(content: AnyView(LiteralLabel(text: "before")),
            composer: AnyView(LiteralLabel(text: "composer")), avoidsKeyboard: false)
        window.rootViewController = host
        await pause()
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        host.update(content: AnyView(LiteralLabel(text: "after")), composer: AnyView(LiteralLabel(text: "composer")),
                    contentRenderKey: "new", composerRenderKey: "same", avoidsKeyboard: false)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await pause()
        require(labels(in: window).contains("after"), "foreground drains interrupted keyboard update")

        // A real cell and real layout, with an in-place ObservableObject edit
        // and NO contentConfiguration replacement or explicit invalidation.
        let layout = MessageListLayout()
        let list = UICollectionView(frame: window.bounds, collectionViewLayout: layout)
        list.register(SelfSizingCell.self, forCellWithReuseIdentifier: "cell")
        list.dataSource = self
        let controller = UIViewController()
        controller.view = list
        window.rootViewController = controller
        await pause()
        list.layoutIfNeeded()
        let ip = IndexPath(item: 0, section: 0)
        guard let cell = list.cellForItem(at: ip) as? SelfSizingCell else {
            finish(error: "production cell did not mount"); return
        }
        func measure() -> CGFloat {
            let attributes = UICollectionViewLayoutAttributes(forCellWith: ip)
            attributes.size = CGSize(width: list.bounds.width, height: 20)
            return cell.preferredLayoutAttributesFitting(attributes).size.height
        }
        let initial = measure()
        inputs.text = Array(repeating: "streamed line", count: 24).joined(separator: "\n")
        await pause() // Beyond the legitimate 50ms dedup window.
        require(measure() > initial + 100, "same-width in-place text growth is measured")

        layout.isKeyboardTransitioning = true
        let keyboardHeight = measure()
        inputs.text += Array(repeating: "\nmore streaming", count: 24).joined()
        await pause()
        require(abs(measure() - keyboardHeight) < 1, "keyboard transaction keeps cached height")
        layout.finishKeyboardTransition()
        await pause()
        require(measure() > keyboardHeight + 100, "keyboard settle releases old height")

        layout.setPrecalcHeight(10, at: 0)
        layout.streamingCellRanges = [0..<1]
        layout.invalidateContentHeight(at: 0)
        cell.clearCachedHeight()
        require(layout.precalcHeight(at: 0) == nil && measure() > 100, "content invalidation drops streaming precalc")
        cell.seedMeasuredHeight(10, width: list.bounds.width)
        cell.clearCachedHeight()
        require(measure() > 100, "explicit invalidation drops old seed")
        finish()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1 }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! SelfSizingCell
        cell.applyContentConfiguration(UIHostingConfiguration { GrowingText(inputs: inputs) }.margins(.all, 0))
        return cell
    }
}
