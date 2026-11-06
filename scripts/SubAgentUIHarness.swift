// Appended to extracted production declarations so private view types remain
// private in shipping code. Only the configuration lookup is a fixture.
private struct HarnessModel { let displayName: String }
private struct HarnessEntry { let model: HarnessModel }
private final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func entry(for reference: String) -> HarnessEntry? {
        HarnessEntry(model: HarnessModel(displayName: "自定义模型-" + String(repeating: "LongModelName", count: 10)))
    }
}

private struct SubAgentScreenshot: View {
    let record: ZeSubAgentRecord
    let scheme: ColorScheme
    let reducedMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("子代理任务").font(.headline)
            ZeSubAgentBlackCard(record: record, compact: true)
            ZeSubAgentRunStats(record: record)
            ZeSubAgentToolHistory(record: record)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, scheme)
        .environment(\.scenePhase, .active)
        .environment(\.accessibilityReduceMotion, reducedMotion)
        .ignoresSafeArea()
    }
}

@main
private final class SubAgentUIHarness: UIResponder, UIApplicationDelegate {
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
            for scheme in [ColorScheme.light, .dark] {
                for status in [ZeSubAgentStatus.running, .completed] {
                    try await capture(window: window, scheme: scheme, status: status, reducedMotion: false)
                }
                try await capture(window: window, scheme: scheme, status: .running, reducedMotion: true)
            }
            try writeResult(["success": true, "renderer": "UIHostingController + visible UIWindow.drawHierarchy", "screenshots": evidence,
                             "scope": "Production cards, stats, history, narrow layout and Core Animation lifecycle; no device FPS assertion"])
        } catch {
            try? writeResult(["success": false, "error": error.localizedDescription, "screenshots": evidence])
        }
    }

    @MainActor private func capture(window: UIWindow, scheme: ColorScheme, status: ZeSubAgentStatus, reducedMotion: Bool) async throws {
        let record = fixture(status: status)
        let width: CGFloat = 320
        let height: CGFloat = min(window.bounds.height, 800)
        let host = UIHostingController(rootView: SubAgentScreenshot(record: record, scheme: scheme, reducedMotion: reducedMotion))
        host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        window.rootViewController = host
        window.frame.size = CGSize(width: width, height: height)
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Allow the hosting hierarchy to attach UIKit-backed layers and commit
        // a real CA frame. No ImageRenderer: it omits UIViewRepresentable rims.
        try await Task.sleep(nanoseconds: 350_000_000)
        host.view.layoutIfNeeded()
        CATransaction.flush()

        let stats = UIHostingController(rootView: ZeSubAgentRunStats(record: record))
        let fitting = stats.sizeThatFits(in: CGSize(width: width - 24, height: 1000))
        try require(fitting.width <= width - 24 + 1, "Long model chip exceeds narrow content width: \(fitting)")
        try require(fitting.height > 0 && fitting.height < 500, "Invalid stats layout: \(fitting)")

        let layers = allLayers(host.view.layer)
        let rims = layers.compactMap { $0 as? CAGradientLayer }.filter { $0.type == .conic }
        let rotations = rims.filter { $0.animation(forKey: "rimRotation") != nil }.count
        if status.isActive {
            try require(!rims.isEmpty, "Running card has no UIKit conic rim")
            try require(reducedMotion ? rotations == 0 : rotations > 0, "Reduce Motion / active animation contract failed")
        } else {
            try require(rims.isEmpty && rotations == 0, "Completed card retained an active rim")
        }
        let name = "subagent-\(scheme == .dark ? "dark" : "light")-\(status.rawValue)\(reducedMotion ? "-reduced-motion" : "").png"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var drew = false
        let image = renderer.image { _ in
            drew = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try require(drew, "Visible window drawHierarchy failed")
        guard let png = image.pngData(), png.count > 3000 else { throw failure("Empty screenshot") }
        try png.write(to: docs.appendingPathComponent(name))

        // Removing the surface from its window must stop compositor work.
        host.view.removeFromSuperview()
        window.rootViewController = UIViewController()
        try require(rims.allSatisfy { $0.animation(forKey: "rimRotation") == nil }, "Detached card retained animation")
        evidence.append(["file": name, "width": Double(width), "height": Double(height), "pngBytes": png.count,
                         "statsWidth": Double(fitting.width), "statsHeight": Double(fitting.height),
                         "conicRims": rims.count, "runningAnimations": rotations, "reducedMotion": reducedMotion,
                         "detachedAnimations": rims.filter { $0.animation(forKey: "rimRotation") != nil }.count])
    }

    private func fixture(status: ZeSubAgentStatus) -> ZeSubAgentRecord {
        let steps = [
            ZeSubAgentStep(id: "read", title: "读取文件 · 配置", icon: "doc.text.magnifyingglass", content: "检查配置与依赖，发现 3 个待更新项目。", state: "success", duration: 0.3),
            ZeSubAgentStep(id: "edit", title: "编辑文件 · 请求适配", icon: "pencil.line", content: "已保存协议适配变更。", state: "success", duration: 1.2),
            ZeSubAgentStep(id: "test", title: "命令 · 执行回归验证", icon: "terminal", content: status.isActive ? "正在检查模型请求参数…" : "11 项回归检查完成。", state: status.isActive ? "running" : "success", duration: status.isActive ? nil : 2.4),
        ]
        var record = ZeSubAgentRecord(id: "fixture-agent", parentId: "fixture-parent", rootSessionId: "fixture-root", nickname: "兼容性验证", depth: 1,
                                      status: status, revision: 1, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 1),
                                      prompt: "检查请求兼容性并报告验证结果", output: "", error: nil, childSessionId: "fixture-child",
                                      inputTokens: 12345, outputTokens: 2345, modelEntryReference: "long-model-layout", steps: steps)
        record.turnCount = 3
        record.cacheReadTokens = 4096
        return record
    }

    private func allLayers(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(allLayers)
    }
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "SubAgentUIHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func writeResult(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: docs.appendingPathComponent("subagent-ui-result.json"))
    }
}
