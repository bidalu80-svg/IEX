import SwiftUI
import UIKit

struct ChatSearchOverlay: View {
    @ObservedObject var model: ChatSearchModel
    var onClose: () -> Void
    var allowsInitialFocus = true
    var focusHeader: ChatSearchFocusHeader? = nil
    var isCurrentFocusRequest: (Int) -> Bool = { _ in true }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var focus = ChatSearchFieldFocus()
    @State private var isOpaque = false
    @State private var entranceFinished = false

    private var hasQuery: Bool { !model.normalizedQuery.isEmpty }
    private var hasResults: Bool { !model.hits.isEmpty }
    private var usesTwoRows: Bool { dynamicTypeSize.isAccessibilitySize || (width > 0 && width < 360) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                searchField
                if !usesTwoRows { resultControls }
            }
            if usesTwoRows {
                HStack(spacing: 4) {
                    if hasQuery { counter }
                    Spacer(minLength: 0)
                    resultControls
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(ChatColors.background)
        .background(ChatSearchFocusAnchor { focus.row = $0 })
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
        .overlay(alignment: .bottom) { noticeView.offset(y: 34) }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .opacity(isOpaque ? 1 : 0)
        .allowsHitTesting(entranceFinished)
        .onAppear(perform: showRow)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatSearchBar")
        .accessibilityHidden(!entranceFinished)
        .accessibilityAction(.escape) { close() }
    }

    private func showRow() {
        guard !isOpaque else { return }
        if #available(iOS 17, *), focusHeader != nil, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.15), completionCriteria: .removed) {
                isOpaque = true
            } completion: {
                entranceFinished = true
            }
        } else {
            isOpaque = true
            entranceFinished = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatColors.secondaryText)
                .accessibilityHidden(true)
            ChatSearchQueryField(query: $model.query, focus: focus, focusRequest: model.focusRequest,
                                 allowsFocus: allowsInitialFocus && entranceFinished && width > 0 && scenePhase == .active,
                                 focusHeader: focusHeader, isCurrentFocusRequest: isCurrentFocusRequest, onNext: { model.step(1) },
                                 onPrevious: { model.step(-1) }, onClose: close)
                .frame(maxWidth: .infinity, minHeight: 44)
            if hasQuery {
                if !usesTwoRows { counter }
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(ChatColors.tertiaryText)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear"))
                .accessibilityIdentifier("chatSearchClear")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultControls: some View {
        HStack(spacing: 4) {
            navButton(systemName: "chevron.up", label: String(localized: "Previous Result")) { model.step(-1) }
                .accessibilityIdentifier("chatSearchPrevious")
            navButton(systemName: "chevron.down", label: String(localized: "Next Result")) { model.step(1) }
                .accessibilityIdentifier("chatSearchNext")
            ChatSearchDoneButton(focus: focus, onClose: close)
                .background {
                    Button(action: close) { Color.clear.frame(width: 0, height: 0) }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func close() {
        focus.pendingRequest = nil
        focus.field?.resignFirstResponder()
        onClose()
    }

    @ViewBuilder
    private var counter: some View {
        if model.isSearching && !hasResults {
            ProgressView().controlSize(.small)
        } else if hasResults {
            Text(verbatim: ChatSearchNavigation.counterText(index: model.currentIndex, count: model.hits.count,
                                                            truncated: model.isTruncated))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .accessibilityLabel("结果 \(model.currentIndex + 1)，共 \(model.hits.count) 个")
                .accessibilityIdentifier("chatSearchCounter")
        } else {
            Text(String(localized: "No results"))
                .font(.footnote)
                .foregroundStyle(ChatColors.secondaryText)
                .lineLimit(1)
                .accessibilityIdentifier("chatSearchCounter")
        }
    }

    private func navButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasResults ? Color.accentColor : ChatColors.tertiaryText)
        .disabled(!hasResults)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75), in: Capsule())
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@MainActor final class ChatSearchFocusHeader {
    weak var bar: UIView?
    weak var badge: UIView?

    func bottom(in window: UIWindow) -> CGFloat? {
        guard let bar, bar.window === window, !bar.bounds.isEmpty else { return nil }
        let barBottom = Self.presentedFrame(of: bar, in: window).maxY
        guard let badge, badge.window === window, !badge.isHidden else { return barBottom }
        return max(barBottom, Self.presentedFrame(of: badge, in: window).maxY)
    }

    static func presentedFrame(of view: UIView, in window: UIWindow) -> CGRect {
        if let layer = view.layer.presentation(), let windowLayer = window.layer.presentation() {
            return layer.convert(layer.bounds, to: windowLayer)
        }
        return view.convert(view.bounds, to: window)
    }
}

@MainActor private final class ChatSearchFieldFocus {
    weak var field: UITextField?
    weak var row: UIView?
    weak var done: UIButton?
    var pendingRequest: Int?
    private var consumedRequest: Int?

    func enqueue(_ request: Int) {
        if request != consumedRequest { pendingRequest = request }
    }

    func consume(_ request: Int, field: UITextField) {
        guard pendingRequest == request, field.isFirstResponder else { return }
        consumedRequest = request
        pendingRequest = nil
    }

    func readyFrame(for field: UITextField, in window: UIWindow, header: ChatSearchFocusHeader?) -> CGRect? {
        guard let row, let done, done.isEnabled, row.window === window, done.window === window,
              field.window === window else { return nil }
        let frame = ChatSearchFocusHeader.presentedFrame(of: row, in: window)
        let fieldFrame = ChatSearchFocusHeader.presentedFrame(of: field, in: window)
        let doneFrame = ChatSearchFocusHeader.presentedFrame(of: done, in: window)
        let tolerance = 1 / max(window.traitCollection.displayScale, 1)
        let rowBounds = frame.insetBy(dx: -tolerance, dy: -tolerance)
        guard !frame.isEmpty, !fieldFrame.isEmpty, !doneFrame.isEmpty,
              rowBounds.contains(fieldFrame), rowBounds.contains(doneFrame),
              window.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(frame) else { return nil }
        if let header {
            guard let bottom = header.bottom(in: window), frame.minY + tolerance >= bottom else { return nil }
        }
        if window.keyboardLayoutGuide.layoutFrame.intersects(frame) { return nil }
        var ancestor: UIView? = row
        while let view = ancestor {
            let opacity = view.layer.presentation()?.opacity ?? view.layer.opacity
            guard !view.isHidden, opacity >= 0.99 else { return nil }
            if view.clipsToBounds, !ChatSearchFocusHeader.presentedFrame(of: view, in: window)
                .insetBy(dx: -tolerance, dy: -tolerance).contains(frame) { return nil }
            ancestor = view.superview
        }
        let fieldCenter = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        let doneCenter = CGPoint(x: doneFrame.midX, y: doneFrame.midY)
        guard let fieldHit = window.hitTest(fieldCenter, with: nil), fieldHit.isDescendant(of: field),
              window.hitTest(doneCenter, with: nil) === done else { return nil }
        return frame
    }
}

private struct ChatSearchFocusAnchor: UIViewRepresentable {
    let register: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { register(view) }
}

private struct ChatSearchDoneButton: UIViewRepresentable {
    let focus: ChatSearchFieldFocus
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(String(localized: "Done"), for: .normal)
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.tintColor = UIColor(Color.accentColor)
        button.accessibilityIdentifier = "chatSearchDone"
        button.addTarget(context.coordinator, action: #selector(Coordinator.close), for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        focus.done = button
        context.coordinator.onClose = onClose
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: max(44, size.width), height: max(44, size.height))
    }

    @MainActor final class Coordinator: NSObject {
        var onClose: (() -> Void)?
        @objc func close() { onClose?() }
    }
}

private struct ChatSearchQueryField: UIViewRepresentable {
    @Binding var query: String
    let focus: ChatSearchFieldFocus
    let focusRequest: Int
    let allowsFocus: Bool
    let focusHeader: ChatSearchFocusHeader?
    let isCurrentFocusRequest: (Int) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = String(localized: "Search this chat")
        field.font = .preferredFont(forTextStyle: .subheadline)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.accessibilityIdentifier = "chatSearchField"
        field.accessibilityLabel = field.placeholder
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.onWindowChange = { [weak coordinator = context.coordinator] field in
            coordinator?.updateFocus(in: field)
            #if DEBUG
            ChatSearchFocusTrace.shared.fieldMoved(field, id: field.traceID)
            #endif
        }
        field.onLayout = { [weak coordinator = context.coordinator] in coordinator?.scheduleFocusCheck() }
        focus.field = field
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onPrevious = onPrevious
        field.onClose = onClose
        if context.coordinator.lastQuery != query, field.markedTextRange == nil {
            context.coordinator.lastQuery = query
            if field.text != query { field.text = query }
        }
        context.coordinator.updateFocus(in: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: max(44, uiView.intrinsicContentSize.height))
    }

    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        coordinator.stopFocusChecks()
        field.onWindowChange = nil
        field.onLayout = nil
        field.resignFirstResponder()
        #if DEBUG
        ChatSearchFocusTrace.shared.fieldRemoved(field, id: field.traceID)
        #endif
        if coordinator.parent.focus.field === field { coordinator.parent.focus.field = nil }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChatSearchQueryField
        var lastQuery: String?
        private weak var field: Field?
        private var retryTimer: Timer?
        private var checkScheduled = false
        #if DEBUG
        private var readyRequest: Int?
        #endif

