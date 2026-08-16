/// 録音開始前のSecure Input安全判定を、全入口で共有する純粋な方針。
///
/// hotkeyのmodifierイベントはSecure Input中にも一部だけ届くことがあるため、
/// hotkey側の判定だけでは録音開始を防げない。session生成・選択取得・
/// clipboard読取りの前と、AudioRecorder.start直前の両方でこの判定を使う。
enum RecordingStartSafetyPolicy {
    enum Decision: Equatable {
        case allow
        case blockedBySecureInput
    }

    static func decision(isSecureInputEnabled: Bool) -> Decision {
        isSecureInputEnabled ? .blockedBySecureInput : .allow
    }
}
