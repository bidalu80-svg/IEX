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
        let soundDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ze-notification-sounds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: soundDirectory) }
        for tone in ReplyCompletionTone.allCases {
            guard let name = ReplyToneAudio.notificationFile(tone, directory: soundDirectory) else { preconditionFailure("Notification sound must materialize") }
            let file = soundDirectory.appendingPathComponent(name)
            let stored = try Data(contentsOf: file)
            precondition(stored == ReplyToneAudio.wav(tone))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
            // URL resource values may retain previously fetched metadata. Read
            // actual file attributes before/after; inode also detects an atomic
            // rewrite even if a filesystem rounds the modification timestamp.
            let before = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition(ReplyToneAudio.notificationFile(tone, directory: soundDirectory) == name)
            let after = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let beforeDate = before[.modificationDate] as? Date,
                  let afterDate = after[.modificationDate] as? Date,
                  let beforeInode = before[.systemFileNumber] as? NSNumber,
                  let afterInode = after[.systemFileNumber] as? NSNumber else { preconditionFailure("Filesystem attributes must exist") }
            if beforeDate != afterDate || beforeInode != afterInode {
                FileHandle.standardError.write(Data("Unexpected notification rewrite \(tone.rawValue): before=\(before), after=\(after)\n".utf8))
            }
            precondition(beforeDate == afterDate && beforeInode == afterInode,
                         "Valid file reuses bytes without rewriting on every notification")
            try Data("damaged".utf8).write(to: file)
            precondition(ReplyToneAudio.notificationFile(tone, directory: soundDirectory) == name)
            let repaired = try Data(contentsOf: file)
            precondition(repaired == ReplyToneAudio.wav(tone), "Damaged audio is replaced with the selected waveform")
        }
        let soundFiles = try FileManager.default.contentsOfDirectory(at: soundDirectory, includingPropertiesForKeys: [.fileSizeKey])
        precondition(soundFiles.count == 5, "Notification audio storage is bounded to five fixed filenames")
        let diskBytes = try soundFiles.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        precondition(diskBytes < 150 * 1024)
        let blockedDirectory = soundDirectory.appendingPathComponent("blocked")
        try Data("a file, not a directory".utf8).write(to: blockedDirectory)
        precondition(ReplyToneAudio.notificationFile(.glass, directory: blockedDirectory) == nil, "Write failure stays silent rather than choosing an unexpected default sound")
        print("PASS notification audio: fixed filenames, exact-byte reuse, corruption repair, bounded disk storage and silent write failure")
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
