/// Pure policy for deciding whether a focused application's selection can be
/// read directly, requires the guarded temporary-copy fallback, or must not be
/// used. Keeping this separate from Accessibility APIs makes the privacy
/// boundary directly regression-testable.
enum SelectionCapturePolicy {
    enum SelectedTextRead: Equatable {
        case text(String)
        case noValue
        case unavailable
    }

    enum SelectedTextRange: Equatable {
        case unavailable
        case zeroLength
        case nonzeroLength
    }

    enum Decision: Equatable {
        case selectedText(String)
        case noSelection
        case temporaryCopy
        case unavailable(SelectionCaptureFailure)
    }

    /// - Parameter bundleIdentifier: **Deliberately unused.** The self-selection guard
    ///   formerly branched on it to block AI-command on text
    ///   selected in Koedex's own Settings window. The user reviewed the privacy
    ///   trade-off and asked for that to be reverted (2026-07-30), so our own windows
    ///   are now treated like any other app's. The parameter is kept so the regression
    ///   suite can assert that Koedex bundle IDs produce identical decisions to a
    ///   third-party one — that assertion is what stops the guard being reintroduced
    ///   without a deliberate decision.
    static func decision(
        bundleIdentifier: String?,
        focusedElementAvailable: Bool,
        selectedText: SelectedTextRead,
        selectedTextRange: SelectedTextRange,
        allowsTemporaryCopy: Bool = false
    ) -> Decision {
        _ = bundleIdentifier
        // A missing focus is ambiguous: it can mean "no selection", but Web
        // and Electron surfaces also hide their focused element. Never switch
        // silently to a general question. Once the user has explicitly enabled
        // compatibility, try the same-frontmost-app temporary copy path.
        guard focusedElementAvailable else {
            return allowsTemporaryCopy
                ? .temporaryCopy
                : .unavailable(.externalCompatibilityDisabled)
        }

        switch selectedText {
        case .text(let text):
            guard text.isEmpty else { return .selectedText(text) }
            if selectedTextRange == .zeroLength { return .noSelection }
            return allowsTemporaryCopy
                ? .temporaryCopy
                : .unavailable(.externalCompatibilityDisabled)
        case .noValue:
            if selectedTextRange == .zeroLength { return .noSelection }
            return allowsTemporaryCopy
                ? .temporaryCopy
                : .unavailable(.externalCompatibilityDisabled)
        case .unavailable:
            if selectedTextRange == .zeroLength { return .noSelection }
            return allowsTemporaryCopy
                ? .temporaryCopy
                : .unavailable(.externalCompatibilityDisabled)
        }
    }

}
