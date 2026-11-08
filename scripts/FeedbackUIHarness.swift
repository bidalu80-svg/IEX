import SwiftUI
import UIKit
import AVFoundation

// The audio-session coordinator boundary is the only fixture. The real
// waveform, AVAudioPlayer, settings store, haptic gate and SwiftUI page run here.
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    enum Intent { case interfaceFeedback }
    var canPlayInterfaceFeedback = true
    private(set) var balance = 0
    func begin(_ intent: Intent) { balance += 1 }
    func end(_ intent: Intent) { balance -= 1 }
}

@main struct FeedbackUIHarness: App {
    @State private var started = false
    var body: some Scene {
        WindowGroup {
            Text("声音与震动验收").onAppear {
                guard !started else { return }
                started = true
                // This task outlives the initial host while we mount the real
                // settings pages; a view-scoped .task would cancel on removal.
                Task { @MainActor in await run() }
            }
        }
    }
    @MainActor private func run() async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let settings = AppFeedbackSettings.shared
        let original = settings.preferences
        defer { settings.preferences = original; AppFeedback.stopSound(); AppFeedback.eventObserver = nil }
        var checks: [String] = []
        var screenshots: [String] = []
        var events: [AppFeedback.Event] = []
        AppFeedback.eventObserver = { events.append($0) }
        func check(_ value: Bool, _ text: String) throws {
            guard value else { throw NSError(domain: "FeedbackUI", code: checks.count, userInfo: [NSLocalizedDescriptionKey: text]) }
            checks.append(text)
        }
        do {
            for _ in 0..<40 where UIApplication.shared.applicationState != .active {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try check(UIApplication.shared.applicationState == .active, "Foreground tone tests run in an active application")
            settings.preferences.hapticsEnabled = false
            settings.preferences.completionSoundEnabled = false
            AppFeedback.haptic()
            AppFeedback.completedReply(hasError: false, isCancelled: false, canResume: false, hasReply: true)
            try check(events.isEmpty, "Both feedback switches OFF suppress app-authored events")
            settings.preferences.hapticsEnabled = true
            for strength in FeedbackHapticStrength.allCases {
                settings.preferences.hapticStrength = strength
                AppFeedback.haptic()
                try check(events.last == .haptic(strength), "Selected haptic style reaches real generator: \(strength.rawValue)")
            }
            // Execute the production view-model finalization method against
            // queue/message boundaries, with real app feedback behind it.
            events.removeAll()
            let completionProbe = FeedbackCompletionProbe()
            let firstReply = FeedbackProbeMessage()
            let queuedReply = FeedbackProbeMessage()
            completionProbe.messages = [firstReply, queuedReply]
            var notifiedIDs = Set<UUID>()
            completionProbe.notifyCompletionFeedback(for: firstReply.id, notifiedMessageIDs: &notifiedIDs)
            completionProbe.notifyCompletionFeedback(for: queuedReply.id, notifiedMessageIDs: &notifiedIDs)
            completionProbe.notifyCompletionFeedback(for: queuedReply.id, notifiedMessageIDs: &notifiedIDs)
            try check(events.count == 2 && notifiedIDs == Set([firstReply.id, queuedReply.id]),
                      "Each completed queued reply notifies once; loop-exit fallback does not replay the last message")
            events.removeAll()
            let removedReply = FeedbackProbeMessage()
            completionProbe.messages = [removedReply]
            completionProbe.messages.removeAll()
            completionProbe.notifyCompletionFeedback(for: removedReply.id, notifiedMessageIDs: &notifiedIDs)
            try check(events.isEmpty && !notifiedIDs.contains(removedReply.id),
                      "A message deleted during persistence does not notify or index a stale array slot")
            completionProbe.messages = [queuedReply, firstReply]
            var reorderedIDs = Set<UUID>()
            completionProbe.notifyCompletionFeedback(for: firstReply.id, notifiedMessageIDs: &reorderedIDs)
            try check(events.count == 1 && reorderedIDs == Set([firstReply.id]),
                      "Completion resolves stable message identity after array reorder")
            events.removeAll()
            let failedReply = FeedbackProbeMessage()
            failedReply.error = "Network error"
            let pausedReply = FeedbackProbeMessage()
            let cancelledReply = FeedbackProbeMessage()
            let emptyReply = FeedbackProbeMessage()
            emptyReply.blocks = [FeedbackProbeBlock(kind: .tool, content: "Tool output")]
            completionProbe.messages = [failedReply, pausedReply, cancelledReply, emptyReply]
            completionProbe.notifyCompletionFeedback(for: failedReply.id, notifiedMessageIDs: &notifiedIDs)
            completionProbe.canResume = true
            completionProbe.notifyCompletionFeedback(for: pausedReply.id, notifiedMessageIDs: &notifiedIDs)
            completionProbe.canResume = false
            completionProbe.userDidCancel = true
            completionProbe.notifyCompletionFeedback(for: cancelledReply.id, notifiedMessageIDs: &notifiedIDs)
            completionProbe.userDidCancel = false
            completionProbe.notifyCompletionFeedback(for: emptyReply.id, notifiedMessageIDs: &notifiedIDs)
            try check(events.isEmpty, "Production finalization suppresses failed, resumable, stopped and tool-only replies")
            try check(AppFeedback.notificationSound(eligible: true, alreadyPlayed: false) == nil,
                      "Automatic sound OFF also silences background completion notifications")
            settings.preferences.completionSoundEnabled = true
            try check(AppFeedback.notificationSound(eligible: false, alreadyPlayed: false) == nil,
                      "Background notification stays silent for incomplete or failed work")
            try check(AppFeedback.notificationSound(eligible: true, alreadyPlayed: true) == nil,
                      "Notification does not replay a chime already played in the foreground")
            AudioSessionCoordinator.shared.canPlayInterfaceFeedback = false
            try check(AppFeedback.notificationSound(eligible: true, alreadyPlayed: false) == nil,
                      "Background notification sound respects microphone/interruption suppression")
            AudioSessionCoordinator.shared.canPlayInterfaceFeedback = true
            for tone in ReplyCompletionTone.allCases {
                settings.preferences.completionTone = tone
                try check(AppFeedback.notificationSound(eligible: true, alreadyPlayed: false) != nil,
                          "Background completion uses a valid selected notification sound: \(tone.rawValue)")
            }
            events.removeAll()
            settings.preferences.completionSoundEnabled = true
            AppFeedback.completedReply(hasError: true, isCancelled: false, canResume: false, hasReply: true)
            AppFeedback.completedReply(hasError: false, isCancelled: true, canResume: false, hasReply: true)
            AppFeedback.completedReply(hasError: false, isCancelled: false, canResume: true, hasReply: true)
            try check(events.isEmpty, "Failure, Stop and truncated/resumable replies do not chime")
            for tone in ReplyCompletionTone.allCases {
                settings.preferences.completionTone = tone
                events.removeAll()
                AppFeedback.completedReply(hasError: false, isCancelled: false, canResume: false, hasReply: true)
                try check(events.filter { $0 == .sound(tone) }.count == 1, "Complete reply plays selected real WAV once: \(tone.rawValue)")
                for _ in 0..<40 {
                    if AudioSessionCoordinator.shared.balance == 0 { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try check(AudioSessionCoordinator.shared.balance == 0, "Audio intent releases after chime: \(tone.rawValue)")
            }
            settings.preferences.completionSoundEnabled = false
            events.removeAll()
            AppFeedback.preview(.prism)
            try check(events == [.sound(.prism)], "Explicit preview works without enabling automatic reply sound")
            AppFeedback.stopSound()
            AudioSessionCoordinator.shared.canPlayInterfaceFeedback = false
            events.removeAll(); AppFeedback.preview(.glass)
            try check(events.isEmpty, "Microphone/interruption gate suppresses sound")
            AudioSessionCoordinator.shared.canPlayInterfaceFeedback = true
            try check(AppFeedbackPreferences(defaults: .standard) == settings.preferences, "Settings mutations persist immediately")

            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let window = scene.windows.first else { throw NSError(domain: "FeedbackUI", code: 50) }
            let previous = window.rootViewController
            defer { window.rootViewController = previous }
            for (name, size, dark, large, enabled) in [
                ("light-phone", CGSize(width: 390, height: 844), false, false, true),
                ("dark-phone", CGSize(width: 390, height: 844), true, false, true),
                ("compact-disabled", CGSize(width: 320, height: 740), false, false, false),
                ("large-type", CGSize(width: 390, height: 844), false, true, true),
                ("tablet", CGSize(width: 768, height: 1024), false, false, true)
            ] {
                settings.preferences.hapticsEnabled = enabled
                settings.preferences.completionSoundEnabled = enabled
                settings.preferences.completionTone = .glass
                let page = NavigationStack { SoundHapticsSettingsView() }
                    .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
                    .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
                let host = UIHostingController(rootView: page)
                host.overrideUserInterfaceStyle = dark ? .dark : .light
                let container = UIViewController()
                window.rootViewController = container
                container.addChild(host); container.view.addSubview(host.view)
                host.didMove(toParent: container)
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.setNeedsLayout(); host.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                try check(host.view.bounds.size == size, "Shipping settings receive \(name) layout proposal")
                func capture(_ suffix: String) throws {
                    let image = UIGraphicsImageRenderer(size: size).image { _ in
                        host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                    }
                    let file = "feedback-\(name)-\(suffix).png"
                    try image.pngData()?.write(to: directory.appendingPathComponent(file))
                    screenshots.append(file)
                    try check(image.size == size, "Shipping settings render at \(name) dimensions (\(suffix))")
                }
                try capture("top")
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                let scroller = descendants(host.view).compactMap { $0 as? UIScrollView }
                    .filter { $0.contentSize.height > $0.bounds.height }
                    .max { $0.bounds.height < $1.bounds.height }
                if let scroller {
                    scroller.setContentOffset(CGPoint(x: 0, y: max(-scroller.adjustedContentInset.top,
                        scroller.contentSize.height - scroller.bounds.height + scroller.adjustedContentInset.bottom)), animated: false)
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                try capture("haptics")
            }
            let report: [String: Any] = ["success": true, "checks": checks, "screenshots": screenshots,
                "scope": "Shipping settings, runtime gates, actual audio decoding/play start and intent cleanup; simulator does not establish physical haptic strength or audible hardware quality"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("feedback-ui-result.json"))
        } catch {
            let report: [String: Any] = ["success": false, "checks": checks, "screenshots": screenshots, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("feedback-ui-result.json"))
        }
    }
}
