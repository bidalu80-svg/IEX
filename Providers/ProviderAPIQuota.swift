import Foundation
import Combine
import CryptoKit
import CoreFoundation

struct ProviderAPIQuota: Equatable, Sendable {
    let remaining: Decimal?
    let total: Decimal?
    let used: Decimal?
    let currency: String
    let sourcePath: String
    let updatedAt: Date

    var displayAmount: Decimal? {
        remaining ?? total.flatMap { totalValue in
            used.map { totalValue - $0 }
        }
    }
}

enum ProviderAPIQuotaState: Equatable {
    case idle
    case loading
    case loaded(ProviderAPIQuota)
    case unavailable(String)
}

/// Best-effort quota reader for API-key based OpenAI-compatible providers.
/// Quota endpoints are not part of the OpenAI compatibility contract, so this
/// probes common relay paths and accepts several response shapes without ever
/// logging or returning the API key.
@MainActor
final class ProviderAPIQuotaStore: ObservableObject {
    static let shared = ProviderAPIQuotaStore()

    @Published private(set) var states: [String: ProviderAPIQuotaState] = [:]
    private var activeRequests: [String: UUID] = [:]
    private var signatures: [String: String] = [:]
    private var lastAttempts: [String: Date] = [:]
    private func signature(_ instance: ProviderInstance) -> String {
        let key = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id) ?? ""
        let settings = "\(instance.providerType)|\(instance.customBaseURL ?? "")|\(instance.appendV1Suffix)|\(instance.azureMode)|\(instance.customUserAgent ?? "")|" + key
        return SHA256.hash(data: Data(settings.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private init() {}

    func state(for instanceID: String) -> ProviderAPIQuotaState {
        states[instanceID] ?? .idle
    }

    func refreshIfNeeded(_ instance: ProviderInstance) async {
        let current = signature(instance)
        if signatures[instance.id] == current {
            switch state(for: instance.id) {
            case .loading: return
            case .loaded(let quota) where Date().timeIntervalSince(quota.updatedAt) < 300: return
            case .unavailable where Date().timeIntervalSince(lastAttempts[instance.id] ?? .distantPast) < 60: return
            default: break
            }
        }
        await refresh(instance)
    }

    func refresh(_ instance: ProviderInstance) async {
        while activeRequests.count >= 3 && activeRequests[instance.id] == nil {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let current = signature(instance)
        guard activeRequests[instance.id] == nil || signatures[instance.id] != current else { return }
        signatures[instance.id] = current
        lastAttempts[instance.id] = Date()
        guard instance.credentialType == .apiKey else {
            states[instance.id] = .unavailable("此服务商使用 OAuth 登录，不支持 API Key 额度查询。")
            return
        }
        guard let apiKey = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id), !apiKey.isEmpty else {
            states[instance.id] = .unavailable("尚未配置 API Key。")
            return
        }

        let requestID = UUID()
        activeRequests[instance.id] = requestID
        states[instance.id] = .loading
        defer { if activeRequests[instance.id] == requestID { activeRequests[instance.id] = nil } }

        do {
            let quota = try await ProviderAPIQuotaClient.fetch(instance: instance, apiKey: apiKey)
            try Task.checkCancellation()
            guard activeRequests[instance.id] == requestID else { return }
            guard signature(instance) == current else { states[instance.id] = .idle; return }
            states[instance.id] = .loaded(quota)
        } catch {
            guard activeRequests[instance.id] == requestID else { return }
            states[instance.id] = Task.isCancelled ? .idle : .unavailable(error.localizedDescription)
        }
    }
}

@MainActor
enum ProviderAPIQuotaClient {
    /// One probe target. Paths are relative to the provider root (the base
    /// URL with a trailing `/v1` stripped), because the shapes below live at
    /// different depths: `/status` at the root, `/v1/credits` one level in.
    private struct Candidate {
        let path: String
        let shape: Shape
    }

    /// Response shapes that generic key matching cannot read.
    private enum Shape {
        /// Flat object; keys like `balance` / `total_available` / `credits`.
        case generic
        /// `{"balance_infos":[{"currency":"CNY","total_balance":"12.34"}]}`
        case deepSeek
        /// `{"accounts":[{"credits":123,"credits_total":456}]}`
        case workbuddyPool
        /// `{"data":{"quota":500000,"used_quota":0}}` in 1/500000 USD units.
        case newAPI
    }

    private enum QuotaError: LocalizedError {
        case unsupported
        case http(Int)
        case invalidResponse
        case unrecognizedShape

        var errorDescription: String? {
            switch self {
            case .unsupported: return "此服务商没有可识别的额度接口。"
            case .http(let code): return "额度接口返回 HTTP \(code)。"
            case .invalidResponse: return "额度接口返回的数据异常。"
            case .unrecognizedShape: return "额度接口已响应，但返回格式暂未识别。"
            }
        }
    }

    static func fetch(instance: ProviderInstance, apiKey: String) async throws -> ProviderAPIQuota {
        guard let base = baseURL(for: instance) else { throw QuotaError.unsupported }
        let root = stripV1Suffix(base)

        // Distinctive gateway shapes run first: a relay that implements only
        // one route would otherwise burn eight 404s before reaching it.
        let shaped: [Candidate] = [
            Candidate(path: "/status", shape: .workbuddyPool),
            Candidate(path: "/user/balance", shape: .deepSeek),
            Candidate(path: "/api/user/self", shape: .newAPI),
            Candidate(path: "/api/v1/user/self", shape: .newAPI),
            Candidate(path: "/user/info", shape: .newAPI),
        ]
        let generic: [Candidate] = [
            Candidate(path: "/v1/credits", shape: .generic),
            Candidate(path: "/credits", shape: .generic),
            Candidate(path: "/api/credits", shape: .generic),
            Candidate(path: "/v1/dashboard/billing/credit_grants", shape: .generic),
            Candidate(path: "/dashboard/billing/credit_grants", shape: .generic),
            Candidate(path: "/usage", shape: .generic),
            Candidate(path: "/account/balance", shape: .generic),
            Candidate(path: "/balance", shape: .generic),
        ]

        var lastError: Error = QuotaError.unsupported

        for candidate in shaped + generic {
            try Task.checkCancellation()
            let (quota, error) = await probe(root: root, candidate: candidate,
                                             instance: instance, apiKey: apiKey)
            if let quota { return quota }
            if let error { lastError = error }
        }

        // OpenAI's billing pair needs two requests, so it cannot be a single
        // candidate: `subscription` carries the ceiling, `usage` the spend.
        let (billing, billingError) = await probeBilling(root: root, instance: instance, apiKey: apiKey)
        if let billing { return billing }
        if let billingError { lastError = billingError }

        throw lastError
    }

    private static func probe(root: String,
                              candidate: Candidate,
                              instance: ProviderInstance,
                              apiKey: String) async -> (ProviderAPIQuota?, Error?) {
        guard let url = URL(string: root + candidate.path) else { return (nil, nil) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url: url, instance: instance, apiKey: apiKey))
            guard let http = response as? HTTPURLResponse else { return (nil, QuotaError.invalidResponse) }
            guard (200..<300).contains(http.statusCode) else {
                // 404/405 only mean "this gateway does not implement the
                // route"; the next candidate is usually the right one.
                return (nil, QuotaError.http(http.statusCode))
            }
            let object = try JSONSerialization.jsonObject(with: data)
            guard let parsed = parse(object: object, shape: candidate.shape, sourcePath: candidate.path),
                  parsed.displayAmount != nil else {
                return (nil, QuotaError.unrecognizedShape)
            }
            return (parsed, nil)
        } catch {
            if Task.isCancelled { return (nil, CancellationError()) }
            return (nil, error)
        }
    }

