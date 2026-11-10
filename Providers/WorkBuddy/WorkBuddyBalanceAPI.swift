import Foundation
import CoreFoundation

/// Account credit packages, not the API-key relay /status response.
/// Protocol evidence: docs/workbuddy-balance-reference.md.
@MainActor
enum WorkBuddyBalanceAPI {
    private static let session = WorkBuddyHTTP.makeSession(configuration: .ephemeral)

    static func cacheIdentity(instanceId: String) -> String {
        let generation = WorkBuddyOAuthManager.shared.credentialSession(instanceId: instanceId)
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self) else {
            return "signed-out|\(generation)"
        }
        // Access-token rotation must not discard a successful same-account query.
        return "\(generation)|\(token.realm.rawValue)|\(token.uid)|\(token.enterpriseID ?? "")"
    }

    static func fetch(instanceId: String, session injectedSession: URLSession? = nil) async throws -> ProviderAPIQuota {
        let expected = cacheIdentity(instanceId: instanceId)
        let credentials = try await WorkBuddyOAuthManager.shared.validCredentials(instanceId: instanceId)
        let paths = credentials.realm == .cn
            ? ["/v2/billing/meter/get-user-resource"]
            : ["/billing/meter/get-user-resource", "/v2/billing/meter/get-user-resource"]
        var path = paths[0]
        var remaining: Decimal = 0
        var used: Decimal = 0
        var total: Decimal = 0
        let now = Date()
        for page in 1...10 {
            try Task.checkCancellation()
            guard cacheIdentity(instanceId: instanceId) == expected else { throw CancellationError() }
            var request = try Self.request(credentials: credentials, path: path, page: page, now: now)
            var (data, response) = try await (injectedSession ?? session).data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404, paths.count == 2, path == paths[0] {
                path = paths[1]
                request = try self.request(credentials: credentials, path: path, page: page, now: now)
                (data, response) = try await (injectedSession ?? session).data(for: request)
            }
            try Task.checkCancellation()
            guard cacheIdentity(instanceId: instanceId) == expected else { throw CancellationError() }
            guard let http = response as? HTTPURLResponse else { throw invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw WorkBuddyError.http(http.statusCode) }
            let payload = try WorkBuddyHTTP.payload(from: data)
            let result = try parse(payload: payload, sourcePath: path)
            remaining += result.quota.remaining ?? 0
            used += result.quota.used ?? 0
            total += result.quota.total ?? 0
            if result.count < 100 {
                return ProviderAPIQuota(remaining: remaining, total: total, used: used,
                    currency: "credits", sourcePath: path, updatedAt: Date())
            }
        }
        throw WorkBuddyError.message("WorkBuddy 积分套餐过多，本次查询未取全，请稍后重试。")
    }

    static func request(credentials: WorkBuddyTokenStorage, path: String, page: Int, now: Date) throws -> URLRequest {
        let host = credentials.realm == .cn ? "https://www.codebuddy.cn" : "https://www.workbuddy.ai"
        let allowed = credentials.realm == .cn ? ["/v2/billing/meter/get-user-resource"]
            : ["/billing/meter/get-user-resource", "/v2/billing/meter/get-user-resource"]
        guard allowed.contains(path), let url = URL(string: host + path) else { throw invalidResponse }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "PageNumber": page, "PageSize": 100, "ProductCode": "p_tcaca", "Status": [0, 3],
            "PackageEndTimeRangeBegin": formatter.string(from: now),
            "PackageEndTimeRangeEnd": formatter.string(from: now.addingTimeInterval(365 * 101 * 86400))
        ])
        var headers = ["Authorization": "Bearer \(credentials.accessToken)", "Content-Type": "application/json",
            "Accept": "application/json", "X-CodeBuddy-Request": "1", "X-User-Id": credentials.uid,
            "User-Agent": "WorkBuddy/5.5.4", "Accept-Language": credentials.realm == .cn ? "zh-CN" : "en-US"]
        if let enterprise = credentials.enterpriseID, !enterprise.isEmpty {
            headers["X-Enterprise-Id"] = enterprise
            headers["X-Tenant-Id"] = enterprise
        }
        if let domain = credentials.domain, !domain.isEmpty { headers["X-Domain"] = domain }
        if let device = credentials.deviceToken, !device.isEmpty { headers["X-Device-Token"] = device }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Requires the documented envelope and numeric package fields. Missing or
    /// malformed account data never becomes a fabricated zero balance.
    static func parse(payload: Data, sourcePath: String) throws -> (quota: ProviderAPIQuota, count: Int) {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let response = object["Response"] as? [String: Any], response["Error"] == nil,
              let data = response["Data"] as? [String: Any],
              let accounts = data["Accounts"] as? [[String: Any]] else { throw invalidResponse }
        var remaining: Decimal = 0
        var used: Decimal = 0
        var total: Decimal = 0
        for account in accounts {
            let cycleSize = try number(account, "CycleCapacitySize", optional: true)
            let prefix = (cycleSize ?? 0) > 0 ? "CycleCapacity" : "Capacity"
            guard let size = try number(account, prefix + "Size"),
                  let remain = try number(account, prefix + "Remain") else { throw invalidResponse }
            let reportedUsed = try number(account, prefix + "Used", optional: true)
            guard remain <= size else { throw invalidResponse }
            let consumed = max(reportedUsed ?? 0, size - remain)
            guard consumed <= size else { throw invalidResponse }
            remaining += min(remain, size - consumed)
            used += consumed
            total += size
        }
        return (ProviderAPIQuota(remaining: remaining, total: total, used: used, currency: "credits",
            sourcePath: sourcePath, updatedAt: Date()), accounts.count)
    }

    private static func number(_ object: [String: Any], _ key: String, optional: Bool = false) throws -> Decimal? {
        guard let raw = object[key] else {
            if optional { return nil }
            throw invalidResponse
        }
        let value: Decimal?
        if let numeric = raw as? NSNumber, CFGetTypeID(numeric) != CFBooleanGetTypeID() {
            value = numeric.decimalValue
        } else if let string = raw as? String,
                  string.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil {
            value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        } else { throw invalidResponse }
        guard let value, !value.isNaN, value >= 0, value <= Decimal(1_000_000_000_000_000_000 as Int64) else { throw invalidResponse }
        return value
    }

    private static var invalidResponse: WorkBuddyError {
        .message("WorkBuddy 积分接口返回的数据格式异常，未显示余额。")
    }
}
