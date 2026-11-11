import SwiftUI
import UIKit

// Configuration fixtures only. SessionModelDisplay, brand rendering and all
// chat chrome are extracted unchanged from their production source files.
enum ProviderType: String, CaseIterable {
    case openAI, anthropic, gemini, antigravity, openRouter, openAIResponses
    case xAI, kimiCode, githubCopilot, workBuddy, unsupported
    var builtInModels: [String] { [] } // Only used by hidden unsupported type's subtitle.
}
enum ProviderCredential {
    case apiKey, oauth, chatGPTWeb
    var displayName: String { self == .apiKey ? "API Key" : "OAuth" }
}
struct ProviderInstance {
    var id: String
    var label: String
    var providerType: ProviderType
    var customBaseURL: String? = nil
    var isEnabled = true
    var hasAnyCredential = true
    var credentialType: ProviderCredential = .apiKey
}
struct FixtureModel { var id: String; var displayName: String }
struct ModelEntry {
    var id: String; var providerInstanceId: String; var model: FixtureModel
    var isHidden = false
}
struct FixtureGroup { var name: String; var memberEntryIds: [String] }
enum FixtureSource { case directEntry(String, String?); case group(String, String) }
struct FixtureBinding { var primarySource: FixtureSource }
final class ProviderConfigStore: ObservableObject {
    static let shared = ProviderConfigStore()
    var authRevision = 0
    var instances: [String: ProviderInstance] = [:]
    var entries: [String: ModelEntry] = [:]
    var groups: [String: FixtureGroup] = [:]
    var bindings: [String: FixtureBinding] = [:]
    var defaultPrimaryGroupId: String?
    func instance(for id: String) -> ProviderInstance? { instances[id] }
    func entry(for id: String) -> ModelEntry? { entries[id] }
    func group(for id: String) -> FixtureGroup? { groups[id] }
    func binding(for id: String) -> FixtureBinding? { bindings[id] }
    func visibleEntries(for id: String) -> [ModelEntry] { entries.values.filter { $0.providerInstanceId == id && !$0.isHidden } }
}
enum ProviderKeychainHelper {
    static func loadAPIKey(instanceId: String) -> String? { "fixture-key-display-only" }
    static func loadOAuthString(instanceId: String, account: String) -> String? { nil }
}
final class FixtureOAuthManager {
    static let shared = FixtureOAuthManager()
    func isAuthenticated(instanceId: String) -> Bool { true }
}
typealias ChatGPTWebOAuthManager = FixtureOAuthManager
typealias ClaudeOAuthManager = FixtureOAuthManager
typealias GeminiOAuthManager = FixtureOAuthManager
typealias CodexOAuthManager = FixtureOAuthManager
typealias AntigravityOAuthManager = FixtureOAuthManager
typealias OpenRouterOAuthManager = FixtureOAuthManager
typealias XAIOAuthManager = FixtureOAuthManager
typealias KimiOAuthManager = FixtureOAuthManager
typealias WorkBuddyOAuthManager = FixtureOAuthManager
typealias GitHubCopilotOAuthManager = FixtureOAuthManager

private let voiceIDs = ["elevenlabs", "deepgram", "azure-tts", "minimax", "alibaba", "doubao", "xunfei", "mimo"]

private struct SettingsRowsGallery: View {
    let adding: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(adding ? "添加 AI 服务商" : "AI 服务商").font(.headline)
            ForEach(ProviderType.allCases.filter { $0 != .unsupported && $0 != .antigravity }, id: \.self) { type in
                Group {
                    if adding {
                        ProductionAddProviderRow(type: type)
                    } else {
                        InstanceRow(instance: ProviderInstance(id: type.rawValue, label: type.displayName, providerType: type,
                            credentialType: type == .workBuddy || type == .githubCopilot ? .oauth : .apiKey))
                    }
                }.padding(12).background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(16).frame(width: 390, alignment: .leading)
            .background(Color(UIColor.systemGroupedBackground))
    }
}

