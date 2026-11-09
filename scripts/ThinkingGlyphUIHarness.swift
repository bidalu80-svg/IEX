import SwiftUI
import UIKit

/// Uses the complete production row and atlas without a substitute label or renderer.
private struct ThinkingGlyphSamples: View {
    let dark: Bool
    private let times: [TimeInterval] = [0, 0.067, 0.133, 0.20, 0.40, 0.60,
                                        0.90, 1.20, 1.50, 2, 3, 5]
    private let rowTimes: [TimeInterval] = [0, 0.467, 0.533, 0.60, 0.70, 0.90]
    var body: some View {
        VStack(spacing: 12) {
            TypingIndicator()
            Text("真实文案入场与魔方时间采样").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(Array(rowTimes.enumerated()), id: \.offset) { _, time in
                    HStack(spacing: 8) {
                        Text(String(format: "%.3fs", time))
                            .font(.system(size: 9, design: .monospaced)).frame(width: 45)
                        TypingIndicatorFrame(elapsed: time)
                        Spacer(minLength: 0)
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(68)), count: 4), spacing: 10) {
                ForEach(Array(times.enumerated()), id: \.offset) { _, time in
                    VStack(spacing: 4) {
                        CubeThinkingGlyphFrame(elapsed: time).scaleEffect(2).frame(width: 54, height: 54)
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
        var total: Double = 0
        for index in first.indices {
            let firstValue: Double = Double(first[index])
            let secondValue: Double = Double(second[index])
            total += abs(firstValue - secondValue)
        }
        let mean: Double = total / Double(first.count)
        return mean / 255.0
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

    private func renderedRow(at elapsed: TimeInterval, dark: Bool = false,
                             reducedMotion: Bool = false) throws -> UIImage {
        let content = TypingIndicatorFrame(elapsed: elapsed, reducedMotion: reducedMotion)
            .frame(width: 220, height: 48, alignment: .leading)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: 220, height: 48)
        guard let image = renderer.uiImage else { throw failure("Production thinking row snapshot was empty") }
        return image
    }

    /// Exclude the 24pt glyph and its 4pt gap, then measure the actual rendered label.
    private func labelInk(_ image: CGImage, dark: Bool = false) throws -> (amount: Double, centerY: Double, top: Int, bottom: Int) {
        let pixels = try rgba(image)
        var amount: Double = 0
        var weightedY: Double = 0
        var top = image.height
        var bottom = -1
        for y in 0..<image.height {
            for x in 84..<image.width {
                let value = Double(pixels[(y * image.width + x) * 4])
                let ink = dark ? value : 255.0 - value
                amount += ink
                weightedY += ink * Double(y)
                if ink > 4 {
                    top = min(top, y)
                    bottom = max(bottom, y)
                }
            }
        }
        return (amount, amount > 0 ? weightedY / amount : 0, top, bottom)
    }

    private func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var checks: [String] = []
        var screenshots: [String] = []
        var frameFiles: [String] = []
        var rowFrameFiles: [String] = []
        var motionFrameFiles: [String] = []
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
            let loopStart = animation.loopStartFrameIndex
            let initialDuration = animation.initialPlaybackDuration
            let budget = animation.decodedMemoryBudget
            guard let frames = CubeThinkingGlyphFrames.load(),
                  let atlas = UIImage(named: "ThinkingCubeAtlas")?.cgImage ??
                    UIImage(named: "thinking-cube-atlas")?.cgImage else {
                throw failure("The real cube atlas must load from the app bundle")
            }
            let expectedRows = (count + columns - 1) / columns
            try check(fps == 60 && count > 0 && intro > 0 && loop > 0 &&
                      loopStart >= intro && loopStart + loop <= count &&
                      tile == 56 && columns == 8 && atlas.width == columns * tile && atlas.height == expectedRows * tile &&
                      frames.frames.count == count && frames.frames.allSatisfy { $0.width == tile && $0.height == tile },
                      "The complete reference atlas decodes every correctly sized 60 Hz frame")

            let actualBytes = frames.frames.reduce(0) { $0 + $1.bytesPerRow * $1.height }
            metrics["decodedByteCount"] = frames.decodedByteCount
            metrics["measuredFrameBytes"] = actualBytes
            try check(actualBytes > 0 && actualBytes <= budget &&
                      frames.decodedByteCount >= actualBytes && frames.decodedByteCount <= budget,
                      "Measured decoded frames and the atlas cache cost fit the production memory budget")

            let introSequence = (0..<intro).map { animation.frameIndex(elapsed: (Double($0) + 0.25) / fps) }
            try check(introSequence == Array(0..<intro) && animation.frameIndex(elapsed: -1) == 0 &&
                      animation.frameIndex(elapsed: .infinity) == 0 && animation.frameIndex(elapsed: .nan) == 0 &&
                      animation.frameIndex(elapsed: animation.introDuration - 0.000001) == intro - 1 &&
                      animation.frameIndex(elapsed: animation.introDuration + 0.000001) == intro,
                      "The intro plays once in order, clamps negative time and enters the loop without skipping a frame")

            let initialSequence = (0..<count).allSatisfy { index in
                animation.frameIndex(elapsed: (Double(index) + 0.25) / fps) == index
            }
            try check(initialSequence && abs(initialDuration - Double(count) / fps) < 0.000001,
                      "The first playback preserves every authored frame instead of truncating the reference motion")

            let orderedLoops = (0..<5).allSatisfy { repetition in
                (0..<loop).allSatisfy { index in
                    let time = initialDuration + Double(repetition) * animation.loopDuration +
                        (Double(index) + 0.25) / fps
                    return animation.frameIndex(elapsed: time) == loopStart + index
                }
            }
            try check(orderedLoops && animation.frameIndex(elapsed: initialDuration - 0.000001) == count - 1 &&
                      animation.frameIndex(elapsed: initialDuration + 0.000001) == loopStart &&
                      (0..<600).allSatisfy {
                          animation.frameIndex(elapsed: initialDuration + Double($0) / fps) >= loopStart
                      },
                      "Five ordered rotation cycles keep the entrance dot out of every repeat")

            var globalBoundarySamples: [[String: Double]] = []
            let continuousGlobalRotation = (0..<5).allSatisfy { repetition in
                let boundary = initialDuration + Double(repetition) * animation.loopDuration
                let before = Double(animation.globalRotationDegrees(elapsed: boundary - 0.000001))
                let after = Double(animation.globalRotationDegrees(elapsed: boundary + 0.000001))
                let previousCycle = Double(animation.globalRotationDegrees(elapsed: boundary - animation.loopDuration))
                globalBoundarySamples.append(["elapsed": boundary, "before": before, "after": after])
                return before.isFinite && after.isFinite && abs(after - before) < 0.01 &&
                    abs(before - previousCycle) > 0.1
            }
            metrics["globalRotationLoopBoundaries"] = globalBoundarySamples
            try check(continuousGlobalRotation,
                      "The global cube rotation advances continuously across five local-layer loop boundaries")

            let still = animation.frameIndex(elapsed: 0, reducedMotion: true)
            try check(still >= 0 && still < count && [0.0, 0.5, 10.0, 1_000_000.0].allSatisfy {
                animation.frameIndex(elapsed: $0, reducedMotion: true) == still
            }, "Reduced Motion always selects the same valid static reference frame")

            let masks: [[UInt8]] = try frames.frames.map { (image: CGImage) throws -> [UInt8] in
                try alpha(image)
            }
            let neutralPaddedMasks: Bool = try frames.frames.allSatisfy { (image: CGImage) throws -> Bool in
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
                return visible > 0 && visible < tile * tile / 2
            }
            try check(neutralPaddedMasks,
                      "Every frame contains a small neutral dot mask with transparent padding and no opaque background")
            let pointPixels = masks[0].filter { $0 > 8 }.count
            let formedPixels = masks[intro].filter { $0 > 8 }.count
            metrics["firstPointPixels"] = pointPixels
            metrics["formedCubePixels"] = formedPixels
            try check(pointPixels > 0 && pointPixels * 4 < formedPixels,
                      "The first rendered reference pose is a small point before the cube grows")

            let atlasFramesMatch: Bool = try (0..<count).allSatisfy { (index: Int) throws -> Bool in
                let rect = CGRect(x: (index % columns) * tile, y: (index / columns) * tile, width: tile, height: tile)
                guard let crop = atlas.cropping(to: rect) else { return false }
                return try alpha(crop) == masks[index]
            }
            try check(atlasFramesMatch,
                      "Every decoded reference frame matches the correct row and column of the source atlas")

            let largestStep = (1..<count).map { difference(masks[$0 - 1], masks[$0]) }.max() ?? 0
            let introJoin = difference(masks[intro - 1], masks[intro])
            let loopJoin = difference(masks[count - 1], masks[loopStart])
            let recurringJoin = difference(masks[loopStart + loop - 1], masks[loopStart])
            metrics["largestAdjacentAlphaDifference"] = largestStep
            metrics["introJoinAlphaDifference"] = introJoin
            metrics["loopJoinAlphaDifference"] = loopJoin
            metrics["recurringLoopJoinAlphaDifference"] = recurringJoin
            try check(largestStep > 0 && introJoin <= max(0.015, largestStep * 1.35) &&
                      loopJoin <= max(0.015, largestStep * 1.35) &&
                      recurringJoin <= max(0.015, largestStep * 1.35),
                      "Playback joins remain within adjacent-frame differences; this bound does not assert reference parity")

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
                let image = try renderedFrame(at: Double(index) / fps + 0.00000001)
                guard let cgImage = image.cgImage, let png = image.pngData() else { throw failure("Frame export failed") }
                let pixels = try rgba(cgImage)
                let ink = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 248 }.count
                visibleExports = visibleExports && cgImage.width == 72 && cgImage.height == 72 && ink > 5 && ink < 72 * 72 / 2
                let name = String(format: "thinking-glyph-frame-%03d.png", index)
                try png.write(to: frameDirectory.appendingPathComponent(name))
                frameFiles.append("thinking-glyph-frames/" + name)
            }
            try check(visibleExports && frameFiles.count == count,
                      "The unchanged production Canvas renders every authored 72 by 72 pixel frame export")

            let motionDirectory = directory.appendingPathComponent("thinking-glyph-motion", isDirectory: true)
            try FileManager.default.createDirectory(at: motionDirectory, withIntermediateDirectories: true)
            let motionFrameCount = 15 * Int(fps)
            for tick in 0..<motionFrameCount {
                let image = try renderedFrame(at: Double(tick) / fps + 0.00000001)
                guard let cgImage = image.cgImage, cgImage.width == 72, cgImage.height == 72,
                      let png = image.pngData() else { throw failure("Continuous production motion export failed") }
                let name = String(format: "thinking-glyph-motion-%04d.png", tick)
                try png.write(to: motionDirectory.appendingPathComponent(name))
                motionFrameFiles.append("thinking-glyph-motion/" + name)
                if tick % 30 == 0 { await Task.yield() }
            }
            try check(motionFrameFiles.count == 900,
                      "The production Canvas exports 15 continuous seconds across repeated local-layer wraps")

            let tintTime = (Double(intro + 18) + 0.25) / fps
            guard let lightFrame = try renderedFrame(at: tintTime).cgImage,
                  let darkFrame = try renderedFrame(at: tintTime, dark: true).cgImage else {
                throw failure("Tint verification frame was empty")
            }
            let lightPixels = try rgba(lightFrame)
            let darkPixels = try rgba(darkFrame)
            var inverseDifference: Double = 0
            for offset in stride(from: 0, to: lightPixels.count, by: 4) {
                let lightValue: Double = Double(lightPixels[offset])
                let darkValue: Double = Double(darkPixels[offset])
                let inverseSum: Double = lightValue + darkValue - 255.0
                inverseDifference += abs(inverseSum)
            }
            let tintPixelCount: Double = Double(lightFrame.width * lightFrame.height)
            let inverseError: Double = inverseDifference / tintPixelCount / 255.0
            let lightInk = stride(from: 0, to: lightPixels.count, by: 4).filter { lightPixels[$0] < 220 }.count
            let darkInk = stride(from: 0, to: darkPixels.count, by: 4).filter { darkPixels[$0] > 35 }.count
            metrics["lightDarkInverseError"] = inverseError
            try check(inverseError < 0.03 && lightInk > 5 && darkInk > 5,
                      "The production Canvas draws matching dark dots on white and light dots on black")

            let labelAnimation = TypingIndicatorAnimation.self
            let labelDelay = labelAnimation.labelDelay
            let labelDuration = labelAnimation.labelDuration
            let hiddenLabel = labelAnimation.labelState(elapsed: 0)
            let settledTime = labelDelay + labelDuration + 0.1
            let settledLabel = labelAnimation.labelState(elapsed: settledTime)
            let reducedLabel = labelAnimation.labelState(elapsed: 0, reducedMotion: true)
            let labelSamples = (0...60).map { index in
                labelAnimation.labelState(elapsed: Double(index) / fps)
            }
            let monotonicEntrance = (1..<labelSamples.count).allSatisfy { index in
                let previous = labelSamples[index - 1]
                let current = labelSamples[index]
                return current.opacity >= previous.opacity - 0.000001 &&
                    current.offsetY <= previous.offsetY + 0.000001
            }
            let midpointLabel = labelAnimation.labelState(elapsed: labelDelay + labelDuration / 2)
            let expectedMidpointOffset = Double(labelAnimation.labelInitialOffsetY) * 0.25
            try check(abs(labelDelay - 14.0 / 30.0) < 0.000001 &&
                      abs(labelDuration - 0.2) < 0.000001 &&
                      abs(Double(midpointLabel.offsetY) - expectedMidpointOffset) < 0.000001 &&
                      hiddenLabel.opacity == 0 &&
                      hiddenLabel.offsetY > 0 && settledLabel.opacity == 1 && settledLabel.offsetY == 0 &&
                      monotonicEntrance,
                      "The real label uses the measured reference delay and ease-out rise, with a monotonic fade")

            let lateLabelTimes: [TimeInterval] = [2, 5, 20, 100]
            let lateLabelSettled = lateLabelTimes.allSatisfy { time in
                let state = labelAnimation.labelState(elapsed: time)
                return state.opacity == 1 && state.offsetY == 0
            }
            try check(lateLabelSettled && reducedLabel.opacity == 1 && reducedLabel.offsetY == 0,
                      "The label entrance runs once; long waits stay settled and Reduced Motion is immediately readable")

            guard let initialRow = try renderedRow(at: 0).cgImage,
                  let earlyRow = try renderedRow(at: labelDelay + labelDuration * 0.25).cgImage,
                  let settledRow = try renderedRow(at: settledTime).cgImage,
                  let lateRow = try renderedRow(at: 20).cgImage,
                  let reducedRow = try renderedRow(at: 0, reducedMotion: true).cgImage else {
                throw failure("The real label entrance could not be rendered")
            }
            let initialInk = try labelInk(initialRow)
            let earlyInk = try labelInk(earlyRow)
            let settledInk = try labelInk(settledRow)
            let lateInk = try labelInk(lateRow)
            let reducedInk = try labelInk(reducedRow)
            metrics["labelDelay"] = labelDelay
            metrics["labelDuration"] = labelDuration
            metrics["labelInitialInk"] = initialInk.amount
            metrics["labelEarlyInk"] = earlyInk.amount
            metrics["labelSettledInk"] = settledInk.amount
            metrics["labelRisePixels"] = abs(earlyInk.centerY - settledInk.centerY)
            try check(initialInk.amount < 1 && earlyInk.amount > 100 &&
                      settledInk.amount > earlyInk.amount &&
                      abs(earlyInk.centerY - settledInk.centerY) > 0.15,
                      "Rendered production text is absent initially and visibly fades while moving toward its final baseline")
            try check(lateInk.amount > settledInk.amount * 0.5 &&
                      abs(lateInk.top - settledInk.top) <= 1 &&
                      abs(lateInk.bottom - settledInk.bottom) <= 1 &&
                      reducedInk.amount > settledInk.amount * 0.5,
                      "Actual long-wait and Reduced Motion rows keep the label readable at its settled baseline")

            let rowDirectory = directory.appendingPathComponent("thinking-glyph-rows", isDirectory: true)
            try FileManager.default.createDirectory(at: rowDirectory, withIntermediateDirectories: true)
            var rowSamples: [[String: Any]] = []
            for dark in [false, true] {
                for index in 0...54 {
                    let time = Double(index) / fps
                    let row = try renderedRow(at: time, dark: dark)
                    guard let cgImage = row.cgImage, cgImage.width == 660, cgImage.height == 144,
                          let png = row.pngData() else { throw failure("Full production row export failed") }
                    let theme = dark ? "dark" : "light"
                    let name = String(format: "thinking-row-%@-%03d.png", theme, index)
                    try png.write(to: rowDirectory.appendingPathComponent(name))
                    let relativePath = "thinking-glyph-rows/" + name
                    rowFrameFiles.append(relativePath)
                    rowSamples.append(["file": relativePath, "elapsed": time, "theme": theme])
                }
            }
            for (name, time, reducedMotion) in [
                ("thinking-row-settled.png", settledTime, false),
                ("thinking-row-long-wait.png", 20.0, false),
                ("thinking-row-reduced-motion.png", 0.0, true)
            ] {
                let row = try renderedRow(at: time, reducedMotion: reducedMotion)
                guard let png = row.pngData() else { throw failure("Settled row export failed") }
                try png.write(to: rowDirectory.appendingPathComponent(name))
                rowFrameFiles.append("thinking-glyph-rows/" + name)
            }
            try check(rowSamples.count == 110 && rowFrameFiles.count == 113,
                      "The complete production row exports every 60 Hz entrance frame through 0.9s in both themes")

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
                      "Light and dark UIKit snapshots show the live production row and its sampled label entrance")

