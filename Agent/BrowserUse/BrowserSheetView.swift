import Foundation
import SwiftUI

/// Sheet view for observing the browser's live WKWebView(s) via a tab pool.
struct BrowserSheetView: View {
    @ObservedObject var pool: BrowserTabPool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var addressText: String = ""
    @State private var activeSheet: ActiveSheet?
    /// [T-browser-tab-overview-fullscreen] The grid is a full page, not a
    /// nested sheet inside this already-presented browser sheet.
    @State private var showTabOverview = false
    @State private var isFullscreen = false
    @FocusState private var addressFocused: Bool

    /// One sheet slot for every secondary panel. SwiftUI only reliably
    /// presents one `.sheet` per view (and this view is itself inside one), so
    /// History, Share and Tabs all route through this enum. [P2-tab-overview]
    private enum ActiveSheet: Identifiable {
        case history
        case share(BrowserSharePayload)
        case downloads
        case filePreview(URL)
        case fileShare(URL)

        var id: String {
            switch self {
            case .history: return "history"
            case .share(let payload): return "share-\(payload.id.uuidString)"
            case .downloads: return "downloads"
            case .filePreview(let url): return "preview-\(url.path)"
            case .fileShare(let url): return "share-file-\(url.path)"
            }
        }
    }

    private var manager: BrowserUseManager? { pool.activeManager }

    /// The pool's control state is the only gate for every chrome affordance.
    /// There is deliberately no second `isAgentBusy` condition in this view.
    private var isAgentControlled: Bool { pool.controlState == .agent }
    private var isUserControlled: Bool { pool.controlState == .user }
    /// True only while the agent's `browser_request_takeover` call is waiting.
    /// `controlState` is still the authority for ownership; this just selects
    /// the request banner and routes the sheet's 完成 button to hand-back.
    private var isTakeoverRequested: Bool { pool.isTakeoverRequested }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let request = pool.pendingTakeoverRequest, !isFullscreen {
                    takeoverRequestBanner(request)
                }

                if !isFullscreen {
                    // Tab bar
                    tabBar
                        .allowsHitTesting(!isAgentControlled)

                    // URL bar — reference layout: one grey rounded surface,
                    // lock at the leading edge, the domain centred, and the
                    // refresh/stop control at the trailing edge. The centred
                    // text is still a button that enters edit mode; the
                    // TextField only replaces it while focused.
                    addressBar
                        .allowsHitTesting(!isAgentControlled)
                }

