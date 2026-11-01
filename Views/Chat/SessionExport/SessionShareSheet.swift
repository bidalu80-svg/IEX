// Share selection and rendered preview. Native chat models are detached before use.
import PDFKit
import SwiftUI
import UIKit

// MARK: - Persisted options

enum SessionExportOptionsStore {
    static func load() -> SessionExportOptions {
        let defaults = UserDefaults.standard
        var options = SessionExportOptions()
        if let raw = defaults.string(forKey: "sessionExport.format"), let value = SessionExportFormat(rawValue: raw) { options.format = value }
        if let raw = defaults.string(forKey: "sessionExport.width"), let value = SessionExportWidth(rawValue: raw) { options.width = value }
        if let raw = defaults.string(forKey: "sessionExport.theme"), let value = SessionExportTheme(rawValue: raw) { options.theme = value }
        if defaults.object(forKey: "sessionExport.includeToolCalls") != nil { options.includeToolCalls = defaults.bool(forKey: "sessionExport.includeToolCalls") }
        if defaults.object(forKey: "sessionExport.includeThinking") != nil { options.includeThinking = defaults.bool(forKey: "sessionExport.includeThinking") }
        if defaults.object(forKey: "sessionExport.includeHeader") != nil { options.includeHeader = defaults.bool(forKey: "sessionExport.includeHeader") }
        options.adaptiveTables = defaults.bool(forKey: "sessionExport.adaptiveTables")
        return options
    }

    static func save(_ options: SessionExportOptions) {
        let defaults = UserDefaults.standard
        defaults.set(options.format.rawValue, forKey: "sessionExport.format")
        defaults.set(options.width.rawValue, forKey: "sessionExport.width")
        defaults.set(options.theme.rawValue, forKey: "sessionExport.theme")
        defaults.set(options.includeToolCalls, forKey: "sessionExport.includeToolCalls")
        defaults.set(options.includeThinking, forKey: "sessionExport.includeThinking")
        defaults.set(options.includeHeader, forKey: "sessionExport.includeHeader")
        defaults.set(options.adaptiveTables, forKey: "sessionExport.adaptiveTables")
    }
}

struct SessionExportPayload: Identifiable {
    let id = UUID()
    let images: [UIImage]
    let pdfURL: URL?
    var shareItems: [Any] { if let pdfURL { return [pdfURL] }; return images }
    var isEmpty: Bool { images.isEmpty && pdfURL == nil }
}

private struct SessionSharePreviewInput: Identifiable {
    let id = UUID()
    let messages: [ChatMessage]
}

