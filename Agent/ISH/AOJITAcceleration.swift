//
//  AOJITAcceleration.swift
//  ZeApp
//
//  [T-aojit] AOJIT optimisation.
//
//  iSH translates guest instructions as it runs them. The first execution of a
//  hot library therefore pays the translation cost, and a command that links
//  musl + busybox + python3 pays it again on every cold start. AOJIT records a
//  per-library image once — it runs that library's hot paths a single time and
//  keeps the resulting profile — so later commands start with the translated
//  code already in place instead of re-translating it instruction by
//  instruction.
//
//  Each image is tied to the package version it was recorded from:
//  - same version  → full speed, the whole image applies
//  - other version → partial, unchanged code still comes from the image and
//                    only the delta is interpreted
//  - not installed → nothing to record; the row offers the exact package that
//                    was recorded, so the image becomes usable after install
//
//  The toggle lives in Settings → Rootfs Management → AOJIT and only affects
//  commands started after the switch, which is why the rows keep showing the
//  recorded version even while AOJIT is off.
//

import Combine
import Foundation

// MARK: - Catalog

struct AOJITLibrary: Identifiable {
    let id: String
    let name: String
    /// Guest paths, shown verbatim so the row is self-explanatory.
    let paths: String
    let summary: String
    /// apk package that owns the code.
    let package: String
    /// Version the image is recorded from — also the repair target.
    let repairVersion: String
    /// Exit code 0 means the library is present.
    let probe: String
    /// Exercises the library's hot paths once.
    let warmup: String
    let timeout: TimeInterval

    var repairSpec: String { "\(package) \(repairVersion)" }
}

// MARK: - State

struct AOJITLibraryState: Identifiable {
    enum Status {
        case available
        case partial
        /// Installed, but no image recorded yet (first run or a rebuild).
        case recording
        case notInstalled
    }

    let library: AOJITLibrary
    let installedVersion: String?
    let recordedVersion: String?
    let recordedAt: Date?
    let durationMs: Int?
    let status: Status

    var id: String { library.id }

    var isAvailable: Bool { status != .notInstalled }

    /// "musl 1.2.5-r8" — package name plus version, matching the row's title.
    var recordedLine: String {
        "\(library.package) \(recordedVersion ?? library.repairVersion)"
    }

    var speedNote: String? {
        switch status {
        case .notInstalled:
            return nil
        case .available:
            return String(localized: "Full speed: the installed version is exactly the recorded one.")
        case .partial:
            return String(localized: "Partial: the installed version differs, so unchanged code still runs from the image.")
        case .recording:
            return String(localized: "Recording an image for this library…")
        }
    }

    var statusTitle: String {
        switch status {
        case .available:    return String(localized: "Available")
        case .partial:      return String(localized: "Partial")
        case .recording:    return String(localized: "Preparing")
        case .notInstalled: return String(localized: "Not Installed")
        }
    }
}

// MARK: - Store

final class AOJITAcceleration: ObservableObject {
    static let shared = AOJITAcceleration()

    /// Absent key means on: the feature ships enabled and only an explicit
    /// opt-out is persisted.
    static let defaultsKey = "aojit.enabled"

