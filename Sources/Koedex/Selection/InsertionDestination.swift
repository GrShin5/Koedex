import AppKit
import Carbon.HIToolbox

enum InsertionDestinationState: Equatable {
    case editable
    case nonEditable
    case unknown
    case changed
    case secureInput
}

/// Secure Event Inputが間に合わない／有効にならない実装もあるため、AXが明示する
/// password fieldは互換入力の候補から外す。文字列本文は一切扱わない純粋な判定。
enum SecureTextFieldPolicy {
    enum LiveClassification: Equatable {
        case nonSecure
        case secure
        case unconfirmed
    }

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || role == "AXSecureTextArea"
            || subrole == "AXSecureTextField" || subrole == "AXSecureTextArea"
    }

    /// 明示挿入の直前は、捕捉時の分類を再利用しない。role/subroleのどちらかを
    /// 読めなければ安全側に倒し、同じAX要素が途中でpassword fieldへ変わる競合も
    /// 書込み前に遮断する。
    static func classifyLive(
        role: String?,
        roleWasReadable: Bool,
        subrole: String?,
        subroleWasReadable: Bool
    ) -> LiveClassification {
        guard roleWasReadable, subroleWasReadable else { return .unconfirmed }
        return isSecure(role: role, subrole: subrole) ? .secure : .nonSecure
    }
}

/// Accessibility APIで選択範囲を直接置換したときの確認結果。
/// 成功を返すのは、停止時に保存したテキスト値から期待できる値へ実際に変わった場合だけ。
enum DirectTextInsertionResult: Equatable {
    case inserted
    case notSupported
    case nonEditable
    case selectionNotCollapsed
    case targetChanged
    case secureInput
    case unconfirmed
}

/// AX直接書込みを使わずUnicode互換入力へ進む前に、停止時の入力先が今も同じかを
/// 確認した結果。明示配送では不確実な状態をUnicodeで補わない。
enum ExplicitUnicodeTargetValidation: Equatable {
    case verified
    case targetChanged
    case nonEditable
    case selectionNotCollapsed
    case secureInput
    case unconfirmed
}

/// `validateExplicitUnicodeTarget()`がAXから集めた事実を、安全側へ倒すための純粋な表。
/// 回帰テストはここでfocus／本文／キャレットの変化をOS非依存で固定する。
enum AICommandExplicitUnicodeTargetPolicy {
    static func decision(
        secureInputEnabled: Bool,
        destinationIsSecureTextField: Bool,
        processMatches: Bool,
        focusMatches: Bool?,
        editableState: InsertionDestinationState?,
        valueMatches: Bool?,
        capturedRange: CFRange?,
        currentRange: CFRange?
    ) -> ExplicitUnicodeTargetValidation {
        guard !secureInputEnabled, !destinationIsSecureTextField else {
            return .secureInput
        }
        guard processMatches else { return .targetChanged }
        guard let focusMatches else { return .unconfirmed }
        guard focusMatches else { return .targetChanged }
        guard let editableState else { return .unconfirmed }
        switch editableState {
        case .editable:
            break
        case .nonEditable:
            return .nonEditable
        case .secureInput:
            return .secureInput
        case .unknown, .changed:
            return .unconfirmed
        }
        guard let valueMatches else { return .unconfirmed }
        guard valueMatches else { return .targetChanged }
        switch AICommandCapturedCaretPolicy.decision(
            capturedRange: capturedRange,
            currentRange: currentRange
        ) {
        case .verified:
            return .verified
        case .unavailable:
            return .unconfirmed
        case .selectionNotCollapsed:
            return .selectionNotCollapsed
        case .targetChanged:
            return .targetChanged
        }
    }
}

/// 明示結果を「選択置換」へ誤って広げないための、AX非依存なキャレット照合。
/// 停止時・送出時の両方が同じ0文字範囲の時だけ直接挿入を許可する。
enum AICommandCapturedCaretPolicy {
    enum Decision: Equatable {
        case verified
        case unavailable
        case selectionNotCollapsed
        case targetChanged
    }

    static func decision(
        capturedRange: CFRange?,
        currentRange: CFRange?
    ) -> Decision {
        guard let capturedRange, let currentRange else { return .unavailable }
        guard capturedRange.location != kCFNotFound,
              currentRange.location != kCFNotFound else {
            return .targetChanged
        }
        guard capturedRange.length == 0, currentRange.length == 0 else {
            return .selectionNotCollapsed
        }
        return capturedRange.location == currentRange.location
            ? .verified
            : .targetChanged
    }
}

