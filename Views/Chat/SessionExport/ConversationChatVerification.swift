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
        descendants(window).compactMap { $0 as? PastableUITextView }
            .first { $0.isEditable && isVisible($0, in: window) }
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
            guard let firstComposer = composer(in: window) else {
                throw NSError(domain: "ConversationChatVerification", code: -3)
            }
            try await waitFor("new-chat automatic production focus") { firstComposer.isFirstResponder }
            try require(firstComposer.isFirstResponder, "Actual new-chat composer accepts automatic focus")
            firstComposer.insertText("新对话输入验证")
            await settle(0.5)
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
            guard let historyVM = ViewModelCache.shared.get(for: session.id),
                  let historyComposer = composer(in: window) else {
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
            try await waitFor("historical composer focus through production binding") {
                historyComposer.isFirstResponder
            }
            try require(historyComposer.isFirstResponder, "Historical composer accepts production focus intent")
            historyComposer.insertText("历史输入绑定验证")
            try await waitFor("actual history composer binding") { historyVM.inputText.contains("历史输入绑定验证") }
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
