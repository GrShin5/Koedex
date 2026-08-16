import Foundation
import CoreGraphics

/// 「AIに指示」クリップボード入力バリアントの追加修飾キー。
///
/// **左右を畳んで側非依存に扱う。** 2026-08-07の実機採取で、同じMacでも接続する
/// キーボードによってside-specificビットの有無が変わることが判明した
/// （キーボードAの`0x900110`は右⌘ビット`0x10`を出すが、キーボードBの`0x20900000`は
/// 汎用マスク`0x100000`のみを出す）。側を指定すると接続キーボードで挙動が変わって
/// しまうため、判定材料には汎用マスクとkeyCodeの集合だけを持つ。`fn`は候補に含めない。
enum AICommandClipboardModifier: String, Codable, CaseIterable, Hashable {
    case command
    case option
    case control
    case shift

    /// 値の根拠: `HotkeyBinding.swift`の`normalized`におけるmask表（:26-34）。
    var genericMask: UInt64 {
        switch self {
        case .command: return 0x100000
        case .option: return 0x080000
        case .control: return 0x040000
        case .shift: return 0x020000
        }
    }

    /// 左右**両方**のkeyCode。値の根拠:
    /// `HotkeyModifierFlagsPolicy.deviceDependentMask`のkeyCode表（`HotkeyBinding.swift:64-76`）。
    var keyCodes: [UInt16] {
        switch self {
        case .command: return [0x36, 0x37]
        case .option: return [0x3A, 0x3D]
        case .control: return [0x3B, 0x3E]
        case .shift: return [0x38, 0x3C]
        }
    }

    /// 設定UI表示用。記号だけ（読みにくい）でも単語だけ（既存UIと不揃い）でもなく、
    /// 左右どちらのキーにも当てはまることが伝わる表記にする。
    var displayLabel: String {
        switch self {
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        }
    }
}

/// クリップボード入力バリアントのChord構成が安全に有効化できるかを判定する純粋なポリシー。
enum AICommandClipboardChordPolicy {
    enum Eligibility: Equatable {
        case eligible
        case startBindingHasNoNormalKey
        case chordExceedsThreeKeys
        case collidesWithStart
        case collidesWithStop
        case collidesWithNormal
        case collidesWithHandsFreeSend
        case chordIsSystemReserved
    }

    /// C-1: 設定保存時のリリースゲート。判定順は先に成立したものを返す。
    static func eligibility(
        startBinding: HotkeyBinding,
        extraModifier: AICommandClipboardModifier,
        stopBinding: HotkeyBinding,
        normalBinding: HotkeyBinding,
        handsFreeSendBinding: HotkeyBinding,
        handsFreeSendEnabled: Bool
    ) -> Eligibility {
        // startのラッチが通常キーを持たない構成では、ラッチは押下集合が揃った時点で
        // どのキーでも成立する（`HotkeyManager.swift:471-483`のstartHasNormalKey）。
        // 追加キーを後から押しても通常バリアントで確定してしまうため対象外にする。
        guard startBinding.keys.contains(where: { !$0.isModifier }) else {
            return .startBindingHasNoNormalKey
        }
        // `HotkeyBinding.isValid`は最大3キー（`HotkeyBinding.swift:115-117`）。
        guard startBinding.keys.count < 3 else {
            return .chordExceedsThreeKeys
        }
        // 3〜6は左右どちらのキーコードでも検出する。
        if bindingContainsAny(startBinding, of: extraModifier) {
            return .collidesWithStart
        }
        if bindingContainsAny(stopBinding, of: extraModifier) {
            return .collidesWithStop
        }
        if bindingContainsAny(normalBinding, of: extraModifier) {
            return .collidesWithNormal
        }
        if handsFreeSendEnabled, bindingContainsAny(handsFreeSendBinding, of: extraModifier) {
            return .collidesWithHandsFreeSend
        }
        // 追加キーを足した結果のChordを、通常のbindingと同じ固定denylistで
        // 判定する。予約はmodifier familyの完全一致で決まり、⌘や⌃自体を
        // 一律に使用不可とするものではない。
        if HotkeyBinding(keys: startBinding.keys + [representativeKey(for: extraModifier)])
            .isKnownSystemReserved {
            return .chordIsSystemReserved
        }
        return .eligible
    }

    static func eligibilities(
        startBinding: HotkeyBinding,
        stopBinding: HotkeyBinding,
        normalBinding: HotkeyBinding,
        handsFreeSendBinding: HotkeyBinding,
        handsFreeSendEnabled: Bool
    ) -> [AICommandClipboardModifier: Eligibility] {
        Dictionary(uniqueKeysWithValues: AICommandClipboardModifier.allCases.map { modifier in
            (
                modifier,
                eligibility(
                    startBinding: startBinding,
                    extraModifier: modifier,
                    stopBinding: stopBinding,
                    normalBinding: normalBinding,
                    handsFreeSendBinding: handsFreeSendBinding,
                    handsFreeSendEnabled: handsFreeSendEnabled
                )
            )
        })
    }

