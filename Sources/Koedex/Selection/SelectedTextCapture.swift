import AppKit
import Carbon.HIToolbox

enum SelectionCaptureFailure: Equatable {
    case accessibilityPermissionMissing
    case secureInput
    case focusedElementUnavailable
    case externalCompatibilityDisabled
    case selectionUnsupported
    case copyDidNotProduceText
    case clipboardChanged
    case clipboardRestoreFailed
}

/// The selected text is captured at AI-command start as immutable model input.
/// Its output target is captured independently when recording stops, so this
/// start-time source never needs to bind an insertion destination.
@MainActor
struct SelectedTextCaptureContext {
    let text: String
}

@MainActor
enum SelectionCaptureResult {
    case selected(SelectedTextCaptureContext)
    case none
    case unavailable(SelectionCaptureFailure)
    case tooLong(actual: Int, maximum: Int)
    case cancelledTemporaryCopy(ClipboardCancellationReceipt)
}

@MainActor
final class ClipboardCancellationReceipt {
    enum Resolution: Equatable {
        case restored
        case preserved
        case clipboardChanged
        case expired
        case revoked
        case alreadyResolved
        case restoreFailed
    }

    nonisolated static let lifetimeSeconds: TimeInterval = 10
    private let expectedChangeCount: Int
    private var currentChangeCount: (() -> Int)?
    private var restoreSnapshot: ((Int) -> Bool)?
    private let now: () -> Date
    private let expiresAt: Date
    private var isValid = true
    private var didResolve = false

    init(
        expectedChangeCount: Int,
        lifetimeSeconds: TimeInterval = ClipboardCancellationReceipt.lifetimeSeconds,
        currentChangeCount: @escaping () -> Int,
        restoreSnapshot: @escaping (Int) -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.expectedChangeCount = expectedChangeCount
        self.currentChangeCount = currentChangeCount
        self.restoreSnapshot = restoreSnapshot
        self.now = now
        self.expiresAt = now().addingTimeInterval(min(Self.lifetimeSeconds, max(0, lifetimeSeconds)))
    }

    func resolve(restoreOriginal: Bool) -> Resolution {
        guard !didResolve else { return .alreadyResolved }
        didResolve = true
        guard isValid, let currentChangeCount, let restoreSnapshot else {
            releaseSnapshot()
            return .revoked
        }
        isValid = false
        guard now() < expiresAt else {
            releaseSnapshot()
            return .expired
        }
        guard restoreOriginal else {
            releaseSnapshot()
            return .preserved
        }
        guard currentChangeCount() == expectedChangeCount else {
            releaseSnapshot()
            return .clipboardChanged
        }
        let restored = restoreSnapshot(expectedChangeCount)
        releaseSnapshot()
        return restored ? .restored : .restoreFailed
    }

    func invalidate() {
        isValid = false
        releaseSnapshot()
    }

    func isUsable() -> Bool {
        guard isValid,
              !didResolve,
              now() < expiresAt,
              currentChangeCount?() == expectedChangeCount else {
            invalidate()
            return false
        }
        return true
    }

    private func releaseSnapshot() {
        currentChangeCount = nil
        restoreSnapshot = nil
    }
}

/// Owns one selection-capture completion across cancellation and replacement.
/// A recovery receipt is accepted only for the capture explicitly cancelled by
/// the user's Esc action; all other late completions are inert.
@MainActor
final class AICommandCaptureCompletionGate {
    struct Lease: Equatable {
        let id: UUID
        let generation: UInt64
    }

    enum Completion {
        case current
        case recovery(ClipboardCancellationReceipt)
        case stale
    }

    private var generation: UInt64 = 0
    private(set) var activeCaptureID: UUID?
    private var recoveryAuthorizedCaptureID: UUID?

    func begin(id: UUID = UUID()) -> Lease {
        generation &+= 1
        activeCaptureID = id
        recoveryAuthorizedCaptureID = nil
        return Lease(id: id, generation: generation)
    }

    func authorizeUserCancellation() {
        recoveryAuthorizedCaptureID = activeCaptureID
        activeCaptureID = nil
    }

    func revokeAll() {
        activeCaptureID = nil
        recoveryAuthorizedCaptureID = nil
    }

    func revokeActive(id: UUID) {
        guard activeCaptureID == id else { return }
        activeCaptureID = nil
        recoveryAuthorizedCaptureID = nil
    }

