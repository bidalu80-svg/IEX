import XCTest
@testable import Ze

/// Regression coverage for Ze's user-configured OpenAI-compatible thinking
/// rules. These assertions pin the request shapes that are easy to break with
/// a seemingly harmless UI or provider refactor.
final class ThinkingRuleWireTests: XCTestCase {

    // MARK: - OpenAI-compatible inline thinking tags

    func testOpenAIThinkPrefixParserSupportsGeminiThinkingTag() {
        var parser = OpenAIAgentProvider.ThinkPrefixStreamParser()
        var thinking = ""
        var visible = ""

        let first = parser.consume("<thinking>先分析")
        thinking += first.thinking
        visible += first.visible
        let second = parser.consume("一下</thinking>最终答案")
        thinking += second.thinking
        visible += second.visible
        let tail = parser.finishTurn()
        thinking += tail.thinking
        visible += tail.visible

        XCTAssertEqual(thinking, "先分析一下")
        XCTAssertEqual(visible, "最终答案")
    }

    func testOpenAIThinkPrefixParserHandlesThinkingTagSplitAcrossChunks() {
        var parser = OpenAIAgentProvider.ThinkPrefixStreamParser()
        var thinking = ""
        var visible = ""

        for chunk in ["<thin", "king>分片", "思考</think", "ing>完成"] {
            let output = parser.consume(chunk)
            thinking += output.thinking
            visible += output.visible
        }
        let tail = parser.finishTurn()
        thinking += tail.thinking
        visible += tail.visible

        XCTAssertEqual(thinking, "分片思考")
        XCTAssertEqual(visible, "完成")
    }

    func testOpenAIThinkPrefixParserMatchesThinkingTagCaseInsensitively() {
        var parser = OpenAIAgentProvider.ThinkPrefixStreamParser()
        let output = parser.consume("<THINKING>reason</THINKING>answer")
        let tail = parser.finishTurn()

        XCTAssertEqual(output.thinking + tail.thinking, "reason")
        XCTAssertEqual(output.visible + tail.visible, "answer")
    }

    func testOpenAIThinkPrefixParserLeavesMidBodyTagUntouched() {
        var parser = OpenAIAgentProvider.ThinkPrefixStreamParser()
        let output = parser.consume("普通正文 <thinking>不是前缀")
        let tail = parser.finishTurn()

        XCTAssertEqual(output.thinking + tail.thinking, "")
        XCTAssertEqual(output.visible + tail.visible, "普通正文 <thinking>不是前缀")
    }

    private let instanceId = "thinking-rule-wire-tests"

    override func tearDown() {
        ThinkingRuleCache.shared.replace([], for: instanceId)
        super.tearDown()
    }

    func testFirstMatchingUserRuleWins() {
        let first = ThinkingRule(label: "first", scope: .allModels, format: .omit)
        let second = ThinkingRule(label: "second", scope: .allModels, format: .reasoningEffort)
        ThinkingRuleCache.shared.replace([first, second], for: instanceId)

        var body: [String: Any] = [:]
        XCTAssertTrue(ThinkingRuleResolver.applyCustomRule(
            to: &body, instanceId: instanceId, modelId: "gpt-5", level: .high, maxTokens: 4096
        ))
        XCTAssertTrue(body.isEmpty)
    }

    func testDeepSeekV4UsesRootSiblingEffort() {
        let rule = ThinkingRule(label: "v4", scope: .allModels, format: .deepSeekV4)
        ThinkingRuleCache.shared.replace([rule], for: instanceId)

        var enabled: [String: Any] = [:]
        _ = ThinkingRuleResolver.applyCustomRule(
            to: &enabled, instanceId: instanceId, modelId: "deepseek-v4-pro", level: .high, maxTokens: 4096
        )
        XCTAssertEqual((enabled["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(enabled["reasoning_effort"] as? String, "high")
        XCTAssertNil((enabled["thinking"] as? [String: Any])?["reasoning_effort"])

        var disabled: [String: Any] = [:]
        _ = ThinkingRuleResolver.applyCustomRule(
            to: &disabled, instanceId: instanceId, modelId: "deepseek-v4-pro", level: .off, maxTokens: 4096
        )
        XCTAssertEqual((disabled["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(disabled["reasoning_effort"])
    }

    func testQwenBudgetIsStrictlyBelowMaxTokens() {
        let rule = ThinkingRule(label: "qwen", scope: .allModels, format: .qwenDual)
        ThinkingRuleCache.shared.replace([rule], for: instanceId)

        var body: [String: Any] = [:]
        _ = ThinkingRuleResolver.applyCustomRule(
            to: &body, instanceId: instanceId, modelId: "qwen3", level: .high, maxTokens: 4096
        )
        let budget = try? XCTUnwrap(body["thinking_budget"] as? Int)
        XCTAssertNotNil(budget)
        XCTAssertLessThan(budget ?? Int.max, 4096)
        let extra = body["extra_body"] as? [String: Any]
        XCTAssertEqual(extra?["enable_thinking"] as? Bool, true)
    }

    func testModelPatternNormalizesDotsAndDashes() {
        let rule = ThinkingRule(label: "pattern", scope: .modelPattern("claude-opus-4.8*"), format: .omit)
        XCTAssertTrue(rule.scope.matches("claude-opus-4-8"))
        XCTAssertTrue(rule.scope.matches("CLAUDE.OPUS.4.8-latest"))
        XCTAssertFalse(rule.scope.matches("claude-sonnet-4-8"))
    }

    func testExtraBodyToggleAndCustomValue() {
        let toggle = ThinkingRule(
            label: "toggle", scope: .allModels, format: .extraBodyToggle,
            path: "extra_body.thinking.enabled"
        )
        let custom = ThinkingRule(
            label: "custom", scope: .modelPattern("custom-*"), format: .customPath,
            path: "reasoning.mode", customHighValue: "enabled"
        )
        ThinkingRuleCache.shared.replace([custom, toggle], for: instanceId)

        var customBody: [String: Any] = [:]
        _ = ThinkingRuleResolver.applyCustomRule(
            to: &customBody, instanceId: instanceId, modelId: "custom-model", level: .high, maxTokens: 4096
        )
        XCTAssertEqual(((customBody["reasoning"] as? [String: Any])?["mode"] as? String), "enabled")

        var toggleBody: [String: Any] = [:]
        _ = ThinkingRuleResolver.applyCustomRule(
            to: &toggleBody, instanceId: instanceId, modelId: "other-model", level: .off, maxTokens: 4096
        )
        XCTAssertEqual((((toggleBody["extra_body"] as? [String: Any])?["thinking"] as? [String: Any])?["enabled"] as? Bool), false)
    }
}
