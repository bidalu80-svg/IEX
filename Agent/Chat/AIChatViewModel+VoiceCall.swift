import Foundation

/// Inherited by structured streaming tasks, independent of whichever turn is
/// currently displayed by the UI. Late events retain their original owner.
enum VoiceCallTaskContext {
    @TaskLocal static var turnID: UUID?
}

/// Keep fenced and inline code out of live speech, including incomplete fences
/// and inline spans while the model is still streaming their contents.
enum VoiceCallSpeechProjection {
    static func visibleText(_ source: String) -> String {
        var fence: Character?
        var fenceCount = 0
        var result: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let marker = trimmed.first
            let count = (marker == "`" || marker == "~")
                ? trimmed.prefix(while: { $0 == marker }).count : 0
            if let active = fence {
                if marker == active && count >= fenceCount {
                    fence = nil
                    fenceCount = 0
                }
                continue
            }
            if count >= 3 {
                fence = marker
                fenceCount = count
                continue
            }
            // Four-space/tab indented Markdown code is not spoken either.
            if line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            var inlineDelimiter = 0
            var visible = ""
            let characters = Array(line)
            var index = 0
            while index < characters.count {
                if characters[index] == "`" {
                    var end = index
                    while end < characters.count, characters[end] == "`" { end += 1 }
                    let length = end - index
                    if inlineDelimiter == 0 { inlineDelimiter = length }
                    else if inlineDelimiter == length { inlineDelimiter = 0 }
                    index = end
                    continue
                }
                if inlineDelimiter == 0 { visible.append(characters[index]) }
                index += 1
            }
            result.append(visible)
        }
        return result.joined(separator: "\n")
    }
}

extension AIChatViewModel {
    func bindVoiceCall(_ coordinator: VoiceCallCoordinator) {
        if let previous = voiceCallCoordinator, previous !== coordinator {
            previous.end()
        }
        voiceCallCoordinator = coordinator
        voiceCallSessionID = sessionId
        coordinator.onSend = { [weak self, weak coordinator] text, turnID in
            guard let self, let coordinator, self.voiceCallCoordinator === coordinator else { return false }
            return self.submitVoiceCallText(text, turnID: turnID, coordinator: coordinator)
        }
        coordinator.onCancelTurn = { [weak self, weak coordinator] turnID in
            guard let self, let coordinator, self.voiceCallCoordinator === coordinator else { return }
            self.cancelVoiceCallTurn(turnID)
        }
        // Do not persistently toggle the user's read-replies preference.
        stopSpeechForThisSession()
    }

    func unbindVoiceCall(_ coordinator: VoiceCallCoordinator) {
        guard voiceCallCoordinator === coordinator else { return }
        if let turnID = voiceCallTurnID { cancelVoiceCallTurn(turnID) }
        coordinator.onSend = nil
        coordinator.onCancelTurn = nil
        voiceCallCoordinator = nil
        voiceCallSessionID = nil
    }

    private func submitVoiceCallText(_ text: String, turnID: UUID,
                                     coordinator: VoiceCallCoordinator) -> Bool {
        let failure: String?
        if !coordinator.isActive {
            return false
        } else if voiceCallRetiringTurnID != nil {
            failure = "上一轮正在停止，请稍后继续。"
        } else if remoteDeviceId != nil {
            failure = "只读对话暂时不能进行语音通话。"
        } else if isProcessing || isCompacting || !promptQueue.isEmpty || scheduledTurnCompletion != nil {
            failure = "当前对话正在处理其他消息，请完成后继续通话。"
        } else if editingMessageIndex != nil {
            failure = "请先完成或取消消息编辑，再继续通话。"
        } else if showCompactBeforeSendPrompt || showContextExhaustedPrompt || checkContextBeforeSend() != .ok {
            failure = "对话上下文需要整理，请先压缩对话或新建对话。"
        } else if !isReady || resolveCurrentEntry() == nil {
            failure = "请先为当前对话选择可用模型。"
        } else if let original = voiceCallSessionID, original != sessionId {
            failure = "对话已切换，请重新开始语音通话。"
        } else {
            failure = nil
        }
        if let failure {
            coordinator.pause(reason: failure)
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        voiceCallSessionID = sessionId // nil -> real ID is allowed for the first turn.
        voiceCallTurnID = turnID
        voiceCallText = ""
        voiceCallLastProjection = .distantPast
        voiceCallMessageStart = messages.count
        send(voiceCallText: text, voiceCallTurnID: turnID)
        return isProcessing
    }

    func appendVoiceCallText(_ delta: String, turnID: UUID) {
        guard voiceCallTurnID == turnID, voiceCallCoordinator?.isActive == true else { return }
        voiceCallText += delta
        // Avoid rescanning a long streamed Markdown answer on every token.
        guard Date().timeIntervalSince(voiceCallLastProjection) >= 0.15 else { return }
        voiceCallLastProjection = Date()
        voiceCallCoordinator?.receiveAssistantText(VoiceCallSpeechProjection.visibleText(voiceCallText), turnID: turnID)
    }

    func finishVoiceCallTurn(_ turnID: UUID, error: String? = nil) {
        if voiceCallRetiringTurnID == turnID { voiceCallRetiringTurnID = nil }
        guard voiceCallTurnID == turnID else { return }
        voiceCallCoordinator?.receiveAssistantText(VoiceCallSpeechProjection.visibleText(voiceCallText), turnID: turnID)
        voiceCallTurnID = nil // clear ownership before invoking client callbacks
        voiceCallSessionID = sessionId
        let assistantError = messages.dropFirst(min(voiceCallMessageStart, messages.count))
            .last(where: { $0.role == .assistant })?.error
        let failure = error ?? errorMessage ?? assistantError
            ?? (Task.isCancelled || userDidCancel ? "本轮回复已停止。" : nil)
        voiceCallCoordinator?.finishResponse(turnID: turnID, error: failure)
    }

    func cancelVoiceCallTurn(_ turnID: UUID) {
        guard voiceCallTurnID == turnID else { return }
        voiceCallTurnID = nil // cancelled stream callbacks cannot become a new turn
        voiceCallRetiringTurnID = turnID
        if isProcessing { cancel() }
        else { voiceCallRetiringTurnID = nil }
    }
}