/// `.unconfirmed` を返した直後に、少し待ってからAX値をもう一度読んだ結果。
///
/// WebKitはAX書込みがプロセス境界を越えるため、書込み直後の`kAXValueAttribute`が
/// まだ更新されていないことがある。Safariのページ内検索欄はこれで`.unconfirmed`になり、
/// 挿入されないままフォールバックのポップアップが出ていた（2026-07-30の実機ログ、
/// `result=insertion_unconfirmed` × 5回）。
enum InsertionReconfirmation: Equatable {
    /// 期待値と一致した。書込みは成功していたので、そのまま挿入成功として扱える。
    case matched
    /// 停止時に保存した値のまま。書込みが反映されていないか、**まだ**反映されていない。
    /// この2つは1回の読みでは区別できないため、呼び出し側は待機を打ち切る最後の
    /// 反復でのみこれを「未反映」と扱うこと。早い段階で縮退させると、後から着弾した
    /// 書込みと⌘Vが二重になる。
    case unchanged
    /// どちらとも言えない。部分的に反映された可能性があるため保守的に扱う。
    case ambiguous
}

/// 停止時の入力先に対して安全に使える貼り付け経路。
/// WebのcontenteditableのようにAX全文値を検証できない欄は、同一アプリ・同一フォーカスを
/// 確認できる場合だけguardedPasteへ進める。確認不能な場合はクリップボードのみを残す。
enum InsertionPastePreparation: Equatable {
    case strictVerified
    case guardedPaste
    case clipboardOnly
    case secureInput
}

/// AXの能力差をUIテストなしでも固定するための純粋な貼り付け経路判定。
enum InsertionPasteRouting {
    static func decide(
        isSecureInput: Bool,
        targetMatches: Bool,
        isKnownNonEditable: Bool,
        hasStrictSnapshot: Bool,
        valueMatches: Bool,
        selectedRangeRestored: Bool,
        requiresUserInputEvent: Bool = false
    ) -> InsertionPastePreparation {
        if isSecureInput { return .secureInput }
        if !targetMatches || isKnownNonEditable { return .clipboardOnly }
        if !hasStrictSnapshot { return .guardedPaste }
        if !valueMatches { return .clipboardOnly }
        guard selectedRangeRestored else { return .guardedPaste }
        // AX直接書き込みでは確定できない欄は、能力が揃っていても⌘V経路へ落とす。
        return requiresUserInputEvent ? .guardedPaste : .strictVerified
    }
}

/// 録音停止時のAX入力先取得は、結果が無い場合に安全に退避できる補助情報である。
/// 反応待ちでMainActorを塞がないよう、最初の問い合わせからの総時間と各AX往復を
/// 短く固定する。
enum InsertionDestinationCapturePolicy {
    static let totalTimeoutSeconds: TimeInterval = 0.150
    static let perMessageTimeoutSeconds: TimeInterval = 0.030
}

/// Chromium系ブラウザのアドレスバーへAXでテキストを直接書き込むと、表示は変わるのに
/// ブラウザ内部の編集モデルが「ユーザーが入力した」と認識しない。その結果、直後の
/// Enterが確定操作にならない（2026-07-31の実機報告）。
///
/// **合成イベントの問題ではないと確定している。** ユーザー自身が物理キーで押したEnterでも
/// 確定しなかったため、原因は送信側ではなく挿入側にある。⌘Vは通常のキー入力経路を通り、
/// ブラウザが入力として登録するのでこの問題が起きない。
///
/// 対象を絞る理由:
/// - **Safari（com.apple.Safari）は対象外。** 同じAX書き込みで正しく確定する（実機確認済み）
/// - **ページ内の入力欄（AXWebArea配下）は対象外。** そちらは元々AX経路が正しく働き、
///   ここで巻き込むと擬似送信の権限判定まで変わってしまう
///
/// ここに無いChromium派生ブラウザは従来どおりAX経路を通る。網羅ではなく、
/// 実在が確かなものだけを列挙している。
enum BrowserChromeInsertionPolicy {
    static let chromiumBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "company.thebrowser.Browser"
    ]

    /// 祖先を遡る上限。探索は本来アプリ要素（親なし）で自然終端するので、
    /// これは暴走を防ぐ安全弁でしかない。
    ///
    /// **上限に達した場合・AXの読み出しに失敗した場合は「Web領域の中」と見なす。**
    /// 判定を誤ったときの被害が非対称なため。Web領域を誤ってブラウザUI扱いすると
    /// ページ内の入力欄まで⌘V経路へ落ち、互換同意が無いユーザーでは挿入自体が
    /// 失われる。逆にブラウザUIをWeb扱いしても、従来どおりEnterが効かないだけで
    /// 現状より悪くはならない。ChromeはSPAで`AXGroup`が深く積み重なるため、
    /// 浅い上限は現実に踏まれる。
    static let maximumAncestorWalkDepth = 64

    /// 祖先探索に使うAXメッセージのタイムアウト（秒）。
    /// 既定は6秒で、応答しないアプリでは往復ごとにMainActorが止まる。
    /// この探索は「あれば良い」情報なので短く切り、失敗側（＝Web領域と見なす）へ倒す。
    static let ancestorWalkMessagingTimeout: Float = 0.2

    static func requiresUserInputEvent(
        bundleIdentifier: String?,
        isInsideWebContent: Bool
    ) -> Bool {
        guard let bundleIdentifier,
              chromiumBrowserBundleIdentifiers.contains(bundleIdentifier) else {
            return false
        }
        return !isInsideWebContent
    }
}

