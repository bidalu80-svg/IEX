#if DEBUG
import UIKit
import OpenGlass
import Darwin

/// Exercises the shipping ContentView navigation and complete AIChatView. In
/// particular, materializes the real inputBar/inputBottomRow generic metadata
/// which component-only share/search fixtures never instantiate.
@MainActor enum ConversationChatVerification {
    /// Used only by the explicit full-application send-layout launch mode.
    static var sendLayoutProvider: SendLayoutProvider?

    final class SendLayoutProvider: AgentProvider, @unchecked Sendable {
        let instanceID = "send-layout-" + UUID().uuidString
        let name = "Controlled send layout"
        let model = LLMModel(id: "send-layout", displayName: "Send layout", provider: "OpenAI",
                             contextWindow: 128_000, maxOutputTokens: 1024)
        let defaultMaxTokens = 1024
        private let lock = NSLock()
        private var streams: [AsyncThrowingStream<AgentStreamEvent, Error>.Continuation] = []
        private var released = false
        private func finish(_ stream: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) {
            stream.yield(.contentBlockStart(.text))
            stream.yield(.textDelta("发送布局验证的受控短回复。"))
            stream.yield(.done(stopReason: .endTurn))
            stream.finish()
        }
        func releaseReply() {
            lock.lock()
            released = true
            let pending = streams
            streams.removeAll()
            lock.unlock()
            pending.forEach(finish)
        }
        func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?,
                                       tools: [AgentToolDefinition], maxTokens: Int,
                                       thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
            AsyncThrowingStream { stream in
                lock.lock()
                let ready = released
                if !ready { streams.append(stream) }
                lock.unlock()
                if ready { finish(stream) }
            }
        }
    }

    private static var checks: [String] = []
    private static var stages: [String] = []
    private static var screenshots: [String] = []
    private static var currentStage = "startup"
    private static var inputDiagnostics: [[String: Any]] = []
    private static var voiceLayoutDiagnostics: [[String: Any]] = []
    private static var headerHitDiagnostics: [[String: Any]] = []
    private static var keyboardHangDiagnostics: [[String: Any]] = []
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

    /// Probe the window, not just the badge: a visible SwiftUI accessibility
    /// element does not prove that NavigationStack routes a real touch to it.
    private static func verifyHeaderHitRegions(in window: UIWindow, phase: String) throws {
        guard let badge = marker("chat.verify.providerBadge", in: window),
              let avatar = descendants(badge).compactMap({ $0 as? SoulAvatarAnimationView }).first,
              let bar = descendants(window).compactMap({ $0 as? UINavigationBar })
                .first(where: { isVisible($0, in: window) }) else {
            try require(false, "\(phase): actual header and navigation bar exist")
            return
        }
        func path(_ view: UIView?) -> [String] {
            var result: [String] = []
            var current = view
            while let view = current {
                let index = view.superview?.subviews.firstIndex(of: view) ?? 0
                result.append("\(type(of: view))[\(index)] \(view.accessibilityIdentifier ?? "")")
                current = view.superview
            }
            return result
        }
        // A hosting view's immediate next responder can be SwiftUI's event
        // bridge rather than its controller. Resolve ownership through UIKit
        // containment and exact view identity, never through that cast. A host
        // with no parent (or the wrong parent) still fails the assertion below.
        let root = window.rootViewController
        let badgeController = root?.children.first { $0.viewIfLoaded === badge }
        var badgeResponderPath: [String] = []
        var responder: UIResponder? = badge.next
        while let current = responder {
            badgeResponderPath.append(String(describing: type(of: current)))
            responder = current.next
        }
        func probe(_ name: String, at point: CGPoint, within expected: UIView) throws {
            let hit = window.hitTest(point, with: nil)
            headerHitDiagnostics.append([
                "phase": phase, "control": name, "point": [point.x, point.y],
                "hitPath": path(hit), "badgePath": path(badge), "barPath": path(bar),
                "badgeSuperviewIsRootView": badge.superview === root?.view,
                "badgeResponderPath": badgeResponderPath,
                "badgeImmediateResponderControllerParent": (badge.next as? UIViewController)?.parent
                    .map { String(describing: type(of: $0)) } ?? "nil",
                "badgeController": badgeController.map { String(describing: type(of: $0)) } ?? "nil",
                "badgeControllerParent": badgeController?.parent
                    .map { String(describing: type(of: $0)) } ?? "nil"
            ])
            // Write before asserting so an intercepted touch identifies its exact
            // receiver and ancestry even when verification stops here.
            try JSONSerialization.data(withJSONObject: headerHitDiagnostics, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("header-hit-testing.json"), options: .atomic)
            try require(hit.map { $0.isDescendant(of: expected) } == true,
                        "\(phase): \(name) receives a window-level hit (\(path(hit)))")
        }
        let avatarFrame = avatar.convert(avatar.bounds, to: window)
        try probe("avatar", at: CGPoint(x: avatarFrame.midX, y: avatarFrame.midY), within: badge)
        let prefix = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? "chat.nativeGlass." : "chat.fallbackGlass."
        guard let capsule = descendants(badge).first(where: { $0.accessibilityIdentifier == prefix + "capsule" }),
              let leading = descendants(bar).first(where: { $0.accessibilityIdentifier == prefix + "circle" }),
              let trailing = descendants(bar).first(where: { $0.accessibilityIdentifier == prefix + "capsule" }) else {
            try require(false, "\(phase): actual provider and navigation control markers exist")
            return
        }
        let capsuleFrame = capsule.convert(capsule.bounds, to: window)
        try probe("provider capsule", at: CGPoint(x: capsuleFrame.midX, y: capsuleFrame.midY), within: badge)
        for (name, surface, fraction) in [("leading navigation", leading, CGFloat(0.5)),
                                          ("trailing navigation", trailing, CGFloat(0.75))] {
            let frame = surface.convert(surface.bounds, to: window)
            // Compare to the bar's own target too, so the header cannot replace
            // a native navigation control's target with its own hosting view.
            let point = CGPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
            let expected = bar.hitTest(bar.convert(point, from: window), with: nil)
            try probe(name, at: point, within: bar)
            try require(expected != nil && expected !== bar && window.hitTest(point, with: nil) === expected,
                        "\(phase): header preserves \(name)'s native hit target")
        }
        try require(badge.superview === window.rootViewController?.view
                    && badgeController?.parent === window.rootViewController,
                    "\(phase): header view and controller stay under the window root")
        try require(ChatHeaderHitRouting.isActive(in: window, badge: badge, bar: bar),
                    "\(phase): chat bar passthrough is active for the root-hosted header")
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

    /// Samples the real composer's window-space top while the software
    /// keyboard animates. Used by verifyKeyboardHang to prove the fix did not
    /// turn the keyboard motion into an instant jump.
    @MainActor private final class KeyboardTransitionSampler: NSObject {
        weak var window: UIWindow?
        weak var input: PastableUITextView?
        private var link: CADisplayLink?
        private(set) var samples: [CGFloat] = []

        init(window: UIWindow, input: PastableUITextView?) {
            self.window = window
            self.input = input
            super.init()
        }

        func start() {
            let displayLink = CADisplayLink(target: self, selector: #selector(tick))
            link = displayLink
            displayLink.add(to: .main, forMode: .common)
            tick()
        }

        func stop() {
            guard link != nil else { return }
            link?.invalidate()
            link = nil
            tick()
        }

        @objc private func tick() {
            guard let window, let input, input.window === window else { return }
            samples.append(input.convert(input.bounds, to: window).minY)
        }

        func intermediatePositionCount(from start: CGFloat, to end: CGFloat) -> Int {
            var unique: [CGFloat] = []
            for value in samples {
                let rounded = (value * 2).rounded() / 2
                if !unique.contains(where: { abs($0 - rounded) < 0.5 }) {
                    unique.append(rounded)
                }
            }
            return unique.filter { abs($0 - start) > 4 && abs($0 - end) > 4 }.count
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

            // Cold mode opens history directly: even an untyped new chat
            // auto-focuses after 600ms and would warm the process keyboard.
            let coldKeyboardStart = ProcessInfo.processInfo.arguments.contains("--keyboard-hang-cold-start")
                && ProcessInfo.processInfo.arguments.contains("--verify-keyboard-hang")
            if !coldKeyboardStart {
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

            }

            try checkpoint("open-persisted-history")
            NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                            userInfo: ["sessionId": session.id])
            try await waitFor("persisted history and full composer") {
                composer(in: window) != nil && renderedHistory(historyMarker, in: window)
            }
            if coldKeyboardStart {
                try await waitFor("cold history real kernel boot", timeout: 90) { ISHKernel.shared.isBooted }
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
            if ProcessInfo.processInfo.arguments.contains("--verify-send-layout") {
                try await verifySessionLoadSearchLayout(window: window, returnSessionID: session.id,
                                                       returnMarker: historyMarker)
                try await verifySendLayout(window: window, vm: historyVM)
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-keyboard-hang") {
                try await verifyKeyboardHang(window: window, vm: historyVM, coldStart: coldKeyboardStart)
                try checkpoint("complete")
                try writeResult(success: true, error: nil)
                return
            }
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


    /// [T-keyboard-hang] Authoritative reproducer for the 0x8BADF00D report:
    /// a 29k-character table/code/math assistant message, a three-line draft,
    /// and ten real keyboard show/hide cycles through the production composer.
    /// Captures HangDetector events plus the four counters that expose a
    /// layout storm (inputBarHeight writes, SelfSizingCell super calls,
    /// ChatKeyboardViewport.update, ChatNavigationBarAppearance.updateBadge)
    /// and proves the keyboard still has intermediate positions.
    private static func verifyKeyboardHang(window: UIWindow, vm: AIChatViewModel, coldStart: Bool = false) async throws {
        try checkpoint("keyboard-hang-fixture")
        window.endEditing(true)
        await settle(0.6)

        let marker = "KEYBOARD-HANG-END-\(UUID().uuidString.prefix(8))"
        let (synthetic, blockCount) = DebugRPCChat.buildSyntheticMarkdown(targetChars: 29_000, blockChars: 800)
        let user = ChatMessage(role: .user, content: "键盘卡死复现：普通用户消息，用于保留可见短 cell。")
        let shortReply = ChatMessage(role: .assistant, content: "普通短回复，键盘弹起时必须保持可布局。")
        let heavy = ChatMessage(role: .assistant, content: synthetic + "\n\n" + marker)
        vm.messages = [user, shortReply, heavy]
        vm.inputText = "第一行草稿\n第二行草稿\n第三行草稿"

        try await waitFor("heavy markdown collection view mounted", timeout: 20) {
            descendants(window).contains {
                guard let collection = $0 as? UICollectionView else { return false }
                return collection.collectionViewLayout is MessageListLayout && isVisible(collection, in: window)
            }
        }
        guard let list = descendants(window).compactMap({ $0 as? UICollectionView })
            .first(where: { $0.collectionViewLayout is MessageListLayout && isVisible($0, in: window) }) else {
            try require(false, "Keyboard-hang fixture has a real message list")
            return
        }
        // Real bottom anchoring, repeated because the 29k cell can correct its
        // height while TextKit finishes laying it out.
        for _ in 0..<4 {
            let bottom = max(0, list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
            list.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            await settle(0.7)
        }
        try await waitFor("heavy markdown ending rendered", timeout: 60) {
            renderedHistory(marker, in: window)
        }
        try await waitFor("three-line draft reaches production composer") {
            composer(in: window)?.text == vm.inputText
        }
        await settle(0.8)

        if !coldStart {
            // Warm the leading-edge seed and one keyboard cycle before measuring,
            // so cycle 1 is not charged for first-appearance layout.
            vm.requestComposerFocusSignal.send()
            try await waitFor("keyboard warmup shown") { composer(in: window)?.isFirstResponder == true }
            await settle(0.8)
            window.endEditing(true)
            await settle(0.8)
        }
        KeyboardHangProbe.reset()
        HangDetector.clearEvents()
        guard HangDetector.start(withThresholdMs: 500) else {
            throw NSError(domain: "ConversationChatVerification", code: -20,
                          userInfo: [NSLocalizedDescriptionKey: "HangDetector could not start"])
        }
        defer { HangDetector.stop() }

        var cycles: [[String: Any]] = []
        var cycleIndex = 0

        // [T-keyboard-hang-1253] One measured show/hide cycle. `setup` runs
        // after the probe reset (so scenario-specific composer work is part
        // of the measured window); `whileVisible` runs once the composer is
        // first responder and before the settle sample (keyplane reload path).
        func runKeyboardCycle(scenario: String,
                              setup: () async throws -> Void = {},
                              whileVisible: (() -> Void)? = nil) async throws -> [String: Any] {
            cycleIndex += 1
            KeyboardHangProbe.reset()
            try await setup()
            let visibleCells = max(1, list.visibleCells.count)
            guard let input = composer(in: window) else {
                throw NSError(domain: "ConversationChatVerification", code: -21,
                              userInfo: [NSLocalizedDescriptionKey: "Keyboard-hang \(scenario) cycle \(cycleIndex): composer missing"])
            }
            let startY = input.convert(input.bounds, to: window).minY
            let sampler = KeyboardTransitionSampler(window: window, input: input)
            sampler.start()
            vm.requestComposerFocusSignal.send()
            try await waitFor("keyboard shown \(scenario) cycle \(cycleIndex)") {
                composer(in: window)?.isFirstResponder == true
            }
            whileVisible?()
            await settle(0.75)
            sampler.stop()
            let endY = composer(in: window).map { $0.convert($0.bounds, to: window).minY } ?? startY
            let intermediates = sampler.intermediatePositionCount(from: startY, to: endY)
            window.endEditing(true)
            try await waitFor("keyboard hidden \(scenario) cycle \(cycleIndex)") {
                composer(in: window)?.isFirstResponder != true
            }
            await settle(0.6)
            let counters = KeyboardHangProbe.snapshot()
            let entry: [String: Any] = [
                "scenario": scenario,
                "cycle": cycleIndex,
                "visibleCells": visibleCells,
                "inputBarHeightWrites": counters.inputBarHeightWrites,
                "latestInputBarFrameHWrites": counters.latestInputBarFrameHWrites,
                "selfSizingSuperCalls": counters.selfSizingSuperCalls,
                "viewportUpdates": counters.viewportUpdates,
                "badgeUpdates": counters.badgeUpdates,
                "keyboardCacheHits": counters.keyboardCacheHits,
                "viewDidLayoutSubviewsCalls": counters.viewDidLayoutSubviewsCalls,
                "hostLayoutIfNeededCalls": counters.hostLayoutIfNeededCalls,
                "composerHostLayoutIfNeededCalls": counters.composerHostLayoutIfNeededCalls,
                "contentRootReplacements": counters.contentRootReplacements,
                "composerRootReplacements": counters.composerRootReplacements,
                "composerIntrinsicSizeCalls": counters.composerIntrinsicSizeCalls,
                "composerSizeThatFitsCalls": counters.composerSizeThatFitsCalls,
                "composerFullMeasurementCalls": counters.composerFullMeasurementCalls,
                "composerMeasurementCacheHits": counters.composerMeasurementCacheHits,
                "composerDuplicateMeasurementCalls": counters.composerDuplicateMeasurementCalls,
                "composerMeasurementTotalMs": counters.composerMeasurementTotalMs,
                "composerMeasurementMaxMs": counters.composerMeasurementMaxMs,
                "keyboardIntermediatePositions": intermediates,
                "composerStartY": startY,
                "composerEndY": endY,
            ]
            cycles.append(entry)
            keyboardHangDiagnostics.append(entry)
            try JSONSerialization.data(withJSONObject: cycles, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("keyboard-hang.json"), options: .atomic)
            return entry
        }

        // Baseline: ten plain keyboard show/hide cycles (existing coverage).
        for index in 1...10 {
            if coldStart && index == 1 { try checkpoint("keyboard-hang-cold-first-show") }
            _ = try await runKeyboardCycle(scenario: coldStart && index == 1 ? "cold-first-show" : "baseline")
        }

        // Scenario 1: quote reply (pendingQuote strip appears) then raise the
        // keyboard through the production focus signal.
        vm.inputText = ""
        await settle(0.3)
        vm.beginReply(to: heavy.id)
        try await waitFor("quote reply strip reaches production composer") { vm.pendingQuote != nil }
        _ = try await runKeyboardCycle(scenario: "quote-reply")
        vm.cancelReply()
        await settle(0.3)

        // Scenario 2: a long selected snippet appended to the composer, then
        // raise the keyboard. Covers the append + width morph combination.
        vm.inputText = ""
        await settle(0.3)
        let selectedSnippet = Array(repeating: "选取到输入框的长段落：这是从消息正文选取并追加到输入框的内容。", count: 24)
            .joined(separator: "\n")
        vm.appendToInputText(selectedSnippet)
        try await waitFor("long selection reaches production composer") { composer(in: window)?.text == vm.inputText }
        _ = try await runKeyboardCycle(scenario: "selection-append")
        vm.inputText = ""
        await settle(0.3)

        // Scenario 3: first responder -> returnKeyType change -> reloadInputViews,
        // the UIKit keyplane/input-mode proxy path (may be a no-op in simulator).
        vm.inputText = "键盘平面切换代理路径"
        try await waitFor("return-key draft reaches production composer") { composer(in: window)?.text == vm.inputText }
        _ = try await runKeyboardCycle(scenario: "keyplane-reload", whileVisible: {
            guard let input = composer(in: window), input.isFirstResponder else { return }
            input.returnKeyType = (input.returnKeyType == .send) ? .default : .send
            input.reloadInputViews()
        })

        let events = HangDetector.dumpLast(0, clear: true)
        let severe = events.filter { $0.durationMs >= 1000 }
        let maxDuration = events.map { $0.durationMs }.max() ?? 0
        let summary: [String: Any] = [
            "cycles": cycles,
            "hangEventCount": events.count,
            "hangEventsAtOrAbove1000ms": severe.count,
            "maxHangDurationMs": maxDuration,
            "fixtureChars": synthetic.count,
            "fixtureBlocks": blockCount,
            "coldStart": coldStart,
            "thresholdMs": 500,
        ]
        keyboardHangDiagnostics.append(summary)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("keyboard-hang-summary.json"), options: .atomic)

        try require(severe.isEmpty,
                    "Ten keyboard cycles produce no HangDetector event >=1000ms (max=\(String(format: "%.0f", maxDuration))ms)")
        for entry in cycles {
            let cycle = entry["cycle"] as? Int ?? -1
            let scenario = entry["scenario"] as? String ?? "baseline"
            let writes = entry["inputBarHeightWrites"] as? Int ?? -1
            let superCalls = entry["selfSizingSuperCalls"] as? Int ?? -1
            let viewportUpdates = entry["viewportUpdates"] as? Int ?? -1
            let badgeUpdates = entry["badgeUpdates"] as? Int ?? -1
            let intermediates = entry["keyboardIntermediatePositions"] as? Int ?? -1
            let visible = entry["visibleCells"] as? Int ?? 1
            try require(writes <= 2,
                        "Cycle \(cycle) [\(scenario)]: inputBarHeight writes <=2 (got \(writes))")
            try require(superCalls <= visible + 2,
                        "Cycle \(cycle) [\(scenario)]: SelfSizingCell super calls <= visible cells + 2 (got \(superCalls), visible \(visible))")
            // A cycle contains two transitions (show + hide); each may
            // legitimately rebuild once for visibility and once for the final
            // height commit.
            try require(viewportUpdates <= 4,
                        "Cycle \(cycle) [\(scenario)]: ChatKeyboardViewport.update <=4 (2 per transition, got \(viewportUpdates))")
            try require(badgeUpdates <= 1,
                        "Cycle \(cycle) [\(scenario)]: ChatNavigationBarAppearance.updateBadge <=1 (got \(badgeUpdates))")
            try require(intermediates >= 4,
                        "Cycle \(cycle) [\(scenario)]: keyboard keeps >=4 intermediate composer positions (got \(intermediates))")

            // [T-keyboard-hang-1253] New instrument assertions. The layout
            // pass limits are deliberately generous and are meant to be
            // calibrated from the first CI baseline; they only reject a
            // runaway per-frame storm, not normal 60/120Hz keyboard motion.
            let layoutPasses = entry["viewDidLayoutSubviewsCalls"] as? Int ?? -1
            let composerLayouts = entry["composerHostLayoutIfNeededCalls"] as? Int ?? -1
            let contentRoots = entry["contentRootReplacements"] as? Int ?? -1
            let composerRoots = entry["composerRootReplacements"] as? Int ?? -1
            let duplicates = entry["composerDuplicateMeasurementCalls"] as? Int ?? -1
            let fullMeasurements = entry["composerFullMeasurementCalls"] as? Int ?? -1
            let measurementMax = entry["composerMeasurementMaxMs"] as? Double ?? 0
            try require(layoutPasses <= 180,
                        "Cycle \(cycle) [\(scenario)]: viewDidLayoutSubviews <=180 per keyboard cycle (got \(layoutPasses))")
            try require(composerLayouts <= 90,
                        "Cycle \(cycle) [\(scenario)]: composerHost layoutIfNeeded <=90 per keyboard cycle (got \(composerLayouts))")
            try require(contentRoots <= 6,
                        "Cycle \(cycle) [\(scenario)]: content root replacements <=6 (got \(contentRoots))")
            try require(composerRoots <= 6,
                        "Cycle \(cycle) [\(scenario)]: composer root replacements <=6 (got \(composerRoots))")
            try require(duplicates == 0,
                        "Cycle \(cycle) [\(scenario)]: no duplicate full measure for the same (text,width,font) (got \(duplicates))")
            try require(fullMeasurements <= 8,
                        "Cycle \(cycle) [\(scenario)]: full composer measurements <=8 (got \(fullMeasurements))")
            try require(measurementMax < 50,
                        "Cycle \(cycle) [\(scenario)]: composer measurement max <50ms (got \(String(format: "%.1f", measurementMax))ms)")
        }
        try require(true, "Ten-cycle keyboard-hang reproducer completes with bounded counters")
    }

    /// Uses the complete production page, including the nested keyboard host,
    /// actual collection cells, attachment grid and FloatingToolBar.
    /// Samples the real coordinator, real cells and presentation layers, including
    /// frames after the keyboard and content have both stopped changing.
    @MainActor private final class SendLayoutSampler: NSObject {
        let window: UIWindow
        let list: UICollectionView
        let oldReply: UUID
        let vm: AIChatViewModel
        var frames: [[String: Any]] = []
        var replyReleased = false
        private var link: CADisplayLink?
        init(window: UIWindow, list: UICollectionView, oldReply: UUID, vm: AIChatViewModel) {
            self.window = window; self.list = list; self.oldReply = oldReply; self.vm = vm
        }
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            self.link = link
            link.add(to: .main, forMode: .common)
            tick()
        }
        func stop() { link?.invalidate(); link = nil }
        @objc func tick() {
            guard let source = list.dataSource as? UICollectionViewDiffableDataSource<CollectionViewMessageListV3.Section, MessageListItem> else { return }
            var frame: [String: Any] = ["t": CACurrentMediaTime(), "offset": list.contentOffset.y,
                "contentSize": list.contentSize.height, "inset": list.adjustedContentInset.bottom,
                "processing": vm.isProcessing, "replyReleased": replyReleased]
            if let input = marker("chat.verify.input", in: window) {
                frame["input"] = rectData(renderedRect(input, window: window))
            }
            let newUser = vm.messages.dropFirst(2).last(where: { $0.role == .user })?.id
            let newAssistant = vm.messages.last(where: { $0.role == .assistant && $0.id != oldReply })?.id
            for item in source.snapshot().itemIdentifiers {
                let role: String?
                switch item {
                case .wholeMessage(let id): role = id == newUser ? "bubble" : nil
                case .assistantBlock(let id, _): role = id == oldReply ? "oldBody" : nil
                case .assistantHeader(let id): role = id == newAssistant ? "newHeader" : nil
                default: role = nil
                }
                if let role, let index = source.indexPath(for: item), let cell = list.cellForItem(at: index) {
                    frame[role] = rectData(renderedRect(cell, window: window))
                }
            }
            if let coordinator = list.delegate as? CollectionViewMessageListV3.Coordinator {
                frame.merge(coordinator.sendLayoutGeometryEvidence()) { _, new in new }
            }
            frames.append(frame)
        }
    }

    private static func verifySessionLoadSearchLayout(window: UIWindow, returnSessionID: String,
                                                      returnMarker: String) async throws {
        try checkpoint("production-load-clamp-search")
        var records: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("load-clamp-search.json"), options: .atomic)
            }
        }
        // Each case opens a fresh persisted session and enters the real first-
        // load subscription, rather than injecting a clamp into a fixture shell.
        for waitForDeadline in [false, true] {
            window.endEditing(true)
            let token = "LOAD-CLAMP-SEARCH-" + UUID().uuidString
            let tail = "LOAD-CLAMP-TAIL-" + UUID().uuidString
            let session = await ChatStore.shared.createSession(modelId: LLMModel.claudeHaiku45.id,
                                                               title: "加载后搜索位置保护验证")
            var messages: [RawMessage] = []
            let created = Date()
            for index in 0..<24 {
                messages.append(RawMessage(id: UUID().uuidString, sessionId: session.id, role: .user,
                    parts: [.text("历史问题 \(index)")], createdAt: created.addingTimeInterval(Double(index * 2)),
                    tokenUsage: nil, reasoningContent: nil))
                let text = index == 0 ? token : (index == 23 ? tail : "已有助手正文 \(index)，用于建立可以搜索浏览的长对话。")
                messages.append(RawMessage(id: UUID().uuidString, sessionId: session.id, role: .assistant,
                    parts: [.text(text)], createdAt: created.addingTimeInterval(Double(index * 2 + 1)),
                    tokenUsage: nil, reasoningContent: nil))
            }
            await ChatStore.shared.appendMessages(messages)
            NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                            userInfo: ["sessionId": session.id])
            try await waitFor("fresh persisted clamp fixture rendered") {
                ViewModelCache.shared.get(for: session.id)?.isLoadingSession == false
                    && renderedHistory(tail, in: window) && composer(in: window) != nil
            }
            guard let vm = ViewModelCache.shared.get(for: session.id),
                  let list = descendants(window).compactMap({ $0 as? UICollectionView })
                    .first(where: { $0.collectionViewLayout is MessageListLayout && isVisible($0, in: window) }),
                  let coordinator = list.delegate as? CollectionViewMessageListV3.Coordinator else {
                try require(false, "Load/search fixture mounts its production VM and coordinator"); return
            }
            let initial = coordinator.sessionLoadClampEvidence()
            try require(initial.pending && initial.deadline > Date() && coordinator.scrollMode == .autoScrolling,
                        "Fresh persisted session starts with an active load clamp and auto follow")
            vm.requestComposerFocusSignal.send()
            try await waitFor("load/search keyboard shown") { composer(in: window)?.isFirstResponder == true }
            await settle(0.9)
            var contentSizeChanges = 0
            let observation = list.observe(\.contentSize, options: [.old, .new]) { _, change in
                if change.oldValue != change.newValue { contentSizeChanges += 1 }
            }
            defer { observation.invalidate(); vm.chatSearch.deactivate() }
            if waitForDeadline {
                let changesBeforeWait = contentSizeChanges
                while Date() <= initial.deadline { await settle(0.1) }
                try require(contentSizeChanges == changesBeforeWait,
                            "Load deadline elapses with no contentSize KVO")
                coordinator.performViewportGeometryCommit { list.layoutIfNeeded() }
                try require(!coordinator.sessionLoadClampEvidence().pending,
                            "Geometry-only commit expires the load clamp without contentSize KVO")
            } else {
                try require(coordinator.sessionLoadClampEvidence().pending && Date() < initial.deadline,
                            "Search begins inside the first-load clamp window")
            }
            vm.chatSearch.bind(viewModel: vm)
            vm.chatSearch.activate(prefill: token)
            try await waitFor("search selects the old assistant text block") {
                guard let hit = vm.chatSearch.current else { return false }
                return hit.blockId != nil && vm.messages.first(where: { $0.id == hit.messageId })?.role == .assistant
                    && coordinator.scrollMode == .userBrowsing
            }
            await settle(0.7) // Include search's deferred 0/0.25s placements.
            try require(!coordinator.sessionLoadClampEvidence().pending,
                        "Explicit assistant search cancels session-load follow intent")
            let before = list.contentOffset.y
            let maxBefore = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
            try require(maxBefore - before > 100, "Search fixture lands above the bottom without dragging")
            window.endEditing(true)
            await settle(0.9) // Includes the production keyboard-end geometry commit.
            let expected = ChatListScrollTarget.resolve(contentHeight: list.contentSize.height,
                viewportHeight: list.bounds.height, adjustedTop: list.adjustedContentInset.top,
                adjustedBottom: list.adjustedContentInset.bottom, baseBottom: 0, safeAreaBottom: 0,
                current: before, followsBottom: false)
            try require(coordinator.scrollMode == .userBrowsing && abs(list.contentOffset.y - expected) <= 1,
                        "Keyboard end preserves the searched reading offset, clamping only to the legal range")
            let afterKeyboard = list.contentOffset.y
            coordinator.performViewportGeometryCommit { list.layoutIfNeeded() }
            try require(abs(list.contentOffset.y - afterKeyboard) <= 0.5,
                        "Repeated geometry-only commit cannot reapply the old load pin")
            records.append(["waitedForDeadline": waitForDeadline, "contentSizeChanges": contentSizeChanges,
                            "searchedOffset": before, "afterKeyboard": afterKeyboard,
                            "expectedBrowseOffset": expected, "clampPending": coordinator.sessionLoadClampEvidence().pending])
        }
        NotificationCenter.default.post(name: .openSessionFromIntent, object: nil,
                                        userInfo: ["sessionId": returnSessionID])
        try await waitFor("original send-layout history restored") { renderedHistory(returnMarker, in: window) }
        await settle(0.5)
    }

    private static func verifySendLayout(window: UIWindow, vm: AIChatViewModel) async throws {
        try checkpoint("production-send-layout")
        window.endEditing(true)
        guard let sessionID = vm.sessionId else { try require(false, "Send fixture has a persisted session"); return }
        let fixture = SendLayoutProvider()
        let store = ProviderConfigStore.shared
        let savedBinding = store.binding(for: sessionID)
        sendLayoutProvider = fixture
        defer {
            fixture.releaseReply()
            sendLayoutProvider = nil
            if let savedBinding { store.setBinding(savedBinding, for: sessionID) }
            else { store.removeBinding(for: sessionID) }
            store.removeInstance(fixture.instanceID)
            window.endEditing(true)
        }
        store.addInstance(ProviderInstance(id: fixture.instanceID, label: fixture.name,
                                           providerType: .openAI, credentialType: .apiKey))
        let entry = ModelEntry(providerInstanceId: fixture.instanceID, model: fixture.model)
        store.addEntry(entry)
        store.setBinding(SessionModelBinding(sessionId: sessionID,
            primarySource: .directEntry(modelEntryId: entry.id), subModelSource: nil), for: sessionID)
        let oldUser = ChatMessage(role: .user, content: "已有的短问题。")
        let oldReplyText = "已有的短回复，操作栏隐藏时应保留间距。"
        let oldReply = ChatMessage(role: .assistant, content: oldReplyText,
                                   blocks: [AssistantBlock(kind: .text, content: oldReplyText)])
        vm.messages = [oldUser, oldReply]
        vm.inputText = ""
        vm.attachments = []
        await settle(1)
        guard let list = descendants(window).compactMap({ $0 as? UICollectionView })
            .first(where: { $0.collectionViewLayout is MessageListLayout && isVisible($0, in: window) }) else {
            try require(false, "Send fixture mounts the production collection list"); return
        }
        let longText = Array(repeating: "粘贴长文发送布局验证：输入栏收缩之后消息和新标题应保持稳定。", count: 24).joined(separator: "\n")
        // Same composer content and keyboard cycle without sending is the local
        // counter baseline; the next cycle adds the real send/snapshot work.
        KeyboardHangProbe.reset()
        vm.inputText = longText
        vm.requestComposerFocusSignal.send()
        try await waitFor("send baseline keyboard") { composer(in: window)?.isFirstResponder == true }
        await settle(0.9)
        window.endEditing(true)
        await settle(0.9)
        let baseline = KeyboardHangProbe.snapshot()
        vm.inputText = ""
        await settle(0.5)
        KeyboardHangProbe.reset()
        vm.inputText = longText
        vm.requestComposerFocusSignal.send()
        try await waitFor("long paste in actual composer") {
            composer(in: window)?.isFirstResponder == true && composer(in: window)?.text == longText
        }
        await settle(0.9)
        let sampler = SendLayoutSampler(window: window, list: list, oldReply: oldReply.id, vm: vm)
        sampler.start()
        defer {
            sampler.stop()
            if let data = try? JSONSerialization.data(withJSONObject: sampler.frames, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("send-layout-frames.json"), options: .atomic)
            }
        }
        guard let input = composer(in: window) as? PastableUITextView else {
            try require(false, "Real composer provides its Return handler"); return
        }
        guard let coordinator = list.delegate as? CollectionViewMessageListV3.Coordinator else {
            try require(false, "Send fixture uses the production coordinator"); return
        }
        let beforeActions = coordinator.completionActionEvidence(for: oldReply.id)
        try require(beforeActions.reservesSpace && beforeActions.visible && beforeActions.hasBody
                    && (beforeActions.footerHeight ?? 0) > 0,
                    "Old reply has a real text block, visible completion actions and measured footer before send")
        // This is the production Return action -> handleReturnKey -> performSend.
        input.onReturnKey?()
        try await waitFor("real send creates user and assistant snapshot", timeout: 20) {
            vm.isProcessing && vm.messages.contains { $0.role == .user && $0.content == longText }
                && vm.messages.contains { $0.role == .assistant && $0.id != oldReply.id }
        }
        try await waitFor("old reply actions hide while processing") {
            let actions = coordinator.completionActionEvidence(for: oldReply.id)
            return vm.isProcessing && actions.reservesSpace && !actions.visible && actions.hasBody
        }
        let duringActions = coordinator.completionActionEvidence(for: oldReply.id)
        try require(duringActions.footerHeight != nil
                    && abs((duringActions.footerHeight ?? 0) - (beforeActions.footerHeight ?? 0)) <= 0.5,
                    "Hidden old completion actions retain the same measured footer height")
        await settle(1)
        sampler.replyReleased = true
        fixture.releaseReply()
        try await waitFor("controlled provider completes real send", timeout: 30) { !vm.isProcessing }
        // Require 0.5s stable geometry, then retain at least a further second.
        var stableSince = CACurrentMediaTime()
        var last: [Double] = []
        let deadline = CACurrentMediaTime() + 15
        while CACurrentMediaTime() < deadline {
            let values = [Double(list.contentOffset.y), Double(list.contentSize.height),
                          Double(list.adjustedContentInset.bottom),
                          Double(marker("chat.verify.input", in: window).map { renderedRect($0, window: window).minY } ?? 0)]
            if values.count != last.count || zip(values, last).contains(where: { abs($0 - $1) > 0.5 }) {
                stableSince = CACurrentMediaTime(); last = values
            }
            if CACurrentMediaTime() - stableSince >= 1.5 { break }
            await settle(0.1)
        }
        try require(CACurrentMediaTime() - stableSince >= 1.5, "Send geometry settles and records at least one extra second")
        sampler.stop()
        let counters = KeyboardHangProbe.snapshot()
        try require(counters.composerHostLayoutIfNeededCalls <= baseline.composerHostLayoutIfNeededCalls * 2 + 12,
                    "Send composer layout count stays within local keyboard baseline allowance")
        try require(counters.contentRootReplacements <= baseline.contentRootReplacements * 2 + 6,
                    "Send content root count stays within local keyboard baseline allowance")
        let finalFrames = sampler.frames.filter { ($0["t"] as? Double ?? 0) >= stableSince + 0.5 }
        try require(finalFrames.count >= 10, "Per-display-frame tail covers at least one second")
        for frame in sampler.frames {
            if let effective = frame["effectiveInputHeight"] as? CGFloat,
               let reserved = frame["reservedInputHeight"] as? CGFloat {
                try require(abs(effective - reserved) <= 0.5, "Input geometry and reserved height agree in the displayed layout")
            }
        }
        func rect(_ frame: [String: Any], _ key: String) -> [String: CGFloat]? { frame[key] as? [String: CGFloat] }
        // A delayed correction after a visible pause is the regression, even
        // if the final one-second tail eventually becomes stable again.
        var previousBubbleY: CGFloat?
        var previousInputY: CGFloat?
        var pausedSince: Double?
        for frame in sampler.frames where frame["processing"] as? Bool == true
            && frame["replyReleased"] as? Bool == false {
            guard let bubbleY = rect(frame, "bubble")?["y"],
                  let inputY = rect(frame, "input")?["y"], let time = frame["t"] as? Double else { continue }
            if let oldY = previousBubbleY, let oldInputY = previousInputY {
                if abs(inputY - oldInputY) <= 0.5 {
                    if abs(bubbleY - oldY) <= 0.5 { pausedSince = pausedSince ?? time }
                    else {
                        if let pausedSince, time - pausedSince >= 0.15 {
                            try require(abs(bubbleY - oldY) <= 2, "No late bubble correction after input and bubble pause")
                        }
                        pausedSince = nil
                    }
                } else { pausedSince = nil }
            }
            previousBubbleY = bubbleY; previousInputY = inputY
        }
        let paired = sampler.frames.filter { rect($0, "oldBody") != nil && rect($0, "bubble") != nil }
        let gaps = paired.compactMap { frame -> CGFloat? in
            guard let body = rect(frame, "oldBody"), let bubble = rect(frame, "bubble"),
                  let y = bubble["y"], let oldY = body["y"], let height = body["height"] else { return nil }
            return y - oldY - height
        }
        try require(!gaps.isEmpty, "Real old reply and new long user bubble are sampled together")
        if let low = gaps.min(), let high = gaps.max() {
            try require(high - low <= 2, "Hiding old completion actions preserves body-to-user spacing")
        }
        try require(finalFrames.allSatisfy { rect($0, "bubble") != nil && rect($0, "newHeader") != nil },
                    "Stable tail includes the long bubble and new assistant header")
        for dimension in ["width", "height"] {
            let values = sampler.frames.compactMap { rect($0, "bubble")?[dimension] }
            if let low = values.min(), let high = values.max() {
                try require(high - low <= 1, "Long bubble \(dimension) stays stable across send")
            }
        }
        for key in ["bubble", "newHeader", "input"] {
            let positions = finalFrames.compactMap { rect($0, key)?["y"] }
            if let low = positions.min(), let high = positions.max() {
                try require(high - low <= 1, "Settled \(key) presentation has no delayed jump")
            }
        }
        let before = list.contentOffset.y
        coordinator.performViewportGeometryCommit {
            coordinator.performViewportGeometryCommit { list.layoutIfNeeded() }
        }
        try require(abs(before - list.contentOffset.y) <= 0.5, "Repeated nested geometry commits are idempotent")
        try JSONSerialization.data(withJSONObject: [
            "baselineComposerLayouts": baseline.composerHostLayoutIfNeededCalls,
            "sendComposerLayouts": counters.composerHostLayoutIfNeededCalls,
            "baselineContentRoots": baseline.contentRootReplacements,
            "sendContentRoots": counters.contentRootReplacements,
            "frames": sampler.frames.count], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("send-layout-counters.json"), options: .atomic)
    }

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
            if ProcessInfo.processInfo.arguments.contains("--verify-soul-avatar"),
               ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
                try await verifyLegacyRefraction(window: window, theme: label)
            }
            // Sample the same normalized location in the gradient on each
            // runtime. Its last 28% ramps to zero; a fixed 8pt offset samples
            // a weaker tail when iOS 26 increases navigation height.
            let frostRect = frost.convert(frost.bounds, to: window)
            let y = frostRect.minY + frostRect.height * 0.80
            // iOS 26's trailing glass starts at x=290 on a 402pt screen.
            // The old x=289.44 sample measures its refracted/shadow edge,
            // not the transcript. Sample the gap between actual controls.
            let surfaces = descendants(window).filter {
                ($0.accessibilityIdentifier?.hasPrefix("chat.nativeGlass.") ?? false)
                    || ($0.accessibilityIdentifier?.hasPrefix("chat.fallbackGlass.") ?? false)
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
        if ProcessInfo.processInfo.arguments.contains("--verify-soul-avatar") {
            try verifyHeaderHitRegions(in: window, phase: "before-external-coordinate-tap")
        }
        let ready = UILabel(frame: CGRect(x: 0, y: window.bounds.height - 2, width: 2, height: 2))
        ready.text = "."
        ready.accessibilityIdentifier = "chat.layout.ready"
        ready.isAccessibilityElement = true
        window.addSubview(ready)
    }

    private static func verifySoulAvatar(window: UIWindow, vm: AIChatViewModel) async throws {
        try checkpoint("production-soul-avatar")
        let nativeGlass = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
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
        let posterAsset = SoulAvatarIdlePolicy.posterAsset
        let mainPoster = UIImage(named: posterAsset)
        try require(mainPoster != nil, "SoulAvatar-main transparent image is packaged")
        for (style, theme) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            let posterBackground = SoulAvatarIdlePolicy.posterBackground(theme: theme)
            for state in ["idle", "thinking", "speaking", "awaiting", "working"] {
                ZeSubAgentCoordinator.shared.setAvatarVerificationChild(active: state == "working", root: root)
                vm.isProcessing = state != "idle"
                reply.blocks = state == "thinking" ? [] : [AssistantBlock(kind: .text, content: "正在输出")]
                reply.isAwaitingModelResponse = state == "awaiting"
                let expected = state == "awaiting" ? "thinking" : state
                let clip = ["idle": "idle", "thinking": "working", "speaking": "making", "working": "working"][expected]!
                let isIdle = expected == "idle"
                try await waitFor("actual avatar \(state) \(theme)") {
                    guard let view = avatar() else { return false }
                    guard view.motionName == expected,
                          view.selectedAsset == "SoulAvatar-\(clip)-\(theme)" else { return false }
                    if isIdle {
                        // Idle is the transparent main image composited over
                        // the theme background. The only other legal state is
                        // the short original-idle playback window.
                        let poster = view.isShowingIdlePoster && !view.isPlaying
                            && view.idlePosterAsset == posterAsset
                            && view.idlePosterBackground == posterBackground
                            && view.idlePosterImage?.size == mainPoster?.size
                        return poster || view.isPlayingIdleSegment
                    }
                    return view.readyForDisplay && view.playbackTime > 0.05
                }
                guard let view = avatar() else { throw NSError(domain: "SoulAvatar", code: 1) }
                let time = view.playbackTime
                // Streaming updates must keep this player's current position.
                if state == "speaking" { reply.blocks.last?.content += "，继续输出" }
                await settle(0.35)
                if isIdle {
                    // Testable idle contract: the main image is composited over
                    // the theme background, the poster is visible and the
                    // looping player is stopped. isPlayingIdleSegment is the
                    // explicit "occasionally plays a short idle clip" window
                    // exception; both flags are mutually exclusive.
                    try require(avatar() === view
                                && (view.isShowingIdlePoster || view.isPlayingIdleSegment),
                                "Idle avatar stays static (or in its short playback window) without recreation: \(state) \(theme)")
                    try require(view.idlePosterAsset == posterAsset
                                && view.idlePosterBackground == posterBackground
                                && view.idlePosterImage?.size == mainPoster?.size
                                && view.isShowingIdlePoster != view.isPlayingIdleSegment,
                                "Idle shows \(posterAsset) composited over the \(theme) background, not a pre-baked poster or looping video: \(state) \(theme)")
                } else {
                    try require(avatar() === view && view.playbackTime != time,
                                "Real avatar plays without recreation: \(state) \(theme)")
                }
                let frame = view.convert(view.bounds, to: window)
                try require(window.bounds.contains(frame), "Avatar stays inside viewport: \(state) \(theme)")
                observations.append(["state": state, "theme": theme, "asset": view.selectedAsset,
                                     "time": view.playbackTime, "idlePoster": view.isShowingIdlePoster,
                                     "idlePlaybackWindow": view.isPlayingIdleSegment,
                                     "idlePosterAsset": view.idlePosterAsset,
                                     "idlePosterBackground": view.idlePosterBackground.map {
                                         "\($0.red),\($0.green),\($0.blue)"
                                     } ?? "",
                                     "idlePosterImageSize": view.idlePosterImage.map {
                                         "\($0.size.width)x\($0.size.height)"
                                     } ?? "",
                                     "frame": rectData(frame)])
                let expectedStatus = ["idle": "idle", "thinking": "思考中", "speaking": "正在回复",
                                      "awaiting": "思考中", "working": "子任务执行中"][state]!
                try await waitFor("header activity \(state) \(theme)") {
                    descendants(window).contains {
                        $0.accessibilityIdentifier == "chat.soulStatus" && $0.accessibilityValue == expectedStatus
                    }
                }
                try require(true, "Actual header text follows \(state): \(theme)")
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
            try verifyHeaderHitRegions(in: window, phase: "avatar-size-\(size)")
            vm.requestComposerFocusSignal.send()
            try await waitFor("keyboard focus with avatar") { composer(in: window)?.isFirstResponder == true }
            await settle(0.6)
            let during = view.convert(view.bounds, to: window)
            try verifyHeaderHitRegions(in: window, phase: "avatar-size-\(size)-keyboard")
            window.endEditing(true)
            await settle(0.6)
            let after = view.convert(view.bounds, to: window)
            try require(abs(before.midY - during.midY) < 1 && abs(before.midY - after.midY) < 1,
                        "Avatar remains anchored through keyboard cycle at size \(size)")
            try capture("avatar-size-\(Int(size)).png", window: window)
        }
        // SwiftUI glass may render directly into its layer tree without a
        // UIVisualEffectView. Markers exist only inside the native API branch.
        let prefix = nativeGlass ? "chat.nativeGlass." : "chat.fallbackGlass."
        let opposite = nativeGlass ? "chat.fallbackGlass." : "chat.nativeGlass."
        let glass = descendants(window).filter {
            ($0.accessibilityIdentifier?.hasPrefix(prefix) ?? false) && isVisible($0, in: window)
        }
        let surfaces = glass.map { ["id": $0.accessibilityIdentifier ?? "", "frame": rectData($0.convert($0.bounds, to: window))] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["states": observations, "nativeGlassSurfaces": surfaces],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("avatar-evidence.json"))
        try require(glass.count >= 4, "All four actual header surfaces execute \(nativeGlass ? "native" : "fallback") glass")
        try require(!descendants(window).contains { ($0.accessibilityIdentifier?.hasPrefix(opposite) ?? false) && isVisible($0, in: window) },
                    "Native and legacy glass branches are mutually exclusive")
        if !nativeGlass {
            let lenses = descendants(window).compactMap { $0 as? OpenGlassView }
            try require(lenses.count == 4, "Four real Metal lens views are attached")
            try require(OpenGlassView.verifyUnregisterDuringFrame(),
                        "Removing and reattaching every glass view during a frame preserves renderer storage")
            let counts = lenses.map(\.renderedFrameCount)
            await settle(0.5)
            try require(zip(lenses, counts).allSatisfy { $0.0.renderedFrameCount > $0.1 },
                        "Every legacy lens actually submits new Metal frames")
        }
        try await verifyHeaderToolActivity(window: window, vm: vm, reply: reply)
        try await verifyAvatarMemory(window: window, vm: vm, reply: reply)
    }

    private static func verifyHeaderToolActivity(window: UIWindow, vm: AIChatViewModel, reply: ChatMessage) async throws {
        func status() -> String? {
            descendants(window).first { $0.accessibilityIdentifier == "chat.soulStatus" }?.accessibilityValue
        }
        vm.isProcessing = true
        reply.isAwaitingModelResponse = false
        for theme: UIUserInterfaceStyle in [.light, .dark] {
            window.overrideUserInterfaceStyle = theme
            let tool = AssistantBlock(kind: .shellTool(command: "scheduled_task_set_enabled"), content: "", toolStatus: .running)
            reply.blocks = [tool]
            try await waitFor("live scheduled task label") { status() == "更新定时任务" }
            // Hold a real running block across content updates; text must not
            // show raw tool output or alternate with thinking between tokens.
            for _ in 0..<4 {
                tool.content += "private execution output"
                await settle(0.1)
                try require(status() == "更新定时任务", "Running tool output leaves the header label unchanged")
            }
            try capture("status-\(theme == .dark ? "dark" : "light")-tool.png", window: window)
            tool.toolStatus = .success
            let question = AssistantBlock(kind: .memoryTool(action: "ask_user"), content: "", toolStatus: .running)
            // This block also renders in the transcript. Use the production
            // parser's non-empty question invariant, not a header-only stub:
            // an empty pending card makes QuestionPendingCard.q index -1.
            guard let card = QuestionCardParser.state(requestId: "status-verification", arguments: [
                "tool_title": "确认下一步",
                "questions": [["id": "next-step", "type": "confirm", "question": "是否继续下一步？"]]
            ], timeout: 60) else {
                try require(false, "Header verification parses a real pending question")
                return
            }
            try require(card.status == .pending && card.questions.indices.contains(card.currentIndex),
                        "Pending header fixture has a renderable current question")
            question.questionCard = card
            reply.blocks = [question]
            try await waitFor("actual pending user input label") { status() == "等待你的回复" }
            await settle()
            try capture("status-\(theme == .dark ? "dark" : "light")-question.png", window: window)
            question.toolStatus = .success
            reply.isAwaitingModelResponse = true
            try await waitFor("model followup is not a user confirmation") { status() == "思考中" }
            vm.isProcessing = false
            try await waitFor("completed work restores provider title") { status() == "idle" }
            try require(true, "Completed tool and user-input states restore the provider name")
            vm.isProcessing = true
        }
        reply.blocks = []
        reply.isAwaitingModelResponse = false
    }

    /// Compare the actual header over the scrolled conversation with only lens
    /// displacement disabled. Blur, tint, rim, foreground and layout stay equal.
    private static func verifyLegacyRefraction(window: UIWindow, theme: String) async throws {
        let lenses = descendants(window).compactMap { $0 as? OpenGlassView }.filter {
            isVisible($0, in: window) && $0.bounds.width > $0.bounds.height * 1.4
        }
        try require(!lenses.isEmpty, "Legacy refraction audit finds actual capsule surfaces")
        let configurations = lenses.map(\.configuration)
        let refracted = snapshot(window)
        defer {
            for (lens, configuration) in zip(lenses, configurations) { lens.configuration = configuration }
        }
        for lens in lenses { lens.configuration.refractionStrength = 0 }
        await settle(0.3)
        let flat = snapshot(window)
        try flat.pngData()?.write(to: directory.appendingPathComponent("legacy-\(theme)-refraction-disabled.png"))
        try refracted.pngData()?.write(to: directory.appendingPathComponent("legacy-\(theme)-refraction-enabled.png"))
        var differences: [CGFloat] = []
        for lens in lenses {
            let rect = lens.convert(lens.bounds, to: window)
            for row in 1..<12 {
                for column in 1..<30 {
                    let point = CGPoint(x: rect.minX + rect.width * CGFloat(column) / 30,
                                        y: rect.minY + rect.height * CGFloat(row) / 12)
                    let before = pixel(flat, point: point), after = pixel(refracted, point: point)
                    differences.append(zip(before, after).map { abs($0 - $1) }.max() ?? 0)
                }
            }
        }
        let changed = differences.filter { $0 > 2.0 / 255 }.count
        try JSONSerialization.data(withJSONObject: ["theme": theme, "samples": differences.count,
            "changedSamples": changed, "maxChannelDifference": differences.max() ?? 0],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("legacy-refraction-\(theme).json"))
        try require(changed >= 3, "Metal refraction changes real conversation pixels inside capsules: \(theme)")
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
            "keyboardHangDiagnostics": keyboardHangDiagnostics,
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
