import Foundation
import Combine

struct ProviderAPIQuota: Equatable, Sendable {
    let remaining: Decimal?
    let total: Decimal?
    let used: Decimal?
    let currency: String
    let sourcePath: String
    let updatedAt: Date

    var displayAmount: Decimal? {
        remaining ?? total.flatMap { totalValue in
            used.map { max(0, totalValue - $0) }
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
    private var activeRequests: Set<String> = []

    private init() {}

    func state(for instanceID: String) -> ProviderAPIQuotaState {
        states[instanceID] ?? .idle
    }

    func refreshIfNeeded(_ instance: ProviderInstance) async {
        guard case .idle = state(for: instance.id) else { return }
        await refresh(instance)
    }

    func refresh(_ instance: ProviderInstance) async {
        guard !activeRequests.contains(instance.id) else { return }
        guard instance.credentialType == .apiKey else {
            states[instance.id] = .unavailable("此服务商使用 OAuth 登录，不支持 API Key 额度查询。")
            return
        }
        guard let apiKey = ProviderKeychainHelper.loadAPIKey(instanceId: instance.id), !apiKey.isEmpty else {
            states[instance.id] = .unavailable("尚未配置 API Key。")
            return
        }

        activeRequests.insert(instance.id)
        states[instance.id] = .loading
        defer { activeRequests.remove(instance.id) }

        do {
            let quota = try await ProviderAPIQuotaClient.fetch(instance: instance, apiKey: apiKey)
            states[instance.id] = .loaded(quota)
        } catch {
            states[instance.id] = .unavailable(error.localizedDescription)
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
            guard let url = endpointURL(base: base, candidate: candidate, instance: instance) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
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
                return parsed
            } catch {
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

    private static func parse(object: Any, sourcePath: String) -> ProviderAPIQuota? {
        let dictionaries = dictionaryCandidates(object)
        let remainingKeys = ["total_available", "remaining_balance", "remaining", "available", "balance", "credits_remaining", "credit_remaining"]
        let totalKeys = ["total_granted", "total", "limit", "quota", "credit_limit", "credits"]
        let usedKeys = ["total_used", "total_usage", "used", "spent", "usage", "consumed"]
        let remaining = firstNumber(in: dictionaries, keys: remainingKeys)
        let total = firstNumber(in: dictionaries, keys: totalKeys)
        let used = firstNumber(in: dictionaries, keys: usedKeys)
        guard remaining != nil || total != nil || used != nil else { return nil }
        let resolvedRemaining = remaining ?? total.flatMap { totalValue in
            used.map { max(0, totalValue - $0) }
        }
        let currency = firstString(in: dictionaries, keys: ["currency", "unit"])?.uppercased() ?? "USD"
        return ProviderAPIQuota(
            remaining: resolvedRemaining,
            total: total,
            used: used,
            currency: currency,
            sourcePath: sourcePath,
            updatedAt: Date()
        )
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
        let normalizedKeys = Set(keys.map(normalize))
        for dictionary in dictionaries {
            for (key, value) in dictionary where normalizedKeys.contains(normalize(key)) {
                if let number = decimal(value) { return number }
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
        if let value = value as? NSNumber { return value.decimalValue }
        guard let value = value as? String else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }
}
