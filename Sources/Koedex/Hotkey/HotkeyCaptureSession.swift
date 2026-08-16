import Foundation

/// UIや永続化から独立した、ショートカット入力の正規化イベント。
///
/// AppKit側では `NSEvent` をこの型へ変換して `HotkeyCaptureSession.consume(_:)`
/// に渡す。`modifiers` はイベントに含まれる修飾フラグだけを正規化して渡し、
/// 直前の `flagsChanged` で捕捉した修飾キーはセッション側で保持する。
struct HotkeyCaptureEvent: Equatable {
    enum Kind: Equatable {
        case flagsChanged
        case keyDown
        case keyUp
    }

    let kind: Kind
    let keyCode: UInt16
    let modifiers: HotkeyCaptureModifierFlags

    init(kind: Kind, keyCode: UInt16, modifiers: HotkeyCaptureModifierFlags = []) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// AppKitなどのフレームワークに依存しない修飾キーの表現。
/// 呼び出し側は `NSEvent.ModifierFlags` をこのOptionSetへ写像して使用する。
struct HotkeyCaptureModifierFlags: OptionSet, Equatable {
    let rawValue: UInt8

    static let function = HotkeyCaptureModifierFlags(rawValue: 1 << 0)
    static let command = HotkeyCaptureModifierFlags(rawValue: 1 << 1)
    static let option = HotkeyCaptureModifierFlags(rawValue: 1 << 2)
    static let control = HotkeyCaptureModifierFlags(rawValue: 1 << 3)
    static let shift = HotkeyCaptureModifierFlags(rawValue: 1 << 4)
}

/// 入力対象ごとの、候補確定前に適用する構文上の制約。
/// 予約済みキーや既存設定との重複は、保存前に呼び出し側で検証する。
enum HotkeyCapturePolicy: Equatable {
    /// 通常モード。macOSが取得できる任意の単一キーを許可する。
    /// Escapeは候補化せず、待受のキャンセル操作として扱う。
    case normalSingleKey
    /// AIに指示モードの起動キー。1〜3キー、複数キーの場合は修飾キーを含める。
    case aiStart
    /// 「AIに指示モード」の停止キー。単一キーだけを許可する。
    case aiStop
}

/// すべてのキーを離した時点で返す、保存前の候補検証エラー。
enum HotkeyCaptureError: Error, Equatable {
    case normalRequiresSingleKey
    case aiStartRequiresOneToThreeKeys
    case aiStartRequiresModifierForMultipleKeys
    case aiStopRequiresSingleKey

    private var japaneseMessage: String {
        switch self {
        case .normalRequiresSingleKey:
            return "通常モードのキーは1つだけ選んでください。"
        case .aiStartRequiresOneToThreeKeys:
            return "起動キーは1〜3個のキーで設定してください。"
        case .aiStartRequiresModifierForMultipleKeys:
            return "複数キーの起動キーには、修飾キーを含めてください。"
        case .aiStopRequiresSingleKey:
            return "停止キーは1つだけ選んでください。"
        }
    }

    /// 保存しないUIエラー。呼び出し側の表示言語に合わせて解決する。
    func message(for language: AppLanguage) -> String {
        AppLocalizer.text(japaneseMessage, language: language)
    }

    /// 既存の回帰・非UI呼び出しでは従来どおり日本語を返す。
    var message: String { message(for: .japanese) }
}

/// 入力中・候補・無効・キャンセルを明示する、UI表示向けの状態。
/// `.candidate` は保存済みではないため、オンボーディングでは明示的な確定ボタンで保存する。
enum HotkeyCaptureStatus: Equatable {
    case capturing(preview: HotkeyBinding?)
    case candidate(HotkeyBinding)
    case invalid(HotkeyCaptureError)
    case cancelled

    var candidate: HotkeyBinding? {
        guard case let .candidate(binding) = self else { return nil }
        return binding
    }

    var error: HotkeyCaptureError? {
        guard case let .invalid(error) = self else { return nil }
        return error
    }

