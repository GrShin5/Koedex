import Foundation

/// 出力を届けた状況から保存内容を決める。呼び出し側の設定判断とは独立する。
enum HistoryRecordingPolicy {
    enum Situation: Equatable {
        case inserted, pasteSentUnverified
        case insertionFailedShown, insertionUnconfirmedShown, manualFallbackShown
        case externalCompatibilityDisabledShown, compatibilityGuideShown
        case handsFreeCleanupFailureShown
        case triggerMismatchShown, unsafeFinalizeShown
        case secureInputBlocked
        case triggerOnlySend, cancelled, emptyOutput, customInstructionOptimization
        case aiCommandInserted, aiCommandPasteSentUnverified, aiCommandShown
    }

    struct Decision: Equatable {
        let storedText: String?
        let spokenInstruction: String?
        let kind: String
        let status: String
        let flags: [String]
    }

    static func decision(output: String, situation: Situation,
                         cleanupEnabled: Bool = false, cleanupDidFail: Bool = false,
                         spokenInstruction: String? = nil, extraFlags: [String] = []) -> Decision? {
        switch situation {
        case .triggerOnlySend, .cancelled, .emptyOutput, .customInstructionOptimization: return nil
        case .secureInputBlocked:
            return Decision(storedText: nil, spokenInstruction: nil,
                kind: InputHistoryStoredTextKind.none, status: InputHistoryInsertStatus.secureInputBlocked,
                flags: [InputHistoryFlag.secureInputBlocked])
        default: break
        }
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        let aiCommand = situation == .aiCommandInserted || situation == .aiCommandPasteSentUnverified || situation == .aiCommandShown
        let review = situation == .triggerMismatchShown || situation == .unsafeFinalizeShown
        let failed = cleanupDidFail || situation == .handsFreeCleanupFailureShown
        let status: String
        switch situation {
        case .inserted, .aiCommandInserted: status = InputHistoryInsertStatus.inserted
        case .pasteSentUnverified, .aiCommandPasteSentUnverified: status = InputHistoryInsertStatus.pasteSentUnverified
        default: status = InputHistoryInsertStatus.shownInWindow
        }
        var flags: [String] = []
        if !aiCommand && !review {
            if !cleanupEnabled { flags.append(InputHistoryFlag.noiseCandidate) }
            if failed { flags.append(InputHistoryFlag.cleanupFailed) }
        }
        if review { flags.append(InputHistoryFlag.needsReview) }
        if situation == .insertionFailedShown { flags.append(InputHistoryFlag.insertFailed) }
        let kind = aiCommand ? InputHistoryStoredTextKind.aiCommandOutput
            : review ? InputHistoryStoredTextKind.reviewText
            : cleanupEnabled && !failed ? InputHistoryStoredTextKind.aiAssistedOutput
            : InputHistoryStoredTextKind.rawTranscriptOutput
        return Decision(storedText: output, spokenInstruction: aiCommand ? spokenInstruction : nil,
                        kind: kind, status: status, flags: Array(Set(flags + extraFlags)).sorted())
    }
}
