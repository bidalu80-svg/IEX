import Foundation

enum LLMError: LocalizedError {
    case invalidAPIKey(detail: String = "")
    case networkError(underlying: Error)
    case providerError(message: String)
    /// Transient server-side errors (HTTP 500/502/503/504/529) that should be
    /// retried on the same model rather than triggering a group fallback.
    case transientError(message: String)
    case decodingError(underlying: Error)
    case rateLimited
    case cancelled
    case unknown(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey(let detail):
            return detail.isEmpty ? "API 密钥无效" : "API 密钥无效：\(detail)"
        case .networkError(let error):
            return "网络错误：\(error.localizedDescription)"
        case .providerError(let message):
            return "服务商错误：\(message)"
        case .transientError(let message):
            return "服务暂时不可用：\(message)"
        case .decodingError(let error):
            return "响应解析失败：\(error.localizedDescription)"
        case .rateLimited:
            return "请求过于频繁，请稍后重试。"
        case .cancelled:
            return "请求已取消"
        case .unknown(let error):
            return "未知错误：\(error?.localizedDescription ?? "无详细信息")"
        }
    }

    var isNetworkError: Bool {
        if case .networkError = self { return true }
        return false
    }

    /// Errors that should be retried with countdown on the same provider.
    /// Includes both network errors and transient server-side errors (5xx).
    var isRetryable: Bool {
        switch self {
        case .networkError, .transientError:
            return true
        case .invalidAPIKey, .providerError, .decodingError, .rateLimited, .cancelled, .unknown:
            return false
        }
    }

    /// Errors that indicate the provider itself cannot serve this request
    /// (rate limit, invalid key, permanent provider-side rejection). These trigger
    /// an immediate fallback to the next model in a group, without retry countdown.
    ///
    /// Note: transientError and networkError are also fallbackable — after
    /// auto-retry is exhausted on the current model, group fallback kicks in.
    var fallbackReason: String {
        switch self {
        case .rateLimited: return "请求过于频繁"
        case .invalidAPIKey: return "API 密钥无效"
        case .providerError(let msg): return "服务商错误：\(String(msg.prefix(60)))"
        default: return "错误"
        }
    }

    var isFallbackable: Bool {
        switch self {
        case .rateLimited, .invalidAPIKey, .providerError:
            return true
        case .transientError, .networkError, .decodingError, .cancelled, .unknown:
            return false
        }
    }
}
