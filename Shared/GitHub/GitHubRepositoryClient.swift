import Foundation

/// Injectable transport shared by account authorization and repository tools.
struct GitHubAPI: Sendable {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func scopes(_ value: String) -> [String] {
        value.split { $0 == "," || $0.isWhitespace }.map(String.init).sorted()
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    func request<T: Decodable>(path: String, token: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let (data, _) = try await raw(path: path, token: token, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func raw(path: String, token: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: "https://api.github.com" + path), url.host == "api.github.com" else {
            throw GitHubConnectorError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Ze-iOS", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubConnectorError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["message"] as? String ?? "GitHub API error"
            if http.statusCode == 401 { throw GitHubConnectorError.invalidToken }
            if http.statusCode == 429 || (http.statusCode == 403 && (
                http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
                http.value(forHTTPHeaderField: "Retry-After") != nil || detail.lowercased().contains("rate limit"))) {
                throw GitHubConnectorError.rateLimited
            }
            if http.statusCode == 403 {
                if let sso = http.value(forHTTPHeaderField: "X-GitHub-SSO"), sso.contains("required") {
                    throw GitHubConnectorError.permissionDenied("组织要求 SSO 授权，请在 GitHub 为此令牌授权组织访问。\(detail)")
                }
                throw GitHubConnectorError.permissionDenied(detail)
            }
            if http.statusCode == 404 {
                throw GitHubConnectorError.permissionDenied("资源不存在或令牌未获授权；请检查仓库、分支、组织授权和令牌权限。\(detail)")
            }
            if http.statusCode == 409 { throw GitHubConnectorError.conflict(detail) }
            throw GitHubConnectorError.http(http.statusCode, detail)
        }
        return (data, http)
    }
}

struct GitHubRepositoryClient {
    let api: GitHubAPI
    init(api: GitHubAPI = GitHubAPI()) { self.api = api }

    static func contentsPath(owner: String, repository: String, path: String) throws -> String {
        func validName(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." &&
                !value.contains(where: { $0 == "/" || $0 == "\\" || $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        }
        guard validName(owner), validName(repository), validFilePath(path) else {
            throw GitHubConnectorError.http(400, "仓库名称或文件路径无效；路径必须位于仓库内且不得包含点路径段或控制字符。")
        }
        return "/repos/" + GitHubAPI.encode(owner) + "/" + GitHubAPI.encode(repository) + "/contents/" +
            path.split(separator: "/").map { GitHubAPI.encode(String($0)) }.joined(separator: "/")
    }

    static func validFilePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" })
    }

    /// Contents API inline text is limited to 1 MiB; encoding:none must never become empty success.
    func readFile(owner: String, repository: String, path: String, branch: String?, token: String) async throws -> [String: Any] {
        let endpoint = try Self.contentsPath(owner: owner, repository: repository, path: path)
        let suffix = branch.map { "?ref=" + GitHubAPI.encode($0) } ?? ""
        let (data, _) = try await api.raw(path: endpoint + suffix, token: token)
        let object = try JSONSerialization.jsonObject(with: data)
        if let items = object as? [[String: Any]] {
            return ["path": path, "items": items.map { ["name": $0["name"] ?? "", "path": $0["path"] ?? "", "type": $0["type"] ?? ""] }]
        }
        guard let value = object as? [String: Any], value["encoding"] as? String == "base64",
              let size = value["size"] as? Int, size >= 0, size <= 1_048_576 else {
            throw GitHubConnectorError.http(422, "文件未提供完整内联内容；此工具读取上限为 1 MiB UTF-8 文本。请使用仓库检出工具读取较大文件。")
        }
        guard let encoded = value["content"] as? String,
              let decoded = Data(base64Encoded: encoded.filter { !$0.isWhitespace }), decoded.count == size,
              let content = String(data: decoded, encoding: .utf8) else {
            throw GitHubConnectorError.http(422, "文件不是完整的 UTF-8 文本。")
        }
        let truncated = content.count > 30_000
        return ["path": path, "sha": value["sha"] ?? "", "content": truncated ? String(content.prefix(30_000)) + "\n[内容已截断]" : content,
                "truncated": truncated, "size": size]
    }

    struct Change: Decodable {
        let path: String
        let content: String?
        let delete: Bool?
        let executable: Bool?
    }

    func repositories(token: String, visibility: String = "all", page: Int = 1) async throws -> [String: Any] {
        guard ["all", "public", "private"].contains(visibility), page > 0 else {
            throw GitHubConnectorError.http(400, "visibility 应为 all/public/private，page 从 1 开始。")
        }
        let path = "/user/repos?per_page=100&page=\(page)&sort=full_name&direction=asc&visibility=\(visibility)&affiliation=owner,collaborator,organization_member"
        let (data, response) = try await api.raw(path: path, token: token)
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitHubConnectorError.malformedResponse }
        let hasNext = (response.value(forHTTPHeaderField: "Link") ?? "").contains("rel=\"next\"")
        let nextPage: Any = hasNext ? (page + 1) as Any : NSNull()
        return ["repositories": values.map { value -> [String: Any] in
            ["full_name": value["full_name"] ?? "", "private": value["private"] ?? false,
             "default_branch": value["default_branch"] ?? "", "html_url": value["html_url"] ?? "",
             "permissions": value["permissions"] ?? [:], "archived": value["archived"] ?? false]
        }, "page": page, "has_more": hasNext, "next_page": nextPage]
    }

