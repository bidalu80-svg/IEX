// Standalone tests for AdaptivePanePolicy, run with macOS Foundation before
// the full iOS build:
//
//   xcrun swiftc -target "$(uname -m)-apple-macosx13.0" \
//       Views/Layout/AdaptivePaneLayout.swift scripts/FoldableLayoutTests.swift -o /tmp/t
//
// Follows the repo's test convention (@main + static main), because swiftc only
// accepts top-level code in a file literally named main.swift.

import CoreGraphics
import Foundation

@main
struct FoldableLayoutTests {
    static var count = 0
    static var failures: [String] = []

    static func check(_ condition: Bool, _ name: String) {
        count += 1
        if condition {
            print("PASS: \(name)")
        } else {
            print("FAIL: \(name)")
            failures.append(name)
        }
    }

    static func layout(_ w: CGFloat, _ h: CGFloat,
                       _ previous: ConversationPaneLayout? = nil) -> ConversationPaneLayout {
        AdaptivePanePolicy.layout(for: CGSize(width: w, height: h), previous: previous)
    }

    static func main() {
        // --- The two states of a foldable phone -----------------------

        check(layout(402, 874) == .stack,
              "outer display (402x874) stays single column")
        check(layout(920, 1000) == .split,
              "inner display (920x1000) splits into two columns")
        check(layout(1100, 1000) == .split,
              "a wide inner display splits too")

        // --- Wide but short windows must not split --------------------

        check(layout(852, 393) == .stack,
              "iPhone landscape (852x393) stays stacked")
        check(layout(1000, 480) == .stack,
              "a window below the height floor never splits")

        // --- Unmeasured windows ---------------------------------------

        check(layout(0, 0) == .stack,
              "an unmeasured window (0x0) stays stacked")
        check(layout(.nan, 800) == .stack,
              "a NaN width stays stacked")
        check(layout(900, .infinity) == .stack,
              "a non-finite height stays stacked")
        check(layout(-10, 800) == .stack,
              "a negative width stays stacked")

        // --- Threshold behaviour --------------------------------------

        check(layout(AdaptivePanePolicy.splitMinWidth, 800) == .split,
              "exactly at the threshold splits")
        check(layout(AdaptivePanePolicy.splitMinWidth - 1, 800) == .stack,
              "1pt below the threshold stays stacked")

        // --- Hysteresis: an existing split must not flap --------------

        check(layout(AdaptivePanePolicy.splitMinWidth - 4, 800, .split) == .split,
              "an existing split survives a 4pt wobble below the threshold")
        check(layout(AdaptivePanePolicy.splitMinWidth - AdaptivePanePolicy.hysteresis, 800, .split) == .split,
              "an existing split survives down to the hysteresis floor")
        check(layout(AdaptivePanePolicy.splitMinWidth - AdaptivePanePolicy.hysteresis - 1, 800, .split) == .stack,
              "below the hysteresis floor it collapses")
        check(layout(AdaptivePanePolicy.splitMinWidth - 4, 800, .stack) == .stack,
              "a stacked layout does not open on a wobble")

        // --- Documented invariants ------------------------------------

        check(AdaptivePanePolicy.splitMinWidth == 700,
              "split entry width is 700pt")
        check(AdaptivePanePolicy.splitMinHeight == 500,
              "split minimum height is 500pt")
        check(AdaptivePanePolicy.splitMinWidth > AdaptivePanePolicy.hysteresis,
              "hysteresis cannot invert the exit threshold")

        print("")
        if failures.isEmpty {
            print("ALL PASS (\(count) checks)")
        } else {
            fatalError("\(failures.count) of \(count) checks failed: \(failures.joined(separator: "; "))")
        }
    }
}
