/// Shared, testable boundary rules for compacting oversized user prompts.
enum UserMessageCollapsePolicy {
    /// Messages strictly over this BPE token count start collapsed.
    static let tokenThreshold = 500
    /// Enough context to identify a prompt without letting it dominate the chat.
    static let collapsedLineLimit = 8

    static func shouldCollapse(tokenCount: Int) -> Bool {
        tokenCount > tokenThreshold
    }

    /// A BPE token always covers at least one UTF-8 byte, so text at or below
    /// 500 bytes is provably at or below 500 tokens. This exact fast path keeps
    /// ordinary short bubbles from loading/running the tokenizer at all.
    static func shouldCollapse(_ text: String, tokenCounter: () -> Int) -> Bool {
        guard text.utf8.count > tokenThreshold else { return false }
        return shouldCollapse(tokenCount: tokenCounter())
    }
}
