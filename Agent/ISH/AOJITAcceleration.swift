//
//  AOJITAcceleration.swift
//  ZeApp
//
//  [T-aojit] Precompiled execution images for the built-in tools.
//
//  What it actually does
//  ---------------------
//  iSH starts every command through `/bin/sh -c`, which costs a shell fork,
//  a PATH search, and a script parse before the tool even begins. For the
//  read-only tools the agent hammers (cat, grep, sed, head, wc, stat, …) the
//  shell adds nothing: the command is a single executable plus arguments.
//
//  At prepare time we resolve each tool's absolute path once (`command -v`)
//  and store it as an *execution image* — a precompiled plan of
//  `(tool → executable path)`. At run time a simple command that matches an
//  image is exec'd directly, skipping the shell entirely; everything else
//  (pipes, redirects, globs, variables, subshells, relative paths) keeps the
//  existing `/bin/sh` path untouched.
//
//  Safety
//  ------
//  - Only read-only / path-scoped tools are imaged.
//  - A command containing any shell metacharacter is never fast-pathed.
//  - A path-only tool must be given absolute paths, because the direct exec
//    does not run the wrapper's `cd /root`.
//  - If the direct exec fails synchronously (missing binary, bad image) the
//    coordinator falls back to the shell path and the image is dropped.
//

import Combine
import Foundation

// MARK: - Image

struct AOJITImage: Codable, Equatable, Identifiable {
    var id: String { tool }
    let tool: String
    /// Absolute guest path resolved at prepare time.
    let path: String
    var warm: Bool
}

struct AOJITPlan {
    let tool: String
    let executable: String
    let arguments: [String]
}

// MARK: - Store

final class AOJITAcceleration: ObservableObject {
    static let shared = AOJITAcceleration()

    /// Absent key means "on": the feature ships enabled, and only an explicit
    /// opt-out is persisted.
    static let defaultsKey = "aojit.enabled"

    /// Every tool here is either read-only or path-scoped. Anything that can
    /// change global state (`rm`, `mv`, `cp`, `mkdir`, `chmod`, …) is left out
    /// on purpose — the shell wrapper stays in charge for those.
    static let builtinTools = [
        "cat", "ls", "grep", "sed", "awk", "head", "tail", "wc", "find",
        "stat", "file", "md5sum", "sha256sum", "base64", "cut", "sort",
        "uniq", "tr", "jq",
    ]

    /// Tools that only ever take paths: every non-flag argument must be
    /// absolute, otherwise the command depends on the working directory that
    /// the direct exec does not set.
    private static let pathOnlyTools: Set<String> = [
        "cat", "ls", "head", "tail", "wc", "stat", "file", "md5sum",
        "sha256sum", "base64", "cut", "sort", "uniq", "tr",
    ]

    /// Shell syntax, globs, variables, redirections, quoting escapes. Any of
    /// these means the command is not a single exec and must keep the shell.
    private static let rejectedCharacters: Set<Character> = [
        "|", "&", ";", "<", ">", "$", "`", "(", ")", "{", "}", "\n", "\r",
        "*", "?", "[", "]", "~", "=", "!", "#", "\\",
    ]

