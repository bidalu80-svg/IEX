import Foundation
import Combine

/// The hardware/provider boundary is injected so the actual lifecycle can be
/// exercised with delayed recognition and playback, including hostile callbacks.
@MainActor
protocol VoiceCallAudio: AnyObject {
    var onInterruption: ((String) -> Void)? { get set }
    var inputLabel: String { get }
    var outputLabel: String { get }
    func prepare() async throws
    func startCapture(onSegment: @escaping (Data) -> Void,
                      onLevel: @escaping (Float) -> Void) throws
    func stopCapture()
    func transcribe(_ data: Data) async throws -> String
    func speak(_ text: String, onLevel: @escaping (Float) -> Void) async throws
    func stopPlayback()
    func releaseResources()
}

@MainActor
final class VoiceCallCoordinator: ObservableObject {
    @Published private(set) var state: VoiceCallState = .idle
    @Published private(set) var isActive = false
    @Published private(set) var isMuted = false
    @Published private(set) var level: Float = 0
    @Published private(set) var error: String?
    @Published private(set) var startDate: Date?
    @Published private(set) var transcript = ""
    @Published private(set) var assistantTranscript = ""
    @Published private(set) var inputLabel = ""
    @Published private(set) var outputLabel = ""

    /// The bridge accepts exactly one turn, without consuming a composer draft.
    var onSend: ((String, UUID) -> Bool)?
    var onCancelTurn: ((UUID) -> Void)?

    private let audio: any VoiceCallAudio
    private var generation = UUID()
    private var captureID: UUID?
    private var turnID: UUID?
    private var responseFinished = false
    private var speechBuffer = VoiceCallSpeechBuffer()
    private var speechQueue: [String] = []
    private var preparationTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var prepared = false

    init(audio: any VoiceCallAudio) {
        self.audio = audio
        audio.onInterruption = { [weak self] reason in self?.pause(reason: reason) }
    }

    func start() {
        guard !isActive else { return }
        generation = UUID()
        let session = generation
        isActive = true
        isMuted = false
        state = .preparing
        error = nil
        transcript = ""
        assistantTranscript = ""
        startDate = nil
        prepared = false
        preparationTask = Task { [weak self] in
            guard let self, self.accepts(session), !Task.isCancelled else { return }
            do {
                try await self.audio.prepare()
                guard self.accepts(session), !Task.isCancelled else { return }
                self.prepared = true
                self.inputLabel = self.audio.inputLabel
                self.outputLabel = self.audio.outputLabel
                self.startDate = Date()
                self.preparationTask = nil
                self.listen()
            } catch {
                guard self.accepts(session), !Task.isCancelled else { return }
                self.pause(reason: error.localizedDescription)
            }
        }
    }

    func end() {
        guard isActive else { return }
        invalidateTurn()
        preparationTask?.cancel()
        preparationTask = nil
        audio.releaseResources()
        prepared = false
        isActive = false
        isMuted = false
        state = .idle
        error = nil
        startDate = nil
        level = 0
    }

    func pause(reason: String) {
        guard isActive else { return }
        invalidateTurn()
        preparationTask?.cancel()
        preparationTask = nil
        state = .paused
        error = reason
        level = 0
    }

    func resume() {
        guard isActive, state == .paused else { return }
        error = nil
        if prepared { listen() }
        else { end(); start() }
    }

    func toggleMute() {
        guard isActive else { return }
        isMuted.toggle()
        if isMuted, state == .listening || state == .transcribing {
            invalidateTurn()
            state = .muted
        } else if !isMuted, state == .muted {
            listen()
        }
        // Muting the microphone during a reply does not mute the assistant.
    }

    func interruptAndListen() {
        guard isActive, prepared else { return }
        invalidateTurn()
        error = nil
        isMuted = false
        listen()
    }

    func receiveAssistantText(_ cumulativeText: String, turnID id: UUID) {
        guard isActive, turnID == id, !responseFinished else { return }
        assistantTranscript = cumulativeText
        speechQueue.append(contentsOf: speechBuffer.append(cumulativeText))
        pumpPlayback()
    }

