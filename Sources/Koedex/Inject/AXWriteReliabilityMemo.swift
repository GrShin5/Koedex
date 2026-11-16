/// AX書込みの未反映をプロセス内だけで記憶する。永続化しない。
@MainActor
final class AXWriteReliabilityMemo {
    struct Key: Hashable {
        let bundleIdentifier: String
        var fieldSignature: String? = nil
    }

    enum Outcome {
        case unchangedAtFinalAttempt
        case matched
        case inserted
    }

    private var consecutiveFailures: [Key: Int] = [:]

    private var successfulSkips: [Key: Int] = [:]

    func record(_ outcome: Outcome, for key: Key, allowAXSkipMemo: Bool = true) {
        guard allowAXSkipMemo else { return }
        successfulSkips.removeValue(forKey: key)
        switch outcome {
        case .unchangedAtFinalAttempt:
            consecutiveFailures[key] = min(2, (consecutiveFailures[key] ?? 0) + 1)
        case .matched, .inserted:
            consecutiveFailures.removeValue(forKey: key)
        }
    }

    func shouldSkipDirectAXWrite(_ key: Key) -> Bool {
        (consecutiveFailures[key] ?? 0) >= 2
    }

    // 呼び出し側が通常入力と確定できた場合だけ有効にする。
    func shouldSkipDirectAXWrite(
        _ key: Key,
        allowAXSkipMemo: Bool,
        allowExternalCompatibility: Bool
    ) -> Bool {
        allowAXSkipMemo && allowExternalCompatibility && shouldSkipDirectAXWrite(key)
    }

    func recordSkippedSubmission(_ result: TextInjectorResult, for key: Key) {
        switch result {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted:
            successfulSkips[key] = (successfulSkips[key] ?? 0) + 1
            if successfulSkips[key] == 10 {
                consecutiveFailures.removeValue(forKey: key)
                successfulSkips.removeValue(forKey: key)
            }
        default:
            successfulSkips.removeValue(forKey: key)
            consecutiveFailures.removeValue(forKey: key)
        }
    }
}
