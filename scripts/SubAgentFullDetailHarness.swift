// Only integration facts are supplied here; both complete detail Views and
// all visible subviews are extracted unchanged from their real source files.
private let detailTask = "检查请求兼容性并报告验证结果"
private let detailStartedAt: Date = {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--fixture-start"), index + 1 < args.count, let epoch = Double(args[index + 1]) else { preconditionFailure("Missing shared fixture clock") }
    return Date(timeIntervalSince1970: epoch)
}()
private let detailFinishedAt = detailStartedAt.addingTimeInterval(1)

// These optional branches are absent from the scenario. Fail if rendered, so
// no screenshot can silently substitute a fake Markdown/image/badge renderer.
struct SelectableMarkdownView: View {
    let markdown: String
    var body: some View { Color.clear.onAppear { preconditionFailure("Markdown is outside the empty-output detail fixture") } }
}

#if ZE_DETAIL
struct HarnessModel { let displayName: String }
struct HarnessEntry { let model: HarnessModel }
final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func entry(for reference: String) -> HarnessEntry? { preconditionFailure("No configured-model lookup in this fixture") }
}
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    func thumbnail(for path: String, maxSize: Int) async -> UIImage? { preconditionFailure("No image in this fixture") }
}
final class ZeSubAgentCoordinator: ObservableObject {
    static let shared = ZeSubAgentCoordinator()
    @Published var fixtureRecord: ZeSubAgentRecord?
    func record(id: String) -> ZeSubAgentRecord? { fixtureRecord }
    func cancelRunGroup(id: String) { preconditionFailure("Detail screenshots never invoke Stop") }
    func sendInput(id: String, message: String) -> String? { preconditionFailure("Detail screenshots never send input") }
}
private func configureDetailFixture(running: Bool) {
    let steps = [
        ZeSubAgentStep(id: "read", title: "配置", icon: "doc.text", content: "检查配置与依赖，发现 3 个待更新项目。", state: "success", duration: 0.3, toolName: "file_read"),
        ZeSubAgentStep(id: "edit", title: "请求适配", icon: "square.and.pencil", content: "已保存协议适配变更。", state: "success", duration: 1.2, toolName: "file_edit"),
        ZeSubAgentStep(id: "test", title: "执行回归验证", icon: "terminal", content: running ? "正在检查模型请求参数…" : "11 项回归检查完成。", state: running ? "running" : "success", duration: running ? nil : 2.4, toolName: "shell_execute"),
    ]
    var record = ZeSubAgentRecord(id: "fixture-agent", parentId: "fixture-parent", rootSessionId: "fixture-root", nickname: "兼容性验证", depth: 1,
        status: running ? .running : .completed, revision: 1, createdAt: detailStartedAt, updatedAt: detailFinishedAt,
        prompt: detailTask, output: "", error: nil, childSessionId: "fixture-child", inputTokens: 12345, outputTokens: 2345,
        modelEntryReference: nil, steps: steps)
    record.turnCount = 3
    record.cacheReadTokens = 4096
    record.startedAt = detailStartedAt
    record.finishedAt = running ? nil : detailFinishedAt
    record.requestModelId = "gpt-5.4"
    record.requestModelName = "gpt-5.4"
    record.deliveryState = "inline"
    record.budgetMinutes = 10
    ZeSubAgentCoordinator.shared.fixtureRecord = record
}
private struct FullDetailScreenshot: View {
    let scheme: ColorScheme
    var body: some View {
        ScrollView { ZeSubAgentDetailContent(recordId: "fixture-agent").padding(12) }
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, scheme)
            .environment(\.scenePhase, .active)
            .ignoresSafeArea()
    }
}
#else
func AppLocalized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
enum SubAgentDefinition { static let toolName = "subagent_task"; static let builtInName = "General Sub Agent" }
struct ThinkingLevel {
    static func parse(_ text: String) -> ThinkingLevel? { preconditionFailure("No thinking badge in this fixture") }
    var isEnabled: Bool { preconditionFailure("No thinking badge in this fixture") }
    var displayName: String { preconditionFailure("No thinking badge in this fixture") }
}
final class AssistantBlock: ObservableObject {
    enum Kind { case text, delegateTool(String), fixtureTool(String) }
    enum Status { case streaming, running, success, failed, cancelled }
    let id = UUID()
    var toolSummary: String?
    var toolDescription = ""
    var kind = Kind.delegateTool(detailTask)
    var content = ""
    var helperModel: HelperModelIdentity?
    var helperAgentName: String? = "兼容性验证"
    var toolStatus: Status? = .running
    var helperQueueLost = false
    var toolInputArgs: String?
    var helperChildSessionId: String? = "fixture-child"
    var toolDuration: TimeInterval?
    var toolStartTime: Date? = detailStartedAt
    var imageFilePath: String?
}
struct FixtureMessage {
    enum Role { case assistant, user }
    let role: Role
    let blocks: [AssistantBlock]
}
struct FixtureTokenStats { var loopCount = 3; var input = 12345; var output = 2345; var cacheRead = 4096 }
final class AIChatViewModel {
    static let helperDefaultMinutes = 10
    static let helperMaxMinutes = 60
    var messages: [FixtureMessage] = []
    var sessionTokenStats = FixtureTokenStats()
    static func parseDelegateResult(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func toolWireName(_ kind: AssistantBlock.Kind) -> String {
        if case .fixtureTool(let name) = kind { return name }
        preconditionFailure("Unexpected tool kind in fixture")
    }
    func loadSession() async { preconditionFailure("Fixture child session is already loaded") }
    func cancel() { preconditionFailure("Detail screenshots never invoke Stop") }
}
final class ViewModelCache {
    enum Kind { case child }
    static let shared = ViewModelCache()
    let child = AIChatViewModel()
    var detailReads = 0
    func getOrCreate(for id: String, kind: Kind) -> (AIChatViewModel, Bool) { detailReads += 1; return (child, false) }
    func get(for id: String) -> AIChatViewModel? { preconditionFailure("Unexpected runtime action") }
}
struct FixtureJob {
    enum State { case running, pending, completed }
    var runSessionId = "fixture-child"
    var startedAt: Date? = detailStartedAt
    var finishedAt: Date?
    var state: State
}
final class AgentJobRegistry {
    static let shared = AgentJobRegistry()
    var job = FixtureJob(state: .running)
    func list() -> [FixtureJob] { [job] }
    func stopSubAgentByUser(childSessionId: String, reason: String) -> Int { preconditionFailure("Detail screenshots never invoke Stop") }
}
enum SubAgentUserSteer {
    static func send(_ text: String, childSessionId: String) -> Bool { preconditionFailure("Detail screenshots never send input") }
}
private enum ReferenceFixture {
    static var parent = AssistantBlock()
}
private func configureDetailFixture(running: Bool) {
    let block = AssistantBlock()
    block.toolSummary = detailTask
    // Uses the same 10-minute default budget as the Ze fixture.
    block.toolInputArgs = "{\"action\":\"delegate\",\"task\":\"检查请求兼容性并报告验证结果\",\"wait\":true}"
    block.toolStatus = running ? .running : .success
    var model = HelperModelIdentity()
    model.effectiveModelId = "gpt-5.4"
    model.effectiveModelName = "gpt-5.4"
    model.effectiveSource = "request"
    block.helperModel = model
    block.content = running
        ? "◐ Helper · 检查请求兼容性并报告验证结果 · shell_execute · 执行回归验证 · 0:01"
        : "{\"status\":\"completed\",\"elapsed_s\":1,\"result\":\"\",\"child_session_id\":\"fixture-child\"}"
    ReferenceFixture.parent = block
    let calls: [(String, String, Double?)] = [("file_read", "配置", 0.3), ("file_edit", "请求适配", 1.2), ("shell_execute", "执行回归验证", running ? nil : 2.4)]
    let blocks = calls.enumerated().map { index, call -> AssistantBlock in
        let b = AssistantBlock()
        b.kind = .fixtureTool(call.0)
        b.toolSummary = call.1
        b.toolStatus = index == 2 && running ? .running : .success
        b.toolDuration = call.2
        return b
    }
    ViewModelCache.shared.detailReads = 0
    ViewModelCache.shared.child.messages = [FixtureMessage(role: .assistant, blocks: blocks)]
    AgentJobRegistry.shared.job = FixtureJob(finishedAt: running ? nil : detailFinishedAt, state: running ? .running : .completed)
}
private struct FullDetailScreenshot: View {
    let scheme: ColorScheme
    var body: some View {
        HelperDetailCard(block: ReferenceFixture.parent)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, scheme)
            .environment(\.scenePhase, .active)
            .ignoresSafeArea()
    }
}
#endif

