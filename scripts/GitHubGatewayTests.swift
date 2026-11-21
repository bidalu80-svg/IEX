import Foundation

// Compile the complete production gateway. Only account/keychain and confirmation
// boundaries are fixtures; all validation/dispatch is the actual app code.
struct AgentToolParam {
    enum Kind { case string, integer, boolean }
    let type: Kind
    let description: String
}
struct AgentToolDefinition {
    let name: String
    let description: String
    let parameters: [String: AgentToolParam]
    let required: [String]
    let propertyOrdering: [String]
}
@MainActor final class GitHubAccountStore {
    static let shared = GitHubAccountStore()
    let accounts = [GitHubAccount(id: UUID(), login: "fixture", displayName: "", avatarURL: nil, createdAt: .now)]
    func token(for id: UUID) -> String? { "fixture-token" }
}
@MainActor final class RemoteServerAIConfirmationGate {
    static let shared = RemoteServerAIConfirmationGate()
    var requests: [AIApprovalPresentation] = []
    func request(_ presentation: AIApprovalPresentation, isDestructive: Bool) async -> Bool {
        precondition(isDestructive)
        requests.append(presentation)
        return false // Never allow a fixture to perform an external write.
    }
}
@main struct GitHubGatewayTests {
    @MainActor static func main() async {
        let gate = RemoteServerAIConfirmationGate.shared
        let identity = GitHubAccountStore.shared.accounts[0].id.uuidString
        for tool in ["github_file_read", "github_file_write", "github_file_delete"] {
            for path in ["..", "../x", "a/../../x", "/absolute", "a\0b", "a\nb"] {
                let result = await GitHubAIToolGateway.execute(name: tool, arguments: [
                    "account_id": identity, "owner": "example", "repository": "project", "path": path,
                    "content": "", "message": "fixture", "file_sha": "sha"])
                precondition(!result.success && result.output.contains("HTTP 400"))
                precondition(gate.requests.isEmpty)
            }
        }
        let repo = AIApprovalPresentation.Repository(account: "fixture", owner: "valid-owner", name: "valid.repo_name")
        let path = "dir/a & b.txt"
        for tool in ["github_file_write", "github_file_delete"] {
            let result = await GitHubAIToolGateway.execute(name: tool, arguments: [
                "account_id": identity, "owner": repo.owner, "repository": repo.name, "path": path,
                "content": "", "message": "fixture", "file_sha": "sha", "branch": "release/review"])
            precondition(!result.success && result.output.contains("用户拒绝"))
        }
        let sourceSHA = String(repeating: "a", count: 40)
        let commit = await GitHubAIToolGateway.execute(name: "github_commit_push", arguments: [
            "account_id": identity, "owner": repo.owner, "repository": repo.name, "branch": "release/review",
            "expected_head": sourceSHA, "message": "fixture commit",
            "changes_json": #"[{"path":"dir/new.txt","content":"a\nb"},{"path":"old.txt","delete":true}]"#])
        precondition(!commit.success && commit.output.contains("用户取消"))
        let branch = await GitHubAIToolGateway.execute(name: "github_branch_create", arguments: [
            "account_id": identity, "owner": repo.owner, "repository": repo.name,
            "branch": "feature/review", "from_sha": sourceSHA])
        precondition(!branch.success && branch.output.contains("用户取消"))
        precondition(gate.requests == [
            .githubWrite(repository: repo, branch: "release/review", path: path, message: "fixture", originalSHA: "sha", content: ""),
            .githubDelete(repository: repo, branch: "release/review", path: path, message: "fixture", fileSHA: "sha"),
            .githubCommit(repository: repo, branch: "release/review", expectedHead: sourceSHA, message: "fixture commit",
                          changes: [.write(path: "dir/new.txt", content: "a\nb"), .delete(path: "old.txt")]),
            .githubBranch(repository: repo, branch: "feature/review", fromSHA: sourceSHA),
        ])
        print("PASS: invalid paths stop before confirmation/HTTP; approval carries the exact repository, branch and file changes")
    }
}
