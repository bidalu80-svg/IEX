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
                                                               title: "聊天导航回归验证")
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
