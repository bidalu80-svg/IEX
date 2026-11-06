// Appended to unmodified production question views, state and coordinator.
// The chat message bridge and logging are integration fixtures, not UI mocks.
private struct AppLogger {
    init(category: String) {}
    func info(_ text: String) {}
    func warning(_ text: String) {}
    func error(_ text: String) {}
    func debug(_ text: String) {}
}
private enum AIChatViewModel { static let activeSessionId: String? = nil }
private final class FontSettings: ObservableObject {
    static let shared = FontSettings()
    func scaledMessage(_ size: CGFloat) -> CGFloat { size }
}
// The screenshot harness never starts microphone recording. Keep the native
// exception-bridge dependency explicit and fail if a future scenario tries it.
func noff_try_objc(_ block: () -> Void) -> Bool {
    preconditionFailure("Microphone capture is outside the screenshot harness")
}
enum HarnessToolStatus { case running, success, failed, cancelled, streaming }
struct HarnessBlockKind { var isQuestionCardTool = true }
@MainActor
final class AssistantBlock: ObservableObject {
    let id = UUID()
    @Published var questionCard: QuestionCardState?
    @Published var isQuestionCardExpanded = true
    @Published var content = ""
    var toolSummary: String?
    var toolInputArgs: String?
    var toolUseId: String?
    var toolStatus: HarnessToolStatus?
    var kind = HarnessBlockKind()
    init(card: QuestionCardState) { questionCard = card; toolUseId = card.requestId }
}
extension Notification.Name {
    static let questionCardToggled = Notification.Name("questionCardToggled")
}

@MainActor
private struct QuestionScreenshot: View {
    @ObservedObject var block: AssistantBlock
    let showOther: Bool
    @State private var sheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("问答交互").font(.headline)
            QuestionCardView(block: block)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .onAppear { sheetPresented = showOther }
        .sheet(isPresented: $sheetPresented) {
            QuestionAnswerInputSheet(title: "你的回答", question: block.questionCard?.displayQuestion ?? "",
                                     initialText: "先完成验证，再安排发布。") { value in
                guard let card = block.questionCard else { return }
                var draft = QuestionCardCoordinator.shared.draft(requestId: card.requestId, questionIndex: card.currentIndex)
                draft.otherText = value
                QuestionCardCoordinator.shared.saveDraft(requestId: card.requestId, questionIndex: card.currentIndex, draft: draft)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

@main
private final class QuestionCardUIHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var evidence: [[String: Any]] = []
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UserDefaults.standard.set(false, forKey: "backgroundNotificationsEnabled")
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in await runChecks() }
        return true
    }

    @MainActor private func runChecks() async {
        do {
            guard let window else { throw failure("Missing UIWindow") }
            for scheme in [ColorScheme.light, .dark] {
                for scenario in ["pending-single", "pending-multi", "pending-confirm", "resolved", "unconfirmed", "other-sheet"] {
                    try await capture(window: window, scheme: scheme, scenario: scenario)
                }
            }
            try writeResult(["success": true, "renderer": "UIHostingController + visible UIWindow.drawHierarchy",
                             "screenshots": evidence, "scope": "Unmodified question UI and live production coordinator; speech permissions and microphone are not exercised"])
        } catch {
            try? writeResult(["success": false, "error": error.localizedDescription, "screenshots": evidence])
        }
    }

    @MainActor private func capture(window: UIWindow, scheme: ColorScheme, scenario: String) async throws {
        let card = fixture(scenario: scenario)
        let block = AssistantBlock(card: card)
        var requestTask: Task<QuestionCardResponse, Never>?
        if card.status == .pending {
            requestTask = Task { @MainActor in
                await QuestionCardCoordinator.shared.request(state: card, block: block)
            }
            for _ in 0..<20 {
                if QuestionCardCoordinator.shared.isPending(requestId: card.requestId) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(QuestionCardCoordinator.shared.isPending(requestId: card.requestId), "Production coordinator did not register request")
            if scenario == "pending-multi" {
                QuestionCardCoordinator.shared.saveDraft(requestId: card.requestId, questionIndex: 0,
                                                         draft: QuestionCardDraft(selectedIndices: [0, 2], otherText: "", note: "优先执行回归检查", delegated: false))
            }
        }
        defer {
            if card.status == .pending { QuestionCardCoordinator.shared.submitUnconfirmed(requestId: card.requestId) }
            requestTask?.cancel()
        }
        let width: CGFloat = 320
        let height = min(UIScreen.main.bounds.height, 844)
        let sample = QuestionScreenshot(block: block, showOther: scenario == "other-sheet")
            .environment(\.colorScheme, scheme)
        let host = UIHostingController(rootView: sample)
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.frame.size = CGSize(width: width, height: height)
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: scenario == "other-sheet" ? 800_000_000 : 400_000_000)
        host.view.layoutIfNeeded()
        CATransaction.flush()
        if scenario == "other-sheet" {
            try require(host.presentedViewController != nil, "Other answer production sheet was not presented")
        }
        if card.status == .pending {
            try require(block.questionCard?.status == .pending && block.questionCard?.answeredCount == 0,
                        "Mounting or selecting a draft implicitly submitted an answer")
        }
        let name = "question-\(scheme == .dark ? "dark" : "light")-\(scenario).png"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var drew = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try require(drew, "Visible question window rendering failed")
        guard let png = image.pngData(), png.count > 3000 else { throw failure("Empty question screenshot") }
        try png.write(to: docs.appendingPathComponent(name))
        evidence.append(["file": name, "scenario": scenario, "width": Double(width), "height": Double(height),
                         "pngBytes": png.count, "liveRequest": QuestionCardCoordinator.shared.isPending(requestId: card.requestId),
                         "status": block.questionCard?.status.rawValue ?? "missing", "answers": block.questionCard?.answeredCount ?? -1,
                         "productionSheetPresented": host.presentedViewController != nil])
        host.dismiss(animated: false)
        window.rootViewController = UIViewController()
    }

    private func fixture(scenario: String) -> QuestionCardState {
        let multi = scenario == "pending-multi" || scenario == "resolved"
        let confirmation = scenario == "pending-confirm"
        let question = QuestionCardQuestion(id: "q1", prompt: confirmation ? "是否开始本次发布？" : multi ? "本次更新需要验证哪些内容？" : "完成更新后，采用哪种验证方式？",
                                           options: confirmation ? ["取消", "允许"] : multi ? ["请求参数兼容", "任务停止与继续", "工具卡片与滚动"] : ["自动构建与回归检查", "先查看改动记录"],
                                           multiSelect: multi,
                                           optionDescriptions: multi ? ["检查模型参数和能力映射", "检查后台任务的生命周期", "检查实时预览和操作入口"] : [nil, nil],
                                           isConfirmation: confirmation,
                                           impact: confirmation ? "构建成功后生成待安装的软件包。" : nil,
                                           risk: confirmation ? "需要确认验证结果。" : nil)
        var card = QuestionCardState(requestId: UUID().uuidString, title: "更新验证", questions: [question], timeoutAt: Date().addingTimeInterval(600))
        if scenario == "resolved" {
            card.status = .confirmed
            card.answers = ["请求参数兼容；工具卡片与滚动；补充说明：优先执行回归检查"]
        } else if scenario == "unconfirmed" {
            card.status = .unconfirmed
            card.resolutionSource = "timeout"
        }
        return card
    }
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "QuestionCardUIHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func writeResult(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: docs.appendingPathComponent("question-ui-result.json"))
    }
}
