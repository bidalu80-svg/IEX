//
//  ChatScrollMemory.swift
//  ZeApp
//
//  Per-conversation scroll anchor, so a pane-layout change does not throw the
//  reader back to the bottom of a long transcript.
//

import Foundation
import CoreGraphics

/// [T-foldable-scroll] Where the reader was, per conversation.
///
/// Switching between the stacked and split pane layouts rebuilds the whole chat
/// subtree — `NavigationStack` and `NavigationSplitView` cannot share one
/// child — so the collection view that held the offset is deallocated and a new
/// one starts at the bottom. On a foldable that happens every time the device
/// is opened or closed, which reads as "it scrolled by itself".
///
/// Only the browsing case is remembered: a reader parked at the bottom wants to
/// stay at the bottom (new messages arrive there), so no anchor is stored and
/// the default behaviour is unchanged.
@MainActor
final class ChatScrollMemory {
    static let shared = ChatScrollMemory()

    struct Anchor: Equatable {
        /// First message visible at the top of the viewport.
        let messageId: UUID
        /// Distance from the viewport's top edge to that row's top edge, so a
        /// tall message resumes at the same line instead of at its start.
        let offset: CGFloat
    }

    /// In-memory only: an anchor pointing at a message that no longer exists is
    /// discarded by the restore path, and a cold launch should start at the
    /// bottom like every other chat app.
    private var anchors: [String: Anchor] = [:]

    func save(_ anchor: Anchor, for key: String) {
        anchors[key] = anchor
    }

    func anchor(for key: String) -> Anchor? {
        anchors[key]
    }

    func clear(_ key: String) {
        anchors.removeValue(forKey: key)
    }
}
