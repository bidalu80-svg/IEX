import Foundation
import QuickLook
import SwiftUI
import UIKit

// MARK: - Preview routing

/// What kind of viewer a downloaded file needs. Text and source files are
/// rendered directly as plain text (the plan deliberately excludes Markdown
/// rendering); media/PDF/office documents go through QuickLook; anything else
/// falls straight through to the system share sheet.
enum BrowserPreviewKind {
    case text
    case quickLook
    case shareOnly

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "csv", "tsv", "json", "xml",
        "yml", "yaml", "toml", "ini", "conf", "cfg", "plist",
        "html", "htm", "css", "scss", "less",
        "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "swift", "py", "rb", "go", "rs", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm",
        "sh", "bash", "zsh", "fish", "sql", "php", "lua", "r"
    ]

    private static let quickLookExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff",
        "tif", "bmp", "svg", "ico",
        "pdf",
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "rtf", "pages", "numbers", "key", "epub", "usdz"
    ]

    static func kind(for url: URL) -> BrowserPreviewKind {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if quickLookExtensions.contains(ext) { return .quickLook }
        return .shareOnly
    }
}

// MARK: - File preview sheet

/// Full-file preview with a share entry point. Used by the download toast and
/// the downloads panel. Text/source files use the plain-text viewer; media,
/// PDFs and office documents use QuickLook; unsupported files are routed to
/// the share sheet by the caller instead of opening this view.
struct BrowserFilePreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch BrowserPreviewKind.kind(for: url) {
                case .text:
                    BrowserPlainTextPreview(url: url)
                case .quickLook:
                    BrowserQuickLookPreview(url: url)
                        .ignoresSafeArea(edges: .bottom)
                case .shareOnly:
                    VStack(spacing: 14) {
                        Image(systemName: "doc")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("This file type has no in-app preview. Use Share to open or save it.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("Share file"))
                }
            }
        }
    }
}

/// QuickLook wrapper for files whose native preview is media/document based.
struct BrowserQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        private let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// Plain monospaced text viewer. Reads the file off the main thread so large
/// downloads cannot hitch the sheet; the text itself is selectable.
struct BrowserPlainTextPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .systemBackground
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        textView.text = String(localized: "Loading…")

        let fileURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? Data(contentsOf: fileURL)) ?? Data()
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            DispatchQueue.main.async {
                // `textView` is a local strong reference; setting text after
                // the view is gone is harmless (UIKit just drops it).
                textView.text = text
            }
        }
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}
}

// MARK: - Generic system activity sheet

/// UIActivityViewController wrapper for sharing a file URL itself. "Save to
/// Files" is the system-provided activity, so there is no custom save path.
struct BrowserActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
