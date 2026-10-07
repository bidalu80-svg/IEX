import Foundation

struct GitHubAIToolResult {
    let output: String
    let success: Bool
}

/// GitHub is a separately authorized connector. The gateway exposes account and
/// repository metadata only; access tokens remain in the local Keychain.
@MainActor
enum GitHubAIToolGateway {
    private static let store = GitHubAccountStore.shared
    private static let api = GitHubAPI()

    static var statusFragment: String {
        let accounts = store.accounts
        let guidance = """

        GitHub 连接器：模型可以使用 github_account_list 查看已登录账号，再使用对应的 account_id 读取仓库、读取文件。写入文件或删除文件会通过 GitHub Contents API 创建提交并推送到指定分支，执行前必须等待用户确认。不要索要、猜测、输出或写入 GitHub 访问令牌，也不要把令牌放入工具参数、工具结果或对话内容。
        """
        guard !accounts.isEmpty else {
            return guidance + "\n当前没有已登录的 GitHub 账号。不要声称可以读取或管理 GitHub 项目，请先引导用户在设置 → 服务器与连接 → GitHub 中登录。"
        }
        let rows = accounts.map { account in
            "- \(account.login) [account_id: \(account.id.uuidString), name: \(account.title)]"
        }.joined(separator: "\n")
        return guidance + "\n当前已登录并授权给本机模型会话的 GitHub 账号：\n\(rows)\n每次操作前先确认账号和仓库。"
    }