    var isTerminal: Bool {
        switch self {
        case .capturing:
            return false
        case .candidate, .invalid, .cancelled:
            return true
        }
    }
}

/// 純粋なショートカット入力セッション。
///
/// `flagsChanged` → `keyDown` → `keyUp` → `flagsChanged` のようなイベント列を
/// 受け取り、関係する全キーが解放されるまで候補を確定しない。そのため、
/// `fn` の `flagsChanged` の後にSpaceの `keyDown` が届く環境でも、
/// `fn + Space` を `fn` 単体として誤認しない。
///
/// 例:
/// ```swift
/// var session = HotkeyCaptureSession(policy: .aiStart)
/// _ = session.consume(.init(kind: .flagsChanged, keyCode: 0x3F, modifiers: [.function]))
/// _ = session.consume(.init(kind: .keyDown, keyCode: 0x31))
/// _ = session.consume(.init(kind: .keyUp, keyCode: 0x31))
/// let result = session.consume(.init(kind: .flagsChanged, keyCode: 0x3F))
/// // result == .candidate(HotkeyBinding(keys: [.function, .space]))
/// ```
struct HotkeyCaptureSession {
    static let escapeKeyCode: UInt16 = 0x35

    let policy: HotkeyCapturePolicy
    private(set) var status: HotkeyCaptureStatus

    private var pressedModifierKeys: [UInt16: HotkeyKey] = [:]
    private var pressedRegularKeyCodes: Set<UInt16> = []
    private var capturedKeys: [UInt16: HotkeyKey] = [:]

    init(policy: HotkeyCapturePolicy) {
        self.policy = policy
        self.status = .capturing(preview: nil)
    }

    /// 正規化済みイベントを反映する。候補またはエラーになった後は、`reset()`まで状態を保持する。
    @discardableResult
    mutating func consume(_ event: HotkeyCaptureEvent) -> HotkeyCaptureStatus {
        guard case .capturing = status else { return status }

        if event.kind == .keyDown, event.keyCode == Self.escapeKeyCode {
            return cancel()
        }

        let wasPressingAnyKey = isPressingAnyKey

        switch event.kind {
        case .flagsChanged:
            updateModifier(for: event)
        case .keyDown:
            // Globe/Fnでは、続く通常キーのイベントに.functionが含まれないことがある。
            // ここでは存在する修飾キーを追加するだけで、直前に捕捉したfnを消さない。
            mergeModifiersPresent(in: event.modifiers)
            registerKeyDown(event.keyCode)
        case .keyUp:
            registerKeyUp(event.keyCode)
        }

        if wasPressingAnyKey, !isPressingAnyKey, !capturedKeys.isEmpty {
            return finishCapture()
        }

        status = .capturing(preview: previewBinding)
        return status
    }

    /// 明示的な再入力用。候補・エラー・押下中のキーをすべて破棄する。
    mutating func reset() {
        pressedModifierKeys.removeAll()
        pressedRegularKeyCodes.removeAll()
        capturedKeys.removeAll()
        status = .capturing(preview: nil)
    }

    /// Escapeや画面遷移時のキャンセル用。保存済み設定には一切影響しない。
    @discardableResult
    mutating func cancel() -> HotkeyCaptureStatus {
        pressedModifierKeys.removeAll()
        pressedRegularKeyCodes.removeAll()
        capturedKeys.removeAll()
        status = .cancelled
        return status
    }

    private var isPressingAnyKey: Bool {
        !pressedModifierKeys.isEmpty || !pressedRegularKeyCodes.isEmpty
    }

    private var previewBinding: HotkeyBinding? {
        guard !capturedKeys.isEmpty else { return nil }
        return HotkeyBinding(keys: Array(capturedKeys.values))
    }

