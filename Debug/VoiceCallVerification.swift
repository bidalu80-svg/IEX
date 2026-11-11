#if DEBUG
import Foundation

/// Runs the actual VM send/cancel path with an injected audio boundary. Every
/// accepted send is cancelled on the same actor turn, before its Task can run;
/// no provider request or permission prompt is needed for this regression.
@MainActor enum VoiceCallVerification {
    private final class Audio: VoiceCallAudio {
        var onInterruption: ((String) -> Void)?
        var inputLabel = "Verification ASR"
        var outputLabel = "Verification TTS"
        func prepare() async throws {}
        func startCapture(onSegment: @escaping (Data) -> Void, onLevel: @escaping (Float) -> Void) throws {}
        func stopCapture() {}
        func transcribe(_ data: Data) async throws -> String { "fixture" }
        func speak(_ text: String, onLevel: @escaping (Float) -> Void) async throws {}
        func stopPlayback() {}
        func releaseResources() {}
    }

    static func runChecks() async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "VoiceCallVerification", code: checks.count + 1,
                                            userInfo: [NSLocalizedDescriptionKey: message]) }
            checks.append(message)
        }
        // Exercise the shipping VAD start/catch/teardown path without requesting
        // microphone access. Keep an unrelated suspension held to detect both
        // leaked ownership and accidental double-resume.
        try require(!AudioSessionCoordinator.shared.isCapturing,
                    "VAD startup-failure fixture begins without another recorder")
        let backgroundAudio = BackgroundKeepAliveManager.shared
        let originalSuspensions = backgroundAudio.silentAudioSuspendCount
        backgroundAudio.suspendSilentAudioForMedia(caller: "VoiceCallVerification.sentinel")
        do {
            defer { backgroundAudio.resumeSilentAudioForMedia(caller: "VoiceCallVerification.sentinel") }
            let detector = VoiceActivityDetector()
            detector.debugStartFailureAfterSessionAcquired = VoiceProviderError.parseError("Injected VAD startup failure")
            for attempt in 0..<20 {
                var rejected = false
                do { try detector.start() } catch { rejected = true }
                try require(rejected && !detector.isRunning,
                            "VAD startup failure \(attempt) leaves no running engine")
                try require(!AudioSessionCoordinator.shared.isCapturing,
                            "VAD startup failure \(attempt) releases capture intent")
                try require(backgroundAudio.silentAudioSuspendCount == originalSuspensions + 1,
                            "VAD startup failure \(attempt) balances only its own suspension")
                detector.stop()
                try require(backgroundAudio.silentAudioSuspendCount == originalSuspensions + 1,
                            "VAD stop after failure \(attempt) does not double-release")
            }
        }
        try require(backgroundAudio.silentAudioSuspendCount == originalSuspensions,
                    "VAD failure fixture restores original background audio ownership")
        let audio = Audio()
        let call = VoiceCallCoordinator(audio: audio)
        let vm = AIChatViewModel()
        vm.bindVoiceCall(call)
        defer { call.end(); vm.unbindVoiceCall(call) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("call-draft-\(UUID()).txt")
        try Data("untouched attachment".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let attachment = InputAttachment(fileName: "draft.txt", cacheURL: file, kind: .document)
        let loading = InputAttachment(fileName: "loading.jpg", cacheURL: file, kind: .image, loadState: .loading)
        let persistedReadAloud = VoiceOutputPreferences.isEnabled
        let persistedMute = VoiceOutputPreferences.isMuted

        for iteration in 0..<20 {
            call.start()
            for _ in 0..<20 where call.state == .preparing { await Task.yield() }
            try require(call.isActive, "Call \(iteration) starts with injected audio")
            vm.inputText = "保留草稿 \(iteration)"
            vm.inputCaret = 3
            vm.pendingCaret = 3
            vm.attachments = [attachment, loading]
            vm.skipCompactCheck = true
            let token = UUID()
            vm.voiceCallTurnID = token
            vm.voiceCallMessageStart = vm.messages.count
            let count = vm.messages.count
            // Execute the shipping call-send branch synchronously, then cancel
            // before yielding. This tests draft isolation without external I/O.
            vm.send(voiceCallText: "/不是命令 \(iteration)", voiceCallTurnID: token)
            try require(vm.messages.count == count + 1 && vm.messages.last?.role == .user,
                        "Call \(iteration) creates exactly one real user message")
            try require(vm.messages.last?.content == "/不是命令 \(iteration)",
                        "Call \(iteration) treats slash speech as ordinary text")
            try require(vm.inputText == "保留草稿 \(iteration)" && vm.attachments.map(\.id) == [attachment.id, loading.id],
                        "Call \(iteration) preserves composer draft and all attachments")
            try require(vm.inputCaret == 3 && vm.pendingCaret == 3 && vm.skipCompactCheck,
                        "Call \(iteration) preserves caret and composer compaction intent")
            vm.cancelVoiceCallTurn(UUID())
            try require(vm.isProcessing && vm.voiceCallTurnID == token,
                        "Call \(iteration) rejects another turn's cancellation")
            vm.cancelVoiceCallTurn(token)
            let prior = vm.voiceCallText
            vm.appendVoiceCallText("LATE AUDIO", turnID: token)
            try require(vm.voiceCallText == prior && !vm.isProcessing,
                        "Call \(iteration) rejects late text after cancellation")
            call.end()
            for _ in 0..<40 where vm.voiceCallRetiringTurnID != nil { await Task.yield() }
            try require(vm.voiceCallRetiringTurnID == nil, "Call \(iteration) retires cancelled model task")
        }
        try require(try Data(contentsOf: file) == Data("untouched attachment".utf8),
                    "Voice send never consumes or deletes the unsent attachment file")
        try require(VoiceOutputPreferences.isEnabled == persistedReadAloud && VoiceOutputPreferences.isMuted == persistedMute,
                    "Call sessions preserve persistent read-aloud and mute settings")
        call.start()
        for _ in 0..<20 where call.state == .preparing { await Task.yield() }
        vm.editingMessageIndex = 0
        let count = vm.messages.count
        try require(call.onSend?("不可覆盖编辑", UUID()) == false && vm.messages.count == count && vm.editingMessageIndex == 0,
                    "Call bridge rejects active message editing without truncating history")
        vm.editingMessageIndex = nil
        call.resume()
        vm.isProcessing = true
        try require(call.onSend?("不可覆盖任务", UUID()) == false && vm.messages.count == count,
                    "Call bridge rejects a busy conversation without sending another turn")
        vm.isProcessing = false
        call.resume()
        let interruptedTurn = UUID()
        vm.voiceCallTurnID = interruptedTurn
        vm.voiceCallText = ""
        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        try require(!vm.pauseVoiceCallAfterStreamError(networkError, turnID: interruptedTurn),
                    "An error before voice text leaves normal retry available")
        vm.voiceCallText = "已经播报的部分。"
        try require(!vm.pauseVoiceCallAfterStreamError(networkError, turnID: UUID()),
                    "A stale stream failure cannot pause another voice turn")
        try require(vm.pauseVoiceCallAfterStreamError(networkError, turnID: interruptedTurn)
                    && call.state == .paused && vm.voiceCallTurnID == nil,
                    "A partial voice stream failure pauses and invalidates its owner before retry")
        return checks
    }
}
#endif
