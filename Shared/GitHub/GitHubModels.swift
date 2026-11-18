import Foundation

/// A finite OAuth target, not a claim of unrestricted account or API access.
enum GitHubScopePolicy {
    static let requirements: [(scope: String, description: String)] = [
        ("repo", "公私仓库及仓库 webhook"), ("workflow", "工作流"),
        ("delete_repo", "删除仓库"), ("admin:org", "组织、团队和成员管理"),
        ("admin:org_hook", "组织 webhook"), ("user", "账号资料、邮箱和关注"),
        ("gist", "Gist"), ("notifications", "通知"),
        ("admin:public_key", "SSH 身份验证公钥"), ("admin:gpg_key", "GPG 公钥"),
        ("admin:ssh_signing_key", "SSH 签名公钥"), ("write:packages", "包读写"),
        ("delete:packages", "删除包"), ("project", "Projects 读写"),
        ("codespace", "Codespaces 管理"), ("codespace:secrets", "Codespaces 秘密配置")
    ]
    // Request these scopes, but do not require them until client/endpoint support is verified.
    static let pendingRequirements: [(scope: String, description: String)] = [
        ("admin:enterprise", "企业管理"), ("read:audit_log", "审计日志读取"),
        ("manage_billing:copilot", "Copilot 席位和订阅管理"),
        ("write:network_configurations", "托管计算网络配置管理")
    ]
    static let requiredScopes = requirements.map(\.scope)
    static let pendingScopes = pendingRequirements.map(\.scope)
    static let requestedScopes = requiredScopes + pendingScopes
    static let requestValue = requestedScopes.joined(separator: " ")

    // GitHub normalizes grants to parent scopes. Keep raw metadata unchanged.
    private static let children: [String: Set<String>] = [
        "repo": ["public_repo", "repo:status", "repo_deployment", "repo:invite", "security_events", "admin:repo_hook"],
        "admin:repo_hook": ["write:repo_hook", "read:repo_hook"],
        "write:repo_hook": ["read:repo_hook"],
        "admin:org": ["write:org", "read:org"], "write:org": ["read:org"],
        "user": ["read:user", "user:email", "user:follow"],
        "admin:public_key": ["write:public_key", "read:public_key"],
        "write:public_key": ["read:public_key"],
        "admin:gpg_key": ["write:gpg_key", "read:gpg_key"], "write:gpg_key": ["read:gpg_key"],
        "admin:ssh_signing_key": ["write:ssh_signing_key", "read:ssh_signing_key"],
        "write:ssh_signing_key": ["read:ssh_signing_key"],
        "write:packages": ["read:packages"], "project": ["read:project"],
        "admin:enterprise": ["manage_runners:enterprise", "manage_billing:enterprise", "read:enterprise", "scim:enterprise"],
        "audit_log": ["read:audit_log"],
        "write:network_configurations": ["read:network_configurations"]
    ]

    static func effectiveScopes(_ granted: [String]) -> Set<String> {
        var result = Set(granted)
        var pending = granted
        while let scope = pending.popLast() {
            for child in children[scope] ?? [] where result.insert(child).inserted {
                pending.append(child)
            }
        }
        return result
    }

    static func state(for granted: [String]?) -> GitHubScopeState {
        guard let granted else { return .unknown }
        let effective = effectiveScopes(granted)
        let missing = requestedScopes.filter { !effective.contains($0) }
        return missing.isEmpty ? .satisfied : .missing(missing)
    }

    static func missingDescription(_ scopes: [String]) -> String {
        scopes.map { scope in
            let description = (requirements + pendingRequirements).first { $0.scope == scope }?.description ?? scope
            let pending = pendingScopes.contains(scope) ? "，待核验专项" : ""
            return "\(scope)（\(description)\(pending)）"
        }.joined(separator: "、")
    }

