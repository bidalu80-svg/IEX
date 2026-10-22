//
//  SessionShareSheet.swift
//  ZeApp
//
//  [T-session-share-single-screen] One screen for everything. The transcript
//  below is rendered with the real chat views, so it *is* the live preview;
//  the export options sit in a chip row at the bottom instead of a separate
//  configuration form. Selecting messages and choosing the output format no
//  longer require bouncing between sheets.
//

import PDFKit
import SwiftUI
import UIKit

// MARK: - Persisted options

enum SessionExportOptionsStore {
    private static let formatKey = "sessionExport.format"
    private static let widthKey = "sessionExport.width"
    private static let themeKey = "sessionExport.theme"
    private static let toolCallsKey = "sessionExport.includeToolCalls"
    private static let thinkingKey = "sessionExport.includeThinking"
    private static let headerKey = "sessionExport.includeHeader"

    static func load() -> SessionExportOptions {
        let defaults = UserDefaults.standard
        var options = SessionExportOptions()

        if let raw = defaults.string(forKey: formatKey),
           let value = SessionExportFormat(rawValue: raw) {
            options.format = value
        }
        if let raw = defaults.string(forKey: widthKey),
           let value = SessionExportWidth(rawValue: raw) {
            options.width = value
        }
        if let raw = defaults.string(forKey: themeKey),
           let value = SessionExportTheme(rawValue: raw) {
            options.theme = value
        }

        // Defaults are the "everything visible" variant; only override when
        // the user has actually stored a value.
        if defaults.object(forKey: toolCallsKey) != nil {
            options.includeToolCalls = defaults.bool(forKey: toolCallsKey)
        }
        if defaults.object(forKey: thinkingKey) != nil {
            options.includeThinking = defaults.bool(forKey: thinkingKey)
        }
        if defaults.object(forKey: headerKey) != nil {
            options.includeHeader = defaults.bool(forKey: headerKey)
        }
        return options
    }

    static func save(_ options: SessionExportOptions) {
        let defaults = UserDefaults.standard
        defaults.set(options.format.rawValue, forKey: formatKey)
        defaults.set(options.width.rawValue, forKey: widthKey)
        defaults.set(options.theme.rawValue, forKey: themeKey)
        defaults.set(options.includeToolCalls, forKey: toolCallsKey)
        defaults.set(options.includeThinking, forKey: thinkingKey)
        defaults.set(options.includeHeader, forKey: headerKey)
    }
}

// MARK: - Payload

struct SessionExportPayload: Identifiable {
    let id = UUID()
    let images: [UIImage]
    let pdfURL: URL?

    var shareItems: [Any] {
        if let pdfURL { return [pdfURL] }
        return images
    }

    var isEmpty: Bool { images.isEmpty && pdfURL == nil }
}

// MARK: - Share sheet

private enum SessionShareRoute: Identifiable {
    case share(SessionExportPayload)
    case preview(SessionExportPayload)

    var id: String {
        switch self {
        case .share(let payload):
            return "share-\(payload.id.uuidString)"
        case .preview(let payload):
            return "preview-\(payload.id.uuidString)"
        }
    }
}

@MainActor
struct SessionShareSheet: View {
    let messages: [ChatMessage]
    let header: SessionExportHeader
    let adaptiveWidth: CGFloat
    /// [T-session-share-native] The export renders the real chat rows, and
    /// those rows read the view model from the environment (tool capsule
    /// menus). The sheet is always presented from the chat, so the live
    /// instance is available — no dummy model needed.
    let vm: AIChatViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var options: SessionExportOptions = SessionExportOptionsStore.load()
    @State private var selection: Set<UUID> = []
    @State private var route: SessionShareRoute?
    @State private var isRendering = false
    @State private var errorText: String?
    /// Anchor for "Select Below": the turn the user touched last.
    @State private var lastTapped: UUID?

    private var selectableMessages: [ChatMessage] {
        messages.filter { $0.role == .user || $0.role == .assistant }
    }

    private var allIDs: Set<UUID> { Set(selectableMessages.map(\.id)) }

