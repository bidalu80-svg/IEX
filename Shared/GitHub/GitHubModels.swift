import Foundation

struct GitHubAccount: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let login: String
    let displayName: String
    let avatarURL: URL?
    let createdAt: Date

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
    case rateLimited
    case http(Int, String)
    case malformedResponse
    case keychain(OSStatus)
    case storage(Error)

    var errorDescription: String? {
        switch self {
        case .clientIDMissing: return "尚未配置 GitHub OAuth Client ID；可以改用访问令牌登录。"
        case .invalidToken: return "GitHub 访问令牌无效或已过期。"
        case .expiredDeviceCode: return "GitHub 登录验证码已过期，请重新开始登录。"
        case .authorizationDenied: return "GitHub 登录被取消。"
        case .rateLimited: return "GitHub 请求过于频繁，请稍后再试。"
        case .http(let status, let detail): return "GitHub 请求失败（HTTP \(status)）：\(detail)"
        case .malformedResponse: return "GitHub 返回的数据格式异常。"
        case .keychain(let status): return "GitHub 令牌保存失败（Keychain \(status)）。"
        case .storage(let error): return "GitHub 账号保存失败：\(error.localizedDescription)"
        }
    }
}