    func finishIfCurrent(_ lease: Lease) {
        guard owns(lease) else { return }
        activeCaptureID = nil
    }

    func classify(
        _ result: SelectionCaptureResult,
        lease: Lease,
        appIsIdle: Bool
    ) -> Completion {
        if case .cancelledTemporaryCopy(let receipt) = result {
            guard lease.generation == generation,
                  recoveryAuthorizedCaptureID == lease.id,
                  activeCaptureID == nil,
                  appIsIdle else {
                receipt.invalidate()
                return .stale
            }
            recoveryAuthorizedCaptureID = nil
            return .recovery(receipt)
        }
        guard owns(lease) else { return .stale }
        return .current
    }

    private func owns(_ lease: Lease) -> Bool {
        lease.generation == generation && activeCaptureID == lease.id
    }
}

/// Captures the selection at recording start. AX is authoritative; Cmd-C is a
/// consent-gated fallback that restores the user's pasteboard before recording
/// begins whenever ownership can still be proven.
@MainActor
final class SelectedTextCapture {
    static let maximumCharacters = 12_000
    private let copyPollNanoseconds: UInt64 = 25_000_000
    private let copyPollAttempts = 13

    struct TemporaryCopyTestRuntime {
        let snapshotIsComplete: Bool
        let snapshotStillCurrent: () -> Bool
        let changeCount: () -> Int
        let copiedString: () -> String?
        let postCopy: () -> Bool
        let secureInputEnabled: () -> Bool
        let targetMatches: () -> Bool
        let restoreSnapshot: (Int) -> Bool
        var sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
        var receiptLifetimeSeconds: TimeInterval = ClipboardCancellationReceipt.lifetimeSeconds
        var now: () -> Date = Date.init
    }

    @MainActor
    private enum CaptureTarget {
        case exact(processIdentifier: pid_t, focusedElement: AXUIElement)
        case appOnly(NormalPasteTarget)