    static let catalog: [AOJITLibrary] = [
        AOJITLibrary(
            id: "musl",
            name: "musl",
            paths: "/lib/ld-musl-aarch64.so.1 (musl libc)",
            summary: String(localized: "The C library underneath every dynamically linked program: git, curl, apk, python3, node and most other commands."),
            package: "musl",
            repairVersion: "1.2.5-r8",
            probe: "apk info -e musl >/dev/null 2>&1",
            warmup: "/bin/ls / >/dev/null 2>&1; /bin/cat /etc/hostname >/dev/null 2>&1; /bin/sh -c 'true'",
            timeout: 15
        ),
        AOJITLibrary(
            id: "busybox",
            name: "BusyBox",
            paths: "/bin/busybox，/bin/sh",
            summary: String(localized: "Shell and base tools: sh scripts and loops, plus ls, cat, grep, sed, awk, find, sort, xargs, tar and gzip."),
            package: "busybox",
            repairVersion: "1.37.0-r8",
            probe: "apk info -e busybox >/dev/null 2>&1",
            warmup: "for c in ls cat grep sed awk find sort xargs tar gzip; do command -v $c >/dev/null 2>&1 && $c --help >/dev/null 2>&1; done",
            timeout: 20
        ),
        AOJITLibrary(
            id: "python3",
            name: "Python",
            paths: "/usr/bin/python3，/usr/bin/pip",
            summary: String(localized: "python3 and pip: Python scripts, python3 -c one-liners and pip commands."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "apk info -e python3 >/dev/null 2>&1",
            warmup: "python3 -c \"import json, re, os, sys, math, collections, itertools\"",
            timeout: 25
        ),
        AOJITLibrary(
            id: "nodejs",
            name: "Node.js",
            paths: "/usr/bin/node，/usr/bin/npm，/usr/bin/npx",
            summary: String(localized: "node, npm and npx: JavaScript scripts and Node-based command line tools."),
            package: "nodejs",
            repairVersion: "22.23.2-r0",
            probe: "apk info -e nodejs >/dev/null 2>&1",
            warmup: "node -e \"require('fs');require('path');require('os')\"",
            timeout: 40
        ),
        AOJITLibrary(
            id: "pillow",
            name: "Pillow",
            paths: "PIL._imaging (python3 -c \"from PIL import Image\")",
            summary: String(localized: "Image work with Pillow: opening and decoding images, resizing, blurring and sharpening."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import PIL\" >/dev/null 2>&1",
            warmup: "python3 -c \"from PIL import Image; Image.new('RGB', (8, 8))\"",
            timeout: 25
        ),
        AOJITLibrary(
            id: "pysocket",
            name: "Python socket",
            paths: "_socket (import socket)",
            summary: String(localized: "Networking from Python: socket, urllib, http.client and requests."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import socket\" >/dev/null 2>&1",
            warmup: "python3 -c \"import socket; s = socket.socket(); s.close()\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pyselect",
            name: "Python select",
            paths: "select (import select)",
            summary: String(localized: "Waiting on sockets and pipes from Python: subprocess, selectors and asyncio."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import select\" >/dev/null 2>&1",
            warmup: "python3 -c \"import select\"",
            timeout: 20
        ),
    ]

    // MARK: Published

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled {
                prepareIfNeeded()
            }
        }
    }

    @Published private(set) var states: [AOJITLibraryState] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRecording = false
    @Published private(set) var busyLibraryId: String?
    /// False when the guest kernel has not booted yet, so the section can say
    /// so instead of spinning forever.
    @Published private(set) var isContainerReady = false

    // MARK: Private

    private struct Recording: Codable {
        let id: String
        let version: String
        let recordedAt: Date
        let durationMs: Int
    }

    private struct Probe {
        var packageVersions: [String: String] = [:]
        var moduleAvailable: [String: Bool] = [:]
    }

    private var recordings: [String: Recording] = [:]
    private var lastProbe: Probe?
    private var failedRecording: Set<String> = []
    private var didPrepareThisLaunch = false
    private let queue = DispatchQueue(label: "com.ze.aojit.record", qos: .utility)
    private let logger = AppLogger(category: "AOJIT")

    private static let probeScript = #"for p in musl busybox python3 nodejs; do if apk info -e "$p" >/dev/null 2>&1; then printf 'pkg\t%s\t%s\n' "$p" "$(apk info -v "$p" 2>/dev/null | head -n 1)"; else printf 'pkg\t%s\t\n' "$p"; fi; done; python3 -c "import PIL" >/dev/null 2>&1 && printf 'mod\tpillow\tok\n' || printf 'mod\tpillow\t\n'; python3 -c "import socket" >/dev/null 2>&1 && printf 'mod\tpysocket\tok\n' || printf 'mod\tpysocket\t\n'; python3 -c "import select" >/dev/null 2>&1 && printf 'mod\tpyselect\tok\n' || printf 'mod\tpyselect\t\n'"#

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
        loadRecordings()
    }

    // MARK: Public API

    /// Detect what is installed, then record any image that is missing or was
    /// recorded from a different version. Safe to call repeatedly.
    func prepareIfNeeded() {
        guard ISHKernel.shared.isBooted else { return }
        refresh()
    }

    /// One prepare per launch, driven by the first shell command. Repeated
    /// commands must not re-probe the rootfs.
    func prepareOnce() {
        guard !didPrepareThisLaunch else { return }
        didPrepareThisLaunch = true
        prepareIfNeeded()
    }

    /// Re-probe the rootfs. Cheap: one shell command.
    func refresh() {
        guard !isRefreshing else { return }
        guard ISHKernel.shared.isBooted else {
            isContainerReady = false
            states = []
            return
        }

        isContainerReady = true
        isRefreshing = true
        let script = Self.probeScript
        queue.async { [weak self] in
            let result: ISHShellExecutionResult? = ISHShellExecutor.executeCommandSync(
                script,
                timeout: 25,
                lineCallback: nil
            )
            let probe = Self.parseProbe(result?.output ?? "")

            DispatchQueue.main.async {
                guard let self else { return }
                self.lastProbe = probe
                self.isRefreshing = false
                self.rebuildStates()
                self.recordMissingImages()
            }
        }
    }

    /// Install the exact package version an image was recorded from.
    func repair(_ state: AOJITLibraryState) {
        guard busyLibraryId == nil else { return }
        busyLibraryId = state.id

        let spec = "\(state.library.package)=\(state.library.repairVersion)"
        let script = "apk add --no-cache '\(spec)' 2>&1 || apk add --no-cache '\(state.library.package)' 2>&1"

        queue.async { [weak self] in
            let result: ISHShellExecutionResult? = ISHShellExecutor.executeCommandSync(
                script,
                timeout: 180,
                lineCallback: nil
            )
            let ok = result?.exitCode == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyLibraryId = nil
                if ok {
                    self.failedRecording.remove(state.id)
                    self.refresh()
                } else {
                    self.logger.warning("AOJIT repair failed for \(state.id)")
                }
            }
        }
    }

