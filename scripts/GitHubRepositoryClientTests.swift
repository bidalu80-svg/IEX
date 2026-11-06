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
        precondition(GitHubAPI.scopes("repo, read:org workflow") == ["read:org", "repo", "workflow"])
        precondition(GitHubAPI.encode("feature/a&ref=b") == "feature%2Fa%26ref%3Db")
        print("GitHub client runtime fixtures passed: \(passed)")
    }
}