@main
private final class SubAgentFullDetailHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var evidence: [[String: Any]] = []
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var prefix: String {
        #if ZE_DETAIL
        return "ze-detail"
        #else
        return "reference-detail"
        #endif
    }
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
            guard let window else { throw failure("Missing UIWindow") }
            for _ in 0..<50 {
                if UIApplication.shared.applicationState == .active { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard UIApplication.shared.applicationState == .active else { throw failure("Application did not become active") }
            for scheme in [ColorScheme.light, .dark] {
                for running in [true, false] { try await capture(window: window, scheme: scheme, running: running) }
            }
            try writeResult(["success": true, "screenshots": evidence,
                "scope": "Complete production detail component, captured at top and bottom scroll positions. Fixture has no Markdown/image/thinking badge. Empty-output completion and live action controls are real Views. No runtime action or device FPS assertion."])
        } catch { try? writeResult(["success": false, "error": error.localizedDescription, "screenshots": evidence]) }
    }
    @MainActor private func capture(window: UIWindow, scheme: ColorScheme, running: Bool) async throws {
        configureDetailFixture(running: running)
        let width: CGFloat = 320
        let height: CGFloat = min(UIScreen.main.bounds.height, 800)
        let host = UIHostingController(rootView: FullDetailScreenshot(scheme: scheme))
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.frame.size = CGSize(width: width, height: height)
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
        host.view.layoutIfNeeded()
        #if !ZE_DETAIL
        guard ViewModelCache.shared.detailReads > 0 else { throw failure("Original loadChildFacts did not read the fixture session") }
        #endif
        let scrolls = allViews(host.view).compactMap { $0 as? UIScrollView }
        guard let scroll = scrolls.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { throw failure("No real detail ScrollView") }
        let name = "\(prefix)-\(scheme == .dark ? "dark" : "light")-\(running ? "running" : "completed")"
        let top = try snapshot(window: window)
        var bottomOffset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        // A LazyVStack can refine its height after the first scroll. Resolve
        // the final offset before capturing controls at the real bottom.
        bottomOffset = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        scroll.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        host.view.layoutIfNeeded()
        guard scroll.contentSize.height <= height * 2 else { throw failure("Two viewport captures leave a gap in detail content; add a middle capture") }
        let bottom = try snapshot(window: window)
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let combined = UIGraphicsImageRenderer(size: CGSize(width: width, height: height * 2 + 28), format: format).image { ctx in
            UIColor.systemGray5.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height * 2 + 28))
            top.draw(at: .zero)
            ("BOTTOM SCROLL POSITION" as NSString).draw(at: CGPoint(x: 8, y: height + 7), withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black])
            bottom.draw(at: CGPoint(x: 0, y: height + 28))
        }
        guard let png = combined.pngData(), png.count > 3000 else { throw failure("Empty full-detail screenshot") }
        try png.write(to: docs.appendingPathComponent(name + ".png"))
        evidence.append(["file": name + ".png", "viewportWidth": Double(width), "viewportHeight": Double(height), "scrollContentHeight": Double(scroll.contentSize.height), "bottomOffset": Double(bottomOffset), "pngBytes": png.count])
        window.rootViewController = UIViewController()
    }
    private func snapshot(window: UIWindow) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        var drew = false
        let result = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard drew else { throw failure("Window drawHierarchy failed") }
        return result
    }
    private func allViews(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(allViews) }
    private func failure(_ text: String) -> NSError { NSError(domain: "FullDetailHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private func writeResult(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: docs.appendingPathComponent(prefix + "-result.json"))
    }
}