/// Keeps the selected text sent to AI bound to the exact destination snapshot
/// that may later be replaced. It is intentionally pure for regression tests.
enum SelectionDestinationBindingPolicy {
    static func matches(selectedText: String, destinationSelectedText: String?) -> Bool {
        destinationSelectedText == selectedText
    }
}

/// A consent panel may temporarily activate Koedex. Resuming a selection
/// capture is allowed only after the app that opened the panel is frontmost
/// again; otherwise it must not silently become a general question.
enum ExternalCompatibilityFocusReturnPolicy {
    static func canResume(
        expectedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?
    ) -> Bool {
        guard let expectedProcessIdentifier else { return true }
        return expectedProcessIdentifier == currentProcessIdentifier
    }
}

/// 通常モードで録音停止時に保存する前面アプリの同一性。
/// Web入力欄はAXのvalueや選択範囲を公開しないことがあるため、通常入力の⌘V送出を
/// AX要素の可観測性へ依存させない。選択テキスト置換には使わない。
enum NormalPasteRouting {
    static func shouldDispatch(
        isSecureInput: Bool,
        capturedProcessIdentifier: pid_t?,
        currentProcessIdentifier: pid_t?,
        capturedBundleIdentifier: String?,
        currentBundleIdentifier: String?
    ) -> Bool {
        guard !isSecureInput,
              let capturedProcessIdentifier,
              capturedProcessIdentifier == currentProcessIdentifier else {
            return false
        }

        // PIDが同一ならbundle IDも通常は同一だが、取得できた場合だけ念のため照合する。
        if let capturedBundleIdentifier, let currentBundleIdentifier {
            return capturedBundleIdentifier == currentBundleIdentifier
        }
        return true
    }
}

@MainActor
struct NormalPasteTarget {
    let processIdentifier: pid_t
    let bundleIdentifier: String?

    static func capture() -> NormalPasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return NormalPasteTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    func matchesCurrentFrontmostApplication() -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return NormalPasteRouting.shouldDispatch(
            isSecureInput: IsSecureEventInputEnabled(),
            capturedProcessIdentifier: processIdentifier,
            currentProcessIdentifier: app?.processIdentifier,
            capturedBundleIdentifier: bundleIdentifier,
            currentBundleIdentifier: app?.bundleIdentifier
        )
    }
}

/// In-memory snapshot of the caret/focused element at recording stop.
/// It is intentionally not Codable and is never persisted.
@MainActor
final class InsertionDestination {
    let processIdentifier: pid_t
    private let focusedElement: AXUIElement
    private let valueSnapshot: String?
    private let selectedRange: CFRange?
    /// Captured with the same AX element/range snapshot used for an AI command.
    /// This binds the text given to the model to the destination eligible for
    /// direct replacement later.
    private let selectedTextSnapshot: String?
    /// AX直接書き込みでは確定できない欄か。捕捉時に一度だけ判定する。
    /// 祖先を遡るAX問い合わせは安くないため、`prepareForPaste()` のたびには行わない。
    ///
    /// **これ単独で経路を変えてはならない。** ⌘V経路は外部アプリ互換の同意を必要とし、
    /// 同意が無いまま縮退させると「Enterが効かない」が「そもそも挿入されない」に
    /// 悪化する。同意の有無を知っている `TextInjector` 側で併せて判断する。
    let requiresUserInputEvent: Bool
    let initialState: InsertionDestinationState
    /// Secure Event Inputを有効化しない実装があるWebパスワード欄も除外するため、
    /// AX role / subroleから得た本文を含まない分類値を保存する。
    let isSecureTextField: Bool
    /// Unicodeで受け付けないことを実機で確認した本文欄だけの、限定Cmd-V候補。
    /// URLや本文は保存・ログ出力しない。
    let scopedClipboardFallbackTarget: ScopedClipboardFallbackTarget?

    private init(
        processIdentifier: pid_t,
        focusedElement: AXUIElement,
        valueSnapshot: String?,
        selectedRange: CFRange?,
        selectedTextSnapshot: String?,
        requiresUserInputEvent: Bool,
        initialState: InsertionDestinationState,
        isSecureTextField: Bool,
        scopedClipboardFallbackTarget: ScopedClipboardFallbackTarget?
    ) {
        self.processIdentifier = processIdentifier
        self.focusedElement = focusedElement
        self.valueSnapshot = valueSnapshot
        self.selectedRange = selectedRange
        self.selectedTextSnapshot = selectedTextSnapshot
        self.requiresUserInputEvent = requiresUserInputEvent
        self.initialState = initialState
        self.isSecureTextField = isSecureTextField
        self.scopedClipboardFallbackTarget = scopedClipboardFallbackTarget
    }

