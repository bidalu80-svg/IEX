import Foundation

@main enum FeedbackPolicyTests {
    static func main() throws {
        let suite = "com.ze.feedback-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = AppFeedbackPreferences(defaults: defaults)
        precondition(!preferences.completionSoundEnabled && preferences.hapticsEnabled && preferences.hapticStrength == .light)
        for tone in ReplyCompletionTone.allCases {
            for strength in FeedbackHapticStrength.allCases {
                preferences.completionSoundEnabled = true
                preferences.completionTone = tone
                preferences.hapticsEnabled = false
                preferences.hapticStrength = strength
                preferences.save(to: defaults)
                precondition(AppFeedbackPreferences(defaults: defaults) == preferences, "Settings survive reconstruction")
            }
        }
        defaults.set("unknown-tone", forKey: AppFeedbackPreferences.Keys.completionTone)
        defaults.set("unknown-strength", forKey: AppFeedbackPreferences.Keys.hapticStrength)
        preferences = AppFeedbackPreferences(defaults: defaults)
        precondition(preferences.completionTone == .glass && preferences.hapticStrength == .light)
        precondition(!preferences.hapticsEnabled, "Explicit OFF must survive fallback decoding")

        for error in [false, true] {
            for cancelled in [false, true] {
                for resumable in [false, true] {
                    for reply in [false, true] {
                        let actual = AppFeedbackPreferences.shouldComplete(hasError: error, isCancelled: cancelled,
                                                                         canResume: resumable, hasReply: reply)
                        precondition(actual == (!error && !cancelled && !resumable && reply))
                    }
                }
            }
        }
        var previous: [Data] = []
        var bytes = 0
        for tone in ReplyCompletionTone.allCases {
            let data = ReplyToneAudio.wav(tone)
            func u32(_ offset: Int) -> UInt32 {
                data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
            }
            precondition(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
            precondition(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
            precondition(Int(u32(4)) + 8 == data.count && Int(u32(40)) + 44 == data.count)
            precondition(u32(24) == UInt32(ReplyToneAudio.sampleRate))
            let duration = Double(u32(40)) / Double(ReplyToneAudio.sampleRate * 2)
            precondition(duration > 0.15 && duration < 0.4, "Chime remains short")
            var peak = 0
            for i in stride(from: 44, to: data.count, by: 2) {
                let raw = UInt16(data[i]) | UInt16(data[i + 1]) << 8
                peak = max(peak, abs(Int(Int16(bitPattern: raw))))
            }
            precondition(peak > 5_000 && peak < 31_000, "Audible waveform without hard clipping")
            precondition(data.suffix(100).allSatisfy { $0 == 0 }, "Silence tail avoids an abrupt cut")
            precondition(!previous.contains(data), "Each selectable sound is different")
            previous.append(data); bytes += data.count
            print("PASS waveform \(tone.rawValue): \(data.count) bytes, \(duration)s, peak \(peak)")
        }
        precondition(bytes < 150 * 1024, "All derived waveforms fit a small memory bound")
        print("Feedback policy: persistence, defaults, corrupt settings, all 16 completion states and five valid bounded WAVs passed")
    }
}
