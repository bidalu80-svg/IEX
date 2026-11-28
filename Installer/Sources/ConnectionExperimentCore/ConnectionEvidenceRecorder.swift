import Foundation

/// Deliberately no free-text logging API. Errors, peer names, payloads, PIN and keys
/// cannot be attached to an event. UI PIN delivery is a separate ephemeral channel.
@MainActor public final class ConnectionEvidenceRecorder {
    public struct Event: Codable {
        public let step: ProbeStep
        public let verdict: EvidenceVerdict
        public let elapsedMilliseconds: Int
        public let failure: ProbeFailure?
    }
    public enum Lifecycle: String, Codable { case foreground, background, heartbeat, pinAvailable, pinCleared, notificationUnavailable }
    public struct LifecycleEvent: Codable { let event: Lifecycle; let elapsedMilliseconds: Int }
    public private(set) var lifecycle: [LifecycleEvent] = []
    public func recordLifecycle(_ event: Lifecycle) {
        lifecycle.append(LifecycleEvent(event: event, elapsedMilliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)))
    }
    public private(set) var runID = UUID()
    public private(set) var mode = ProbeMode.firstPairing
    public private(set) var events: [Event] = []
    public private(set) var results = Dictionary(uniqueKeysWithValues: ProbeStep.allCases.map { ($0, EvidenceVerdict.notTested) })
    private var started = DispatchTime.now().uptimeNanoseconds
    public init() {}
    public func begin(mode: ProbeMode) {
        runID = UUID(); self.mode = mode; events = []; lifecycle = []; started = DispatchTime.now().uptimeNanoseconds
        results = Dictionary(uniqueKeysWithValues: ProbeStep.allCases.map { ($0, EvidenceVerdict.notTested) })
    }
    public func record(_ step: ProbeStep, _ verdict: EvidenceVerdict, failure: ProbeFailure? = nil) {
        results[step] = verdict
        events.append(Event(step: step, verdict: verdict,
                            elapsedMilliseconds: Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000), failure: failure))
    }
    public func blockRemaining() {
        for step in ProbeStep.allCases where results[step] == .notTested && step != .systemDiscovery && step != .appReopen && step != .deviceRestart {
            record(step, .blocked)
        }
    }
    public func export() throws -> Data {
        struct Report: Encodable {
            let schema: Int; let runID: UUID; let mode: ProbeMode; let backend: String
            let results: [String: EvidenceVerdict]; let events: [Event]; let lifecycle: [LifecycleEvent]
            let environment: [String: String]; let boundaries: String
        }
        let report = Report(schema: 1, runID: runID, mode: mode, backend: "idevice 0.1.68 @ c8fff6d7fb2690eaeb591ce510754effa7b1e19b",
                            results: Dictionary(uniqueKeysWithValues: results.map { ($0.key.rawValue, $0.value) }), events: events, lifecycle: lifecycle,
                            environment: ["bundleID": Bundle.main.bundleIdentifier ?? "unknown",
                                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                "sourceCommit": Bundle.main.object(forInfoDictionaryKey: "ZEConnectionSourceCommit") as? String ?? "unknown",
                                "hostOS": ProcessInfo.processInfo.operatingSystemVersionString],
                            boundaries: "Publication is not Settings discovery. Fixture results are not device evidence. Signing and installation NOT TESTED.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}