    /// `nil` header means the user turned the header off; the transcript then
    /// starts straight at the first message, exactly like the export does.
    private var exportHeader: SessionExportHeader? {
        options.includeHeader ? header : nil
    }

    private var scope: SessionExportScope {
        selection.count == selectableMessages.count ? .all : .selected(selection)
    }

    private var transcriptScheme: ColorScheme {
        options.theme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            selectionChips
            Divider()
            transcript
            Divider()
            optionChips
            shareBar
        }
        .background(Color(UIColor.systemBackground))
        .overlay {
            if isRendering {
                Color.black.opacity(0.06).ignoresSafeArea()
            }
        }
        .sheet(item: $route) { route in
            routeContent(route)
        }
        .onAppear {
            // Everything is selected until the user narrows it down, which
            // matches the previous default scope (.all).
            if selection.isEmpty { selection = allIDs }
        }
        // [T-share-ios16-onchange] The two-parameter `onChange(of:) { old, new in }`
        // closure is iOS 17+, and the app target is iOS 16.0.
        .onChange(of: options) { newValue in
            SessionExportOptionsStore.save(newValue)
        }
    }

    // MARK: Header

    private var headerBar: some View {
        ZStack {
            Text(String(format: String(localized: "%ld selected"), selection.count))
                .font(.headline)

            HStack {
                Button(String(localized: "Cancel")) { dismiss() }
                Spacer(minLength: 0)
                Button(selection.count == selectableMessages.count
                       ? String(localized: "Deselect All")
                       : String(localized: "Select All")) {
                    selection = selection.count == selectableMessages.count ? [] : allIDs
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Selection chips

    private var selectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "Select Below"),
                     systemImage: "arrow.down.to.line") {
                    selectBelow()
                }
                chip(String(localized: "Clear Selection"),
                     systemImage: "xmark") {
                    selection.removeAll()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if options.includeHeader {
                    SessionExportHeaderCard(header: header, scheme: transcriptScheme)
                }
                ForEach(selectableMessages, id: \.id) { message in
                    SessionExportPickerRow(message: message,
                                           isSelected: selection.contains(message.id),
                                           showTools: options.includeToolCalls,
                                           showThinking: options.includeThinking,
                                           scheme: transcriptScheme,
                                           vm: vm)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            lastTapped = message.id
                            if selection.contains(message.id) {
                                selection.remove(message.id)
                            } else {
                                selection.insert(message.id)
                            }
                        }
                }
            }
            .padding(.vertical, 6)
        }
        // The transcript is the preview: theme changes show up here, not in a
        // separate thumbnail strip.
        .background(options.theme == .dark ? Color(UIColor(white: 0.07, alpha: 1)) : Color(UIColor.systemBackground))
        .environment(\.colorScheme, transcriptScheme)
    }

    // MARK: Option chips

    /// [T-session-share-single-screen] The former Form sections, flattened
    /// into the same capsule row the picker already used. Enum options open a
    /// menu; booleans toggle in place.
    private var optionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chipMenu(options.format.title, systemImage: options.format.systemImage) {
                    Picker(String(localized: "Format"), selection: $options.format) {
                        ForEach(SessionExportFormat.allCases) { format in
                            Label(format.title, systemImage: format.systemImage).tag(format)
                        }
                    }
                }

                chipMenu(options.width.title, systemImage: "rectangle.portrait") {
                    Picker(String(localized: "Page Width"), selection: $options.width) {
                        ForEach(SessionExportWidth.allCases) { width in
                            Text(width.title).tag(width)
                        }
                    }
                }

                chipMenu(options.theme.title, systemImage: "circle.lefthalf.filled") {
                    Picker(String(localized: "Theme"), selection: $options.theme) {
                        ForEach(SessionExportTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                }

                toggleChip(String(localized: "Tool Calls"),
                           systemImage: "wrench.and.screwdriver",
                           isOn: $options.includeToolCalls)

                toggleChip(String(localized: "Thinking"),
                           systemImage: "brain",
                           isOn: $options.includeThinking)

                toggleChip(String(localized: "Avatar, Model and Date"),
                           systemImage: "person.crop.circle",
                           isOn: $options.includeHeader)

                chip(String(localized: "Preview"), systemImage: "eye") {
                    preview()
                }
                .disabled(isRendering || selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ title: String,
                      systemImage: String,
                      isOn: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(title, systemImage: systemImage, isOn: isOn)
        }
        .buttonStyle(.plain)
    }

    private func chipMenu<Content: View>(_ title: String,
                                         systemImage: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            chipLabel(title, systemImage: systemImage, isOn: true, showsChevron: true)
        }
    }

    private func toggleChip(_ title: String,
                            systemImage: String,
                            isOn: Binding<Bool>,
                            isEnabled: Bool = true) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            chipLabel(title,
                      systemImage: systemImage,
                      isOn: isOn.wrappedValue && isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func chipLabel(_ title: String,
                           systemImage: String,
                           isOn: Bool,
                           showsChevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(isOn
                           ? Color.accentColor.opacity(0.12)
                           : Color(UIColor.secondarySystemBackground))
        )
    }

    // MARK: Share bar

    private var shareBar: some View {
        VStack(spacing: 0) {
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Button {
                export()
            } label: {
                HStack(spacing: 8) {
                    if isRendering {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(String(format: String(localized: "Share (%ld)"), selection.count))
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selection.isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty || isRendering)
            .padding(16)
        }
        .background(Color(UIColor.systemBackground))
    }

    // MARK: Routing

    @ViewBuilder
    private func routeContent(_ route: SessionShareRoute) -> some View {
        switch route {
        case .share(let payload):
            SessionExportActivityView(items: payload.shareItems)
                .ignoresSafeArea()
        case .preview(let payload):
            SessionExportPreviewSheet(payload: payload, title: header.title)
        }
    }

    // MARK: Actions

    private func selectBelow() {
        let anchor = lastTapped ?? selectableMessages.last?.id
        guard let anchor,
              let index = selectableMessages.firstIndex(where: { $0.id == anchor })
        else { return }
        selection.formUnion(selectableMessages[index...].map(\.id))
    }

    private func export() {
        render { result in
            switch result {
            case .success(let payload):
                self.route = .share(payload)
            case .failure(let error):
                self.errorText = error.localizedDescription
            }
        }
    }

    private func preview() {
        render { result in
            switch result {
            case .success(let payload):
                self.route = .preview(payload)
            case .failure(let error):
                self.errorText = error.localizedDescription
            }
        }
    }

    private func render(completion: @escaping (Result<SessionExportPayload, Error>) -> Void) {
        guard !isRendering else { return }
        guard !selection.isEmpty else {
            completion(.failure(SessionExportError.empty))
            return
        }

        let options = self.options
        let scope = self.scope
        let header = exportHeader
        isRendering = true
        errorText = nil

        // [T-session-share-native] Snapshotting the real chat rows has to run
        // on the main actor (UIKit). Yield once so the progress overlay gets a
        // chance to paint before the synchronous render pass begins.
        Task { @MainActor in
            await Task.yield()

            let renderer = SessionExportNativeRenderer(messages: messages,
                                                       scope: scope,
                                                       options: options,
                                                       header: header,
                                                       vm: vm,
                                                       adaptiveWidth: adaptiveWidth)

            let result: Result<SessionExportPayload, Error>
            switch options.format {
            case .image:
                let images = renderer.makeImages()
                result = images.isEmpty
                    ? .failure(SessionExportError.empty)
                    : .success(SessionExportPayload(images: images, pdfURL: nil))
            case .pdf:
                if let data = renderer.makePDFData(), let url = Self.writePDF(data) {
                    result = .success(SessionExportPayload(images: [], pdfURL: url))
                } else {
                    result = .failure(SessionExportError.renderFailed)
                }
            }

            self.isRendering = false
            completion(result)
        }
    }

    /// `nonisolated` because it runs inside the background render closure;
    /// without it the call is main-actor isolated and Swift 6 rejects it.
    nonisolated private static func writePDF(_ data: Data) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Ze-Session-\(formatter.string(from: Date())).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Picker row

/// One selectable turn. Assistant replies go through the same
/// header/block/footer composition the message list uses, so the picker shows
/// what the export will contain instead of a flattened approximation.
private struct SessionExportPickerRow: View {
    @ObservedObject var message: ChatMessage
    let isSelected: Bool
    let showTools: Bool
    let showThinking: Bool
    let scheme: ColorScheme
    let vm: AIChatViewModel

    /// Owned here so the bridge's published state survives body re-evaluation
    /// while the user scrolls and taps.
    @StateObject private var bridge = CellStateBridgeV2()

    var body: some View {
        Group {
            if message.role == .assistant {
                SessionExportAssistantTurn(message: displayMessage,
                                           bridge: bridge,
                                           maxWidth: 0)
            } else {
                ChatMessageRow(
                    message: displayMessage,
                    isActiveMessage: false,
                    commandStartTime: nil,
                    onStop: nil,
                    onRetry: nil,
                    onEdit: nil,
                    onDelete: nil,
                    onWithdraw: nil,
                    autoRetryAttempt: 0,
                    autoRetryCountdown: 0,
                    canResume: false,
                    onResume: nil,
                    onCompact: nil,
                    onCopyScreenshot: nil,
                    onReadAloud: nil,
                    onShowCompactSummary: nil,
                    onRevertCompact: nil,
                    onToggleUserMessageExpansion: nil,
                    browserPool: nil,
                    toolSnapshots: []
                )
            }
        }
        .environmentObject(vm)
        .environment(\.colorScheme, scheme)
        .padding(.vertical, 2)
        .opacity(isSelected ? 1 : 0.38)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(alignment: .topTrailing) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
        .onAppear(perform: configureBridge)
    }

    private func configureBridge() {
        // Static, non-interactive: the picker must not start speech or retry.
        bridge.isActiveMessage = false
        bridge.showUsage = message.usage != nil
        bridge.usageContentVisible = true
        // Kept off here so a long conversation stays scannable while picking;
        // the export turns the action bar back on.
        bridge.showsCompletionActions = false
    }

    private var displayMessage: ChatMessage {
        let blocks = message.blocks.filter { block in
            switch block.kind {
            case .thinking:
                return showThinking
            case .text, .info:
                return true
            default:
                return showTools
            }
        }

        let copy = ChatMessage(role: message.role,
                               content: message.content,
                               blocks: blocks,
                               isQueued: false,
                               timestamp: message.timestamp)
        copy.attachments = message.attachments
        copy.inputAttachments = message.inputAttachments
        copy.firstTokenLatency = message.firstTokenLatency
        copy.taskDuration = message.taskDuration
        copy.usage = message.usage
        copy.streamInterruptCount = message.streamInterruptCount
        copy.isUserTextExpanded = true
        return copy
    }
}

// MARK: - Errors

enum SessionExportError: LocalizedError {
    case empty
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "Nothing to export.")
        case .renderFailed: return String(localized: "Could not render the session.")
        }
    }
}

// MARK: - Preview

struct SessionExportPreviewSheet: View {
    let payload: SessionExportPayload
    let title: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let pdfURL = payload.pdfURL {
                    SessionExportPDFView(url: pdfURL)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(spacing: 12) {
                            ForEach(Array(payload.images.enumerated()), id: \.offset) { _, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .padding(.horizontal, 16)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        SessionExportActivityPresenter.present(items: payload.shareItems)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

private struct SessionExportPDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

// MARK: - Activity sheet

struct SessionExportActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Fallback presenter for the preview sheet's share button, where there is
/// no `UIViewControllerRepresentable` hosting the activity controller.
enum SessionExportActivityPresenter {
    static func present(items: [Any]) {
        guard !items.isEmpty else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first?.rootViewController else { return }

        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }

        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY,
                                        width: 0,
                                        height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }
}
