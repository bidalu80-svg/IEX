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
    var requests = 0
    func request(serverName: String, operation: String, detail: String, isDestructive: Bool) async -> Bool {
        requests += 1
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
                precondition(gate.requests == 0)
            }
        }
        for tool in ["github_file_write", "github_file_delete"] {
            let result = await GitHubAIToolGateway.execute(name: tool, arguments: [
                "account_id": identity, "owner": "valid-owner", "repository": "valid.repo_name", "path": "dir/a & b.txt",
                "content": "", "message": "fixture", "file_sha": "sha"])
            precondition(!result.success && result.output.contains("用户拒绝"))
        }
        precondition(gate.requests == 2)
        print("PASS: actual gateway rejects invalid file paths before confirmation/HTTP; valid names and empty content reach confirmation")
    }
}
