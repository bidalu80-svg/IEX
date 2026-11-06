// Fixture data and integration effects only. View declarations are copied verbatim
// from the pinned upstream commit by extract-subagent-reference.py.
final class AssistantBlock: ObservableObject {
    enum Kind { case delegateTool(String) }
    enum Status { case streaming, running, success, failed, cancelled }
    let id = UUID()
    var toolSummary: String? = "检查请求兼容性并报告验证结果"
    var kind = Kind.delegateTool("检查请求兼容性并报告验证结果")
    var content = ""
    var helperModel: HelperModelIdentity?
    var helperAgentName: String? = "兼容性验证"
    var toolStatus = Status.running
    var helperQueueLost = false
    var toolInputArgs: String? = "{\"action\":\"delegate\"}"
    var helperChildSessionId: String? = "fixture-child"
}
func AppLocalized(_ key: String) -> String { NSLocalizedString(key, comment: "") }
enum SubAgentDefinition {
    static let toolName = "subagent_task"
    static let builtInName = "General Sub Agent"
}
final class AIChatViewModel {
    static func parseDelegateResult(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    func loadSession() async { preconditionFailure("Reference fixture must not load a session") }
    func resumeInterruptedHelper(childSessionId: String) async -> String? { preconditionFailure("Reference fixture must not resume a job") }
    func cancel() { preconditionFailure("Reference fixture must not cancel a job") }
}
struct FixtureSession { let parentSessionId: String? }
final class ChatStore {
    static let shared = ChatStore()
    func getSession(_ id: String) async -> FixtureSession? { preconditionFailure("Reference fixture must not access storage") }
    func sessionExists(id: String) async -> Bool { preconditionFailure("Reference fixture must not access storage") }
}
final class ViewModelCache {
    static let shared = ViewModelCache()
    func getOrCreate(for id: String) -> (AIChatViewModel, Bool) { preconditionFailure("Reference fixture must not create a session") }
    func get(for id: String) -> AIChatViewModel? { preconditionFailure("Reference fixture must not access sessions") }
}
final class AgentJobRegistry {
    static let shared = AgentJobRegistry()
    func stopSubAgentByUser(childSessionId: String, reason: String) -> Int { preconditionFailure("Reference fixture must not stop a job") }
}
struct AppLogger {
    let category: String
    func warning(_ text: String) { preconditionFailure("Unexpected reference runtime action: \(text)") }
}

private struct SubAgentReferenceScreenshot: View {
    let block: AssistantBlock
    let digest: SubAgentRunDigest
    let scheme: ColorScheme
    @State private var detailBlock: AssistantBlock?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("子代理任务").font(.headline)
            HelperBlockView(block: block, detailBlock: $detailBlock)
            HelperThumbnailView(block: block)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            SubAgentStatChips(digest: digest, remaining: nil, budgetMinutes: nil)
            SubAgentToolTimelineCard(digest: digest)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, scheme)
        .environment(\.scenePhase, .active)
        .ignoresSafeArea()
    }
}

@main
private final class SubAgentReferenceHarness: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var evidence: [[String: Any]] = []
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
            guard UIApplication.shared.applicationState == .active else { throw failure("Reference application did not become active") }
            for scheme in [ColorScheme.light, .dark] {
                for running in [true, false] { try await capture(window: window, scheme: scheme, running: running) }
            }
            try writeResult(["success": true, "renderer": "UIHostingController + visible UIWindow.drawHierarchy", "screenshots": evidence,
                             "scope": "Unmodified upstream inline, raw thumbnail, stats and tool timeline. Detail sections use fixture digest; not the full detail sheet or floating toolbar rim. No runtime control or device FPS assertion."])
        } catch {
            try? writeResult(["success": false, "error": error.localizedDescription, "screenshots": evidence])
        }
    }
    @MainActor private func capture(window: UIWindow, scheme: ColorScheme, running: Bool) async throws {
        let (block, digest) = fixture(running: running)
        let width: CGFloat = 320
        let height: CGFloat = min(window.bounds.height, 800)
        let host = UIHostingController(rootView: SubAgentReferenceScreenshot(block: block, digest: digest, scheme: scheme))
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.frame.size = CGSize(width: width, height: height)
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        CATransaction.flush()
        let name = "reference-\(scheme == .dark ? "dark" : "light")-\(running ? "running" : "completed").png"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        var drew = false
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drew, let png = screenshot.pngData(), png.count > 3000 else { throw failure("Empty reference screenshot") }
        try png.write(to: docs.appendingPathComponent(name))
        evidence.append(["file": name, "width": Double(width), "height": Double(height), "pngBytes": png.count])
        window.rootViewController = UIViewController()
    }
    private func fixture(running: Bool) -> (AssistantBlock, SubAgentRunDigest) {
        let block = AssistantBlock()
        block.toolStatus = running ? .running : .success
        var model = HelperModelIdentity()
        model.effectiveModelId = "gpt-5.4"
        model.effectiveModelName = "gpt-5.4"
        model.effectiveSource = "request"
        block.helperModel = model
        if running {
            block.content = "◐ Helper · 检查请求兼容性并报告验证结果 · shell_execute · 执行回归验证 · 0:01"
        } else {
            block.content = "{\"status\":\"completed\",\"elapsed_s\":1,\"result\":\"\",\"child_session_id\":\"fixture-child\",\"agent\":\"兼容性验证\"}"
        }
        var digest = SubAgentRunDigest()
        digest.calls = [
            .init(id: "read", tool: "file_read", title: "配置", state: .ok, duration: 0.3),
            .init(id: "edit", tool: "file_edit", title: "请求适配", state: .ok, duration: 1.2),
            .init(id: "test", tool: "shell_execute", title: "执行回归验证", state: running ? .running : .ok, duration: running ? nil : 2.4),
        ]
        digest.turns = 3
        digest.tokensIn = 12345
        digest.tokensOut = 2345
        digest.cacheRead = 4096
        return (block, digest)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "SubAgentReferenceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func writeResult(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: docs.appendingPathComponent("reference-ui-result.json"))
    }
}