@MainActor
struct SessionShareSheet: View {
    let messages: [ChatMessage]
    let header: SessionExportHeader
    let adaptiveWidth: CGFloat
    let vm: AIChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = SessionExportOptionsStore.load()
    @State private var snapshot: [ChatMessage] = []
    @State private var cells: [SessionShareCell] = []
    @State private var selection: Set<SessionShareCell.ID> = []
    @State private var initialized = false
    @State private var lastTapped: SessionShareCell.ID?
    @State private var previewInput: SessionSharePreviewInput?
    @State private var rowFrames: [SessionShareCell.ID: CGRect] = [:]
    @State private var dragAnchor: SessionShareCell.ID?
    @State private var dragInitial: Set<SessionShareCell.ID> = []
    @State private var dragSelecting = true
    @State private var dragY: CGFloat?
    @State private var viewportHeight: CGFloat = 0
    @StateObject private var railScroll = SessionShareScrollReference()
    private let dragClock = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private var allIDs: Set<SessionShareCell.ID> { Set(cells.map(\.id)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "Cancel")) { dismiss() }
                Spacer()
                Text(String(format: String(localized: "%ld selected"), selection.count)).font(.headline)
                Spacer()
                Button(selection == allIDs ? String(localized: "Deselect All") : String(localized: "Select All")) {
                    selection = selection == allIDs ? [] : allIDs
                }
            }.padding(16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    Button(String(localized: "Select Below")) { changeBelow(lastTapped ?? cells.first?.id, selecting: true) }
                    Button(String(localized: "Deselect All Below")) { changeBelow(lastTapped ?? cells.first?.id, selecting: false) }
                    Button(String(localized: "Clear Selection")) { selection.removeAll() }
                }.font(.subheadline).padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            transcript
            Divider()
            Button {
                options = SessionExportOptionsStore.load()
                previewInput = SessionSharePreviewInput(messages: SessionShareSnapshot.selectedMessages(snapshot, selection: selection))
            } label: {
                Label(String(format: String(localized: "Share (%ld)"), selection.count), systemImage: "square.and.arrow.up")
                    .font(.headline).frame(maxWidth: .infinity).padding(14)
            }
            .buttonStyle(.borderedProminent).disabled(selection.isEmpty).padding(16)
        }
        .background(Color(UIColor.systemBackground))
        .onAppear {
            guard !initialized else { return }
            initialized = true
            snapshot = SessionShareSnapshot.capture(messages)
            cells = SessionShareSnapshot.cells(snapshot)
            // Thinking is selectable individually, but starts excluded unless opted in.
            selection = Set(cells.filter {
                ($0.kind != .thinking || options.includeThinking) && ($0.kind != .tool || options.includeToolCalls)
            }.map(\.id))
        }
        .sheet(item: $previewInput) { input in
            SessionShareRenderedPreview(messages: input.messages, header: header,
                                        adaptiveWidth: adaptiveWidth, vm: vm, options: options)
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(cells) { cell in
                    HStack(spacing: 0) {
                        Image(systemName: selection.contains(cell.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(cell.id) ? Color.accentColor : Color.secondary)
                            .frame(width: 36)
                            .accessibilityHidden(true)
                        SessionExportPickerRow(message: cell.message, vm: vm)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 3)
                    .background(selection.contains(cell.id) ? Color.accentColor.opacity(0.07) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(cell.id) }
                    .contextMenu {
                        Button(String(localized: "Select All Below")) { changeBelow(cell.id, selecting: true) }
                        Button(String(localized: "Deselect All Below")) { changeBelow(cell.id, selecting: false) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection.contains(cell.id) ? [.isButton, .isSelected] : [.isButton])
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: SessionShareFramesKey.self,
                                               value: [cell.id: proxy.frame(in: .named("sharePicker"))])
                    })
                }
            }
            .background(SessionShareScrollProbe(reference: railScroll))
        }
        .coordinateSpace(name: "sharePicker")
        .onPreferenceChange(SessionShareFramesKey.self) { frames in
            rowFrames = frames
            if let dragY { updateDrag(at: dragY) }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { viewportHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { viewportHeight = $0 }
        })
        .onReceive(dragClock) { _ in
            guard dragAnchor != nil, let dragY else { return }
            let edge: CGFloat = 56
            let step: CGFloat
            if dragY < edge {
                step = -min(28, max(0, (edge - dragY) * 0.5))
            } else if dragY > viewportHeight - edge {
                step = min(28, max(0, (dragY - viewportHeight + edge) * 0.5))
            } else { return }
            railScroll.scroll(by: step)
            updateDrag(at: dragY)
        }
        .onDisappear { endDrag() }
        .overlay(alignment: .leading) {
            // Only this narrow rail takes the drag recognizer; the transcript
            // remains a normal scroll view everywhere else.
            Color.clear.frame(width: 36).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("sharePicker"))
                    .onChanged { value in
                        dragY = min(max(0, value.location.y), viewportHeight)
                        updateDrag(at: dragY ?? value.location.y)
                    }
                    .onEnded { _ in endDrag() })
        }
    }

    private func updateDrag(at y: CGFloat) {
        guard let hit = rowFrames.first(where: { $0.value.contains(CGPoint(x: 18, y: y)) })?.key else { return }
        if dragAnchor == nil {
            dragAnchor = hit
            dragInitial = selection
            dragSelecting = !selection.contains(hit)
        }
        guard let anchor = dragAnchor else { return }
        lastTapped = hit
        selection = SessionShareSelection.dragging(from: anchor, to: hit, ordered: cells.map(\.id),
                                                   initial: dragInitial, selecting: dragSelecting)
    }

    private func endDrag() {
        dragAnchor = nil
        dragY = nil
        dragInitial.removeAll()
    }

    private func toggle(_ id: SessionShareCell.ID) {
        lastTapped = id
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func changeBelow(_ id: SessionShareCell.ID?, selecting: Bool) {
        guard let id else { return }
        lastTapped = id
        let range = SessionShareSelection.below(id, ordered: cells.map(\.id))
        if selecting { selection.formUnion(range) } else { selection.subtract(range) }
    }
}

