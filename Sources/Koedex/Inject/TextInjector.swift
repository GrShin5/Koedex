import Foundation
import AppKit
import Carbon.HIToolbox

enum TextInjectorResult {
    case inserted
    /// クリップボード非依存のUnicodeイベントをOSへ送出した。受領のAX確認はできない。
    case unicodeSubmitted
    /// Mail本文／Chrome版Google Docs本文だけの、明示同意済み限定Cmd-Vを送出した。
    case scopedClipboardFallbackSubmitted
    /// The user has not accepted the one-time Web/Electron compatibility path.
    case externalCompatibilityDisabled
    /// クリップボードを変更しない明示的な結果表示・コピー操作が必要。
    case manualFallbackRequired
    /// 限定貼り付けの書込み失敗後、開始前clipboardの完全性を保証できない。
    case clipboardMayHaveBeenLost
    /// クリップボードバリアント: ⌘V送出後、AXで反映を確認できた。
    case clipboardVariantPasteConfirmed
    /// クリップボードバリアント: ⌘Vを送出したが反映は確認できない。
    case clipboardVariantPasteSubmittedUnverified
    /// クリップボードバリアント: 書込み失敗で開始前clipboardの完全性を保証できない。
    case clipboardVariantPasteMayHaveLostClipboard
    case insertionUnconfirmed
    case secureInputBlocked
    case failed(Error)
}

/// 別ウィンドウへ退避した理由のうち、利用者へ伝える価値があるものだけを表す。
/// 挿入の成否判定には使わない。文言の選択だけに使う。
enum NormalTextInsertionFallbackReason: Equatable {
    /// 一括Unicodeイベントの上限を超えていて、一度に送れなかった。
    case payloadTooLong
}

/// 通常モードの挿入結果に、擬似送信の可否だけを表す証跡を添える。
/// 既存の`TextInjectorResult`の意味や履歴判定は変更しない。
struct NormalTextInsertionOutcome {
    let result: TextInjectorResult
    let sendEligibility: SendAfterInsertEligibility
    /// 退避した理由。既定の`nil`は「理由を区別しない従来どおりの退避」を意味する。
    let fallbackReason: NormalTextInsertionFallbackReason?

    init(
        result: TextInjectorResult,
        sendEligibility: SendAfterInsertEligibility,
        fallbackReason: NormalTextInsertionFallbackReason? = nil
    ) {
        self.result = result
        self.sendEligibility = sendEligibility
        self.fallbackReason = fallbackReason
    }
}

enum SafeTextInjectionResult {
    case inserted
    case unicodeSubmitted
    case scopedClipboardFallbackSubmitted
    case clipboardVariantPasteConfirmed
    case clipboardVariantPasteSubmittedUnverified
    case clipboardVariantPasteMayHaveLostClipboard
    case externalCompatibilityDisabled
    case manualFallbackRequired
    /// 本文が一括Unicodeイベントの上限を超えていて直接入力できなかった。
    /// `.manualFallbackRequired`と分けるのは、利用者へ理由を伝えるため。
    case payloadTooLongForDirectInsertion
    case insertionUnconfirmed
    case nonEditable
    case selectionNotCollapsed
    case targetChanged
    case secureInputBlocked
    case failed(Error)
}

enum TextInjectorError: Error, LocalizedError, Equatable {
    case targetChangedBeforePaste

    var errorDescription: String? {
        switch self {
        case .targetChangedBeforePaste: return "挿入先が変更されました"
        }
    }
}

/// 本文確認済みのReturnと、Unicode／trigger-only後の同一欄確認を混同しない。
enum SendKeyVerificationMode {
    case confirmedInsertedText(String)
    case exactCapturedEditableField
}

/// 通常モードの出力を履歴本文として保存できるかを決める、UI非依存の純粋な判定。
enum NormalInputHistoryPolicy {
    static func shouldRecord(_ result: TextInjectorResult) -> Bool {
        switch result {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted:
            return true
        case .externalCompatibilityDisabled, .manualFallbackRequired,
             .clipboardMayHaveBeenLost, .insertionUnconfirmed, .secureInputBlocked, .failed,
             .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified,
             .clipboardVariantPasteMayHaveLostClipboard:
            return false
        }
    }

    static func shouldStoreText(
        historyEnabled: Bool,
        cleanupEnabled: Bool,
        cleanupDidFail: Bool,
        output: String,
        result: TextInjectorResult
    ) -> Bool {
        guard historyEnabled,
              shouldRecord(result),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !cleanupEnabled || !cleanupDidFail
    }

