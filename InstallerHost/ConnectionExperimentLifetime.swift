#if ZE_CONNECTION_EXPERIMENT
import AVFoundation
import UIKit
import ConnectionExperimentCore

/// A bounded lease independent of chat state. The central audio owner revokes it
/// before any other intent starts. Never stops/resumes another subsystem's player.
@MainActor final class ConnectionExperimentLifetime: ProbeLifetime {
    private let heartbeat: @MainActor () -> Void
    init(heartbeat: @escaping @MainActor () -> Void) { self.heartbeat = heartbeat }
    private var task = UIBackgroundTaskIdentifier.invalid
    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    private var monitor: Task<Void, Never>?
    private let callbacks = ProbeCallbackScope()
    private var leased = false
    func acquire(expired: @escaping @MainActor (ProbeFailure) -> Void) throws {
        guard !leased else { throw ProbeFailure.alreadyRunning }
        let token = callbacks.begin()
        let audioConflict = callbacks.bind { expired(.audioConflict) }
        let backgroundExpired = callbacks.bind { expired(.backgroundExpired) }
        guard AudioSessionCoordinator.shared.reserveConnectionExperiment(audioConflict) else {
            callbacks.invalidate(); throw ProbeFailure.audioConflict
        }
        leased = true
        observer = NotificationCenter.default.addObserver(forName: AudioSessionCoordinator.connectionExperimentExternalAudio, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { audioConflict() }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.callbacks.isCurrent(token) else { return }
                self.heartbeat()
                let session = AVAudioSession.sharedInstance()
                if session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint || self.player?.isPlaying != true {
                    audioConflict(); return
                }
            }
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "Ze.ConnectionExperiment") {
            Task { @MainActor in backgroundExpired() }
        }
        do {
            // One second, mono signed 16-bit PCM silence, entirely in memory.
            var wav = Data("RIFF".utf8)
            func u32(_ value: UInt32) { var x = value.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
            func u16(_ value: UInt16) { var x = value.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
            u32(16036); wav.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
            u32(8000); u32(16000); u16(2); u16(16); wav.append(Data("data".utf8)); u32(16000); wav.append(Data(count: 16000))
            let audio = try AVAudioPlayer(data: wav); audio.numberOfLoops = -1; audio.volume = 0
            guard audio.play() else { throw ProbeFailure.audioConflict }; player = audio
        } catch { release(); throw ProbeFailure.audioConflict }
    }
    func release() {
        callbacks.invalidate(); leased = false; monitor?.cancel(); monitor = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        player?.stop(); player = nil
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        AudioSessionCoordinator.shared.releaseConnectionExperiment()
    }
}
#endif