    func info(owner: String, repository: String, branch: String?, token: String) async throws -> [String: Any] {
        let base = try repositoryPath(owner, repository)
        var value = try await object(base, token: token)
        let selected = branch ?? (value["default_branch"] as? String ?? "")
        if !selected.isEmpty {
            value["selected_branch"] = selected
            do { value["head_sha"] = try await head(base: base, branch: selected, token: token) }
            catch { value["branch_error"] = error.localizedDescription }
        }
        return value
    }

    /// Creates a single commit for all changes and advances the ref without force.
    /// If a concurrent writer advances the branch, the original expected head is rejected.
    func commit(owner: String, repository: String, branch: String, expectedHead: String,
                message: String, changes: [Change], token: String) async throws -> [String: Any] {
        guard !changes.isEmpty, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expectedHead.count == 40, expectedHead.allSatisfy({ $0.isHexDigit }) else {
            throw GitHubConnectorError.http(400, "需要修改项、提交说明和 40 位 expected_head。")
        }
        var paths = Set<String>()
        for change in changes {
            guard validPath(change.path), paths.insert(change.path).inserted,
                  (change.delete == true ? change.content == nil : change.content != nil) else {
                throw GitHubConnectorError.http(400, "修改路径须唯一且位于仓库内；写入传 content，删除只传 delete:true。")
            }
        }
        let base = try repositoryPath(owner, repository)
        try await requireWrite(base, token: token)
        guard try await head(base: base, branch: branch, token: token) == expectedHead else {
            throw GitHubConnectorError.conflict("目标分支已变化，请重新读取并审阅修改。")
        }
        let parent = try await object(base + "/git/commits/" + expectedHead, token: token)
        guard let baseTree = (parent["tree"] as? [String: Any])?["sha"] as? String else { throw GitHubConnectorError.malformedResponse }
        var treeCache: [String: [[String: Any]]] = [:]
        var entries: [[String: Any]] = []
        for change in changes {
            try Task.checkCancellation()
            // Walk only the affected directories; a truncated recursive tree could
            // silently reset executable modes or miss an existing symlink.
            let existing = try await entry(path: change.path, tree: baseTree, base: base, token: token, cache: &treeCache)
            if let existing, existing["type"] as? String != "blob" {
                throw GitHubConnectorError.http(400, "目标不是普通文件：\(change.path)")
            }
            if change.delete == true, existing == nil { throw GitHubConnectorError.conflict("待删除文件不存在：\(change.path)") }
            let mode = change.executable.map { $0 ? "100755" : "100644" } ?? (existing?["mode"] as? String ?? "100644")
            var entry: [String: Any] = ["path": change.path, "mode": mode, "type": "blob"]
            if change.delete == true { entry["sha"] = NSNull() }
            else {
                let blob = try await object(base + "/git/blobs", token: token, method: "POST",
                    body: ["content": Data((change.content ?? "").utf8).base64EncodedString(), "encoding": "base64"])
                guard let sha = blob["sha"] as? String else { throw GitHubConnectorError.malformedResponse }
                entry["sha"] = sha
            }
            entries.append(entry)
        }
        let tree = try await object(base + "/git/trees", token: token, method: "POST", body: ["base_tree": baseTree, "tree": entries])
        guard let treeSHA = tree["sha"] as? String else { throw GitHubConnectorError.malformedResponse }
        let commit = try await object(base + "/git/commits", token: token, method: "POST",
            body: ["message": message, "tree": treeSHA, "parents": [expectedHead]])
        guard let commitSHA = commit["sha"] as? String else { throw GitHubConnectorError.malformedResponse }
        guard try await head(base: base, branch: branch, token: token) == expectedHead else {
            throw GitHubConnectorError.conflict("生成提交期间分支发生变化；未推送，请重新读取并审阅修改。")
        }
        let ref = try branchPath(branch)
        _ = try await object(base + "/git/refs/heads/" + ref, token: token, method: "PATCH", body: ["sha": commitSHA, "force": false])
        return ["success": true, "commit_sha": commitSHA, "branch": branch, "changed_files": changes.count, "pushed": true]
    }

