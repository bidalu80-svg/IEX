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
/// iPhone Duo (iOS 27) is the concrete case. It reports `.phone` at every
/// configuration, so the previous `isIPad && width >= 700` gate locked it into
/// the phone stack forever — unfolded, the app painted one column across the
/// whole 7.6" inner display. Its measured sizes (3× scale, from Apple's tech
/// specs: inner 1878×2670 @430ppi, outer 1398×2034 @460ppi):
///
/// | configuration            | points      | panes |
/// |--------------------------|-------------|-------|
/// | outer display (closed)   | 466 × 678   | stack |
/// | inner display, portrait  | 626 × 890   | stack |
/// | inner display, landscape | 890 × 626   | split |
/// | Split View half window   | ~313 × 626  | stack |
///
/// The rules, in order:
///
/// 1. Height must reach `splitMinHeight`. A phone in landscape is wide (852pt on
///    a 6.3" iPhone) but only ~390pt tall; splitting that leaves neither column
///    usable, so it stays stacked no matter how wide the window is.
/// 2. Width must reach `splitMinWidth` to enter the split, and
///    `splitMinWidth - hysteresis` to stay in it. Without the lower exit
///    threshold, a window dragged across the boundary re-evaluates on both sides
///    and flaps between the two layouts every frame.
///
/// 700pt also happens to be the practical compact/regular width boundary, which
/// is why Duo's 626pt portrait stays single-column — two panes there would be
/// ~310pt each, narrower than any iOS sidebar.
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
