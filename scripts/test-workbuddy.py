#!/usr/bin/env python3
"""Compile production WorkBuddy auth/catalog/adapter and run offline fixtures.

Requires the macOS Swift toolchain; no live account or network calls are used.
Only unrelated application storage/model dependencies are stubbed.
"""
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
swift = shutil.which("swiftc")
if swift is None:
    raise SystemExit("WorkBuddy fixtures require swiftc (run on macOS CI).")

SUPPORT = r'''
import Foundation
/// Intercept every URL, including unexpected ones: fixtures never fall back to
/// real HTTP. The session explicitly installs this protocol; no global registration is used.
final class WorkBuddyFixtureProtocol: URLProtocol, @unchecked Sendable {
    enum Scenario { case login, cancel, stateFailure, billing, billingDenied, billingMalformed, billingFallback, billingHTTPDenied, billingDelayed, billingPages, billingExactPage, billingTooMany }
    private static let lock = NSLock()
    private static var scenario: Scenario = .login
    private static var counts: [String: Int] = [:]

    static func reset(_ value: Scenario) {
        lock.lock(); defer { lock.unlock() }
        scenario = value
        counts = [:]
    }
    static func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[path, default: 0]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let length = stream.read(&buffer, maxLength: buffer.count)
            guard length >= 0 else { return nil }
            if length == 0 { break }
            data.append(contentsOf: buffer.prefix(length))
        }
        return data
    }
    private static func response(for request: URLRequest) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let url = request.url else { throw URLError(.badURL) }
        guard url.scheme == "https", ["copilot.tencent.com", "www.workbuddy.ai", "www.codebuddy.cn"].contains(url.host ?? "") else {
            throw URLError(.unsupportedURL)
        }
        let path = url.path
        counts[path, default: 0] += 1
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch path {
        case "/v2/billing/meter/get-user-resource", "/billing/meter/get-user-resource":
            guard request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-balance-access",
                  request.value(forHTTPHeaderField: "X-User-Id") == "balance-user",
                  request.value(forHTTPHeaderField: "X-Refresh-Token") == nil,
                  let body = requestBody(request),
                  let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  json["ProductCode"] as? String == "p_tcaca",
                  let page = json["PageNumber"] as? Int, page >= 1 else { throw URLError(.badServerResponse) }
            if scenario == .billingPages || scenario == .billingExactPage || scenario == .billingTooMany {
                let count = scenario == .billingTooMany || page == 1 ? 100 : (scenario == .billingExactPage ? 0 : 1)
                let rows = Array(repeating: ["CapacitySize":2,"CapacityRemain":1,"CapacityUsed":1], count:count)
                return ["code":0, "data":["Response":["Data":["Accounts":rows]]]]
            }
            if scenario == .billingDenied { return ["code":401, "msg":"sensitive-token", "data":[:]] }
            if scenario == .billingMalformed { return ["code":0, "data":["Response":["Data":[:]]]] }
            return ["code":0, "data":["Response":["Data":["Accounts":[
                ["CapacitySize":100, "CapacityRemain":75, "CapacityUsed":25],
                ["CapacitySize":999, "CapacityRemain":999, "CycleCapacitySize":20, "CycleCapacityRemain":8, "CycleCapacityUsed":12]
            ]]]]]

        case "/v2/plugin/auth/state":
            guard request.httpMethod == "POST", query.contains(where: { $0.name == "platform" && $0.value == "CLI" }) else { throw URLError(.badURL) }
            if scenario == .stateFailure { return ["code":11217, "msg":"login ing...", "data": NSNull()] }
            let host = url.host == "copilot.tencent.com" ? "www.codebuddy.cn" : "www.workbuddy.ai"
            return ["code":0, "data":["state":"fixture-state", "authUrl":"https://\(host)/fixture-authorize"]]
        case "/v2/plugin/auth/token":
            guard scenario == .login, request.httpMethod == "GET",
                  query.contains(where: { $0.name == "state" && $0.value == "fixture-state" }) else { throw URLError(.badURL) }
            if counts[path, default: 0] <= 2 { return ["code":11217, "msg":"login ing...", "data":NSNull()] }
            return ["code":0, "data":["accessToken":"fixture-login-access", "refreshToken":"fixture-login-refresh", "expiresIn":3600]]
        case "/v2/plugin/login/account":
            guard scenario == .login, request.httpMethod == "GET",
                  request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-login-access" else { throw URLError(.userAuthenticationRequired) }
            return ["code":0, "data":["uid":"fixture-login-user", "enterpriseId":"", "nickname":"Fixture"]]
        default:
            throw URLError(.unsupportedURL)
        }
    }

    override func startLoading() {
        do {
            let object = try Self.response(for: request)
            Self.lock.lock()
            let currentScenario = Self.scenario
            Self.lock.unlock()
            if currentScenario == .billingDelayed { Thread.sleep(forTimeInterval: 0.3) }
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let url = request.url else { throw URLError(.badURL) }
            let status = currentScenario == .billingHTTPDenied ? 401 : (currentScenario == .billingFallback && url.path == "/billing/meter/get-user-resource" ? 404 : 200)
            let response = HTTPURLResponse(url:url, statusCode:status, httpVersion:"HTTP/1.1", headerFields:["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive:response, cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self, didLoad:data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError:error)
        }
    }
}
struct ModelModality: OptionSet, Sendable {
    let rawValue: Int
    static let textOnly = ModelModality(rawValue: 3)
    static let imageInput = ModelModality(rawValue: 4)
}
struct LLMModel: Sendable {
    let id: String
    let displayName: String
    let provider: String
    var modalityOverride: ModelModality?
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var supportsReasoning: Bool?
    var interleavedReasoningField: String?
}
func modelDisplayName(from id: String) -> String { id }
@MainActor enum ProviderKeychainHelper {
    static var values: [String: Data] = [:]
    static func loadOAuthToken<T: Codable>(instanceId: String, as type: T.Type) -> T? {
        values[instanceId].flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    static func saveOAuthToken<T: Codable>(_ token: T, instanceId: String) {
        values[instanceId] = try? JSONEncoder().encode(token)
    }
    static func deleteOAuthToken(instanceId: String) { values[instanceId] = nil }
}
@main struct Fixture {
    @MainActor static func main() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        func expectFailure(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch {}
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkBuddyFixtureProtocol.self]
        let loginManager = WorkBuddyOAuthManager(configuration: configuration)
        let billingSession = WorkBuddyHTTP.makeSession(configuration: configuration)
        for realm in WorkBuddyRealm.allCases {
            let token = WorkBuddyTokenStorage(accessToken: "fixture-balance-access", refreshToken: "never-send",
                expiresAt: Date().addingTimeInterval(3600), realm: realm, uid: "balance-user",
                enterpriseID: "enterprise", domain: "domain", nickname: nil, deviceToken: nil)
            let id = "balance-" + realm.rawValue
            ProviderKeychainHelper.saveOAuthToken(token, instanceId: id)
            WorkBuddyFixtureProtocol.reset(.billing)
            let quota = try await WorkBuddyBalanceAPI.fetch(instanceId: id, session: billingSession)
            check(quota.remaining == 83 && quota.total == 120 && quota.used == 37 && quota.currency == "credits", "real OAuth billing response uses active package sums")
            let path = realm == .cn ? "/v2/billing/meter/get-user-resource" : "/billing/meter/get-user-resource"
            check(WorkBuddyFixtureProtocol.count(path) == 1, "correct CN/global billing path")
            let request = try WorkBuddyBalanceAPI.request(credentials: token, path: path, page: 1, now: Date(timeIntervalSince1970: 0))
            check(request.url?.host == (realm == .cn ? "www.codebuddy.cn" : "www.workbuddy.ai"), "billing host separate from chat host")
            check(request.value(forHTTPHeaderField: "X-Enterprise-Id") == "enterprise" && request.value(forHTTPHeaderField: "X-Tenant-Id") == "enterprise", "enterprise account headers")
            check(request.value(forHTTPHeaderField: "X-Device-Token") == nil, "no invented device credential")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            check(body["PackageEndTimeRangeBegin"] as? String == "1970-01-01 08:00:00", "billing filter uses UTC+8 independent of device timezone")
            for scenario in [WorkBuddyFixtureProtocol.Scenario.billingDenied, .billingMalformed, .billingHTTPDenied] {
                WorkBuddyFixtureProtocol.reset(scenario)
                do { _ = try await WorkBuddyBalanceAPI.fetch(instanceId:id, session:billingSession); preconditionFailure("billing error must not become zero") }
                catch { check(!error.localizedDescription.contains("sensitive-token"), "billing error redacts server content") }
            }
            if realm == .global {
                WorkBuddyFixtureProtocol.reset(.billingFallback)
                let fallback = try await WorkBuddyBalanceAPI.fetch(instanceId:id, session:billingSession)
                check(fallback.remaining == 83 && WorkBuddyFixtureProtocol.count("/v2/billing/meter/get-user-resource") == 1, "global HTTP404 uses documented v2 fallback")
            }
            for scenario in [WorkBuddyFixtureProtocol.Scenario.billingPages, .billingExactPage] {
                WorkBuddyFixtureProtocol.reset(scenario)
                let paged = try await WorkBuddyBalanceAPI.fetch(instanceId:id, session:billingSession)
                let expected: Decimal = scenario == .billingPages ? 101 : 100
                check(paged.remaining == expected && paged.total == expected * 2 && WorkBuddyFixtureProtocol.count(path) == 2, "billing pagination sums complete 100+1 or 100+0 pages")
            }
            WorkBuddyFixtureProtocol.reset(.billingTooMany)
            do { _ = try await WorkBuddyBalanceAPI.fetch(instanceId:id, session:billingSession); preconditionFailure("ten full pages must not publish partial total") }
            catch { check(WorkBuddyFixtureProtocol.count(path) == 10, "billing pagination bound returns error after ten full pages") }
            WorkBuddyFixtureProtocol.reset(.billingDelayed)
            let flight = Task { @MainActor in try await WorkBuddyBalanceAPI.fetch(instanceId:id, session:billingSession) }
            for _ in 0..<100 {
                if WorkBuddyFixtureProtocol.count(path) > 0 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            check(WorkBuddyFixtureProtocol.count(path) == 1, "delayed query actually reached HTTP")
            let oldIdentity = WorkBuddyBalanceAPI.cacheIdentity(instanceId:id)
            WorkBuddyOAuthManager.shared.logout(instanceId:id)
            check(WorkBuddyBalanceAPI.cacheIdentity(instanceId:id) != oldIdentity, "logout invalidates cached balance identity")
            do { _ = try await flight.value; preconditionFailure("late balance must not publish after logout") } catch is CancellationError {}
            do { _ = try await WorkBuddyBalanceAPI.fetch(instanceId:id, session:billingSession); preconditionFailure("signed-out balance must fail") } catch {}
        }
        let empty = try WorkBuddyBalanceAPI.parse(payload: Data(#"{"Response":{"Data":{"Accounts":[]}}}"#.utf8), sourcePath: "/fixture")
        check(empty.quota.remaining == 0, "explicit empty account collection is real zero")
        for json in ["{}", #"{"Response":{"Data":{}}}"#, #"{"Response":{"Error":{"Code":"Unauthorized"},"Data":{"Accounts":[]}}}"#,
            #"{"Response":{"Data":{"Accounts":[{"CapacitySize":10}]}}}"#,
            #"{"Response":{"Data":{"Accounts":[{"CapacitySize":10,"CapacityRemain":true}]}}}"#,
            #"{"Response":{"Data":{"Accounts":[{"CapacitySize":10,"CapacityRemain":"1oops"}]}}}"#,
            #"{"Response":{"Data":{"Accounts":[{"CapacitySize":10,"CapacityRemain":12}]}}}"#] {
            expectFailure("malformed billing response must fail") { _ = try WorkBuddyBalanceAPI.parse(payload:Data(json.utf8),sourcePath:"/fixture") }
        }
        print("WorkBuddy balance fixtures passed: CN/global, package sums, period precedence, malformed/errors, zero, fixed hosts, headers, 404 fallback, logout isolation.")


        for realm in WorkBuddyRealm.allCases {
            WorkBuddyFixtureProtocol.reset(.login)
            let id = "http-login-\(realm.rawValue)"
            var presented = false
            try await loginManager.login(instanceId:id, realm:realm) { _ in presented = true }
            check(presented, "real manager presents authorization URL")
            check(WorkBuddyFixtureProtocol.count("/v2/plugin/auth/state") == 1, "one state request")
            check(WorkBuddyFixtureProtocol.count("/v2/plugin/auth/token") == 3, "real loop survives two 11217 responses")
            check(WorkBuddyFixtureProtocol.count("/v2/plugin/login/account") == 1, "account lookup follows successful token")
            let saved = ProviderKeychainHelper.loadOAuthToken(instanceId:id, as:WorkBuddyTokenStorage.self)
            check(saved?.uid == "fixture-login-user" && saved?.realm == realm, "successful login persists matching account")
            loginManager.logout(instanceId:id)
        }
        WorkBuddyFixtureProtocol.reset(.cancel)
        do {
            try await loginManager.login(instanceId:"http-cancel") { _ in
                loginManager.cancelLogin(instanceId:"http-cancel")
            }
            preconditionFailure("present-time cancellation must stop real login")
        } catch is CancellationError {}
        check(WorkBuddyFixtureProtocol.count("/v2/plugin/auth/token") == 0, "cancelled login never polls")
        check(!loginManager.isAuthenticated(instanceId:"http-cancel"), "cancelled login never saves")
        WorkBuddyFixtureProtocol.reset(.stateFailure)
        do {
            try await loginManager.login(instanceId:"http-state-failure") { _ in
                preconditionFailure("failed state must not present authorization")
            }
            preconditionFailure("11217 at state endpoint must fail")
        } catch WorkBuddyError.business(let code, _) { check(code == 11217, "state failure code") }
        check(WorkBuddyFixtureProtocol.count("/v2/plugin/auth/token") == 0, "state business failure does not start polling")
        check(!loginManager.isAuthenticated(instanceId:"http-state-failure"), "failed state never saves")
        check(WorkBuddyOAuthManager.isPending("login ing"), "pending response")
        check(WorkBuddyOAuthManager.isPending("login ing..."), "observed CN/global pending punctuation")
        check(WorkBuddyOAuthManager.isPending("login ing…"), "pending Unicode ellipsis")
        check(!WorkBuddyOAuthManager.isPending("access denied"), "rejected authorization is not pending")
        check(!WorkBuddyOAuthManager.isPending("login ing denied"), "pending matching is bounded")
        // Actual anonymous CN/global response shape, with no live state/token.
        let pendingEnvelope = Data(#"{"code":11217,"msg":"login ing...","data":null}"#.utf8)
        var pendingCount = 0
        for envelope in [pendingEnvelope, pendingEnvelope, Data(#"{"code":0,"data":{"accessToken":"fixture-access"}}"#.utf8)] {
            do {
                let payload = try WorkBuddyHTTP.payload(from: envelope, authorizationPoll:true)
                let result = try JSONSerialization.jsonObject(with: payload) as? [String:String]
                check(result?["accessToken"] == "fixture-access", "pending transitions to success")
                check(pendingCount == 2, "both pending responses classified before success")
            } catch WorkBuddyError.authorizationPending {
                pendingCount += 1
            }
        }
        check(pendingCount == 2, "11217 continues polling")
        do {
            _ = try WorkBuddyHTTP.payload(from: pendingEnvelope)
            preconditionFailure("11217 outside auth poll must remain an error")
        } catch WorkBuddyError.business(let code, _) {
            check(code == 11217, "non-poll error code preserved")
        }
        for message in ["authorization_pending", "login ing...", "login ing"] {
            let envelope = try JSONSerialization.data(withJSONObject:["code":123, "msg":message])
            do {
                _ = try WorkBuddyHTTP.payload(from:envelope, authorizationPoll:true)
                preconditionFailure("known pending message")
            } catch WorkBuddyError.authorizationPending {}
        }
        for message in ["access denied", "state expired", "login ing denied", "secret-fixture-token"] {
            let envelope = try JSONSerialization.data(withJSONObject:["code":123, "msg":message])
            do {
                _ = try WorkBuddyHTTP.payload(from:envelope, authorizationPoll:true)
                preconditionFailure("denied and expired responses must fail")
            } catch WorkBuddyError.business(let code, let redacted) {
                check(code == 123 && !redacted.contains(message), "non-pending error redaction")
            }
        }
        check(WorkBuddyOAuthManager.isAuthorizationHost("www.codebuddy.cn", realm: .cn), "CN authorization domain")
        check(!WorkBuddyOAuthManager.isAuthorizationHost("codebuddy.cn.example.org", realm: .cn), "domain suffix attack")
        check(!WorkBuddyOAuthManager.isAuthorizationHost("www.workbuddy.ai", realm: .cn), "realm isolation")
        check(WorkBuddyOAuthManager.expiry(nil).timeIntervalSinceNow < 301, "unknown expiry bounded")
        let data = try WorkBuddyHTTP.payload(from: Data(#"{"code":0,"data":{"state":"fixture"}}"#.utf8))
        let envelopeObject = try JSONSerialization.jsonObject(with: data) as? [String:String]
        check(envelopeObject?["state"] == "fixture", "business envelope")
        expectFailure("missing business code") { _ = try WorkBuddyHTTP.payload(from: Data(#"{"data":{}}"#.utf8)) }
        do {
            _ = try WorkBuddyHTTP.payload(from: Data(#"{"code":123,"msg":"secret-fixture-token","data":{}}"#.utf8))
            preconditionFailure("business failure must throw")
        } catch { check(!error.localizedDescription.contains("secret-fixture-token"), "error redaction") }

        let rows: [[String:Any]] = [
            ["id":"vision", "name":"Vision", "supportsImages":true, "supportsReasoning":true, "supportsToolCall":true, "maxInputTokens":128000, "maxOutputTokens":8192],
            ["id":"text", "supportsImages":false, "supportsToolCall":false],
            ["id":"disabled", "disabled":true], ["id":"disabled", "disabled":false],
            ["id":"nes-test"], ["id":"image-gen", "tags":["text-to-image"]],
            ["id":"tiny", "maxOutputTokens":128]
        ]
        let parsed = WorkBuddyModelsAPI.parseModels(rows)
        check(Set(parsed.models.map(\.id)) == Set(["vision", "text"]), "catalog exclusions")
        check(parsed.capabilities["text"]?.supportsTools == false, "explicit tool capability")
        check(parsed.models.first(where: {$0.id == "vision"})?.modalityOverride?.contains(.imageInput) == true, "vision metadata")
        check(parsed.models.first(where: {$0.id == "text"})?.modalityOverride?.contains(.imageInput) == false, "text metadata")
        let token = WorkBuddyTokenStorage(accessToken:"fixture-access", refreshToken:"fixture-refresh", expiresAt:Date().addingTimeInterval(3600), realm:.cn, uid:"fixture-user", enterpriseID:nil, domain:nil, nickname:"Fixture", deviceToken:nil)
        ProviderKeychainHelper.saveOAuthToken(token, instanceId:"one")
        check(WorkBuddyOAuthManager.shared.isAuthenticated(instanceId:"one"), "stored login")
        check(!WorkBuddyOAuthManager.shared.isAuthenticated(instanceId:"two"), "per-instance isolation")
        check(WorkBuddyModelsAPI.capabilities(instanceId:"one", modelID:"vision", credentials:token) == nil, "cold catalog")
        var catalogRequests = 0
        let fixtureLoader: WorkBuddyModelsAPI.RowLoader = { credentials in
            check(credentials.uid == "fixture-user", "catalog account binding")
            catalogRequests += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return rows
        }
        let concurrent = (0..<8).map { _ in Task { @MainActor in
            try await WorkBuddyModelsAPI.requiredCapabilities(instanceId:"one", modelID:"vision", credentials:token, rowLoader:fixtureLoader)
        } }
        for request in concurrent { _ = try await request.value }
        check(catalogRequests == 1, "catalog single-flight")
        let textCapability = try await WorkBuddyModelsAPI.requiredCapabilities(instanceId:"one", modelID:"text", credentials:token)
        check(textCapability.supportsTools == false, "text model is never inferred tool capable")
        do {
            _ = try await WorkBuddyModelsAPI.requiredCapabilities(instanceId:"one", modelID:"unknown-model", credentials:token, rowLoader:fixtureLoader)
            preconditionFailure("missing model must fail before prompt transport")
        } catch {}
        let model = parsed.models.first(where: {$0.id == "vision"})!
        var request = URLRequest(url: URL(string:"https://copilot.tencent.com/v2/chat/completions")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model":"vision", "stream":false, "max_completion_tokens":2048, "messages":[["role":"developer", "content":"fixture"]], "tool_choice":["type":"function", "function":["name":"read_file"]]])
        let adapted = try await WorkBuddyRequestAdapter.adapt(request, instanceId:"one", model:model, conversationID:"conversation-fixture", turnID:"0123456789abcdef0123456789abcdef")
        let body = try JSONSerialization.jsonObject(with: adapted.httpBody!) as! [String:Any]
        check(body["stream"] as? Bool == true, "mandatory stream")
        check(body["max_tokens"] as? Int == 2048 && body["max_completion_tokens"] == nil, "output limit alias")
        check(body["tool_choice"] as? String == "read_file", "function choice")
        check((body["messages"] as? [[String:Any]])?.first?["role"] as? String == "system", "developer role")
        check(adapted.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-access", "access auth")
        check(adapted.value(forHTTPHeaderField:"X-Refresh-Token") == nil, "refresh secret excluded")
        check(adapted.value(forHTTPHeaderField:"X-Device-Token") == nil, "no fabricated device token")
        check(adapted.value(forHTTPHeaderField:"X-Conversation-ID") == "conversation-fixture", "conversation identity")
        let globalToken = WorkBuddyTokenStorage(accessToken:"fixture-global", refreshToken:"fixture-refresh", expiresAt:Date().addingTimeInterval(3600), realm:.global, uid:"fixture-user", enterpriseID:nil, domain:nil, nickname:nil, deviceToken:nil)
        ProviderKeychainHelper.saveOAuthToken(globalToken, instanceId:"two")
        check(WorkBuddyModelsAPI.capabilities(instanceId:"two", modelID:"vision", credentials:globalToken) == nil, "catalog realm and instance isolation")
        let globalCapability = try await WorkBuddyModelsAPI.requiredCapabilities(instanceId:"two", modelID:"text", credentials:globalToken, rowLoader: { credentials in
            check(credentials.realm == .global, "global catalog route")
            return [["id":"text", "supportsToolCall":false]]
        })
        check(globalCapability.supportsTools == false, "global catalog authoritative")
        check(WorkBuddyModelsAPI.capabilities(instanceId:"two", modelID:"vision", credentials:globalToken) == nil, "CN models not copied to global")
        WorkBuddyOAuthManager.shared.logout(instanceId:"two")

        let valid = WorkBuddyRequestAdapter.streamValidator()
        try valid(#"data: {"choices":[{"delta":{"content":"ok"},"finish_reason":null}]}"#)
        try valid("data: [DONE]")
        try valid(nil)
        let empty = WorkBuddyRequestAdapter.streamValidator()
        try empty("data: [DONE]")
        expectFailure("empty stream") { try empty(nil) }
        let truncated = WorkBuddyRequestAdapter.streamValidator()
        try truncated(#"data: {"choices":[{"delta":{"content":"partial"}}]}"#)
        expectFailure("truncated stream") { try truncated(nil) }
        let rejected = WorkBuddyRequestAdapter.streamValidator()
        expectFailure("HTTP 200 business error") { try rejected(#"{"code":123,"msg":"error"}"#) }
        WorkBuddyOAuthManager.shared.logout(instanceId:"one")
        check(!WorkBuddyOAuthManager.shared.isAuthenticated(instanceId:"one"), "logout removes credentials")
        check(WorkBuddyModelsAPI.capabilities(instanceId:"one", modelID:"vision", credentials:token) == nil, "logout invalidates catalog")
        ProviderKeychainHelper.saveOAuthToken(token, instanceId:"one")
        do {
            _ = try await WorkBuddyModelsAPI.fetchModels(instanceId:"one", rowLoader: { _ in
                WorkBuddyOAuthManager.shared.logout(instanceId:"one")
                ProviderKeychainHelper.saveOAuthToken(token, instanceId:"one")
                return rows
            })
            preconditionFailure("old login generation must not publish catalog")
        } catch {}
        check(WorkBuddyModelsAPI.capabilities(instanceId:"one", modelID:"vision", credentials:token) == nil, "same-account relogin isolation")
        WorkBuddyOAuthManager.shared.logout(instanceId:"one")
        print("WorkBuddy production fixtures passed: auth envelope, realm, expiry, catalog single-flight, generation isolation, missing model, request, SSE, instance isolation.")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="ze-workbuddy-fixtures-") as directory:
    directory = pathlib.Path(directory)
    support = directory / "Fixture.swift"
    support.write_text(SUPPORT, encoding="utf-8")
    binary = directory / "workbuddy-fixtures"
    sources = [ROOT / "Providers/WorkBuddy" / name for name in (
        "WorkBuddyOAuthManager.swift", "WorkBuddyModelsAPI.swift", "WorkBuddyRequestAdapter.swift", "WorkBuddyBalanceAPI.swift")]
    quota = directory / "Quota.swift"
    quota_source = (ROOT / "Providers/ProviderAPIQuota.swift").read_text(encoding="utf-8")
    quota.write_text("import Foundation\n" + quota_source[quota_source.index("struct ProviderAPIQuota:"):quota_source.index("enum ProviderAPIQuotaState:")], encoding="utf-8")
    sources.append(quota)
    subprocess.run([swift, "-swift-version", "5", "-parse-as-library", *map(str, sources), str(support), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