                // Live webview + agent overlay
                ZStack {
                    if let manager {
                        BrowserWebView(manager: manager)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(pool.selectedTabId)
                        // [T-ios-webview-error-ui] Safari-style error overlay for
                        // agent/manual navigation failures (blank page otherwise).
                        BrowserLoadErrorOverlay(manager: manager)
                    } else {
                        Color(UIColor.systemBackground)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if pool.controlState == .agent {
                        AgentBrowsingOverlay { pool.userTakeover() }
                            .transition(.opacity)
                    }

                    // Fullscreen exit button
                    if isFullscreen {
                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) { isFullscreen = false }
                                } label: {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.white)
                                        .padding(8)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                                .padding(.trailing, 12)
                                .padding(.top, 8)
                            }
                            Spacer()
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: pool.controlState)

                // Download toast — one Minis-style bar directly above the
                // bottom toolbar. It follows the newest active/unseen entry
                // from BrowserDownloadCenter (the single source of truth).
                if let manager {
                    BrowserDownloadToast(
                        sessionId: manager.sessionIdProvider?() ?? pool.sessionId ?? "",
                        onOpenPanel: { activeSheet = .downloads },
                        onOpenFile: { url in
                            if BrowserPreviewKind.kind(for: url) == .shareOnly {
                                activeSheet = .fileShare(url)
                            } else {
                                activeSheet = .filePreview(url)
                            }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                if !isFullscreen, isUserControlled, !isTakeoverRequested {
                    // 交还 entry: stays in the bottom chrome, deliberately
                    // weaker than the blue 接管 capsule it replaces.
                    HStack {
                        Spacer()
                        Button {
                            pool.handControlBack()
                            addressFocused = false
                        } label: {
                            Label("交还", systemImage: "hand.wave")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(Color(UIColor.tertiarySystemFill))
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Hand browser control back"))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }

                if !isFullscreen {
                    // Separator
                    Divider()

                    // Bottom navigation toolbar
                    HStack(spacing: 0) {
                        Button { pool.touchActivity(); manager?.goBack() } label: {
                            Image(systemName: "chevron.left")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isAgentControlled || !(manager?.canGoBack ?? false))

                        Button { pool.touchActivity(); manager?.goForward() } label: {
                            Image(systemName: "chevron.right")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isAgentControlled || !(manager?.canGoForward ?? false))

                        // Share the current tab: title + URL, handed to the
                        // system share sheet. Disabled only while the agent
                        // holds control.
                        Button {
                            presentShare()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isAgentControlled || (manager?.currentURL.isEmpty ?? true))
                        .accessibilityLabel(Text("Share page"))

                        // Tab count button (reference style): opens the tab
                        // overview grid. Replaces the old read-only text.
                        Button {
                            openTabOverview()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: 1.5)
                                    .frame(width: 25, height: 25)
                                Text("\(pool.tabs.count)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(isAgentControlled)
                        .accessibilityLabel(Text("Tabs, \(pool.tabs.count) open"))

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { isFullscreen = true }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(isAgentControlled)
                    }
                    .font(.system(size: 18))
                    .padding(.vertical, 10)
                    .background(Color(UIColor.secondarySystemBackground))
                    .allowsHitTesting(!isAgentControlled)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 5) {
                        // The selected tab's own profile - what the page on
                        // screen was loaded with - not the global default,
                        // which only says what the NEXT tab will get.
                        Image(systemName: UserAgentProfile.panelProfile(
                            activeTab: pool.activeManager?.currentProfile,
                            globalDefault: pool.userAgentProfile).icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(navigationTitle)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
            }
            .toolbar(isFullscreen ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        Button {
                            _ = pool.newTab()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isAgentControlled || pool.tabs.count >= BrowserTabPool.maxTabs)

                        Button {
                            activeSheet = .history
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .disabled(isAgentControlled)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // In a requested handover the sheet's existing 完成 button
                    // IS the hand-back: same pool completion path as the
                    // banner, no second mechanism.
                    Button(isTakeoverRequested ? "完成" : "Done") {
                        if isTakeoverRequested {
                            pool.completeTakeoverRequest()
                        }
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { addressFocused = false } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .history:
                    BrowserHistoryView(historyStore: BrowserHistoryStore.shared) { url in
                        // Ensure a tab exists, then navigate
                        if pool.tabs.isEmpty {
                            pool.ensureTabForUI()
                        }
                        manager?.loadURL(url)
                    }
                case .share(let payload):
                    BrowserShareSheet(payload: payload)
                case .downloads:
                    BrowserDownloadPanelSheet(sessionId: manager?.sessionIdProvider?() ?? pool.sessionId ?? "")
                case .filePreview(let url):
                    BrowserFilePreviewSheet(url: url)
                case .fileShare(let url):
                    BrowserActivityView(items: [url])
                }
            }
            .fullScreenCover(isPresented: $showTabOverview) {
                BrowserTabOverviewView(pool: pool)
            }
            .onAppear {
                // Ensure at least one tab exists when opened manually
                if pool.tabs.isEmpty {
                    pool.ensureTabForUI()
                }
                addressText = manager?.currentURL ?? ""
            }
            .onDisappear {
                // Closing the sheet while a request is pending is the user's
                // cancel path: resume the waiting tool with user_cancelled
                // instead of leaving a zombie continuation behind.
                if pool.pendingTakeoverRequest != nil {
                    pool.cancelTakeoverRequest()
                }
                // The sheet stretched each tab's offscreen WKWebView to the
                // sheet width (~620pt), reflowing the page's CSS viewport away
                // from the configured size. Restore every tab's frame + force
                // a reflow so subsequent agent screenshots capture the page at
                // its intended viewport (e.g. 390) instead of a 620-wide
                // layout squeezed into a 390 rect.
                // (T-ios-browser-sheet-viewport-pollution)
                for tab in pool.tabs {
                    tab.manager.restoreViewportFrame()
                }
            }
            .onChange(of: manager?.currentURL) { newURL in
                if !addressFocused {
                    addressText = newURL ?? ""
                }
            }
            .onChange(of: pool.pendingTakeoverRequest) { request in
                guard request != nil else { return }
                // A request must be visible even if the user was fullscreen.
                withAnimation(.easeInOut(duration: 0.25)) { isFullscreen = false }
                addressFocused = false
            }
            .onChange(of: pool.selectedTabId) { _ in
                addressText = manager?.currentURL ?? ""
            }
        }
    }

    // MARK: - Requested Takeover Banner

    /// Top-of-sheet prompt for `browser_request_takeover`. It only reports the
    /// agent's reason; both 完成 buttons go through the pool's single
    /// completeTakeoverRequest path, and dismissing the sheet cancels it.
    private func takeoverRequestBanner(_ request: BrowserTakeoverRequestInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("模型请求你接管浏览器")
                    .font(.system(size: 13, weight: .semibold))
                Text(request.reason)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("取消") {
                pool.cancelTakeoverRequest()
                dismiss()
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)

            Button("完成") {
                pool.completeTakeoverRequest()
                dismiss()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.blue))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.blue.opacity(0.08))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }

    // MARK: - Address Bar

    private var addressBar: some View {
        HStack(spacing: 0) {
            ZStack {
                HStack(spacing: 0) {
                    Image(systemName: addressLockSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                        .padding(.leading, 10)

                    Spacer(minLength: 0)

                    Button {
                        toggleAddressEditing()
                    } label: {
                        Image(systemName: (manager?.isLoading ?? false) ? "xmark" : "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .accessibilityLabel(Text((manager?.isLoading ?? false) ? "Stop loading" : "Reload page"))
                }

                if addressFocused {
                    TextField("Search or enter URL", text: $addressText)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .multilineTextAlignment(.center)
                        .focused($addressFocused)
                        .padding(.horizontal, 38)
                        .onSubmit { submitAddress() }
                } else {
                    Button {
                        beginAddressEditing()
                    } label: {
                        Text(addressDisplayText)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(hasAddress ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Edit address"))
                }
            }
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var hasAddress: Bool {
        !(manager?.currentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var addressDisplayText: String {
        guard let raw = manager?.currentURL, !raw.isEmpty else {
            return String(localized: "Search or enter URL")
        }
        if let domain = FaviconService.normalizedDomain(raw), !domain.isEmpty {
            return domain
        }
        return raw
    }

    private var addressLockSymbol: String {
        let raw = manager?.currentURL.lowercased() ?? ""
        if raw.hasPrefix("https://") { return "lock.fill" }
        if raw.isEmpty { return "magnifyingglass" }
        return "lock.open"
    }

    private func beginAddressEditing() {
        pool.touchActivity()
        addressText = manager?.currentURL ?? ""
        addressFocused = true
    }

    private func toggleAddressEditing() {
        if manager?.isLoading ?? false {
            manager?.webView.stopLoading()
        } else {
            pool.touchActivity()
            manager?.reload()
        }
    }

    private func submitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addressFocused = false
        pool.touchActivity()
        manager?.loadURL(trimmed)
    }

    private func chipBackground(isSelected: Bool) -> Color {
        if isSelected {
            // Reference: selected chip is a clean white card in light mode;
            // dark mode uses the nearest "raised" surface instead of blinding
            // pure white.
            return colorScheme == .dark ? Color(UIColor.secondarySystemBackground) : Color.white
        }
        return Color(UIColor.tertiarySystemFill)
    }

    private var navigationTitle: String {
        let title = manager?.pageTitle ?? ""
        return title.isEmpty ? "浏览器" : title
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pool.tabs) { tab in
                    tabButton(for: tab)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(UIColor.tertiarySystemBackground))
    }

    private func tabButton(for tab: BrowserTabPool.Tab) -> some View {
        let isSelected = tab.id == pool.selectedTabId
        return Button {
            selectTab(tab.id)
        } label: {
            HStack(spacing: 5) {
                FaviconView(domain: tabDomain(for: tab),
                            url: tab.manager.currentURL,
                            size: 16)

                Text(tabLabel(for: tab))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 120)

                if !isAgentControlled {
                    Button {
                        _ = pool.closeTab(id: tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chipBackground(isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isSelected ? Color.black.opacity(0.06) : Color.clear, lineWidth: 1)
            )
            .shadow(color: isSelected ? Color.black.opacity(0.08) : .clear, radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func tabLabel(for tab: BrowserTabPool.Tab) -> String {
        // Reference chip copy is the DOMAIN, not the page title. Title remains
        // the fallback for blank / local pages with no resolvable host.
        let domain = tabDomain(for: tab)
        if !domain.isEmpty { return domain }
        let title = tab.manager.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(20)) }
        return "标签页 \(tab.id + 1)"
    }

    private func tabDomain(for tab: BrowserTabPool.Tab) -> String {
        FaviconService.normalizedDomain(tab.manager.currentURL) ?? ""
    }

    /// Switching tabs captures the outgoing tab in `selectedTabId.didSet`, so
    /// this helper only has to keep the activity stamp and selection in sync.
    private func selectTab(_ id: Int) {
        guard id != pool.selectedTabId else { return }
        pool.selectedTabId = id
        pool.touchActivity()
    }

    private func openTabOverview() {
        pool.touchActivity()
        pool.captureTabSnapshot(tabId: pool.selectedTabId)
        showTabOverview = true
    }

    /// Freeze the share content at the moment the button is tapped, so a page
    /// change underneath can never alter what the system sheet is sharing.
    private func presentShare() {
        guard let manager else { return }
        let rawURL = manager.currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty, let url = URL(string: rawURL) else { return }
        let title = manager.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSheet = .share(BrowserSharePayload(title: title, url: url))
    }
}

// MARK: - Address Bar Loading Icon

/// Globe icon with a spinning arc border when loading.
private struct BrowserAddressBarIcon: View {
    let isLoading: Bool
    @State private var spinning = false

    var body: some View {
        ZStack {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundStyle(isLoading ? Color.accentColor : .secondary)

            if isLoading {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
                    .onDisappear { spinning = false }
                    .transition(.identity)
            }
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Agent Browsing Overlay

/// Agent-control overlay: a static blue→purple→pink→orange glow ring plus the
/// central frosted “Ze 正在浏览” card. The glow never takes touches; only the
/// card's blue 接管 capsule is interactive.
private struct AgentBrowsingOverlay: View {
    let onTakeover: () -> Void
    @State private var breathing = false

    var body: some View {
        ZStack {
            // Static gradient + a slow opacity breath only. No timeline,
            // no full-screen per-frame redraw; this layer never takes touches.
            AgentGlowBorder(breathing: breathing)
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [.blue, .purple, .pink],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )
                    Text("Ze 正在浏览")
                        .font(.system(size: 17, weight: .semibold))
                }
                .allowsHitTesting(false)

                Button {
                    onTakeover()
                } label: {
                    Label("接管", systemImage: "hand.raised.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.blue))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Take over browser"))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
                    .allowsHitTesting(false)
            }
            .offset(y: -10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// Blue → purple → pink → orange glow ring around the page. Two static
/// gradient strokes (a wide blurred bloom and a crisp inner edge); animation
/// only changes their opacity at ~3s intervals.
private struct AgentGlowBorder: View {
    let breathing: Bool

    private let colors: [Color] = [.blue, .purple, .pink, .orange, .blue]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    AngularGradient(gradient: Gradient(colors: colors), center: .center),
                    lineWidth: 26
                )
                .blur(radius: 20)
                .opacity(breathing ? 0.82 : 0.55)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    AngularGradient(gradient: Gradient(colors: colors), center: .center),
                    lineWidth: 4
                )
                .opacity(breathing ? 1.0 : 0.72)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Download Progress Banner

/// Slim banner listing this session's downloads inside the browser sheet.
/// [T-browser-download-ux] Now driven by the session-scoped
/// BrowserDownloadCenter (covers all tabs) and reuses the same card rows as
/// the chat's floating overlay, so the sheet shows live percent/bytes too.
struct BrowserDownloadBanner: View {
    @ObservedObject var manager: BrowserUseManager
    @ObservedObject private var center = BrowserDownloadCenter.shared

    var body: some View {
        let items = center.downloads(for: manager.sessionIdProvider?() ?? "")
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(items) { entry in
                    BrowserDownloadCardRow(entry: entry,
                                           onTap: nil,
                                           onDismiss: { center.dismiss(id: entry.id) })
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemBackground))
        }
    }
}

// MARK: - Floating download button (chat overlay)

/// Round 36×36 floating button shown near the scroll-jump buttons while the
/// session has active/unviewed native browser downloads. Shares the scroll
/// buttons' surface (`FloatingCircleButtonSurface`: glass on iOS 26+,
/// system-background circle + stroke + shadow below). Badge = in-flight + unviewed terminal entries;
/// hidden entirely at badge 0. Tapping opens BrowserDownloadPanelSheet.
/// [T-browser-download-ux-v2]
struct BrowserDownloadFloatingButton: View {
    @ObservedObject private var center = BrowserDownloadCenter.shared
    let sessionId: String
    let action: () -> Void

    @State private var legacyPulse = false

    var body: some View {
        let items = center.downloads(for: sessionId)
        // Visible while ANY entries exist (user hasn't cleared them yet) —
        // the button disappears the moment the last record is cleared. The
        // badge itself only renders when there is something "active" to
        // count (in-flight + unviewed terminal entries).
        if !items.isEmpty {
            let badge = center.badgeCount(for: sessionId)
            let downloading = items.contains { $0.state == .downloading }
            Button(action: action) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FloatingCircleButtonSurface.glyphStyle)
                    .modifier(DownloadPulseModifier(active: downloading, legacyPulse: $legacyPulse))
                    .frame(width: 36, height: 36)
                    .modifier(FloatingCircleButtonSurface(
                        legacyLightOpacity: 0.5,
                        legacyStrokeOpacity: 0.25,
                        legacyShadowOpacity: 0.12,
                        legacyShadowRadius: 4
                    ))
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, badge > 9 ? 4 : 0)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.red, in: Capsule())
                                .offset(x: 5, y: -5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

/// Pulse on iOS 17+ via symbolEffect; below that, a gentle repeating opacity
/// breath driven by an explicit animation.
private struct DownloadPulseModifier: ViewModifier {
    let active: Bool
    @Binding var legacyPulse: Bool

    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.symbolEffect(.pulse, options: .repeating, isActive: active)
        } else {
            content
                .opacity(active && legacyPulse ? 0.35 : 1.0)
                .animation(active
                           ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                           : .default,
                           value: legacyPulse)
                .onAppear { if active { legacyPulse = true } }
                .onChange(of: active) { nowActive in
                    legacyPulse = nowActive
                }
        }
    }
}

// MARK: - Download toast (in-sheet)

/// One Minis-style download bar bound to `BrowserDownloadCenter`. Never keeps
/// its own download state: the newest active/unseen entry is the only thing
/// rendered, and progress comes straight from the WKDownload NSProgress.
struct BrowserDownloadToast: View {
    @ObservedObject private var center = BrowserDownloadCenter.shared
    let sessionId: String
    let onOpenPanel: () -> Void
    let onOpenFile: (URL) -> Void

    var body: some View {
        if let entry = center.toastEntry(for: sessionId) {
            BrowserDownloadToastRow(entry: entry,
                                    onOpenPanel: onOpenPanel,
                                    onOpenFile: onOpenFile)
                .id(entry.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct BrowserDownloadToastRow: View {
    let entry: BrowserDownloadCenter.Entry
    let onOpenPanel: () -> Void
    let onOpenFile: (URL) -> Void
    @ObservedObject private var center = BrowserDownloadCenter.shared
    @StateObject private var progress: DownloadProgressObserver

    init(entry: BrowserDownloadCenter.Entry,
         onOpenPanel: @escaping () -> Void,
         onOpenFile: @escaping (URL) -> Void) {
        self.entry = entry
        self.onOpenPanel = onOpenPanel
        self.onOpenFile = onOpenFile
        _progress = StateObject(wrappedValue: DownloadProgressObserver(progress: entry.progress))
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingStatus
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismissToast) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close download notice"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            switch entry.state {
            case .completed:
                if let url = entry.localFileURL { onOpenFile(url) }
            case .failed:
                onOpenPanel()
            case .downloading:
                break
            }
        }
    }

    @ViewBuilder private var leadingStatus: some View {
        switch entry.state {
        case .downloading:
            DownloadProgressRing(fraction: progress.fraction,
                                 indeterminate: progress.total <= 0)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch entry.state {
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)
            if progress.total > 0 {
                let total = ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file)
                Text("\(done) / \(total)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                // Unknown total: show real downloaded bytes only. No fake
                // percentage, no estimated remaining time.
                Text("\(done) · \(String(localized: "Downloading…"))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .completed(let sizeText):
            Text("\(sizeText) · 点按查看")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func dismissToast() {
        switch entry.state {
        case .downloading:
            // Real WKDownload cancel; BrowserUseManager deletes the partial
            // file and the panel row flips to the same terminal state.
            center.cancel(id: entry.id)
        case .completed, .failed:
            // Close the toast only. The file and the panel record stay.
            center.markSeen(id: entry.id)
        }
    }
}

/// Ring driven by real byte progress. `indeterminate` is used when
/// `totalUnitCount <= 0` — it spins without a percentage.
private struct DownloadProgressRing: View {
    let fraction: Double
    let indeterminate: Bool
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 3)

            if indeterminate {
                Circle()
                    .trim(from: 0, to: 0.24)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(max(0, min(1, fraction)) * 100))%")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
            }
        }
        .padding(2)
    }
}

// MARK: - Downloads panel sheet

/// Download manager panel opened from the floating button: all of the
/// session's downloads newest-first — cancel for in-flight rows, jump to the
/// file browser (located at the file) for completed rows, reason + clear for
/// failed rows. [T-browser-download-ux-v2]
struct BrowserDownloadPanelSheet: View {
    @ObservedObject private var center = BrowserDownloadCenter.shared
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    /// Optional "Show in Files" hook (the chat host passes its file browser).
    var onLocate: ((String) -> Void)? = nil

    @State private var activeSheet: PanelSheet?

    private enum PanelSheet: Identifiable {
        case preview(URL)
        case share(URL)

        var id: String {
            switch self {
            case .preview(let url): return "preview-\(url.path)"
            case .share(let url): return "share-\(url.path)"
            }
        }
    }

    private func locateAction(for entry: BrowserDownloadCenter.Entry) -> (() -> Void)? {
        guard let locate = onLocate else { return nil }
        return { locate(entry.filename) }
    }

    var body: some View {
        NavigationStack {
            Group {
                let items = center.downloads(for: sessionId)
                    .sorted { $0.startedAt > $1.startedAt }
                if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("No downloads", comment: "Empty downloads panel")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(items) { entry in
                            BrowserDownloadPanelRow(
                                entry: entry,
                                onCancel: { center.cancel(id: entry.id) },
                                onPreview: {
                                    guard let url = entry.localFileURL else { return }
                                    if BrowserPreviewKind.kind(for: url) == .shareOnly {
                                        activeSheet = .share(url)
                                    } else {
                                        activeSheet = .preview(url)
                                    }
                                },
                                onShare: {
                                    if let url = entry.localFileURL { activeSheet = .share(url) }
                                },
                                onLocate: locateAction(for: entry),
                                onClear: { center.dismiss(id: entry.id) }
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(Text("Downloads", comment: "Downloads panel title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // [T-browser-download-ux-v3] "Clear" wipes every finished
                    // record (completed + failed); in-flight rows stay.
                    let hasFinished = center.downloads(for: sessionId).contains {
                        $0.state != .downloading
                    }
                    if hasFinished {
                        Button {
                            center.clearFinished(for: sessionId)
                        } label: {
                            Text("Clear", comment: "Downloads panel action")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Viewing the panel clears the badge; records themselves persist
        // until the user clears them (rows / Clear Completed) — the floating
        // button hides only when the list is actually empty.
        .onAppear { center.markAllSeen(for: sessionId) }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preview(let url):
                BrowserFilePreviewSheet(url: url)
            case .share(let url):
                BrowserActivityView(items: [url])
            }
        }
    }
}

/// One panel row: state icon + filename + progress/summary, with a
/// state-appropriate trailing action. Completed rows open the QuickLook or
/// plain-text preview; their share button hands the file itself to the
/// system share sheet.
private struct BrowserDownloadPanelRow: View {
    let entry: BrowserDownloadCenter.Entry
    let onCancel: () -> Void
    let onPreview: () -> Void
    let onShare: () -> Void
    let onLocate: (() -> Void)?
    let onClear: () -> Void
    @StateObject private var progress: DownloadProgressObserver

    init(entry: BrowserDownloadCenter.Entry,
         onCancel: @escaping () -> Void,
         onPreview: @escaping () -> Void,
         onShare: @escaping () -> Void,
         onLocate: (() -> Void)?,
         onClear: @escaping () -> Void) {
        self.entry = entry
        self.onCancel = onCancel
        self.onPreview = onPreview
        self.onShare = onShare
        self.onLocate = onLocate
        self.onClear = onClear
        _progress = StateObject(wrappedValue: DownloadProgressObserver(progress: entry.progress))
    }

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .font(.system(size: 24))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.filename)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch entry.state {
                case .downloading:
                    let done = ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)
                    let pctText = progress.total > 0 ? "\(Int(progress.fraction * 100))% · " : ""
                    let totalText = progress.total > 0
                        ? " / \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))" : ""
                    Text("\(pctText)\(done)\(totalText)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                case .completed(let sizeText):
                    Text("\(sizeText) · 点按查看")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch entry.state {
            case .downloading:
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            case .completed:
                HStack(spacing: 10) {
                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Share file"))

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .disabled(entry.localFileURL == nil)
            case .failed:
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if case .completed = entry.state { onPreview() }
        }
        .contextMenu {
            if case .completed = entry.state, let locate = onLocate {
                Button {
                    locate()
                } label: {
                    Label(String(localized: "Show in Files", comment: "Completed download context action"),
                          systemImage: "folder")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if entry.state != .downloading {
                Button(role: .destructive, action: onClear) {
                    Label(String(localized: "Clear"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private var stateIcon: some View {
        switch entry.state {
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .symbolEffectPulseIfAvailable()
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// One download card: state icon + filename + live progress (percent and
/// downloaded/total bytes) or completion/failure summary. Completed cards
/// are tappable (open the file preview).
struct BrowserDownloadCardRow: View {
    let entry: BrowserDownloadCenter.Entry
    let onTap: (() -> Void)?
    let onDismiss: (() -> Void)?
    @StateObject private var progress: DownloadProgressObserver

    init(entry: BrowserDownloadCenter.Entry,
         onTap: (() -> Void)?,
         onDismiss: (() -> Void)?) {
        self.entry = entry
        self.onTap = onTap
        self.onDismiss = onDismiss
        _progress = StateObject(wrappedValue: DownloadProgressObserver(progress: entry.progress))
    }

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
                .font(.system(size: 22))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                if case .downloading = entry.state {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    @ViewBuilder private var stateIcon: some View {
        switch entry.state {
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(Color.accentColor)
                .symbolEffectPulseIfAvailable()
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch entry.state {
        case .downloading:
            let done = ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)
            let pctText = progress.total > 0 ? "\(Int(progress.fraction * 100))% · " : ""
            let totalText = progress.total > 0
                ? " / \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))" : ""
            Text("\(pctText)\(done)\(totalText)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .completed(let sizeText):
            Text("\(sizeText) · \(String(localized: "Tap to view", comment: "Completed download card"))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

private extension View {
    /// Gentle pulse on the in-progress icon where the OS supports it.
    @ViewBuilder func symbolEffectPulseIfAvailable() -> some View {
        if #available(iOS 17, *) {
            self.symbolEffect(.pulse)
        } else {
            self
        }
    }
}

/// KVO bridge: republishes a WKDownload's NSProgress (fractionCompleted /
/// byte counts) on the main thread so SwiftUI text refreshes live — a bare
/// `Progress` held in a struct is not observed by SwiftUI for Text purposes.
final class DownloadProgressObserver: ObservableObject {
    @Published var fraction: Double
    @Published var completed: Int64
    @Published var total: Int64
    private var observation: NSKeyValueObservation?

    init(progress: Progress) {
        fraction = progress.fractionCompleted
        completed = progress.completedUnitCount
        total = progress.totalUnitCount
        // fractionCompleted changes whenever completed/total unit counts do,
        // so one observation covers all three published values.
        observation = progress.observe(\.fractionCompleted, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.fraction = p.fractionCompleted
                self?.completed = p.completedUnitCount
                self?.total = p.totalUnitCount
            }
        }
    }
}

/// [T-ios-webview-error-ui] Observes the manager's `loadError` and renders the
/// shared Safari-style overlay (with Retry) over the agent browser's blank
/// page. Split into its own `@ObservedObject` view so a `loadError` change
/// actually re-renders — the parent reads `manager` via a computed property and
/// wouldn't otherwise observe it.
private struct BrowserLoadErrorOverlay: View {
    @ObservedObject var manager: BrowserUseManager

    var body: some View {
        if let err = manager.loadError {
            WebLoadErrorOverlay(error: err) { manager.retryFailedLoad() }
        }
    }
}

// Source: OpenMinis/OpenMinis at 1a71df0f381cefde80bf912b723de6f9831bc177,
// src/ios/Views/Chat/AIChatView/Composer/ComposerSurface.swift.
struct FloatingCircleButtonSurface: ViewModifier {
    var legacyLightOpacity: Double = 0.92
    var legacyStrokeOpacity: Double = 0.35
    var legacyShadowOpacity: Double = 0.18
    var legacyShadowRadius: CGFloat = 5

    @Environment(\.colorScheme) private var colorScheme

    /// Glyph style for icons on this surface. Inside a default-styled Button
    /// both resolve against the button tint (accent): `.secondary` is a faded
    /// accent that washes out against the glass material, `.primary` is the
    /// full-strength accent, which stays readable (verified on device).
    /// Sub-26 keeps the original `.secondary` over its opaque disc.
    static var glyphStyle: HierarchicalShapeStyle {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return .primary }
        #endif
        return .secondary
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        } else {
            legacySurface(content: content)
        }
        #else
        legacySurface(content: content)
        #endif
    }

    private func legacySurface(content: Content) -> some View {
        content
            .background {
                Color(.systemBackground)
                    .opacity(colorScheme == .dark ? 0.8 : legacyLightOpacity)
                    .clipShape(Circle())
            }
            .overlay(Circle().stroke(Color.gray.opacity(legacyStrokeOpacity), lineWidth: 0.5))
            .shadow(color: .black.opacity(legacyShadowOpacity), radius: legacyShadowRadius, y: 2)
    }
}
