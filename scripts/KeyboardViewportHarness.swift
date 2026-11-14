import SwiftUI
import UIKit
import os

// Fixtures required by the unchanged production collection-view subclass.
func AppLogger(category: String) -> Logger { Logger(subsystem: "com.ze.keyboard-harness", category: category) }
final class MessageListLayout: UICollectionViewFlowLayout { var streamingCellIndex: Int? }
final class MessageListViewController: UIViewController { func prewarmVisibleCellsAfterWidthChange() {} }

struct FixtureMessages: UIViewRepresentable {
    let count: Int
    let followsBottom: Bool
    func makeCoordinator() -> Coordinator { Coordinator(count: count) }
    func makeUIView(context: Context) -> NoAnimationCollectionView {
        let layout = MessageListLayout()
        layout.itemSize = CGSize(width: 280, height: 52)
        layout.minimumLineSpacing = 8
        let list = NoAnimationCollectionView(frame: .zero, collectionViewLayout: layout)
        list.accessibilityIdentifier = "messages"
        list.backgroundColor = .clear
        list.contentInset.bottom = 70
        list.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        list.dataSource = context.coordinator
        list.shouldFollowViewportBottom = { followsBottom }
        DispatchQueue.main.async {
            list.layoutIfNeeded()
            if count > 10 {
                list.setContentOffset(CGPoint(x: 0, y: followsBottom
                    ? max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
                    : 1000), animated: false)
            }
        }
        return list
    }
    func updateUIView(_ list: NoAnimationCollectionView, context: Context) {}
    final class Coordinator: NSObject, UICollectionViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
            var config = UIListContentConfiguration.cell()
            config.text = "Message \(indexPath.item) — keyboard viewport"
            cell.contentConfiguration = config
            cell.accessibilityIdentifier = "message.\(indexPath.item)"
            return cell
        }
    }
}

/// Records actual on-screen geometry through the presentation tree. Sampling
/// is evidence, not a claim that simulator frame pacing equals a real device.
final class KeyboardFrameSampler: UIView {
    private var link: CADisplayLink?
    private var samples: [[String: Double]] = []
    private var start = CACurrentMediaTime()
    private var lastFlush = CACurrentMediaTime()
    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        if window != nil {
            let ticker = CADisplayLink(target: self, selector: #selector(sample))
            ticker.add(to: .main, forMode: .common)
            link = ticker
        }
    }
    @objc private func sample() {
        guard let window else { return }
        let presentation = layer.presentation() ?? layer
        let rect = presentation.convert(bounds, to: window.layer)
        samples.append(["t": CACurrentMediaTime() - start, "composerTop": rect.minY, "composerBottom": rect.maxY])
        if CACurrentMediaTime() - lastFlush > 0.5 {
            lastFlush = CACurrentMediaTime()
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("keyboard-motion.json")
            if let data = try? JSONSerialization.data(withJSONObject: samples) { try? data.write(to: url, options: .atomic) }
        }
    }
}
struct KeyboardProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardFrameSampler { KeyboardFrameSampler() }
    func updateUIView(_ view: KeyboardFrameSampler, context: Context) {}
    static func dismantleUIView(_ view: KeyboardFrameSampler, coordinator: ()) { view.removeFromSuperview() }
}

struct KeyboardFixture: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var avoidsKeyboard = true
    private var long: Bool { ProcessInfo.processInfo.arguments.contains("--long") }
    private var browse: Bool { ProcessInfo.processInfo.arguments.contains("--browse") }
    var body: some View {
        ChatKeyboardViewport(content: AnyView(
            ZStack(alignment: .bottom) {
                FixtureMessages(count: long ? 200 : 3, followsBottom: !browse)
            }
            .overlay(alignment: .top) {
                HStack {
                    Button("Dismiss") { focused = false }.accessibilityIdentifier("dismiss")
                    Button("Voice mode") { focused = false; avoidsKeyboard.toggle() }.accessibilityIdentifier("voice")
                }.padding(10).background(.regularMaterial)
            }
        ), composer: AnyView(
            HStack {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...4).focused($focused).accessibilityIdentifier("composer")
                Button("Send") { focused = false; text = "" }.accessibilityIdentifier("send")
            }
            .padding(12).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 18))
            .background(KeyboardProbe())
            .padding(.horizontal, 12).padding(.bottom, 8)
        ), avoidsKeyboard: avoidsKeyboard)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

@main struct KeyboardHarnessApp: App {
    var body: some Scene { WindowGroup { KeyboardFixture() } }
}