private struct BrandGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务商本地图标 · 18 / 25 / 32 pt").font(.headline)
            ForEach(ProviderType.allCases, id: \.self) { type in
                HStack(spacing: 18) {
                    ForEach([18, 25, 32], id: \.self) { size in
                        ProviderBrandIcon(type: type, size: CGFloat(size)).frame(width: 40)
                    }
                    Text(type.displayName).font(.caption)
                }.frame(height: 35)
            }
            Text("语音服务商").font(.headline)
            ForEach(voiceIDs, id: \.self) { id in
                HStack(spacing: 18) {
                    VoiceProviderBrandIcon(templateID: id, size: 25).frame(width: 40)
                    Text(id).font(.caption)
                }.frame(height: 29)
            }
        }.padding(16).frame(width: 390, alignment: .leading)
            .background(Color(UIColor.systemBackground))
    }
}

private struct BadgeGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前服务商圆形图标 · 展开 / 收起").font(.headline)
            ForEach(ProviderType.allCases, id: \.self) { type in
                HStack {
                    ForEach([false, true], id: \.self) { collapsed in
                        NavigationStatusCapsule(provider: ProviderInstance(id: type.rawValue, label: type.displayName, providerType: type),
                                                isCollapsed: collapsed, onToggle: {})
                    }
                    Text(type.displayName).font(.caption)
                }
            }
            HStack {
                NavigationStatusCapsule(provider: nil, isCollapsed: false, onToggle: {})
                Text("尚未选择服务商").font(.caption)
            }
        }.padding(16).frame(width: 390, alignment: .leading)
            .background(Color(UIColor.systemBackground))
    }
}

