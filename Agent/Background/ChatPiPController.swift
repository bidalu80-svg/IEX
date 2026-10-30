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

/// One row of the mini terminal: a tool call and how it went.
struct FloatingStep: Equatable {
    var glyph: String
    var text: String
    var seconds: String
    var isError: Bool
    var isRunning: Bool
}

/// One frame's worth of conversation, rendered into the PiP window.
struct FloatingCardModel: Equatable {
    var title: String
    var line: String
    var status: String
    var soulName: String
    var startedAt: Date
    var isCompleted: Bool
    var steps: [FloatingStep] = []

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

    /// [T-floating-window-pip] The PiP window inherits the sample buffer's
    /// aspect ratio, so this size *is* the window's shape. 480x180 is a small
    /// horizontal terminal strip in a corner; the previous 360x480 portrait made
    /// the system open a tall card that covered a third of the screen and left
    /// most of it empty.
    static let cardWidth: CGFloat = 480
    static let cardHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // One-line title bar, like a terminal window's chrome.
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isCompleted ? Color.green : Color.blue)
                    .frame(width: 6, height: 6)
                Text(model.soulName.isEmpty ? "Ze" : model.soulName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                Text("·")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Text(model.title.isEmpty ? String(localized: "Agent Task") : model.title)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(elapsedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // Terminal output: the turn's tool calls, newest last, plus the
            // latest thing said. Up to nine rows fill the strip at this size.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(model.steps.suffix(9).enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 5) {
                        Image(systemName: step.glyph)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(step.isError ? Color.red.opacity(0.95)
                                             : (step.isRunning ? Color.blue.opacity(0.95)
                                                : Color.green.opacity(0.7)))
                            .frame(width: 11)
                        Text(step.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(step.isRunning ? 0.95 : 0.72))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if !step.seconds.isEmpty {
                            Text(step.seconds)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                }
                if !model.line.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Text("›")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.32))
                        Text(model.line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                if !model.isCompleted {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                }
                Text(model.status)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
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
final class ChatPiPController: NSObject, ObservableObject {
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
    /// [T-floating-window-pip] A sample-buffer layer shows nothing without one:
    /// `enqueue` only defines a queue. Without a timebase the system treats
    /// every frame as "not yet due", which is the grey card with a spinner the
    /// Picture in Picture window shows when it has no content.
    private var timebase: CMTimebase?
    /// Presentation timestamps must advance; a repeated or future timestamp is
    /// dropped by the layer.
    private var frameIndex: Int64 = 0
    /// [T-floating-window-pip] The timestamp carried by the last frame, kept so
    /// the next one is always strictly later. Two frames with the same stamp
    /// can make the layer drop one of them.
    private var lastPresentationTime: CMTime = .invalid
    private var hostView: UIView?
    private var frameTimer: Timer?
    private var silentAudio: SilentAudioKeepAlive?
    private var observers: [NSObjectProtocol] = []
    private var sessionCancellable: AnyCancellable?
    private var startRetries = 0

    private var model: FloatingCardModel = .empty
    /// Set by `preview()`: float the card even with no task running, so the
    /// window can be proven from Settings instead of after a backgrounding.
    private var forcedPreview = false
    /// True once a task has been seen in this prepared session. The layer is
    /// prepared at launch too, and must not be torn down for the "no task yet"
    /// state that is normal at launch.
    private var sawActiveSession = false

    /// [T-floating-window-diag] One line of live state, shown under the switch.
    /// The window can only be debugged on a device, and the Console is not
    /// always at hand, so the answer to "why is it grey" belongs in the app.
    @Published private(set) var diagnostic = "未准备"
    private var lastFrameAt: Date?
    private var lastLayerStatus = "—"

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
        guard Self.isSupported, Self.isEnabled else { return }
        forcedPreview = true
        ensurePrepared()
        guard isPrepared else { return }
        model = Self.previewPlaceholderModel()
        renderFrame()
        present(force: true)
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
        // [T-floating-window-pip] Only auto-float while a task actually runs.
        // With this on and a prepared layer, iOS restores the window on *every*
        // backgrounding — including the ones with nothing running, which is the
        // "no task but a window shows up" report.
        controller.canStartPictureInPictureAutomaticallyFromInline =
            !SessionActivityTracker.shared.activeSessions.isEmpty

        hostView = host
        displayLayer = layer
        pip = controller
        model = Self.currentModel()

        isPrepared = true
        // No frame while idle: a layer holding a rendered card can be floated by
        // the system even with no task. Content only exists during a run.
        if !SessionActivityTracker.shared.activeSessions.isEmpty {
            renderFrame()
        }
        startFrameTimer()
        AppLogger(category: "PiP").info("[PiP] prepared — layer on screen")
    }

    /// Prepare from the app's launch path, so the very first backgrounding has a
    /// layer that has been rendering for a while. Without this, the layer is
    /// created during `willResignActive` and the system refuses to float it —
    /// the window only appeared on the *second* backgrounding.
    func prepareIfEnabled() {
        guard Self.isEnabled else { return }
        ensurePrepared()
    }

    /// [T-floating-window-pip] Audio keeps the process alive long enough for the
    /// system to finish starting PiP as the app backgrounds. It must therefore
    /// start when a task starts, not when the window appears.
    private func startAudioIfNeeded() {
        guard silentAudio == nil else { return }
        silentAudio = SilentAudioKeepAlive()
        silentAudio?.start()
    }

    private func enableAutomaticStart(_ on: Bool) {
        pip?.canStartPictureInPictureAutomaticallyFromInline = on
    }

    /// Ask the system to float the prepared layer.
    func present(force: Bool = false) {
        guard Self.isSupported else { return }
        guard Self.isEnabled else { return }
        ensurePrepared()
        guard let pip else { return }
        guard !pip.isPictureInPictureActive else { return }
        if !force {
            guard !SessionActivityTracker.shared.activeSessions.isEmpty else {
                AppLogger(category: "PiP").info("[PiP] present skipped — no active task")
                return
            }
        }
        guard pip.isPictureInPicturePossible else {
            // The usual cause: the layer has no rendered frame yet. Push one
            // out before retrying, then try again on the next runloop.
            renderFrame()
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
        // Audio only while the window is on screen: it is what keeps the
        // process (and therefore the stream) alive in the background.
        startAudioIfNeeded()
        // Make sure the frame that is about to become the window's first image
        // is current — the timer may be a whole tick behind.
        renderFrame()
        pip.startPictureInPicture()
        // [T-floating-window-pip] The window animates in over roughly a second
        // and the system samples the layer while it settles. A single frame
        // handed over at the start is not enough: what the window keeps is
        // whatever arrived during that animation.
        for delay in [0.2, 0.6, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in self?.renderFrame() }
            }
        }
        AppLogger(category: "PiP").info("[PiP] start requested")
    }

    /// Take the window down but keep the layer ready for the next backgrounding.
    func dismiss() {
        if let pip, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        silentAudio?.stop()
        silentAudio = nil
        isFloating = false
    }

    /// Drop the layer, the audio session and the timer.
    func teardown() {
        dismiss()
        // Never leave auto-start armed with no task: the system would float the
        // last card again on the next backgrounding.
        pip?.canStartPictureInPictureAutomaticallyFromInline = false
        frameTimer?.invalidate()
        frameTimer = nil
        silentAudio?.stop()
        silentAudio = nil
        hostView?.removeFromSuperview()
        hostView = nil
        displayLayer = nil
        // [T-floating-window-pip] The layer is gone, so its clock must go too:
        // a stale timebase makes the next `ensurePrepared` skip configuring the
        // fresh layer, and the new window waits for frames that never display.
        timebase = nil
        frameIndex = 0
        lastPresentationTime = .invalid
        pip = nil
        isPrepared = false
        isFloating = false
        startRetries = 0
        forcedPreview = false
        lastFrameAt = nil
        lastLayerStatus = "—"
        updateDiagnostic()
        AppLogger(category: "PiP").info("[PiP] torn down")
    }

    // MARK: - Frames

    private func startFrameTimer() {
        frameTimer?.invalidate()
        // 4 fps. At 2 fps a late tick left a whole half second with nothing to
        // show, and the window flashed empty; at 4 fps the 0.5s sample duration
        // covers two ticks. The card is text only, so this is cheap.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func tick() {
        if !forcedPreview {
            let sessions = SessionActivityTracker.shared.activeSessions
            if sessions.isEmpty {
                // The window exists only while a task runs — but an idle launch
                // is not "the task ended": keep the layer prepared so the first
                // backgrounding can float it.
                if sawActiveSession {
                    AppLogger(category: "PiP").info("[PiP] no active session — closing window")
                    teardown()
                    return
                }
                return
            }
            sawActiveSession = true
            model = Self.currentModel()
        }
        renderFrame()
    }

    private func renderFrame() {
        guard let layer = displayLayer else { return }
        configureTimebaseIfNeeded(on: layer)
        let elapsed = Date().timeIntervalSince(model.startedAt)
        let card = FloatingConversationCard(model: model, elapsed: elapsed)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(
            width: FloatingConversationCard.cardWidth,
            height: FloatingConversationCard.cardHeight
        )
        guard let cgImage = renderer.cgImage else {
            AppLogger(category: "PiP").warning("[PiP] render produced no image")
            return
        }
        // [T-floating-window-pip] A failed layer keeps its last image out of the
        // window, which is exactly the grey spinner. Flushing alone does not
        // help: the clock that fed it is stale too. Rebuild both — and rebuild
        // *before* stamping, because a fresh clock starts again at zero and a
        // timestamp taken from the old one would never be reached.
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            AppLogger(category: "PiP").warning(
                "[PiP] layer \(String(describing: layer.status)) (\(String(describing: layer.error))) — rebuilding")
            layer.flushAndRemoveImage()
            timebase = nil
            lastPresentationTime = .invalid
            configureTimebaseIfNeeded(on: layer)
        }
        let stamp = nextPresentationTime()
        guard let sample = Self.sampleBuffer(from: cgImage, presentationTime: stamp) else {
            AppLogger(category: "PiP").warning("[PiP] could not build a sample buffer")
            return
        }
        frameIndex += 1
        lastFrameAt = Date()
        layer.enqueue(sample)
        lastLayerStatus = Self.describe(layer.status)
        updateDiagnostic()
        // The first frame is the one that proves the pipeline works, so say so
        // once instead of logging every tick.
        if frameIndex == 1 {
            AppLogger(category: "PiP").info(
                "[PiP] first frame \(cgImage.width)x\(cgImage.height) enqueued, layer=\(String(describing: layer.status))")
        }
    }

    /// Start the layer's clock. Frames are stamped against it, so it has to
    /// exist before the first one is enqueued.
    private func configureTimebaseIfNeeded(on layer: AVSampleBufferDisplayLayer) {
        guard timebase == nil else { return }
        var tb: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb
        ) == noErr, let timebase = tb else {
            AppLogger(category: "PiP").warning("[PiP] could not create a timebase")
            return
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1.0)
        layer.controlTimebase = timebase
        self.timebase = timebase
        AppLogger(category: "PiP").info("[PiP] timebase started")
    }

    /// [T-floating-window-pip] The timestamp a frame has to carry to be shown.
    ///
    /// It is read from the layer's own clock, not counted per frame. A counter
    /// only stays in step with real time while nothing slips, and plenty slips:
    /// a background timer iOS throttles, a main-thread hitch while the window
    /// animates in, a short suspension. The moment the counter falls behind, the
    /// clock has already passed every following frame, and the layer discards
    /// them without an error — the queue drains, Picture in Picture puts its
    /// grey spinner back, and it never recovers because a counter cannot catch
    /// up with a clock. Reading the clock makes each frame "now" by
    /// construction, whatever happened in between.
    private func nextPresentationTime() -> CMTime {
        let now = timebase.map { CMTimebaseGetTime($0) }
            ?? CMClockGetTime(CMClockGetHostTimeClock())
        guard lastPresentationTime.isValid else {
            lastPresentationTime = now
            return now
        }
        // Strictly increasing, so two frames never share a stamp.
        let stamp = CMTimeMaximum(now, CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 600)))
        lastPresentationTime = stamp
        return stamp
    }

    /// [T-floating-window-diag] Keeps the settings line current.
    private func updateDiagnostic() {
        let age = lastFrameAt.map { String(format: "%.0fs", Date().timeIntervalSince($0)) } ?? "—"
        let state = isFloating ? "浮窗中" : (isPrepared ? "已准备" : "未准备")
        let next = "\(state) · 帧 \(frameIndex) · 最近 \(age) · 图层 \(lastLayerStatus) · 0.5s/帧"
        if next != diagnostic { diagnostic = next }
    }

    private static func describe(_ status: AVQueuedSampleBufferRenderingStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .rendering: return "rendering"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }

    private static func sampleBuffer(from image: CGImage, presentationTime: CMTime) -> CMSampleBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue as Any,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
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

        // [T-floating-window-pip] The caller stamps the frame with the layer's
        // clock reading, so it is always "now" and can never be past due.
        //
        // The duration stays at one frame interval — 0.5s, which covers two
        // ticks at the 4 fps the timer produces. It is deliberately *not*
        // inflated to hours. A day-long duration looks like a safe way to keep
        // a starved queue on screen, and on a device it does the exact
        // opposite: the window paints the first frame and then sits on Picture
        // in Picture's grey spinner forever. The system reads the sample timing
        // to decide whether there is video to present, and a frame that claims
        // to last 24 hours reads as "no video". This was a real regression, not
        // a theory: with a 0.5s duration the card was visible, and the only
        // change between that build and the one that shows a spinner is this
        // number.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 2),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        // [T-floating-window-pip] Show the frame on arrival. Without this the
        // layer holds each frame until its timebase reaches the presentation
        // stamp — and PiP pauses the source layer while the window animates in,
        // so the frame sits in the queue and the window keeps its spinner. This
        // is the difference between "a frame was handed over" and "a frame is
        // on screen".
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let raw = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
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
            isCompleted: false,
            steps: steps(from: vm)
        )
    }

    /// Recent tool calls of the turn that is running, oldest first.
    private static func steps(from vm: AIChatViewModel?) -> [FloatingStep] {
        guard let turn = vm?.messages.last(where: { $0.role == .assistant && !$0.blocks.isEmpty }) else {
            return []
        }
        var rows: [FloatingStep] = []
        for block in turn.blocks.suffix(9) {
            if let row = stepRow(block) { rows.append(row) }
        }
        return rows
    }

    private static func stepRow(_ block: AssistantBlock) -> FloatingStep? {
        let glyph: String
        let text: String
        switch block.kind {
        case .shellTool(let command):
            glyph = "terminal"; text = command
        case .fileReadTool(let path):
            glyph = "doc.text"; text = path
        case .fileWriteTool(let path):
            glyph = "square.and.arrow.down"; text = path
        case .fileEditTool(let path):
            glyph = "pencil"; text = path
        case .browserTool(let action):
            glyph = "globe"; text = action
        case .readImageTool(let path):
            glyph = "photo"; text = path
        case .memoryTool(let action):
            glyph = "brain"; text = action
        default:
            return nil
        }
        var isError = false
        var isRunning = false
        if let status = block.toolStatus {
            switch status {
            case .failed:
                isError = true
            case .running, .streaming:
                isRunning = true
            default:
                break
            }
        }
        var seconds = ""
        if let duration = block.toolDuration, duration > 0 {
            seconds = duration < 10 ? String(format: "%.1fs", duration)
                                    : String(format: "%.0fs", duration)
        }
        return FloatingStep(glyph: glyph,
                            text: clip(text, to: 46),
                            seconds: seconds,
                            isError: isError,
                            isRunning: isRunning)
    }

    private static func clip(_ raw: String, to limit: Int) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    /// Placeholder card used by the preview button.
    private static func previewPlaceholderModel() -> FloatingCardModel {
        FloatingCardModel(
            title: String(localized: "悬浮窗预览"),
            line: String(localized: "任务运行时，这里显示当前对话的最新一句。"),
            status: String(localized: "预览模式 · 没有任务在跑"),
            soulName: AgentLiveActivityManager.currentSoulName(),
            startedAt: Date(),
            isCompleted: false,
            steps: [
                FloatingStep(glyph: "terminal", text: "python3 抓取页面", seconds: "0.8s", isError: false, isRunning: false),
                FloatingStep(glyph: "globe", text: "浏览器 · 打开油价页面", seconds: "1.6s", isError: false, isRunning: false),
                FloatingStep(glyph: "magnifyingglass", text: "百度搜索 · 广东油价", seconds: "", isError: false, isRunning: true),
            ]
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
            Task { @MainActor in
                guard let self else { return }
                self.ensurePrepared()
                guard !SessionActivityTracker.shared.activeSessions.isEmpty else { return }
                // [T-floating-window-pip] The automatic start covers the normal
                // path; this is cheap insurance. The audio session is already
                // up (it starts with the task), so the process survives long
                // enough for the request to land — and `present()` retries
                // while `isPictureInPicturePossible` is still false.
                self.present()
            }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Back in the app: the window is redundant. Keep the layer
                // prepared so the next backgrounding floats instantly.
                self?.dismiss()
                self?.ensurePrepared()
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
                        // Only tear down when a task actually ended. At launch
                        // this fires with an empty set and must keep the
                        // prepared layer alive.
                        if self.sawActiveSession {
                            self.sawActiveSession = false
                            self.teardown()
                        }
                    } else {
                        // A real task supersedes the placeholder card.
                        self.forcedPreview = false
                        self.sawActiveSession = true
                        self.ensurePrepared()
                        self.enableAutomaticStart(true)
                        // [T-floating-window-pip] The audio session has to be
                        // up while the app is still in the foreground: iOS
                        // suspends a silent app before PiP finishes starting,
                        // which is why the window only ever appeared on the
                        // second backgrounding.
                        self.startAudioIfNeeded()
                        self.renderFrame()
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
        // The audio session is what keeps the process alive once the window
        // floats; started here it also covers the automatic start, which never
        // goes through `present()`.
        startAudioIfNeeded()
        // [T-floating-window-pip] Hand the window a frame right now. The
        // automatic start never goes through `present()`, so without this the
        // window can open on an empty layer while the timer is a tick away.
        renderFrame()
        updateDiagnostic()
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
        // [T-floating-window-pip] A zero-length range keeps the system chrome to
        // a close button. Returning an indefinite one makes iOS treat the strip
        // as a live broadcast and draw the 直播 label plus 10-second skip
        // buttons across it.
        CMTimeRange(start: .zero, duration: .zero)
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
