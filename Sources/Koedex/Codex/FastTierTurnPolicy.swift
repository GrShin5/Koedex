import Foundation

enum FastTierTurnPolicy {
    static func params(_ base: [String: Any], enabled: Bool, disabled: Bool = false) -> [String: Any] {
        var result = base
        result.removeValue(forKey: "serviceTierForTurn")
        if enabled && !disabled { result["serviceTierForTurn"] = "priority" }
        return result
    }
}

/// 高速tierを一時停止しているモード。
enum FastTierPauseMode: Hashable, Sendable {
    case aiCommand
    case optimization
}

/// AIに指示とカスタム指示の最適化は、失敗や実行ごとにclientが作り直されるため、
/// client側の一時停止だけでは次の依頼で高速tierが復活してしまう。
/// 停止状態をプロセス内（メモリのみ）で保持し、利用者がそのモードの設定を操作したら解除する。
final class FastTierPauseRegistry: @unchecked Sendable {
    static let shared = FastTierPauseRegistry()
    private let lock = NSLock()
    private var paused: Set<FastTierPauseMode> = []

    func isPaused(_ mode: FastTierPauseMode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paused.contains(mode)
    }

    /// 設定上の希望と停止状態から、今回のturnで高速tierを付けるかを決める。
    func effective(_ requested: Bool, for mode: FastTierPauseMode) -> Bool {
        requested && !isPaused(mode)
    }

    func pause(_ mode: FastTierPauseMode) {
        lock.lock()
        let inserted = paused.insert(mode).inserted
        lock.unlock()
        if inserted {
            AppLog.shared.warn("[FastTier] 高速tierを一時停止しました mode=\(mode)")
        }
    }

    func reset(_ mode: FastTierPauseMode) {
        lock.lock(); defer { lock.unlock() }
        paused.remove(mode)
    }

    func resetAll() {
        lock.lock(); defer { lock.unlock() }
        paused.removeAll()
    }
}
