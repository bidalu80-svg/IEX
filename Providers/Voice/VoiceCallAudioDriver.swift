import Foundation
import AVFoundation
import UIKit

extension VoiceCallCoordinator {
    convenience init() { self.init(audio: VoiceCallAudioDriver()) }
}

/// Dedicated per-call audio. It never modifies persisted read-aloud preferences
/// and never uses the global TTS queue. Capturing and playback are sequential.
@MainActor
final class VoiceCallAudioDriver: NSObject, VoiceCallAudio {
    var onInterruption: ((String) -> Void)?
    private(set) var inputLabel = ""
    private(set) var outputLabel = ""
    private var inputProvider: (any VoiceInputCapable)?
    private var outputProvider: (any VoiceOutputCapable)?
    private var inputModel: LLMModel?
    private var outputModel: LLMModel?
    private var systemVoiceID: String?
    private var systemInputOnDevice: Bool?
    private var language = "zh-CN"
    private var detector: VoiceActivityDetector?
    private var captureRelay: CallCaptureRelay?
    private var captureID: UUID?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var player: AVAudioPlayer?
    private var playbackID = UUID()
    private var playbackContinuation: CheckedContinuation<Void, Error>?
    private var meterTask: Task<Void, Never>?
    private var playbackLevel: ((Float) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AudioSessionCoordinator.foregroundPlaybackStartedNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onInterruption?("已切换到其他音频，点继续恢复通话")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                             object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.onInterruption?("音频被系统中断，点继续恢复通话")
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                             object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            // Category changes during sequential capture/playback are expected.
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                    || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.onInterruption?("音频设备已切换，点继续恢复通话")
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onInterruption?("通话已暂停，返回后点继续")
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func prepare() async throws {
        ProviderConfigStore.shared.ensureDefaultVoiceInputGroup()
        ProviderConfigStore.shared.ensureDefaultVoiceOutputGroup()
        inputModel = VoiceProviderResolver.resolvedInputEntry()?.model
        outputModel = VoiceProviderResolver.resolvedOutputEntry()?.model
        inputProvider = VoiceProviderResolver.inputProvider()
        outputProvider = VoiceProviderResolver.outputProvider()
        inputLabel = VoiceProviderResolver.inputModelLabel()
        outputLabel = VoiceProviderResolver.outputModelLabel()
        systemVoiceID = VoiceProviderResolver.resolvedSystemOutputVoiceId()
        language = VoiceLanguages.lastUsed
        switch VoiceProviderResolver.resolvedSystemInputMode() {
        case .offline: systemInputOnDevice = true
        case .online: systemInputOnDevice = false
        case .auto: systemInputOnDevice = nil
        }
        guard await VoiceActivityDetector.requestMicrophonePermission() else {
            throw CallAudioError.message("请在系统设置中允许 Ze 使用麦克风")
        }
        try Task.checkCancellation()
        if let system = inputProvider as? SystemVoiceProvider {
            guard await SystemVoiceProvider.ensureSpeechAuthorization() else {
                throw CallAudioError.message("请在系统设置中允许 Ze 使用语音识别")
            }
            try Task.checkCancellation()
            system.prewarm(language: language)
        }
    }

    func startCapture(onSegment: @escaping (Data) -> Void,
                      onLevel: @escaping (Float) -> Void) throws {
        stopCapture()
        stopPlayback()
        // Explicitly entering/resuming the call owns audio. Do not mutate the
        // persistent read-aloud toggle, voice speed, or selected provider.
        VoiceOutputState.shared.stop()
        if GlobalAudioPlayer.shared.isPlaying { GlobalAudioPlayer.shared.stop() }
        var configuration = VoiceActivityDetector.Configuration()
        configuration.voiceStartFrameCount = 5
        configuration.voiceEndFrameCount = 25 // ~800 ms, independent of dictation.
        let vad = VoiceActivityDetector(configuration: configuration)
        vad.maxSegmentSeconds = 55
        let id = UUID()
        captureID = id
        let relay = CallCaptureRelay(onSegment: { [weak self] data in
            guard self?.captureID == id else { return }
            onSegment(data)
        }, onLevel: { [weak self] value in
            guard self?.captureID == id else { return }
            onLevel(value)
        }, onInterrupted: { [weak self] in
            guard self?.captureID == id else { return }
            self?.onInterruption?("收音已中断，点继续恢复通话")
        })
        captureRelay = relay
        detector = vad
        vad.delegate = relay
        VoiceModePreference.shared.isCapturing = true
        do { try vad.start() }
        catch {
            stopCapture()
            AudioSessionCoordinator.shared.end(.capture)
            throw error
        }
    }

    func stopCapture() {
        guard detector != nil || captureID != nil else { return }
        captureID = nil
        detector?.delegate = nil
        detector?.stop()
        detector = nil
        captureRelay = nil
        VoiceModePreference.shared.isCapturing = false
    }

    func transcribe(_ data: Data) async throws -> String {
        guard let provider = inputProvider else { throw CallAudioError.message("语音识别尚未准备好") }
        let request = VoiceInputRequest(audioData: data, model: inputModel?.id,
                                        language: language, resolvedModel: inputModel,
                                        onDeviceRecognition: systemInputOnDevice)
        let response = try await provider.transcribe(request)
        try Task.checkCancellation()
        return response.text
    }

    func speak(_ raw: String, onLevel: @escaping (Float) -> Void) async throws {
        let text = VoiceTextSanitizer.sanitize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let provider = outputProvider else { throw CallAudioError.message("语音播放尚未准备好") }
        try Task.checkCancellation()
        stopPlayback()
        let id = UUID()
        playbackID = id
        playbackLevel = onLevel
        if provider is SystemVoiceProvider {
            let speech = AVSpeechUtterance(string: text)
            let request = VoiceOutputRequest(input: text, model: systemVoiceID)
            speech.voice = SystemVoiceProvider.resolveVoice(request: request, fallbackLocale: Locale(identifier: language))
            guard speech.voice != nil else {
                throw CallAudioError.message("系统语音资源尚未就绪，请在设置中选择可用声音")
            }
            speech.rate = AVSpeechUtteranceDefaultSpeechRate
            speech.pitchMultiplier = SystemVoicePreferences.pitch
            speech.volume = SystemVoicePreferences.volume
            utterance = speech
            AudioSessionCoordinator.shared.begin(.voiceCallPlayback)
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled, self.playbackID == id else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    self.playbackContinuation = continuation
                    self.synthesizer.speak(speech)
                }
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.playbackID == id else { return }
                    self?.stopPlayback()
                }
            })
        } else {
            let data = try await provider.synthesize(VoiceOutputRequest(input: text, model: outputModel?.id))
            try Task.checkCancellation()
            guard playbackID == id else { throw CancellationError() }
            guard !data.isEmpty else { throw VoiceProviderError.noAudioData }
            AudioSessionCoordinator.shared.begin(.voiceCallPlayback)
            let audio = try AVAudioPlayer(data: data)
            audio.delegate = self
            audio.isMeteringEnabled = true
            player = audio
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled, self.playbackID == id else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    self.playbackContinuation = continuation
                    guard audio.prepareToPlay(), audio.play() else {
                        self.completePlayback(error: CallAudioError.message("音频播放失败，请稍后继续"))
                        return
                    }
                    onLevel(0)
                    self.meterTask = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self, self.playbackID == id, let player = self.player else { return }
                            player.updateMeters()
                            onLevel(min(1, pow(10, player.averagePower(forChannel: 0) / 20) * 3))
                            try? await Task.sleep(nanoseconds: 80_000_000)
                        }
                    }
                }
            }, onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.playbackID == id else { return }
                    self?.stopPlayback()
                }
            })
        }
    }

    func stopPlayback() {
        playbackID = UUID()
        utterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.delegate = nil
        player?.stop()
        player = nil
        completePlayback(error: CancellationError())
    }

    private func completePlayback(error: Error? = nil) {
        meterTask?.cancel(); meterTask = nil
        player = nil
        utterance = nil
        playbackLevel = nil
        AudioSessionCoordinator.shared.end(.voiceCallPlayback)
        let continuation = playbackContinuation
        playbackContinuation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }

    func release() {
        stopCapture()
        stopPlayback()
        inputProvider = nil
        outputProvider = nil
    }
}

