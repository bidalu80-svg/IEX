import Foundation

// MARK: - Browser Action Enum

enum BrowserAction: String, CaseIterable {
    case navigate
    case screenshot
    case click
    case type
    case getText = "get_text"
    case scroll
    case getPageInfo = "get_page_info"
    case executeJS = "execute_js"
    case findElements = "find_elements"
    case hover
    case getReadable = "get_readable"
    case setUserAgent = "set_user_agent"
    case setViewport = "set_viewport"
    case getBackbone = "get_backbone"
    case fetch
    case newTab = "new_tab"
    case closeTab = "close_tab"
    case listTabs = "list_tabs"
    case getCookies = "get_cookies"
    case setCookies = "set_cookies"
    case scrollAndCollect = "scroll_and_collect"
    case waitForDomStable = "wait_for_dom_stable"
    /// Waiting action exposed as the dedicated `browser_request_takeover`
    /// tool. It is routed by BrowserTabPool before any tab is acquired.
    case requestTakeover = "request_takeover"
}

// MARK: - Browser Action Input

struct BrowserActionInput {
    let action: BrowserAction
    let url: String?
    let selector: String?
    let text: String?
    let coordinateX: Int?
    let coordinateY: Int?
    let direction: ScrollDirection?
    let amount: Int?
    let script: String?
    let userAgent: UserAgentProfile?
    let maxDepth: Int?
    let tabId: Int?
    var scrollCount: Int? = nil
    var itemSelector: String? = nil
    var keywords: [String]? = nil
    var fuzzy: Bool? = nil
    var timeout: Int? = nil
    /// Custom viewport width in CSS pixels for `set_viewport`.
    var viewportWidth: Int? = nil
    /// Custom viewport height in CSS pixels for `set_viewport`.
    var viewportHeight: Int? = nil
    /// When true with `set_viewport`, clear the session-level viewport
    /// override and fall back to the global setting.
    var viewportReset: Bool? = nil
    /// When true with `screenshot`, capture the entire scrollable page by
    /// temporarily resizing the WebView to `document.documentElement.scrollHeight`.
    /// Default false captures only the current viewport.
    var fullPage: Bool? = nil
    /// Cookies to write (set_cookies). Each entry is a loosely-typed dict with
    /// keys: name, value (required), and optional domain, path, secure,
    /// http_only, expires (Unix seconds).
    var cookies: [[String: Any]]? = nil
    /// The `user_agent` argument exactly as the caller sent it, kept so a
    /// `set_user_agent` with a value `userAgent` could not be parsed from can
    /// name that value in its error instead of silently picking a profile.
    var userAgentRaw: String? = nil
    /// One-line instruction shown to the user when the agent requests browser
    /// takeover (`request_takeover`). Required for that action only.
    var reason: String? = nil

    enum ScrollDirection: String {
        case up, down
    }

    static func parse(from json: String) -> BrowserActionInput? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionStr = dict["action"] as? String,
              let action = BrowserAction(rawValue: actionStr) else {
            return nil
        }

        return BrowserActionInput(
            action: action,
            url: dict["url"] as? String,
            selector: dict["selector"] as? String,
            text: dict["text"] as? String,
            coordinateX: dict["coordinate_x"] as? Int,
            coordinateY: dict["coordinate_y"] as? Int,
            direction: (dict["direction"] as? String).flatMap(ScrollDirection.init),
            amount: dict["amount"] as? Int,
            script: dict["script"] as? String,
            userAgent: UserAgentProfile.parse(dict["user_agent"] as? String),
            maxDepth: dict["max_depth"] as? Int,
            tabId: dict["tab_id"] as? Int,
            scrollCount: dict["scroll_count"] as? Int,
            itemSelector: dict["item_selector"] as? String,
            keywords: {
                if let arr = dict["keywords"] as? [String] {
                    let tokens = arr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    return tokens.isEmpty ? nil : tokens
                } else if let str = dict["keywords"] as? String {
                    let tokens = str.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                    return tokens.isEmpty ? nil : tokens
                }
                return nil
            }(),
            fuzzy: dict["fuzzy"] as? Bool,
            timeout: dict["timeout"] as? Int,
            viewportWidth: dict["viewport_width"] as? Int,
            viewportHeight: dict["viewport_height"] as? Int,
            viewportReset: dict["reset"] as? Bool,
            fullPage: dict["full_page"] as? Bool,
            cookies: Self.parseCookies(dict["cookies"]),
            userAgentRaw: dict["user_agent"] as? String,
            reason: dict["reason"] as? String
        )
    }

    /// `cookies` may arrive either as a real JSON array (`[[String: Any]]`) or —
    /// because the tool schema can only type it as a string — as a JSON-encoded
    /// STRING like `"[{\"name\":...}]"`. Accept both so a schema-faithful model
    /// (which emits the string form) isn't silently dropped to empty.
    private static func parseCookies(_ raw: Any?) -> [[String: Any]]? {
        if let arr = raw as? [[String: Any]] { return arr }
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            return arr
        }
        return nil
    }
}