/// A weak reference to the owning SwiftUI scroll view; no global window lookup.
@MainActor
private final class SessionShareScrollReference: ObservableObject {
    weak var scrollView: UIScrollView?
    func scroll(by delta: CGFloat) {
        guard let view = scrollView else { return }
        let minimum = -view.adjustedContentInset.top
        let maximum = max(minimum, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        let y = min(maximum, max(minimum, view.contentOffset.y + delta))
        guard abs(y - view.contentOffset.y) > 0.1 else { return }
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
    }
}

private struct SessionShareScrollProbe: UIViewRepresentable {
    let reference: SessionShareScrollReference
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.reference = reference
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) { view.resolve() }
    final class Probe: UIView {
        weak var reference: SessionShareScrollReference?
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }
        func resolve() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { reference?.scrollView = scroll; return }
                ancestor = view.superview
            }
        }
    }
}

private struct SessionShareFramesKey: PreferenceKey {
    static var defaultValue: [SessionShareCell.ID: CGRect] = [:]
    static func reduce(value: inout [SessionShareCell.ID: CGRect], nextValue: () -> [SessionShareCell.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Each block keeps Ze's native bubble/card styling, without actionable chat controls.
private struct SessionExportPickerRow: View {
    @ObservedObject var message: ChatMessage
    let vm: AIChatViewModel
    var body: some View {
        Group {
            if message.role == .assistant {
                // A picker cell is one block, not an entire assistant turn.
                // Avoid repeating avatar/timing/footer chrome for every tool.
                ForEach(message.blocks) { block in
                    AssistantBlockView(block: block, message: message, isActiveMessage: false,
                                       highlightedBlockId: .constant(nil), detailBlock: .constant(nil))
                        .padding(.horizontal, 12)
                }
            } else {
                ChatMessageRow(message: message, isActiveMessage: false, commandStartTime: nil,
                               onStop: nil, onRetry: nil, onEdit: nil, onDelete: nil, onWithdraw: nil,
                               autoRetryAttempt: 0, autoRetryCountdown: 0, canResume: false, onResume: nil,
                               onCompact: nil, onCopyScreenshot: nil, onReadAloud: nil, onShowCompactSummary: nil,
                               onRevertCompact: nil, onToggleUserMessageExpansion: nil, browserPool: nil, toolSnapshots: [])
            }
        }
        .environmentObject(vm)
    }
}

// MARK: - Cancellable, bounded rendered-preview cache

@MainActor
private final class SessionSharePreviewRenderer: ObservableObject {
    @Published private(set) var payload: SessionExportPayload?
    @Published private(set) var isRendering = false
    @Published private(set) var errorText: String?
    @Published private(set) var imageUnavailable = false
    private var cache: [SessionExportOptions: SessionExportPayload] = [:]
    private var recency: [SessionExportOptions] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var files: Set<URL> = []

    func render(messages: [ChatMessage], header: SessionExportHeader, adaptiveWidth: CGFloat,
                vm: AIChatViewModel, options: SessionExportOptions) {
        task?.cancel()
        let request = UUID()
        generation = request
        errorText = nil
        imageUnavailable = false
        // Do not leave the old theme/format visible or shareable while rendering.
        payload = nil
        if let cached = cache[options] {
            payload = cached
            touch(options)
            isRendering = false
            return
        }
        isRendering = true
        task = Task { @MainActor [weak self] in
            // Coalesce quick option taps before entering UIKit's synchronous pass.
            do { try await Task.sleep(nanoseconds: 160_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            let renderer = SessionExportNativeRenderer(messages: messages, scope: .all,
                                                       options: options, header: options.includeHeader ? header : nil,
                                                       vm: vm, adaptiveWidth: adaptiveWidth)
            let result: SessionExportPayload?
            var writeFailure: String?
            switch options.format {
            case .image:
                let images = renderer.makeImages()
                result = images.isEmpty ? nil : SessionExportPayload(images: images, pdfURL: nil)
            case .pdf:
                if let data = renderer.makePDFData() {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ze-Session-\(UUID().uuidString).pdf")
                    do {
                        try data.write(to: url, options: .atomic)
                        self.files.insert(url)
                        result = SessionExportPayload(images: [], pdfURL: url)
                    } catch {
                        writeFailure = error.localizedDescription
                        result = nil
                    }
                } else { result = nil }
            }
            // The renderer is synchronous. Yield afterwards so a queued option
            // change can invalidate this result before it is published.
            await Task.yield()
            guard !Task.isCancelled, self.generation == request else { return }
            self.isRendering = false
            guard let result else {
                self.errorText = writeFailure ?? renderer.failureReason ?? SessionExportError.renderFailed.localizedDescription
                self.imageUnavailable = options.format == .image
                return
            }
            self.cache[options] = result
            self.touch(options)
            self.trimCache()
            self.payload = result
        }
    }

    private func touch(_ options: SessionExportOptions) {
        recency.removeAll { $0 == options }
        recency.append(options)
    }

    private func trimCache() {
        // Long-image caches can otherwise multiply a large bitmap by every toggle.
        func bytes() -> Int {
            cache.values.reduce(0) { total, entry in
                total + entry.images.reduce(0) { sum, image in
                    sum + (image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
                }
            }
        }
        while recency.count > 1 && (recency.count > 3 || bytes() > 48 * 1024 * 1024) {
            let oldest = recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        // Keep PDF files until dismissal: a system share extension can still be reading one.
    }

    func stop() {
        task?.cancel()
        task = nil
        generation = UUID()
        isRendering = false
    }

    deinit {
        task?.cancel()
        for url in files { try? FileManager.default.removeItem(at: url) }
    }
}

@MainActor
private struct SessionShareRenderedPreview: View {
    let messages: [ChatMessage]
    let header: SessionExportHeader
    let adaptiveWidth: CGFloat
    let vm: AIChatViewModel
    @State var options: SessionExportOptions
    @StateObject private var renderer = SessionSharePreviewRenderer()
    @Environment(\.dismiss) private var dismiss
    @State private var activity: SessionExportPayload?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let payload = renderer.payload {
                        SessionExportPreviewContent(payload: payload)
                    } else if renderer.isRendering {
                        VStack(spacing: 12) { ProgressView(); Text(String(localized: "Preparing preview…")) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 14) {
                            Text(renderer.errorText ?? String(localized: "Nothing to export."))
                            if renderer.imageUnavailable {
                                Button(String(localized: "Use PDF")) { options.format = .pdf }
                            }
                            Button(String(localized: "Retry")) { refresh() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                    }
                }
                Divider()
                controls
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle(options.includeHeader ? header.title : String(localized: "Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Back")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        activity = renderer.payload
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(renderer.payload == nil || renderer.isRendering)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: options) { value in SessionExportOptionsStore.save(value); refresh() }
        .onDisappear { renderer.stop() }
        .sheet(item: $activity) { payload in
            SessionExportActivityView(items: payload.shareItems).ignoresSafeArea()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker(String(localized: "Format"), selection: $options.format) {
                ForEach(SessionExportFormat.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Menu {
                        Picker(String(localized: "Page Width"), selection: $options.width) {
                            ForEach(SessionExportWidth.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Label(options.width.title, systemImage: "rectangle.portrait") }
                    Button { options.adaptiveTables.toggle() } label: {
                        Label(String(localized: "Adaptive Tables"), systemImage: "tablecells")
                            .foregroundStyle(options.adaptiveTables ? Color.accentColor : Color.secondary)
                    }
                    Button { options.theme = options.theme == .light ? .dark : .light } label: {
                        Label(options.theme.title, systemImage: "circle.lefthalf.filled")
                    }
                    Button { options.includeHeader.toggle() } label: {
                        Label(String(localized: "Title"), systemImage: options.includeHeader ? "textformat" : "textformat.size.smaller")
                            .foregroundStyle(options.includeHeader ? Color.accentColor : Color.secondary)
                    }
                }.buttonStyle(.bordered).font(.subheadline)
            }
        }.padding(12)
    }

    private func refresh() {
        // The picker already made the exact block selection. Global legacy
        // switches must not silently discard a thinking/tool cell selected there.
        var renderingOptions = options
        renderingOptions.includeThinking = true
        renderingOptions.includeToolCalls = true
        renderer.render(messages: messages, header: header, adaptiveWidth: adaptiveWidth,
                        vm: vm, options: renderingOptions)
    }
}

enum SessionExportError: LocalizedError {
    case empty, renderFailed
    var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "Nothing to export.")
        case .renderFailed: return String(localized: "Could not render the session.")
        }
    }
}

private struct SessionExportPreviewContent: View {
    let payload: SessionExportPayload
    var body: some View {
        GeometryReader { proxy in
            if let url = payload.pdfURL {
                SessionExportPDFView(url: url)
            } else {
                SessionExportImageZoomView(images: payload.images, identity: payload.id)
            }
        }
    }
}

// MARK: - Pinch and double-tap image preview

private struct SessionExportImageZoomView: UIViewRepresentable {
    let images: [UIImage]
    let identity: UUID

    func makeUIView(context: Context) -> SessionExportZoomScrollView { SessionExportZoomScrollView() }
    func updateUIView(_ view: SessionExportZoomScrollView, context: Context) {
        view.setImages(images, identity: identity)
    }
}

private final class SessionExportZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let canvas = UIView()
    private var identity: UUID?
    private var canvasSize = CGSize.zero
    private var needsFit = true
    private var previousWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .secondarySystemBackground
        addSubview(canvas)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImages(_ images: [UIImage], identity: UUID) {
        guard self.identity != identity else { return }
        self.identity = identity
        setZoomScale(1, animated: false)
        canvas.subviews.forEach { $0.removeFromSuperview() }
        let width = images.map(\.size.width).max() ?? 1
        var y: CGFloat = 0
        for image in images {
            let height = image.size.height * width / max(1, image.size.width)
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFit
            view.frame = CGRect(x: 0, y: y, width: width, height: height)
            canvas.addSubview(view)
            y += height
        }
        canvasSize = CGSize(width: width, height: max(1, y))
        canvas.frame = CGRect(origin: .zero, size: canvasSize)
        contentSize = canvasSize
        needsFit = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, canvasSize.width > 0 else { return }
        if needsFit || previousWidth != bounds.width {
            previousWidth = bounds.width
            minimumZoomScale = min(1, bounds.width / canvasSize.width)
            maximumZoomScale = max(4, minimumZoomScale * 4)
            setZoomScale(minimumZoomScale, animated: false)
            needsFit = false
        }
        let x = max(0, (bounds.width - canvasSize.width * zoomScale) / 2)
        contentInset = UIEdgeInsets(top: 0, left: x, bottom: 0, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { setNeedsLayout() }

    @objc private func zoomTapped(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale * 1.05 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let scale = min(maximumZoomScale, minimumZoomScale * 2.5)
            let point = recognizer.location(in: canvas)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

// Kept for callers that already own a completed payload.
struct SessionExportPreviewSheet: View {
    let payload: SessionExportPayload
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SessionExportPreviewContent(payload: payload)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Done")) { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button { SessionExportActivityPresenter.present(items: payload.shareItems) } label: {
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
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url { uiView.document = PDFDocument(url: url) }
    }
}

struct SessionExportActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum SessionExportActivityPresenter {
    static func present(items: [Any]) {
        guard !items.isEmpty,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first?.rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }
}
