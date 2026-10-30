//
//  AdaptivePaneLayout.swift
//  ZeApp
//
//  Pane selection for the conversation UI.
//

import CoreGraphics

/// Which shape the conversation UI takes at a given window size.
enum ConversationPaneLayout: Equatable {
    /// One column: the session list pushes the chat.
    case stack
    /// Two columns: the session list sits beside the chat.
    case split
}

/// [T-foldable-panes] Chooses the pane layout from the size the window actually
/// received, not from `userInterfaceIdiom`.
///
/// A foldable iPhone reports `.phone` at every width: unfolded on the inner
/// display it hands the app ~800–1000pt, folded on the outer display ~380–430pt.
/// Gating the two-column layout on the idiom — the previous
/// `isIPad && width >= 700` — therefore locked the inner display into the phone
/// stack forever. The app ran, but it never adapted: no sidebar beside the
/// chat, and the same single column stretched across 900pt.
///
/// The rules, in order:
///
/// 1. Height must reach `splitMinHeight`. iPhone landscape is wide (852pt) but
///    only ~390pt tall; splitting that leaves neither column usable, so it
///    stays stacked no matter how wide the window is.
/// 2. Width must reach `splitMinWidth` to enter the split, and
///    `splitMinWidth - hysteresis` to stay in it. Without the lower exit
///    threshold, a window dragged across 700pt re-evaluates on both sides of
///    the boundary and flaps between the two layouts every frame.
///
/// Pure and free of UIKit so the rules can be tested on macOS in CI.
enum AdaptivePanePolicy {
    /// Width at which an un-split window becomes a split.
    static let splitMinWidth: CGFloat = 700
    /// Height below which a split is never used (phone landscape).
    static let splitMinHeight: CGFloat = 500
    /// Slack that keeps an existing split from collapsing on a 1pt wobble.
    static let hysteresis: CGFloat = 24

    /// - Parameter previous: The layout currently on screen, used for
    ///   hysteresis. Pass `nil` on the first evaluation.
    static func layout(for size: CGSize,
                       previous: ConversationPaneLayout? = nil) -> ConversationPaneLayout {
        // A window that has not been measured yet reports zero. Stay stacked
        // rather than flash a split with no width to draw it in.
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return .stack }
        // A short window is a phone in landscape however wide it is.
        guard size.height >= splitMinHeight else { return .stack }
        let threshold = previous == .split ? splitMinWidth - hysteresis : splitMinWidth
        return size.width >= threshold ? .split : .stack
    }
}
