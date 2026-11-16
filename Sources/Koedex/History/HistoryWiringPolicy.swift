import Foundation

enum HistoryWiringPolicy {
    static func mayRecord(start: Bool, live: Bool) -> Bool { start && live }

    static func situation(for result: TextInjectorResult,
                          fallbackReason: NormalTextInsertionFallbackReason? = nil) -> HistoryRecordingPolicy.Situation {
        switch result {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted: return .inserted
        case .secureInputBlocked: return .secureInputBlocked
        case .externalCompatibilityDisabled: return .externalCompatibilityDisabledShown
        case .insertionUnconfirmed: return .insertionUnconfirmedShown
        case .failed: return .insertionFailedShown
        case .manualFallbackRequired:
            switch fallbackReason {
            case .payloadTooLong, nil: return .manualFallbackShown
            }
        case .clipboardMayHaveBeenLost, .clipboardVariantPasteMayHaveLostClipboard: return .manualFallbackShown
        case .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified: return .insertionUnconfirmedShown
        }
    }
}

/// 原文の回収先はメモリだけに保持する。
struct LastOriginalTranscript {
    private var text: String?
    private var expiresAt: Date?

    mutating func store(_ text: String, now: Date = Date()) {
        self.text = text
        expiresAt = now.addingTimeInterval(600)
    }

    func value(now: Date = Date()) -> String? {
        guard let expiresAt, now < expiresAt else { return nil }
        return text
    }

    mutating func clear() { text = nil; expiresAt = nil }
}
