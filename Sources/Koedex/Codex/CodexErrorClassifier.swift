import Foundation

enum CodexRPCFailureKind: Equatable {
    case rateLimited
    case quotaExhausted
    case authFailed
    case other

    var userMessage: String {
        switch self {
        case .rateLimited:
            return "レートリミットに達しています。しばらく待ってから再試行してください"
        case .quotaExhausted:
            return "利用枠を使い切っています。プランや請求設定を確認してください"
        case .authFailed:
            return "Codexの認証に失敗しています。codex loginで再ログインしてください"
        case .other:
            return ""
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .rateLimited:
            return "レートリミット"
        case .quotaExhausted:
            return "利用枠エラー"
        case .authFailed:
            return "認証エラー"
        case .other:
            return ""
        }
    }
}

enum CodexErrorClassifier {
    /// JSON-RPC本文は認証URLやその他の機微情報を含み得るため、数値codeだけで分類する。
    static func classify(code: Int) -> CodexRPCFailureKind {
        switch code {
        case 429:
            return .rateLimited
        case 402:
            return .quotaExhausted
        case 401, 403:
            return .authFailed
        default:
            return .other
        }
    }
}
