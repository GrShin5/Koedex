import Foundation

/// GUIアプリはシェルPATHを継承しないため、`/usr/bin/env codex`はexit 127で即死する。
/// このリゾルバは既知の候補パスから`codex`実行ファイルの絶対パスを解決し、
/// `Process.executableURL`へ直接渡せるようにする。
enum CodexPathResolver {
    /// 優先順位:
    /// 1. 設定値 settingsPath（非空・存在・実行可能なら採用）
    /// 2. ~/.npm-global/bin/codex
    /// 3. /opt/homebrew/bin/codex
    /// 4. /usr/local/bin/codex
    /// 5. 最終手段: `/bin/zsh -lc 'command -v codex'`（タイムアウト5秒、失敗は無視）
    ///
    /// 解決結果だけをAppLogへ記録する。CLI実行パスは通常ログへ出さない。
    static func resolve(settingsPath: String?) -> String? {
        if let settingsPath, !settingsPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isExecutable(settingsPath) {
                AppLog.shared.info("codex解決: 設定値を使用")
                return settingsPath
            } else {
                AppLog.shared.warn("codex解決: 設定値のパスが無効です。自動探索を続けます")
            }
        }

        let knownCandidates = [
            NSHomeDirectory() + "/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]

        for candidate in knownCandidates {
            if isExecutable(candidate) {
                AppLog.shared.info("codex解決: 既知パスで発見")
                return candidate
            }
        }

        if let fromShell = resolveViaLoginShell() {
            AppLog.shared.info("codex解決: ログインシェル経由で発見")
            return fromShell
        }

        AppLog.shared.error("codex解決: すべての候補で失敗しました（設定/既知パス/ログインシェル）")
        return nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// `/bin/zsh -lc 'command -v codex'` を1回だけ実行してPATHを解決する最終手段。
    /// タイムアウト5秒。失敗（起動不可・非0終了・空出力・タイムアウト）はすべて無視してnilを返す。
    private static func resolveViaLoginShell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v codex"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            AppLog.shared.warn("codex解決: ログインシェル起動に失敗")
            return nil
        }

        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                AppLog.shared.warn("codex解決: ログインシェル経由の解決がタイムアウトしました")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty, isExecutable(output) else {
            return nil
        }
        return output
    }
}
