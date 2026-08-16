import CoreGraphics
import Carbon.HIToolbox

/// クリップボードに触れずに、前面アプリへ一度だけUnicode文字列を送る互換経路。
///
/// 文字ごとの疑似キー入力は遅く、途中欠落時に復旧もできないため使わない。本文全体を
/// 1組のkey down / key upイベントに載せる方式だけを許可する。
enum SyntheticUnicodeTextTransportResult: Equatable {
    case submitted
    case payloadTooLong
    case secureInputBlocked
    case targetChanged
    case eventCreationFailed
}

@MainActor
enum SyntheticUnicodeTextTransport {
    /// Phase 0で確認した一括Unicodeイベントの安全上限。上限を超える本文は途中まで
    /// 入力せず、従来の結果ウィンドウへ退避する。
    static let maximumUTF16Length = 390

    static func canSubmitUTF16Count(_ count: Int) -> Bool {
        count > 0 && count <= maximumUTF16Length
    }

    static func submit(
        _ text: String,
        to target: NormalPasteTarget
    ) -> SyntheticUnicodeTextTransportResult {
        let units = Array(text.utf16)
        guard canSubmitUTF16Count(units.count) else {
            return .payloadTooLong
        }
        guard !IsSecureEventInputEnabled() else { return .secureInputBlocked }
        guard target.matchesCurrentFrontmostApplication() else { return .targetChanged }
        guard let source = CGEventSource(stateID: .hidSystemState),
              // Unicode本文が優先されるため、この仮想キー自体は意味を持たない。
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_9),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_9),
                  keyDown: false
              ) else {
            return .eventCreationFailed
        }

        units.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        SyntheticInputEventTag.markUnicodeText(keyDown)
        SyntheticInputEventTag.markUnicodeText(keyUp)

        // イベント生成後にも、前面アプリとSecure Inputを最後に確認する。
        guard !IsSecureEventInputEnabled() else { return .secureInputBlocked }
        guard target.matchesCurrentFrontmostApplication() else { return .targetChanged }
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return .submitted
    }
}
