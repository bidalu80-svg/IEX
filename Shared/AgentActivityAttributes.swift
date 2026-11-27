import ActivityKit
import Foundation

struct LiveSessionSnapshot: Codable, Hashable {
    var sessionId: String
    var title: String
    /// SF Symbol name for the current tool (e.g. "globe", "terminal", "doc.text").
    var toolIcon: String
    /// Human-readable tool status (e.g. "navigate...", "running...", "get_text...").
    var toolStatus: String
    var loopIteration: Int
    /// True once this session's task has finished. Drives the "completed" look
    /// (checkmark + last message) in the Live Activity. Defaulted so all
    /// existing snapshot construction sites compile unchanged.
    var isCompleted: Bool = false
    /// One-line summary of the final assistant reply, shown when `isCompleted`.
    var lastMessage: String = ""
    /// [T-floating-window] The latest line of the conversation this session
    /// belongs to, collapsed to a single line. The floating card shows this so
    /// the user can read the conversation from the Lock Screen / Dynamic Island.
    /// Empty when no cached view model had a message for the session. Defaulted
    /// so snapshots encoded before this field existed still decode.
    var conversationLine: String = ""
}

@available(iOS 16.2, *)
struct AgentActivityAttributes: ActivityAttributes {
    var startDate: Date

    public struct ContentState: Codable, Hashable {
        var activeSessionCount: Int
        var sessions: [LiveSessionSnapshot]
        /// Index into `sessions` for the currently displayed session (rotates each update).
        var carouselIndex: Int
        var soulName: String
        /// SF Symbol for the most-recently-invoked tool across all sessions.
        /// The Dynamic Island minimal icon alternates between this tool icon
        /// and the session-count icon on each refresh. Empty when no tool is
        /// active yet. Defaulted so existing ContentState construction sites
        /// (end / cleanup states with no sessions) compile unchanged.
        var latestToolIcon: String = ""
        /// Drives the minimal-icon alternation: when true the minimal Dynamic
        /// Island shows `latestToolIcon`, otherwise the session-count badge.
        /// Flipped by the manager on every refresh so it alternates even with a
        /// single session (where `carouselIndex` would stay 0).
        var minimalShowsTool: Bool = false
        /// True when ALL tasks have finished and the Live Activity is in its
        /// "completed" resting state: it stops the carousel, shows a checkmark +
        /// each session's last message, and lingers (instead of ending instantly)
        /// until the user taps it and Ze decides whether to dismiss it.
        /// [T-ios-live-activity-soft-finish]
        var allCompleted: Bool = false
        /// Pure task flags; carry no approval details or error messages.
        var waitingForApproval: Bool = false
        var hasError: Bool = false
        /// [T-ios-live-activity-audio-toggle] True while the global TTS/audio
        /// player (`GlobalAudioPlayer`) is actively playing a reply-narration or
        /// attachment audio. Drives the play/pause control shown beside the Agent
        /// identity capsule in the Dynamic Island expanded view. Defaulted so old
        /// encoded ContentStates (written before this field existed) still decode.
        var isAudioPlaying: Bool = false
        /// [T-ios-live-activity-audio-toggle] True whenever the audio player has a
        /// file loaded (playing OR paused). Distinguishes "audio present, show the
        /// control" from "no audio at all, hide it". When true but `isAudioPlaying`
        /// is false, the control shows a play (resume) glyph. Defaulted for
        /// backward-compatible decoding.
        var isAudioLoaded: Bool = false
        /// [T-ios-live-activity-audio-toggle] Short title of the current audio
        /// (the player's `fileName`), for optional display. Defaulted for decoding.
        var audioTitle: String = ""
        /// [T-ios-live-activity-privacy-duration] Wall-clock moment the LAST
        /// task finished, set only on the soft-finish (allCompleted) push. The
        /// widget renders `finishedAt − attributes.startDate` as a static
        /// "total run time" capsule in the completed resting state — the live
        /// `.timer` stops there, and Privacy Mode's redacted rows otherwise
        /// carry no informative content at all. Optional + defaulted so
        /// ContentStates encoded before this field existed still decode.
        var finishedAt: Date? = nil
        /// [T-ios-live-activity-privacy-mode] True when the user has turned on
        /// Privacy Mode. The manager already redacts the sensitive fields
        /// (session title / tool status / tool icon / last message / soul name)
        /// before pushing, so the widget mostly renders correctly without
        /// checking this. It is carried anyway so the view can suppress the few
        /// things data-redaction alone can't (e.g. forcing the neutral minimal
        /// icon). Defaulted so ContentStates encoded before this field existed
        /// still decode.
        var privacyMode: Bool = false
        /// [T-floating-window] True when Appearance → 后台终端悬浮窗口 is on, so this
        /// push renders the conversation card (title + latest line + elapsed)
        /// instead of the technical task card. Carried in the state rather than
        /// the attributes because the switch can be flipped while a task runs.
        /// Defaulted so ContentStates encoded before this field existed still
        /// decode (and so the end/cleanup states stay unchanged).
        var floatingWindow: Bool = false
    }
}

// An initializer in an extension preserves the memberwise initializer used by
// the app. Stored-property defaults alone do not make Codable accept missing keys.
@available(iOS 16.2, *)
extension AgentActivityAttributes.ContentState {
    private enum CodingKeys: String, CodingKey {
        case activeSessionCount, sessions, carouselIndex, soulName
        case latestToolIcon, minimalShowsTool, allCompleted, waitingForApproval, hasError
        case isAudioPlaying, isAudioLoaded, audioTitle, finishedAt, privacyMode, floatingWindow
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activeSessionCount = try values.decode(Int.self, forKey: .activeSessionCount)
        sessions = try values.decode([LiveSessionSnapshot].self, forKey: .sessions)
        carouselIndex = try values.decode(Int.self, forKey: .carouselIndex)
        soulName = try values.decode(String.self, forKey: .soulName)
        latestToolIcon = try values.decodeIfPresent(String.self, forKey: .latestToolIcon) ?? ""
        minimalShowsTool = try values.decodeIfPresent(Bool.self, forKey: .minimalShowsTool) ?? false
        allCompleted = try values.decodeIfPresent(Bool.self, forKey: .allCompleted) ?? false
        waitingForApproval = try values.decodeIfPresent(Bool.self, forKey: .waitingForApproval) ?? false
        hasError = try values.decodeIfPresent(Bool.self, forKey: .hasError) ?? false
        isAudioPlaying = try values.decodeIfPresent(Bool.self, forKey: .isAudioPlaying) ?? false
        isAudioLoaded = try values.decodeIfPresent(Bool.self, forKey: .isAudioLoaded) ?? false
        audioTitle = try values.decodeIfPresent(String.self, forKey: .audioTitle) ?? ""
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        privacyMode = try values.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? false
        floatingWindow = try values.decodeIfPresent(Bool.self, forKey: .floatingWindow) ?? false
    }
}
