// No app target, UIKit, SwiftUI, Combine or package dependencies required.
// macOS / Linux (from repository root):
// swiftc Shared/ConsecutiveToolCallsPolicy.swift scripts/ConsecutiveToolCallsTests.swift -o /tmp/ConsecutiveToolCallsTests
// /tmp/ConsecutiveToolCallsTests
import Foundation

@main
struct ConsecutiveToolCallsTests {
    static func main() {
        var tests = TestSuite()
        tests.run()
    }
}

private struct TestSuite {
    private var checks = 0
    private typealias Policy = ConsecutiveToolCallsPolicy

    private mutating func check(_ value: Bool, _ name: String) {
        guard value else { fatalError("FAIL: \(name)") }
        checks += 1
    }

    private mutating func expect(
        _ input: [Bool], _ expected: [Range<Int>], _ name: String, enabled: Bool = true
    ) {
        check(Policy.ranges(isTool: input, enabled: enabled) == expected, name)
    }

    mutating func run() {
        check(Policy.preferenceKey == "chat.collapseConsecutiveToolCalls", "preference key")
        check(Policy.defaultEnabled, "default enabled")
        examples()
        semanticBoundaries()
        appendExamples()
        exhaustiveGrouping()
        summaries()
        durationTests()
        print("PASS: \(checks) checks; 2047 Boolean sequences (length 0...10), both toggle states; 3280 state sequences (length 0...7); duration tests.")
    }

    private mutating func examples() {
        expect([], [], "empty")
        expect([true], [0..<1], "single tool")
        expect([false], [0..<1], "single non-tool")
        expect([true, true], [0..<2], "two tools")
        expect([true, true, true, true], [0..<4], "long run")
        expect([false, false, false], [0..<1, 1..<2, 2..<3], "non-tools never merge")
        expect([true, false, true], [0..<1, 1..<2, 2..<3], "nonconsecutive tools")
        expect([false, true, true, false, true, true, true, false, true],
               [0..<1, 1..<3, 3..<4, 4..<7, 7..<8, 8..<9], "mixed runs in source order")
        expect([], [], "disabled empty", enabled: false)
        expect([true, true, false, true], [0..<1, 1..<2, 2..<3, 3..<4],
               "disabled all singletons", enabled: false)
    }

    private enum Block: Equatable {
        case tool(Int)
        case text(String)
        case thinking(String)
        case info(String)
        case finalSummary(String)

        var isTool: Bool {
            if case .tool = self { return true }
            return false
        }
    }

    private mutating func semanticBoundaries() {
        let boundaries: [Block] = [
            .text("middle text"), .text(""), .thinking("reasoning"), .thinking(""),
            .info("info"), .info(""), .finalSummary("final answer"), .finalSummary("")
        ]
        for boundary in boundaries {
            let source: [Block] = [.tool(0), .tool(1), boundary, .tool(2), .tool(3)]
            let snapshot = source
            let ranges = Policy.ranges(isTool: source.map(\.isTool), enabled: true)
            check(ranges == [0..<2, 2..<3, 3..<5], "semantic boundary: \(boundary)")
            check(ranges.flatMap { Array(source[$0]) } == snapshot, "unchanged source contents")
            check(source == snapshot, "source not mutated")
        }
        let finalAnswer: [Block] = [.tool(0), .tool(1), .finalSummary(""), .text("answer")]
        check(Policy.ranges(isTool: finalAnswer.map(\.isTool), enabled: true)
              == [0..<2, 2..<3, 3..<4], "final summary and following text remain independent")

        // Message isolation is a CALLER contract: process separately, never
        // flatten messages into one Bool array, which loses their boundaries.
        let messages: [[Block]] = [[.tool(0), .tool(1)], [], [.tool(2)], [.tool(3), .tool(4)]]
        let grouped = messages.map { Policy.ranges(isTool: $0.map(\.isTool), enabled: true) }
        check(grouped == [[0..<2], [], [0..<1], [0..<2]], "message-local indices and isolation")
        for (message, ranges) in zip(messages, grouped) {
            check(ranges.flatMap { Array(message[$0]) } == message, "message content preserved")
        }
    }

