import AppKit
import Carbon.HIToolbox

/// `NSPasteboard`から事実を集めて`ClipboardSourceReadPolicy`（C-3）へ渡すだけの薄い層。
///
/// 判定ロジックは一切持たない。読むだけで、`clearContents` / `setString` /
/// `declareTypes` / `setData` のいずれも呼ばない。
@MainActor
final class ClipboardSourceReader {
    func read() -> ClipboardSourceReadPolicy.Decision {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems ?? []

        // C-3のドキュメントコメントのとおり、型情報だけの拒否を先に確定する。
        // `readString`は許可された経路だけで呼ばれるため、Secure Input等の拒否側は
        // クリップボード本文を一度も読み取らない。
        var availableTypes = Set((pasteboard.types ?? []).map(\.rawValue))
        if let firstItem = items.first {
            availableTypes.formUnion(firstItem.types.map(\.rawValue))
        }
        let itemCount = items.count
        let secureInputEnabled = IsSecureEventInputEnabled()

        return ClipboardSourceReadPolicy.decision(
            secureInputEnabled: secureInputEnabled,
            itemCount: itemCount,
            availableTypes: Array(availableTypes),
            readString: { pasteboard.string(forType: .string) },
            maximumCharacters: SelectedTextCapture.maximumCharacters
        )
    }
}