    func finishResponse(turnID id: UUID, error message: String? = nil) {
        guard isActive, turnID == id, !responseFinished else { return }
        if let message, !message.isEmpty { pause(reason: message); return }
        responseFinished = true
        speechQueue.append(contentsOf: speechBuffer.append(assistantTranscript, final: true))
        pumpPlayback()
    }

    private func accepts(_ session: UUID) -> Bool { isActive && generation == session }

    /// Invalidate first: synchronous cancellation callbacks are stale too.
    private func invalidateTurn() {
        generation = UUID()
        captureID = nil
        let previous = turnID
        turnID = nil
        responseFinished = false
        transcriptionTask?.cancel(); transcriptionTask = nil
        playbackTask?.cancel(); playbackTask = nil
        watchdog?.cancel(); watchdog = nil
        speechQueue.removeAll()
        speechBuffer = VoiceCallSpeechBuffer()
        audio.stopCapture()
        audio.stopPlayback()
        level = 0
        if let previous { onCancelTurn?(previous) }
    }

    private func listen() {
        guard isActive, prepared else { return }
        guard !isMuted else { state = .muted; return }
        let session = generation
        let capture = UUID()
        captureID = capture
        state = .listening
        level = 0
        do {
            try audio.startCapture(onSegment: { [weak self] data in
                guard let self, self.accepts(session), self.captureID == capture,
                      self.state == .listening, !self.isMuted else { return }
                self.recognize(data)
            }, onLevel: { [weak self] value in
                guard let self, self.accepts(session), self.captureID == capture,
                      self.state == .listening else { return }
                self.level = min(1, max(0, value))
            })
        } catch { pause(reason: error.localizedDescription) }
    }

    private func recognize(_ data: Data) {
        captureID = nil
        audio.stopCapture()
        level = 0
        guard !data.isEmpty else { listen(); return }
        state = .transcribing
        let session = generation
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled, let self, self.accepts(session), self.state == .transcribing else { return }
            self.pause(reason: "语音识别超时，请检查网络后继续")
        }
        transcriptionTask = Task { [weak self] in
            guard let self, self.accepts(session), !Task.isCancelled else { return }
            do {
                let text = try await self.audio.transcribe(data).trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.accepts(session), !Task.isCancelled, !self.isMuted else { return }
                self.watchdog?.cancel(); self.watchdog = nil
                self.transcriptionTask = nil
                if text.isEmpty { self.listen(); return }
                self.transcript = text
                self.assistantTranscript = ""
                self.speechBuffer = VoiceCallSpeechBuffer()
                self.responseFinished = false
                let id = UUID()
                self.turnID = id
                self.state = .responding
                guard self.onSend?(text, id) == true else {
                    if self.state != .paused {
                        self.pause(reason: "当前对话尚未就绪，请稍后继续通话")
                    }
                    return
                }
            } catch {
                guard self.accepts(session), !Task.isCancelled else { return }
                self.pause(reason: error.localizedDescription)
            }
        }
    }

    private func pumpPlayback() {
        guard isActive, let id = turnID, playbackTask == nil else { return }
        guard !speechQueue.isEmpty else {
            if responseFinished {
                turnID = nil
                responseFinished = false
                level = 0
                listen()
            } else { state = .responding }
            return
        }
        let session = generation
        let text = speechQueue.removeFirst()
        // Thinking remains visible until actual playback begins (meter callback).
        state = .responding
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self, self.accepts(session), self.turnID == id else { return }
            self.pause(reason: "语音播放超时，请稍后继续")
        }
        playbackTask = Task { [weak self] in
            guard let self, self.accepts(session), self.turnID == id, !Task.isCancelled else { return }
            do {
                try await self.audio.speak(text, onLevel: { [weak self] value in
                    guard let self, self.accepts(session), self.turnID == id else { return }
                    self.state = .speaking
                    self.level = min(1, max(0, value))
                })
                guard self.accepts(session), self.turnID == id, !Task.isCancelled else { return }
                self.watchdog?.cancel(); self.watchdog = nil
                self.playbackTask = nil
                self.level = 0
                self.pumpPlayback()
            } catch {
                guard self.accepts(session), self.turnID == id, !Task.isCancelled else { return }
                self.playbackTask = nil
                self.pause(reason: error.localizedDescription)
            }
        }
    }
}