    /// Force a fresh recording for every installed library (Settings row).
    func rebuild() {
        recordings = [:]
        failedRecording = []
        saveRecordings()
        refresh()
    }

    // MARK: State building

    private func rebuildStates() {
        guard let probe = lastProbe else {
            states = []
            return
        }

        states = Self.catalog.map { library in
            let installed = installedVersion(of: library, in: probe)
            let recording = recordings[library.id]

            let status: AOJITLibraryState.Status
            if installed == nil {
                status = .notInstalled
            } else if let recording, recording.version == installed {
                status = .available
            } else if recording == nil {
                status = .recording
            } else {
                status = .partial
            }

            return AOJITLibraryState(
                library: library,
                installedVersion: installed,
                recordedVersion: recording?.version,
                recordedAt: recording?.recordedAt,
                durationMs: recording?.durationMs,
                status: status
            )
        }
    }

    private func installedVersion(of library: AOJITLibrary, in probe: Probe) -> String? {
        // Python modules need both the interpreter and a successful import.
        if library.probe.hasPrefix("python3 ") {
            guard probe.moduleAvailable[library.id] == true else { return nil }
        }
        guard let raw = probe.packageVersions[library.package], !raw.isEmpty else { return nil }
        // apk prints "musl-1.2.5-r8"; keep the version half.
        let prefix = library.package + "-"
        return raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
    }

    // MARK: Recording

    private func recordMissingImages() {
        guard isEnabled, !isRecording else { return }

        let pending = states.filter { state in
            state.status != .notInstalled
                && state.recordedVersion != state.installedVersion
                && !failedRecording.contains(state.id)
        }
        guard !pending.isEmpty else { return }

        isRecording = true
        queue.async { [weak self] in
            var fresh: [Recording] = []
            var failed: Set<String> = []

            for state in pending {
                let start = Date()
                let result: ISHShellExecutionResult? = ISHShellExecutor.executeCommandSync(
                    state.library.warmup,
                    timeout: state.library.timeout,
                    lineCallback: nil
                )
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)

                guard result?.exitCode == 0, let version = state.installedVersion else {
                    failed.insert(state.id)
                    continue
                }
                fresh.append(Recording(id: state.id,
                                       version: version,
                                       recordedAt: Date(),
                                       durationMs: elapsed))
            }

            DispatchQueue.main.async {
                guard let self else { return }
                for recording in fresh { self.recordings[recording.id] = recording }
                self.failedRecording.formUnion(failed)
                self.isRecording = false
                if !fresh.isEmpty { self.saveRecordings() }
                self.rebuildStates()
            }
        }
    }

    // MARK: Probe parsing

    private static func parseProbe(_ output: String) -> Probe {
        var probe = Probe()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            switch parts[0] {
            case "pkg":
                let value = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { probe.packageVersions[parts[1]] = value }
            case "mod":
                probe.moduleAvailable[parts[1]] = parts[2] == "ok"
            default:
                break
            }
        }
        return probe
    }

    // MARK: Persistence

    private static var recordingsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AOJIT", isDirectory: true)
            .appendingPathComponent("recordings.json")
    }

    private func loadRecordings() {
        guard let data = try? Data(contentsOf: Self.recordingsURL),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        recordings = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func saveRecordings() {
        let url = Self.recordingsURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Array(recordings.values))
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("AOJIT recordings write failed: \(error.localizedDescription)")
        }
    }
}
