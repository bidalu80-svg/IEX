import SwiftUI
import UIKit

/// Compiled in the same file as the extracted, unchanged production glyph.
/// The screenshots are deterministic timeline samples plus one live 12pt glyph.
private struct ThinkingGlyphSamples: View {
    let dark: Bool
    private let times: [TimeInterval] = [0, 0.08, 0.10, 0.20, 0.36, 0.50, 0.625, 0.65,
                                         0.75, 0.85, 0.98, 1.15, 1.25, 1.40, 1.60, 1.80,
                                         2.0, 2.20, 2.32, 2.40]
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 5) {
                JellyThinkingGlyph()
                Text("Ze正在思考中").font(.callout.weight(.medium))
            }
            Text("原尺寸与时间采样").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68)), count: 4), spacing: 17) {
                ForEach(Array(times.enumerated()), id: \.offset) { _, time in
                    VStack(spacing: 7) {
                        JellyThinkingGlyphFrame(elapsed: time)
                            .scaleEffect(4)
                            .frame(width: 60, height: 60)
                        Text(String(format: "%.3f s", time))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
            Text(dark ? "深色" : "浅色").font(.caption)
        }
        .frame(width: 320, height: 640)
        .foregroundColor(dark ? .white : .black)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.accessibilityReduceMotion, false)
    }
}

@MainActor private final class ThinkingGlyphHarnessDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        self.window = window
        window.rootViewController = UIHostingController(rootView: ThinkingGlyphSamples(dark: false))
        window.makeKeyAndVisible()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await run()
        }
        return true
    }
    private func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        var screenshots: [String] = []
        func check(_ value: Bool, _ label: String) throws {
            if !value { throw NSError(domain: "ThinkingGlyph", code: checks.count, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        do {
            try check(abs(JellyThinkingGlyphAnimation.transitionDuration - 0.525) < 0.000001,
                      "Each morph is 0.15 seconds faster than the previous 0.675 second transition")
            let start = JellyThinkingGlyphAnimation.state(elapsed: 0)
            let held = JellyThinkingGlyphAnimation.state(elapsed: 0.08)
            try check(abs(start.morph - held.morph) < 0.000001 && held.sweepOffset > start.sweepOffset,
                      "Color sweep advances to the right while the shape is held")
            let ease = JellyThinkingGlyphAnimation.easedProgress
            let step = 0.001
            try check(abs(ease(0)) < 0.000001 && abs(ease(1) - 1) < 0.000001,
                      "Easing lands exactly on each shape endpoint")
            try check((ease(step) - ease(0)) / step < 0.001 && (ease(1) - ease(1-step)) / step < 0.001,
                      "Morph easing settles with near-zero endpoint velocity")
            try check(ease(0.25) < 0.25 && ease(0.75) > 0.75,
                      "Morph uses acceleration and deceleration rather than linear interpolation")
            let boundary = JellyThinkingGlyphAnimation.cycleDuration
            let before = JellyThinkingGlyphAnimation.state(elapsed: boundary - 0.00001)
            let after = JellyThinkingGlyphAnimation.state(elapsed: boundary + 0.00001)
            let toRadians = Double.pi / 180
            try check(abs(before.morph - after.morph) < 0.0001 &&
                      abs(sin(before.rotationDegrees * toRadians) - sin(after.rotationDegrees * toRadians)) < 0.0001,
                      "The shape and orientation join continuously across the loop")
            try check(abs(JellyThinkingGlyphAnimation.colorCycleDuration - boundary) > 0.1,
                      "Color timing runs independently of the shape loop")
            guard let window else { throw NSError(domain: "ThinkingGlyph", code: -1) }
            for dark in [false, true] {
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView: ThinkingGlyphSamples(dark: dark))
                window.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 200_000_000)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let name = "thinking-glyph-\(dark ? "dark" : "light").png"
                guard let data = image.pngData() else { throw NSError(domain: "ThinkingGlyph", code: -2) }
                try data.write(to: directory.appendingPathComponent(name))
                screenshots.append(name)
            }
            let result: [String: Any] = ["success": true, "checks": checks, "screenshots": screenshots,
                "systemVersion": UIDevice.current.systemVersion,
                "scope": "Unmodified production animation math and SwiftUI drawing, iOS16 target compilation and simulator snapshots. A 60Hz animation schedule is not a physical-device FPS measurement."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("thinking-glyph-result.json"))
        } catch {
            let result: [String: Any] = ["success": false, "checks": checks,
                "screenshots": screenshots, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("thinking-glyph-result.json"))
        }
    }
}

@main private enum ThinkingGlyphHarnessMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ThinkingGlyphHarnessDelegate.self)) }
}
