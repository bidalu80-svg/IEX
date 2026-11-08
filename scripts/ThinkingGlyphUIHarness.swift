import SwiftUI
import UIKit

/// Uses the extracted production Canvas, cache and real atlas without a second renderer.
private struct ThinkingGlyphSamples: View {
    let dark: Bool
    private let times: [TimeInterval] = [0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.333, 0.40,
                                         0.467, 0.533, 0.60, 0.667, 0.733, 0.80, 0.867,
                                         0.933, 1.0, 1.067, 1.133, 1.20]
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 5) {
                CubeThinkingGlyph()
                Text("Ze正在思考中").font(.callout.weight(.medium))
            }
            Text("原尺寸与时间采样").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68)), count: 4), spacing: 17) {
                ForEach(Array(times.enumerated()), id: \.offset) { _, time in
                    VStack(spacing: 7) {
                        CubeThinkingGlyphFrame(elapsed: time).scaleEffect(2).frame(width: 60, height: 60)
                        Text(String(format: "%.3f s", time)).font(.system(size: 10, design: .monospaced))
                    }
                }
            }
            Text(dark ? "深色" : "浅色").font(.caption)
        }
        .frame(width: 320, height: 640)
        .foregroundColor(dark ? .white : .black)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
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

    private func failure(_ text: String) -> NSError {
        NSError(domain: "ThinkingGlyph", code: -1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw failure("RGBA inspection context allocation failed") }
        return bytes
    }

    private func alpha(_ image: CGImage) throws -> [UInt8] {
        let bytes = try rgba(image)
        return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
    }

    private func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return .infinity }
        return zip(first, second).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } /
            Double(first.count) / 255
    }

    private func renderedFrame(at elapsed: TimeInterval, dark: Bool = false) throws -> UIImage {
        let content = CubeThinkingGlyphFrame(elapsed: elapsed)
            .frame(width: 24, height: 24)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: 24, height: 24)
        guard let image = renderer.uiImage else { throw failure("Production Canvas snapshot was empty") }
        return image
    }

    private func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        var screenshots: [String] = []
        var frameFiles: [String] = []
        var metrics: [String: Any] = [:]
        func check(_ value: Bool, _ label: String) throws {
            if !value { throw failure(label) }
            checks.append(label)
        }
        do {
            let animation = CubeThinkingGlyphAnimation.self
            let fps = animation.framesPerSecond
            let tile = animation.tileSide
            let columns = animation.atlasColumns
            let count = animation.frameCount
            let intro = animation.introFrameCount
            let loop = animation.loopFrameCount
            guard let frames = CubeThinkingGlyphFrames.load(),
                  let atlas = UIImage(named: "ThinkingCubeAtlas")?.cgImage ??
                    UIImage(named: "thinking-cube-atlas")?.cgImage else {
                throw failure("The real cube atlas must load from the app bundle")
            }
            try check(fps == 60 && intro == 12 && loop == 62 && count == intro + loop &&
                      tile == 56 && columns == 8 && atlas.width == 448 && atlas.height == 560 &&
                      frames.frames.count == count && frames.frames.allSatisfy { $0.width == tile && $0.height == tile },
                      "The bundled reference atlas decodes all 74 correctly sized 60 Hz frames")

            let actualBytes = frames.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            metrics["decodedByteCount"] = frames.decodedByteCount
            metrics["measuredFrameBytes"] = actualBytes
            try check(actualBytes > 0 && actualBytes <= 2 * 1024 * 1024 &&
                      frames.decodedByteCount >= actualBytes && frames.decodedByteCount <= 2 * 1024 * 1024,
                      "Measured decoded frames and the cache cost both fit the 2 MiB budget")

            let introSequence = (0..<intro).map { animation.frameIndex(elapsed: (Double($0) + 0.25) / fps) }
            try check(introSequence == Array(0..<intro) && animation.frameIndex(elapsed: -1) == 0 &&
                      animation.frameIndex(elapsed: .infinity) == 0 && animation.frameIndex(elapsed: .nan) == 0 &&
                      animation.frameIndex(elapsed: animation.introDuration - 0.000001) == intro - 1 &&
                      animation.frameIndex(elapsed: animation.introDuration + 0.000001) == intro,
                      "The intro plays once in order, clamps negative time and enters the loop without skipping a frame")

            let orderedLoops = (0..<5).allSatisfy { repetition in
                (0..<loop).allSatisfy { index in
                    let time = animation.introDuration + Double(repetition) * animation.loopDuration +
                        (Double(index) + 0.25) / fps
                    return animation.frameIndex(elapsed: time) == intro + index
                }
            }
            let loopEnd = animation.introDuration + animation.loopDuration
            try check(orderedLoops && animation.frameIndex(elapsed: loopEnd - 0.000001) == count - 1 &&
                      animation.frameIndex(elapsed: loopEnd + 0.000001) == intro,
                      "All 62 loop frames repeat in order for five cycles with the exact wrap boundary")

            let still = animation.frameIndex(elapsed: 0, reducedMotion: true)
            try check(still >= 0 && still < count && [0.0, 0.5, 10.0, 1_000_000.0].allSatisfy {
                animation.frameIndex(elapsed: $0, reducedMotion: true) == still
            }, "Reduced Motion always selects the same valid static reference frame")

            let masks = try frames.frames.map { try alpha($0) }
            let neutralPaddedMasks = try frames.frames.allSatisfy { image in
                let bytes = try rgba(image)
                var visible = 0
                for y in 0..<tile {
                    for x in 0..<tile {
                        let offset = (y * tile + x) * 4
                        let a = bytes[offset + 3]
                        if a > 0 {
                            if x < 2 || y < 2 || x >= tile - 2 || y >= tile - 2 { return false }
                            if abs(Int(bytes[offset]) - Int(bytes[offset + 1])) > 1 ||
                                abs(Int(bytes[offset + 1]) - Int(bytes[offset + 2])) > 1 { return false }
                            if a > 8 { visible += 1 }
                        }
                    }
                }
                return visible > 8 && visible < tile * tile / 2
            }
            try check(neutralPaddedMasks,
                      "Every frame contains a small neutral dot mask with transparent padding and no opaque background")

            let atlasFramesMatch = try (0..<count).allSatisfy { index in
                let rect = CGRect(x: (index % columns) * tile, y: (index / columns) * tile, width: tile, height: tile)
                guard let crop = atlas.cropping(to: rect) else { return false }
                return try alpha(crop) == masks[index]
            }
            try check(atlasFramesMatch,
                      "Every decoded reference frame matches the correct row and column of the source atlas")

            let largestStep = (1..<count).map { difference(masks[$0 - 1], masks[$0]) }.max() ?? 0
            let introJoin = difference(masks[intro - 1], masks[intro])
            let loopJoin = difference(masks[count - 1], masks[intro])
            metrics["largestAdjacentAlphaDifference"] = largestStep
            metrics["introJoinAlphaDifference"] = introJoin
            metrics["loopJoinAlphaDifference"] = loopJoin
            try check(largestStep > 0 && introJoin <= max(0.015, largestStep * 1.35) &&
                      loopJoin <= max(0.015, largestStep * 1.35),
                      "Intro and loop joins stay within the authored frame-to-frame motion envelope")

            let reusedSameFrames = CubeThinkingGlyphFrames.load() === frames
            CubeThinkingGlyphFrames.purgeCache()
            guard let reloaded = CubeThinkingGlyphFrames.load() else { throw failure("Atlas reload failed after purge") }
            let reloadedMask = try alpha(reloaded.frames[intro])
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            guard let afterWarning = CubeThinkingGlyphFrames.load() else {
                throw failure("Atlas reload failed after the memory warning")
            }
            try check(reusedSameFrames && reloaded !== frames && reloaded.frames.count == count &&
                      reloaded.decodedByteCount == frames.decodedByteCount && reloadedMask == masks[intro] &&
                      afterWarning !== reloaded && afterWarning.decodedByteCount == frames.decodedByteCount,
                      "The cache reuses one decoded set and reloads identical frames after explicit purge and memory warning")

            let frameDirectory = directory.appendingPathComponent("thinking-glyph-frames", isDirectory: true)
            try FileManager.default.createDirectory(at: frameDirectory, withIntermediateDirectories: true)
            var visibleExports = true
            for index in 0..<count {
                let image = try renderedFrame(at: (Double(index) + 0.25) / fps)
                guard let cgImage = image.cgImage, let png = image.pngData() else { throw failure("Frame export failed") }
                let pixels = try rgba(cgImage)
                let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 248 }.count
                visibleExports = visibleExports && cgImage.width == 72 && cgImage.height == 72 && ink > 5 && ink < 72 * 72 / 2
                let name = String(format: "thinking-glyph-frame-%03d.png", index)
                try png.write(to: frameDirectory.appendingPathComponent(name))
                frameFiles.append("thinking-glyph-frames/" + name)
            }
            try check(visibleExports && frameFiles.count == count,
                      "The unchanged production Canvas renders all 74 nonempty 72 by 72 pixel frame exports")

            let tintTime = (Double(intro + 18) + 0.25) / fps
            guard let lightFrame = try renderedFrame(at: tintTime).cgImage,
                  let darkFrame = try renderedFrame(at: tintTime, dark: true).cgImage else {
                throw failure("Tint verification frame was empty")
            }
            let lightPixels = try rgba(lightFrame)
            let darkPixels = try rgba(darkFrame)
            let inverseError = stride(from: 0, to: lightPixels.count, by: 4).reduce(0.0) {
                $0 + abs(Double(lightPixels[$1]) + Double(darkPixels[$1]) - 255)
            } / Double(lightFrame.width * lightFrame.height) / 255
            let lightInk = stride(from: 0, to: lightPixels.count, by: 4).filter { lightPixels[$0] < 220 }.count
            let darkInk = stride(from: 0, to: darkPixels.count, by: 4).filter { darkPixels[$0] > 35 }.count
            metrics["lightDarkInverseError"] = inverseError
            try check(inverseError < 0.03 && lightInk > 5 && darkInk > 5,
                      "The production Canvas draws matching dark dots on white and light dots on black")

            guard let window else { throw failure("Missing UIKit window") }
            for dark in [false, true] {
                window.overrideUserInterfaceStyle = dark ? .dark : .light
                window.rootViewController = UIHostingController(rootView: ThinkingGlyphSamples(dark: dark))
                window.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 200_000_000)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let name = "thinking-glyph-\(dark ? "dark" : "light").png"
                guard let data = image.pngData(), let cgImage = image.cgImage else { throw failure("UIKit snapshot failed") }
                let pixels = try rgba(cgImage)
                let background = dark ? 0 : 255
                guard stride(from: 0, to: pixels.count, by: 4).contains(where: {
                    abs(Int(pixels[$0]) - background) > 30
                }) else { throw failure("UIKit snapshot contained only the background") }
                try data.write(to: directory.appendingPathComponent(name))
                screenshots.append(name)
            }
            try check(screenshots.count == 2,
                      "Light and dark UIKit snapshots show the live glyph, unchanged label and sampled poses")

            let result: [String: Any] = ["success": true, "checks": checks, "screenshots": screenshots,
                "frameFiles": frameFiles, "metrics": metrics, "framesPerSecond": fps,
                "introFrameCount": intro, "loopFrameCount": loop, "systemVersion": UIDevice.current.systemVersion,
                "scope": "Unmodified production atlas cache, frame sampling and SwiftUI Canvas; iOS16 target compilation, 74 deterministic frame exports and simulator snapshots. A 60Hz schedule is not a physical-device FPS measurement."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("thinking-glyph-result.json"))
        } catch {
            let result: [String: Any] = ["success": false, "checks": checks, "screenshots": screenshots,
                "frameFiles": frameFiles, "metrics": metrics, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("thinking-glyph-result.json"))
        }
    }
}

@main private enum ThinkingGlyphHarnessMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ThinkingGlyphHarnessDelegate.self)) }
}