    private mutating func appendExamples() {
        let original = [true, true, false, true]
        expect(original, [0..<2, 2..<3, 3..<4], "append baseline")
        expect(original + [true], [0..<2, 2..<3, 3..<5], "only trailing tool range extends")
        expect(original + [false], [0..<2, 2..<3, 3..<4, 4..<5], "boundary closes trailing tool")
        expect(original + [false, true, true], [0..<2, 2..<3, 3..<4, 4..<5, 5..<7],
               "append after boundary preserves closed groups")
    }

    /// Independent oracle: insert a cut unless both adjacent entries are tools.
    private func reference(_ input: [Bool], enabled: Bool) -> [Range<Int>] {
        guard !input.isEmpty else { return [] }
        let cuts = [0] + input.indices.dropFirst().filter {
            !enabled || !input[$0 - 1] || !input[$0]
        } + [input.count]
        return zip(cuts, cuts.dropFirst()).map { $0.0..<$0.1 }
    }

    private mutating func exhaustiveGrouping() {
        var sequenceCount = 0
        for length in 0...10 {
            for mask in 0..<(1 << length) {
                let input = (0..<length).map { (mask & (1 << $0)) != 0 }
                let snapshot = input
                sequenceCount += 1
                for enabled in [false, true] {
                    let context = "length=\(length) mask=\(mask) enabled=\(enabled)"
                    let ranges = Policy.ranges(isTool: input, enabled: enabled)
                    check(ranges == reference(input, enabled: enabled), "reference \(context)")
                    check(ranges == Policy.ranges(isTool: input, enabled: enabled), "determinism \(context)")
                    check(input == snapshot, "input immutability \(context)")
                    let flattened = ranges.flatMap { Array($0) }
                    check(flattened == Array(input.indices), "no omissions, duplicates or reordering \(context)")
                    check(Set(flattened).count == length, "unique indices \(context)")
                    check(ranges.isEmpty == input.isEmpty, "empty equivalence \(context)")
                    for range in ranges {
                        check(!range.isEmpty && range.lowerBound >= 0 && range.upperBound <= length,
                              "valid nonempty range \(context)")
                        if !enabled {
                            check(range.count == 1, "disabled singleton \(context)")
                        } else if !input[range.lowerBound] {
                            check(range.count == 1, "non-tool singleton \(context)")
                        } else {
                            check(range.allSatisfy { input[$0] }, "tool-only range \(context)")
                            check(range.lowerBound == 0 || !input[range.lowerBound - 1],
                                  "maximal left tool boundary \(context)")
                            check(range.upperBound == length || !input[range.upperBound],
                                  "maximal right tool boundary \(context)")
                        }
                    }
                    for (left, right) in zip(ranges, ranges.dropFirst()) {
                        check(left.upperBound == right.lowerBound, "contiguous partition \(context)")
                    }

                    for appended in [false, true] {
                        let extended = Policy.ranges(isTool: input + [appended], enabled: enabled)
                        let extendsTail = enabled && appended && input.last == true
                        let stableCount = ranges.count - (extendsTail ? 1 : 0)
                        check(Array(extended.prefix(stableCount)) == Array(ranges.prefix(stableCount)),
                              "append preserves closed ranges \(context)")
                        if extendsTail, let last = ranges.last {
                            check(extended.last == last.lowerBound..<(length + 1),
                                  "append extends only tail with stable lower bound \(context)")
                            check(extended.count == ranges.count, "tail extension count \(context)")
                        } else {
                            check(extended.last == length..<(length + 1), "new singleton appended \(context)")
                            check(extended.count == ranges.count + 1, "new range count \(context)")
                        }
                    }

                    // Any streamed prefix is the same partition as clipping
                    // the full result to that prefix (only the tail can grow).
                    for prefixLength in 0...length {
                        let clipped = ranges.compactMap { range -> Range<Int>? in
                            guard range.lowerBound < prefixLength else { return nil }
                            return range.lowerBound..<min(range.upperBound, prefixLength)
                        }
                        check(Policy.ranges(isTool: Array(input.prefix(prefixLength)), enabled: enabled) == clipped,
                              "stable streaming prefix \(prefixLength) \(context)")
                    }
                }
            }
        }
        check(sequenceCount == 2047, "all Boolean sequences through length ten visited")
    }

