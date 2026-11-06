//
//  SessionShareSheet.swift
//  ZeApp
//
//  The conversation-menu adapter opens the source-derived block-selection page,
//  followed by its automatically rendered image/PDF preview. Historical export
//  helpers below remain for existing callers; the active path uses ChatExportRenderer.
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

/// Entry point from the conversation menu. Selection and export use frozen models.
@MainActor
struct SessionShareSheet: View {
    let messages: [ChatMessage]
    let header: SessionExportHeader
    let adaptiveWidth: CGFloat
    let vm: AIChatViewModel
    var initialMessageId: UUID? = nil
    @State private var request: ChatShareRequest?

    var body: some View {
        Group {
            if let request { ChatShareSelectionView(request: request) }
            else { ProgressView() }
        }
        .task {
            guard request == nil else { return }
            request = ChatShareSnapshot.request(messages: messages, title: header.title, vm: vm, messageId: initialMessageId)
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