    private mutating func updateModifier(for event: HotkeyCaptureEvent) {
        guard let modifier = Self.modifierKey(for: event.keyCode) else { return }

        if event.modifiers.contains(Self.flag(for: modifier)) {
            registerModifierDown(modifier)
        } else {
            pressedModifierKeys.removeValue(forKey: modifier.keyCode)
        }
    }

    private mutating func mergeModifiersPresent(in flags: HotkeyCaptureModifierFlags) {
        for (flag, modifier) in Self.fallbackModifierKeys where flags.contains(flag) {
            guard !pressedModifierKeys.values.contains(where: { Self.flag(for: $0) == flag }) else { continue }
            registerModifierDown(modifier)
        }
    }

    private mutating func registerModifierDown(_ modifier: HotkeyKey) {
        let normalized = modifier.normalized
        pressedModifierKeys[normalized.keyCode] = normalized
        capturedKeys[normalized.keyCode] = normalized
    }

    private mutating func registerKeyDown(_ keyCode: UInt16) {
        if let modifier = Self.modifierKey(for: keyCode) {
            registerModifierDown(modifier)
            return
        }

        let key = HotkeyKey(keyCode: keyCode, isModifier: false, modifierMask: 0)
        pressedRegularKeyCodes.insert(keyCode)
        capturedKeys[keyCode] = key
    }

    private mutating func registerKeyUp(_ keyCode: UInt16) {
        if Self.modifierKey(for: keyCode) != nil {
            pressedModifierKeys.removeValue(forKey: keyCode)
        } else {
            pressedRegularKeyCodes.remove(keyCode)
        }
    }

    private mutating func finishCapture() -> HotkeyCaptureStatus {
        let binding = HotkeyBinding(keys: Array(capturedKeys.values))
        let result = validate(binding)
        switch result {
        case .success:
            status = .candidate(binding)
        case let .failure(error):
            status = .invalid(error)
        }
        return status
    }

    private func validate(_ binding: HotkeyBinding) -> Result<Void, HotkeyCaptureError> {
        switch policy {
        case .normalSingleKey:
            guard binding.keys.count == 1 else {
                return .failure(.normalRequiresSingleKey)
            }
            return .success(())

        case .aiStart:
            guard (1...3).contains(binding.keys.count) else {
                return .failure(.aiStartRequiresOneToThreeKeys)
            }
            guard binding.keys.count == 1 || binding.keys.contains(where: \.isModifier) else {
                return .failure(.aiStartRequiresModifierForMultipleKeys)
            }
            return .success(())

        case .aiStop:
            guard binding.keys.count == 1 else {
                return .failure(.aiStopRequiresSingleKey)
            }
            return .success(())
        }
    }

    private static func modifierKey(for keyCode: UInt16) -> HotkeyKey? {
        switch keyCode {
        case HotkeyDefaults.fnKeyCode:
            return .function
        case 0x36, 0x37:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x100000)
        case 0x3A, 0x3D:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x080000)
        case 0x3B, 0x3E:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x040000)
        case 0x38, 0x3C:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x020000)
        default:
            return nil
        }
    }

    private static func flag(for key: HotkeyKey) -> HotkeyCaptureModifierFlags {
        switch key.keyCode {
        case HotkeyDefaults.fnKeyCode:
            return .function
        case 0x36, 0x37:
            return .command
        case 0x3A, 0x3D:
            return .option
        case 0x3B, 0x3E:
            return .control
        case 0x38, 0x3C:
            return .shift
        default:
            return []
        }
    }

    private static let fallbackModifierKeys: [(HotkeyCaptureModifierFlags, HotkeyKey)] = [
        (.function, .function),
        (.command, HotkeyKey(keyCode: 0x37, isModifier: true, modifierMask: 0x100000)),
        (.option, HotkeyKey(keyCode: 0x3A, isModifier: true, modifierMask: 0x080000)),
        (.control, HotkeyKey(keyCode: 0x3B, isModifier: true, modifierMask: 0x040000)),
        (.shift, HotkeyKey(keyCode: 0x38, isModifier: true, modifierMask: 0x020000)),
    ]

}
