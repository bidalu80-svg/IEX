//
//  SessionShareSheet.swift
//  ZeApp
//
//  [T-session-share] "Share Session" configuration sheet: long image / PDF,
//  phone / iPad / adaptive width, light / dark theme, content granularity,
//  and message scope (everything or a hand-picked subset).
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
    case range
    case share(SessionExportPayload)
    case preview(SessionExportPayload)

    var id: String {
        switch self {
        case .range:
            return "range"
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
    @State private var scope: SessionExportScope = .all
    @State private var route: SessionShareRoute?
    @State private var isRendering = false
    @State private var errorText: String?

    /// [T-session-share-live-preview] Debounced thumbnail state. The token
    /// guards against a slow render landing after a newer one.
    @State private var previewImage: UIImage?
    @State private var previewWorkItem: DispatchWorkItem?
    @State private var previewToken = UUID()

    private var selectableMessages: [ChatMessage] {
        messages.filter { $0.role == .user || $0.role == .assistant }
    }

    private var selectedCount: Int {
        switch scope {
        case .all:
            return selectableMessages.count
        case .selected(let ids):
            return selectableMessages.filter { ids.contains($0.id) }.count
        }
    }

    var body: some View {
        // [T-share-toolbar-ambiguous] No NavigationStack / toolbar modifier.
        // `toolbar(content:)` exposes both a ViewBuilder and a
        // ToolbarContentBuilder overload on iOS 16+, and on Xcode 16.4 the
        // compiler kept reporting "ambiguous use of 'toolbar(content:)'" for
        // inline items, an opaque `some ToolbarContent` property, and a
        // concrete `ToolbarContent` struct alike. A hand-rolled header bar has
        // no overload to resolve, and the sheet still hosts its own
        // NavigationStacks for the picker and preview.
        VStack(spacing: 0) {
            headerBar
            previewPanel
            formContent
        }
        .background(Color(UIColor.systemGroupedBackground))
        .overlay {
            if isRendering {
                Color.black.opacity(0.05).ignoresSafeArea()
            }
        }
        .sheet(item: $route) { route in
            routeContent(route)
        }
        // [T-share-ios16-onchange] The two-parameter `onChange(of:) { old, new in }`
        // closure is iOS 17+, and the app target is iOS 16.0. Use the
        // single-parameter form so the share sheet compiles on the deployment
        // floor instead of relying on the CI runner's SDK.
        .onChange(of: options) { newValue in
            SessionExportOptionsStore.save(newValue)
            schedulePreview()
        }
        .onChange(of: scope) { _ in
            schedulePreview()
        }
        .onAppear {
            schedulePreview()
        }
    }

    /// Hand-rolled replacement for the navigation bar (see the note on `body`).
    private var headerBar: some View {
        ZStack {
            Text(String(localized: "Share Session"))
                .font(.headline)

            HStack(spacing: 18) {
                Button {
                    dismiss()
                } label: {
                    Text(String(localized: "Cancel"))
                }

                Spacer(minLength: 0)

                Button {
                    preview()
                } label: {
                    Image(systemName: "eye")
                }
                .disabled(isRendering || selectedCount == 0)

                Button {
                    export()
                } label: {
                    if isRendering {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isRendering || selectedCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemGroupedBackground))
    }

    // MARK: Toolbar

    /// [T-share-toolbar-ambiguous] `toolbar(content:)` ships two generic
    /// overloads on iOS 16 — one taking `@ViewBuilder` content constrained to
    /// `View`, one taking `@ToolbarContentBuilder` content constrained to
    /// `ToolbarContent`. Writing the items inline, or behind an opaque
    /// `some ToolbarContent` property, left the compiler unable to discard the
    /// `View` overload (opaque results are opened inside their own module), so
    /// it reported "ambiguous use of 'toolbar(content:)'" on Xcode 16.4 /
    /// iOS 18.5 SDK. A concrete `ToolbarContent` type cannot satisfy
    /// `Content: View`, which makes the choice unambiguous.
    private var formContent: some View {
        Form {
            formatSection
            appearanceSection
            contentSection
            rangeSection

            if let errorText {
                Section {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func routeContent(_ route: SessionShareRoute) -> some View {
        switch route {
        case .range:
            SessionExportRangePicker(messages: selectableMessages,
                                     scope: $scope,
                                     vm: vm,
                                     options: options)
        case .share(let payload):
            SessionExportActivityView(items: payload.shareItems)
                .ignoresSafeArea()
        case .preview(let payload):
            SessionExportPreviewSheet(payload: payload, title: header.title)
        }
    }

    // MARK: Live preview

    /// A pinned strip above the form that re-renders ~200 ms after any option
    /// change, so the effect of a toggle is visible without leaving the sheet.
    private var previewPanel: some View {
        Button {
            preview()
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))

                if let previewImage {
                    GeometryReader { geo in
                        let width = geo.size.width
                        let ratio = previewImage.size.height / max(previewImage.size.width, 1)
                        Image(uiImage: previewImage)
                            .resizable()
                            .frame(width: width, height: width * ratio, alignment: .top)
                            // [T-share-preview-clip] The ZStack is bottom-aligned
                            // for the gradient + label, so the oversized image has
                            // to be pinned to the TOP of its own box explicitly —
                            // otherwise the strip shows the bottom of the render
                            // (a wall of tool-output JSON) instead of the header.
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .clipped()
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                        Text(String(localized: "Live Preview"))
                            .font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                LinearGradient(
                    colors: [Color.clear, Color(UIColor.secondarySystemGroupedBackground).opacity(0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 44)
                .allowsHitTesting(false)

                HStack(spacing: 6) {
                    Label(String(localized: "Live Preview"), systemImage: "eye")
                        .font(.caption2.weight(.medium))
                    Spacer()
                    Text(String(localized: "Tap to open full preview"))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.6)
            )
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
    }

    private func schedulePreview() {
        previewWorkItem?.cancel()
        let item = DispatchWorkItem { renderPreview() }
        previewWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func renderPreview() {
        let options = self.options
        let header = options.includeHeader ? self.header : nil
        let token = UUID()
        previewToken = token

        Task { @MainActor in
            await Task.yield()
            let renderer = SessionExportNativeRenderer(messages: messages,
                                                       scope: scope,
                                                       options: options,
                                                       header: header,
                                                       vm: vm,
                                                       adaptiveWidth: adaptiveWidth)
            let image = renderer.makePreviewImage(maxHeight: 900)
            guard previewToken == token else { return }
            previewImage = image
        }
    }

    // MARK: Sections

    private var formatSection: some View {
        Section {
            Picker(String(localized: "Format"), selection: $options.format) {
                ForEach(SessionExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(String(localized: "Format"))
        } footer: {
            Text(options.format == .image
                 ? String(localized: "One tall image. Very long conversations are split into several images.")
                 : String(localized: "Paginated PDF with selectable text."))
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker(String(localized: "Page Width"), selection: $options.width) {
                ForEach(SessionExportWidth.allCases) { width in
                    Text(width.title).tag(width)
                }
            }
            .pickerStyle(.segmented)

            Picker(String(localized: "Theme"), selection: $options.theme) {
                ForEach(SessionExportTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(String(localized: "Appearance"))
        }
    }

    private var contentSection: some View {
        Section {
            Toggle(isOn: $options.includeHeader) {
                Label(String(localized: "Avatar, Model and Date"), systemImage: "person.crop.circle")
            }
            Toggle(isOn: $options.includeToolCalls) {
                Label(String(localized: "Tool Calls"), systemImage: "wrench.and.screwdriver")
            }
            Toggle(isOn: $options.includeThinking) {
                Label(String(localized: "Thinking"), systemImage: "brain")
            }
        } header: {
            Text(String(localized: "Content"))
        } footer: {
            Text(String(localized: "Thinking blocks are hidden by default because they can be very long."))
        }
    }

    private var rangeSection: some View {
        Section {
            Button {
                route = .range
            } label: {
                HStack {
                    Label(String(localized: "Messages"), systemImage: "text.bubble")
                    Spacer()
                    Text(scope.isAll
                         ? String(localized: "All")
                         : String(localized: "\(selectedCount) selected"))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text(String(localized: "Range"))
        } footer: {
            Text(String(localized: "Pick the whole conversation or just a few messages."))
        }
    }

    // MARK: Actions

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
        guard !messages.filter({ scope.contains($0.id) }).isEmpty else {
            completion(.failure(SessionExportError.empty))
            return
        }

        let options = self.options
        let header = options.includeHeader ? self.header : nil
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

// MARK: - Range picker

/// [T-share-picker-native] Mirrors the OpenMinis picker: the transcript is
/// rendered with the real chat rows and each turn is tapped to include or
/// exclude it. A plain text list made it impossible to tell turns apart once
/// tool calls and thinking blocks were involved.
struct SessionExportRangePicker: View {
    let messages: [ChatMessage]
    @Binding var scope: SessionExportScope
    let vm: AIChatViewModel
    let options: SessionExportOptions

    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []
    @State private var lastTapped: UUID?
    @State private var showTools = true
    @State private var showThinking = true

    private var allIDs: Set<UUID> { Set(messages.map(\.id)) }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            chipBar
            Divider()
            transcript
            shareBar
        }
        .background(Color(UIColor.systemBackground))
        .onAppear {
            if case .selected(let ids) = scope {
                selection = ids
            } else {
                selection = allIDs
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        ZStack {
            Text(String(format: String(localized: "%ld selected"), selection.count))
                .font(.headline)

            HStack {
                Button(String(localized: "Cancel")) { dismiss() }
                Spacer()
                Button(selection.count == messages.count
                       ? String(localized: "Deselect All")
                       : String(localized: "Select All")) {
                    selection = selection.count == messages.count ? [] : allIDs
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Chips

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "Select Below"),
                     systemImage: "arrow.down.to.line") {
                    selectBelow()
                }
                chip(showTools
                     ? String(localized: "Collapse Tools")
                     : String(localized: "Expand Tools"),
                     systemImage: "arrow.up.and.down.text.horizontal") {
                    showTools.toggle()
                }
                chip(showThinking
                     ? String(localized: "Hide Thinking")
                     : String(localized: "Show Thinking"),
                     systemImage: "brain") {
                    showThinking.toggle()
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

    private func chip(_ title: String,
                      systemImage: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color(UIColor.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(messages, id: \.id) { message in
                    selectableRow(message)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func selectableRow(_ message: ChatMessage) -> some View {
        let isSelected = selection.contains(message.id)

        return ChatMessageRow(
            message: pickerCopy(message),
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
        .environmentObject(vm)
        .padding(.vertical, 2)
        .opacity(isSelected ? 1 : 0.42)
        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
        .overlay(alignment: .topTrailing) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                .padding(.top, 8)
                .padding(.trailing, 10)
        }
        .overlay {
            // The whole row is the checkbox here: swallow taps that would
            // otherwise open a tool sheet or a context menu.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    lastTapped = message.id
                    if isSelected {
                        selection.remove(message.id)
                    } else {
                        selection.insert(message.id)
                    }
                }
        }
    }

    private func pickerCopy(_ message: ChatMessage) -> ChatMessage {
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
        copy.isUserTextExpanded = true
        return copy
    }

    // MARK: Actions

    private func selectBelow() {
        guard let anchor = lastTapped ?? messages.last?.id,
              let index = messages.firstIndex(where: { $0.id == anchor }) else { return }
        selection.formUnion(messages[index...].map(\.id))
    }

    private var shareBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                scope = selection.count == messages.count ? .all : .selected(selection)
                dismiss()
            } label: {
                Label(String(format: String(localized: "Share (%ld)"), selection.count),
                      systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selection.isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
            .padding(16)
        }
        .background(Color(UIColor.systemBackground))
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
                                        y: 64,
                                        width: 0,
                                        height: 0)
        }
        presenter.present(controller, animated: true)
    }
}