// MARK: - User Agent Profile

enum UserAgentProfile: String {
    case mobileSafari = "mobile_safari"
    case desktopSafari = "desktop_safari"
    case custom = "custom"

    /// Returns a UA string, or `nil` for `.custom` (caller uses the custom string stored externally).
    var userAgentString: String? {
        switch self {
        case .custom:
            return nil
        case .desktopSafari:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        case .mobileSafari:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
    }

    var displayName: String {
        switch self {
        case .desktopSafari: return String(localized: "Desktop Safari")
        case .mobileSafari: return String(localized: "Mobile Safari")
        case .custom: return String(localized: "Custom")
        }
    }

    var icon: String {
        switch self {
        case .desktopSafari: return "desktopcomputer"
        case .mobileSafari: return "iphone"
        case .custom: return "pencil.line"
        }
    }

    /// Logical viewport size for the profile. Only takes effect for headless
    /// agent usage — once the WKWebView is embedded in SwiftUI its bounds are
    /// driven by the container. Desktop rendering in the visible browser is
    /// forced separately via a viewport-meta override script.
    var viewportSize: (width: Int, height: Int) {
        switch self {
        case .desktopSafari: return (1280, 800)
        case .mobileSafari, .custom: return (390, 844)
        }
    }
}

// MARK: - User Agent Profile: arguments and the panel icon

extension UserAgentProfile {
    /// Parse a `user_agent` argument. Accepts the raw values plus the short
    /// aliases models reach for (`desktop`, `mobile`), ignoring case, outer
    /// whitespace and `-` vs `_`. Returns nil for a missing or unknown value:
    /// the caller reports an error, it does not fall back to a profile.
    /// (An unknown value used to become mobile Safari without a word, so
    /// `user_agent: "desktop"` switched the browser to MOBILE.)
    static func parse(_ raw: String?) -> UserAgentProfile? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch key {
        case "desktop": return .desktopSafari
        case "mobile": return .mobileSafari
        default: return UserAgentProfile(rawValue: key)
        }
    }

    /// Error text for a `set_user_agent` whose `user_agent` is missing or not
    /// one of the accepted values.
    static func invalidArgumentMessage(raw: String?) -> String {
        let got = raw.map { "\"\($0)\" is not a user agent profile" } ?? "user_agent is missing"
        return "set_user_agent: \(got). Use desktop_safari or mobile_safari (aliases: desktop, mobile). Nothing was changed."
    }

    /// Which profile the browser panel's title icon stands for: the selected
    /// tab's own profile, because that is what the page on screen was loaded
    /// with; the global default only when no tab is open yet.
    static func panelProfile(activeTab: UserAgentProfile?, globalDefault: UserAgentProfile) -> UserAgentProfile {
        activeTab ?? globalDefault
    }
}

// MARK: - Browser Control

/// Pool-level single source of truth for who is driving the browser.
/// `agent` covers an in-flight agent action (and its short post-action grace);
/// `user` means the user holds control — either they pressed 接管 themselves
/// or the agent asked for help via `browser_request_takeover`; `idle` means
/// nobody is driving.
enum BrowserControlState: String, Sendable, Equatable {
    case agent
    case user
    case idle
}

/// A pending, agent-initiated handover. `controlState` is still the single
/// authority for who owns the browser; this only carries the one-line reason
/// plus an identity used to finish exactly one waiter.
struct BrowserTakeoverRequestInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let reason: String
}

