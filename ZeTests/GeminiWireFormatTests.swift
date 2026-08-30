import XCTest

/// [T-gemini-empty-part-oneof-400] Regression tests pinning the Gemini
/// wire-format invariant: a part's text is NEVER the empty string, so the
/// protobuf `oneof` is always initialised and the API doesn't 400 with
/// "required oneof field 'data' must have one initialized field". Repro'd on
/// Gemini 3.5 Flash tool calls (empty assistant/model text after a
/// thinking-heavy or safety-stripped turn).
final class GeminiWireFormatTests: XCTestCase {

    // MARK: - Tagged thinking parser

    func testTaggedThinkingParserSeparatesInlineThinking() {
        var parser = GeminiTaggedThinkingParser()
        let segments = parser.feed("正文前<thinking>先分析一下</thinking>正文后") + parser.finish()
        XCTAssertEqual(segments, [
            .init(isThinking: false, text: "正文前"),
            .init(isThinking: true, text: "先分析一下"),
            .init(isThinking: false, text: "正文后")
        ])
    }

    func testTaggedThinkingParserHandlesTagsSplitAcrossSSEChunks() {
        var parser = GeminiTaggedThinkingParser()
        var segments: [GeminiTaggedThinkingParser.Segment] = []
        for chunk in ["<thin", "king>分片", "思考</think", "ing>完成"] {
            segments += parser.feed(chunk)
        }
        segments += parser.finish()
        XCTAssertEqual(segments, [
            .init(isThinking: true, text: "分片思考"),
            .init(isThinking: false, text: "完成")
        ])
    }

    func testTaggedThinkingParserIsCaseInsensitive() {
        var parser = GeminiTaggedThinkingParser()
        let segments = parser.feed("<THINKING>reason</THINKING>answer") + parser.finish()
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].isThinking)
        XCTAssertEqual(segments[0].text, "reason")
        XCTAssertFalse(segments[1].isThinking)
        XCTAssertEqual(segments[1].text, "answer")
    }

    func testTaggedThinkingParserFlushesUnclosedThinkingAtEnd() {
        var parser = GeminiTaggedThinkingParser()
        let segments = parser.feed("<thinking>未闭合") + parser.finish()
        XCTAssertEqual(segments, [.init(isThinking: true, text: "未闭合")])
    }

    // MARK: - nonEmptyText

    func testNonEmptyText_emptyString_becomesSpace() {
        XCTAssertEqual(GeminiWireFormat.nonEmptyText(""), " ")
    }

    func testNonEmptyText_nil_becomesSpace() {
        XCTAssertEqual(GeminiWireFormat.nonEmptyText(nil), " ")
    }

    func testNonEmptyText_nonEmpty_preserved() {
        XCTAssertEqual(GeminiWireFormat.nonEmptyText("hello"), "hello")
    }

    func testNonEmptyText_whitespaceOnly_preserved() {
        // A single space is already valid — don't collapse or trim it away.
        XCTAssertEqual(GeminiWireFormat.nonEmptyText(" "), " ")
        XCTAssertEqual(GeminiWireFormat.nonEmptyText("\n"), "\n")
    }

    // MARK: - textPart (empty text turn → never {"text":""})

    func testTextPart_emptyText_neverEmpty() {
        let part = GeminiWireFormat.textPart("")
        XCTAssertEqual(part["text"] as? String, " ",
                       "{\"text\":\"\"} triggers Gemini oneof 400 — must be substituted")
    }

    func testTextPart_nilText_neverEmpty() {
        XCTAssertEqual(GeminiWireFormat.textPart(nil)["text"] as? String, " ")
    }

    func testTextPart_realText_passesThrough() {
        XCTAssertEqual(GeminiWireFormat.textPart("[Called foo with: {}]")["text"] as? String,
                       "[Called foo with: {}]")
    }

    // MARK: - functionResponseResult (empty tool result content → never empty)

    func testFunctionResponseResult_emptyContent_neverEmpty() {
        let resp = GeminiWireFormat.functionResponseResult("")
        XCTAssertEqual(resp["result"] as? String, " ",
                       "empty tool result would ship an empty string into the response payload")
    }

    func testFunctionResponseResult_nilContent_neverEmpty() {
        XCTAssertEqual(GeminiWireFormat.functionResponseResult(nil)["result"] as? String, " ")
    }

    func testFunctionResponseResult_realContent_passesThrough() {
        XCTAssertEqual(GeminiWireFormat.functionResponseResult("ok")["result"] as? String, "ok")
    }

    // MARK: - Guarantee: no produced part ever carries an empty string

    func testInvariant_noEmptyStringEverProduced() {
        for input: String? in [nil, "", " ", "x", "多字节文本"] {
            XCTAssertFalse((GeminiWireFormat.textPart(input)["text"] as? String)?.isEmpty ?? true,
                           "textPart must never yield an empty string (input=\(String(describing: input)))")
            XCTAssertFalse((GeminiWireFormat.functionResponseResult(input)["result"] as? String)?.isEmpty ?? true,
                           "functionResponseResult must never yield an empty string (input=\(String(describing: input)))")
        }
    }
}