    static func capture() -> InsertionDestination? {
        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard setShortMessagingTimeout(for: application, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              Date() <= deadline else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        return capture(
            processIdentifier: app.processIdentifier,
            focusedElement: element,
            deadline: deadline
        )
    }

    /// Captures destination state from a caller-owned AX focused-element
    /// snapshot. This intentionally does not ask AX for a new focused element.
    /// It is used to bind AI-command selected text and replacement target.
    static func capture(
        processIdentifier: pid_t,
        focusedElement: AXUIElement
    ) -> InsertionDestination? {
        capture(
            processIdentifier: processIdentifier,
            focusedElement: focusedElement,
            deadline: Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        )
    }

    private static func capture(
        processIdentifier: pid_t,
        focusedElement: AXUIElement,
        deadline: Date
    ) -> InsertionDestination? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              setShortMessagingTimeout(for: focusedElement, deadline: deadline) else {
            return nil
        }
        let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        // Web領域の判定はChromium系のときだけ行う。他のアプリでは祖先を遡る必要がない。
        let isChromium = BrowserChromeInsertionPolicy
            .chromiumBrowserBundleIdentifiers
            .contains(bundleIdentifier ?? "")
        guard setShortMessagingTimeout(for: focusedElement, deadline: deadline) else { return nil }
        let valueSnapshot = stringValue(of: focusedElement)
        guard Date() <= deadline else { return nil }
        guard setShortMessagingTimeout(for: focusedElement, deadline: deadline) else { return nil }
        let selectedRange = selectedTextRange(of: focusedElement)
        guard Date() <= deadline else { return nil }
        guard setShortMessagingTimeout(for: focusedElement, deadline: deadline) else { return nil }
        let selectedTextSnapshot = selectedText(of: focusedElement)
        guard Date() <= deadline else { return nil }
        guard setShortMessagingTimeout(for: focusedElement, deadline: deadline) else { return nil }
        let initialState = editableState(of: focusedElement)
        guard Date() <= deadline else { return nil }
        let chromiumWebContext = isChromium
            ? webContext(for: focusedElement, deadline: deadline)
            : ChromiumWebContext(isInsideWebContent: true, url: nil)
        let isInsideWeb = chromiumWebContext.isInsideWebContent
        guard Date() <= deadline else { return nil }
        let role = role(of: focusedElement)
        let subrole = subrole(of: focusedElement)
        let isSecureTextField = SecureTextFieldPolicy.isSecure(
            role: role,
            subrole: subrole
        )
        let scopedClipboardFallbackTarget = scopedClipboardFallbackTarget(
            bundleIdentifier: bundleIdentifier,
            role: role,
            isInsideWebContent: isInsideWeb,
            chromiumWebURL: chromiumWebContext.url
        )
        return InsertionDestination(
            processIdentifier: processIdentifier,
            focusedElement: focusedElement,
            valueSnapshot: valueSnapshot,
            selectedRange: selectedRange,
            selectedTextSnapshot: selectedTextSnapshot,
            requiresUserInputEvent: BrowserChromeInsertionPolicy.requiresUserInputEvent(
                bundleIdentifier: bundleIdentifier,
                isInsideWebContent: isInsideWeb
            ),
            initialState: initialState,
            isSecureTextField: isSecureTextField,
            scopedClipboardFallbackTarget: scopedClipboardFallbackTarget
        )
    }

    private struct ChromiumWebContext {
        let isInsideWebContent: Bool
        /// 分類だけに使い、destinationやログへは保存しない。
        let url: URL?
    }

    /// フォーカス要素からAX階層を一度だけ遡り、Web領域とそのURLを同時に得る。
    /// ページ内の入力欄はブラウザのツールバーと違いAX経路が正しく働くため、
    /// 両者を区別しないとページ内まで⌘V経路へ巻き込んでしまう。
    /// 判定できなかった場合は `true`（Web領域の中）を返す。理由は
    /// `BrowserChromeInsertionPolicy.maximumAncestorWalkDepth` のコメントを参照。
    private static func webContext(
        for element: AXUIElement,
        deadline: Date
    ) -> ChromiumWebContext {
        var current = element
        for _ in 0..<BrowserChromeInsertionPolicy.maximumAncestorWalkDepth {
            guard setShortMessagingTimeout(for: current, deadline: deadline) else {
                return ChromiumWebContext(isInsideWebContent: true, url: nil)
            }
            guard let role = role(of: current) else {
                return ChromiumWebContext(isInsideWebContent: true, url: nil)
            }
            if role == kAXWebAreaRole {
                return ChromiumWebContext(
                    isInsideWebContent: true,
                    url: url(of: current, deadline: deadline)
                )
            }
            guard setShortMessagingTimeout(for: current, deadline: deadline) else {
                return ChromiumWebContext(isInsideWebContent: true, url: nil)
            }
            guard let parent = parent(of: current) else {
                // 親が無いのはアプリ要素まで遡り切った証拠。Web領域は無かった。
                return ChromiumWebContext(
                    isInsideWebContent: role == kAXApplicationRole as String ? false : true,
                    url: nil
                )
            }
            current = parent
        }
        return ChromiumWebContext(isInsideWebContent: true, url: nil)
    }