    private mutating func summaries() {
        check(Policy.summary(states: []) == .init(total: 0, failed: 0, running: 0), "empty summary")
        check(Policy.summary(states: [.finished, .finished]) == .init(total: 2, failed: 0, running: 0),
              "finished (including mapped cancelled) is not failed or running")
        check(Policy.summary(states: [.failed, .running, .finished, .running])
              == .init(total: 4, failed: 1, running: 2), "mixed summary")
        var transitioning: [Policy.CallState] = [.running, .running]
        check(Policy.summary(states: transitioning).running == 2, "initial active summary")
        transitioning[0] = .failed
        check(Policy.summary(states: transitioning) == .init(total: 2, failed: 1, running: 1), "failure transition")
        transitioning[1] = .finished
        check(Policy.summary(states: transitioning) == .init(total: 2, failed: 1, running: 0), "finish transition")

        let choices: [Policy.CallState] = [.failed, .running, .finished]
        var combinations = 1
        var sequenceCount = 0
        for length in 0...7 {
            for encoded in 0..<combinations {
                var value = encoded
                let states: [Policy.CallState] = (0..<length).map { _ in
                    let state = choices[value % 3]
                    value /= 3
                    return state
                }
                let snapshot = states
                let summary = Policy.summary(states: states)
                check(summary.total == length, "summary total")
                check(summary.failed == states.filter { $0 == .failed }.count, "summary failed")
                check(summary.running == states.filter { $0 == .running }.count, "summary running")
                check(summary.failed + summary.running <= summary.total, "summary disjoint counts")
                check(Policy.summary(states: Array(states.reversed())) == summary, "summary order independence")
                check(states == snapshot, "summary input unchanged")
                for state in choices {
                    let next = Policy.summary(states: states + [state])
                    check(next.total == summary.total + 1, "summary appended total")
                    check(next.failed == summary.failed + (state == .failed ? 1 : 0), "summary appended failed")
                    check(next.running == summary.running + (state == .running ? 1 : 0), "summary appended running")
                }
                sequenceCount += 1
            }
            combinations *= 3
        }
        check(sequenceCount == 3280, "all state sequences through length seven visited")
    }

