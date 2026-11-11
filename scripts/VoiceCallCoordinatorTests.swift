import Foundation

private enum TestCallError: LocalizedError {
    case failed
    var errorDescription: String? { "测试服务失败" }
}

@MainActor
private final class TestCallAudio: VoiceCallAudio {
    var onInterruption: ((String) -> Void)?
    var inputLabel = "Test recognition"
    var outputLabel = "Test speech"
    var segments: [(Data) -> Void] = []
    var meters: [(Float) -> Void] = []
    var recognitions: [CheckedContinuation<String, Error>] = []
    var playbacks: [CheckedContinuation<Void, Error>] = []
    var preparation: [CheckedContinuation<Void, Error>] = []
    var holdPreparation = false
    var spoken: [String] = []
    var captureRunning = false
    var stopPlaybackCount = 0
    var releaseCount = 0

    func prepare() async throws {
        if holdPreparation {
            try await withCheckedThrowingContinuation { preparation.append($0) }
        }
    }
    func startCapture(onSegment: @escaping (Data) -> Void, onLevel: @escaping (Float) -> Void) throws {
        captureRunning = true
        segments.append(onSegment); meters.append(onLevel)
    }
    func stopCapture() { captureRunning = false }
    func transcribe(_ data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { recognitions.append($0) }
    }
    func speak(_ text: String, onLevel: @escaping (Float) -> Void) async throws {
        spoken.append(text)
        onLevel(0.4)
        try await withCheckedThrowingContinuation { playbacks.append($0) }
    }
    // Intentionally hostile: cancellation doesn't finish our async callbacks.
    // The coordinator must reject their later results by generation/turn ID.
    func stopPlayback() { stopPlaybackCount += 1 }
    func release() { releaseCount += 1; stopCapture(); stopPlayback() }
}