        init(_ parent: ChatSearchQueryField) { self.parent = parent }

        func updateFocus(in field: Field) {
            self.field = field
            parent.focus.enqueue(parent.focusRequest)
            if parent.focus.pendingRequest != nil, parent.allowsFocus, field.window != nil {
                scheduleFocusCheck()
            } else {
                stopFocusChecks()
            }
        }

        func scheduleFocusCheck() {
            guard !checkScheduled, parent.focus.pendingRequest != nil, parent.allowsFocus,
                  field?.window != nil else { return }
            checkScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.checkScheduled = false
                self.checkFocus()
            }
        }

        func stopFocusChecks() {
            retryTimer?.invalidate()
            retryTimer = nil
        }

        @objc private func retryFocus(_ timer: Timer) { checkFocus() }

        private func checkFocus() {
            guard let field, let request = parent.focus.pendingRequest,
                  parent.allowsFocus, field.window != nil, request == parent.focusRequest,
                  parent.focus.field === field, parent.isCurrentFocusRequest(request) else {
                stopFocusChecks()
                return
            }
            if retryTimer == nil {
                let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(retryFocus(_:)), userInfo: nil, repeats: true)
                timer.tolerance = 0.05
                RunLoop.main.add(timer, forMode: .common)
                retryTimer = timer
            }
            guard readyFrame(in: field) != nil else { return }
            #if DEBUG
            guard !ChatSearchFocusTrace.shared.holdFocus else { return }
            #endif
            if !field.isFirstResponder { _ = field.becomeFirstResponder() }
            if field.isFirstResponder {
                parent.focus.consume(request, field: field)
                stopFocusChecks()
            }
        }

        private func readyFrame(in field: Field) -> CGRect? {
            let request = parent.focusRequest
            guard parent.allowsFocus, let window = field.window, window.isKeyWindow,
                  parent.focus.field === field, parent.isCurrentFocusRequest(request),
                  window.windowScene?.activationState == .foregroundActive,
                  let frame = parent.focus.readyFrame(for: field, in: window, header: parent.focusHeader) else { return nil }
            #if DEBUG
            if readyRequest != request {
                readyRequest = request
                ChatSearchFocusTrace.shared.rowReady(field, id: field.traceID, request: request, frame: frame)
            }
            #endif
            return frame
        }

        func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
            guard let field = textField as? Field, readyFrame(in: field) != nil else { return false }
            #if DEBUG
            if ChatSearchFocusTrace.shared.holdFocus { return false }
            #endif
            return true
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.focus.consume(parent.focusRequest, field: textField)
            stopFocusChecks()
            #if DEBUG
            if let field = textField as? Field { ChatSearchFocusTrace.shared.focusBegan(field, id: field.traceID) }
            #endif
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            #if DEBUG
            if let field = textField as? Field { ChatSearchFocusTrace.shared.focusEnded(field, id: field.traceID) }
            #endif
        }

        @objc func textChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let text = field.text ?? ""
            lastQuery = text
            if parent.query != text { parent.query = text }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard textField.markedTextRange == nil else { return false }
            let queryChanged = textField.text != parent.query
            if queryChanged {
                textChanged(textField)
            } else {
                #if DEBUG
                if let field = textField as? Field { ChatSearchFocusTrace.shared.submitted(field, id: field.traceID) }
                #endif
                parent.onNext()
            }
            return false
        }
    }

    final class Field: UITextField {
        var onWindowChange: ((Field) -> Void)?
        var onLayout: (() -> Void)?
        var onPrevious: (() -> Void)?
        var onClose: (() -> Void)?
        #if DEBUG
        let traceID = UUID()
        #endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(self)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }

        override var keyCommands: [UIKeyCommand]? {
            let previous = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(previousResult))
            let close = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeSearch))
            previous.wantsPriorityOverSystemBehavior = markedTextRange == nil
            close.wantsPriorityOverSystemBehavior = true
            return (super.keyCommands ?? []) + [previous, close]
        }

        @objc private func previousResult() {
            if markedTextRange == nil { onPrevious?() }
        }

        @objc private func closeSearch() { onClose?() }
    }
}