/// A control transition delivered to the session layer. `url`/`title` describe
/// the page the user is on at the moment of the transition. `requested` marks
/// an agent-initiated handover so its event copy is distinguishable from a
/// user-initiated 接管; `reason` is that request's one-line instruction.
struct BrowserControlEvent: Sendable {
    enum Kind: String, Sendable, Equatable {
        case takeover
        case requestedTakeover
        case handBack
    }
    let kind: Kind
    let state: BrowserControlState
    let url: String
    let title: String
    var requested: Bool = false
    var reason: String? = nil
}

// MARK: - Browser Action Result

struct BrowserActionResult {
    var text: String
    let success: Bool
    /// Base64-encoded image data for the API (vision).
    let base64Image: String?
    /// Local file path where the screenshot/image was saved to disk.
    let imageFilePath: String?
    /// Raw downloaded file data (for fetch action).
    let fetchedFileData: Data?
    /// Determined filename for the fetched file (for fetch action).
    let fetchedFileName: String?
    /// The page URL at the time this action was executed.
    var pageURL: String?
    /// The tab id this action actually ran on. Stamped by `BrowserTabPool.execute`
    /// at the point of dispatch using the verified `targetId`, NOT the global
    /// `selectedTabId` — which is overwritten when the fan-out branch spawns
    /// a fresh tab for a concurrent navigate. Without this, the agent had to
    /// guess tab_id for its follow-up reads/scrolls and routinely picked the
    /// wrong one, sometimes surfacing as empty get_text results.
    /// [T-ios-browser-result-tab-id]
    var tabId: Int?
    /// Who was in control when this result was produced. Every browser tool
    /// result carries it so a model that missed the takeover event still sees
    /// `control: user` before trying another write.
    var control: BrowserControlState = .idle
    /// Structured machine-readable error code (currently `user_takeover`).
    var errorCode: String?

    init(text: String, success: Bool = true, base64Image: String? = nil, imageFilePath: String? = nil,
         fetchedFileData: Data? = nil, fetchedFileName: String? = nil, pageURL: String? = nil,
         tabId: Int? = nil, control: BrowserControlState = .idle, errorCode: String? = nil) {
        self.text = text
        self.success = success
        self.base64Image = base64Image
        self.imageFilePath = imageFilePath
        self.fetchedFileData = fetchedFileData
        self.fetchedFileName = fetchedFileName
        self.pageURL = pageURL
        self.tabId = tabId
        self.control = control
        self.errorCode = errorCode
    }

    static func error(_ message: String) -> BrowserActionResult {
        BrowserActionResult(text: "Error: \(message)", success: false)
    }

    /// Structured refusal for every agent write attempted while the user holds
    /// control. Includes the page the user is on so the model does not have to
    /// ask where they ended up.
    static func userTakeover(pageURL: String?, pageTitle: String?) -> BrowserActionResult {
        var text = "Error: user_takeover — the user has taken over the browser. "
            + "Do not operate the browser until the user hands control back."
        let url = pageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !url.isEmpty || !title.isEmpty {
            text += "\nCurrent page: \(title.isEmpty ? "(untitled)" : title) \(url)"
        }
        return BrowserActionResult(text: text, success: false,
                                   pageURL: url.isEmpty ? nil : url,
                                   control: .user, errorCode: "user_takeover")
    }

    /// Structured normal outcome for `browser_request_takeover` when the user
    /// closes the sheet instead of completing the task. Deliberately a result,
    /// not a thrown error: the model decides whether to try another route.
    static func userCancelled(pageURL: String?, pageTitle: String?,
                              sessionStopped: Bool = false) -> BrowserActionResult {
        let url = pageURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var text = sessionStopped
            ? "user_cancelled: the session was stopped while waiting for the user to finish the browser task."
            : "user_cancelled: the user cancelled the browser takeover request without completing it."
        if !url.isEmpty || !title.isEmpty {
            text += "\nCurrent page: \(title.isEmpty ? "(untitled)" : title) \(url)"
        }
        return BrowserActionResult(text: text, success: true,
                                   pageURL: url.isEmpty ? nil : url,
                                   control: .idle, errorCode: "user_cancelled")
    }
}