    /// Called before metadata or credentials are changed. Manual tokens may be restricted.
    static func validateLogin(login: String, expectedLogin: String?, grantedScopes: [String]?,
                              method: GitHubLoginMethod) throws {
        if let expectedLogin, login.caseInsensitiveCompare(expectedLogin) != .orderedSame {
            throw GitHubConnectorError.accountMismatch(expected: expectedLogin, actual: login)
        }
        if method == .deviceAuthorization {
            switch state(for: grantedScopes) {
            case .satisfied: break
            case .missing(let scopes):
                let requiredMissing = scopes.filter { requiredScopes.contains($0) }
                if !requiredMissing.isEmpty {
                    throw GitHubConnectorError.permissionDenied("缺少 " + missingDescription(requiredMissing) + "。请重新授权；原账号未替换。")
                }
            case .unknown:
                throw GitHubConnectorError.permissionDenied("无法核验授予的 scope，请重新授权或使用受限访问令牌登录；原账号未替换。")
            }
        }
    }
}

enum GitHubScopeState: Equatable, Sendable {
    case satisfied
    case missing([String])
    case unknown

    var summary: String {
        switch self {
        case .satisfied: return "已满足连接器要求的 scope；实际操作仍受账号角色和组织策略限制"
        case .missing(let scopes): return "缺少权限：" + GitHubScopePolicy.missingDescription(scopes)
        case .unknown: return "无法核验权限；细粒度令牌需按仓库和具体操作确认授权"
        }
    }
}

enum GitHubLoginMethod: String, Codable, Sendable {
    case deviceAuthorization
    case manualToken
}

/// Publish metadata before changing credentials; a failed metadata write never touches Keychain.
/// Keychain operations are atomic. If they fail, restore the previous metadata before reporting failure.
enum GitHubAccountPersistence {
    static func commit(writeMetadata: () throws -> Void, writeCredential: () throws -> Void,
                       rollbackMetadata: () throws -> Void) throws {
        try writeMetadata()
        do { try writeCredential() }
        catch {
            let credentialError = error
            do { try rollbackMetadata() }
            catch {
                throw GitHubConnectorError.storage(NSError(domain: "GitHubAccountPersistence", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "凭据未更新，恢复账号元数据失败，请重新登录。\(error.localizedDescription)",
                               NSUnderlyingErrorKey: credentialError]))
            }
            throw credentialError
        }
    }
}

struct GitHubAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let login: String
    let displayName: String
    let avatarURL: URL?
    let createdAt: Date
    var grantedScopes: [String]? = nil
    var loginMethod: GitHubLoginMethod? = nil

    var scopeState: GitHubScopeState { GitHubScopePolicy.state(for: grantedScopes) }
    var permissionSummary: String { scopeState.summary }

    var title: String { displayName.isEmpty ? login : displayName }
}

struct GitHubDeviceAuthorization: Identifiable, Sendable {
    let id = UUID()
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresIn: TimeInterval
    let pollingInterval: TimeInterval
}

enum GitHubConnectorError: LocalizedError {
    case clientIDMissing
    case invalidToken
    case expiredDeviceCode
    case authorizationDenied
    case accountMismatch(expected: String, actual: String)
    case rateLimited
    case http(Int, String)
    case malformedResponse
    case keychain(OSStatus)
    case storage(Error)
    case permissionDenied(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .clientIDMissing: return "尚未配置 GitHub OAuth Client ID；可以改用访问令牌登录。"
        case .invalidToken: return "GitHub 访问令牌无效或已过期。"
        case .expiredDeviceCode: return "GitHub 登录验证码已过期，请重新开始登录。"
        case .authorizationDenied: return "GitHub 登录被取消。"
        case .accountMismatch(let expected, let actual): return "需要为 \(expected) 补权，但本次登录的是 \(actual)。请切换 GitHub 账号后重试；原账号未替换。"
        case .rateLimited: return "GitHub 请求过于频繁，请稍后再试。"
        case .http(let status, let detail): return "GitHub 请求失败（HTTP \(status)）：\(detail)"
        case .malformedResponse: return "GitHub 返回的数据格式异常。"
        case .keychain(let status): return "GitHub 令牌保存失败（Keychain \(status)）。"
        case .storage(let error): return "GitHub 账号保存失败：\(error.localizedDescription)"
        case .permissionDenied(let detail): return "GitHub 权限不足：\(detail)"
        case .conflict(let detail): return "GitHub 分支或文件已变化：\(detail)"
        }
    }
}