    private static let probeScript = #"for t in cat ls grep sed awk head tail wc find stat file md5sum sha256sum base64 cut sort uniq tr jq; do p=$(command -v "$t" 2>/dev/null) || continue; [ -n "$p" ] && printf '%s\t%s\n' "$t" "$p"; done"#

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled {
                prepareIfNeeded()
            } else {
                logger.info("AOJIT disabled by user")
            }
        }
    }

    @Published private(set) var images: [AOJITImage] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var lastPreparedAt: Date?

    private var byName: [String: AOJITImage] = [:]
    /// Guards `byName` only. `plan(for:)` runs on the execution actor while
    /// prepare/invalidate publish on main, so the lookup table needs its own
    /// lock rather than relying on either queue.
    private let tableLock = NSLock()
    private let logger = AppLogger(category: "AOJIT")
    private let queue = DispatchQueue(label: "com.ze.aojit.prepare", qos: .utility)

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
        loadManifest()
    }

    // MARK: Prepare

    /// Resolve the tool paths once and cache them. Safe to call repeatedly;
    /// concurrent calls collapse into the first one.
    func prepareIfNeeded() {
        guard isEnabled, !isPreparing, images.isEmpty else { return }
        guard ISHKernel.shared.isBooted else { return }

        isPreparing = true
        let script = Self.probeScript
        queue.async { [weak self] in
            let result: ISHShellExecutionResult? = ISHShellExecutor.executeCommandSync(
                script,
                timeout: 30,
                lineCallback: nil
            )
            let parsed = Self.parseProbe(result?.output ?? "")

            DispatchQueue.main.async {
                guard let self else { return }
                self.isPreparing = false
                guard !parsed.isEmpty else {
                    self.logger.warning("AOJIT probe found no tools; staying on the shell path")
                    return
                }
                self.images = parsed
                self.replaceTable(Dictionary(uniqueKeysWithValues: parsed.map { ($0.tool, $0) }))
                self.lastPreparedAt = Date()
                self.saveManifest()
                self.logger.info("AOJIT prepared \(parsed.count) execution images")
            }
        }
    }

    /// Drop the cached images and probe again (Settings → Rebuild Images).
    func rebuild() {
        images = []
        replaceTable([:])
        lastPreparedAt = nil
        try? FileManager.default.removeItem(at: Self.manifestURL)
        prepareIfNeeded()
    }

    /// Called by the coordinator when a direct exec fails synchronously, so a
    /// stale image cannot keep breaking the same tool. Hop to main because
    /// `images` drives the settings row.
    func invalidate(tool: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let index = self.images.firstIndex(where: { $0.tool == tool }) else { return }
            let removed = self.images.remove(at: index)
            self.removeFromTable(tool)
            self.saveManifest()
            self.logger.warning("AOJIT dropped stale image for \(removed.tool) at \(removed.path)")
        }
    }

    /// Lock-guarded snapshot check for callers on the execution actor.
    var hasImages: Bool {
        tableLock.lock()
        defer { tableLock.unlock() }
        return !byName.isEmpty
    }

    // MARK: Plan

    /// Returns a direct-exec plan when — and only when — the command is a
    /// single imaged tool invocation that does not depend on shell semantics
    /// or on the working directory.
    func plan(for command: String) -> AOJITPlan? {
        guard isEnabled else { return nil }

        tableLock.lock()
        let table = byName
        tableLock.unlock()
        guard !table.isEmpty else { return nil }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: { Self.rejectedCharacters.contains($0) }) else { return nil }
        guard let tokens = Self.tokenize(trimmed), let head = tokens.first else { return nil }

        let name = (head as NSString).lastPathComponent
        guard let image = table[name] else { return nil }
        // An explicit path must agree with the precompiled image, otherwise the
        // caller is targeting a different binary (e.g. a Python venv shim).
        if head.hasPrefix("/"), head != image.path { return nil }

        let arguments = Array(tokens.dropFirst())
        guard Self.argumentsAreSafe(arguments, tool: name) else { return nil }
        return AOJITPlan(tool: name, executable: image.path, arguments: arguments)
    }

    // MARK: Parsing

    private static func parseProbe(_ output: String) -> [AOJITImage] {
        var result: [AOJITImage] = []
        var seen = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let tool = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard !tool.isEmpty, path.hasPrefix("/"), seen.insert(tool).inserted else { continue }
            result.append(AOJITImage(tool: tool, path: path, warm: true))
        }
        return result
    }

    /// Splits on whitespace while honouring single and double quotes. Returns
    /// nil for unbalanced quotes, which are left to the shell.
    private static func tokenize(_ command: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false

        for character in command {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasToken = true
                continue
            }
            if character == " " || character == "\t" {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(character)
            hasToken = true
        }

        guard quote == nil else { return nil }
        if hasToken { tokens.append(current) }
        return tokens.isEmpty ? nil : tokens
    }

    private static func argumentsAreSafe(_ arguments: [String], tool: String) -> Bool {
        var index = 0

        // grep/sed/awk take a pattern or script first; it is not a path.
        if tool == "grep" || tool == "sed" || tool == "awk" {
            while index < arguments.count, arguments[index].hasPrefix("-") { index += 1 }
            guard index < arguments.count else { return false }
            index += 1
        }

        var sawAbsolutePath = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if argument.hasPrefix("-") { continue }
            if argument.hasPrefix("/") {
                sawAbsolutePath = true
                continue
            }
            if pathOnlyTools.contains(tool) { return false }
            // grep/find accept bare words as patterns; a relative path would
            // resolve against the wrong directory, so refuse anything with a
            // slash in it.
            if argument.contains("/") { return false }
        }
        return sawAbsolutePath
    }

    // MARK: Manifest

    private static var manifestURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("AOJIT", isDirectory: true)
            .appendingPathComponent("images.json")
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: Self.manifestURL) else { return }
        guard let decoded = try? JSONDecoder().decode([AOJITImage].self, from: data) else { return }
        images = decoded
        replaceTable(Dictionary(uniqueKeysWithValues: decoded.map { ($0.tool, $0) }))
        if let attributes = try? FileManager.default.attributesOfItem(atPath: Self.manifestURL.path),
           let date = attributes[.modificationDate] as? Date {
            lastPreparedAt = date
        }
    }

    // MARK: Table

    private func replaceTable(_ table: [String: AOJITImage]) {
        tableLock.lock()
        byName = table
        tableLock.unlock()
    }

    private func removeFromTable(_ tool: String) {
        tableLock.lock()
        byName[tool] = nil
        tableLock.unlock()
    }

    private func saveManifest() {
        let url = Self.manifestURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(images)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("AOJIT manifest write failed: \(error.localizedDescription)")
        }
    }
}
