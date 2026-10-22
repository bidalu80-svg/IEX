//
//  ContainerDNS.swift
//  ZeApp
//
//  [T-container-dns] DNS mode for the container network.
//
//  /etc/resolv.conf inside iSH is a file-level bind mount to
//  Library/ZeChat/dns/resolv.conf, so the app writes the host file and the
//  guest sees it immediately. Automatic delegates to `ISHKernel.refreshDns()`
//  (the existing system-resolver path, including its public-DNS fallback);
//  Custom pins the user's servers through `setCustomDns:`.
//
//  NetworkMonitor already refreshes the file on every path change. In Custom
//  mode it must stay out of the way, otherwise a Wi-Fi → cellular switch would
//  silently replace the pinned servers — hence `isCustomMode`, which reads the
//  stored preference without touching the singleton from another queue.
//

import Combine
import Darwin
import Foundation

enum ContainerDNSMode: String, CaseIterable, Identifiable {
    case automatic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .custom:    return String(localized: "Custom")
        }
    }
}

final class ContainerDNSSettings: ObservableObject {
    static let shared = ContainerDNSSettings()

    private static let modeKey = "containerDNS.mode"
    private static let serversKey = "containerDNS.servers"

    /// Safe to read from any queue: it goes straight to UserDefaults instead of
    /// the published property.
    static var isCustomMode: Bool {
        (UserDefaults.standard.string(forKey: modeKey) ?? "") == ContainerDNSMode.custom.rawValue
    }

    @Published var mode: ContainerDNSMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            apply()
        }
    }

    /// Raw text as typed, so the editor keeps the user's line breaks.
    @Published var customText: String {
        didSet {
            UserDefaults.standard.set(customText, forKey: Self.serversKey)
        }
    }

    @Published private(set) var lastApplied: Date?
    @Published private(set) var lastError: String?

    private init() {
        let defaults = UserDefaults.standard
        mode = ContainerDNSMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .automatic
        customText = defaults.string(forKey: Self.serversKey) ?? ""
    }

    // MARK: Validation

    /// Splits on newlines, commas and whitespace, keeps valid IPv4/IPv6
    /// literals, and de-duplicates while preserving order.
    static func validServers(from text: String) -> [String] {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
            .map(String.init)

        var seen = Set<String>()
        return tokens.filter { token in
            guard isValidAddress(token), seen.insert(token).inserted else { return false }
            return true
        }
    }

    static func isValidAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, text, &v6) == 1
    }

    // MARK: Apply

    /// Rewrites /etc/resolv.conf for the current mode. Called when the mode
    /// changes, when the settings page appears, and after a custom save.
    func apply() {
        guard ISHKernel.shared.isBooted else {
            lastError = String(localized: "The container is not running yet.")
            return
        }

        switch mode {
        case .automatic:
            ISHKernel.shared.refreshDns()
            lastApplied = Date()
            lastError = nil

        case .custom:
            let servers = Self.validServers(from: customText)
            guard !servers.isEmpty else {
                lastError = String(localized: "Enter at least one DNS server. System DNS stays in use until then.")
                return
            }
            ISHKernel.shared.setCustomDns(servers)
            lastApplied = Date()
            lastError = nil
        }
    }
}
