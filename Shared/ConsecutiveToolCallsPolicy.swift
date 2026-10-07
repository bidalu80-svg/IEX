/// Pure, index-only grouping for ONE message at a time.
///
/// Pass every source block in order: only tools are `true`; text (even empty),
/// thinking, info and final summaries are `false`. Never prefilter the input or
/// concatenate messages. A Bool array carries no message-boundary information.
/// Returned ranges refer to the unchanged source array. A range of length > 1
/// is a collapsible tool group; a singleton remains an ordinary source block.
enum ConsecutiveToolCallsPolicy {
    static let preferenceKey = "chat.collapseConsecutiveToolCalls"
    static let defaultEnabled = true

    static func ranges(isTool: [Bool], enabled: Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        while start < isTool.count {
            var end = start + 1
            if enabled && isTool[start] {
                while end < isTool.count && isTool[end] {
                    end += 1
                }
            }
            result.append(start..<end)
            start = end
        }
        return result
    }

    /// Platform-neutral, mutually exclusive states for aggregate UI counts.
    /// Production ToolBlockStatus mapping lives in ConsecutiveToolCallsHeader.swift.
    enum CallState: Equatable {
        case failed
        case running
        case finished
    }

    struct Summary: Equatable {
        let total: Int
        let failed: Int
        let running: Int
    }

    static func summary(states: [CallState]) -> Summary {
        var failed = 0
        var running = 0
        for state in states {
            switch state {
            case .failed: failed += 1
            case .running: running += 1
            case .finished: break
            }
        }
        return Summary(total: states.count, failed: failed, running: running)
    }

    /// Numeric timestamps use a single caller-chosen clock origin. No Foundation
    /// dependency is needed; the UI uses Date.timeIntervalSinceReferenceDate.
    struct Timing: Equatable {
        var state: CallState
        var startedAt: Double?
        var duration: Double?
        var finishedAt: Double?
    }

    struct DurationSummary: Equatable {
        let seconds: Double
        /// Missing timing data is not silently presented as an exact zero.
        let hasUnknownDuration: Bool
    }

    /// Running calls use their start time so a stale stored duration cannot
    /// stop the clock. Terminal calls prefer recorded duration, then an OBSERVED
    /// terminal transition, never `now` for a historical completed call.
    static func durationSeconds(timing: Timing, now: Double) -> Double? {
        if timing.state == .running, let start = timing.startedAt,
           start.isFinite, now.isFinite, (now - start).isFinite {
            return max(0, now - start)
        }
        if let duration = timing.duration, duration.isFinite, duration >= 0 {
            return duration
        }
        guard timing.state != .running,
              let start = timing.startedAt, start.isFinite,
              let end = timing.finishedAt, end.isFinite else { return nil }
        let elapsed = end - start
        guard elapsed.isFinite else { return nil }
        return max(0, elapsed)
    }

    /// Cumulative per-call seconds, NOT the wall-clock span of the group.
    /// Concurrent calls intentionally contribute separately; gaps between calls
    /// do not contribute. Unknown durations make the known sum a lower bound.
    static func durationSummary(timings: [Timing], now: Double) -> DurationSummary {
        var seconds = 0.0
        var hasUnknownDuration = false
        for timing in timings {
            if let duration = durationSeconds(timing: timing, now: now),
               (seconds + duration).isFinite {
                seconds += duration
            } else {
                hasUnknownDuration = true
            }
        }
        return DurationSummary(seconds: seconds, hasUnknownDuration: hasUnknownDuration)
    }
}
