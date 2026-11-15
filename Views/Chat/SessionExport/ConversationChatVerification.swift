#if DEBUG
import UIKit
import Darwin

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
        descendants(window).first {
            ($0.accessibilityIdentifier == identifier || ($0 as? ChatLayoutGeometryUIView)?.layoutRole == identifier)
                && isVisible($0, in: window)
        }
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
        // The in-app AX walker does not expose all SwiftUI virtual elements.
        // Measure a noninteractive marker on the actual shipping Button label;
        // independent XCTest still finds voiceCall.hangUp and taps that control.
        guard let hangup = marker("chat.verify.voiceHangUp", in: window) else {
            throw NSError(domain: "ConversationChatVerification", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "\(phase): actual hang-up label geometry missing"])
        }
        try require(isVisible(hangup, in: window), "\(phase): actual hang-up label is visible")
        let hangupFrame = hangup.convert(hangup.bounds, to: window)
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
            if ProcessInfo.processInfo.arguments.contains("--verify-chat-layout-only") {
                if ProcessInfo.processInfo.arguments.contains("--verify-soul-avatar") {
                    try await verifySoulAvatar(window: window, vm: historyVM)
                }
                try await verifyChatLayout(window: window, vm: historyVM)
                try checkpoint("complete")
                try writeResult(success: true, error: nil)
                return
            }
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
            if let window = appWindow {
                try? capture("failure.png", window: window)
                let failed = UILabel(frame: CGRect(x: 0, y: window.bounds.height - 2, width: 2, height: 2))
                failed.text = "."
                failed.accessibilityIdentifier = "chat.layout.failed"
                failed.isAccessibilityElement = true
                window.addSubview(failed)
            }
            try? writeResult(success: false, error: error.localizedDescription)
        }
    }


    /// Uses the complete production page, including the nested keyboard host,
    /// actual collection cells, attachment grid and FloatingToolBar.
    private static func verifyChatLayout(window: UIWindow, vm: AIChatViewModel) async throws {
        try checkpoint("production-layout-combinations")
        window.endEditing(true)
        vm.inputText = ""
        let user = ChatMessage(role: .user, content: Array(repeating: "渐隐区域检查：这是真实消息气泡，向上滚动时应该连续淡出。", count: 45).joined(separator: "\n"))
        user.isUserTextExpanded = true
        let reply = ChatMessage(role: .assistant, content: "附件与预览应同排，输入框保持跟随键盘。")
        reply.blocks = [AssistantBlock(kind: .shellTool(command: "printf layout-check"), content: "layout-check\nPreview remains tappable", toolStatus: .success),
                        AssistantBlock(kind: .text, content: reply.content)]
        vm.messages = [user, reply]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
            ("附件" as NSString).draw(at: CGPoint(x: 30, y: 65), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 30), .foregroundColor: UIColor.white])
        }
        let url = directory.appendingPathComponent("fixture-attachment.png")
        try image.pngData()!.write(to: url)
        let savedStatus = UserDefaults.standard.object(forKey: "toolStatusBarEnabled")
        let savedPreview = UserDefaults.standard.object(forKey: "toolPreviewEnabled")
        defer {
            UserDefaults.standard.set(savedStatus, forKey: "toolStatusBarEnabled")
            UserDefaults.standard.set(savedPreview, forKey: "toolPreviewEnabled")
            window.overrideUserInterfaceStyle = .unspecified
        }
        var records: [[String: Any]] = []
        for showStatus in [false, true] {
            UserDefaults.standard.set(showStatus, forKey: "toolStatusBarEnabled")
            UserDefaults.standard.set(true, forKey: "toolPreviewEnabled")
            for count in [1, 6] {
                vm.attachments = (0..<count).map { InputAttachment(fileName: "附件\($0).png", cacheURL: url, kind: .image) }
                for keyboard in [false, true, false] {
                    if keyboard { vm.requestComposerFocusSignal.send() }
                    else { window.endEditing(true) }
                    await settle(0.9)
                    let probes = descendants(window).compactMap { $0 as? ChatLayoutGeometryUIView }
                    let probeData = probes.map { ["role": $0.layoutRole, "accessibility": $0.accessibilityIdentifier ?? "", "frame": NSCoder.string(for: $0.convert($0.bounds, to: window))] }
                    try JSONSerialization.data(withJSONObject: probeData, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("layout-probes.json"), options: .atomic)
                    // Observe final presentation, not stale compact-host bounds.
                    var settledSamples = 0
                    var geometrySamples: [[String: Any]] = []
                    do {
                        try await waitFor("expanded composer and accessory presentation settled", timeout: 10) {
                            window.layoutIfNeeded()
                            guard let tray = marker("chat.verify.attachments", in: window),
                                  let preview = marker("chat.verify.preview", in: window),
                                  let input = marker("chat.verify.input", in: window) else { return false }
                            let a = renderedRect(tray, window: window)
                            let b = renderedRect(preview, window: window)
                            let c = renderedRect(input, window: window)
                            geometrySamples.append(["attachment": rectData(a), "preview": rectData(b), "input": rectData(c),
                                                    "inputModel": rectData(input.convert(input.bounds, to: window))])
                            let landed = c.width > window.bounds.width - 40 && c.minY >= max(a.maxY, b.maxY) - 1
                                && c.minY - max(a.maxY, b.maxY) < 12
                            settledSamples = landed ? settledSamples + 1 : 0
                            return settledSamples >= 3
                        }
                    } catch {
                        try JSONSerialization.data(withJSONObject: geometrySamples, options: [.prettyPrinted, .sortedKeys])
                            .write(to: directory.appendingPathComponent("layout-settling.json"), options: .atomic)
                        throw error
                    }
                    let name = "layout-status\(showStatus)-attachments\(count)-keyboard\(keyboard)"
                    try capture(name + ".png", window: window)
                    guard let tray = marker("chat.verify.attachments", in: window),
                          let preview = marker("chat.verify.preview", in: window),
                          let input = marker("chat.verify.input", in: window) else {
                        try require(false, "Production attachment, preview and input markers exist: \(name)")
                        return
                    }
                    let a = renderedRect(tray, window: window)
                    let b = renderedRect(preview, window: window)
                    let c = renderedRect(input, window: window)
                    records.append(["name": name, "attachment": rectData(a), "preview": rectData(b), "input": rectData(c)])
                    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("accessory-geometry.json"), options: .atomic)
                    let statusRect = marker("chat.verify.status", in: window).map { renderedRect($0, window: window) }
                    if showStatus, let statusRect {
                        try require(abs(b.maxY - statusRect.maxY) < 2, "Preview bottom aligns with status bottom: \(name)")
                        try require(abs(a.maxY - statusRect.minY) < 2, "Attachments sit immediately above status: \(name)")
                    } else {
                        try require(abs(a.maxY - b.maxY) < 2, "Without status, attachment and preview share bottom edge: \(name)")
                    }
                    try require(a.maxX <= b.minX + 1, "Attachment grid reserves preview width: \(name)")
                    try require(c.minY >= a.maxY - 1 && c.minY - a.maxY < (showStatus ? 60 : 12), "No empty preview-height row above composer: \(name)")
                    if showStatus, let status = marker("chat.verify.status", in: window) {
                        try require(status.bounds.height < 45, "Status remains intrinsic height: \(name)")
                    }
                    // Detect the earlier regression where the upper preview was
                    // drawn outside its owning UIHostingController's hit region.
                    let point = CGPoint(x: b.midX, y: b.minY + 8)
                    let hit = window.hitTest(point, with: nil)
                    var ancestor = preview.superview
                    while let current = ancestor, !String(describing: type(of: current)).contains("Hosting") {
                        ancestor = current.superview
                    }
                    let hostingAncestor = ancestor
                    try require(hit != nil && hostingAncestor.map { hit!.isDescendant(of: $0) } == true,
                                "Upper preview has a real hosting hit region: \(name)")
                }
            }
        }
        vm.attachments = []
        window.endEditing(true)
        await settle(0.8)
        try checkpoint("production-transcript-fade")
        guard let list = descendants(window).compactMap({ $0 as? UICollectionView }).first(where: { isVisible($0, in: window) }),
              let frost = marker("chat-progressive-frost", in: window),
              let bar = descendants(window).compactMap({ $0 as? UINavigationBar }).first(where: { isVisible($0, in: window) }) else {
            try require(false, "Full application has actual transcript, overlay and navigation bar")
            return
        }
        list.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        await settle(0.7)
        let listRect = list.convert(list.bounds, to: window)
        let barRect = bar.convert(bar.bounds, to: window)
        let hierarchy = descendants(window).map { view -> [String: Any] in
            ["type": String(describing: type(of: view)), "frame": rectData(view.convert(view.bounds, to: window)),
             "clips": view.clipsToBounds, "hidden": view.isHidden, "alpha": view.alpha,
             "background": view.backgroundColor?.description ?? "nil", "identifier": view.accessibilityIdentifier ?? ""]
        }
        try JSONSerialization.data(withJSONObject: hierarchy, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("actual-view-hierarchy.json"))
        try capture("actual-header-before-pixel-check.png", window: window)
        try require(listRect.minY <= window.safeAreaInsets.top + 1,
                    "Transcript viewport extends above navigation bottom; no safe-area clipping strip (top=\(listRect.minY), bar=\(barRect.maxY))")
        var pixelRecords: [[String: Any]] = []
        for theme: UIUserInterfaceStyle in [.light, .dark] {
            window.overrideUserInterfaceStyle = theme
            await settle(0.5)
            frost.isHidden = true
            await settle(0.15)
            let unfaded = snapshot(window)
            frost.isHidden = false
            await settle(0.15)
            let faded = snapshot(window)
            let dark = theme == .dark
            let label = dark ? "dark" : "light"
            try capture("actual-header-\(label)-scrolled.png", window: window)
            let y = barRect.midY - 8
            // iOS 26's trailing glass starts at x=290 on a 402pt screen.
            // The old x=289.44 sample measures its refracted/shadow edge,
            // not the transcript. Sample the gap between actual controls.
            let surfaces = descendants(window).filter {
                $0.accessibilityIdentifier?.hasPrefix("chat.nativeGlass.") ?? false
            }.map { $0.convert($0.bounds, to: window).insetBy(dx: -12, dy: -12) }
            let x = [0.64, 0.36, 0.72].map { window.bounds.width * $0 }.first { candidate in
                !surfaces.contains { $0.contains(CGPoint(x: candidate, y: y)) }
            } ?? window.bounds.width * 0.64
            let before = pixel(unfaded, point: CGPoint(x: x, y: y))
            let after = pixel(faded, point: CGPoint(x: x, y: y))
            let distance: ([CGFloat]) -> CGFloat = { $0.reduce(0) { $0 + abs($1 - (dark ? 0 : 1)) } }
            let base = distance(before), actual = distance(after)
            pixelRecords.append(["theme": label, "point": [x, y], "before": before, "after": after,
                                 "unfadedContrast": base, "fadedContrast": actual])
            try JSONSerialization.data(withJSONObject: pixelRecords, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("actual-header-pixels.json"), options: .atomic)
            try require(base > 0.06, "Real message bubble reaches the header sampling point: \(label)")
            try require(actual < base * 0.85 && actual > base * 0.015,
                        "Real bubble partially fades above the control centerline: \(label)")
            let belowPoint = CGPoint(x: x, y: barRect.midY + 10)
            let beforeBelow = pixel(unfaded, point: belowPoint)
            let afterBelow = pixel(faded, point: belowPoint)
            try require(zip(beforeBelow, afterBelow).allSatisfy { abs($0 - $1) < 0.025 },
                        "Below the red line the actual message is unchanged: \(label)")
        }
        // Leave the actual attachment+preview combination for external XCTest
        // taps, rather than exercising copied label/rectangle substitutes.
        window.overrideUserInterfaceStyle = .light
        UserDefaults.standard.set(false, forKey: "toolStatusBarEnabled")
        vm.attachments = [InputAttachment(fileName: "附件.png", cacheURL: url, kind: .image)]
        await settle(0.5)
        let ready = UILabel(frame: CGRect(x: 0, y: window.bounds.height - 2, width: 2, height: 2))
        ready.text = "."
        ready.accessibilityIdentifier = "chat.layout.ready"
        ready.isAccessibilityElement = true
        window.addSubview(ready)
    }

    private static func verifySoulAvatar(window: UIWindow, vm: AIChatViewModel) async throws {
        try checkpoint("production-soul-avatar")
        try require(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
                    "Native glass verification runs on iOS 26 or newer")
        let savedMessages = vm.messages
        let savedProcessing = vm.isProcessing
        let savedSize = UserDefaults.standard.object(forKey: SoulAppearancePreferences.headerAvatarSizeKey)
        let root = vm.workspaceSessionId ?? vm.sessionId!
        defer {
            ZeSubAgentCoordinator.shared.setAvatarVerificationChild(active: false, root: root)
            vm.isProcessing = savedProcessing
            vm.messages = savedMessages
            UserDefaults.standard.set(savedSize, forKey: SoulAppearancePreferences.headerAvatarSizeKey)
            window.overrideUserInterfaceStyle = .unspecified
        }
        window.endEditing(true)
        let reply = ChatMessage(role: .assistant, content: "头像状态验证")
        vm.messages = [ChatMessage(role: .user, content: "检查头像"), reply]
        func avatar() -> SoulAvatarAnimationView? {
            descendants(window).compactMap { $0 as? SoulAvatarAnimationView }
                .first { isVisible($0, in: window) }
        }
        var observations: [[String: Any]] = []
        for (style, theme) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            for state in ["idle", "thinking", "speaking", "awaiting", "working"] {
                ZeSubAgentCoordinator.shared.setAvatarVerificationChild(active: state == "working", root: root)
                vm.isProcessing = state != "idle"
                reply.blocks = state == "thinking" ? [] : [AssistantBlock(kind: .text, content: "正在输出")]
                reply.isAwaitingModelResponse = state == "awaiting"
                let expected = state == "awaiting" ? "thinking" : state
                let clip = ["idle": "idle", "thinking": "working", "speaking": "making", "working": "working"][expected]!
                try await waitFor("actual avatar \(state) \(theme)") {
                    guard let view = avatar() else { return false }
                    return view.motionName == expected && view.selectedAsset == "SoulAvatar-\(clip)-\(theme)"
                        && view.readyForDisplay && view.playbackTime > 0.05
                }
                guard let view = avatar() else { throw NSError(domain: "SoulAvatar", code: 1) }
                let time = view.playbackTime
                // Streaming updates must keep this player's current position.
                if state == "speaking" { reply.blocks.last?.content += "，继续输出" }
                await settle(0.35)
                try require(avatar() === view && view.playbackTime != time,
                            "Real avatar plays without recreation: \(state) \(theme)")
                let frame = view.convert(view.bounds, to: window)
                try require(window.bounds.contains(frame), "Avatar stays inside viewport: \(state) \(theme)")
                observations.append(["state": state, "theme": theme, "asset": view.selectedAsset,
                                     "time": view.playbackTime, "frame": rectData(frame)])
                try capture("avatar-\(theme)-\(state).png", window: window)
                await settle(0.4)
            }
        }
        ZeSubAgentCoordinator.shared.setAvatarVerificationChild(active: false, root: root)
        vm.isProcessing = false
        reply.isAwaitingModelResponse = false
        for size in [40.0, 80.0] {
            UserDefaults.standard.set(size, forKey: SoulAppearancePreferences.headerAvatarSizeKey)
            try await waitFor("avatar size setting \(size)") {
                guard let view = avatar() else { return false }
                return abs(view.bounds.width - (size - 4)) < 1
            }
            guard let view = avatar() else { throw NSError(domain: "SoulAvatar", code: 2) }
            let before = view.convert(view.bounds, to: window)
            vm.requestComposerFocusSignal.send()
            try await waitFor("keyboard focus with avatar") { composer(in: window)?.isFirstResponder == true }
            await settle(0.6)
            let during = view.convert(view.bounds, to: window)
            window.endEditing(true)
            await settle(0.6)
            let after = view.convert(view.bounds, to: window)
            try require(abs(before.midY - during.midY) < 1 && abs(before.midY - after.midY) < 1,
                        "Avatar remains anchored through keyboard cycle at size \(size)")
            try capture("avatar-size-\(Int(size)).png", window: window)
        }
        // SwiftUI glass may render directly into its layer tree without a
        // UIVisualEffectView. Markers exist only inside the native API branch.
        let glass = descendants(window).filter {
            ($0.accessibilityIdentifier?.hasPrefix("chat.nativeGlass.") ?? false) && isVisible($0, in: window)
        }
        let surfaces = glass.map { ["id": $0.accessibilityIdentifier ?? "", "frame": rectData($0.convert($0.bounds, to: window))] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["states": observations, "nativeGlassSurfaces": surfaces],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("avatar-evidence.json"))
        try require(glass.count >= 4, "All four actual header surfaces execute native glassEffect on iOS 26")
        try await verifyAvatarMemory(window: window, vm: vm, reply: reply)
    }

    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func verifyAvatarMemory(window: UIWindow, vm: AIChatViewModel, reply: ChatMessage) async throws {
        try checkpoint("production-avatar-memory")
        var samples: [[String: Any]] = []
        var warmed: [UInt64] = []
        // Warm all decoder paths, then measure repeated actual message updates.
        for iteration in 0..<36 {
            let speaking = iteration % 2 == 0
            vm.isProcessing = true
            reply.blocks = speaking ? [AssistantBlock(kind: .text, content: "连续状态切换 \(iteration)")] : []
            let expected = speaking ? "speaking" : "thinking"
            try await waitFor("crossfade cycle \(iteration)") {
                descendants(window).compactMap { $0 as? SoulAvatarAnimationView }.contains {
                    isVisible($0, in: window) && $0.motionName == expected && $0.readyForDisplay
                }
            }
            await settle(0.45)
            let views = descendants(window).compactMap { $0 as? SoulAvatarAnimationView }.filter { isVisible($0, in: window) }
            try require(views.count == 1 && views[0].retainedPlayerCount == 1,
                        "Crossfade releases outgoing decoder, cycle \(iteration)")
            let bytes = physicalFootprint()
            try require(bytes > 0, "Physical footprint is measurable, cycle \(iteration)")
            samples.append(["iteration": iteration, "physicalFootprint": bytes,
                            "players": views[0].retainedPlayerCount, "transitions": views[0].completedTransitions])
            if iteration >= 12 { warmed.append(bytes) }
        }
        let early = warmed.prefix(6).sorted()[3]
        let late = warmed.suffix(6).sorted()[3]
        let growth = Int64(late) - Int64(early)
        try JSONSerialization.data(withJSONObject: ["samples": samples, "warmMedianBytes": early,
            "lateMedianBytes": late, "growthBytes": growth,
            "scope": "Full simulator app footprint; includes system and chat allocations, not a device leak instrument."],
            options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("avatar-memory.json"))
        try require(growth < 32 * 1024 * 1024, "Post-warmup avatar switching footprint grows by less than 32 MiB")
        vm.isProcessing = false
    }

    private static func renderedRect(_ view: UIView, window: UIWindow) -> CGRect {
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }

    private static func snapshot(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private static func pixel(_ image: UIImage, point: CGPoint) -> [CGFloat] {
        guard let cg = image.cgImage else { return [] }
        let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
        var bytes: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return bytes.prefix(3).map { CGFloat($0) / 255 }
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