    func createBranch(owner: String, repository: String, branch: String, fromSHA: String, token: String) async throws -> [String: Any] {
        _ = try branchPath(branch)
        guard fromSHA.count == 40, fromSHA.allSatisfy({ $0.isHexDigit }) else { throw GitHubConnectorError.http(400, "from_sha 应为完整提交 SHA。") }
        let base = try repositoryPath(owner, repository)
        try await requireWrite(base, token: token)
        return try await object(base + "/git/refs", token: token, method: "POST", body: ["ref": "refs/heads/" + branch, "sha": fromSHA])
    }

    private func requireWrite(_ base: String, token: String) async throws {
        let repository = try await object(base, token: token)
        guard repository["archived"] as? Bool != true,
              (repository["permissions"] as? [String: Any])?["push"] as? Bool == true else {
            throw GitHubConnectorError.permissionDenied("当前账号没有此仓库的写入权限，或仓库已经归档。")
        }
    }

    private func entry(path: String, tree: String, base: String, token: String,
                       cache: inout [String: [[String: Any]]]) async throws -> [String: Any]? {
        let components = path.split(separator: "/").map(String.init)
        var current = tree
        for (index, component) in components.enumerated() {
            if cache[current] == nil {
                let value = try await object(base + "/git/trees/" + GitHubAPI.encode(current), token: token)
                guard value["truncated"] as? Bool != true, let rows = value["tree"] as? [[String: Any]] else {
                    throw GitHubConnectorError.http(422, "目录树返回不完整，请缩小修改范围后重试。")
                }
                cache[current] = rows
            }
            guard let found = cache[current]?.first(where: { $0["path"] as? String == component }) else { return nil }
            if index == components.count - 1 { return found }
            guard found["type"] as? String == "tree", let sha = found["sha"] as? String else {
                throw GitHubConnectorError.http(400, "文件路径经过非目录项：\(component)")
            }
            current = sha
        }
        return nil
    }

    private func head(base: String, branch: String, token: String) async throws -> String {
        let ref = try branchPath(branch)
        let value = try await object(base + "/git/ref/heads/" + ref, token: token)
        guard let sha = (value["object"] as? [String: Any])?["sha"] as? String else { throw GitHubConnectorError.malformedResponse }
        return sha
    }

    private func repositoryPath(_ owner: String, _ repository: String) throws -> String {
        let contents = try Self.contentsPath(owner: owner, repository: repository, path: "validation")
        return String(contents.dropLast("/contents/validation".count))
    }

    private func validPath(_ path: String) -> Bool {
        Self.validFilePath(path)
    }

    private func branchPath(_ branch: String) throws -> String {
        guard validPath(branch), !branch.contains(".."), !branch.contains("@{"), !branch.hasSuffix("."),
              !branch.contains(where: { $0.isWhitespace || $0.asciiValue.map({ $0 < 32 || $0 == 127 }) == true || "~^:?*[".contains($0) }),
              !branch.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }) else {
            throw GitHubConnectorError.http(400, "分支名无效。")
        }
        return branch.split(separator: "/").map { GitHubAPI.encode(String($0)) }.joined(separator: "/")
    }

    private func object(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, _) = try await api.raw(path: path, token: token, method: method, body: encoded)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitHubConnectorError.malformedResponse }
        return value
    }
}