            let result: [String: Any] = ["success": true, "checks": checks, "screenshots": screenshots,
                "frameFiles": frameFiles, "rowFrameFiles": rowFrameFiles, "rowSamples": rowSamples,
                "motionFrameFiles": motionFrameFiles, "motionFPS": fps,
                "metrics": metrics, "framesPerSecond": fps, "frameCount": count,
                "introFrameCount": intro, "loopFrameCount": loop, "systemVersion": UIDevice.current.systemVersion,
                "loopStartFrameIndex": loopStart, "initialPlaybackDuration": initialDuration,
                "scope": "Unmodified production atlas cache, frame sampling, Canvas and full TypingIndicatorFrame; iOS16 target compilation, every authored glyph frame, 15 seconds of continuous deterministic motion, complete label entrance exports and simulator snapshots. Pixel seam bounds do not prove reference parity. A 60Hz schedule is not a physical-device FPS measurement."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("thinking-glyph-result.json"))
        } catch {
            let result: [String: Any] = ["success": false, "checks": checks, "screenshots": screenshots,
                "frameFiles": frameFiles, "rowFrameFiles": rowFrameFiles,
                "motionFrameFiles": motionFrameFiles, "metrics": metrics, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("thinking-glyph-result.json"))
        }
    }
}

@main private enum ThinkingGlyphHarnessMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ThinkingGlyphHarnessDelegate.self)) }
}
