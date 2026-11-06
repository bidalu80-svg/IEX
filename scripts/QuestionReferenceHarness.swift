// Integration fixtures only. All card, typography, palette, text and sheet
// declarations above this file are extracted unchanged from the pinned source.
final class FontSettings: ObservableObject {
    static let shared = FontSettings()
    func scaledMessage(_ size: CGFloat) -> CGFloat { size }
}
final class AssistantBlock: ObservableObject {
    let id = UUID()
    var toolInputArgs: String?
    var content = ""
    @Published var isThinkingExpanded = false
}
final class ToggleRequest {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { let run = action; action = nil; run?() }
}
enum ToggleAnchorMath {
    static let anchorTopKey = "anchorTop"
    static let toggleRequestKey = "toggleRequest"
}
extension Notification.Name { static let thinkingBlockToggled = Notification.Name("thinkingBlockToggled") }
func AppLocalized(_ key: String) -> String { NSLocalizedString(key, comment: "") }

@MainActor
final class UserAskCenter: ObservableObject {
    static let shared = UserAskCenter()
    @Published var asks: [String: PendingAsk] = [:]
    // UPSTREAM_PRESELECT_RECOMMENDED
    func noteInteraction(requestId: String) {}
    func updateAnswer(requestId: String, index: Int, _ answer: UserAskAnswer) { asks[requestId]?.answers[index] = answer }
    func submitQuestion(requestId: String, index: Int) {}
    func goTo(requestId: String, index: Int) { asks[requestId]?.currentIndex = index }
    func confirm(requestId: String, index: Int, choice: UserAskConfirmChoice, note: String? = nil) {}
}
final class VoiceInputViewModel: ObservableObject {
    enum State { case waiting }
    var state = State.waiting
    func stopListening() {}
    func handleMainButtonTap() { preconditionFailure("Reference screenshots do not exercise microphone input") }
}
final class VoiceModePreference {
    static let shared = VoiceModePreference()
    var expanded = false
    var enteredFromText = false
}
struct InlineVoiceInputView: View {
    let viewModel: VoiceInputViewModel
    @Binding var inputText: String
    var body: some View {
        Color.clear.onAppear { preconditionFailure("A voice UI fixture must never appear in a reference screenshot") }
    }
}

@MainActor
private struct ReferenceScreenshot: View {
    let ask: PendingAsk
    let scenario: String
    @StateObject private var block = AssistantBlock()
    @State private var showingInput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("问答交互").font(.headline)
            if scenario == "resolved" || scenario == "unconfirmed" {
                UserAskResolvedCard(block: block, questions: ask.questions,
                                    results: [UserAskCardModel.Result(status: scenario == "resolved" ? .answered : .timeout,
                                                answer: scenario == "resolved" ? ["请求参数兼容", "工具卡片与滚动"] : [],
                                                note: scenario == "resolved" ? "优先执行回归检查" : nil)],
                                    source: nil, dismissReason: nil)
            } else {
                UserAskPendingCard(ask: ask, blockId: block.id)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .onAppear { showingInput = scenario == "other-sheet" }
        .sheet(isPresented: $showingInput) {
            UserAskInputSheet(kind: .other, requestId: ask.requestId, index: 0,
                              question: ask.questions[0].question, initial: "先完成验证，再安排发布。",
                              onChange: { _ in }, onDone: { _ in showingInput = false }, onCancel: { showingInput = false })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

@main
private final class QuestionReferenceHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var evidence: [[String: Any]] = []
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in await runChecks() }
        return true
    }
    @MainActor private func runChecks() async {
        do {
            guard let window else { throw failure("Missing window") }
            for scheme in [ColorScheme.light, .dark] {
                for scenario in ["pending-single", "pending-multi", "pending-confirm", "resolved", "unconfirmed", "other-sheet"] {
                    try await capture(window: window, scheme: scheme, scenario: scenario)
                }
            }
            try write(["success": true, "commit": "1a71df0f381cefde80bf912b723de6f9831bc177", "screenshots": evidence,
                       "scope": "Unmodified upstream question cards and input sheet; center side effects and inactive voice branch are fixtures"])
        } catch { try? write(["success": false, "error": error.localizedDescription, "screenshots": evidence]) }
    }
    @MainActor private func capture(window: UIWindow, scheme: ColorScheme, scenario: String) async throws {
        let ask = fixture(scenario)
        UserAskCenter.shared.asks[ask.requestId] = ask
        let host = UIHostingController(rootView: ReferenceScreenshot(ask: ask, scenario: scenario).environment(\.colorScheme, scheme))
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.frame.size = CGSize(width: 320, height: min(UIScreen.main.bounds.height, 844))
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: scenario == "other-sheet" ? 1_500_000_000 : 450_000_000)
        host.view.layoutIfNeeded()
        CATransaction.flush()
        if scenario == "other-sheet", host.presentedViewController == nil { throw failure("Reference input sheet not presented") }
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        var drew = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drew, let png = image.pngData(), png.count > 3000 else { throw failure("Empty reference capture") }
        let filename = "reference-\(scheme == .dark ? "dark" : "light")-\(scenario).png"
        try png.write(to: docs.appendingPathComponent(filename))
        evidence.append(["file": filename, "scenario": scenario, "pngBytes": png.count,
                         "width": Double(window.bounds.width), "height": Double(window.bounds.height)])
        host.dismiss(animated: false)
        window.rootViewController = UIViewController()
        UserAskCenter.shared.asks.removeValue(forKey: ask.requestId)
    }
    private func fixture(_ scenario: String) -> PendingAsk {
        let multi = scenario == "pending-multi" || scenario == "resolved"
        let confirm = scenario == "pending-confirm"
        let options = multi ? ["请求参数兼容", "任务停止与继续", "工具卡片与滚动"] : ["自动构建与回归检查", "先查看改动记录"]
        let details = multi ? ["检查模型参数和能力映射", "检查后台任务的生命周期", "检查实时预览和操作入口"] : []
        let q = UserAskQuestion(type: confirm ? .confirm : .options,
                               question: confirm ? "是否开始本次发布？" : multi ? "本次更新需要验证哪些内容？" : "完成更新后，采用哪种验证方式？",
                               header: nil, options: confirm ? nil : options.enumerated().map { UserAskOption(label: $0.element, description: details.indices.contains($0.offset) ? details[$0.offset] : nil) },
                               multiSelect: multi, impact: confirm ? "构建成功后生成待安装的软件包。" : nil,
                               risk: confirm ? .high : .medium, defaultValue: nil)
        var ask = PendingAsk(requestId: UUID().uuidString, sessionId: "fixture", toolCallId: "fixture", questions: [q], createdAt: Date(), timeoutMinutes: 10)
        UserAskCenter.preselectRecommended(&ask, at: 0)
        if scenario == "pending-multi" { ask.answers[0] = UserAskAnswer(selected: [0, 2], note: "优先执行回归检查") }
        return ask
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "QuestionReferenceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func write(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent("reference-ui-result.json"))
    }
}
