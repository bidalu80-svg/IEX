//
//  ChatPiPController.swift
//  ZeApp
//
//  [T-floating-window-pip] The floating window: the running conversation is
//  rasterised into a video stream and handed to Picture in Picture, so the
//  system floats it over every other app — the same mechanism ToDesk uses for
//  its remote screen. Live Activities cannot do this: they only own the Dynamic
//  Island and the Lock Screen.
//
//  Lifecycle, and why it is split in three:
//
//    prepare()  build the layer, attach it to the window, start pushing frames.
//               This must happen while the app is still in the foreground and
//               has time to draw, otherwise PiP has nothing to show and the
//               request fails.
//    present()  only asks the system to float the already-rendering layer.
//               Called when the app resigns active.
//    dismiss()  takes the window down without losing the prepared layer, so
//               the next backgrounding is instant.
//    teardown() drops everything (switch off, or the last task finished).
//

import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

/// One frame's worth of conversation, rendered into the PiP window.
struct FloatingCardModel: Equatable {
    var title: String
    var line: String
    var status: String
    var soulName: String
    var startedAt: Date
    var isCompleted: Bool

    static let empty = FloatingCardModel(title: "", line: "", status: "",
                                         soulName: "Ze", startedAt: Date(),
                                         isCompleted: false)
}

/// The card itself. Deliberately plain: it is rasterised at ~2 fps, so anything
/// animated or expensive would burn battery for no visible gain.
private struct FloatingConversationCard: View {
    let model: FloatingCardModel
    let elapsed: TimeInterval