    private static func probeBilling(root: String,
                                     instance: ProviderInstance,
                                     apiKey: String) async -> (ProviderAPIQuota?, Error?) {
        guard let subscriptionURL = URL(string: root + "/dashboard/billing/subscription") else {
            return (nil, nil)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url: subscriptionURL, instance: instance, apiKey: apiKey))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return (nil, QuotaError.http((response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            let subscription = try JSONSerialization.jsonObject(with: data)

            // Usage is optional: a gateway may expose only the ceiling.
            var usage: Any?
            if let usageURL = URL(string: root + "/dashboard/billing/usage"),
               let (usageData, usageResponse) = try? await URLSession.shared.data(for: request(url: usageURL, instance: instance, apiKey: apiKey)),
               let usageHTTP = usageResponse as? HTTPURLResponse,
               (200..<300).contains(usageHTTP.statusCode) {
                usage = try? JSONSerialization.jsonObject(with: usageData)
            }

            guard let parsed = parseBilling(subscription: subscription, usage: usage,
                                            sourcePath: "/dashboard/billing/subscription"),
                  parsed.displayAmount != nil else {
                return (nil, QuotaError.unrecognizedShape)
            }
            return (parsed, nil)
        } catch {
            if Task.isCancelled { return (nil, CancellationError()) }
            return (nil, error)
        }
    }

    private static func request(url: URL, instance: ProviderInstance, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(instance.customUserAgent ?? "Ze-iOS", forHTTPHeaderField: "User-Agent")
        if instance.azureMode {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Root URL for quota probes. Every configured instance is eligible: a
    /// relay fronting an OpenAI-compatible API can expose a balance route even
    /// when its provider type is Anthropic or Gemini. Types with no public
    /// quota endpoint and no custom URL still return nil.
    private static func baseURL(for instance: ProviderInstance) -> String? {
        if let custom = instance.customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return instance.appendV1Suffix ? stripV1Suffix(custom) : custom
        }
        switch instance.providerType {
        case .openAI, .openAIResponses: return "https://api.openai.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .xAI: return "https://api.x.ai"
        case .kimiCode: return "https://api.moonshot.cn"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .antigravity, .githubCopilot, .unsupported: return nil
        }
    }

    private static func stripV1Suffix(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix("/v1") { result.removeLast(3) }
        return result
    }

    static func parse(object: Any, sourcePath: String) -> ProviderAPIQuota? {
        parse(object: object, shape: .generic, sourcePath: sourcePath)
    }

    private static func parse(object: Any, shape: Shape, sourcePath: String) -> ProviderAPIQuota? {
        switch shape {
        case .deepSeek:      return parseDeepSeek(object, sourcePath: sourcePath)
        case .workbuddyPool: return parseWorkbuddyPool(object, sourcePath: sourcePath)
        case .newAPI:        return parseNewAPI(object, sourcePath: sourcePath)
        case .generic:       return parseGeneric(object, sourcePath: sourcePath)
        }
    }

    /// `{"balance_infos":[{"currency":"CNY","total_balance":"12.34",
    /// "granted_balance":"0.00","topped_up_balance":"12.34"}]}`
    private static func parseDeepSeek(_ object: Any, sourcePath: String) -> ProviderAPIQuota? {
        guard let root = object as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]],
              let info = infos.first,
              let remaining = decimal(info["total_balance"]) else { return nil }
        let granted = decimal(info["granted_balance"])
        let toppedUp = decimal(info["topped_up_balance"])
        return ProviderAPIQuota(remaining: remaining,
                                total: granted.map { $0 + (toppedUp ?? 0) },
                                used: nil,
                                currency: (info["currency"] as? String ?? "CNY").uppercased(),
                                sourcePath: sourcePath,
                                updatedAt: Date())
    }

