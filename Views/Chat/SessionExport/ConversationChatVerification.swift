#if DEBUG
import UIKit

/// Exercises the shipping ContentView navigation and complete AIChatView. In
/// particular, materializes the real inputBar/inputBottomRow generic metadata
/// which component-only share/search fixtures never instantiate.
@MainActor enum ConversationChatVerification {
    private static var checks: [String] = []
    private static var stages: [String] = []
    private static var screenshots: [String] = []
    private static var currentStage = "startup"
    private static var inputDiagnostics: [[String: Any]] = []
    private static var voiceLayoutDiagnostics: [[String: Any]] = []
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("chat-verification")

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "ConversationChatVerification", code: checks.count + 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        checks.append(message)
    }

    private static func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitFor(_ description: String, timeout: Double = 10, condition: () -> Bool) async throws {
        for _ in 0..<Int(timeout * 10) {
            if condition() { return }
            await settle(0.1)
        }
        try require(false, "Timed out: \(description)")
    }

    private static func checkpoint(_ stage: String) throws {
        currentStage = stage
        stages.append(stage)
        let progress: [String: Any] = ["stage": stage, "stages": stages, "checks": checks,
                                       "timestamp": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: progress, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("progress.json"), options: .atomic)
        print("[ConversationChatVerification] \(stage)")
    }

    private static func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.window === window, !view.bounds.isEmpty else { return false }
        var ancestor: UIView? = view
        while let item = ancestor {
            if item.isHidden || item.alpha < 0.01 { return false }
            ancestor = item.superview
        }
        return window.bounds.intersects(view.convert(view.bounds, to: window))
    }

    private static func composer(in window: UIWindow) -> PastableUITextView? {
        let inputs = descendants(window).compactMap { $0 as? PastableUITextView }
            .filter { $0.isEditable && isVisible($0, in: window) }
        return inputs.first { $0.isFirstResponder } ?? inputs.first
    }

    private static func recordInput(_ phase: String, input: PastableUITextView?,
                                    window: UIWindow, vm: AIChatViewModel?) {
        let coordinator = input?.delegate as? PastableTextView.Coordinator
        let entry: [String: Any] = [
            "stage": currentStage, "phase": phase,
            "input": input.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "delegate": coordinator.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "vm": vm.map { String(describing: ObjectIdentifier($0)) } ?? "not-supplied",
            "currentComposer": composer(in: window).map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "firstResponder": input?.isFirstResponder ?? false,
            "syncingFocus": coordinator?.isSyncingFocus ?? false,
            "bindingFocused": coordinator?.parent.isFocused ?? false,
            "uiText": input?.text ?? "nil",
            "bindingText": coordinator?.parent.text ?? "nil",
            "vmText": vm?.inputText ?? "not-supplied"
        ]
        inputDiagnostics.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: inputDiagnostics, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("input-diagnostics.json"), options: .atomic)
        }
        print("[ConversationChatVerification] input \(entry)")
    }

    /// A first responder can still be inside SwiftUI's asynchronous focus sync.
    /// Resolve the visible UIKit instance after navigation/screenshots and wait
    /// for its existing delegate binding to settle before sending ONE real edit.
    private static func typeIntoReadyComposer(_ text: String, in window: UIWindow,
                                              vm: AIChatViewModel? = nil) async throws -> PastableUITextView {
        var readyInput: PastableUITextView?
        var readyText: String?
        var stableSamples = 0
        recordInput("await-ready", input: composer(in: window), window: window, vm: vm)
        do {
            try await waitFor("current composer and production binding ready") {
                guard let input = composer(in: window), input.isFirstResponder,
                      let coordinator = input.delegate as? PastableTextView.Coordinator,
                      !coordinator.isSyncingFocus, coordinator.parent.isFocused,
                      input.markedTextRange == nil, input.selectedTextRange != nil,
                      input.text == coordinator.parent.text,
                      vm == nil || coordinator.parent.text == vm?.inputText else {
                    readyInput = nil
                    readyText = nil
                    stableSamples = 0
                    return false
                }
                stableSamples = readyInput === input && readyText == input.text ? stableSamples + 1 : 1
                readyInput = input
                readyText = input.text
                return stableSamples >= 3
            }
            guard let input = readyInput, composer(in: window) === input else {
                throw NSError(domain: "ConversationChatVerification", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "Ready composer replaced before typing"])
            }
            recordInput("before-insert", input: input, window: window, vm: vm)
            input.insertText(text)
            recordInput("after-insert", input: input, window: window, vm: vm)
            try await waitFor("real UIKit edit reaches current production binding") {
                guard composer(in: window) === input,
                      let coordinator = input.delegate as? PastableTextView.Coordinator else { return false }
                return input.text.contains(text) && coordinator.parent.text == input.text
                    && (vm == nil || vm?.inputText == input.text)
            }
            // Also detect a deferred updateUIView overwriting the actual edit.
            await settle(0.3)
            recordInput("after-binding-settled", input: input, window: window, vm: vm)
            let coordinator = input.delegate as? PastableTextView.Coordinator
            try require(composer(in: window) === input && input.text.contains(text)
                        && coordinator?.parent.text == input.text
                        && (vm == nil || vm?.inputText == input.text),
                        "Actual composer edit survives production binding synchronization")
            return input
        } catch {
            recordInput("input-failure", input: readyInput ?? composer(in: window), window: window, vm: vm)
            throw error
        }
    }

    private static func renderedHistory(_ marker: String, in window: UIWindow) -> Bool {
        // Require a real transcript collection and a visible rendered text view
        // inside it. A sidebar title, VM-only fixture or hidden retained page
        // cannot satisfy this assertion.
        let collections = descendants(window).compactMap { $0 as? UICollectionView }
            .filter { isVisible($0, in: window) }
        return collections.contains { collection in
            descendants(collection).contains { view in
                guard !(view is PastableUITextView), isVisible(view, in: window) else { return false }
                if let text = view as? UITextView { return text.text?.contains(marker) == true }
                if let label = view as? UILabel { return label.text?.contains(marker) == true }
                return false
            }
        }
    }

    private static func capture(_ name: String, window: UIWindow) throws {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else {
            throw NSError(domain: "ConversationChatVerification", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Screenshot encoding failed"])
        }
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        screenshots.append(name)
    }

    private static func marker(_ identifier: String, in window: UIWindow) -> UIView? {
        descendants(window).first { $0.accessibilityIdentifier == identifier && isVisible($0, in: window) }
    }

    private static func rectData(_ rect: CGRect) -> [String: CGFloat] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
         "midX": rect.midX, "maxY": rect.maxY]
    }

    /// Preserve both UIKit conversion and presentation geometry. SwiftUI may
    /// update ancestor transforms during a transition, so even `layout` here is
    /// not guaranteed to be the final target. Assert geometry only after the
    /// visible presentation has settled.
    private static func markerData(_ view: UIView, window: UIWindow) -> [String: Any] {
        let layout = view.convert(view.bounds, to: window)
        let presentation = view.layer.presentation()
        let rendered = presentation?.convert(presentation?.bounds ?? view.bounds,
                                              to: window.layer.presentation() ?? window.layer) ?? layout
        var opacity: Float = 1
        var layer: CALayer? = presentation ?? view.layer
        while let current = layer {
            opacity *= current.opacity
            layer = current.superlayer
        }
        return ["layout": rectData(layout), "presentation": rectData(rendered), "opacity": opacity]
    }

    @MainActor private final class VoiceTransitionSampler: NSObject {
        weak var window: UIWindow?
        var frames: [[String: Any]] = []
        private var link: CADisplayLink?
        private let began = CACurrentMediaTime()

        init(window: UIWindow) {
            self.window = window
            super.init()
        }

        func start() {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick))
            link = displayLink
            displayLink.add(to: .main, forMode: .common)
            sample()
        }

        func stop() {
            guard link != nil else { return }
            link?.invalidate()
            link = nil
            sample()
        }

        @objc private func tick() { sample() }

        private func sample() {
            guard let window else { return }
            var entry: [String: Any] = ["elapsed": CACurrentMediaTime() - began]
            let views = ConversationChatVerification.descendants(window)
            for key in ["title", "voicePanel", "providerBadge"] {
                if let view = views.first(where: {
                    $0.accessibilityIdentifier == "chat.verify.\(key)"
                        && ConversationChatVerification.isVisible($0, in: window)
                }) {
                    entry[key] = ConversationChatVerification.markerData(view, window: window)
                }
            }
            frames.append(entry)
        }
    }

    private static func writeVoiceLayoutDiagnostics() throws {
        try JSONSerialization.data(withJSONObject: voiceLayoutDiagnostics, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("voice-layout-diagnostics.json"), options: .atomic)
    }

    private static func voiceLayoutAction(_ action: String, sessionID: String) {
        NotificationCenter.default.post(name: Notification.Name("ZeChatVoiceLayoutVerification"), object: nil,
                                        userInfo: ["sessionId": sessionID, "action": action])
    }

    private static func waitForVoicePresentation(_ action: String, window: UIWindow) async throws {
        var previous: [String: CGFloat]?
        var stableSamples = 0
        var samples: [[String: Any]] = []
        defer {
            voiceLayoutDiagnostics.append(["phase": "\(action)-await-settled", "samples": samples])
            try? writeVoiceLayoutDiagnostics()
        }
        // Keep waitFor's existing 10s bound and 0.1s sampling. This waits for
        // rendered state, rather than assuming async coordinator startup and
        // the ensuing spring both fit into one second after notification.
        try await waitFor("\(action): production voice presentation settled") {
            if action == "stop" {
                let absent = !descendants(window).contains { $0.accessibilityIdentifier == "chat.verify.voicePanel" }
                samples.append(["panelAbsent": absent])
                stableSamples = absent ? stableSamples + 1 : 0
                return stableSamples >= 3
            }
            guard let panel = marker("chat.verify.voicePanel", in: window) else {
                previous = nil
                stableSamples = 0
                samples.append(["panelPresent": false])
                return false
            }
            let data = markerData(panel, window: window)
            samples.append(data)
            guard let opacity = data["opacity"] as? Float, opacity >= 0.99,
                  let rect = data["presentation"] as? [String: CGFloat] else {
                previous = nil
                stableSamples = 0
                return false
            }
            let unchanged = previous.map { old in
                ["x", "y", "width", "height"].allSatisfy { key in
                    guard let before = old[key], let now = rect[key] else { return false }
                    return abs(before - now) <= 0.1
                }
            } ?? false
            stableSamples = unchanged ? stableSamples + 1 : 1
            previous = rect
            return stableSamples >= 3
        }
        try require(stableSamples >= 3, "\(action): presentation settled for three consecutive 0.1s samples")
    }

    /// Retain screenshots in memory while sampling so PNG encoding/file IO do
    /// not occupy the transition itself. Actual elapsed times are recorded: this
    /// is animation evidence, not an FPS/performance benchmark.
    private static func sampleVoiceTransition(_ action: String, sessionID: String,
                                              window: UIWindow) async throws {
        let requested = CACurrentMediaTime()
        voiceLayoutAction(action, sessionID: sessionID)
        if action == "start" {
            try await waitFor("production voice panel first appears") {
                guard let panel = marker("chat.verify.voicePanel", in: window),
                      let opacity = markerData(panel, window: window)["opacity"] as? Float else { return false }
                return opacity > 0.01
            }
        }
        let began = CACurrentMediaTime()
        let sampler = VoiceTransitionSampler(window: window)
        sampler.start()
        defer { sampler.stop() }
        var images: [(String, UIImage)] = []
        var captureTimes: [[String: Any]] = []
        for (index, targetTime) in [0.06, 0.16, 0.30, 0.55].enumerated() {
            let remaining = targetTime - (CACurrentMediaTime() - began)
            if remaining > 0 { await settle(remaining) }
            let name = "07-voice-\(action)-transition-\(index + 1).png"
            let actualTime = CACurrentMediaTime() - began
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            images.append((name, image))
            captureTimes.append(["file": name, "requestedElapsed": targetTime, "actualElapsed": actualTime])
        }
        var settleError: Error?
        do { try await waitForVoicePresentation(action, window: window) }
        catch { settleError = error }
        sampler.stop()
        voiceLayoutDiagnostics.append(["phase": action, "displayFrames": sampler.frames,
                                       "captures": captureTimes,
                                       "captureOriginDelayAfterAction": began - requested,
                                       "captureOrigin": action == "start" ? "first visible production panel" : "action dispatched",
                                       "scope": "Real AIChatView and navigation; injected audio; capture overhead included"])
        try writeVoiceLayoutDiagnostics()
        for (name, image) in images {
            guard let data = image.pngData() else {
                throw NSError(domain: "ConversationChatVerification", code: -7,
                              userInfo: [NSLocalizedDescriptionKey: "Voice transition PNG encoding failed"])
            }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            screenshots.append(name)
        }
        if let settleError { throw settleError }
        try require(sampler.frames.count >= 3, "\(action): actual display-link transition samples recorded")
        let titleCenters = sampler.frames.compactMap { frame -> CGFloat? in
            guard let title = frame["title"] as? [String: Any],
                  let presentation = title["presentation"] as? [String: CGFloat] else { return nil }
            return presentation["midX"]
        }
        try require(titleCenters.count >= 3 && titleCenters.allSatisfy { abs($0 - window.bounds.midX) <= 2 },
                    "\(action): long title remains centered throughout sampled transition")
    }

    @discardableResult
    private static func verifyVoiceLayout(_ phase: String, panelExpected: Bool,
                                          window: UIWindow) throws -> CGRect? {
        guard let title = marker("chat.verify.title", in: window),
              let navbar = descendants(window).compactMap({ $0 as? UINavigationBar })
                .first(where: { isVisible($0, in: window) }) else {
            throw NSError(domain: "ConversationChatVerification", code: -8,
                          userInfo: [NSLocalizedDescriptionKey: "\(phase): real navigation/title marker missing"])
        }
        let titleFrame = title.convert(title.bounds, to: window)
        let navFrame = navbar.convert(navbar.bounds, to: window)
        var evidence: [String: Any] = ["phase": phase, "title": rectData(titleFrame),
                                      "navbar": rectData(navFrame), "window": rectData(window.bounds)]
        let panel = marker("chat.verify.voicePanel", in: window)
        let panelFrame = panel.map { $0.convert($0.bounds, to: window) }
        if let panelFrame { evidence["panel"] = rectData(panelFrame) }
        let badge = marker("chat.verify.providerBadge", in: window)
        let badgeFrame = badge.map { $0.convert($0.bounds, to: window) }
        if let badgeFrame { evidence["badge"] = rectData(badgeFrame) }
        voiceLayoutDiagnostics.append(evidence)
        try writeVoiceLayoutDiagnostics()
        try require(abs(titleFrame.midX - window.bounds.midX) <= 2,
                    "\(phase): long history principal remains within 2pt of screen center")
        try require(panelExpected == (panel != nil), "\(phase): production voice panel presence matches state")
        guard panelExpected, let panelFrame else { return nil }
        try require(panelFrame.minY >= navFrame.maxY + 28 - 0.5,
                    "\(phase): voice panel starts at least 28pt below navigation bar")
        guard let badgeFrame else {
            throw NSError(domain: "ConversationChatVerification", code: -9,
                          userInfo: [NSLocalizedDescriptionKey: "\(phase): actual provider badge marker missing"])
        }
        try require(panelFrame.minY >= badgeFrame.maxY + 2 - 0.5,
                    "\(phase): voice panel clears provider badge by at least 2pt")
        try require(window.bounds.contains(panelFrame), "\(phase): whole voice panel stays inside visible window")
        guard let target = DebugViewInspector().findTarget(identifier: "voiceCall.hangUp") else {
            throw NSError(domain: "ConversationChatVerification", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "\(phase): actual hang-up accessibility control missing"])
        }
        let hangupFrame: CGRect
        switch target {
        case .view(let view):
            try require(isVisible(view, in: window), "\(phase): actual hang-up UIView is visible")
            hangupFrame = view.convert(view.bounds, to: window)
        case .element(_, let frame):
            hangupFrame = window.convert(frame, from: nil)
        }
        voiceLayoutDiagnostics.append(["phase": "\(phase)-hangup", "frame": rectData(hangupFrame)])
        try writeVoiceLayoutDiagnostics()
        try require(hangupFrame.width >= 40 && hangupFrame.height >= 40,
                    "\(phase): actual hang-up control has a usable visible frame")
        try require(panelFrame.insetBy(dx: -1, dy: -1).contains(hangupFrame)
                    && window.bounds.contains(hangupFrame), "\(phase): hang-up fits inside visible panel")
        return panelFrame
    }

    private static func verifyVoiceCallInHistory(sessionID: String, window: UIWindow) async throws {
        try checkpoint("voice-call-real-history-layout")
        window.endEditing(true)
        await settle(0.7)
        defer { voiceLayoutAction("stop", sessionID: sessionID) }
        try capture("07-voice-before.png", window: window)
        try verifyVoiceLayout("before", panelExpected: false, window: window)
        try await sampleVoiceTransition("start", sessionID: sessionID, window: window)
        try capture("07-voice-started.png", window: window)
        let compact = try verifyVoiceLayout("started", panelExpected: true, window: window)
        try await sampleVoiceTransition("expand", sessionID: sessionID, window: window)
        try capture("07-voice-expanded.png", window: window)
        let expanded = try verifyVoiceLayout("expanded", panelExpected: true, window: window)
        try require((expanded?.height ?? 0) > (compact?.height ?? 0) + 20,
                    "Expanded production voice panel is taller than compact panel")
        try await sampleVoiceTransition("collapse", sessionID: sessionID, window: window)
        try capture("07-voice-collapsed.png", window: window)
        let collapsed = try verifyVoiceLayout("collapsed", panelExpected: true, window: window)
        try require(abs((collapsed?.height ?? 0) - (compact?.height ?? 0)) <= 2,
                    "Collapsed production voice panel returns to compact height")
        try await sampleVoiceTransition("stop", sessionID: sessionID, window: window)
        try capture("07-voice-stopped.png", window: window)
        try verifyVoiceLayout("stopped", panelExpected: false, window: window)
    }

    static func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var appWindow: UIWindow?
        do {
            try checkpoint("await-production-content-view")
            try await waitFor("ContentView readiness") {
                UserDefaults.standard.bool(forKey: "ZeChatLifecycleReady")
            }
            try await waitFor("production key window") {
                appWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows).first { $0.isKeyWindow && $0.rootViewController != nil }
                return appWindow != nil
            }
            guard let window = appWindow, let originalRoot = window.rootViewController else {
                throw NSError(domain: "ConversationChatVerification", code: -2)
            }
            await settle(1.5)
            try checkpoint("persist-history-fixture")
            let historyMarker = "CHAT-LIFECYCLE-HISTORY-\(UUID().uuidString.prefix(8))"
            let session = await ChatStore.shared.createSession(modelId: LLMModel.claudeHaiku45.id,
                                                               title: "这是用于验证语音通话入口不会挤偏居中标题的长中文历史会话")
            await ChatStore.shared.appendMessages([
                RawMessage(id: UUID().uuidString, sessionId: session.id, role: .user,
                           parts: [.text("请检查历史对话可以重新打开。")], createdAt: Date(),
                           tokenUsage: nil, reasoningContent: nil),
                RawMessage(id: UUID().uuidString, sessionId: session.id, role: .assistant,
                           parts: [.text("**历史记录验证**\n\n\(historyMarker)\n\n真实聊天页面与输入栏已加载。")],
                           createdAt: Date().addingTimeInterval(0.1), tokenUsage: nil, reasoningContent: nil)
            ])

            try checkpoint("open-first-new-chat")
            NotificationCenter.default.post(name: .newChatRequested, object: nil)
            try await waitFor("new chat actual composer") { composer(in: window) != nil }
            try checkpoint("await-real-kernel-boot")
            try await waitFor("real bundled rootfs installation and kernel boot", timeout: 90) {
                ISHKernel.shared.isBooted
            }
            await settle(0.7)
            try require(ISHKernel.shared.isBooted, "Real bundled rootfs boots before chat interaction")
            try require(window.rootViewController === originalRoot, "New chat preserves production root")
            try require(!renderedHistory(historyMarker, in: window), "New chat has no history fixture")
            try capture("01-new-chat.png", window: window)

            try checkpoint("type-in-first-new-chat")
            let firstComposer = try await typeIntoReadyComposer("新对话输入验证", in: window)
            try require(firstComposer.isFirstResponder, "Actual new-chat composer accepts automatic focus")
            try require(firstComposer.text.contains("新对话输入验证"), "Actual new-chat composer accepts typed text")
            try capture("02-new-chat-typing.png", window: window)
            firstComposer.resignFirstResponder()

            try checkpoint("open-persisted-history")
            NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                            userInfo: ["sessionId": session.id])
            try await waitFor("persisted history and full composer") {
                composer(in: window) != nil && renderedHistory(historyMarker, in: window)
            }
            await settle(0.5)
            try require(ISHKernel.shared.isBooted, "Historical chat retains the running kernel")
            try require(window.rootViewController === originalRoot, "History preserves production root")
            guard let historyVM = ViewModelCache.shared.get(for: session.id) else {
                throw NSError(domain: "ConversationChatVerification", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "History VM or actual composer missing"])
            }
            try await waitFor("history kernel overlay dismissal") {
                if case .booted = historyVM.kernelStatus { return true }
                return false
            }
            try require(historyVM.sessionId == session.id, "Visible history uses persisted session VM")
            try require(historyVM.messages.count >= 2, "History messages hydrate from ChatStore")
            try capture("03-persisted-history.png", window: window)
            try checkpoint("type-in-history")
            // Use the shipping focus-intent signal. PastableUITextView deliberately
            // rejects unsolicited UIKit first-responder promotion until an actual
            // tap or SwiftUI focus request opens its allowsFirstResponder gate.
            historyVM.requestComposerFocusSignal.send()
            let historyComposer = try await typeIntoReadyComposer("历史输入绑定验证", in: window, vm: historyVM)
            try require(historyComposer.isFirstResponder, "Historical composer accepts production focus intent")
            try require(historyVM.inputText.contains("历史输入绑定验证"), "History input reaches production VM binding")
            historyComposer.resignFirstResponder()

            try checkpoint("open-second-new-chat")
            NotificationCenter.default.post(name: .newChatRequested, object: nil)
            try await waitFor("fresh second new-chat composer") {
                guard let input = composer(in: window) else { return false }
                return input !== historyComposer && input.text.isEmpty && !renderedHistory(historyMarker, in: window)
            }
            await settle(0.5)
            try require(composer(in: window)?.text.isEmpty == true, "Second new chat owns a fresh empty composer")
            try capture("04-second-new-chat.png", window: window)

            for iteration in 1...3 {
                try checkpoint("return-home-\(iteration)")
                window.endEditing(true)
                NotificationCenter.default.post(name: Notification.Name("ZeChatLifecycleReturnHome"), object: nil)
                try await waitFor("home without visible chat composer") { composer(in: window) == nil }
                await settle(0.4)
                try require(composer(in: window) == nil, "Home \(iteration) removes full chat screen")
                try capture("05-home-\(iteration).png", window: window)

                try checkpoint("reopen-history-\(iteration)")
                NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                                userInfo: ["sessionId": session.id])
                try await waitFor("reopened actual persisted history \(iteration)") {
                    composer(in: window) != nil && renderedHistory(historyMarker, in: window)
                }
                await settle(0.4)
                try require(window.rootViewController === originalRoot, "Reopen \(iteration) preserves production root")
                try require(composer(in: window)?.text.contains("历史输入绑定验证") == true,
                            "Reopen \(iteration) restores actual cached history composer draft")
                try capture("06-reopened-history-\(iteration).png", window: window)
            }
            try await verifyVoiceCallInHistory(sessionID: session.id, window: window)
            try checkpoint("voice-call-draft-and-cancellation")
            checks += try await VoiceCallVerification.runChecks()
            try checkpoint("complete")
            try writeResult(success: true, error: nil)
        } catch {
            if let window = appWindow { try? capture("failure.png", window: window) }
            try? writeResult(success: false, error: error.localizedDescription)
        }
    }

    private static func writeResult(success: Bool, error: String?) throws {
        var result: [String: Any] = [
            "success": success, "checks": checks, "stages": stages, "lastStage": currentStage,
            "screenshots": screenshots, "systemVersion": UIDevice.current.systemVersion,
            "inputDiagnostics": inputDiagnostics,
            "voiceLayoutDiagnostics": voiceLayoutDiagnostics,
            "deviceModel": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? UIDevice.current.model,
            "scope": "Production ContentView navigation and full AIChatView, real editable composer, persisted history, repeated home/reopen; original root retained.",
            "limitations": "Simulator runtime version recorded above; no physical-device or iOS 18.1 claim, no provider requests or device FPS measurement."
        ]
        if let error { result["error"] = error }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
}
#endif
