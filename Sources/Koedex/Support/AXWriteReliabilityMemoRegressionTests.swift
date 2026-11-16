@MainActor
enum AXWriteReliabilityMemoRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        let memo = AXWriteReliabilityMemo()
        let key = AXWriteReliabilityMemo.Key(bundleIdentifier: "test.app.a")
        let other = AXWriteReliabilityMemo.Key(bundleIdentifier: "test.app.b")
        let field = AXWriteReliabilityMemo.Key(bundleIdentifier: "test.app.a", fieldSignature: "AXTextField")
        memo.record(.unchangedAtFinalAttempt, for: key)
        expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: one failure does not skip")
        memo.record(.unchangedAtFinalAttempt, for: key)
        expect(memo.shouldSkipDirectAXWrite(key), "AX memo: two consecutive failures skip")
        expect(!memo.shouldSkipDirectAXWrite(other), "AX memo: apps are isolated")
        expect(!memo.shouldSkipDirectAXWrite(field), "AX memo: field signatures are isolated")
        expect(!memo.shouldSkipDirectAXWrite(key, allowAXSkipMemo: false, allowExternalCompatibility: true), "AX memo: disabled or hands-free caller never skips")
        expect(!memo.shouldSkipDirectAXWrite(key, allowAXSkipMemo: true, allowExternalCompatibility: false), "AX memo: compatibility consent is required")
        expect(memo.shouldSkipDirectAXWrite(key, allowAXSkipMemo: true, allowExternalCompatibility: true), "AX memo: enabled normal caller skips")
        memo.record(.matched, for: key)
        expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: immediate or late match resets")
        memo.record(.unchangedAtFinalAttempt, for: key)
        expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: failure after match starts at one")
        memo.record(.unchangedAtFinalAttempt, for: key)
        memo.record(.inserted, for: key)
        expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: inserted resets")
        memo.record(.unchangedAtFinalAttempt, for: key)
        memo.record(.unchangedAtFinalAttempt, for: key)
        memo.recordSkippedSubmission(.unicodeSubmitted, for: key)
        expect(memo.shouldSkipDirectAXWrite(key), "AX memo: Unicode submission preserves skip")
        memo.recordSkippedSubmission(.inserted, for: key)
        expect(memo.shouldSkipDirectAXWrite(key), "AX memo: successful skipped insertion preserves skip")
        memo.recordSkippedSubmission(.scopedClipboardFallbackSubmitted, for: key)
        expect(memo.shouldSkipDirectAXWrite(key), "AX memo: scoped clipboard counts as success")
        for _ in 0..<6 { memo.recordSkippedSubmission(.unicodeSubmitted, for: key) }
        expect(memo.shouldSkipDirectAXWrite(key), "AX memo: nine successes retain skip")
        memo.recordSkippedSubmission(.unicodeSubmitted, for: key)
        expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: ten successes re-probe AX")
        memo.record(.unchangedAtFinalAttempt, for: key, allowAXSkipMemo: false)
        memo.record(.unchangedAtFinalAttempt, for: key, allowAXSkipMemo: false)
        expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: opted-out outcomes never train")
        let failures: [TextInjectorResult] = [
            .manualFallbackRequired, .secureInputBlocked, .insertionUnconfirmed,
            .externalCompatibilityDisabled,
            .clipboardMayHaveBeenLost, .clipboardVariantPasteConfirmed,
            .clipboardVariantPasteSubmittedUnverified, .clipboardVariantPasteMayHaveLostClipboard,
            .failed(TextInjectorError.targetChangedBeforePaste)
        ]
        for failure in failures {
            memo.record(.unchangedAtFinalAttempt, for: key)
            memo.record(.unchangedAtFinalAttempt, for: key)
            memo.recordSkippedSubmission(failure, for: key)
            expect(!memo.shouldSkipDirectAXWrite(key), "AX memo: unsuccessful skipped submission resets")
        }
        expect(!AXWriteReliabilityMemo().shouldSkipDirectAXWrite(key), "AX memo: new process memo starts empty")
    }
}