    private mutating func durationTests() {
        typealias Timing = Policy.Timing
        func timing(_ state: Policy.CallState = .running, start: Double? = 100,
                    duration: Double? = nil, end: Double? = nil) -> Timing {
            Timing(state: state, startedAt: start, duration: duration, finishedAt: end)
        }
        func seconds(_ sample: Timing, _ now: Double = 110) -> Double? {
            Policy.durationSeconds(timing: sample, now: now)
        }

        check(seconds(timing()) == 10, "active elapsed from source start")
        check(seconds(timing(), 111) == 11, "active refresh")
        check(seconds(timing(duration: 2)) == 10, "active start overrides stale duration")
        check(seconds(timing(start: nil)) == nil, "active missing start is unknown")
        check(seconds(timing(start: nil, duration: 2)) == 2, "duration fallback when start missing")
        check(seconds(timing(start: 120)) == 0, "future start clamps to zero")
        check(seconds(timing(.finished, duration: 3.25)) == 3.25, "historical recorded duration")
        check(seconds(timing(.failed, duration: 0)) == 0, "zero duration is known")
        check(seconds(timing(.finished, duration: 3, end: 108)) == 3, "recorded duration wins over end")
        check(seconds(timing(.finished, start: nil, duration: 7)) == 7, "restored duration needs no start")
        check(seconds(timing(.finished, end: 108)) == 8, "observed terminal time")
        check(seconds(timing(.failed, end: 108), 500) == 8, "failed fallback frozen")
        check(seconds(timing(.finished, end: 108), 10_000) == 8, "completed or cancelled fallback frozen")
        check(seconds(timing(.finished), 10_000) == nil, "historical missing end never runs to now")
        check(seconds(timing(.failed, start: nil, end: 108)) == nil, "end without start is unknown")
        check(seconds(timing(.finished, end: 90)) == 0, "backwards finish clamps to zero")
        check(seconds(timing(.finished, duration: -2, end: 108)) == 8, "negative duration ignored")
        check(seconds(timing(.finished, duration: .nan, end: 108)) == 8, "NaN duration ignored")
        check(seconds(timing(.finished, duration: .infinity)) == nil, "infinite duration unknown")
        check(seconds(timing(start: .nan)) == nil, "invalid start unknown")
        check(seconds(timing(), .infinity) == nil, "invalid current date unknown")
        check(seconds(timing(.finished, end: .infinity)) == nil, "invalid finish unknown")
        check(seconds(timing(.finished, start: -.greatestFiniteMagnitude,
                             end: .greatestFiniteMagnitude)) == nil, "timestamp overflow rejected")

        check(Policy.durationSummary(timings: [], now: 110)
              == .init(seconds: 0, hasUnknownDuration: false), "empty duration summary")
        let parallel = [timing(), timing()]
        let snapshot = parallel
        check(Policy.durationSummary(timings: parallel, now: 110)
              == .init(seconds: 20, hasUnknownDuration: false), "parallel sum exceeds wall clock")
        check(Policy.durationSummary(timings: parallel, now: 111).seconds == 22,
              "each running tool contributes to refresh")
        check(parallel == snapshot, "duration input unchanged")
        let mixed = [timing(.finished, end: 104), timing()]
        check(Policy.durationSummary(timings: mixed, now: 110).seconds == 14,
              "finished tool freezes while sibling continues")
        let completed = [timing(.finished, end: 104), timing(.failed, end: 110)]
        for now in [110.0, 120, 10_000] {
            check(Policy.durationSummary(timings: completed, now: now)
                  == .init(seconds: 14, hasUnknownDuration: false), "all terminal durations stay fixed")
        }
        let historical = [timing(.finished, start: nil, duration: 4),
                          timing(.failed, start: nil, duration: 6)]
        check(Policy.durationSummary(timings: historical, now: 10_000).seconds == 10,
              "restored per-tool durations reused")
        check(Policy.durationSummary(timings: historical + [timing(.finished)], now: 10_000)
              == .init(seconds: 10, hasUnknownDuration: true), "partial history reports a lower bound")
        check(Policy.durationSummary(timings: [timing(.finished)], now: 10_000)
              == .init(seconds: 0, hasUnknownDuration: true), "all unknown is not an exact zero")
        check(Policy.durationSummary(timings: [timing(.finished, duration: 0)], now: 10_000)
              == .init(seconds: 0, hasUnknownDuration: false), "recorded zero remains exact")
        check(Policy.durationSummary(timings: completed + [timing(start: 120)], now: 123).seconds == 17,
              "appending a tool preserves finished contributions and excludes idle gap")
        let overflow = [timing(.finished, duration: .greatestFiniteMagnitude),
                        timing(.finished, duration: .greatestFiniteMagnitude)]
        check(Policy.durationSummary(timings: overflow, now: 0)
              == .init(seconds: .greatestFiniteMagnitude, hasUnknownDuration: true),
              "overflow never formats infinite seconds")
        var late = timing(.finished, end: 108)
        check(seconds(late) == 8, "initial observed end fallback")
        late.duration = 7.5
        check(seconds(late, 10_000) == 7.5, "late canonical duration replaces fallback and stays fixed")
    }
}
