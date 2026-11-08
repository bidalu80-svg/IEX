import UIKit
import AVFoundation
import Combine
import UserNotifications

@MainActor final class AppFeedbackSettings: ObservableObject {
    static let shared = AppFeedbackSettings()
    private let defaults: UserDefaults
    @Published var preferences: AppFeedbackPreferences {
        didSet {
            preferences.save(to: defaults)
            if oldValue.completionSoundEnabled && !preferences.completionSoundEnabled { AppFeedback.stopSound() }
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = AppFeedbackPreferences(defaults: defaults)
    }
}

/// Every app-authored tactile event passes through this single preference gate.
/// System-owned keyboard/selection feedback remains controlled by iOS.
@MainActor enum AppFeedback {
    #if DEBUG
    enum Event: Equatable { case haptic(FeedbackHapticStrength), sound(ReplyCompletionTone) }
    static var eventObserver: ((Event) -> Void)?
    #endif
    private static var generator: UIImpactFeedbackGenerator?
    private static var generatorStrength: FeedbackHapticStrength?
    private static let sound = ReplyTonePlayer()

    static func haptic() {
        let preferences = AppFeedbackSettings.shared.preferences
        guard preferences.hapticsEnabled else { return }
        let strength = preferences.hapticStrength
        if generatorStrength != strength || generator == nil {
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch strength { case .light: style = .light; case .medium: style = .medium; case .heavy: style = .heavy }
            generator = UIImpactFeedbackGenerator(style: style)
            generatorStrength = strength
        }
        generator?.impactOccurred()
        #if DEBUG
        eventObserver?(.haptic(strength))
        #endif
    }

    @discardableResult static func completedReply(hasError: Bool, isCancelled: Bool, canResume: Bool, hasReply: Bool) -> Bool {
        guard AppFeedbackPreferences.shouldComplete(hasError: hasError, isCancelled: isCancelled,
                                                    canResume: canResume, hasReply: hasReply) else { return false }
        haptic()
        let preferences = AppFeedbackSettings.shared.preferences
        // Background completion is announced by its existing local notification.
        // Playing directly here as well would produce two different chimes.
        guard preferences.completionSoundEnabled, UIApplication.shared.applicationState == .active else { return false }
        return sound.play(preferences.completionTone)
    }
    static func notificationSound(eligible: Bool, alreadyPlayed: Bool) -> UNNotificationSound? {
        let preferences = AppFeedbackSettings.shared.preferences
        guard eligible, !alreadyPlayed, preferences.completionSoundEnabled,
              AudioSessionCoordinator.shared.canPlayInterfaceFeedback,
              let name = ReplyToneAudio.notificationFile(preferences.completionTone) else { return nil }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: name))
    }
    /// An explicit preview works while the automatic completion switch is off.
    static func preview(_ tone: ReplyCompletionTone) { sound.play(tone) }
    static func stopSound() { sound.stop() }
}

@MainActor private final class ReplyTonePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var holdingIntent = false
    private var waveforms: [ReplyCompletionTone: Data] = [:]
    private var observers: [NSObjectProtocol] = []
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, UIApplication.didReceiveMemoryWarningNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.stop(); self?.waveforms.removeAll() }
            })
        }
    }
    @discardableResult func play(_ tone: ReplyCompletionTone) -> Bool {
        // A completion chime must never leak into the microphone or fight a call.
        guard AudioSessionCoordinator.shared.canPlayInterfaceFeedback else { return false }
        stop()
        let data = waveforms[tone] ?? ReplyToneAudio.wav(tone)
        waveforms[tone] = data
        guard let next = try? AVAudioPlayer(data: data) else { return false }
        AudioSessionCoordinator.shared.begin(.interfaceFeedback)
        holdingIntent = true
        next.delegate = self
        next.volume = 0.7
        player = next
        if next.play() {
            #if DEBUG
            AppFeedback.eventObserver?(.sound(tone))
            #endif
            return true
        }
        stop()
        return false
    }
    func stop() {
        player?.stop(); player?.delegate = nil; player = nil
        if holdingIntent { holdingIntent = false; AudioSessionCoordinator.shared.end(.interfaceFeedback) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, self.player === player else { return }; self.stop()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self, weak player] in
            guard let self, self.player === player else { return }; self.stop()
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