extension VoiceCallAudioDriver: AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.completePlayback(error: flag ? nil : CallAudioError.message("音频播放中断，请稍后继续"))
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.completePlayback(error: error ?? CallAudioError.message("音频解码失败"))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.playbackLevel?(0) // System speech exposes no PCM meter; do not invent a level.
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.completePlayback()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.completePlayback(error: CallAudioError.message("语音播放已中断"))
        }
    }
}

private enum CallAudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// One delegate per capture epoch. Even a queued VAD callback from a destroyed
/// engine retains its old epoch and cannot submit into the next utterance.
private final class CallCaptureRelay: VoiceActivityDelegate {
    private let onSegment: @MainActor (Data) -> Void
    private let onLevel: @MainActor (Float) -> Void
    private let onInterrupted: @MainActor () -> Void

    init(onSegment: @escaping @MainActor (Data) -> Void,
         onLevel: @escaping @MainActor (Float) -> Void,
         onInterrupted: @escaping @MainActor () -> Void) {
        self.onSegment = onSegment; self.onLevel = onLevel; self.onInterrupted = onInterrupted
    }

    func voiceActivityDidEnd(audioData: Data, reason: SegmentEndReason) {
        Task { @MainActor in self.onSegment(audioData) }
    }

    func voiceActivityDidUpdate(pcmData: Data) {
        let count = pcmData.count / MemoryLayout<Float>.size
        guard count > 0 else { return }
        let rms: Float = pcmData.withUnsafeBytes { bytes in
            var sum: Float = 0
            for i in 0..<count {
                let sample = bytes.loadUnaligned(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
                if sample.isFinite { sum += sample * sample }
            }
            return sqrt(sum / Float(count))
        }
        Task { @MainActor in self.onLevel(min(1, rms * 5)) }
    }

    func voiceActivityInterrupted() { Task { @MainActor in self.onInterrupted() } }
}
