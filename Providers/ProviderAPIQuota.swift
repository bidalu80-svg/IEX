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
            guard activeRequests[instance.id] == requestID, signature(instance) == current else { return }
            states[instance.id] = .loaded(quota)
        } catch {
            guard activeRequests[instance.id] == requestID else { return }
            states[instance.id] = Task.isCancelled ? .idle : .unavailable(error.localizedDescription)
        }
    }
}

@MainActor
enum ProviderAPIQuotaClient {
    private struct Candidate {
        let path: String
        let includesV1: Bool
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
        let candidates = [
            Candidate(path: "usage", includesV1: true),
            Candidate(path: "credits", includesV1: true),
            Candidate(path: "account/balance", includesV1: true),
            Candidate(path: "balance", includesV1: true),
            Candidate(path: "dashboard/billing/credit_grants", includesV1: false),
            Candidate(path: "dashboard/billing/subscription", includesV1: false),
        ]
        var lastError: Error = QuotaError.unsupported

        for candidate in candidates {
            try Task.checkCancellation()
            guard let url = endpointURL(base: base, candidate: candidate, instance: instance) else { continue }
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

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw QuotaError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    lastError = QuotaError.http(http.statusCode)
                    continue
                }
                let object = try JSONSerialization.jsonObject(with: data)
                guard let parsed = parse(object: object, sourcePath: pathForDisplay(candidate, instance: instance)) else {
                    lastError = QuotaError.unrecognizedShape
                    continue
                }
                guard parsed.displayAmount != nil else { lastError = QuotaError.unrecognizedShape; continue }
                return parsed
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }

    private static func baseURL(for instance: ProviderInstance) -> String? {
        if let custom = instance.customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return instance.appendV1Suffix ? stripV1Suffix(custom) : custom
        }
        switch instance.providerType {
        case .openAI, .openAIResponses: return "https://api.openai.com"
        case .openRouter: return "https://openrouter.ai/api"
        case .xAI: return "https://api.x.ai"
        case .kimiCode: return "https://api.moonshot.cn"
        default: return nil
        }
    }

    private static func endpointURL(base: String, candidate: Candidate, instance: ProviderInstance) -> URL? {
        let urlString: String
        if candidate.includesV1 && instance.appendV1Suffix {
            urlString = URLBuilding.join(base, "/v1", "/\(candidate.path)")
        } else {
            urlString = URLBuilding.join(base, "/\(candidate.path)")
        }
        return URL(string: urlString)
    }

    private static func pathForDisplay(_ candidate: Candidate, instance: ProviderInstance) -> String {
        if candidate.includesV1 && instance.appendV1Suffix { return "/v1/\(candidate.path)" }
        return "/\(candidate.path)"
    }

    private static func stripV1Suffix(_ value: String) -> String {
        var result = value
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix("/v1") { result.removeLast(3) }
        return result
    }

    static func parse(object: Any, sourcePath: String) -> ProviderAPIQuota? {
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

    private static func decimal(_ value: Any) -> Decimal? {
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
