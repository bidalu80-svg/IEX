import Foundation

enum ReplyCompletionTone: String, CaseIterable, Identifiable {
    case glass, prism, droplet, bell, sparkle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glass: return "清音"
        case .prism: return "双音"
        case .droplet: return "水滴"
        case .bell: return "铃音"
        case .sparkle: return "星光"
        }
    }
    var detail: String {
        switch self {
        case .glass: return "轻快的一声，干净利落"
        case .prism: return "两声上扬，清晰明亮"
        case .droplet: return "短促圆润，像一滴水"
        case .bell: return "清脆铃声，带一点余韵"
        case .sparkle: return "三声轻响，灵动柔和"
        }
    }
    var notes: [(frequency: Double, start: Double, duration: Double)] {
        switch self {
        case .glass: return [(1568, 0, 0.22)]
        case .prism: return [(1174.66, 0, 0.16), (1760, 0.09, 0.20)]
        case .droplet: return [(2093, 0, 0.14), (1046.5, 0.025, 0.16)]
        case .bell: return [(1318.51, 0, 0.32), (2637.02, 0, 0.18)]
        case .sparkle: return [(1318.51, 0, 0.14), (1661.22, 0.07, 0.14), (2093, 0.14, 0.18)]
        }
    }
}

enum FeedbackHapticStrength: String, CaseIterable, Identifiable {
    case light, medium, heavy
    var id: String { rawValue }
    var title: String {
        switch self { case .light: return "轻"; case .medium: return "中"; case .heavy: return "重" }
    }
}

/// Shared persisted policy. Defaults preserve existing tactile feedback and
/// leave audible feedback opt-in. This contains no UIKit or audio ownership.
struct AppFeedbackPreferences: Equatable {
    enum Keys {
        static let completionSoundEnabled = "feedback.completionSoundEnabled"
        static let completionTone = "feedback.completionTone"
        static let hapticsEnabled = "feedback.hapticsEnabled"
        static let hapticStrength = "feedback.hapticStrength"
    }
    var completionSoundEnabled = false
    var completionTone: ReplyCompletionTone = .glass
    var hapticsEnabled = true
    var hapticStrength: FeedbackHapticStrength = .light

    init(defaults: UserDefaults) {
        completionSoundEnabled = defaults.bool(forKey: Keys.completionSoundEnabled)
        completionTone = ReplyCompletionTone(rawValue: defaults.string(forKey: Keys.completionTone) ?? "") ?? .glass
        hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) == nil || defaults.bool(forKey: Keys.hapticsEnabled)
        hapticStrength = FeedbackHapticStrength(rawValue: defaults.string(forKey: Keys.hapticStrength) ?? "") ?? .light
    }
    func save(to defaults: UserDefaults) {
        defaults.set(completionSoundEnabled, forKey: Keys.completionSoundEnabled)
        defaults.set(completionTone.rawValue, forKey: Keys.completionTone)
        defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled)
        defaults.set(hapticStrength.rawValue, forKey: Keys.hapticStrength)
    }
    static func shouldComplete(hasError: Bool, isCancelled: Bool, canResume: Bool, hasReply: Bool) -> Bool {
        !hasError && !isCancelled && !canResume && hasReply
    }
}

/// Short, original synthesized chimes. Five mono WAVs together cost less than
/// 150 KiB. Direct playback is memory-only; background notifications reuse at
/// most five derived audio files in the system-required Library/Sounds folder.
enum ReplyToneAudio {
    static let sampleRate = 44_100
    /// iOS local notifications load custom audio from Library/Sounds. Only the
    /// five fixed names are used; identical contents are reused and damaged or
    /// outdated contents are replaced atomically. Failure stays silent.
    static func notificationFile(_ tone: ReplyCompletionTone, directory: URL? = nil) -> String? {
        guard let directory = directory ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Sounds", isDirectory: true) else { return nil }
        let name = "ze-reply-\(tone.rawValue)-v1.wav"
        let file = directory.appendingPathComponent(name)
        let data = wav(tone)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if size == data.count, (try? Data(contentsOf: file)) == data { return name }
            try data.write(to: file, options: .atomic)
            return name
        } catch { return nil }
    }
    static func wav(_ tone: ReplyCompletionTone) -> Data {
        let notes = tone.notes
        let duration = (notes.map { $0.start + $0.duration }.max() ?? 0.2) + 0.015
        let count = Int(ceil(duration * Double(sampleRate)))
        var samples = [Int16](); samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            var value = 0.0
            for note in notes where t >= note.start && t < note.start + note.duration {
                let local = t - note.start
                let attack = min(1, local / 0.003)
                let end = min(1, (note.duration - local) / 0.018)
                let envelope = attack * end * exp(-local * 12)
                let phase = 2 * Double.pi * note.frequency * local
                value += (sin(phase) + 0.13 * sin(phase * 2.002)) * envelope * 0.30
            }
            samples.append(Int16(max(-0.92, min(0.92, value)) * Double(Int16.max)))
        }
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + count * 2)); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(count * 2))
        for sample in samples { u16(UInt16(bitPattern: sample)) }
        return data
    }
}
