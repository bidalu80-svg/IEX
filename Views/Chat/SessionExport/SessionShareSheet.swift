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
    private static let toolIOKey = "sessionExport.includeToolIO"
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
        if defaults.object(forKey: toolIOKey) != nil {
            options.includeToolIO = defaults.bool(forKey: toolIOKey)
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
        defaults.set(options.includeToolIO, forKey: toolIOKey)
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
        NavigationStack {
            VStack(spacing: 0) {
                previewPanel

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
                .navigationTitle(String(localized: "Share Session"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { shareToolbar }
                .overlay {
                    if isRendering {
                        Color.black.opacity(0.05).ignoresSafeArea()
                    }
                }
                .sheet(item: $route) { route in
                    routeContent(route)
                }
            }
        }
        .onChange(of: options) { _, newValue in
            SessionExportOptionsStore.save(newValue)
            schedulePreview()
        }
        .onChange(of: scope) { _, _ in
            schedulePreview()
        }
        .onAppear {
            schedulePreview()
        }
    }

    // MARK: Toolbar

    /// [T-share-toolbar-ambiguous] Kept out of `body` as an explicitly typed
    /// `ToolbarContent` value. Inline, `toolbar(content:)` had two viable
    /// overloads — the `@ViewBuilder` one and the `@ToolbarContentBuilder`
    /// one — and the compiler gave up on the whole chain rather than picking
    /// the latter (Xcode 16.4, iOS 18.5 SDK). Returning an opaque
    /// `some ToolbarContent` makes the `View` overload inapplicable, and it
    /// also keeps `body` short enough for the type checker.
    @ToolbarContentBuilder
    private var shareToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(String(localized: "Cancel")) { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                preview()
            } label: {
                Image(systemName: "eye")
            }
            .disabled(isRendering || selectedCount == 0)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                export()
            } label: {
                Group {
                    if isRendering {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .disabled(isRendering || selectedCount == 0)
        }
    }

    @ViewBuilder
    private func routeContent(_ route: SessionShareRoute) -> some View {
        switch route {
        case .range:
            SessionExportRangePicker(messages: selectableMessages, scope: $scope)
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
        // Bound the work: only the first screenful matters, so build from at
        // most 60 scoped messages instead of the whole conversation.
        let scoped = messages.filter { scope.contains($0.id) }
        let previewMessages = Array(scoped.prefix(60))
        let options = self.options
        let document = SessionExportBuilder.build(
            messages: previewMessages,
            scope: .all,
            options: options,
            header: options.includeHeader ? header : nil
        )
        guard !document.isEmpty else {
            previewImage = nil
            return
        }

        let blocks = Array(document.blocks.prefix(40))
        let pageWidth = options.width.pageWidth(adaptiveWidth: adaptiveWidth)
        let metrics = SessionExportMetrics(pageWidth: pageWidth)
        let palette = SessionExportPalette.palette(for: options.theme)
        // PDF previews exactly one page; the image format previews the top
        // strip of the single tall image.
        let previewHeight = options.format == .pdf ? (pageWidth * 1.4142).rounded() : 900
        let token = UUID()
        previewToken = token

        DispatchQueue.global(qos: .userInitiated).async {
            let layout = SessionExportLayout(blocks: blocks, palette: palette, metrics: metrics)
            let renderer = SessionExportRenderer(layout: layout, palette: palette, metrics: metrics)
            let image = renderer.makePreviewImage(maxHeight: previewHeight)

            DispatchQueue.main.async {
                guard previewToken == token else { return }
                previewImage = image
            }
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
            Toggle(isOn: $options.includeToolIO) {
                Label(String(localized: "Tool Input and Result"), systemImage: "text.alignleft")
            }
            .disabled(!options.includeToolCalls)
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

    private func makeDocument() -> SessionExportDocument {
        SessionExportBuilder.build(
            messages: messages,
            scope: scope,
            options: options,
            header: options.includeHeader ? header : nil
        )
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
        let document = makeDocument()
        guard !document.isEmpty else {
            completion(.failure(SessionExportError.empty))
            return
        }

        let options = self.options
        let pageWidth = options.width.pageWidth(adaptiveWidth: adaptiveWidth)
        let metrics = SessionExportMetrics(pageWidth: pageWidth)
        let palette = SessionExportPalette.palette(for: options.theme)

        isRendering = true
        errorText = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let layout = SessionExportLayout(blocks: document.blocks, palette: palette, metrics: metrics)
            let renderer = SessionExportRenderer(layout: layout, palette: palette, metrics: metrics)

            let result: Result<SessionExportPayload, Error>
            switch options.format {
            case .image:
                let images = renderer.makeImages()
                if images.isEmpty {
                    result = .failure(SessionExportError.empty)
                } else {
                    result = .success(SessionExportPayload(images: images, pdfURL: nil))
                }
            case .pdf:
                if let data = renderer.makePDFData(), let url = Self.writePDF(data) {
                    result = .success(SessionExportPayload(images: [], pdfURL: url))
                } else {
                    result = .failure(SessionExportError.renderFailed)
                }
            }

            DispatchQueue.main.async {
                self.isRendering = false
                completion(result)
            }
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

struct SessionExportRangePicker: View {
    let messages: [ChatMessage]
    @Binding var scope: SessionExportScope
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []

    private var allIDs: Set<UUID> { Set(messages.map(\.id)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if selection.count == messages.count {
                            selection.removeAll()
                        } else {
                            selection = allIDs
                        }
                    } label: {
                        HStack {
                            Text(String(localized: "Select All"))
                            Spacer()
                            Text("\(selection.count)/\(messages.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach(messages, id: \.id) { message in
                        Button {
                            toggle(message.id)
                        } label: {
                            row(message)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(String(localized: "Select Messages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        scope = selection.count == messages.count ? .all : .selected(selection)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .onAppear {
                if case .selected(let ids) = scope {
                    selection = ids
                } else {
                    selection = allIDs
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func row(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selection.contains(message.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selection.contains(message.id) ? Color.accentColor : Color.secondary)
                .font(.system(size: 18))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(message.role == .user
                         ? String(localized: "You")
                         : String(localized: "Assistant"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(snippet(message))
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }

    private func snippet(_ message: ChatMessage) -> String {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        if let first = message.blocks.first(where: { block in
            if case .text = block.kind { return true }
            return false
        }) {
            let blockText = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !blockText.isEmpty {
                return blockText.replacingOccurrences(of: "\n", with: " ")
            }
        }
        if let name = message.attachments.first?.fileName {
            return "📎 \(name)"
        }
        return "—"
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