    /// `{"accounts":[{"credits":123.4,"credits_total":200,"cooling":false,
    /// "disabled":false}]}` — the pool's numbers are the caller's allowance.
    private static func parseWorkbuddyPool(_ object: Any, sourcePath: String) -> ProviderAPIQuota? {
        guard let root = object as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]],
              !accounts.isEmpty else { return nil }
        var remaining: Decimal = 0
        var total: Decimal = 0
        var counted = 0
        for account in accounts {
            guard let credits = decimal(account["credits"]) else { continue }
            counted += 1
            remaining += credits
            if let quota = decimal(account["credits_total"]), quota > 0 { total += quota }
        }
        guard counted > 0 else { return nil }
        let pooled = total > 0 ? total : nil
        return ProviderAPIQuota(remaining: max(remaining, 0),
                                total: pooled,
                                used: pooled.map { max($0 - remaining, 0) },
                                currency: "credits",
                                sourcePath: sourcePath,
                                updatedAt: Date())
    }

    /// New API / One API express quota in 1/500000 USD units.
    private static func parseNewAPI(_ object: Any, sourcePath: String) -> ProviderAPIQuota? {
        guard let root = object as? [String: Any] else { return nil }
        let data = (root["data"] as? [String: Any]) ?? root
        guard let quota = decimal(data["quota"]) else { return nil }
        let used = decimal(data["used_quota"]) ?? 0
        let unit = Decimal(500_000)
        return ProviderAPIQuota(remaining: quota / unit,
                                total: (quota + used) / unit,
                                used: used / unit,
                                currency: "USD",
                                sourcePath: sourcePath,
                                updatedAt: Date())
    }

    /// `{"hard_limit_usd":120.0}` + `{"total_usage":1234}` (cents).
    private static func parseBilling(subscription: Any, usage: Any?, sourcePath: String) -> ProviderAPIQuota? {
        guard let subscription = subscription as? [String: Any] else { return nil }
        let limit = decimal(subscription["hard_limit_usd"]) ?? decimal(subscription["soft_limit_usd"])
        guard let limit else { return nil }
        let usedCents = (usage as? [String: Any]).flatMap { decimal($0["total_usage"]) }
        return ProviderAPIQuota(remaining: limit,
                                total: limit,
                                used: usedCents.map { $0 / 100 },
                                currency: "USD",
                                sourcePath: sourcePath,
                                updatedAt: Date())
    }

    private static func parseGeneric(_ object: Any, sourcePath: String) -> ProviderAPIQuota? {
        let dictionaries = dictionaryCandidates(object)
        let remainingKeys = ["total_available", "remaining_balance", "remaining", "available", "balance", "credits_remaining", "credit_remaining", "total_balance"]
        let totalKeys = ["total_granted", "total_credits", "total", "limit", "quota", "credit_limit", "credits"]
        let usedKeys = ["total_used", "total_usage", "used", "spent", "usage", "consumed"]
        // Never subtract unrelated objects' totals and usages, nor mistake an
        // error payload's numeric code/boolean for a monetary balance.
        if let root = object as? [String: Any], root["error"] != nil || (root["success"] as? Bool) == false { return nil }
        for dictionary in dictionaries {
            let remaining = firstNumber(in: [dictionary], keys: remainingKeys)
            let total = firstNumber(in: [dictionary], keys: totalKeys)
            let used = firstNumber(in: [dictionary], keys: usedKeys)
            let resolvedRemaining = remaining ?? total.flatMap { totalValue in used.map { totalValue - $0 } }
            guard let resolvedRemaining, !resolvedRemaining.isNaN else { continue }
            let currency = firstString(in: [dictionary], keys: ["currency", "unit"])
                ?? firstString(in: dictionaries, keys: ["currency", "unit"]) ?? "USD"
            return ProviderAPIQuota(remaining: resolvedRemaining, total: total, used: used,
                                    currency: currency.uppercased(), sourcePath: sourcePath, updatedAt: Date())
        }
        return nil
    }

    private static func dictionaryCandidates(_ object: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 5 else { return }
            if let dictionary = value as? [String: Any] {
                result.append(dictionary)
                for nested in dictionary.values { visit(nested, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for nested in array.prefix(20) { visit(nested, depth: depth + 1) }
            }
        }
        visit(object, depth: 0)
        return result
    }

    private static func firstNumber(in dictionaries: [[String: Any]], keys: [String]) -> Decimal? {
        for key in keys {
            for dictionary in dictionaries {
                for (candidate, value) in dictionary where normalize(candidate) == normalize(key) {
                    if let number = decimal(value), !number.isNaN { return number }
                }
            }
        }
        return nil
    }

    private static func firstString(in dictionaries: [[String: Any]], keys: [String]) -> String? {
        let normalizedKeys = Set(keys.map(normalize))
        for dictionary in dictionaries {
            for (key, value) in dictionary where normalizedKeys.contains(normalize(key)) {
                if let string = value as? String, !string.isEmpty { return string }
            }
        }
        return nil
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// Accepts `Any?` on purpose: dictionary lookups (`info["credits"]`) yield
    /// an optional, and every caller means "nil is not a number".
    private static func decimal(_ value: Any?) -> Decimal? {
        guard let value else { return nil }
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.decimalValue
        }
        guard let value = value as? String else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$", options: .regularExpression) != nil else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}