    static func storedTextKind(cleanupEnabled: Bool) -> String {
        cleanupEnabled
            ? InputHistoryStoredTextKind.aiAssistedOutput
            : InputHistoryStoredTextKind.rawTranscriptOutput
    }
}

/// 一般clipboardを使うCmd-Vは外部アプリの受領を検証できないため、既定では自動実行しない。
/// ここを切り替える時は、clipboard保持・復元・連続入力・HFS Returnをまとめて実機検証する。
enum UnverifiedExternalPastePolicy {
    static let allowsAutomaticPaste = false
}

/// 挿入直前に、画面に現れない制御・書式文字だけを除去する。ブラックリスト方式で、
/// 可視文字（箇条書き記号・番号付けリストの記号・全角約物などを含む）は種類を問わず
/// 一切変更しない。
enum InvisibleCharacterSanitizer {
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isInvisible(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// 除去するのは「表示に一切寄与しない」文字だけ。字形や結合に影響する書式文字
    /// （ZWJ/ZWNJ、異体字セレクタ、IVS、結合文字、肌色修飾子）は可視文字の一部なので残す。
    private static func isInvisible(_ value: UInt32) -> Bool {
        switch value {
        // C0制御文字（tab=0x09, LF=0x0A, CR=0x0Dは除く）
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:
            return true
        // DEL＋C1制御文字。Unicodeのcategory Ccは0x00...0x1Fと0x7F...0x9F。
        case 0x7F...0x9F:
            return true
        // ARABIC LETTER MARK / MONGOLIAN VOWEL SEPARATOR
        case 0x061C, 0x180E:
            return true
        // ZERO WIDTH SPACE。0x200C(ZWNJ)と0x200D(ZWJ)は絵文字の連結や
        // ペルシア語・ヒンディー語等の字形制御に必要なため除去しない。
        case 0x200B:
            return true
        // 双方向書式・オーバーライド・分離文字
        case 0x202A...0x202E, 0x2066...0x2069:
            return true
        // WORD JOINER と不可視演算子
        case 0x2060...0x2064:
            return true
        // 行内注釈用の書式文字
        case 0xFFF9...0xFFFB:
            return true
        // BOM / ZERO WIDTH NO-BREAK SPACE
        case 0xFEFF:
            return true
        // タグ文字。完全に不可視で、隠しテキストの混入経路になる。
        // 0xE0100...0xE01EF(IVS)は漢字の異体字指定に必須なので含めない。
        case 0xE0000...0xE007F:
            return true
        default:
            return false
        }
    }
}

/// ネイティブ入力欄はAccessibilityで直接置換する。
///
/// macOSには外部アプリがCmd-Vの内容を受領したことを観測するAPIがない。そのため
/// AXで反映を確認できないWeb/Electron向けに一般clipboardを一時的に書き換えると、
/// 「以前のclipboardを早く戻すと旧内容を貼る」「戻さないとKoedex出力を残す」
/// という両立不能な競合になる。未確認経路は自動貼り付けせず、結果表示へ安全に退避する。
@MainActor
final class TextInjector {
    private let scopedClipboardTextTransport = ScopedClipboardTextTransport()

    func restorePendingScopedClipboardIfOwned() {
        scopedClipboardTextTransport.restorePendingClipboardIfOwned()
    }

    /// 挿入境界で必ず通す不可視文字の除去。元が非空なのに全て消えた場合はnilを返し、
    /// 呼び出し側は何も挿入せず手動フォールバックへ倒す。空文字を挿入扱いにして
    /// 送信キーだけが飛ぶ事態を防ぐため、判定はここへ一元化する。
    private static func sanitizedForInsertion(_ text: String) -> String? {
        let sanitized = InvisibleCharacterSanitizer.sanitize(text)
        if !text.isEmpty, sanitized.isEmpty { return nil }
        return sanitized
    }

    func insert(_ text: String) async -> TextInjectorResult {
        let outcome = await insert(
            text,
            forNormalTarget: NormalPasteTarget.capture(),
            verificationDestination: InsertionDestination.capture(),
            allowExternalCompatibility: false,
            allowScopedClipboardFallback: false
        )
        return outcome.result
    }

