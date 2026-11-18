import Foundation

// Exercises the production transport/client against an in-process HTTP fixture.
// No live credential or GitHub repository is used.
private final class FixtureProtocol: URLProtocol {
    struct Reply {
        let method: String
        let path: String
        let status: Int
        let headers: [String: String]
        let json: Any
        let inspect: ((URLRequest) -> Void)?
        init(_ method: String, _ path: String, _ json: Any, status: Int = 200,
             headers: [String: String] = [:], inspect: ((URLRequest) -> Void)? = nil) {
            self.method = method; self.path = path; self.json = json
            self.status = status; self.headers = headers; self.inspect = inspect
        }
    }
    static var replies: [Reply] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        precondition(!Self.replies.isEmpty, "Unexpected request \(request.url!)")
        let next = Self.replies.removeFirst()
        Self.lock.unlock()
        precondition(request.httpMethod == next.method, "Unexpected HTTP method")
        precondition(request.url!.path == next.path, "Unexpected path \(request.url!.path), expected \(next.path)")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        next.inspect?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: next.json))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main private struct GitHubRepositoryTests {
    static let old = String(repeating: "a", count: 40)
    static let new = String(repeating: "b", count: 40)
    static let base = "/repos/example/project"
    static let token = "fixture-token"
    static var passed = 0

    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func done(_ label: String) {
        precondition(FixtureProtocol.replies.isEmpty, "Unconsumed fixture replies: \(label)")
        passed += 1; print("PASS: \(label)")
    }

    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let api = GitHubAPI(session: URLSession(configuration: config))
        let client = GitHubRepositoryClient(api: api)

        FixtureProtocol.replies = [
            .init("GET", "/user/repos", [["full_name": "example/a", "permissions": ["push": true]]],
                headers: ["Link": "<https://api.github.com/user/repos?page=2>; rel=\"next\""], inspect: { request in
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    precondition(query.contains { $0.name == "affiliation" && $0.value == "owner,collaborator,organization_member" })
                }),
            .init("GET", "/user/repos", [["full_name": "organization/private", "private": true]], inspect: { request in
                precondition(request.url!.query!.contains("page=2"))
            })
        ]
        let first = try await client.repositories(token: token)
        precondition(first["has_more"] as? Bool == true && first["next_page"] as? Int == 2)
        let second = try await client.repositories(token: token, page: 2)
        precondition(second["has_more"] as? Bool == false && second["next_page"] is NSNull)
        done("repository pagination includes organization/collaborator affiliation and next page")

        for (status, headers, expected) in [
            (403, ["X-GitHub-SSO": "required; url=https://github.com/orgs/example/sso"], "permission"),
            (403, [String: String](), "permission"),
            (403, ["X-RateLimit-Remaining": "0"], "rate"),
            (429, [String: String](), "rate"),
            (409, [String: String](), "conflict"),
            (401, [String: String](), "token")
        ] {
            FixtureProtocol.replies = [.init("GET", "/user", ["message": "fixture"], status: status, headers: headers)]
            do { _ = try await api.raw(path: "/user", token: token); fatalError("Expected HTTP error") }
            catch let error as GitHubConnectorError {
                switch (error, expected) {
                case (.permissionDenied, "permission"), (.rateLimited, "rate"), (.conflict, "conflict"), (.invalidToken, "token"): break
                default: fatalError("Wrong error classification \(error)")
                }
            }
            done("HTTP \(status) \(expected) classification")
        }

        let changes = try JSONDecoder().decode([GitHubRepositoryClient.Change].self,
            from: Data(#"[{"path":"script.sh","content":"  echo hello\n\n"},{"path":"empty.txt","content":""},{"path":"removed.txt","delete":true}]"#.utf8))
        let prefix: [FixtureProtocol.Reply] = [
            .init("GET", base, ["permissions": ["push": true], "archived": false]),
            .init("GET", base + "/git/ref/heads/feature/test", ["object": ["sha": old]]),
            .init("GET", base + "/git/commits/" + old, ["tree": ["sha": "root-tree"]]),
            .init("GET", base + "/git/trees/root-tree", ["tree": [
                ["path": "script.sh", "mode": "100755", "type": "blob", "sha": "old-script"],
                ["path": "removed.txt", "mode": "100644", "type": "blob", "sha": "old-file"]], "truncated": false]),
            .init("POST", base + "/git/blobs", ["sha": "script-blob"], inspect: { request in
                let value = body(request)
                precondition(value["content"] as? String == Data("  echo hello\n\n".utf8).base64EncodedString())
            }),
            .init("POST", base + "/git/blobs", ["sha": "empty-blob"], inspect: { request in
                precondition(body(request)["content"] as? String == "")
            }),
            .init("POST", base + "/git/trees", ["sha": "new-tree"], inspect: { request in
                let value = body(request), rows = value["tree"] as! [[String: Any]]
                precondition(value["base_tree"] as? String == "root-tree")
                precondition(rows.count == 3 && rows[0]["mode"] as? String == "100755" && rows[2]["sha"] is NSNull)
            }),
            .init("POST", base + "/git/commits", ["sha": new], inspect: { request in
                precondition(body(request)["parents"] as? [String] == [old])
            })
        ]
        FixtureProtocol.replies = prefix + [
            .init("GET", base + "/git/ref/heads/feature/test", ["object": ["sha": old]]),
            .init("PATCH", base + "/git/refs/heads/feature/test", ["object": ["sha": new]], inspect: { request in
                let value = body(request)
                precondition(value["force"] as? Bool == false && value["sha"] as? String == new)
            })]
        let result = try await client.commit(owner: "example", repository: "project", branch: "feature/test",
            expectedHead: old, message: "Update fixtures", changes: changes, token: token)
        precondition(result["pushed"] as? Bool == true && result["commit_sha"] as? String == new)
        done("atomic multi-file commit preserves whitespace, empty text, executable mode and uses non-force push")

        FixtureProtocol.replies = prefix + [.init("GET", base + "/git/ref/heads/feature/test", ["object": ["sha": String(repeating: "c", count: 40)]])]
        do {
            _ = try await client.commit(owner: "example", repository: "project", branch: "feature/test", expectedHead: old,
                message: "Update fixtures", changes: changes, token: token)
            fatalError("Expected concurrent writer rejection")
        } catch GitHubConnectorError.conflict { }
        done("concurrent branch advancement produces no PATCH")

        FixtureProtocol.replies = [.init("GET", base, ["permissions": ["push": false]])]
        do {
            _ = try await client.commit(owner: "example", repository: "project", branch: "main", expectedHead: old,
                message: "Update fixtures", changes: changes, token: token)
            fatalError("Expected write permission rejection")
        } catch GitHubConnectorError.permissionDenied { }
        done("read-only repository produces no git writes")

        FixtureProtocol.replies = [.init("GET", base, ["permissions": ["push": true]]),
            .init("POST", base + "/git/refs", ["ref": "refs/heads/new-branch"], inspect: { request in
                precondition(body(request)["ref"] as? String == "refs/heads/new-branch")
            })]
        _ = try await client.createBranch(owner: "example", repository: "project", branch: "new-branch", fromSHA: old, token: token)
        done("branch creation writes explicit new ref")
        for path in ["..", "../x", "a/../../x", "/absolute", "a//b", "a/./b", "nul\0file", "line\nfile"] {
            do {
                _ = try await client.readFile(owner: "example", repository: "project", path: path, branch: nil, token: token)
                fatalError("Invalid path was accepted")
            } catch GitHubConnectorError.http(400, _) { }
        }
        for (owner, repository) in [("..", "project"), ("example", "."), ("bad/owner", "project"), ("example", "bad\\repo")] {
            do {
                _ = try GitHubRepositoryClient.contentsPath(owner: owner, repository: repository, path: "valid.txt")
                fatalError("Invalid repository identity was accepted")
            } catch GitHubConnectorError.http(400, _) { }
        }
        let escaped = try GitHubRepositoryClient.contentsPath(owner: "valid-owner", repository: "valid.repo_name", path: "dir/a & b.txt")
        precondition(escaped == "/repos/valid-owner/valid.repo_name/contents/dir/a%20%26%20b.txt")
        done("contents paths reject traversal before transport and retain valid repository names")

        FixtureProtocol.replies = [.init("GET", base + "/contents/empty.txt",
            ["type": "file", "size": 0, "encoding": "base64", "content": "", "sha": "empty-sha"])]
        let empty = try await client.readFile(owner: "example", repository: "project", path: "empty.txt", branch: nil, token: token)
        precondition(empty["content"] as? String == "" && empty["truncated"] as? Bool == false)
        done("real empty file succeeds")
        for value in [
            ["size": 2_000_000, "encoding": "none", "content": "", "download_url": "https://untrusted.invalid/file"] as [String: Any],
            ["size": 1, "encoding": "base64", "content": ""],
            ["size": 1_048_577, "encoding": "base64", "content": ""]
        ] {
            FixtureProtocol.replies = [.init("GET", base + "/contents/large.txt", value)]
            do {
                _ = try await client.readFile(owner: "example", repository: "project", path: "large.txt", branch: nil, token: token)
                fatalError("Incomplete/oversized contents accepted")
            } catch GitHubConnectorError.http(422, _) { }
            done("incomplete or oversized contents fail without following download_url")
        }
        var stored = "old-metadata", credential = "old-token"
        let diskError = NSError(domain: NSPOSIXErrorDomain, code: 28)
        do {
            try GitHubAccountPersistence.commit(writeMetadata: { throw diskError },
                writeCredential: { credential = "new-token" }, rollbackMetadata: { stored = "old-metadata" })
            fatalError("Expected disk failure")
        } catch { }
        precondition(stored == "old-metadata" && credential == "old-token")
        do {
            try GitHubAccountPersistence.commit(writeMetadata: { stored = "new-metadata" },
                writeCredential: { throw GitHubConnectorError.keychain(-1) }, rollbackMetadata: { stored = "old-metadata" })
            fatalError("Expected credential failure")
        } catch GitHubConnectorError.keychain { }
        precondition(stored == "old-metadata" && credential == "old-token")
        try GitHubAccountPersistence.commit(writeMetadata: { stored = "new-metadata" },
            writeCredential: { credential = "new-token" }, rollbackMetadata: { stored = "old-metadata" })
        precondition(stored == "new-metadata" && credential == "new-token")
        done("account transaction reports failure and retains old credential/metadata until success")
        precondition(GitHubAPI.scopes("repo, read:org workflow") == ["read:org", "repo", "workflow"])
        let target = GitHubScopePolicy.requestedScopes
        precondition(GitHubScopePolicy.state(for: target) == .satisfied)
        precondition(GitHubScopePolicy.state(for: Array(target.reversed()) + target + ["extra:scope"]) == .satisfied)
        for missingScope in target {
            precondition(GitHubScopePolicy.state(for: target.filter { $0 != missingScope }) == .missing([missingScope]))
            precondition(GitHubScopePolicy.missingDescription([missingScope]).contains(missingScope))
        }
        precondition(GitHubScopePolicy.state(for: nil) == .unknown)
        precondition(GitHubScopePolicy.state(for: []) == .missing(target))
        let inherited = GitHubScopePolicy.effectiveScopes([
            "repo", "admin:org", "user", "admin:public_key", "admin:gpg_key",
            "admin:ssh_signing_key", "write:packages", "project", "admin:enterprise",
            "audit_log", "write:network_configurations"
        ])
        for child in ["public_repo", "repo:status", "repo_deployment", "repo:invite", "security_events",
                      "admin:repo_hook", "write:repo_hook", "read:repo_hook", "write:org", "read:org",
                      "read:user", "user:email", "user:follow", "write:public_key", "read:public_key",
                      "write:gpg_key", "read:gpg_key", "write:ssh_signing_key", "read:ssh_signing_key",
                      "read:packages", "read:project", "manage_runners:enterprise", "manage_billing:enterprise",
                      "read:enterprise", "scim:enterprise", "read:audit_log", "read:network_configurations"] {
            precondition(inherited.contains(child), "Missing inherited scope: \(child)")
        }
        precondition(!GitHubScopePolicy.effectiveScopes(["read:org", "read:user", "read:packages", "read:project"]).contains("admin:org"))
        precondition(!inherited.contains("delete_repo") && !inherited.contains("admin:org_hook"))
        precondition(!inherited.contains("workflow") && !inherited.contains("codespace:secrets"))
        done("scope policy handles parents, transitive children, separate grants, duplicates, order, nil and empty")

        let legacyData = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "login": "legacy", "displayName": "", "createdAt": "2026-01-01T00:00:00Z"
        ])
        let metadataDecoder = JSONDecoder()
        metadataDecoder.dateDecodingStrategy = .iso8601
        let legacyAccount = try metadataDecoder.decode(GitHubAccount.self, from: legacyData)
        precondition(legacyAccount.grantedScopes == nil && legacyAccount.loginMethod == nil)
        precondition(legacyAccount.scopeState == .unknown)
        let rawScopes = ["user", "repo", "repo"]
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        let manualAccount = GitHubAccount(id: legacyAccount.id, login: "legacy", displayName: "", avatarURL: nil,
            createdAt: legacyAccount.createdAt, grantedScopes: rawScopes, loginMethod: .manualToken)
        let roundTrip = try metadataDecoder.decode(GitHubAccount.self, from: metadataEncoder.encode(manualAccount))
        precondition(roundTrip.grantedScopes == rawScopes && roundTrip.loginMethod == .manualToken)
        done("legacy metadata decodes as unknown; raw grants and login method survive round trip")

        try GitHubScopePolicy.validateLogin(login: "Example", expectedLogin: "example", grantedScopes: target, method: .deviceAuthorization)
        let required = GitHubScopePolicy.requiredScopes
        let pending = GitHubScopePolicy.pendingScopes
        precondition(required.count == 16 && pending.count == 4 && Set(required).isDisjoint(with: pending))
        for pendingScope in pending {
            let grants = target.filter { $0 != pendingScope }
            try GitHubScopePolicy.validateLogin(login: "example", expectedLogin: "example", grantedScopes: grants, method: .deviceAuthorization)
            let account = GitHubAccount(id: UUID(), login: "example", displayName: "", avatarURL: nil,
                createdAt: .now, grantedScopes: grants, loginMethod: .deviceAuthorization)
            let saved = try metadataDecoder.decode(GitHubAccount.self, from: metadataEncoder.encode(account))
            precondition(saved.grantedScopes == grants && saved.scopeState == .missing([pendingScope]))
            precondition(saved.permissionSummary.contains(pendingScope) && saved.permissionSummary.contains("待核验专项"))
        }
        try GitHubScopePolicy.validateLogin(login: "example", expectedLogin: "example", grantedScopes: required, method: .deviceAuthorization)
        let restrictedAccount = GitHubAccount(id: UUID(), login: "example", displayName: "", avatarURL: nil,
            createdAt: .now, grantedScopes: required, loginMethod: .deviceAuthorization)
        let savedRestricted = try metadataDecoder.decode(GitHubAccount.self, from: metadataEncoder.encode(restrictedAccount))
        precondition(savedRestricted.grantedScopes == required && savedRestricted.scopeState == .missing(pending))
        for pendingScope in pending { precondition(savedRestricted.permissionSummary.contains(pendingScope)) }
        for missingRequired in required {
            for grants in [target.filter { $0 != missingRequired }, required.filter { $0 != missingRequired }] {
                do {
                    try GitHubScopePolicy.validateLogin(login: "example", expectedLogin: "example", grantedScopes: grants, method: .deviceAuthorization)
                    fatalError("Expected missing mandatory scope rejection")
                } catch GitHubConnectorError.permissionDenied(let detail) {
                    precondition(detail.contains(missingRequired))
                    for pendingScope in pending { precondition(!detail.contains(pendingScope)) }
                }
            }
        }
        done("pending scopes never block login; one or all missing stay in saved metadata/UI; all mandatory scopes remain enforced")
        try GitHubScopePolicy.validateLogin(login: "example", expectedLogin: nil, grantedScopes: nil, method: .manualToken)
        try GitHubScopePolicy.validateLogin(login: "example", expectedLogin: "example", grantedScopes: [], method: .manualToken)
        let insufficientGrants: [[String]?] = [nil, [], target.filter { $0 != "delete_repo" }]
        for grants in insufficientGrants {
            do {
                try GitHubScopePolicy.validateLogin(login: "example", expectedLogin: "example", grantedScopes: grants, method: .deviceAuthorization)
                fatalError("Expected unverified or insufficient device grant rejection")
            } catch GitHubConnectorError.permissionDenied(let detail) {
                precondition(!detail.isEmpty)
            }
        }
        for method in [GitHubLoginMethod.deviceAuthorization, .manualToken] {
            do {
                try GitHubScopePolicy.validateLogin(login: "other", expectedLogin: "example", grantedScopes: target, method: method)
                fatalError("Expected target account mismatch rejection")
            } catch GitHubConnectorError.accountMismatch(let expected, let actual) {
                precondition(expected == "example" && actual == "other")
            }
        }
        done("login policy rejects wrong accounts and unverified device grants, permits restricted manual tokens")
        precondition(GitHubAPI.encode("feature/a&ref=b") == "feature%2Fa%26ref%3Db")
        print("GitHub client runtime fixtures passed: \(passed)")
    }
}