private struct ChromeFixture: View {
    let provider: ProviderInstance
    @State private var inset: CGFloat = 0
    @State private var collapsed = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("当前会话服务商应随选择即时更新").font(.title2)
                        .padding(20).background(Color.blue.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
                    ForEach(0..<12) { row in
                        Text("消息 \(row + 1)：保留聊天滚动与模型切换，顶部以半透明材质平滑过渡。")
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The production UICollectionView automatically adjusts its
                // content inset. Match that in this SwiftUI-only fixture while
                // keeping its viewport extended behind the navigation bar.
                .padding(.top, inset)
                .padding(.horizontal, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if collapsed {
                        NavigationStatusCapsule(provider: provider, isCollapsed: true) { collapsed.toggle() }
                    } else {
                        VStack(spacing: 0) {
                            Text("查询广东油价").font(.system(size: 12, weight: .semibold))
                            Text("\(provider.label) · GPT 6.1 Sol").font(.system(size: 9))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) { Image(systemName: "line.3.horizontal") }
                ToolbarItem(placement: .navigationBarTrailing) { Image(systemName: "gearshape") }
            }
            .modifier(NavBarStyleModifier(topSafeAreaInset: $inset, providerBadge: collapsed ? nil :
                AnyView(NavigationStatusCapsule(provider: provider, isCollapsed: false) { collapsed.toggle() })))
        }
    }
}

// Deterministic backdrops follow the actual scroll offset. White Chinese text
// content is the primary reference; black colored dots expose material tint.
private final class FrostTailBackdrop: UIView {
    var blackPattern = false
    var contentStart: CGFloat = 0
    var scrollOffset: CGFloat = 0
    override func draw(_ rect: CGRect) {
        (blackPattern ? UIColor.black : UIColor.white).setFill()
        UIRectFill(bounds)
        let colors: [UIColor] = [.systemPink, .systemCyan, .systemYellow, .systemGreen]
        for row in 0..<50 {
            let y = contentStart + CGFloat(row) * 28 - scrollOffset
            guard y > -28 && y < bounds.height else { continue }
            if blackPattern {
                for column in 0..<4 {
                    colors[(row + column) % colors.count].setFill()
                    UIBezierPath(ovalIn: CGRect(x: CGFloat(column) * 17 + 12, y: y + 5, width: 9, height: 9)).fill()
                }
            }
            let text = blackPattern ? "彩点与文字 \(row) Aa 123" : "这是一段连续中文消息，观察顶部文字自然模糊。"
            (text as NSString).draw(at: CGPoint(x: blackPattern ? 90 : 16, y: y), withAttributes: [
                .font: UIFont.systemFont(ofSize: 15),
                .foregroundColor: blackPattern ? UIColor.white : UIColor.black
            ])
        }
    }
}

@MainActor private final class ProviderChromeDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        Task { @MainActor in await run() }
        return true
    }

    private func controllers(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap(controllers)
    }

    private func descendants(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func frostedOverlay(_ navigation: UINavigationController) -> UIView? {
        navigation.navigationBar.superview?.subviews.first {
            $0.accessibilityIdentifier == "chat-progressive-frost"
        }
    }

    private func providerBadgeView(_ navigation: UINavigationController) -> UIView? {
        navigation.navigationBar.superview?.subviews.first { $0 is UIContentView && $0.bounds.width == 24 && $0.bounds.height == 24 }
    }

    private func imageContrast(_ image: UIImage) -> Int {
        guard let source = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard rendered else { return 0 }
        var minimum = 255, maximum = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let intensity = (Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])) / 3
            minimum = min(minimum, intensity)
            maximum = max(maximum, intensity)
        }
        return max(0, maximum - minimum)
    }

    private func opaqueExtent(_ image: UIImage) -> CGSize {
        guard let source = image.cgImage else { return .zero }
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return .zero }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return CGSize(width: CGFloat(max(0, maxX - minX + 1)) / image.scale,
                      height: CGFloat(max(0, maxY - minY + 1)) / image.scale)
    }

    private func hasNoShadow(_ appearance: UINavigationBarAppearance?) -> Bool {
        // Apple's UIBarAppearance.shadowColor contract: nil and clear BOTH
        // mean no shadow. UIKit may normalize a clear assignment to nil.
        // Require an actual appearance and no opaque custom shadow image.
        guard let appearance else { return false }
        let imageIsEmpty = appearance.shadowImage == nil || appearance.shadowImage?.size == .zero
        return imageIsEmpty && (appearance.shadowColor == nil || appearance.shadowColor?.cgColor.alpha == 0)
    }

    private func chromaticCoverage(_ image: UIImage) -> Double {
        guard let source = image.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 256,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard rendered else { return 0 }
        var colored = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let values = [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
            if (values.max() ?? 0) - (values.min() ?? 0) > 40 { colored += 1 }
        }
        return Double(colored) / 4096
    }

    private func greenPixelCount(_ image: UIImage, around point: CGPoint) -> Int {
        guard let source = image.cgImage else { return 0 }
        let rect = CGRect(x: max(0, point.x - 15) * image.scale, y: max(0, point.y - 15) * image.scale,
                          width: 30 * image.scale, height: 30 * image.scale)
        guard let crop = source.cropping(to: rect) else { return 0 }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if green > red + 25 && green > blue + 10 { count += 1 }
        }
        return count
    }

    private func run() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        var failures: [String] = []
        var diagnostics: [[String: Any]] = []
        var screenshots: [String] = []
        func progress(_ stage: String) {
            let record: [String: Any] = ["stage": stage, "checks": checks.count, "failures": failures,
                                       "screenshots": screenshots, "time": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: docs.appendingPathComponent("provider-chrome-progress.json"), options: .atomic)
            }
        }
        func check(_ pass: Bool, _ name: String) throws {
            guard pass else { failures.append(name); progress("FAILED: " + name); return }
            checks.append(name)
            progress(name)
        }
        func captureComparisons(host: UIViewController, navigation: UINavigationController, scroll: UIScrollView,
                                theme: String, stage: String) async throws {
            guard let frost = frostedOverlay(navigation), let frostHost = frost.superview else {
                try check(false, "Production progressive frost exists for comparison: \(theme)-\(stage)")
                return
            }
            let bar = navigation.navigationBar
            let bottom = bar.convert(bar.bounds, to: frostHost).maxY
            let legacy = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            legacy.frame = frost.frame
            legacy.isUserInteractionEnabled = false
            let mask = CAGradientLayer()
            mask.frame = legacy.bounds
            mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor,
                           UIColor.black.withAlphaComponent(0.72).cgColor, UIColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: Double(max(0, bottom - 8) / legacy.bounds.height)),
                              NSNumber(value: Double((bottom + 9) / legacy.bounds.height)), 1]
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
            legacy.layer.mask = mask
            legacy.isHidden = true
            frostHost.insertSubview(legacy, aboveSubview: frost)
            let backdrop = FrostTailBackdrop(frame: frostHost.bounds)
            backdrop.isOpaque = true
            backdrop.isUserInteractionEnabled = false
            backdrop.contentStart = bottom + 34
            backdrop.scrollOffset = scroll.contentOffset.y
            frostHost.insertSubview(backdrop, belowSubview: frost)
            defer {
                frost.isHidden = false
                legacy.removeFromSuperview()
                backdrop.removeFromSuperview()
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
            for background in ["white-text", "black-pattern"] {
                backdrop.blackPattern = background == "black-pattern"
                backdrop.setNeedsDisplay()
                for variant in ["legacy", "production"] {
                    frost.isHidden = variant == "legacy"
                    legacy.isHidden = variant != "legacy"
                    try await Task.sleep(nanoseconds: 250_000_000)
                    var drawn = false
                    let image = renderer.image { _ in
                        drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    let file = "provider-chrome-tail-\(theme)-\(background)-\(stage)-\(variant).png"
                    try image.pngData()!.write(to: docs.appendingPathComponent(file))
                    screenshots.append(file)
                    diagnostics.append(["screenshot": file, "variant": variant, "background": background,
                                        "stage": stage, "scrollOffset": scroll.contentOffset.y, "barBottom": bottom,
                                        "productionView": String(describing: type(of: frost)),
                                        "visibleEffectViews": descendants(variant == "legacy" ? legacy : frost)
                                            .compactMap { $0 as? UIVisualEffectView }.count])
                    try check(drawn && imageContrast(image) > 24,
                              "Frost comparison renders reference content in actual navigation: \(theme)-\(background)-\(stage)-\(variant)")
                }
            }
        }
        func write(_ success: Bool, _ error: String? = nil) {
            var result: [String: Any] = ["success": success && failures.isEmpty, "checks": checks, "failures": failures,
                "diagnostics": diagnostics, "screenshots": screenshots,
                "scope": "Actual production components on simulator; configuration fixtures; no physical-device or account balance verification"]
            if let error { result["error"] = error }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: docs.appendingPathComponent("provider-chrome-result.json"), options: .atomic)
            }
        }
        do {
            progress("begin production tests")
            let probe = UINavigationBarAppearance()
            probe.configureWithDefaultBackground()
            diagnostics.append(["fixture": "shadow-setter-default", "shadow": probe.shadowColor?.description ?? "nil"])
            probe.shadowColor = UIColor.clear
            diagnostics.append(["fixture": "shadow-setter-clear", "shadow": probe.shadowColor?.description ?? "nil"])
            probe.shadowImage = nil
            probe.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            probe.backgroundColor = UIColor.white.withAlphaComponent(0.25)
            let probeItem = UINavigationItem()
            probeItem.standardAppearance = probe
            diagnostics.append(["fixture": "shadow-setter-copied-to-item", "shadow": probeItem.standardAppearance?.shadowColor?.description ?? "nil"])
            try check(hasNoShadow(probeItem.standardAppearance), "UIKit nil/clear shadow follows Apple's documented no-shadow contract")
            let store = ProviderConfigStore()
            let open = ProviderInstance(id: "open", label: "自定义 OpenAI", providerType: .openAI)
            let buddy = ProviderInstance(id: "buddy", label: "Wbnew", providerType: .workBuddy)
            store.instances = ["open": open, "buddy": buddy]
            store.entries = ["e1": ModelEntry(id: "e1", providerInstanceId: "open", model: FixtureModel(id: "gpt", displayName: "GPT")),
                             "e2": ModelEntry(id: "e2", providerInstanceId: "buddy", model: FixtureModel(id: "auto", displayName: "Auto"))]
            store.groups = ["g1": FixtureGroup(name: "默认组", memberEntryIds: ["e1", "e2"]),
                            "g2": FixtureGroup(name: "WorkBuddy 组", memberEntryIds: ["e2"])]
            store.defaultPrimaryGroupId = "g1"
            let display = SessionModelDisplay(store: store)
            try check(display.resolvedInstanceAndModel(for: nil)?.instance.id == "open", "Draft uses default group's actual provider")
            try check(SessionModelDisplay(store: store, draftGroupId: "g2").resolvedInstanceAndModel(for: nil)?.instance.id == "buddy", "Draft explicit group overrides default provider")
            store.bindings["chat"] = FixtureBinding(primarySource: .directEntry("e2", nil))
            try check(display.resolvedInstanceAndModel(for: "chat")?.instance.id == "buddy", "Direct conversation binding resolves selected WorkBuddy instance")
            store.bindings["chat"] = FixtureBinding(primarySource: .directEntry("e1", nil))
            try check(display.resolvedInstanceAndModel(for: "chat")?.instance.id == "open", "Switching direct selection updates provider")
            store.bindings["chat"] = FixtureBinding(primarySource: .group("g1", "e2"))
            try check(display.resolvedInstanceAndModel(for: "chat")?.instance.id == "buddy", "Bound group uses selected entry rather than group first member")
            store.instances["open"]?.isEnabled = false
            try check(display.resolvedInstanceAndModel(for: nil)?.instance.id == "buddy", "Draft group skips disabled instance")
            store.instances["open"]?.isEnabled = true
            store.entries["e1"]?.isHidden = true
            try check(display.resolvedInstanceAndModel(for: nil)?.instance.id == "buddy", "Draft group skips hidden model")
            store.entries["e1"]?.isHidden = false
            store.instances["open"]?.hasAnyCredential = false
            try check(display.resolvedInstanceAndModel(for: nil)?.instance.id == "buddy", "Draft group skips missing credentials when usable provider exists")
            store.bindings["missing"] = FixtureBinding(primarySource: .directEntry("deleted", nil))
            try check(display.resolvedInstanceAndModel(for: "missing") == nil, "Deleted binding yields no provider instead of unrelated account")
            store.defaultPrimaryGroupId = nil
            try check(display.resolvedInstanceAndModel(for: nil) == nil, "Empty draft has no invented provider")

            try check(ProviderBrandIcon.assetName(type: .openAI, baseURL: "https://api.deepseek.com/v1") == "ProviderBrandDeepSeek", "Known compatible hostname uses actual vendor mark")
            try check(ProviderBrandIcon.assetName(type: .openAI, baseURL: "https://api.deepseek.com.evil.test/v1") == "ProviderBrandOpenAI", "Vendor hostname matching respects DNS boundary")
            try check(ProviderBrandIcon.assetName(type: .anthropic, baseURL: "https://unknown.example/v1") == "ProviderBrandAnthropic", "Unknown compatible host retains selected protocol mark")
            for type in ProviderType.allCases {
                if let asset = ProviderBrandIcon.assetName(type: type) {
                    try check(UIImage(named: asset) != nil, "Bundled vendor asset loads: \(type.rawValue)")
                    try check(UIImage(named: asset)?.renderingMode != .alwaysTemplate, "Vendor asset preserves original artwork colors: \(type.rawValue)")
                }
            }
            try check(UIImage(named: "WorkBuddy") != nil, "Existing WorkBuddy asset loads")
            for id in voiceIDs {
                let asset = VoiceProviderBrandIcon.assetName(templateID: id)
                try check(asset.flatMap { UIImage(named: $0) } != nil, "Voice vendor asset loads: \(id)")
            }
            var toggleCount = 0
            NavigationStatusCapsule(provider: buddy, isCollapsed: false, onToggle: { toggleCount += 1 }).onToggle()
            NavigationStatusCapsule(provider: buddy, isCollapsed: true, onToggle: { toggleCount += 1 }).onToggle()
            try check(toggleCount == 2, "Both badge variants preserve supplied toggle callbacks")
            var badgeImages: [Data] = []
            for type in [ProviderType.openAI, .anthropic, .workBuddy, .githubCopilot] {
                let badge = NavigationStatusCapsule(provider: ProviderInstance(id: type.rawValue, label: type.displayName, providerType: type),
                                                    isCollapsed: false, onToggle: {})
                let renderer = ImageRenderer(content: badge.environment(\.colorScheme, .light))
                renderer.scale = 3
                guard let image = renderer.uiImage, let bytes = image.pngData() else {
                    throw NSError(domain: "ProviderChrome", code: -4)
                }
                try check(image.size.width == image.size.height && image.size.width == 24,
                          "Provider badge keeps square 24-point bounds for circular mask: \(type.rawValue)")
                badgeImages.append(bytes)
            }
            try check(Set(badgeImages).count == badgeImages.count, "Different selected providers render distinct badge artwork")
            for scheme: ColorScheme in [.light, .dark] {
                let openAIRenderer = ImageRenderer(content: ProviderBrandIcon(type: .openAI, size: 32).environment(\.colorScheme, scheme))
                openAIRenderer.scale = 3
                if let image = openAIRenderer.uiImage {
                    let coverage = chromaticCoverage(image)
                    diagnostics.append(["fixture": "openai-original-color-\(scheme)", "chromaticCoverage": coverage])
                    try check(coverage > 0.25, "OpenAI retains its published green avatar instead of template tint: \(scheme)")
                } else {
                    try check(false, "OpenAI avatar produces an image: \(scheme)")
                }
                let renderer = ImageRenderer(content: ProviderBrandIcon(type: .gemini, size: 32).environment(\.colorScheme, scheme))
                renderer.scale = 3
                if let image = renderer.uiImage {
                    let extent = opaqueExtent(image)
                    diagnostics.append(["fixture": "gemini-32-\(scheme)", "opaqueWidth": extent.width, "opaqueHeight": extent.height])
                    try check(extent.width >= 24 && extent.height >= 24,
                              "Gemini renders its full star silhouette rather than a tiny dot: \(scheme)")
                } else {
                    try check(false, "Gemini icon produces an image: \(scheme)")
                }
            }

            // Exercise the actual controller's scoped apply/restore contract.
            let unrelated = UINavigationBar()
            let unrelatedShadow = unrelated.standardAppearance.shadowColor
            let owner = UIViewController()
            let previous = UINavigationBarAppearance()
            previous.shadowColor = .red
            owner.navigationItem.standardAppearance = previous
            let nav = UINavigationController(rootViewController: owner)
            let controller = ChatNavigationBarAppearance.Controller()
            owner.addChild(controller)
            owner.view.addSubview(controller.view)
            controller.didMove(toParent: owner)
            guard let window else { throw NSError(domain: "ProviderChrome", code: -1) }
            window.rootViewController = nav
            window.makeKeyAndVisible()
            nav.loadViewIfNeeded()
            nav.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 450_000_000)
            let beforeShadow = owner.navigationItem.standardAppearance?.shadowColor?.description ?? "nil"
            controller.applyIfNeeded()
            diagnostics.append([
                "fixture": "synthetic-mounted",
                "controllerNavigationFound": controller.navigationController != nil,
                "controllerParent": controller.parent.map { String(describing: type(of: $0)) } ?? "nil",
                "topIsOwner": nav.topViewController === owner,
                "beforeApplyShadow": beforeShadow,
                "standardShadow": owner.navigationItem.standardAppearance?.shadowColor?.description ?? "nil",
                "scrollShadow": owner.navigationItem.scrollEdgeAppearance?.shadowColor?.description ?? "nil"
            ])
            try check(hasNoShadow(owner.navigationItem.standardAppearance), "Chat item removes separator")
            try check(owner.navigationItem.standardAppearance?.backgroundEffect == nil &&
                      (owner.navigationItem.standardAppearance?.backgroundColor?.cgColor.alpha ?? 0) == 0,
                      "Native navigation background is clear so no solid rectangular plate remains")
            let syntheticFrost = frostedOverlay(nav)
            try check(syntheticFrost != nil && syntheticFrost?.isUserInteractionEnabled == false,
                      "Separate gradient frost exists below toolbar without intercepting touches")
            try check(syntheticFrost.map { descendants($0).contains { ($0 as? UIVisualEffectView)?.effect != nil } } == true || UIAccessibility.isReduceTransparencyEnabled,
                      "Gradient overlay uses real UIKit backdrop blur")
            try check(unrelated.standardAppearance.shadowColor == unrelatedShadow, "Unrelated navigation bar appearance is unchanged")
            var expandedBadge = NavigationStatusCapsule(provider: open, isCollapsed: false) {}
            expandedBadge = NavigationStatusCapsule(provider: open, isCollapsed: false) {
                controller.updateBadge(nil)
                controller.applyIfNeeded()
            }
            controller.updateBadge(AnyView(expandedBadge))
            controller.applyIfNeeded()
            nav.view.layoutIfNeeded()
            let mountedBadge = providerBadgeView(nav)
            try check(mountedBadge != nil && nav.topViewController === owner,
                      "Mounted provider content view leaves navigation's top controller unchanged")
            if let badgeView = mountedBadge {
                let hitPoint = badgeView.convert(CGPoint(x: badgeView.bounds.midX, y: badgeView.bounds.midY), to: nav.view)
                let hit = nav.view.hitTest(hitPoint, with: nil)
                try check(hit === badgeView || hit?.isDescendant(of: badgeView) == true,
                          "Visible provider badge receives hit testing above the noninteractive frost")
            }
            expandedBadge.onToggle()
            try check(providerBadgeView(nav) == nil && nav.topViewController === owner,
                      "Expanded badge callback removes its hosted view when collapsed")
            let collapsedBadge = NavigationStatusCapsule(provider: buddy, isCollapsed: true) {
                controller.updateBadge(AnyView(NavigationStatusCapsule(provider: buddy, isCollapsed: false, onToggle: {})))
                controller.applyIfNeeded()
            }
            collapsedBadge.onToggle()
            try check(providerBadgeView(nav) != nil && nav.topViewController === owner,
                      "Collapsed badge callback restores provider host on expand")
            let hostBeforeSwitch = providerBadgeView(nav)
            controller.updateBadge(AnyView(NavigationStatusCapsule(provider: open, isCollapsed: false, onToggle: {})))
            controller.applyIfNeeded()
            let hostAfterSwitch = providerBadgeView(nav)
            try check(hostBeforeSwitch === hostAfterSwitch && nav.topViewController === owner, "Switching provider reuses the content view without changing navigation ownership")
            controller.restore()
            try check(owner.navigationItem.standardAppearance?.shadowColor == UIColor.red, "Leaving chat restores prior navigation item appearance")
            try check(frostedOverlay(nav) == nil, "Leaving chat removes its gradient frost overlay")
            try check(providerBadgeView(nav) == nil && nav.topViewController === owner, "Leaving chat removes the provider badge view without changing navigation ownership")

            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                let scheme: ColorScheme = dark ? .dark : .light
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                for (name, view) in [("brands", AnyView(BrandGallery())), ("badges", AnyView(BadgeGallery())),
                                     ("instances", AnyView(SettingsRowsGallery(adding: false))),
                                     ("add-provider", AnyView(SettingsRowsGallery(adding: true)))] {
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                    renderer.scale = 3
                    guard let image = renderer.uiImage, let data = image.pngData() else { throw NSError(domain: "ProviderChrome", code: -2) }
                    let file = "provider-chrome-\(name)-\(theme).png"
                    try data.write(to: docs.appendingPathComponent(file))
                    screenshots.append(file)
                    try check(imageContrast(image) > 24, "Gallery contains visible rendered content: \(name)-\(theme)")
                }
                for width: CGFloat in [320, 390] {
                    for large in [false, true] {
                        progress("mount navbar \(theme)-\(Int(width))-\(large)")
                        let fixture = ChromeFixture(provider: dark ? buddy : open)
                            .environment(\.colorScheme, scheme)
                            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
                        let host = UIHostingController(rootView: fixture)
                        window.rootViewController = host
                        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
                        host.view.frame = window.bounds
                        host.view.backgroundColor = .systemBackground
                        window.makeKeyAndVisible()
                        host.view.setNeedsLayout()
                        progress("layout navbar \(theme)-\(Int(width))-\(large)")
                        host.view.layoutIfNeeded()
                        progress("settle navbar \(theme)-\(Int(width))-\(large)")
                        try await Task.sleep(nanoseconds: 450_000_000)
                        progress("inspect navbar \(theme)-\(Int(width))-\(large)")
                        let navigation = controllers(host).compactMap { $0 as? UINavigationController }.first
                        if let navigation {
                            let frost = frostedOverlay(navigation)
                            let bar = navigation.navigationBar
                            let barBottom = bar.superview.map { bar.convert(bar.bounds, to: $0).maxY } ?? 0
                            diagnostics.append([
                                "fixture": "frost-\(theme)-\(Int(width))-\(large)",
                                "frostFrame": frost.map { NSCoder.string(for: $0.frame) } ?? "nil",
                                "barBottom": barBottom,
                                "nativeBackgroundAlpha": navigation.topViewController?.navigationItem.standardAppearance?.backgroundColor?.cgColor.alpha ?? 0
                            ])
                            try check(frost != nil && frost!.frame.minY == 0 && abs(frost!.frame.maxY - (barBottom + 24)) <= 1,
                                      "Frost covers status and navigation area with a fading lower extension: \(theme)-\(Int(width))-\(large)")
                        }
                        diagnostics.append([
                            "fixture": "\(theme)-\(Int(width))-\(large)",
                            "controllerTree": controllers(host).map { String(describing: type(of: $0)) },
                            "topController": navigation?.topViewController.map { String(describing: type(of: $0)) } ?? "nil",
                            "standardShadow": navigation?.topViewController?.navigationItem.standardAppearance?.shadowColor?.description ?? "nil",
                            "scrollShadow": navigation?.topViewController?.navigationItem.scrollEdgeAppearance?.shadowColor?.description ?? "nil"
                        ])
                        try check(hasNoShadow(navigation?.topViewController?.navigationItem.standardAppearance),
                                  "Actual NavigationStack has no hard separator: \(theme), \(Int(width)), large \(large)")
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 3
                        let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format)
                        var drawn = false
                        let image = renderer.image { _ in drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
                        let file = "provider-chrome-navbar-\(theme)-\(Int(width))-\(large ? "large" : "normal").png"
                        try image.pngData()!.write(to: docs.appendingPathComponent(file))
                        screenshots.append(file)
                        let barBottomInHost = navigation.map { $0.navigationBar.convert($0.navigationBar.bounds, to: host.view).maxY } ?? 0
                        let badgeCenter = CGPoint(x: host.view.bounds.midX, y: barBottomInHost + 14)
                        let badgePixels = greenPixelCount(image, around: badgeCenter)
                        diagnostics.append(["fixture": "visible-badge-\(theme)-\(Int(width))-\(large)", "greenPixels": badgePixels,
                                            "expectedCenterY": badgeCenter.y])
                        try check(badgePixels > 30, "Current provider badge is visibly above frost below navigation: \(theme)-\(Int(width))-\(large)")
                        diagnostics.append(["screenshot": file, "drawHierarchySucceeded": drawn,
                                            "contrast": imageContrast(image), "windowHidden": window.isHidden,
                                            "hostAttachedToWindow": host.view.window != nil])
                        try check(drawn && imageContrast(image) > 24, "Hosted navbar screenshot is rendered and nonblank: \(file)")
                        if !large {
                            let scroll = descendants(host.view).compactMap { $0 as? UIScrollView }
                                .first { $0.contentSize.height > $0.bounds.height }
                            if let scroll {
                                if width == 390, let navigation {
                                    try await captureComparisons(host: host, navigation: navigation, scroll: scroll,
                                                                 theme: theme, stage: "initial")
                                }
                                let offset = min(CGFloat(125), scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                                host.view.layoutIfNeeded()
                                try await Task.sleep(nanoseconds: 300_000_000)
                                let rect = scroll.convert(scroll.bounds, to: window)
                                let navBottom = navigation.map { $0.navigationBar.convert($0.navigationBar.bounds, to: window).maxY } ?? 0
                                diagnostics.append(["fixture": "scrolled-\(theme)-\(Int(width))", "offset": scroll.contentOffset.y,
                                                    "scrollViewportTop": rect.minY, "navigationBottom": navBottom,
                                                    "adjustedInsetTop": scroll.adjustedContentInset.top])
                                try check(scroll.contentOffset.y > 0, "Scrolling moves real message content beneath navigation: \(theme)-\(Int(width))")
                                try check(rect.minY < navBottom - 20, "Message viewport extends behind navigation bar: \(theme)-\(Int(width))")
                                let scrolledImage = renderer.image { _ in drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
                                let scrolledFile = "provider-chrome-navbar-\(theme)-\(Int(width))-scrolled.png"
                                try scrolledImage.pngData()!.write(to: docs.appendingPathComponent(scrolledFile))
                                screenshots.append(scrolledFile)
                                try check(greenPixelCount(scrolledImage, around: badgeCenter) > 30,
                                          "Provider badge remains visible when messages scroll beneath frost: \(theme)-\(Int(width))")
                                try check(drawn && imageContrast(scrolledImage) > 24, "Scrolled navigation screenshot contains actual rendered messages: \(theme)-\(Int(width))")
                                if width == 390, let navigation {
                                    try await captureComparisons(host: host, navigation: navigation, scroll: scroll,
                                                                 theme: theme, stage: "scrolled")
                                }
                            } else {
                                try check(false, "Actual message scroll view exists: \(theme)-\(Int(width))")
                            }
                        }
                    }
                }
            }
            write(true)
        } catch { write(false, error.localizedDescription) }
    }
}

@main struct ProviderChromeMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ProviderChromeDelegate.self)) }
}
