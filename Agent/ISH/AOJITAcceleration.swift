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

    /// [T-aojit-status] Substrings that identify this library's guest module
    /// in the AOT registry (aot_module.path). The catalog's `paths` field is
    /// prose for the UI, so it cannot be matched directly.
    var imageMatch: [String] {
        switch id {
        case "musl": return ["ld-musl"]
        case "busybox": return ["busybox"]
        case "python": return ["python3"]
        case "node": return ["node"]
        default: return [id]
        }
    }
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
            summary: String(localized: "Image work with Pillow: opening and decoding images, resizing, blurring and sharpening filters, and colour conversion."),
            package: "py3-pillow",
            repairVersion: "11.0.0-r0",
            probe: "python3 -c \"import PIL\" >/dev/null 2>&1",
            warmup: "python3 -c \"from PIL import Image; Image.new('RGB', (8, 8))\"",
            timeout: 25
        ),
        AOJITLibrary(
            id: "libwebp",
            name: "libwebp",
            paths: "/usr/lib/libwebp.so.7 (Pillow's WebP support)",
            summary: String(localized: "Saving and opening WebP images with Pillow. libwebp leans on vector instructions, which are still emulated, so the gain is small."),
            package: "libwebp",
            repairVersion: "1.4.0-r0",
            probe: "apk info -e libwebp >/dev/null 2>&1",
            warmup: "python3 -c \"import ctypes; ctypes.CDLL('/usr/lib/libwebp.so.7')\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "libjpeg",
            name: "libjpeg-turbo",
            paths: "/usr/lib/libjpeg.so.8 (Pillow's JPEG support)",
            summary: String(localized: "Saving and opening JPEG images with Pillow. libjpeg-turbo leans on vector instructions, which are still emulated, so the gain is small."),
            package: "libjpeg-turbo",
            repairVersion: "3.0.4-r0",
            probe: "apk info -e libjpeg-turbo >/dev/null 2>&1",
            warmup: "python3 -c \"import ctypes; ctypes.CDLL('/usr/lib/libjpeg.so.8')\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "numpy",
            name: "NumPy",
            paths: "numpy._core._multiarray_umath (python3 -c \"import numpy\")",
            summary: String(localized: "NumPy array work in Python: array arithmetic, reductions such as sum and mean, sorting and indexing (also underneath pandas and matplotlib). Linear algebra runs in OpenBLAS, which has no image."),
            package: "py3-numpy",
            repairVersion: "2.1.3-r0",
            probe: "python3 -c \"import numpy\" >/dev/null 2>&1",
            warmup: "python3 -c \"import numpy as np; np.arange(1000).sum()\"",
            timeout: 30
        ),
        AOJITLibrary(
            id: "zlib",
            name: "zlib",
            paths: "/usr/lib/libz.so.1",
            summary: String(localized: "Compression and decompression: PNG images, Python's zlib and gzip modules, pip unpacking wheels, and any other program using zlib."),
            package: "zlib",
            repairVersion: "1.3.1-r2",
            probe: "apk info -e zlib >/dev/null 2>&1",
            warmup: "python3 -c \"import zlib; zlib.compress(b'x' * 4096)\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "sqlite",
            name: "SQLite",
            paths: "/usr/lib/libsqlite3.so.0 (python3 sqlite3, node:sqlite)",
            summary: String(localized: "SQLite databases in Python (sqlite3), Node (node:sqlite) and other programs: inserts, indexed and range queries, full-text search and JSON functions."),
            package: "sqlite-libs",
            repairVersion: "3.48.0-r4",
            probe: "apk info -e sqlite-libs >/dev/null 2>&1",
            warmup: "python3 -c \"import sqlite3; sqlite3.connect(':memory:').execute('create table t(a)')\"",
            timeout: 25
        ),
        AOJITLibrary(
            id: "libcrypto",
            name: "OpenSSL libcrypto",
            paths: "/usr/lib/libcrypto.so.3 (python3 ssl/hashlib, curl, git, node)",
            summary: String(localized: "HTTPS and cryptography: TLS handshakes, certificate checks and hashing (Python hashlib and ssl, curl, git, pip, node https). Bulk AES-GCM encrypt/decrypt gains little."),
            package: "libcrypto3",
            repairVersion: "3.3.2-r4",
            probe: "apk info -e libcrypto3 >/dev/null 2>&1",
            warmup: "python3 -c \"import hashlib; hashlib.sha256(b'x').hexdigest()\"",
            timeout: 25
        ),
        AOJITLibrary(
            id: "libssl",
            name: "OpenSSL libssl",
            paths: "/usr/lib/libssl.so.3",
            summary: String(localized: "The TLS protocol layer behind HTTPS, used together with libcrypto; most of the HTTPS gain comes from libcrypto."),
            package: "libssl3",
            repairVersion: "3.3.2-r4",
            probe: "apk info -e libssl3 >/dev/null 2>&1",
            warmup: "python3 -c \"import ssl\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pcre2",
            name: "PCRE2",
            paths: "/usr/lib/libpcre2-8.so.0 (git grep -P, grep -P, rg -P)",
            summary: String(localized: "Only searches that explicitly use PCRE regexes benefit: git grep -P, GNU grep -P and rg -P / --pcre2. ripgrep's default search does not use PCRE2, and jq uses another regex library, so neither benefits."),
            package: "pcre2",
            repairVersion: "10.43-r0",
            probe: "apk info -e pcre2 >/dev/null 2>&1",
            warmup: "python3 -c \"import ctypes; ctypes.CDLL('/usr/lib/libpcre2-8.so.0')\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "ssh",
            name: "OpenSSH ssh",
            paths: "/usr/bin/ssh (also under scp, sftp, rsync and git over SSH)",
            summary: String(localized: "ssh logins and remote commands, plus every tool that connects through ssh: scp, sftp, rsync and git over SSH. Each new connection's handshake gets faster; the data itself is encrypted in libcrypto."),
            package: "openssh-client-default",
            repairVersion: "9.9_p2-r0",
            probe: "apk info -e openssh-client-default >/dev/null 2>&1",
            warmup: "/usr/bin/ssh -V",
            timeout: 20
        ),
        AOJITLibrary(
            id: "scp",
            name: "OpenSSH scp",
            paths: "/usr/bin/scp",
            summary: String(localized: "Copying files with scp. Most of the gain comes from the ssh connection scp opens, and ssh has its own image."),
            package: "openssh-client-common",
            repairVersion: "9.9_p2-r0",
            probe: "apk info -e openssh-client-common >/dev/null 2>&1",
            warmup: "/usr/bin/ssh -V",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pyjson",
            name: "Python json",
            paths: "_json (import json)",
            summary: String(localized: "json.loads and json.dumps in Python scripts and python3 -c one-liners."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import json\" >/dev/null 2>&1",
            warmup: "python3 -c \"import json; json.loads('{\\\"a\\\": 1}')\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pyhashlib",
            name: "Python hashlib",
            paths: "_hashlib (import hashlib)",
            summary: String(localized: "Python hashlib digests such as sha256 and md5; the hashing itself runs in libcrypto."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import hashlib\" >/dev/null 2>&1",
            warmup: "python3 -c \"import hashlib; hashlib.sha256(b'x').digest()\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pyblake2",
            name: "Python blake2",
            paths: "_blake2 (hashlib.blake2b / blake2s)",
            summary: String(localized: "hashlib.blake2b and hashlib.blake2s in Python."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import _blake2\" >/dev/null 2>&1",
            warmup: "python3 -c \"import hashlib; hashlib.blake2b(b'x').digest()\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pystruct",
            name: "Python struct",
            paths: "_struct (import struct)",
            summary: String(localized: "struct.pack and struct.unpack: reading and writing binary data in Python."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import struct\" >/dev/null 2>&1",
            warmup: "python3 -c \"import struct; struct.pack('i', 1)\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pydatetime",
            name: "Python datetime",
            paths: "_datetime (import datetime)",
            summary: String(localized: "Parsing, formatting and calculating dates and times with Python's datetime."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import datetime\" >/dev/null 2>&1",
            warmup: "python3 -c \"import datetime; datetime.datetime.now()\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pybinascii",
            name: "Python binascii",
            paths: "binascii (import base64, binascii)",
            summary: String(localized: "Base64, hex and CRC conversions in Python (base64 and binascii)."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import binascii\" >/dev/null 2>&1",
            warmup: "python3 -c \"import base64, binascii; base64.b64encode(b'x')\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pymath",
            name: "Python math",
            paths: "math (import math)",
            summary: String(localized: "Python's math module."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import math\" >/dev/null 2>&1",
            warmup: "python3 -c \"import math; math.sqrt(2)\"",
            timeout: 20
        ),
        AOJITLibrary(
            id: "pyzlib",
            name: "Python zlib",
            paths: "zlib (import zlib, gzip, zipfile)",
            summary: String(localized: "Compression in Python (zlib, gzip, zipfile); the compression itself runs in libz."),
            package: "python3",
            repairVersion: "3.12.15-r0",
            probe: "python3 -c \"import zlib\" >/dev/null 2>&1",
            warmup: "python3 -c \"import zlib; zlib.compress(b'x' * 4096)\"",
            timeout: 20
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
            applyRuntimeSwitch()
            if isEnabled {
                prepareIfNeeded()
            }
        }
    }

    @Published private(set) var states: [AOJITLibraryState] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRecording = false
    @Published private(set) var busyLibraryId: String?
    /// Last install failure per library, shown under its row. Silent failures
    /// made the repair button look dead: `executeCommandSync` returns nil when
    /// the kernel has not booted, and apk's own errors were only logged.
    @Published private(set) var repairError: [String: String] = [:]
    /// False when the guest kernel has not booted yet, so the section can say
    /// so instead of spinning forever.
    @Published private(set) var isContainerReady = false

    /// [T-aojit-runtime-switch] What the kernel reports, not what the toggle
    /// says: read back from `ish_jit_is_enabled()` after every sync.
    @Published private(set) var jitRuntimeEnabled = false
    /// True once the host feed has moved admission to footprint mode.
    @Published private(set) var footprintMode = false
    /// How many AOT images this build actually links (`ish_aot_image_count`).
    @Published private(set) var linkedImageCount = 0

    // MARK: Private

    private struct Recording: Codable {
        let id: String
        let version: String
        let recordedAt: Date
        let durationMs: Int
    }

    private struct Probe: Codable {
        var packageVersions: [String: String] = [:]
        var moduleAvailable: [String: Bool] = [:]
    }

    private var recordings: [String: Recording] = [:]
    private var lastProbe: Probe?
    private var failedRecording: Set<String> = []
    private var didPrepareThisLaunch = false
    private let queue = DispatchQueue(label: "com.ze.aojit.record", qos: .utility)
    private let logger = AppLogger(category: "AOJIT")

    private static let probeScript = #"for p in musl busybox python3 nodejs py3-pillow libwebp libjpeg-turbo py3-numpy zlib sqlite-libs libcrypto3 libssl3 pcre2 openssh-client-default openssh-client-common; do if apk info -e "$p" >/dev/null 2>&1; then printf 'pkg\t%s\t%s\n' "$p" "$(v=$(apk info -e -v "$p" 2>/dev/null | head -n 1); v=${v#"$p"-}; if [ -z "$v" ]; then v=$(apk list --installed "$p" 2>/dev/null | head -n 1 | cut -d' ' -f1); v=${v#"$p"-}; fi; printf '%s' "$v")"; else printf 'pkg\t%s\t\n' "$p"; fi; done; python3 -c "import PIL" >/dev/null 2>&1 && printf 'mod\tpillow\tok\n' || printf 'mod\tpillow\t\n'; python3 -c "import numpy" >/dev/null 2>&1 && printf 'mod\tnumpy\tok\n' || printf 'mod\tnumpy\t\n'; python3 -c "import json" >/dev/null 2>&1 && printf 'mod\tpyjson\tok\n' || printf 'mod\tpyjson\t\n'; python3 -c "import hashlib" >/dev/null 2>&1 && printf 'mod\tpyhashlib\tok\n' || printf 'mod\tpyhashlib\t\n'; python3 -c "import _blake2" >/dev/null 2>&1 && printf 'mod\tpyblake2\tok\n' || printf 'mod\tpyblake2\t\n'; python3 -c "import struct" >/dev/null 2>&1 && printf 'mod\tpystruct\tok\n' || printf 'mod\tpystruct\t\n'; python3 -c "import datetime" >/dev/null 2>&1 && printf 'mod\tpydatetime\tok\n' || printf 'mod\tpydatetime\t\n'; python3 -c "import binascii" >/dev/null 2>&1 && printf 'mod\tpybinascii\tok\n' || printf 'mod\tpybinascii\t\n'; python3 -c "import math" >/dev/null 2>&1 && printf 'mod\tpymath\tok\n' || printf 'mod\tpymath\t\n'; python3 -c "import zlib" >/dev/null 2>&1 && printf 'mod\tpyzlib\tok\n' || printf 'mod\tpyzlib\t\n'; python3 -c "import socket" >/dev/null 2>&1 && printf 'mod\tpysocket\tok\n' || printf 'mod\tpysocket\t\n'; python3 -c "import select" >/dev/null 2>&1 && printf 'mod\tpyselect\tok\n' || printf 'mod\tpyselect\t\n'"#

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
        loadRecordings()
        // [T-aojit-cache] Rebuild from the last probe so the section is filled
        // the moment it opens. Without this the rows only appeared after a
        // fresh detection, which is why every relaunch started blank.
        loadCachedProbe()
        rebuildStates()
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
        // [T-ish-footprint-brake] The kernel booted: start feeding it live
        // memory status so admission follows jetsam's number, not the ledger.
        MemoryPressureMonitor.shared.start()
        applyRuntimeSwitch()
        prepareIfNeeded()
    }

    /// [T-aojit-runtime-switch] Push the switch into the engine and read it
    /// back. Logged so a speed test can be tied to the state it ran in.
    func applyRuntimeSwitch() {
        ish_jit_set_enabled(isEnabled)
        jitRuntimeEnabled = ish_jit_is_enabled()
        footprintMode = ish_footprint_mode()
        linkedImageCount = Self.linkedImagePaths().count
        logger.info("[AOJIT] switch=preference:\(isEnabled) runtime:\(jitRuntimeEnabled) footprint:\(footprintMode) images:\(Self.linkedImagePaths().count)")
    }

    /// Re-probe the rootfs. Cheap: one shell command.
    func refresh() {
        guard !isRefreshing else { return }
        guard ISHKernel.shared.isBooted else {
            isContainerReady = false
            // Keep the cached rows: clearing them turned every relaunch into
            // "wait for a probe" instead of showing the last known state.
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
                self.saveCachedProbe()
                self.rebuildStates()
                self.footprintMode = ish_footprint_mode()
                self.jitRuntimeEnabled = ish_jit_is_enabled()
                self.linkedImageCount = Self.linkedImagePaths().count
                self.recordMissingImages()
            }
        }
    }

    /// Install the exact package version an image was recorded from.
    ///
    /// [T-aojit-repair] Runs through `ISHExecutionCoordinator`, the same path
    /// every tool call uses. `ISHShellExecutor.executeCommandSync` skips the
    /// coordinator's `ensureStaticMountsInitialized(for:)`, so apk wrote into
    /// an unmounted view of the rootfs and the package never appeared — the
    /// button looked dead. Booting first is still required: the kernel is only
    /// started when the terminal opens.
    func repair(_ state: AOJITLibraryState) {
        guard busyLibraryId == nil else { return }
        busyLibraryId = state.id
        repairError[state.id] = nil

        let spec = "\(state.library.package)=\(state.library.repairVersion)"
        let package = state.library.package
        // [T-aojit-repair] `/etc/apk/repositories` lives in the rootfs data dir,
        // which is bind-mounted into the guest. A fresh rootfs ships without it,
        // and every `apk add` then fails with "no repositories configured" —
        // that is why the button appeared to do nothing. Write it from the host,
        // reusing whichever Alpine mirror the Mirror screen has selected.
        ensureRepositories()

        let script = """
        echo "AOJIT-REPOS:"
        cat /etc/apk/repositories 2>&1 | head -4
        if ! command -v apk >/dev/null 2>&1; then echo "AOJIT-ERROR=apk-missing"; exit 0; fi
        if [ ! -s /etc/apk/repositories ]; then echo "AOJIT-ERROR=no-repositories"; exit 0; fi
        apk update 2>&1 | tail -6
        apk add --no-cache '\(spec)' 2>&1 || apk add --no-cache '\(package)' 2>&1
        if apk info -e '\(package)' >/dev/null 2>&1; then echo "AOJIT-INSTALLED=1"; else echo "AOJIT-INSTALLED=0"; fi
        """

        Task { @MainActor in
            guard ensureBooted() else {
                busyLibraryId = nil
                repairError[state.id] = String(localized: "The container could not be started.")
                return
            }
            isContainerReady = true

            let output: String
            do {
                let result = try await ISHExecutionCoordinator.shared.execute(
                    sessionId: Self.settingsSessionId,
                    command: script,
                    timeout: 420,
                    lineCallback: { _ in },
                    pidCallback: { _ in }
                )
                output = result.output
            } catch {
                busyLibraryId = nil
                repairError[state.id] = "\(String(localized: "Install failed.")) — \(error.localizedDescription)"
                return
            }

            busyLibraryId = nil
            let installed = output.contains("AOJIT-INSTALLED=1")
            if installed {
                failedRecording.remove(state.id)
                refresh()
            } else {
                logger.warning("AOJIT repair failed for \(state.id)")
                let hint: String?
                if output.contains("AOJIT-ERROR=apk-missing") {
                    hint = String(localized: "apk is missing from this rootfs.")
                } else if output.contains("AOJIT-ERROR=no-repositories") {
                    hint = String(localized: "No package source is configured.")
                } else {
                    hint = nil
                }
                let lines = output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("AOJIT-") }
                let tail = lines.suffix(6).joined(separator: "\n")
                let parts = [hint, tail.isEmpty ? nil : tail].compactMap { $0 }
                repairError[state.id] = parts.isEmpty
                    ? String(localized: "Install failed.")
                    : parts.joined(separator: "\n")
            }
        }
    }

    /// Stable mount context for installs started from Settings.
    private static let settingsSessionId = "aojit-settings"

    /// Writes `/etc/apk/repositories` when the rootfs has none.
    ///
    /// The Mirror screen (`MirrorSpeedTestViewModel.applyMirror`) writes this
    /// file straight into the rootfs data directory rather than through the
    /// guest, so the same approach is used here: it works before the kernel has
    /// booted and cannot be blocked by a read-only guest view of `/etc`.
    private func ensureRepositories() {
        let data = RootfsManager.shared.dataPath
        let file = data.appendingPathComponent("etc/apk/repositories")

        // Match the rootfs's own branch; a mismatched branch 404s every index.
        // The Mirror screen hard-codes v3.21, so a 3.20 rootfs ends up pointing
        // at a branch that does not exist.
        let release = (try? String(contentsOf: data.appendingPathComponent("etc/alpine-release"),
                                    encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = release.split(separator: ".").prefix(2)
        let branch = parts.count == 2 ? parts.joined(separator: ".") : "3.21"

        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let referenced = Self.branch(inRepositories: trimmed)
            if !trimmed.isEmpty, referenced == nil || referenced == branch {
                return
            }
            logger.info("AOJIT repositories point at v\(referenced ?? "?") but the rootfs is v\(branch); rewriting")
        }

        let base = UserDefaults.standard.string(forKey: "mirror.selected.alpine")
            .flatMap { MirrorEntry.find(baseURL: $0) }?.baseURL
            ?? "https://dl-cdn.alpinelinux.org/alpine/"

        let content = "\(base)v\(branch)/main\n\(base)v\(branch)/community\n"
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
            logger.info("AOJIT repositories → v\(branch) via \(base)")
        } catch {
            logger.error("AOJIT repositories write failed: \(error.localizedDescription)")
        }
    }

    /// Extracts `3.21` from a repositories file containing `/alpine/v3.21/…`.
    private static func branch(inRepositories text: String) -> String? {
        guard let range = text.range(of: "/v", options: .backwards) else { return nil }
        let tail = text[range.upperBound...]
        let digits = tail.prefix { $0.isNumber || $0 == "." }
        return digits.isEmpty ? nil : String(digits)
    }

    /// Boots the guest kernel when the terminal has not done it yet.
    /// Mirrors `ISHTerminalView.startShell`, including the rootfs install step.
    private func ensureBooted() -> Bool {
        if ISHKernel.shared.isBooted { return true }
        do {
            try RootfsManager.shared.installIfNeeded()
        } catch {
            logger.warning("AOJIT rootfs install failed: \(error.localizedDescription)")
            return false
        }
        let status = ISHKernel.shared.boot(withRootPath: RootfsManager.shared.rootfsPath.path)
        guard status >= 0 else {
            logger.warning("AOJIT kernel boot failed: \(status)")
            return false
        }
        return true
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
            let linked = Self.linkedImagePaths()
            let hasImage = linked.contains { path in
                library.imageMatch.contains { path.contains($0) }
            }
            if installed == nil {
                status = .notInstalled
            } else if hasImage && (recording == nil || recording?.version == installed) {
                // [T-aojit-status] The build has a real AOT image for this
                // module linked in — that is what makes it fast, not the
                // warm-up record.
                status = .available
            } else if hasImage {
                status = .partial
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

        // [T-aojit-order] Available first: the page should answer "where is the
        // speed" before "what is missing".
        states.sort { Self.rank($0.status) < Self.rank($1.status) }
    }

    private static func rank(_ status: AOJITLibraryState.Status) -> Int {
        switch status {
        case .available:    return 0
        case .partial:      return 1
        case .recording:    return 2
        case .notInstalled: return 3
        }
    }

    /// Guest paths of the AOT images this build actually has linked in.
    private static func linkedImagePaths() -> [String] {
        var out: [String] = []
        let n = ish_aot_image_count()
        guard n > 0 else { return out }
        for i in 0..<n {
            if let c = ish_aot_image_path(i), let s = String(validatingUTF8: c) {
                out.append(s)
            }
        }
        return out
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

                guard let version = state.installedVersion else {
                    failed.insert(state.id)
                    continue
                }
                if result?.exitCode != 0 {
                    // Best-effort: a missing helper (python3 for the C
                    // libraries) must not leave an installed library stuck on
                    // "preparing" forever.
                    self?.logger.info("AOJIT warm-up \(state.id) exited \(result?.exitCode ?? -1)")
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

    // MARK: Probe cache

    private static var cachedProbeURL: URL {
        recordingsURL.deletingLastPathComponent().appendingPathComponent("probe.json")
    }

    private func loadCachedProbe() {
        guard let data = try? Data(contentsOf: Self.cachedProbeURL),
              let decoded = try? JSONDecoder().decode(Probe.self, from: data) else { return }
        lastProbe = decoded
    }

    private func saveCachedProbe() {
        guard let probe = lastProbe else { return }
        let url = Self.cachedProbeURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(probe).write(to: url, options: .atomic)
        } catch {
            logger.warning("AOJIT probe cache write failed: \(error.localizedDescription)")
        }
    }
}