@main
struct VoiceCallCoordinatorTests {
    @MainActor static func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }

    @MainActor static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS: \(name)")
        }
        var buffer = VoiceCallSpeechBuffer()
        check(buffer.append("你好").isEmpty, "partial phrase waits")
        check(buffer.append("你好。")==["你好。"], "complete sentence released once")
        check(buffer.append("你好。").isEmpty, "duplicate cumulative text not repeated")
        check(buffer.append("你好。```swift\nprint(1)").isEmpty, "open fenced code never spoken")
        check(buffer.append("你好。```swift\nprint(1)\n```后续！") == ["后续！"], "code skipped across stream chunks")
        check(buffer.append("你好。```swift\nprint(1)\n```后续！尾句", final: true) == ["尾句"], "final tail flushed")
        var latin = VoiceCallSpeechBuffer()
        check(latin.append("The value is 3.14").isEmpty, "decimal not cut into a sentence")
        check(latin.append("The value is 3.14. Next") == ["The value is 3.14."], "Latin sentence boundary waits for whitespace")

        let audio = TestCallAudio()
        let call = VoiceCallCoordinator(audio: audio)
        var sent: [(String, UUID)] = []
        var cancelled: [UUID] = []
        call.onSend = { text, id in sent.append((text,id)); return true }
        call.onCancelTurn = { id in
            cancelled.append(id)
            call.receiveAssistantText("迟到消息。", turnID: id)
            call.finishResponse(turnID: id)
        }
        call.start(); await drain()
        check(call.isActive && call.state == .listening && audio.captureRunning, "start reaches listening")
        check(call.startDate != nil && call.inputLabel == audio.inputLabel, "actual prepared metadata published")
        call.start(); await drain()
        check(audio.segments.count == 1, "double start does not duplicate mic")

        for round in 0..<20 {
            let previousCapture = audio.segments.last!
            previousCapture(Data([1]))
            previousCapture(Data([1]))
            await drain()
            check(audio.recognitions.count == 1 && !audio.captureRunning, "round \(round): segment submits once and mic closes")
            audio.recognitions.removeFirst().resume(returning: "嗯")
            await drain()
            let id = sent.last!.1
            check(sent.last!.0 == "嗯" && call.state == .responding, "round \(round): short utterance submitted")
            call.receiveAssistantText("第一句。", turnID: id)
            await drain()
            check(call.state == .speaking && audio.playbacks.count == 1, "round \(round): first sentence streams")
            call.receiveAssistantText("第一句。第二句", turnID: id)
            audio.playbacks.removeFirst().resume()
            await drain()
            check(call.state == .responding && !audio.captureRunning, "round \(round): temporary queue drain never reopens mic")
            call.finishResponse(turnID: id)
            await drain()
            check(audio.playbacks.count == 1 && !audio.captureRunning, "round \(round): final tail must finish playback")
            audio.playbacks.removeFirst().resume()
            await drain()
            check(call.state == .listening && audio.captureRunning, "round \(round): all audio drained automatically reopens mic")
            previousCapture(Data([2])); await drain()
            check(audio.recognitions.isEmpty, "round \(round): retired capture callbacks ignored")
        }
        check(sent.count == 20, "20 rounds have exactly 20 messages")

        audio.segments.last!(Data([1])); await drain()
        call.toggleMute()
        check(call.isMuted && call.state == .muted && !audio.captureRunning, "muting cancels pending recognition")
        audio.recognitions.removeFirst().resume(returning: "must not send")
        await drain()
        check(sent.count == 20 && call.state == .muted, "late recognition after mute discarded")
        call.toggleMute(); await drain()
        check(call.state == .listening && audio.captureRunning, "unmute resumes listening")

        audio.segments.last!(Data([1])); await drain()
        audio.recognitions.removeFirst().resume(returning: "question")
        await drain()
        let interruptedID = sent.last!.1
        call.receiveAssistantText("正在播报。", turnID: interruptedID); await drain()
        call.interruptAndListen()
        let captures = audio.segments.count
        audio.playbacks.removeFirst().resume(); await drain()
        check(cancelled.contains(interruptedID), "manual interruption cancels owned model turn")
        check(audio.segments.count == captures && call.state == .listening, "late playback and synchronous cancellation callbacks ignored")

        audio.segments.last!(Data([1])); await drain()
        audio.recognitions.removeFirst().resume(returning: "muted response")
        await drain()
        let mutedID = sent.last!.1
        call.receiveAssistantText("回复。", turnID: mutedID); await drain()
        call.toggleMute()
        call.finishResponse(turnID: mutedID)
        audio.playbacks.removeFirst().resume(); await drain()
        check(call.state == .muted && !audio.captureRunning, "muting during reply prevents automatic capture")
        call.toggleMute(); await drain()

        audio.onInterruption?("system interruption")
        check(call.state == .paused && !audio.captureRunning && call.error != nil, "system interruption requires explicit resume")
        call.resume(); await drain()
        check(call.state == .listening, "resume after interruption")
        let retainedCapture = audio.segments.last!
        retainedCapture(Data([1])); await drain()
        call.end()
        let sentBeforeEnd = sent.count
        audio.recognitions.removeFirst().resume(returning: "late after hangup")
        retainedCapture(Data([2])); await drain()
        check(!call.isActive && call.state == .idle && !audio.captureRunning, "hangup releases audio and stays idle")
        check(sent.count == sentBeforeEnd && audio.releaseCount == 1, "late callbacks after hangup never send")

        let slow = TestCallAudio(); slow.holdPreparation = true
        let permissions = VoiceCallCoordinator(audio: slow)
        permissions.start(); await drain()
        permissions.end()
        permissions.start(); await drain()
        slow.preparation.removeFirst().resume(); await drain()
        check(permissions.state == .preparing && slow.segments.isEmpty, "old permission completion cannot start restarted call")
        slow.preparation.removeFirst().resume(); await drain()
        check(permissions.state == .listening && slow.segments.count == 1, "new call owns its permission completion")
        permissions.end()

        call.start(); await drain()
        call.onSend = { _, _ in false }
        audio.segments.last!(Data([1])); await drain()
        audio.recognitions.removeFirst().resume(returning: "busy")
        await drain()
        check(call.state == .paused && call.error != nil && !audio.captureRunning, "busy chat bridge surfaces pause rather than dropping silently")
        call.end()
        call.onSend = { _, _ in call.pause(reason: "具体模型尚未配置"); return false }
        call.start(); await drain()
        audio.segments.last!(Data([1])); await drain()
        audio.recognitions.removeFirst().resume(returning: "bridge error")
        await drain()
        check(call.error == "具体模型尚未配置", "specific synchronous bridge error is preserved")
        call.end()
        call.onSend = { text, id in sent.append((text, id)); return true }
        call.start(); await drain()
        audio.segments.last!(Data([1])); await drain()
        let beforeEmpty = sent.count
        audio.recognitions.removeFirst().resume(returning: "  \n")
        await drain()
        check(call.state == .listening && sent.count == beforeEmpty, "empty recognition re-arms without empty message")
        audio.segments.last!(Data([1])); await drain()
        audio.recognitions.removeFirst().resume(throwing: TestCallError.failed)
        await drain()
        check(call.state == .paused && call.error == "测试服务失败", "recognition failure retains actual service error")
        call.resume(); await drain()
        audio.segments.last!(Data([1])); await drain()
        audio.recognitions.removeFirst().resume(returning: "audio error")
        await drain()
        let failingID = sent.last!.1
        call.receiveAssistantText("播放失败。", turnID: failingID); await drain()
        audio.playbacks.removeFirst().resume(throwing: TestCallError.failed)
        await drain()
        check(call.state == .paused && !audio.captureRunning && call.error == "测试服务失败", "playback failure pauses and never silently skips a sentence")
        call.receiveAssistantText("迟到。", turnID: failingID)
        call.finishResponse(turnID: failingID)
        check(call.state == .paused && audio.playbacks.isEmpty, "failed turn cannot revive after later completion")
        call.end()
        for _ in 0..<20 { call.start(); call.end() }
        await drain()
        check(!call.isActive && !audio.captureRunning, "20 rapid start/hangup cycles leave no capture")
        print("Voice call lifecycle checks passed: \(checks)")
    }
}