        func matchesCurrentTarget() -> Bool {
            switch self {
            case .appOnly(let target):
                return target.matchesCurrentFrontmostApplication()
            case .exact(let processIdentifier, let focusedElement):
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                    return false
                }
                let application = AXUIElementCreateApplication(processIdentifier)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    application,
                    kAXFocusedUIElementAttribute as CFString,
                    &value
                ) == .success, let value else {
                    return false
                }
                return CFEqual(unsafeBitCast(value, to: AXUIElement.self), focusedElement)
            }
        }

    }

    func capture(allowingExternalCompatibility: Bool = false) async -> SelectionCaptureResult {
        guard AXIsProcessTrusted() else { return .unavailable(.accessibilityPermissionMissing) }
        guard !IsSecureEventInputEnabled() else { return .unavailable(.secureInput) }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            // テキスト入力先がなくても、選択なしのAIへの質問は実行できる。
            return .none
        }

        let appOnlyTarget = NormalPasteTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedElementAvailable = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success && focusedValue != nil

        guard let focusedValue else {
            let decision = SelectionCapturePolicy.decision(
                bundleIdentifier: app.bundleIdentifier,
                focusedElementAvailable: false,
                selectedText: .unavailable,
                selectedTextRange: .unavailable,
                allowsTemporaryCopy: allowingExternalCompatibility
            )
            return await result(for: decision, target: .appOnly(appOnlyTarget))
        }

        let focused = unsafeBitCast(focusedValue, to: AXUIElement.self)
        let decision = SelectionCapturePolicy.decision(
            bundleIdentifier: app.bundleIdentifier,
            focusedElementAvailable: focusedElementAvailable,
            selectedText: selectedTextRead(of: focused),
            selectedTextRange: selectedTextRangeState(of: focused),
            allowsTemporaryCopy: allowingExternalCompatibility
        )
        // WebKitは同一入力欄でもAXプロキシを返し直すことがある。直接読めた選択は
        // 現在の要素で確認するが、Cmd-Cを送る互換経路だけは同一前面アプリの確認へ
        // 狭め、proxy同一性だけでSafariの選択取得を失敗させない。
        let target: CaptureTarget
        if case .temporaryCopy = decision {
            target = .appOnly(appOnlyTarget)
        } else {
            target = .exact(processIdentifier: app.processIdentifier, focusedElement: focused)
        }
        return await result(for: decision, target: target)
    }

    /// Before an explicitly enabled AX-less AI replacement, recapture the
    /// current selection once and require exactly the text that started the
    /// request. This narrows, but cannot eliminate, same-app copy races.
    func revalidateExternalSelection(
        expectedText: String,
        target: NormalPasteTarget
    ) async -> Bool {
        guard !IsSecureEventInputEnabled(), target.matchesCurrentFrontmostApplication() else {
            return false
        }
        let result = await captureByTemporaryCopy(target: .appOnly(target))
        guard case .selected(let context) = result,
              context.text == expectedText,
              target.matchesCurrentFrontmostApplication(),
              !IsSecureEventInputEnabled() else {
            return false
        }
        return true
    }

    private func validated(
        _ text: String
    ) -> SelectionCaptureResult {
        guard !text.isEmpty else { return .none }
        guard text.count <= Self.maximumCharacters else {
            return .tooLong(actual: text.count, maximum: Self.maximumCharacters)
        }
        return .selected(SelectedTextCaptureContext(text: text))
    }

    private func result(
        for decision: SelectionCapturePolicy.Decision,
        target: CaptureTarget
    ) async -> SelectionCaptureResult {
        switch decision {
        case .selectedText(let text):
            guard target.matchesCurrentTarget() else {
                return .unavailable(.focusedElementUnavailable)
            }
            return validated(text)
        case .noSelection:
            return .none
        case .temporaryCopy:
            return await captureByTemporaryCopy(target: target)
        case .unavailable(let failure):
            return .unavailable(failure)
        }
    }

    private func captureByTemporaryCopy(target: CaptureTarget) async -> SelectionCaptureResult {
        guard target.matchesCurrentTarget() else {
            return .unavailable(.focusedElementUnavailable)
        }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        let runtime = TemporaryCopyTestRuntime(
            snapshotIsComplete: snapshot.isComplete,
            snapshotStillCurrent: { snapshot.stillRepresentsCurrentContents(of: pasteboard) },
            changeCount: { pasteboard.changeCount },
            copiedString: { pasteboard.string(forType: .string) },
            postCopy: postCommandC,
            secureInputEnabled: IsSecureEventInputEnabled,
            targetMatches: target.matchesCurrentTarget,
            restoreSnapshot: { snapshot.restore(to: pasteboard, ifChangeCountIs: $0) }
        )
        return await captureByTemporaryCopy(runtime: runtime)
    }

    func debugCaptureTemporaryCopy(runtime: TemporaryCopyTestRuntime) async -> SelectionCaptureResult {
        await captureByTemporaryCopy(runtime: runtime)
    }

    private func captureByTemporaryCopy(runtime: TemporaryCopyTestRuntime) async -> SelectionCaptureResult {
        guard runtime.targetMatches() else {
            return .unavailable(.focusedElementUnavailable)
        }
        guard runtime.snapshotIsComplete else {
            return .unavailable(.clipboardRestoreFailed)
        }
        guard runtime.snapshotStillCurrent() else {
            return .unavailable(.clipboardChanged)
        }
        let before = runtime.changeCount()
        guard runtime.postCopy() else { return .unavailable(.selectionUnsupported) }

        var copiedChangeCount: Int?
        var copiedText: String?
        for attempt in 0..<copyPollAttempts {
            let currentChangeCount = runtime.changeCount()
            if currentChangeCount != before {
                if let copiedChangeCount, copiedChangeCount != currentChangeCount {
                    // A second write may be a user copy. Its author cannot be
                    // identified, so never restore over it.
                    return .unavailable(.clipboardChanged)
                }
                copiedChangeCount = currentChangeCount
            }

            if Task.isCancelled {
                return await cancelledTemporaryCopyResult(
                    runtime: runtime,
                    beforeChangeCount: before,
                    copiedChangeCount: copiedChangeCount,
                    remainingPolls: copyPollAttempts - attempt - 1
                )
            }
            if runtime.secureInputEnabled() {
                return finishTemporaryCopyFailure(
                    .secureInput,
                    runtime: runtime,
                    copiedChangeCount: copiedChangeCount,
                    restoreAllowed: false
                )
            }
            guard runtime.targetMatches() else {
                return finishTemporaryCopyFailure(
                    .focusedElementUnavailable,
                    runtime: runtime,
                    copiedChangeCount: copiedChangeCount,
                    restoreAllowed: false
                )
            }

            if copiedChangeCount != nil {
                copiedText = runtime.copiedString()
                if copiedText != nil { break }
            }
            guard attempt + 1 < copyPollAttempts else { break }
            await runtime.sleep(copyPollNanoseconds)
        }

        guard let copiedChangeCount else {
            // No clipboard change is ambiguous. The UI must offer an explicit
            // "選択なしで質問する" action rather than guessing a general query.
            return .unavailable(.copyDidNotProduceText)
        }
        guard let copiedText else {
            return finishTemporaryCopyFailure(
                .copyDidNotProduceText,
                runtime: runtime,
                copiedChangeCount: copiedChangeCount,
                restoreAllowed: true
            )
        }

        if Task.isCancelled {
            return await cancelledTemporaryCopyResult(
                runtime: runtime,
                beforeChangeCount: before,
                copiedChangeCount: copiedChangeCount,
                remainingPolls: 0
            )
        }
        if runtime.secureInputEnabled() {
            return finishTemporaryCopyFailure(
                .secureInput,
                runtime: runtime,
                copiedChangeCount: copiedChangeCount,
                restoreAllowed: false
            )
        }
        guard runtime.targetMatches() else {
            return finishTemporaryCopyFailure(
                .focusedElementUnavailable,
                runtime: runtime,
                copiedChangeCount: copiedChangeCount,
                restoreAllowed: false
            )
        }
        guard runtime.changeCount() == copiedChangeCount else {
            return .unavailable(.clipboardChanged)
        }
        guard runtime.restoreSnapshot(copiedChangeCount) else {
            if runtime.changeCount() != copiedChangeCount {
                return .unavailable(.clipboardChanged)
            }
            return .unavailable(.clipboardRestoreFailed)
        }
        return validated(copiedText)
    }

    private func finishTemporaryCopyFailure(
        _ failure: SelectionCaptureFailure,
        runtime: TemporaryCopyTestRuntime,
        copiedChangeCount: Int?,
        restoreAllowed: Bool
    ) -> SelectionCaptureResult {
        guard restoreAllowed, let copiedChangeCount else {
            return .unavailable(failure)
        }
        guard runtime.changeCount() == copiedChangeCount else {
            return .unavailable(.clipboardChanged)
        }
        guard runtime.restoreSnapshot(copiedChangeCount) else {
            return .unavailable(.clipboardRestoreFailed)
        }
        return .unavailable(failure)
    }

    private func cancelledTemporaryCopyResult(
        runtime: TemporaryCopyTestRuntime,
        beforeChangeCount: Int,
        copiedChangeCount initialCopiedChangeCount: Int?,
        remainingPolls: Int
    ) async -> SelectionCaptureResult {
        var copiedChangeCount = initialCopiedChangeCount
        if let copiedChangeCount, copiedChangeCount != beforeChangeCount + 1 {
            return .unavailable(.clipboardChanged)
        }
        for _ in 0..<max(0, remainingPolls) {
            await Task.detached { await runtime.sleep(self.copyPollNanoseconds) }.value
            let current = runtime.changeCount()
            if current == beforeChangeCount { continue }
            guard current == beforeChangeCount + 1 else {
                return .unavailable(.clipboardChanged)
            }
            if let copiedChangeCount, copiedChangeCount != current {
                return .unavailable(.clipboardChanged)
            }
            copiedChangeCount = current
        }
        guard let copiedChangeCount else { return .unavailable(.selectionUnsupported) }
        return .cancelledTemporaryCopy(ClipboardCancellationReceipt(
            expectedChangeCount: copiedChangeCount,
            lifetimeSeconds: runtime.receiptLifetimeSeconds,
            currentChangeCount: runtime.changeCount,
            restoreSnapshot: runtime.restoreSnapshot,
            now: runtime.now
        ))
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func selectedTextRead(of element: AXUIElement) -> SelectionCapturePolicy.SelectedTextRead {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) {
        case .success:
            return .text(value as? String ?? "")
        case .noValue:
            return .noValue
        default:
            return .unavailable
        }
    }

    private func selectedTextRangeState(of element: AXUIElement) -> SelectionCapturePolicy.SelectedTextRange {
        guard let range = selectedTextRange(of: element) else { return .unavailable }
        return range.length > 0 && range.location != kCFNotFound
            ? .nonzeroLength
            : .zeroLength
    }

    private func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        SyntheticInputEventTag.markSelectionCapture(down)
        SyntheticInputEventTag.markSelectionCapture(up)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