    func insert(
        _ text: String,
        forNormalTarget target: NormalPasteTarget?,
        verificationDestination destination: InsertionDestination?,
        allowExternalCompatibility: Bool = false,
        allowScopedClipboardFallback: Bool = false,
        allowUnverifiedMultilineText: Bool = true
    ) async -> NormalTextInsertionOutcome {
        guard !IsSecureEventInputEnabled() else {
            return NormalTextInsertionOutcome(
                result: .secureInputBlocked,
                sendEligibility: .notEligible
            )
        }
        guard let target, target.matchesCurrentFrontmostApplication() else {
            return NormalTextInsertionOutcome(
                result: .failed(TextInjectorError.targetChangedBeforePaste),
                sendEligibility: .notEligible
            )
        }

        // パスワード欄は、グローバルなSecure Event Inputがまだ立っていない場合も
        // AX分類で除外する。通常／HFSとも本文イベントを出さない。
        if destination?.isSecureTextField == true {
            return NormalTextInsertionOutcome(
                result: .secureInputBlocked,
                sendEligibility: .notEligible
            )
        }

        // 画面に現れない文字だけを除去する。ここで全ての本文が消えた場合は、
        // 何も挿入せず送信キーも送らない（trigger-onlyの経路はここを通らない）。
        guard let text = Self.sanitizedForInsertion(text) else {
            return NormalTextInsertionOutcome(
                result: .manualFallbackRequired,
                sendEligibility: .notEligible
            )
        }

        // Mail本文／Chrome版Google Docs本文は、実機でUnicodeを受け取れないことを
        // 確認した限定対象だけ。追加同意がある時はAX再確認を待たず専用Cmd-Vを使う。
        if allowScopedClipboardFallback,
           destination?.scopedClipboardFallbackTarget != nil {
            return await submitExternalText(
                text,
                normalTarget: target,
                destination: destination,
                allowExternalCompatibility: allowExternalCompatibility,
                allowScopedClipboardFallback: true,
                allowUnverifiedMultilineText: allowUnverifiedMultilineText
            )
        }

        guard let destination,
              destination.processIdentifier == target.processIdentifier,
              !destination.requiresUserInputEvent,
              destination.initialState != .nonEditable else {
            return await submitExternalText(
                text,
                normalTarget: target,
                destination: destination,
                allowExternalCompatibility: allowExternalCompatibility,
                allowScopedClipboardFallback: allowScopedClipboardFallback,
                allowUnverifiedMultilineText: allowUnverifiedMultilineText
            )
        }

        switch destination.replaceSelection(with: text) {
        case .inserted:
            return NormalTextInsertionOutcome(
                result: .inserted,
                sendEligibility: .directAXVerified
            )
        case .unconfirmed:
            // WebKitはAX書込みがプロセス境界を越えるため、書込み直後の値読み出しが
            // まだ更新されていないことがある。Safariのページ内検索欄はこれで毎回
            // `.unconfirmed` になり、挿入されないままフォールバック表示になっていた
            // （2026-07-30の実機ログ、`result=insertion_unconfirmed` × 5回）。
            // ネイティブAppKitのURLバーは同期的に更新されるので通っていた。
            //
            // 少し待って読み直し、確定した状態にだけ手を打つ。二重挿入の懸念は
            // 「部分的に反映された」場合にだけ存在するので、`.matched`（成功確定）と
            // `.unchanged`（未反映確定）は安全に扱える。曖昧な場合は従来どおり。
            // 待機は3回に分ける。遅れて着弾するケースを`.matched`で拾いきってから
            // 「未反映」と結論したいので、**最後の反復まで`.unchanged`を受け付けない**。
            // 途中の`.unchanged`は「まだ着弾していない」の意でもあり得るため、そこで
            // ⌘Vを送ると後から着弾した本文と二重になる。
            let reconfirmDelays: [UInt64] = [80_000_000, 200_000_000, 400_000_000]
            for (attempt, delayNanoseconds) in reconfirmDelays.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    // キャンセルされると待機が0msで抜ける。その直後の読みは必ず古いので
                    // 「未反映」と誤断定して⌘Vを送ってしまう。ESCを押したのに入力される
                    // ことになるため、ここで打ち切る。
                    AppLog.shared.info("AX書込みの再確認を中断しました（キャンセル）")
                    return NormalTextInsertionOutcome(
                        result: .insertionUnconfirmed,
                        sendEligibility: .notEligible
                    )
                }
                switch destination.reconfirmInsertion(of: text) {
                case .matched:
                    AppLog.shared.info("AX書込みは遅延して反映されました（再確認\(attempt + 1)回目で一致）")
                    return NormalTextInsertionOutcome(
                        result: .inserted,
                        sendEligibility: .directAXVerified
                    )
                case .unchanged where attempt == reconfirmDelays.count - 1:
                    // 互換入力の同意が無いなら縮退しない。`pasteStaticText`は
                    // `.externalCompatibilityDisabled`を返すため、AXが完備した欄に対して
                    // 「ブラウザやElectronアプリでは…」という的外れな案内が出てしまう。
                    // 従来どおり本文をコピーできるフォールバック表示に倒す。
                    guard allowExternalCompatibility else {
                        AppLog.shared.warn("AX書込みが反映されませんが、互換入力の同意が無いため手動フォールバックにします")
                        return NormalTextInsertionOutcome(
                            result: .insertionUnconfirmed,
                            sendEligibility: .notEligible
                        )
                    }
                    guard !Task.isCancelled else {
                        AppLog.shared.info("AX書込みの再確認後にキャンセルされました")
                        return NormalTextInsertionOutcome(
                            result: .insertionUnconfirmed,
                            sendEligibility: .notEligible
                        )
                    }
                    AppLog.shared.info("AX書込みが反映されていないためUnicode互換入力へ切り替えます")
                    return await submitExternalText(
                        text,
                        normalTarget: target,
                        destination: destination,
                        allowExternalCompatibility: allowExternalCompatibility,
                        allowScopedClipboardFallback: allowScopedClipboardFallback,
                        allowUnverifiedMultilineText: allowUnverifiedMultilineText
                    )
                case .unchanged, .ambiguous:
                    continue
                }
            }
            AppLog.shared.warn("AX書込みの反映を確認できませんでした（二重挿入を避けて中止）")
            return NormalTextInsertionOutcome(
                result: .insertionUnconfirmed,
                sendEligibility: .notEligible
            )
        case .secureInput:
            return NormalTextInsertionOutcome(
                result: .secureInputBlocked,
                sendEligibility: .notEligible
            )
        case .targetChanged, .notSupported, .nonEditable, .selectionNotCollapsed:
            // 停止時の前面アプリが一致していれば、通常モードは現在の同一アプリ内の
            // キャレットへbest-effortで入れる。HFSのReturn可否は別の厳格条件で決める。
            return await submitExternalText(
                text,
                normalTarget: target,
                destination: destination,
                allowExternalCompatibility: allowExternalCompatibility,
                allowScopedClipboardFallback: allowScopedClipboardFallback,
                allowUnverifiedMultilineText: allowUnverifiedMultilineText
            )
        }
    }

    /// AIに指示のAX経路。選択開始時に束縛したdestination以外へは貼り付けない。
    func insert(_ text: String, at destination: InsertionDestination) async -> SafeTextInjectionResult {
        guard let text = Self.sanitizedForInsertion(text) else { return .manualFallbackRequired }
        switch destination.replaceSelection(with: text) {
        case .inserted:
            return .inserted
        case .unconfirmed:
            return .insertionUnconfirmed
        case .targetChanged:
            return .targetChanged
        case .nonEditable:
            return .nonEditable
        case .selectionNotCollapsed:
            return .selectionNotCollapsed
        case .secureInput:
            return .secureInputBlocked
        case .notSupported:
            return .manualFallbackRequired
        }
    }

    /// AXなしのAI編集は停止時のアプリtargetだけを使う。完了時の現在フォーカスを
    /// 追い掛けることはしない。
    func insertExternalAIEdit(
        _ text: String,
        for target: NormalPasteTarget,
        allowExternalCompatibility: Bool
    ) async -> SafeTextInjectionResult {
        guard let text = Self.sanitizedForInsertion(text) else { return .manualFallbackRequired }
        let outcome = await submitExternalText(
            text,
            normalTarget: target,
            destination: nil,
            allowExternalCompatibility: allowExternalCompatibility,
            allowScopedClipboardFallback: false,
            allowUnverifiedMultilineText: true
        )
        return Self.mapSafeResult(outcome)
    }

    /// `「AIに指示」モード`の出力先は、開始時の選択sourceではなく録音停止時に
    /// 捕捉したtargetを使う。通常モードと同じSecure Input・前面アプリ・外部互換の
    /// 境界を通し、完了時の新しいキャレットには追従しない。
    ///
    /// 経路の最初の選択は`AICommandInsertionTransportPolicy.transport(...)`（C-4）に
    /// 委ねる。実行時のフォールスルー（AX置換が`.targetChanged`/`.nonEditable`/
    /// `.notSupported`を返した場合や再確認が一致しなかった場合に外部入力へ落ちる挙動）は
    /// その表の対象外で、ここに残す。
    func insertAICommandOutput(
        _ text: String,
        forNormalTarget target: NormalPasteTarget?,
        verificationDestination destination: InsertionDestination?,
        allowExternalCompatibility: Bool,
        allowScopedClipboardFallback: Bool,
        operation: AICommandInsertionOperation,
        clipboardVariantEnabled: Bool
    ) async -> SafeTextInjectionResult {
        guard let text = Self.sanitizedForInsertion(text) else { return .manualFallbackRequired }
        let hasStoppedTarget = target != nil
        let targetMatchesFrontmost = target?.matchesCurrentFrontmostApplication() ?? false
        let destinationMatchesTargetPID = hasStoppedTarget && destination?.processIdentifier == target?.processIdentifier
        let scopedFallbackTargetMatchesFreshCapture: Bool
        if operation == .explicitTargetInsertion,
           allowScopedClipboardFallback,
           let target,
           let destination,
           destination.scopedClipboardFallbackTarget != nil {
            scopedFallbackTargetMatchesFreshCapture = Self.scopedFallbackTargetMatchesFreshCapture(
                target: target,
                destination: destination
            )
        } else {
            scopedFallbackTargetMatchesFreshCapture = false
        }

        let transport = AICommandInsertionTransportPolicy.transport(
            operation: operation,
            clipboardVariantEnabled: clipboardVariantEnabled,
            hasStoppedTarget: hasStoppedTarget,
            targetMatchesFrontmost: targetMatchesFrontmost,
            secureInputEnabled: IsSecureEventInputEnabled(),
            destinationIsSecureTextField: destination?.isSecureTextField == true,
            allowExternalCompatibility: allowExternalCompatibility,
            allowScopedClipboardFallback: allowScopedClipboardFallback,
            hasScopedFallbackTarget: destination?.scopedClipboardFallbackTarget != nil,
            scopedFallbackTargetMatchesFreshCapture: scopedFallbackTargetMatchesFreshCapture,
            destinationState: destination?.initialState,
            destinationMatchesTargetPID: destinationMatchesTargetPID,
            destinationRequiresUserInputEvent: destination?.requiresUserInputEvent ?? false
        )

        switch transport {
        case .blocked(.targetChanged):
            return .targetChanged
        case .blocked(.secureInput):
            return .secureInputBlocked
        case .blocked(.sourceUnavailable):
            return .manualFallbackRequired
        case .blocked(.nonEditable):
            return .nonEditable
        case .blocked(.externalCompatibilityDisabled):
            return .externalCompatibilityDisabled
        case .blocked(.clipboardVariantNotEnabled):
            return .manualFallbackRequired
        case .accessibility:
            // `hasStoppedTarget`と`destinationMatchesTargetPID`がtrueである以上、
            // targetとdestinationはここで必ず揃っている（表の評価順序が保証する）。
            guard let target, let destination else { return .manualFallbackRequired }
            let directResult: DirectTextInsertionResult
            switch operation {
            case .automaticSourceReplacement:
                directResult = destination.replaceSelection(with: text)
            case .explicitTargetInsertion:
                directResult = destination.insertAtCapturedCaret(with: text)
            }
            switch directResult {
            case .inserted:
                return .inserted
            case .secureInput:
                return .secureInputBlocked
            case .unconfirmed:
                // WebKitのAX反映は遅れて届くことがある。ここで直ちにUnicodeへ切り替えると
                // 遅延したAX書込みと二重になるため、通常モードと同じ確認窓を使う。
                let reconfirmDelays: [UInt64] = [80_000_000, 200_000_000, 400_000_000]
                for (attempt, delayNanoseconds) in reconfirmDelays.enumerated() {
                    do {
                        try await Task.sleep(nanoseconds: delayNanoseconds)
                    } catch {
                        return .insertionUnconfirmed
                    }
                    switch destination.reconfirmInsertion(of: text) {
                    case .matched:
                        return .inserted
                    case .ambiguous:
                        return .insertionUnconfirmed
                    case .unchanged where attempt == reconfirmDelays.count - 1:
                        break
                    case .unchanged:
                        continue
                    }
                }
                if operation == .explicitTargetInsertion {
                    return .insertionUnconfirmed
                }
            case .targetChanged:
                if operation == .explicitTargetInsertion { return .targetChanged }
            case .nonEditable:
                if operation == .explicitTargetInsertion { return .nonEditable }
            case .selectionNotCollapsed:
                return .selectionNotCollapsed
            case .notSupported:
                if operation == .explicitTargetInsertion,
                   let validationFailure = Self.explicitUnicodeValidationFailure(
                    for: destination
                   ) {
                    return validationFailure
                }
                break
            }
            // 自動source置換の従来経路、または厳格AXが明示的に未対応だった場合だけ
            // 互換入力へ進む。明示挿入のtarget変更・非編集・未確認は上で終了する。
            let outcome = await submitExternalText(
                text,
                normalTarget: target,
                destination: destination,
                allowExternalCompatibility: allowExternalCompatibility,
                allowScopedClipboardFallback: operation.isAutomaticSourceReplacement
                    ? allowScopedClipboardFallback
                    : false,
                allowUnverifiedMultilineText: true
            )
            return Self.mapSafeResult(outcome)
        case .scopedClipboardPaste, .unicode:
            guard let target else { return .targetChanged }
            if operation == .explicitTargetInsertion,
               transport == .unicode,
               let validationFailure = Self.explicitUnicodeValidationFailure(
                for: destination
               ) {
                return validationFailure
            }
            if operation == .explicitTargetInsertion,
               Self.currentDestinationIsSecureTextField(for: target) {
                return .secureInputBlocked
            }
            if operation == .explicitTargetInsertion,
               transport == .scopedClipboardPaste {
                guard let destination,
                      Self.scopedFallbackTargetMatchesFreshCapture(
                        target: target,
                        destination: destination
                      ) else {
                    return .targetChanged
                }
            }
            let outcome = await submitExternalText(
                text,
                normalTarget: target,
                destination: destination,
                allowExternalCompatibility: allowExternalCompatibility,
                allowScopedClipboardFallback: transport == .scopedClipboardPaste,
                allowUnverifiedMultilineText: true
            )
            return Self.mapSafeResult(outcome)
        case .clipboardVariantPaste:
            guard let target else { return .targetChanged }
            switch scopedClipboardTextTransport.submit(text, to: target) {
            case .submitted:
                return await confirmClipboardVariantPaste(text, target: target, destination: destination)
            case .secureInputBlocked:
                return .secureInputBlocked
            case .targetChanged:
                return .targetChanged
            case .installationFailed(let mayHaveLostClipboard):
                return mayHaveLostClipboard
                    ? .clipboardVariantPasteMayHaveLostClipboard
                    : .manualFallbackRequired
            case .unavailable, .eventCreationFailed:
                return .manualFallbackRequired
            }
        }
    }

    /// 限定Cmd-Vの停止時分類を、実行直前に同じ前面PID・同じ分類として再確認する。
    /// URLや本文は保持せず、再捕捉できなければ一致しないものとしてfail closedする。
    private static func scopedFallbackTargetMatchesFreshCapture(
        target: NormalPasteTarget,
        destination: InsertionDestination
    ) -> Bool {
        guard destination.processIdentifier == target.processIdentifier,
              let capturedTarget = destination.scopedClipboardFallbackTarget,
              let current = InsertionDestination.capture(),
              current.processIdentifier == target.processIdentifier,
              !current.isSecureTextField else {
            return false
        }
        return current.scopedClipboardFallbackTarget == capturedTarget
    }

    /// AXが現在欄を公開する場合は、Unicode互換入力の直前にもsecure field分類を
    /// 再確認する。取得不能は既存のAX-less互換入力契約どおりfalseとする。
    private static func currentDestinationIsSecureTextField(for target: NormalPasteTarget) -> Bool {
        guard let current = InsertionDestination.capture(),
              current.processIdentifier == target.processIdentifier else {
            return false
        }
        return current.isSecureTextField
    }

    /// 明示Unicodeは、停止時にAX destinationを得ていたなら同じ要素・本文・
    /// collapsed caretを読み取りだけで再確認できる時に限る。destinationが最初から
    /// 無い真のAX-less欄だけは、既存の二重同意済み互換入力の残余リスクとして許可する。
    private static func explicitUnicodeValidationFailure(
        for destination: InsertionDestination?
    ) -> SafeTextInjectionResult? {
        guard let destination else { return nil }
        switch destination.validateExplicitUnicodeTarget() {
        case .verified:
            return nil
        case .targetChanged:
            return .targetChanged
        case .nonEditable:
            return .nonEditable
        case .selectionNotCollapsed:
            return .selectionNotCollapsed
        case .secureInput:
            return .secureInputBlocked
        case .unconfirmed:
            return .insertionUnconfirmed
        }
    }

    /// クリップボードバリアントの⌘V送出後、既存の再確認と同じ80/200/400msの段階で
    /// AX反映を確認する。macOSには外部アプリの⌘V受領を観測するAPIが無いため、
    /// destinationを取れないGoogle Docsのような欄では常にUnverifiedになるのが正しい。
    /// Unverifiedを Confirmed へ丸めない。
    ///
    /// **Confirmedは「貼り付いた証拠」ではない。** `reconfirmInsertion`は
    /// 「選択範囲をtextで置換した想定値」と現在値を比べるため、AI出力が選択元と
    /// 同一文字列だと、貼り付いていなくても一致しうる（冪等な整形や、既に訳文に
    /// なっている文への「翻訳して」など）。Confirmedは観測できた範囲での追加情報として
    /// テレメトリに使うに留め、これを条件に挙動を分岐させないこと。
    private func confirmClipboardVariantPaste(
        _ text: String,
        target: NormalPasteTarget,
        destination: InsertionDestination?
    ) async -> SafeTextInjectionResult {
        guard let destination,
              destination.processIdentifier == target.processIdentifier,
              destination.initialState != .nonEditable else {
            return .clipboardVariantPasteSubmittedUnverified
        }
        let reconfirmDelays: [UInt64] = [80_000_000, 200_000_000, 400_000_000]
        for (attempt, delayNanoseconds) in reconfirmDelays.enumerated() {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return .clipboardVariantPasteSubmittedUnverified
            }
            switch destination.reconfirmInsertion(of: text) {
            case .matched:
                return .clipboardVariantPasteConfirmed
            case .ambiguous:
                return .clipboardVariantPasteSubmittedUnverified
            case .unchanged where attempt == reconfirmDelays.count - 1:
                return .clipboardVariantPasteSubmittedUnverified
            case .unchanged:
                continue
            }
        }
        return .clipboardVariantPasteSubmittedUnverified
    }

    /// AX未確認の外部入力。通常はclipboard非依存のUnicodeを使い、実機でUnicodeを
    /// 受け付けない二つの本文欄だけを、追加同意がある場合に限定Cmd-Vへ送る。
    private func submitExternalText(
        _ text: String,
        normalTarget: NormalPasteTarget,
        destination: InsertionDestination?,
        allowExternalCompatibility: Bool,
        allowScopedClipboardFallback: Bool,
        allowUnverifiedMultilineText: Bool
    ) async -> NormalTextInsertionOutcome {
        guard allowExternalCompatibility else {
            return NormalTextInsertionOutcome(
                result: .externalCompatibilityDisabled,
                sendEligibility: .notEligible
            )
        }
        guard !IsSecureEventInputEnabled() else {
            return NormalTextInsertionOutcome(
                result: .secureInputBlocked,
                sendEligibility: .notEligible
            )
        }
        guard normalTarget.matchesCurrentFrontmostApplication() else {
            return NormalTextInsertionOutcome(
                result: .failed(TextInjectorError.targetChangedBeforePaste),
                sendEligibility: .notEligible
            )
        }

        if destination?.isSecureTextField == true {
            return NormalTextInsertionOutcome(
                result: .secureInputBlocked,
                sendEligibility: .notEligible
            )
        }
        if !allowUnverifiedMultilineText,
           text.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return NormalTextInsertionOutcome(
                result: .manualFallbackRequired,
                sendEligibility: .notEligible
            )
        }
        if allowScopedClipboardFallback,
           destination?.scopedClipboardFallbackTarget != nil {
            switch scopedClipboardTextTransport.submit(text, to: normalTarget) {
            case .submitted:
                return NormalTextInsertionOutcome(
                    result: .scopedClipboardFallbackSubmitted,
                    sendEligibility: .notEligible
                )
            case .secureInputBlocked:
                return NormalTextInsertionOutcome(result: .secureInputBlocked, sendEligibility: .notEligible)
            case .targetChanged:
                return NormalTextInsertionOutcome(
                    result: .failed(TextInjectorError.targetChangedBeforePaste),
                    sendEligibility: .notEligible
                )
            case .installationFailed(let mayHaveLostClipboard):
                if mayHaveLostClipboard {
                    AppLog.shared.warn("限定貼り付けのclipboard書込みが失敗しました。以前の内容が失われた可能性があります")
                    return NormalTextInsertionOutcome(
                        result: .clipboardMayHaveBeenLost,
                        sendEligibility: .notEligible
                    )
                }
                return NormalTextInsertionOutcome(result: .manualFallbackRequired, sendEligibility: .notEligible)
            case .unavailable, .eventCreationFailed:
                // この設定はUnicodeを受け取れないと実機確認した対象だけの専用経路。
                // 失敗時にUnicode成功として扱うと、何も入らないまま履歴成功になる。
                return NormalTextInsertionOutcome(result: .manualFallbackRequired, sendEligibility: .notEligible)
            }
        }
        switch SyntheticUnicodeTextTransport.submit(text, to: normalTarget) {
        case .submitted:
            return NormalTextInsertionOutcome(
                result: .unicodeSubmitted,
                sendEligibility: destination == nil ? .notEligible : .unicodeSubmitted
            )
        case .secureInputBlocked:
            return NormalTextInsertionOutcome(result: .secureInputBlocked, sendEligibility: .notEligible)
        case .targetChanged:
            return NormalTextInsertionOutcome(
                result: .failed(TextInjectorError.targetChangedBeforePaste),
                sendEligibility: .notEligible
            )
        case .payloadTooLong:
            // 途中まで入力する分割送出はしない設計のため、ここで退避する。
            // ただし理由は保ち、呼び出し側が利用者へ伝えられるようにする。
            // 空本文も同じ`.payloadTooLong`で返るため、長さが原因の時だけ理由を付ける。
            // 空本文に「長すぎる」と説明すると、利用者を誤った対処へ誘導する。
            return NormalTextInsertionOutcome(
                result: .manualFallbackRequired,
                sendEligibility: .notEligible,
                fallbackReason: SyntheticUnicodeTextTransport
                    .exceedsMaximumUTF16Length(text.utf16.count) ? .payloadTooLong : nil
            )
        case .eventCreationFailed:
            return NormalTextInsertionOutcome(result: .manualFallbackRequired, sendEligibility: .notEligible)
        }
    }

    /// 退避理由を保ったまま写す。`.payloadTooLong`だけは専用の値へ写し、
    /// 「長すぎて入らなかった」ことが呼び出し側で分かるようにする。
    static func mapSafeResult(_ outcome: NormalTextInsertionOutcome) -> SafeTextInjectionResult {
        if case .manualFallbackRequired = outcome.result,
           outcome.fallbackReason == .payloadTooLong {
            return .payloadTooLongForDirectInsertion
        }
        return mapSafeResult(outcome.result)
    }

    // 回帰テストがTextInjectorのインスタンスなしで写像を直接検証できるよう、
    // 状態を持たないこの関数だけ`static`にしてある。
    static func mapSafeResult(_ result: TextInjectorResult) -> SafeTextInjectionResult {
        switch result {
        case .inserted: return .inserted
        case .unicodeSubmitted: return .unicodeSubmitted
        case .scopedClipboardFallbackSubmitted: return .scopedClipboardFallbackSubmitted
        case .clipboardVariantPasteConfirmed: return .clipboardVariantPasteConfirmed
        case .clipboardVariantPasteSubmittedUnverified: return .clipboardVariantPasteSubmittedUnverified
        // `.clipboardMayHaveBeenLost`（限定fallback）とは別扱い。クリップボード
        // バリアントは利用者へ出力を渡す必要があるため、結果ウィンドウへ退避させたい。
        case .clipboardVariantPasteMayHaveLostClipboard: return .clipboardVariantPasteMayHaveLostClipboard
        case .externalCompatibilityDisabled: return .externalCompatibilityDisabled
        case .manualFallbackRequired: return .manualFallbackRequired
        case .clipboardMayHaveBeenLost: return .manualFallbackRequired
        case .insertionUnconfirmed: return .insertionUnconfirmed
        case .secureInputBlocked: return .secureInputBlocked
        case .failed(let error):
            if (error as? TextInjectorError) == .targetChangedBeforePaste {
                return .targetChanged
            }
            return .failed(error)
        }
    }

    /// 送信直前にもう一度対象・Secure Input・AX本文を確認してから、固定3種のReturnを送出する。
    func postSendKey(
        _ stroke: SendKeyStroke,
        forNormalTarget target: NormalPasteTarget,
        verificationDestination destination: InsertionDestination,
        verification: SendKeyVerificationMode
    ) -> SendKeyDispatchResult {
        guard !IsSecureEventInputEnabled() else { return .secureInputBlocked }
        guard target.matchesCurrentFrontmostApplication() else { return .targetChanged }
        // 本文一致だけでは、直後に入力欄が非編集化したケースを除けない。
        // direct AX / Unicode / trigger-onlyを問わずReturnの直前に同一editableを確認する。
        guard destination.currentFocusMatchesCapturedEditableElement() else {
            return .focusedElementOrTextChanged
        }
        switch verification {
        case .confirmedInsertedText(let expectedText):
            guard destination.confirmsInsertion(of: expectedText) else {
                return .focusedElementOrTextChanged
            }
        case .exactCapturedEditableField:
            guard destination.currentFocusMatchesCapturedEditableElement() else {
                return .focusedElementOrTextChanged
            }
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: stroke.keyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: stroke.keyCode,
                  keyDown: false
              ) else {
            return .eventCreationFailed
        }

        keyDown.flags = stroke.eventFlags
        keyUp.flags = stroke.eventFlags
        SyntheticInputEventTag.markSendKey(keyDown)
        SyntheticInputEventTag.markSendKey(keyUp)
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return .sent
    }
}
