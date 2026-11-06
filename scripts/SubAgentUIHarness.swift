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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("子代理任务").font(.headline)
            ZeSubAgentCompactCard(record: record, open: {}, stop: {}, resume: {})
            ZeSubAgentThumbnail(record: record)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if record.status.isActive { ZeSubAgentAnimatedRim(cornerRadius: 8) }
                }
            ZeSubAgentRunStats(record: record)
            ZeSubAgentToolHistory(record: record)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        .environment(\.colorScheme, scheme)
        // UIKit hosts do not supply a SwiftUI App scene; model the active scene explicitly.
        .environment(\.scenePhase, .active)
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
            for _ in 0..<50 {
                if UIApplication.shared.applicationState == .active { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try require(UIApplication.shared.applicationState == .active, "Harness application did not become active")
            for scheme in [ColorScheme.light, .dark] {
                for status in [ZeSubAgentStatus.running, .completed] {
                    try await capture(window: window, scheme: scheme, status: status, animationDisabledFixture: false)
                }
                try await capture(window: window, scheme: scheme, status: .running, animationDisabledFixture: true)
            }
            try writeResult(["success": true, "renderer": "UIHostingController + visible UIWindow.drawHierarchy", "screenshots": evidence,
                             "scope": "Production compact card, thumbnail, stats, history, narrow layout and Core Animation lifecycle; static-rim uses a compositor animation-disabled fixture, not OS Reduce Motion; no device FPS assertion"])
        } catch {
            try? writeResult(["success": false, "error": error.localizedDescription, "screenshots": evidence])
        }
    }

    @MainActor private func capture(window: UIWindow, scheme: ColorScheme, status: ZeSubAgentStatus, animationDisabledFixture: Bool) async throws {
        let record = fixture(status: status)
        let width: CGFloat = 320
        let height: CGFloat = min(window.bounds.height, 800)
        let host = UIHostingController(rootView: SubAgentScreenshot(record: record, scheme: scheme))
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
        try require(fitting.width <= width - 24 + 1, "Stats chips exceed narrow content width: \(fitting)")
        try require(fitting.height > 0 && fitting.height < 500, "Invalid stats layout: \(fitting)")

        let layers = allLayers(host.view.layer)
        let rims = layers.compactMap { $0 as? CAGradientLayer }.filter { $0.type == .conic }
        if animationDisabledFixture {
            let surfaces = allViews(host.view).compactMap { $0 as? ZeSubAgentRimLayerView }
            try require(!surfaces.isEmpty, "Static-rim fixture found no production rim surface")
            for surface in surfaces {
                surface.animates = false
                surface.updateAnimation()
            }
            CATransaction.flush()
        }
        let rotations = rims.filter { $0.animation(forKey: "rimRotation") != nil }.count
        if status.isActive {
            try require(!rims.isEmpty, "Running card has no UIKit conic rim")
            try require(animationDisabledFixture ? rotations == 0 : rotations > 0, "Compositor disabled-fixture / active animation contract failed")
        } else {
            try require(rims.isEmpty && rotations == 0, "Completed card retained an active rim")
        }
        let name = "subagent-\(scheme == .dark ? "dark" : "light")-\(status.rawValue)\(animationDisabledFixture ? "-static-rim" : "").png"
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
                         "conicRims": rims.count, "runningAnimations": rotations, "animationDisabledFixture": animationDisabledFixture,
                         "detachedAnimations": rims.filter { $0.animation(forKey: "rimRotation") != nil }.count])
    }

    private func fixture(status: ZeSubAgentStatus) -> ZeSubAgentRecord {
        let capturedAt = Date()
        let startedAt = capturedAt.addingTimeInterval(-1)
        let steps = [
            ZeSubAgentStep(id: "read", title: "配置", icon: "doc.text", content: "检查配置与依赖，发现 3 个待更新项目。", state: "success", duration: 0.3, toolName: "file_read"),
            ZeSubAgentStep(id: "edit", title: "请求适配", icon: "square.and.pencil", content: "已保存协议适配变更。", state: "success", duration: 1.2, toolName: "file_edit"),
            ZeSubAgentStep(id: "test", title: "执行回归验证", icon: "terminal", content: status.isActive ? "正在检查模型请求参数…" : "11 项回归检查完成。", state: status.isActive ? "running" : "success", duration: status.isActive ? nil : 2.4, toolName: "shell_execute"),
        ]
        var record = ZeSubAgentRecord(id: "fixture-agent", parentId: "fixture-parent", rootSessionId: "fixture-root", nickname: "兼容性验证", depth: 1,
                                      status: status, revision: 1, createdAt: startedAt, updatedAt: capturedAt,
                                      prompt: "检查请求兼容性并报告验证结果", output: "", error: nil, childSessionId: "fixture-child",
                                      inputTokens: 12345, outputTokens: 2345, modelEntryReference: "long-model-layout", steps: steps)
        record.startedAt = startedAt
        record.finishedAt = status.isActive ? nil : capturedAt
        record.requestModelId = "gpt-5.4"
        record.requestModelName = "gpt-5.4"
        record.turnCount = 3
        record.cacheReadTokens = 4096
        return record
    }

    private func allViews(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(allViews)
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
