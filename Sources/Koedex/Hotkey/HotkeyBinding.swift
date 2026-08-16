import Foundation
import CoreGraphics

/// A physical key participating in a global hotkey binding.
struct HotkeyKey: Codable, Hashable, Identifiable {
    var keyCode: UInt16
    var isModifier: Bool
    var modifierMask: UInt64

    var id: String { "\(keyCode)|\(isModifier)|\(modifierMask)" }

    static let function = HotkeyKey(
        keyCode: HotkeyDefaults.fnKeyCode,
        isModifier: true,
        modifierMask: HotkeyDefaults.functionModifierMask
    )

    static let leftShift = HotkeyKey(keyCode: 0x38, isModifier: true, modifierMask: 0x020000)
    /// 右Shift。fnと組んでも片手で押せるため、ハンズフリー送信の既定に使う。
    static let rightShift = HotkeyKey(keyCode: 0x3C, isModifier: true, modifierMask: 0x020000)
    static let space = HotkeyKey(keyCode: 0x31, isModifier: false, modifierMask: 0)

    var normalized: HotkeyKey {
        guard isModifier else { return HotkeyKey(keyCode: keyCode, isModifier: false, modifierMask: 0) }
        let mask: UInt64
        switch keyCode {
        case 0x3F: mask = HotkeyDefaults.functionModifierMask
        case 0x36, 0x37: mask = 0x100000
        case 0x3A, 0x3D: mask = 0x080000
        case 0x38, 0x3C: mask = 0x020000
        case 0x3B, 0x3E: mask = 0x040000
        default: mask = modifierMask
        }
        return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: mask)
    }
}

/// 修飾キーの押下/解放を、処理中のイベント自身のflagsだけから判定する純粋なポリシー。
///
/// `CGEventSource.keyState(.combinedSessionState)` を使ってはいけない。
/// head-insertされたtapのコールバック内では、いま処理しているイベントがまだ
/// セッション状態へ反映されていないため、解放イベントを「押下中」と誤判定し、
/// 押下集合にキーが残留する。2026-07-30の実機障害では左Shift(0x38)が残留し、
/// ハンズフリー送信の拘束フラグが解除されず全ホットキーが停止した。
enum HotkeyModifierFlagsPolicy {
    static func isPressed(_ key: HotkeyKey, flags: CGEventFlags) -> Bool {
        if key.keyCode == HotkeyDefaults.fnKeyCode {
            return flags.contains(.maskSecondaryFn)
        }
        guard let deviceMask = deviceDependentMask(for: key.keyCode) else {
            return (flags.rawValue & key.modifierMask) != 0
        }
        if (flags.rawValue & deviceMask) != 0 {
            return true
        }
        // 左右ビットを持たない合成イベント向けの保険。左右ビットが1つも立っておらず、
        // 汎用マスクだけが立っている場合に限り押下として扱う。
        return (flags.rawValue & key.modifierMask) != 0
            && (flags.rawValue & allDeviceDependentMask) == 0
    }

    /// keyCode → NX_DEVICE*KEYMASK。左右の修飾キーを区別できる唯一のビット。
    /// 汎用マスク（.maskShift等）は左右を分けられないため、これが必要になる。
    static func deviceDependentMask(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 0x3B: return 0x0000_0001 // 左Control
        case 0x38: return 0x0000_0002 // 左Shift
        case 0x3C: return 0x0000_0004 // 右Shift
        case 0x37: return 0x0000_0008 // 左Command
        case 0x36: return 0x0000_0010 // 右Command
        case 0x3A: return 0x0000_0020 // 左Option
        case 0x3D: return 0x0000_0040 // 右Option
        case 0x3E: return 0x0000_2000 // 右Control
        default: return nil
        }
    }

    static let allDeviceDependentMask: UInt64 = 0x0000_207F
}

/// A normalized one-to-three key chord. Multi-key chords must include a modifier
/// so ordinary typing never has to be buffered and replayed into the foreground app.
struct HotkeyBinding: Codable, Hashable {
    var keys: [HotkeyKey]