    private var elapsedText: String {
        let total = Int(max(0, elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isCompleted ? Color.green : Color.blue)
                    .frame(width: 8, height: 8)
                Text(model.soulName.isEmpty ? "Ze" : model.soulName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 4)
                Text(elapsedText)
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }

            Text(model.title.isEmpty ? String(localized: "Agent Task") : model.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            if !model.line.isEmpty {
                Text(model.line)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if !model.isCompleted {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.7))
                        .scaleEffect(0.7)
                }
                Text(model.status)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(width: 360, height: 480, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.12),
                                    Color(red: 0.03, green: 0.04, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Keeps the process running (and therefore the PiP stream refreshing) while the
/// app is in the background. PiP alone does not keep an app alive; an active
/// audio session does. Silent, mixed with other audio, and only while a
/// floating window is on screen.
private final class SilentAudioKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            try engine.start()

            let frames = AVAudioFrameCount(44_100)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            if let data = buffer.floatChannelData?[0] {
                data.update(repeating: 0, count: Int(frames))
            }
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()
            isRunning = true
        } catch {
            AppLogger(category: "PiP").warning("[PiP] silent audio failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
    }
}

@MainActor
final class ChatPiPController: NSObject {
    static let shared = ChatPiPController()

    /// Preference key shared with the Appearance switch.
    static let preferenceKey = "backgroundFloatingWindow"

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: preferenceKey) as? Bool) ?? false
    }

    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// True once the layer exists and frames are flowing (not necessarily
    /// floated yet).
    private(set) var isPrepared = false
    /// True while the system is floating the window.
    private(set) var isFloating = false

    private var pip: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var hostView: UIView?
    private var frameTimer: Timer?
    private var silentAudio: SilentAudioKeepAlive?
    private var observers: [NSObjectProtocol] = []
    private var sessionCancellable: AnyCancellable?
    private var startRetries = 0

    private var model: FloatingCardModel = .empty

    private override init() {
        super.init()
        observeAppLifecycle()
        observeSessions()
    }

    // MARK: - Public

    /// Called by the Appearance switch.
    func setPreference(_ on: Bool) {
        if on {
            ensurePrepared()
        } else {
            teardown()
        }
    }

    /// The "预览" button: float the window right now, no backgrounding needed.
    func preview() {
        ensurePrepared()
        present()
    }

    /// Build the layer and start feeding it frames. Cheap to call repeatedly.
    func ensurePrepared() {
        guard Self.isEnabled, Self.isSupported else { return }
        guard !isPrepared else { return }
        guard let window = Self.keyWindow() else {
            AppLogger(category: "PiP").warning("[PiP] prepare skipped — no key window")
            return
        }

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        host.clipsToBounds = true
        host.layer.addSublayer(layer)
        layer.frame = host.bounds
        // A PiP source layer has to be on screen: an invisible (alpha 0) or
        // off-window view makes the start request fail. 2×2 in the corner is
        // invisible to the eye and visible to the system.
        window.addSubview(host)

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false

        hostView = host
        displayLayer = layer
        pip = controller
        model = Self.currentModel()

        silentAudio = SilentAudioKeepAlive()
        silentAudio?.start()

        isPrepared = true
        renderFrame()
        startFrameTimer()
        AppLogger(category: "PiP").info("[PiP] prepared — layer on screen, frames flowing")
    }

    /// Ask the system to float the prepared layer.
    func present() {
        guard Self.isSupported else { return }
        guard Self.isEnabled else { return }
        ensurePrepared()
        guard let pip else { return }
        guard !pip.isPictureInPictureActive else { return }
        guard !SessionActivityTracker.shared.activeSessions.isEmpty else {
            AppLogger(category: "PiP").info("[PiP] present skipped — no active task")
            return
        }
        guard pip.isPictureInPicturePossible else {
            // The usual cause: the layer has no rendered frame yet. Try again on
            // the next runloop instead of giving up silently.
            if startRetries < 8 {
                startRetries += 1
                AppLogger(category: "PiP").info("[PiP] not possible yet — retry \(startRetries)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    Task { @MainActor in self?.present() }
                }
            } else {
                AppLogger(category: "PiP").warning("[PiP] present gave up — isPictureInPicturePossible stayed false")
            }
            return
        }
        startRetries = 0
        pip.startPictureInPicture()
        AppLogger(category: "PiP").info("[PiP] start requested")
    }

    /// Take the window down but keep the layer ready for the next backgrounding.
    func dismiss() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        isFloating = false
    }

    /// Drop the layer, the audio session and the timer.
    func teardown() {
        dismiss()
        frameTimer?.invalidate()
        frameTimer = nil
        silentAudio?.stop()
        silentAudio = nil
        hostView?.removeFromSuperview()
        hostView = nil
        displayLayer = nil
        pip = nil
        isPrepared = false
        isFloating = false
        startRetries = 0
        AppLogger(category: "PiP").info("[PiP] torn down")
    }

    // MARK: - Frames

    private func startFrameTimer() {
        frameTimer?.invalidate()
        // 2 fps: the card only carries text plus a seconds clock.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func tick() {
        // The window exists only while a task runs.
        guard !SessionActivityTracker.shared.activeSessions.isEmpty else {
            AppLogger(category: "PiP").info("[PiP] no active session — closing window")
            teardown()
            return
        }
        model = Self.currentModel()
        renderFrame()
    }

    private func renderFrame() {
        guard let layer = displayLayer else { return }
        let elapsed = Date().timeIntervalSince(model.startedAt)
        let card = FloatingConversationCard(model: model, elapsed: elapsed)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 360, height: 480)
        guard let cgImage = renderer.cgImage,
              let sample = Self.sampleBuffer(from: cgImage) else { return }
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sample)
    }

    private static func sampleBuffer(from image: CGImage) -> CMSampleBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attrs, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    // MARK: - Content

    /// Reads the conversation that is currently running:
    /// title / tool status from `SessionActivityTracker`, the latest line from
    /// the cached view model.
    private static func currentModel() -> FloatingCardModel {
        let tracker = SessionActivityTracker.shared
        let sessions = tracker.activeSessions.sorted()
        guard let sid = sessions.first(where: { $0 == AIChatViewModel.activeSessionId }) ?? sessions.first else {
            return .empty
        }
        let info = tracker.sessionToolInfo[sid]
        let vm = ViewModelCache.shared.get(for: sid)
        var line = ""
        if let messages = vm?.messages {
            for message in messages.reversed() {
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    line = collapse(text)
                    break
                }
            }
        }
        let toolName = info?.toolName ?? ""
        let toolStatus = info?.toolStatus ?? ""
        let status: String
        if toolName.isEmpty {
            status = String(localized: "Working...")
        } else if toolStatus.isEmpty {
            status = AgentLiveActivityManager.displayName(forTool: toolName)
        } else {
            status = "\(AgentLiveActivityManager.displayName(forTool: toolName)) · \(toolStatus)"
        }
        return FloatingCardModel(
            title: info?.title ?? "",
            line: line,
            status: status,
            soulName: AgentLiveActivityManager.currentSoulName(),
            startedAt: taskStartDate(for: sid),
            isCompleted: false
        )
    }

    /// The card's clock counts from the task, not from the moment the window
    /// opened. First sighting of a running session stamps the start.
    private static func taskStartDate(for sessionId: String) -> Date {
        if let known = SessionStartClock.shared.startDate(for: sessionId) { return known }
        let now = Date()
        SessionStartClock.shared.noteStart(sessionId, at: now)
        return now
    }

    private static func collapse(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return oneLine.count > 240 ? String(oneLine.prefix(240)) + "…" : oneLine
    }

    // MARK: - Lifecycle

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.present() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Back in the app: the window is redundant. Keep the layer
                // prepared so the next backgrounding floats instantly.
                self?.dismiss()
            }
        })
    }

    /// Prepare as soon as a task starts, while the app is still in the
    /// foreground and can draw. By the time the user swipes away, the layer has
    /// been streaming for a while and the start request is accepted.
    private func observeSessions() {
        sessionCancellable = SessionActivityTracker.shared.$activeSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                Task { @MainActor in
                    guard let self else { return }
                    guard Self.isEnabled else { return }
                    if sessions.isEmpty {
                        self.teardown()
                    } else {
                        self.ensurePrepared()
                    }
                }
            }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

// MARK: - PiP delegates

extension ChatPiPController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isFloating = true
        AppLogger(category: "PiP").info("[PiP] floating")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isFloating = false
        AppLogger(category: "PiP").warning("[PiP] failed to start: \(error.localizedDescription)")
        // The layer may simply not have had a frame yet; one more attempt after
        // the next draw is cheaper than making the user toggle the switch again.
        if startRetries < 3 {
            startRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                Task { @MainActor in self?.present() }
            }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isFloating = false
        AppLogger(category: "PiP").info("[PiP] stopped")
    }
}

extension ChatPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   setPlaying playing: Bool) {
        // A live card has no transport: playing/paused is meaningless.
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// When each session's current task started, so the card's clock counts from
/// the task rather than from the moment the window opened.
@MainActor
final class SessionStartClock {
    static let shared = SessionStartClock()
    private var starts: [String: Date] = [:]

    func noteStart(_ sessionId: String, at date: Date = Date()) {
        starts[sessionId] = date
    }

    func clear(_ sessionId: String) {
        starts.removeValue(forKey: sessionId)
    }

    func startDate(for sessionId: String) -> Date? {
        starts[sessionId]
    }
}
