import Foundation

/// [T-gemini-empty-part-oneof-400] Pure, testable helpers that enforce Gemini's
/// wire-format invariants when building `contents[].parts[]`.
///
/// Gemini's REST API models a part's payload as a protobuf `oneof` ("data"). An
/// EMPTY text part — `{"text": ""}` — is treated as an *uninitialized* oneof and
/// rejected:
///
///   contents[N].parts[M].data: required oneof field 'data' must have one
///   initialized field  (HTTP 400 INVALID_ARGUMENT)
///
/// This bites Gemini 3.x / 3.5 Flash especially: a thinking-heavy turn (whole
/// budget spent thinking) or a safety-stripped candidate can yield an empty
/// assistant text, and a naive `{"text": text}` then ships `{"text": ""}` → 400,
/// surfacing to users as "tool format errors". The fix (cc-plugins #99, verified
/// against the live gateway: `{"text":""}`→400, `{"text":" "}`→200) is to never
/// emit an empty text part — substitute a single space.
///
/// Centralised here so every call site shares one guarantee and a regression
/// test can pin the behaviour.
enum GeminiWireFormat {

    /// Placeholder used in place of an empty text so the `oneof` is always
    /// initialised. A single space is the minimal non-empty, semantically-inert
    /// value (mirrors the Anthropic path's "never send an empty text block").
    static let nonEmptyPlaceholder = " "

    /// Coerce a text value so it is never the empty string. `nil`/`""` → `" "`.
    static func nonEmptyText(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return nonEmptyPlaceholder }
        return text
    }

    /// Build a text part guaranteed to satisfy the oneof constraint (never empty).
    static func textPart(_ text: String?) -> [String: Any] {
        ["text": nonEmptyText(text)]
    }

    /// The `response` object for a `functionResponse` part, guaranteeing the
    /// wrapped `result` string is never empty (an empty tool result would ship an
    /// empty string into the response payload).
    static func functionResponseResult(_ content: String?) -> [String: Any] {
        ["result": nonEmptyText(content)]
    }
}

/// Parses reasoning emitted by OpenAI-compatible Gemini gateways as inline
/// `<thinking>...</thinking>` text. Native Gemini responses mark thought parts
/// with `thought: true`; some relays instead serialize the same content into
/// ordinary text, and SSE boundaries may split either tag across chunks.
struct GeminiTaggedThinkingParser: Sendable {
    struct Segment: Equatable, Sendable {
        let isThinking: Bool
        let text: String
    }

    private static let openTag = "<thinking>"
    private static let closeTag = "</thinking>"
    private var buffer = ""
    private var inThinking = false

    mutating func feed(_ chunk: String) -> [Segment] {
        guard !chunk.isEmpty else { return [] }
        buffer += chunk
        return drain(final: false)
    }

    mutating func finish() -> [Segment] {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> [Segment] {
        var output: [Segment] = []
        while true {
            let marker = inThinking ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: marker, options: [.caseInsensitive]) {
                let prefix = String(buffer[..<range.lowerBound])
                if !prefix.isEmpty { output.append(Segment(isThinking: inThinking, text: prefix)) }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                inThinking.toggle()
                continue
            }

            if final {
                if !buffer.isEmpty { output.append(Segment(isThinking: inThinking, text: buffer)) }
                buffer.removeAll(keepingCapacity: false)
                break
            }

            // Keep a possible partial marker for the next SSE chunk. Everything
            // before that suffix is safe to emit immediately.
            let markerLower = marker.lowercased()
            let bufferLower = buffer.lowercased()
            var keep = 0
            let maxKeep = min(markerLower.count - 1, bufferLower.count)
            if maxKeep > 0 {
                for count in stride(from: maxKeep, through: 1, by: -1) {
                    if bufferLower.suffix(count) == markerLower.prefix(count) {
                        keep = count
                        break
                    }
                }
            }
            let emitCount = buffer.count - keep
            if emitCount > 0 {
                let end = buffer.index(buffer.startIndex, offsetBy: emitCount)
                output.append(Segment(isThinking: inThinking, text: String(buffer[..<end])))
                buffer.removeSubrange(buffer.startIndex..<end)
            }
            break
        }
        return output
    }
}
