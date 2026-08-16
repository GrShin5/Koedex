import AppKit
import Carbon.HIToolbox

/// 一般の互換入力とは別に、Unicodeイベントを受け取れないことを実機で確認した二つの
/// 本文欄だけで使う、明示同意済みのCmd-V経路。
enum ScopedClipboardFallbackTarget: Equatable {
    case mailComposeBody
    case chromeGoogleDocsBody
}

enum ScopedClipboardTextTransportResult: Equatable {
    case submitted
    case unavailable
    case secureInputBlocked
    case targetChanged
    case installationFailed(mayHaveLostClipboard: Bool)
    case eventCreationFailed
}

@MainActor
final class ScopedClipboardTextTransport {
    private static let restorationDelayNanoseconds: UInt64 = 1_000_000_000

    private var activeTransaction: PasteboardPasteTransaction?
    private var restorationTask: Task<Void, Never>?

    /// 通常の音声処理Taskとは独立しているが、アプリ終了だけは明示的に所有中の
    /// 一時clipboardを復元する。後発コピーがあれば所有権判定で何もしない。
    func restorePendingClipboardIfOwned() {
        restorationTask?.cancel()
        restorationTask = nil
        _ = activeTransaction?.restoreIfOwned()
        activeTransaction = nil
    }

    /// 直前の限定貼り付けだけを直列化する。通常のUnicode入力はこの待機に巻き込まない。
    func submit(
        _ text: String,
        to target: NormalPasteTarget
    ) -> ScopedClipboardTextTransportResult {
        guard !IsSecureEventInputEnabled() else { return .secureInputBlocked }
        guard target.matchesCurrentFrontmostApplication() else { return .targetChanged }

        restorePendingClipboardIfOwned()

        let installation = PasteboardPasteTransaction.install(text: text)
        let transaction: PasteboardPasteTransaction
        switch installation {
        case .installed(let installed):
            transaction = installed
        case .snapshotIncomplete:
            return .installationFailed(mayHaveLostClipboard: false)
        case .writeFailed(let mayHaveLostClipboard):
            return .installationFailed(mayHaveLostClipboard: mayHaveLostClipboard)
        }
        guard !IsSecureEventInputEnabled() else {
            _ = transaction.restoreIfOwned()
            return .secureInputBlocked
        }
        guard target.matchesCurrentFrontmostApplication() else {
            _ = transaction.restoreIfOwned()
            return .targetChanged
        }
        guard postCommandV() else {
            _ = transaction.restoreIfOwned()
            return .eventCreationFailed
        }

        activeTransaction = transaction
        restorationTask = Task { [weak self, weak transaction] in
            try? await Task.sleep(nanoseconds: Self.restorationDelayNanoseconds)
            guard !Task.isCancelled, let self, let transaction else { return }
            _ = transaction.restoreIfOwned()
            if self.activeTransaction === transaction {
                self.activeTransaction = nil
                self.restorationTask = nil
            }
        }
        return .submitted
    }

    private func postCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        SyntheticInputEventTag.markScopedClipboardPaste(keyDown)
        SyntheticInputEventTag.markScopedClipboardPaste(keyUp)
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }
}
