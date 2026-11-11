import Foundation

enum VoiceCallState: String, Equatable {
    case idle, preparing, listening, transcribing, responding, speaking, muted, paused

    var title: String {
        switch self {
        case .idle: return "语音通话"
        case .preparing: return "正在准备"
        case .listening: return "正在听"
        case .transcribing: return "正在识别"
        case .responding: return "正在思考"
        case .speaking: return "正在说话"
        case .muted: return "麦克风已静音"
        case .paused: return "通话已暂停"
        }
    }
}

/// Consumes cumulative visible assistant text exactly once. Only complete
/// sentences are released during streaming; fenced code is never spoken.
struct VoiceCallSpeechBuffer {
    private var received = ""
    private var pending = ""
    private var insideFence = false

    mutating func append(_ cumulative: String, final: Bool = false) -> [String] {
        // A stale or rewritten prefix is not safe to replay as new speech.
        guard cumulative.hasPrefix(received) else { return [] }
        pending += cumulative.dropFirst(received.count)
        received = cumulative
        var result: [String] = []
        var sentence = ""
        var consumed = pending.startIndex
        var index = pending.startIndex
        while index < pending.endIndex {
            let rest = pending[index...]
            if rest.hasPrefix("```") {
                if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(sentence)
                }
                sentence = ""
                insideFence.toggle()
                index = pending.index(index, offsetBy: 3)
                consumed = index
                continue
            }
            // A streamed fence prefix must wait for the following chunk.
            if !final && (rest == "`" || rest == "``") { break }
            let character = pending[index]
            let next = pending.index(after: index)
            if insideFence {
                index = next
                consumed = index
                continue
            }
            sentence.append(character)
            // Latin full stops wait for whitespace to avoid splitting decimals.
            let terminator = "。！？!?；;\n".contains(character)
                || (character == "." && next < pending.endIndex && pending[next].isWhitespace)
            if terminator {
                if !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(sentence)
                }
                sentence = ""
                consumed = next
            }
            index = next
        }
        if final {
            if !insideFence && !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(sentence)
            }
            pending = ""
        } else {
            pending = String(pending[consumed...])
        }
        return result
    }
}