    static func pickerOptions(
        eligibilities: [AICommandClipboardModifier: Eligibility],
        current: AICommandClipboardModifier
    ) -> [AICommandClipboardModifier] {
        AICommandClipboardModifier.allCases.filter { candidate in
            eligibilities[candidate] == .eligible || candidate == current
        }
    }

    /// 予約規則の判定用。`isKnownSystemReserved`は正規化後の`modifierMask`
    /// familyを見るため、側非依存の修飾キーを左右どちらか一方のkeyCodeで代表させる。
    /// `HotkeyBinding(keys:)`が`normalized`を通すので、どちらを選んでも同じmaskになる。
    private static func representativeKey(for modifier: AICommandClipboardModifier) -> HotkeyKey {
        HotkeyKey(
            keyCode: modifier.keyCodes[0],
            isModifier: true,
            modifierMask: modifier.genericMask
        )
    }

    private static func bindingContainsAny(
        _ binding: HotkeyBinding,
        of modifier: AICommandClipboardModifier
    ) -> Bool {
        let codes = Set(modifier.keyCodes)
        return binding.keys.contains { codes.contains($0.keyCode) }
    }

    /// C-2: ラッチ確定イベント自身のflagsだけから入力ソースを判定する。
    ///
    /// **side-specificビットも押下集合も参照しない。** 押下集合へ追加キーの状態を足すと、
    /// 解放イベントを取りこぼした場合に残留し、次の通常chordを誤分類する。これは
    /// `HotkeyBinding.swift:38-45`に記録された2026-07-30の左Shift残留障害と同型の失敗になる。
    /// ここでは常に、いま処理している1イベントのflagsだけを読む。
    static func inputSource(
        extraModifier: AICommandClipboardModifier?,
        latchingKey: HotkeyKey,
        eventFlags: CGEventFlags
    ) -> AICommandInputSource {
        guard let extraModifier else { return .selection }
        // C-1はstartBindingが必ず非修飾キーを持つ構成だけをeligibleにする。ラッチは
        // その非修飾キーで成立する前提を、実行時にも守る（ラッチが修飾キーで起きた
        // 場合はここでは判定しない）。
        guard !latchingKey.isModifier else { return .selection }
        return (eventFlags.rawValue & extraModifier.genericMask) != 0 ? .clipboard : .selection
    }
}

/// クリップボードモードのON/OFF要求を、既存のChord適格性へ結び付ける純粋なポリシー。
/// 保存済みの不適格値はここで自動修正せず、UI側が理由を表示する。
enum AICommandClipboardActivationPolicy {
    enum Decision: Equatable {
        case disabled
        case enabled
        case rejected(AICommandClipboardChordPolicy.Eligibility)
    }

    static func decision(
        requestedEnabled: Bool,
        eligibility: AICommandClipboardChordPolicy.Eligibility
    ) -> Decision {
        guard requestedEnabled else { return .disabled }
        return eligibility == .eligible ? .enabled : .rejected(eligibility)
    }
}

/// `Eligibility`を利用者向け案内文へ変換する純粋関数。
enum AICommandClipboardEligibilityCopy {
    /// `.eligible`は案内不要なので`nil`。それ以外は必ず文言を返す。
    /// `default:`を書かない。ケース追加時にコンパイラへ検出させるため。
    static func message(
        for eligibility: AICommandClipboardChordPolicy.Eligibility,
        language: AppLanguage
    ) -> String? {
        switch eligibility {
        case .eligible:
            return nil
        case .startBindingHasNoNormalKey:
            return AppLocalizer.text(
                "AIに指示モードの起動キーが修飾キーだけの組み合わせのため、追加キーを判別できません。起動キーに通常キー（Spaceなど）を含めてください。",
                language: language
            )
        case .chordExceedsThreeKeys:
            return AppLocalizer.text(
                "AIに指示モードの起動キーが3つのため、これ以上キーを追加できません。起動キーを2つ以下にしてください。",
                language: language
            )
        case .collidesWithStart:
            return AppLocalizer.text(
                "この追加キーはAIに指示モードの起動キーに含まれているため使えません。別のキーを選んでください。",
                language: language
            )
        case .collidesWithStop:
            return AppLocalizer.text(
                "この追加キーはAIに指示モードの停止キーに含まれているため使えません。別のキーを選んでください。",
                language: language
            )
        case .collidesWithNormal:
            return AppLocalizer.text(
                "この追加キーは通常モードの起動キーに含まれているため使えません。別のキーを選んでください。",
                language: language
            )
        case .collidesWithHandsFreeSend:
            return AppLocalizer.text(
                "この追加キーはハンズフリー送信モードのキーに含まれているため使えません。別のキーを選んでください。",
                language: language
            )
        case .chordIsSystemReserved:
            return AppLocalizer.text(
                "この組み合わせはmacOSが予約しています（Spotlightや入力ソースの切り替え）。別のキーを選んでください。",
                language: language
            )
        }
    }
}
