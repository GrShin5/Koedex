import Foundation

/// 通常UIには露出しない、サポート案内時だけの限定貼り付け互換コマンド。
/// 設定ストアを注入できるため、GUIを起動せず回帰テストできる。
@MainActor
enum ScopedClipboardFallbackSupportCommand {
    static let flag = "--support-scoped-clipboard-fallback"

    enum Action: String, Equatable {
        case enable
        case disable
        case status
    }

    enum ParseResult: Equatable {
        case notRequested
        case success(Action)
        case failure
    }

    enum ExecutionResult: Equatable {
        case notRequested
        case success(String)
        case failure

        var exitCode: Int32 {
            switch self {
            case .notRequested, .success:
                return 0
            case .failure:
                return 1
            }
        }
    }

    static func parse(arguments: [String]) -> ParseResult {
        guard arguments.contains(flag) else { return .notRequested }

        let commandArguments = Array(arguments.dropFirst())
        guard commandArguments.count == 2,
              commandArguments[0] == flag,
              let action = Action(rawValue: commandArguments[1]) else {
            return .failure
        }
        return .success(action)
    }

    static func execute(
        action: Action,
        isDebug: Bool,
        settingsStore: SettingsStore,
        isAnotherInstanceRunning: Bool = false
    ) -> ExecutionResult {
        guard !isAnotherInstanceRunning else {
            FileHandle.standardError.write(Data(
                "Koedex is already running. Quit Koedex, then run this command again.\n".utf8
            ))
            return .failure
        }
        guard !isDebug, settingsStore.canSave else { return .failure }

        switch action {
        case .status:
            return .success(
                settingsStore.settings.externalAppCompatibilitySettings.allowScopedClipboardFallback
                    ? "enabled"
                    : "disabled"
            )
        case .enable:
            // 通常UIの互換入力がOFFだと隠しフラグは立てられない（設定側が握っている）。
            // 理由を出さないと呼び出し側は "support command failed" としか言えず、
            // 「先に設定の互換入力をONにする」という復旧手順に辿り着けない。
            guard settingsStore.settings.externalAppCompatibilitySettings.enabled else {
                FileHandle.standardError.write(Data(
                    """
                    External app compatibility is off, so this flag cannot be enabled.
                    Turn on compatibility mode in Koedex settings first, then run this command again.\n
                    """.utf8
                ))
                return .failure
            }
            guard settingsStore.setScopedClipboardFallbackForSupport(true) else {
                return .failure
            }
            return .success("enabled")
        case .disable:
            // 既にOFFなら書かない。書くと、アプリを一度も起動していないマシンで
            // このコマンドを叩いただけで settings.json ができてしまう。
            guard settingsStore.settings.externalAppCompatibilitySettings.allowScopedClipboardFallback else {
                return .success("disabled")
            }
            guard settingsStore.setScopedClipboardFallbackForSupport(false) else {
                return .failure
            }
            return .success("disabled")
        }
    }
}