    /// AXの問い合わせが長引いても、残りの呼出し予算を超えないタイムアウトを設定する。
    /// captureと出力直前の再確認の両方で、**各AX問い合わせの直前**に呼ぶ。残りが
    /// 無い場合は`false`を返し、呼び出し側は互換入力または結果表示へ退避する。
    private static func setShortMessagingTimeout(for element: AXUIElement, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(
            element,
            Float(min(InsertionDestinationCapturePolicy.perMessageTimeoutSeconds, remaining))
        )
        return true
    }

    /// AXの公開定数が無いロール名。Chromiumもここは同じ文字列を返す。
    private static let kAXWebAreaRole = "AXWebArea"

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func subrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// 互換入力と直接AX書込みの直前に使う、本文を読まないlive secure分類。
    /// subrole属性がそもそも無いことは通常のtext fieldで起こり得るため読取済みと
    /// 扱うが、問い合わせ自体の失敗や型不明は安全に確認できない。
    private static func liveSecureTextFieldClassification(
        of element: AXUIElement,
        deadline: Date
    ) -> SecureTextFieldPolicy.LiveClassification {
        guard setShortMessagingTimeout(for: element, deadline: deadline) else {
            return .unconfirmed
        }
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            return .unconfirmed
        }

        guard setShortMessagingTimeout(for: element, deadline: deadline) else {
            return .unconfirmed
        }
        var subroleValue: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        let subroleWasReadable: Bool
        let subrole: String?
        switch subroleResult {
        case .success:
            guard subroleValue == nil || subroleValue is String else {
                return .unconfirmed
            }
            subroleWasReadable = true
            subrole = subroleValue as? String
        case .attributeUnsupported:
            subroleWasReadable = true
            subrole = nil
        default:
            subroleWasReadable = false
            subrole = nil
        }
        return SecureTextFieldPolicy.classifyLive(
            role: role,
            roleWasReadable: true,
            subrole: subrole,
            subroleWasReadable: subroleWasReadable
        )
    }

    /// ここで分類できない入力欄に限定Cmd-Vを広げない。通常のUnicode経路へ戻す。
    private static func scopedClipboardFallbackTarget(
        bundleIdentifier: String?,
        role: String?,
        isInsideWebContent: Bool,
        chromiumWebURL: URL?
    ) -> ScopedClipboardFallbackTarget? {
        if bundleIdentifier == "com.apple.mail", role == "AXTextArea" || role == kAXWebAreaRole {
            return .mailComposeBody
        }
        guard bundleIdentifier == "com.google.Chrome",
              isInsideWebContent,
              !["AXTextField", "AXSearchField", "AXComboBox", "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton"].contains(role ?? ""),
              let url = chromiumWebURL,
              url.host?.lowercased() == "docs.google.com",
              url.path.hasPrefix("/document/") else {
            return nil
        }
        return .chromeGoogleDocsBody
    }

    /// URL文字列は分類後に破棄し、ログ・履歴・destinationには保持しない。
    private static func url(of element: AXUIElement, deadline: Date) -> URL? {
        guard setShortMessagingTimeout(for: element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
              let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Returns true only when the text read for the AI request is the text in
    /// this destination snapshot. A change in focus/selection during capture
    /// therefore falls back to result display rather than replacing another
    /// selection later.
    func bindsSelectedText(_ text: String) -> Bool {
        SelectionDestinationBindingPolicy.matches(
            selectedText: text,
            destinationSelectedText: selectedTextSnapshot
        )
    }

    /// 停止時と同じ前面アプリ・フォーカス先であることを確認し、使える貼り付け経路を返す。
    /// AX全文値と選択範囲が取れる欄だけ厳格確認へ進め、Web入力欄はguarded pasteへ落とす。
    func prepareForPaste() -> InsertionPastePreparation {
        prepareForPaste(
            deadline: Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        )
    }

    /// この呼出し中に使い回すdeadlineを受け取ることで、再確認・選択範囲復元までの
    /// 全AX往復が既定の数秒timeoutへ戻らないようにする。
    private func prepareForPaste(deadline: Date) -> InsertionPastePreparation {
        let isSecureInput = IsSecureEventInputEnabled()
        guard !isSecureInput else { return .secureInput }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return InsertionPasteRouting.decide(
                isSecureInput: false,
                targetMatches: false,
                isKnownNonEditable: false,
                hasStrictSnapshot: false,
                valueMatches: false,
                selectedRangeRestored: false
            )
        }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard Self.setShortMessagingTimeout(for: application, deadline: deadline) else {
            return Self.clipboardOnlyPreparation()
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value,
              Date() <= deadline else {
            return Self.clipboardOnlyPreparation()
        }
        let current = unsafeBitCast(value, to: AXUIElement.self)
        guard CFEqual(current, focusedElement) else {
            return Self.clipboardOnlyPreparation()
        }

        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return Self.clipboardOnlyPreparation()
        }
        let editableState = Self.editableState(of: current)
        let isKnownNonEditable = editableState == .nonEditable
        let hasStrictSnapshot = valueSnapshot != nil && selectedRange != nil
        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return Self.clipboardOnlyPreparation()
        }
        let valueMatches = valueSnapshot.map { Self.stringValue(of: current) == $0 } ?? false

        guard editableState == .editable, hasStrictSnapshot, valueMatches,
              let selectedRange else {
            return InsertionPasteRouting.decide(
                isSecureInput: false,
                targetMatches: true,
                isKnownNonEditable: isKnownNonEditable,
                hasStrictSnapshot: hasStrictSnapshot,
                valueMatches: valueMatches,
                selectedRangeRestored: false
            )
        }

        var range = selectedRange
        let restored: Bool
        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return .guardedPaste
        }
        if let rangeValue = AXValueCreate(.cfRange, &range),
           AXUIElementSetAttributeValue(
                current,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success,
           Self.setShortMessagingTimeout(for: current, deadline: deadline),
           let verified = Self.selectedTextRange(of: current),
           verified.location == selectedRange.location,
           verified.length == selectedRange.length {
            restored = true
        } else {
            restored = false
        }
        return InsertionPasteRouting.decide(
            isSecureInput: false,
            targetMatches: true,
            isKnownNonEditable: false,
            hasStrictSnapshot: true,
            valueMatches: true,
            selectedRangeRestored: restored
        )
    }

    private static func clipboardOnlyPreparation() -> InsertionPastePreparation {
        InsertionPasteRouting.decide(
            isSecureInput: false,
            targetMatches: false,
            isKnownNonEditable: false,
            hasStrictSnapshot: false,
            valueMatches: false,
            selectedRangeRestored: false
        )
    }

    /// クリップボードを経由せず、停止時の選択範囲を直接置換する。
    /// AX側が書込み可能であることと、置換後の値を両方確認できる場合だけ成功にする。
    func replaceSelection(with text: String) -> DirectTextInsertionResult {
        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        switch prepareForPaste(deadline: deadline) {
        case .strictVerified:
            break
        case .guardedPaste:
            return .notSupported
        case .clipboardOnly:
            return .targetChanged
        case .secureInput:
            return .secureInput
        }

        guard let expectedValue = expectedValue(afterReplacingSelectionWith: text) else {
            return .targetChanged
        }
        guard Self.setShortMessagingTimeout(for: focusedElement, deadline: deadline) else {
            return .notSupported
        }
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else {
            return .notSupported
        }

        guard Self.setShortMessagingTimeout(for: focusedElement, deadline: deadline) else {
            return .notSupported
        }
        guard AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .notSupported
        }
        return currentValueMatches(expectedValue, deadline: deadline) ? .inserted : .unconfirmed
    }

    /// AX直接書込みではなくUnicode互換入力を使う前に、停止時と同じ入力先を
    /// read-onlyで確認する。途中で別欄へ移動した場合、明示配送をそこへ送らず
    /// 結果ウィンドウへ退避させる。
    func validateExplicitUnicodeTarget() -> ExplicitUnicodeTargetValidation {
        let secureInputEnabled = IsSecureEventInputEnabled()
        let processMatches = NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        guard !secureInputEnabled, !isSecureTextField, processMatches else {
            return AICommandExplicitUnicodeTargetPolicy.decision(
                secureInputEnabled: secureInputEnabled,
                destinationIsSecureTextField: isSecureTextField,
                processMatches: processMatches,
                focusMatches: nil,
                editableState: nil,
                valueMatches: nil,
                capturedRange: selectedRange,
                currentRange: nil
            )
        }

        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        guard Self.setShortMessagingTimeout(for: application, deadline: deadline) else {
            return .unconfirmed
        }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue, Date() <= deadline else {
            return .unconfirmed
        }
        let current = unsafeBitCast(focusedValue, to: AXUIElement.self)
        guard CFEqual(current, focusedElement) else { return .targetChanged }
        switch Self.liveSecureTextFieldClassification(of: current, deadline: deadline) {
        case .nonSecure:
            break
        case .secure:
            return .secureInput
        case .unconfirmed:
            return .unconfirmed
        }
        let currentState = Self.editableState(of: current)
        guard currentState == .editable else {
            return AICommandExplicitUnicodeTargetPolicy.decision(
                secureInputEnabled: false,
                destinationIsSecureTextField: false,
                processMatches: true,
                focusMatches: true,
                editableState: currentState,
                valueMatches: nil,
                capturedRange: selectedRange,
                currentRange: nil
            )
        }

        guard Self.setShortMessagingTimeout(for: current, deadline: deadline),
              let valueSnapshot,
              let currentValue = Self.stringValue(of: current) else {
            return .unconfirmed
        }
        guard Self.setShortMessagingTimeout(for: current, deadline: deadline),
              let currentRange = Self.selectedTextRange(of: current) else {
            return .unconfirmed
        }
        return AICommandExplicitUnicodeTargetPolicy.decision(
            secureInputEnabled: false,
            destinationIsSecureTextField: false,
            processMatches: true,
            focusMatches: true,
            editableState: currentState,
            valueMatches: currentValue == valueSnapshot,
            capturedRange: selectedRange,
            currentRange: currentRange
        )
    }

    /// 録音停止時に捕捉した0文字キャレットへだけ挿入する。
    ///
    /// `prepareForPaste`／`replaceSelection`は選択置換のため停止時範囲を復元するが、
    /// 明示結果の挿入では、利用者が処理中にキャレットを動かした場合に元の位置へ
    /// 巻き戻してはならない。この経路は現在の範囲を変更せず、停止時と同じ要素・
    /// 本文・0文字範囲を確認できた時だけAX書込みを行う。
    func insertAtCapturedCaret(with text: String) -> DirectTextInsertionResult {
        guard !IsSecureEventInputEnabled(), !isSecureTextField else {
            return .secureInput
        }
        switch AICommandCapturedCaretPolicy.decision(
            capturedRange: selectedRange,
            currentRange: selectedRange
        ) {
        case .verified:
            break
        case .unavailable:
            return .notSupported
        case .selectionNotCollapsed:
            return .selectionNotCollapsed
        case .targetChanged:
            return .targetChanged
        }
        guard let capturedRange = selectedRange else { return .notSupported }
        guard let valueSnapshot,
              expectedValue(afterReplacingSelectionWith: text) != nil else {
            return .notSupported
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return .targetChanged
        }

        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        guard Self.setShortMessagingTimeout(for: application, deadline: deadline) else {
            return .unconfirmed
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value, Date() <= deadline else {
            return .unconfirmed
        }
        let current = unsafeBitCast(value, to: AXUIElement.self)
        guard CFEqual(current, focusedElement) else { return .targetChanged }

        switch Self.liveSecureTextFieldClassification(of: current, deadline: deadline) {
        case .nonSecure:
            break
        case .secure:
            return .secureInput
        case .unconfirmed:
            return .unconfirmed
        }
        switch Self.editableState(of: current) {
        case .editable:
            break
        case .nonEditable:
            return .nonEditable
        case .unknown, .changed, .secureInput:
            return .notSupported
        }

        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return .unconfirmed
        }
        guard let currentValue = Self.stringValue(of: current) else {
            return .unconfirmed
        }
        guard currentValue == valueSnapshot else { return .targetChanged }

        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return .unconfirmed
        }
        guard let currentRange = Self.selectedTextRange(of: current) else {
            return .unconfirmed
        }
        switch AICommandCapturedCaretPolicy.decision(
            capturedRange: capturedRange,
            currentRange: currentRange
        ) {
        case .verified:
            break
        case .unavailable:
            return .unconfirmed
        case .selectionNotCollapsed:
            return .selectionNotCollapsed
        case .targetChanged:
            return .targetChanged
        }

        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return .unconfirmed
        }
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            current,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success, isSettable.boolValue else {
            return .notSupported
        }
        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return .unconfirmed
        }
        guard AXUIElementSetAttributeValue(
            current,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .notSupported
        }
        guard let expectedValue = expectedValue(afterReplacingSelectionWith: text) else {
            return .unconfirmed
        }
        return currentValueMatches(expectedValue, deadline: deadline) ? .inserted : .unconfirmed
    }

    /// `replaceSelection` が `.unconfirmed` を返したあと、AX値をもう一度読んで判定する。
    ///
    /// `replaceSelection` は同期・純粋なまま保つ（AIに指示の経路と共有しているため）。
    /// 待機を挟むのは呼び出し側の非同期経路だけにする。
    func reconfirmInsertion(of text: String) -> InsertionReconfirmation {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let expectedValue = expectedValue(afterReplacingSelectionWith: text) else {
            return .ambiguous
        }
        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        guard Self.setShortMessagingTimeout(for: focusedElement, deadline: deadline) else {
            return .ambiguous
        }
        return Self.reconfirmation(
            currentValue: Self.stringValue(of: focusedElement),
            expectedValue: expectedValue,
            valueSnapshot: valueSnapshot
        )
    }

    /// 3分岐の判定は値の比較だけで決まるので、AXから切り離して回帰テストで固定する。
    static func reconfirmation(
        currentValue: String?,
        expectedValue: String,
        valueSnapshot: String?
    ) -> InsertionReconfirmation {
        if currentValue == expectedValue { return .matched }
        // 停止時の値のままなら書込みは届いていない。⌘Vを送っても二重にならない。
        if let currentValue, let valueSnapshot, currentValue == valueSnapshot { return .unchanged }
        return .ambiguous
    }

    /// Command-V経路のあと、前面アプリが今回の値を受け取ったことを確認する。
    /// 途中で対象アプリ・フォーカス・元の本文が変わった場合は確認失敗と扱い、
    /// 以前のクリップボードを復元してはいけない。
    func confirmsInsertion(of text: String) -> Bool {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let expectedValue = expectedValue(afterReplacingSelectionWith: text) else {
            return false
        }
        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        guard Self.setShortMessagingTimeout(for: application, deadline: deadline) else {
            return false
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value,
              Date() <= deadline else {
            return false
        }
        let current = unsafeBitCast(value, to: AXUIElement.self)
        guard CFEqual(current, focusedElement) else { return false }
        return currentValueMatches(expectedValue, deadline: deadline)
    }

    private func expectedValue(afterReplacingSelectionWith text: String) -> String? {
        guard let selectedRange,
              let valueSnapshot,
              selectedRange.location != kCFNotFound else { return nil }
        let snapshot = valueSnapshot as NSString
        let range = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard range.location >= 0,
              range.length >= 0,
              range.location <= snapshot.length,
              range.length <= snapshot.length - range.location else {
            return nil
        }
        return snapshot.replacingCharacters(in: range, with: text)
    }

    private func currentValueMatches(_ expectedValue: String, deadline: Date) -> Bool {
        guard Self.setShortMessagingTimeout(for: focusedElement, deadline: deadline) else {
            return false
        }
        return Self.stringValue(of: focusedElement) == expectedValue
    }

    /// 貼り付け直前に、いま実際にフォーカスされている要素が編集可能かだけを見る。
    ///
    /// `prepareForPaste()` は `CFEqual` の不一致時点で抜けるため、現在のフォーカスが
    /// 編集可能かどうかという情報を捨てている。`.targetChanged` から互換貼り付けへ
    /// 縮退する経路では、フォーカスが編集できない場所へ移っていた場合に中止したい。
    ///
    /// AXが答えられない場合（`.unknown`）とフォーカス要素を取得できない場合は許可する。
    /// WebKitは同じ入力欄でも照会ごとに別プロキシを返すため、そこを塞ぐと
    /// Safariの挿入が直らない（2026-07-30の実機報告）。
    func currentFocusAllowsPaste() -> Bool {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return false
        }
        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        guard Self.setShortMessagingTimeout(for: application, deadline: deadline) else {
            // 通常モードの互換経路では、AX timeoutだけを理由に既存のWeb貼り付けを
            // 塞がない。実際のCmd-V直前にもPID/Secure Inputは再確認される。
            return true
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value,
              Date() <= deadline else {
            // フォーカス要素を公開しないアプリ（Electron等）は従来どおり許可する。
            return true
        }
        let current = unsafeBitCast(value, to: AXUIElement.self)
        guard Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return true
        }
        return Self.editableState(of: current) != .nonEditable
    }

    /// 本文なしのハンズフリー送信は、停止時と**同一の**AX要素が今も編集可能と
    /// 証明できる場合だけ許す。AXを公開しないWeb/Electronへの通常貼り付けとは違い、
    /// Return単独には本文の確認材料が無いため、未知を許可してはならない。
    func currentFocusMatchesCapturedEditableElement() -> Bool {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            return false
        }
        let deadline = Date().addingTimeInterval(InsertionDestinationCapturePolicy.totalTimeoutSeconds)
        let application = AXUIElementCreateApplication(processIdentifier)
        guard Self.setShortMessagingTimeout(for: application, deadline: deadline) else {
            return false
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value,
              Date() <= deadline else {
            return false
        }
        let current = unsafeBitCast(value, to: AXUIElement.self)
        guard CFEqual(current, focusedElement),
              Self.setShortMessagingTimeout(for: current, deadline: deadline) else {
            return false
        }
        return Self.editableState(of: current) == .editable
    }

    private static func editableState(of element: AXUIElement) -> InsertionDestinationState {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success {
            return settable.boolValue ? .editable : .nonEditable
        }
        return .unknown
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
