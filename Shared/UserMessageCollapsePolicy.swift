/// Shared, testable boundary rules for compacting oversized user prompts.
///
/// The threshold is language-neutral: characters and hard line breaks are
/// counted directly, so the same visual amount of Chinese and English text
/// collapses at the same point. The previous BPE-token threshold treated
/// ~500 Chinese characters and ~2,000 English characters as equivalent.
enum UserMessageCollapsePolicy {
    /// Messages strictly over this many characters start collapsed.
    static let characterThreshold = 1_200
    /// Also collapse short-but-tall prompts over this many hard line breaks.
    static let lineThreshold = 16
    /// Enough context to identify a prompt without letting it dominate the chat.
    static let collapsedLineLimit = 8

    static func shouldCollapse(characterCount: Int, lineCount: Int = 0) -> Bool {
        characterCount > characterThreshold || lineCount > lineThreshold
    }

    /// Language-neutral text check shared by the SwiftUI and collection-view
    /// rows. Counts Characters (extended grapheme clusters), not UTF-8 bytes.
    static func shouldCollapse(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // Character count, not bytes: one CJK character and one Latin letter
        // both count as 1. UTF-8 byte length would penalize CJK 3×.
        if text.count > characterThreshold {
            return true
        }
        var lineBreaks = 0
        for character in text where character == "\n" {
            lineBreaks += 1
            if lineBreaks > lineThreshold { return true }
        }
        return false
    }

    /// Returns the collection-view offset that keeps an item's top edge at the
    /// same screen coordinate after its height changes, clamped to the actual
    /// scrollable range. Kept here with the disclosure policy so the anchoring
    /// equation and its top/bottom boundary behavior stay unit-testable.
    static func viewportOffset(
        itemMinY: Double,
        preservedScreenMinY: Double,
        minimumOffset: Double,
        maximumOffset: Double
    ) -> Double {
        let lowerBound = min(minimumOffset, maximumOffset)
        let upperBound = max(minimumOffset, maximumOffset)
        let desiredOffset = itemMinY - preservedScreenMinY
        return min(max(desiredOffset, lowerBound), upperBound)
    }
}
