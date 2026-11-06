import Foundation
import CoreFoundation

@MainActor
enum WorkBuddyModelsAPI {
    struct Capabilities: Sendable {
        let supportsTools: Bool?
        let supportsImages: Bool?
        let supportsReasoning: Bool?
        let efforts: [String]
        let defaultEffort: String?
    }

    private struct Identity: Hashable, Sendable {
        let instanceId: String
        let uid: String
        let realm: WorkBuddyRealm
        let session: UUID
    }
    private struct Catalog: Sendable {
        let identity: Identity
        let models: [LLMModel]
        let capabilities: [String: Capabilities]
    }
    typealias RowLoader = @MainActor (WorkBuddyTokenStorage) async throws -> [[String: Any]]
    private static var catalogs: [String: Catalog] = [:]
    private static var flights: [Identity: (id: UUID, task: Task<Catalog, Error>)] = [:]

    static func capabilities(instanceId: String, modelID: String, credentials: WorkBuddyTokenStorage) -> Capabilities? {
        guard let catalog = catalogs[instanceId], catalog.identity == identity(instanceId, credentials) else { return nil }
        return catalog.capabilities[modelID]
    }

    /// Used by both chat surfaces: a cold process discovers the authenticated
    /// account's catalog before deciding tools/images or sending any prompt.
    static func requiredCapabilities(instanceId: String, modelID: String, credentials: WorkBuddyTokenStorage, rowLoader: RowLoader? = nil) async throws -> Capabilities {
        let expected = identity(instanceId, credentials)
        if capabilities(instanceId: instanceId, modelID: modelID, credentials: credentials) == nil {
            _ = try await fetchModels(instanceId: instanceId, rowLoader: rowLoader)
        }
        try Task.checkCancellation()
        guard isCurrent(expected) else { throw CancellationError() }
        guard let value = capabilities(instanceId: instanceId, modelID: modelID, credentials: credentials) else {
            throw WorkBuddyError.message("当前 WorkBuddy 账号的模型目录中没有此模型，请刷新模型列表后重新选择。")
        }
        return value
    }

    static func invalidate(instanceId: String) {
        catalogs[instanceId] = nil
        for key in Array(flights.keys) where key.instanceId == instanceId {
            flights.removeValue(forKey: key)?.task.cancel()
        }
    }

    static func fetchModels(instanceId: String, rowLoader: RowLoader? = nil) async throws -> [LLMModel] {
        let credentials = try await WorkBuddyOAuthManager.shared.validCredentials(instanceId: instanceId)
        let expected = identity(instanceId, credentials)
        if let running = flights[expected] {
            let result = try await running.task.value
            try Task.checkCancellation()
            guard isCurrent(expected) else { throw CancellationError() }
            return result.models
        }
        let flightID = UUID()
        let task = Task { @MainActor () async throws -> Catalog in
            let rows: [[String: Any]]
            if let rowLoader { rows = try await rowLoader(credentials) }
            else { rows = try await downloadRows(credentials) }
            let result = parseModels(rows)
            guard !result.models.isEmpty else { throw WorkBuddyError.message("当前 WorkBuddy 账号没有可用的聊天模型。") }
            try Task.checkCancellation()
            guard isCurrent(expected) else { throw CancellationError() }
            let catalog = Catalog(identity: expected, models: result.models, capabilities: result.capabilities)
            catalogs[instanceId] = catalog
            return catalog
        }
        flights[expected] = (flightID, task)
        defer { if flights[expected]?.id == flightID { flights[expected] = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        guard isCurrent(expected) else { throw CancellationError() }
        return result.models
    }

    private static func identity(_ instanceId: String, _ credentials: WorkBuddyTokenStorage) -> Identity {
        Identity(instanceId: instanceId, uid: credentials.uid, realm: credentials.realm,
                 session: WorkBuddyOAuthManager.shared.credentialSession(instanceId: instanceId))
    }

    private static func isCurrent(_ expected: Identity) -> Bool {
        guard let stored = ProviderKeychainHelper.loadOAuthToken(instanceId: expected.instanceId, as: WorkBuddyTokenStorage.self) else { return false }
        return identity(expected.instanceId, stored) == expected
    }

    private static func downloadRows(_ credentials: WorkBuddyTokenStorage) async throws -> [[String: Any]] {
        let headers = ["Authorization": "Bearer \(credentials.accessToken)"]
        var rows: [[String: Any]] = []
        var firstError: Error?
        do {
            let data = try await WorkBuddyHTTP.data(realm: credentials.realm, path: "/v3/config", headers: headers)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = object["models"] as? [[String: Any]] else {
                throw WorkBuddyError.message("WorkBuddy 模型目录格式错误。")
            }
            rows = models
        } catch {
            try Task.checkCancellation()
            firstError = error
        }
        // The enterprise endpoint fills gaps and is the older-server fallback.
        do {
            let path = credentials.realm == .cn ? "/console/enterprises/personal/models" : "/v2/enterprises/personal/models"
            let data = try await WorkBuddyHTTP.data(realm: credentials.realm, path: path, headers: headers)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = object["models"] as? [[String: Any]],
               let agents = object["agents"] as? [[String: Any]],
               let cli = agents.first(where: { ($0["name"] as? String) == "cli" }),
               let allowed = cli["models"] as? [String] {
                let ids = Set(allowed)
                rows += models.filter { ($0["id"] as? String).map(ids.contains) ?? false }
            }
        } catch {
            try Task.checkCancellation()
            if rows.isEmpty { throw firstError ?? error }
        }
        if rows.isEmpty, let firstError { throw firstError }
        return rows
    }

    static func parseModels(_ rows: [[String: Any]]) -> (models: [LLMModel], capabilities: [String: Capabilities]) {
        var models: [LLMModel] = []
        var capabilities: [String: Capabilities] = [:]
        var seen: Set<String> = []
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id) // A disabled primary entry must not revive via fallback.
            guard row["disabled"] as? Bool != true else { continue }
            let lower = id.lowercased()
            let output = positiveInt(row["maxOutputTokens"])
            let tags = row["tags"] as? [String] ?? []
            if ["nes-", "completion-", "codewise-"].contains(where: lower.hasPrefix)
                || (output != nil && output! <= 256) || tags.contains("text-to-image") { continue }
            let images = row["supportsImages"] as? Bool
            let reasoning = row["supportsReasoning"] as? Bool
            let reasoningConfig = row["reasoning"] as? [String: Any] ?? [:]
            capabilities[id] = Capabilities(supportsTools: row["supportsToolCall"] as? Bool,
                supportsImages: images, supportsReasoning: reasoning,
                efforts: reasoningConfig["supportedEfforts"] as? [String] ?? [],
                defaultEffort: reasoningConfig["defaultEffort"] as? String)
            var modalities: ModelModality = .textOnly
            if images == true { modalities.insert(.imageInput) }
            models.append(LLMModel(id: id, displayName: row["name"] as? String ?? modelDisplayName(from: id),
                provider: "WorkBuddy", modalityOverride: modalities,
                contextWindow: positiveInt(row["maxInputTokens"]) ?? positiveInt(row["contextWindow"]),
                maxOutputTokens: output, supportsReasoning: reasoning, interleavedReasoningField: "reasoning_content"))
        }
        return (models.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }, capabilities)
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 0,
              number.doubleValue < Double(Int.max) else { return nil }
        return number.intValue
    }
}