    static func definitions() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "github_account_list",
                description: "列出当前已登录的 GitHub 账号。不会返回访问令牌。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题")
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "github_repository_list",
                description: "列出一个已登录 GitHub 账号可以访问的仓库。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题"),
                    "account_id": AgentToolParam(type: .string, description: "github_account_list 返回的账号 UUID"),
                    "visibility": AgentToolParam(type: .string, description: "可选：all、owner、public、private")
                ],
                required: ["tool_title", "account_id"],
                propertyOrdering: ["tool_title", "account_id", "visibility"]
            ),
            AgentToolDefinition(
                name: "github_file_read",
                description: "读取 GitHub 仓库中的文件，返回文本内容和当前文件 SHA。目录会返回目录项列表。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题"),
                    "account_id": AgentToolParam(type: .string, description: "GitHub 账号 UUID"),
                    "owner": AgentToolParam(type: .string, description: "仓库所有者或组织名"),
                    "repository": AgentToolParam(type: .string, description: "仓库名"),
                    "path": AgentToolParam(type: .string, description: "仓库内文件路径"),
                    "branch": AgentToolParam(type: .string, description: "可选分支名，默认仓库默认分支")
                ],
                required: ["tool_title", "account_id", "owner", "repository", "path"],
                propertyOrdering: ["tool_title", "account_id", "owner", "repository", "path", "branch"]
            ),
            AgentToolDefinition(
                name: "github_file_write",
                description: "向 GitHub 仓库写入或更新文本文件。GitHub 会创建提交并推送到指定分支；操作前必须获得用户确认。更新已有文件时传入 file_sha。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题"),
                    "account_id": AgentToolParam(type: .string, description: "GitHub 账号 UUID"),
                    "owner": AgentToolParam(type: .string, description: "仓库所有者或组织名"),
                    "repository": AgentToolParam(type: .string, description: "仓库名"),
                    "path": AgentToolParam(type: .string, description: "仓库内文件路径"),
                    "content": AgentToolParam(type: .string, description: "要写入的 UTF-8 文本内容"),
                    "message": AgentToolParam(type: .string, description: "提交说明"),
                    "branch": AgentToolParam(type: .string, description: "目标分支，默认仓库默认分支"),
                    "file_sha": AgentToolParam(type: .string, description: "更新已有文件时从 github_file_read 得到的 SHA，可选")
                ],
                required: ["tool_title", "account_id", "owner", "repository", "path", "content", "message"],
                propertyOrdering: ["tool_title", "account_id", "owner", "repository", "path", "content", "message", "branch", "file_sha"]
            ),
            AgentToolDefinition(
                name: "github_file_delete",
                description: "删除 GitHub 仓库中的文件并创建提交推送到指定分支。操作前必须获得用户确认。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题"),
                    "account_id": AgentToolParam(type: .string, description: "GitHub 账号 UUID"),
                    "owner": AgentToolParam(type: .string, description: "仓库所有者或组织名"),
                    "repository": AgentToolParam(type: .string, description: "仓库名"),
                    "path": AgentToolParam(type: .string, description: "仓库内文件路径"),
                    "file_sha": AgentToolParam(type: .string, description: "从 github_file_read 得到的文件 SHA"),
                    "message": AgentToolParam(type: .string, description: "提交说明"),
                    "branch": AgentToolParam(type: .string, description: "目标分支，默认仓库默认分支")
                ],
                required: ["tool_title", "account_id", "owner", "repository", "path", "file_sha", "message"],
                propertyOrdering: ["tool_title", "account_id", "owner", "repository", "path", "file_sha", "message", "branch"]
            )
        ]
    }

    static func execute(name: String, arguments: [String: Any]) async -> GitHubAIToolResult {
        switch name {
        case "github_account_list":
            return accountList()
        case "github_repository_list":
            return await repositoryList(arguments)
        case "github_file_read":
            return await fileRead(arguments)
        case "github_file_write":
            return await fileWrite(arguments)
        case "github_file_delete":
            return await fileDelete(arguments)
        default:
            return .init(output: "Error: 未知的 GitHub 工具：\(name)", success: false)
        }
    }

    private static func accountList() -> GitHubAIToolResult {
        let rows = store.accounts.map { account in
            ["account_id": account.id.uuidString, "login": account.login, "name": account.title]
        }
        return .init(output: json(["accounts": rows, "security": "访问令牌不会返回给模型。"]), success: true)
    }

    private static func repositoryList(_ arguments: [String: Any]) async -> GitHubAIToolResult {
        guard let (account, token) = authorizedAccount(arguments) else { return unauthorized() }
        let visibility = string("visibility", arguments) ?? "all"
        let query = "?per_page=100&sort=updated&direction=desc&visibility=\(urlEncode(visibility))"
        do {
            let (data, _) = try await api.raw(path: "/user/repos\(query)", token: token)
            guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return malformed() }
            let rows = values.compactMap { value -> [String: Any]? in
                guard let fullName = value["full_name"] as? String else { return nil }
                var row: [String: Any] = ["account_id": account.id.uuidString, "full_name": fullName]
                row["name"] = (value["name"] as? String) ?? ""
                row["private"] = (value["private"] as? Bool) ?? false
                row["default_branch"] = (value["default_branch"] as? String) ?? ""
                row["html_url"] = (value["html_url"] as? String) ?? ""
                return row
            }
            return .init(output: json(["account": account.login, "repositories": rows]), success: true)
        } catch { return failure(error) }
    }

    private static func fileRead(_ arguments: [String: Any]) async -> GitHubAIToolResult {
        guard let (account, token) = authorizedAccount(arguments),
              let owner = string("owner", arguments), let repository = string("repository", arguments),
              let filePath = string("path", arguments) else { return missing("account_id、owner、repository 或 path") }
        let branch = string("branch", arguments)
        let suffix = branch.map { "?ref=\(urlEncode($0))" } ?? ""
        do {
            let (data, _) = try await api.raw(path: "/repos/\(urlEncode(owner))/\(urlEncode(repository))/contents/\(encodePath(filePath))\(suffix)", token: token)
            let object = try JSONSerialization.jsonObject(with: data)
            if let items = object as? [[String: Any]] {
                let rows = items.map { ["name": $0["name"] as? String ?? "", "path": $0["path"] as? String ?? "", "type": $0["type"] as? String ?? ""] }
                return .init(output: json(["account": account.login, "path": filePath, "items": rows]), success: true)
            }
            guard let value = object as? [String: Any] else { return malformed() }
            if let encoded = value["content"] as? String {
                let compact = encoded.filter { !$0.isWhitespace }
                guard let decoded = Data(base64Encoded: compact), let text = String(data: decoded, encoding: .utf8) else {
                    return .init(output: "Error: 文件不是 UTF-8 文本，未暴露给模型。", success: false)
                }
                return .init(output: json(["account": account.login, "path": filePath, "sha": value["sha"] as? String ?? "", "content": truncate(text)]), success: true)
            }
            return malformed()
        } catch { return failure(error) }
    }

    private static func fileWrite(_ arguments: [String: Any]) async -> GitHubAIToolResult {
        guard let (account, token) = authorizedAccount(arguments),
              let owner = string("owner", arguments), let repository = string("repository", arguments),
              let filePath = string("path", arguments), let content = arguments["content"] as? String,
              let message = string("message", arguments) else { return missing("写入所需参数") }
        let branch = string("branch", arguments)
        let detail = "账号 \(account.login) 将写入 \(owner)/\(repository)/\(filePath)，创建提交并推送\(branch.map { "到分支 \($0)" } ?? "")。提交说明：\(message)"
        guard await RemoteServerAIConfirmationGate.shared.request(serverName: "GitHub / \(account.login)", operation: "写入并推送 GitHub 文件", detail: detail, isDestructive: true) else {
            return .init(output: "用户拒绝了 GitHub 写入操作。除非用户再次明确要求，不要重试。", success: false)
        }
        var body: [String: Any] = ["message": message, "content": Data(content.utf8).base64EncodedString()]
        if let branch { body["branch"] = branch }
        if let sha = string("file_sha", arguments) { body["sha"] = sha }
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [])
            let (responseData, _) = try await api.raw(path: "/repos/\(urlEncode(owner))/\(urlEncode(repository))/contents/\(encodePath(filePath))", token: token, method: "PUT", body: data)
            let value = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
            return .init(output: json(["success": true, "account": account.login, "repository": "\(owner)/\(repository)", "path": filePath, "commit_sha": (value["commit"] as? [String: Any])?["sha"] as? String ?? "", "message": "文件已提交并推送。"]), success: true)
        } catch { return failure(error) }
    }

    private static func fileDelete(_ arguments: [String: Any]) async -> GitHubAIToolResult {
        guard let (account, token) = authorizedAccount(arguments),
              let owner = string("owner", arguments), let repository = string("repository", arguments),
              let filePath = string("path", arguments), let sha = string("file_sha", arguments),
              let message = string("message", arguments) else { return missing("删除所需参数") }
        let branch = string("branch", arguments)
        let detail = "账号 \(account.login) 将删除 \(owner)/\(repository)/\(filePath)，创建提交并推送。提交说明：\(message)"
        guard await RemoteServerAIConfirmationGate.shared.request(serverName: "GitHub / \(account.login)", operation: "删除并推送 GitHub 文件", detail: detail, isDestructive: true) else {
            return .init(output: "用户拒绝了 GitHub 删除操作。除非用户再次明确要求，不要重试。", success: false)
        }
        var body: [String: Any] = ["message": message, "sha": sha]
        if let branch { body["branch"] = branch }
        do {
            let data = try JSONSerialization.data(withJSONObject: body, options: [])
            let (responseData, _) = try await api.raw(path: "/repos/\(urlEncode(owner))/\(urlEncode(repository))/contents/\(encodePath(filePath))", token: token, method: "DELETE", body: data)
            let value = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
            return .init(output: json(["success": true, "account": account.login, "path": filePath, "commit_sha": (value["commit"] as? [String: Any])?["sha"] as? String ?? "", "message": "文件已删除并推送。"]), success: true)
        } catch { return failure(error) }
    }

    private static func authorizedAccount(_ arguments: [String: Any]) -> (GitHubAccount, String)? {
        guard let raw = string("account_id", arguments), let id = UUID(uuidString: raw),
              let account = store.accounts.first(where: { $0.id == id }), let token = store.token(for: id), !token.isEmpty else { return nil }
        return (account, token)
    }

    private static func unauthorized() -> GitHubAIToolResult {
        .init(output: "Error: GitHub 账号不存在、未登录或访问令牌已失效。先调用 github_account_list，并让用户在设置中登录。", success: false)
    }

    private static func missing(_ detail: String) -> GitHubAIToolResult { .init(output: "Error: 缺少 GitHub 参数：\(detail)。", success: false) }
    private static func malformed() -> GitHubAIToolResult { .init(output: "Error: GitHub 返回的数据格式异常。", success: false) }
    private static func failure(_ error: Error) -> GitHubAIToolResult { .init(output: "Error: \(error.localizedDescription)", success: false) }

    private static func string(_ key: String, _ arguments: [String: Any]) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { urlEncode(String($0)) }.joined(separator: "/")
    }

    private static func truncate(_ text: String, maximum: Int = 30_000) -> String {
        guard text.count > maximum else { return text }
        return String(text.prefix(maximum)) + "\n[内容已截断]"
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let value = String(data: data, encoding: .utf8) else { return "{\"error\":\"无法编码 GitHub 结果\"}" }
        return value
    }
}
