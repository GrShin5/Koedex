import Foundation

/// AI出力で許可された操作。クリップボードsourceの有無は自動置換だけが保持し、
/// 明示挿入は型の上でもclipboard variantを要求できない。
enum AICommandInsertionOperation: Equatable {
    case automaticSourceReplacement(
        inputSource: AICommandInputSource,
        hasActualSource: Bool
    )
    case explicitTargetInsertion

    var isAutomaticSourceReplacement: Bool {
        if case .automaticSourceReplacement = self { return true }
        return false
    }
}

/// C-4: 「AIに指示」出力の挿入経路判定。
///
/// **これは「最初にどの経路を選ぶか」だけを決める。** 自動source置換は既存の
/// fallbackを維持する一方、明示挿入はtarget変更・非編集・未確認からUnicodeへ
/// 縮退しない。実行結果を踏まえた後者の判定は`TextInjector`側に残す。
enum AICommandInsertionTransportPolicy {
    enum BlockReason: Equatable {
        case targetChanged
        case secureInput
        case sourceUnavailable
        case nonEditable
        case clipboardVariantNotEnabled
        case externalCompatibilityDisabled
    }

    enum Transport: Equatable {
        case accessibility
        case scopedClipboardPaste
        case clipboardVariantPaste
        case unicode
        case blocked(BlockReason)
    }

    static func transport(
        operation: AICommandInsertionOperation,
        clipboardVariantEnabled: Bool,
        hasStoppedTarget: Bool,
        targetMatchesFrontmost: Bool,
        secureInputEnabled: Bool,
        destinationIsSecureTextField: Bool,
        allowExternalCompatibility: Bool,
        allowScopedClipboardFallback: Bool,
        hasScopedFallbackTarget: Bool,
        scopedFallbackTargetMatchesFreshCapture: Bool,
        destinationState: InsertionDestinationState?,
        destinationMatchesTargetPID: Bool,
        destinationRequiresUserInputEvent: Bool
    ) -> Transport {
        guard hasStoppedTarget else { return .blocked(.targetChanged) }
        guard !secureInputEnabled else { return .blocked(.secureInput) }
        guard targetMatchesFrontmost else { return .blocked(.targetChanged) }
        guard !destinationIsSecureTextField else { return .blocked(.secureInput) }

        switch operation {
        case .automaticSourceReplacement(let inputSource, let hasActualSource):
            guard hasActualSource else { return .blocked(.sourceUnavailable) }
            // クリップボードバリアントは「実際のsourceを自動置換する」操作に限定する。
            // 選択なし復帰が`.clipboard`を保持していても、`hasActualSource == false`なら
            // Cmd-Vを送らない。
            if inputSource == .clipboard {
                return clipboardVariantEnabled
                    ? .clipboardVariantPaste
                    : .blocked(.clipboardVariantNotEnabled)
            }

            // 自動source置換は既存挙動を維持する。限定fallbackの同意は外部互換入力と
            // 独立して保存されるが、実行には両方が必要。
            if allowScopedClipboardFallback, hasScopedFallbackTarget {
                return allowExternalCompatibility
                    ? .scopedClipboardPaste
                    : .blocked(.externalCompatibilityDisabled)
            }
            if let destinationState,
               destinationState != .nonEditable,
               destinationMatchesTargetPID,
               !destinationRequiresUserInputEvent {
                return .accessibility
            }
            return allowExternalCompatibility
                ? .unicode
                : .blocked(.externalCompatibilityDisabled)

        case .explicitTargetInsertion:
            // 明示挿入はAX直接書込みを含め、録音開始時・送出時の両同意を親が
            // まとめたフラグが必須。互換経路だけの権限として扱わない。
            guard allowExternalCompatibility else {
                return .blocked(.externalCompatibilityDisabled)
            }
            // 限定Cmd-Vは、停止時の分類だけでは許可しない。送出直前に再捕捉した
            // targetが同じ分類だった場合だけ実行し、失敗時はUnicodeへ落とさない。
            if allowScopedClipboardFallback, hasScopedFallbackTarget {
                return scopedFallbackTargetMatchesFreshCapture
                    ? .scopedClipboardPaste
                    : .blocked(.targetChanged)
            }

            if destinationState == .nonEditable {
                return .blocked(.nonEditable)
            }
            if destinationState == .editable {
                guard destinationMatchesTargetPID else { return .blocked(.targetChanged) }
                if !destinationRequiresUserInputEvent {
                    return .accessibility
                }
            } else if let destinationState,
                      destinationState != .unknown {
                return .blocked(.targetChanged)
            }

            // destinationが無い真のAX-less欄、AX状態がunknown、またはユーザー入力
            // イベント必須の欄だけをUnicode候補にする。destinationが存在する場合は
            // 実送出直前にTextInjectorが同一focus・本文・caretを再検証する。
            return allowExternalCompatibility
                ? .unicode
                : .blocked(.externalCompatibilityDisabled)
        }
    }
}

/// C-5: クリップボードバリアントの貼り付け同意は、他のどの同意フラグからも導出しない。
/// この関数が`clipboardVariantEnabled`以外を**引数に取らない**こと自体が、
/// 同意が独立していることの実装上の証明になる。
enum AICommandClipboardConsentPolicy {
    static func allowsClipboardVariantPaste(clipboardVariantEnabled: Bool) -> Bool {
        clipboardVariantEnabled
    }
}