    static let aiCommandStart = HotkeyBinding(keys: [.function, .space])
    static let aiCommandStop = HotkeyBinding(keys: [.function])
    /// ハンズフリー送信は開始と停止を同じ組でトグルする。停止用の別bindingは持たない。
    /// 右Shiftにするのは、fn+左Shiftが片手で押せず開始キー連打の原因になっていたため。
    static let handsFreeSend = HotkeyBinding(keys: [.function, .rightShift])

    init(keys: [HotkeyKey]) {
        var byPhysicalKey: [UInt16: HotkeyKey] = [:]
        for key in keys.map(\.normalized) where byPhysicalKey[key.keyCode] == nil {
            byPhysicalKey[key.keyCode] = key
        }
        self.keys = Array(byPhysicalKey.values).sorted {
            if $0.isModifier != $1.isModifier { return $0.isModifier && !$1.isModifier }
            return $0.keyCode < $1.keyCode
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keys: try container.decode([HotkeyKey].self, forKey: .keys))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
    }

    private enum CodingKeys: String, CodingKey { case keys }

    var isValid: Bool {
        (1...3).contains(keys.count) && (keys.count == 1 || keys.contains(where: \.isModifier))
    }

    var keySet: Set<HotkeyKey> { Set(keys) }

    func conflictsExactly(with other: HotkeyBinding) -> Bool {
        keySet == other.keySet
    }

    /// `self`の全キーが`other`に含まれ、かつ`other`の方が長い場合にtrue。
    /// 例: Fn は Fn + Space の開始キー前方一致になる。
    func isStrictPrefix(of other: HotkeyBinding) -> Bool {
        let ownKeys = keySet
        let otherKeys = other.keySet
        return ownKeys.count < otherKeys.count && ownKeys.isSubset(of: otherKeys)
    }

    var isKnownSystemReserved: Bool {
        let normalizedKeys = keys.map(\.normalized)
        let modifierMasks = Set(
            normalizedKeys.lazy.filter(\.isModifier).map(\.modifierMask)
        )
        let normalKeyCodes = Set(
            normalizedKeys.lazy.filter { !$0.isModifier }.map(\.keyCode)
        )
        return Self.knownSystemReservedChordRows.contains { row in
            row.modifierMasks == modifierMasks
                && !normalKeyCodes.isDisjoint(with: row.normalKeyCodes)
        }
    }

    /// Koedexで設定を拒否するための固定denylist。macOSの全予約キーを
    /// 網羅するものではない。modifier familyは汎用maskの完全一致で比較し、
    /// 左右device bitや未知modifierを既知familyへ畳み込まない。
    private static let knownSystemReservedChordRows: [
        (modifierMasks: Set<UInt64>, normalKeyCodes: Set<UInt16>)
    ] = [
        (modifierMasks: [0x100000], normalKeyCodes: [0x31, 0x30, 0x32, 0x0C, 0x04, 0x2E, 0x0D]),
        (modifierMasks: [0x020000, 0x100000], normalKeyCodes: [0x30, 0x32, 0x0C]),
        (modifierMasks: [0x080000, 0x100000], normalKeyCodes: [0x31, 0x04, 0x2E, 0x0D]),
        (modifierMasks: [0x040000, 0x100000], normalKeyCodes: [0x31, 0x0C]),
        (modifierMasks: [0x080000, 0x020000, 0x100000], normalKeyCodes: [0x0C]),
        (modifierMasks: [0x040000], normalKeyCodes: [0x31]),
        (modifierMasks: [0x040000, 0x080000], normalKeyCodes: [0x31]),
        (modifierMasks: [0x800000], normalKeyCodes: [0x0E, 0x0C, 0x04, 0x67, 0x00, 0x08, 0x02, 0x2D]),
        (modifierMasks: [0x800000, 0x020000], normalKeyCodes: [0x00]),
    ]
}

enum HotkeyConflictReason: Equatable {
    case invalidChord
    case duplicateBinding
    case reservedBySystem
}
