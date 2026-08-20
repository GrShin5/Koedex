import Foundation

/// GUIアプリはシェルPATHを継承しないため、`/usr/bin/env codex`はexit 127で即死する。
/// このリゾルバは既知の候補パスから`codex`実行ファイルの絶対パスを解決し、
/// `Process.executableURL`へ直接渡せるようにする。
enum CodexPathResolver {
    /// 優先順位:
    /// 1. 設定値 settingsPath（非空・存在・実行可能なら採用）
    /// 2. CodexBinaryLocations.codexCandidates()（npm/Volta/Homebrew/nvm/fnm/asdf/pnpm/bun/MacPorts）
    /// 3. `<shell> -lc 'command -v codex'`（タイムアウト5秒）
    /// 4. `<shell> -ilc 'command -v codex'`（タイムアウト10秒）
    ///
    /// 3を先に試すのは、従来からある速い経路をそのまま残すため。
    /// 3は非対話シェルなので`~/.zshrc`を読まない。nvm・fnm・asdf・voltaは慣例として
    /// `~/.zshrc`に初期化を書くため、そこにしか設定がない環境では4でしか見つからない。
    ///
    /// 4は対話シェルなので、起動ファイル経由でユーザーのシェル状態に触れることがある
    /// （zshの履歴追記、`compinit`による`~/.zcompdump`の生成など）。パス探索のためだけに
    /// 副作用を持つ経路なので、3で見つからなかった時にだけ使い、結果はキャッシュする。
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

        for candidate in CodexBinaryLocations.codexCandidates() {
            if isExecutable(candidate) {
                AppLog.shared.info("codex解決: 既知パスで発見")
                return candidate
            }
        }

        if let fromShell = shellProbeCache.resolve({
            resolveViaShell(interactive: false, timeoutSeconds: 5)
                ?? resolveViaShell(interactive: true, timeoutSeconds: 10)
        }) {
            AppLog.shared.info("codex解決: ログインシェル経由で発見")
            return fromShell
        }

        AppLog.shared.error("codex解決: すべての候補で失敗しました（設定/既知パス/ログインシェル）")
        return nil
    }

    /// 自動探索で見つかった候補の一覧。設定画面で「探した場所」を示すために使う。
    static func searchedLocationsSummary() -> [String] {
        CodexBinaryLocations.codexCandidates()
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// ユーザーのログインシェルを使う。`$SHELL`が取れない、または`-ilc`を解さない
    /// シェル（fish等）の場合は`/bin/zsh`へフォールバックする。
    private static func loginShellPath() -> String {
        let fallback = "/bin/zsh"
        guard let shell = ProcessInfo.processInfo.environment["SHELL"],
              shell.hasPrefix("/"),
              isExecutable(shell) else {
            return fallback
        }
        let name = (shell as NSString).lastPathComponent
        return (name == "zsh" || name == "bash") ? shell : fallback
    }

    /// ログインシェルへ1回だけ問い合わせてPATHを解決する最終手段。
    /// 失敗（起動不可・非0終了・空出力・タイムアウト）はすべて無視してnilを返す。
    ///
    /// 標準出力はPipeではなく一時ファイルへ落とす。Pipeにすると、起動ファイルが大量に
    /// 書いた時にバッファが詰まってシェルが止まり、読み取り側のスレッドは、シェルが
    /// バックグラウンドで起こしたプロセスが書き込み端を握ったままだと戻ってこない。
    /// ファイルならどちらも起きず、待つスレッドも要らない。
    private static func resolveViaShell(interactive: Bool, timeoutSeconds: Double) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("koedex-codex-probe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: loginShellPath())
        proc.arguments = [interactive ? "-ilc" : "-lc", "command -v codex"]
        proc.standardOutput = outputHandle
        proc.standardError = FileHandle.nullDevice
        // 対話シェルが入力を待って止まらないようにする
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            AppLog.shared.warn("codex解決: ログインシェル起動に失敗")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                AppLog.shared.warn("codex解決: ログインシェル経由の解決がタイムアウトしました")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: outputURL),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        // 対話シェルでは起動ファイルが標準出力へ書くことがあるため、後ろの行から探す。
        for line in output.split(separator: "\n").reversed() {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, isExecutable(path) else { continue }
            return path
        }
        return nil
    }

    /// シェルへの問い合わせは、失敗した時ほど高くつく（起動ファイルの読み込みを待つため）。
    /// 見つかった結果はプロセス内で使い回し、失敗した直後は一定時間だけ再試行を控える。
    /// これが無いと、アクティブ化のたびの再接続で毎回シェルを起こすことになる。
    private final class ShellProbeCache: @unchecked Sendable {
        private static let failureCooldownSeconds: TimeInterval = 60
        private let lock = NSLock()
        private var resolved: String?
        private var lastAttemptAt: Date?

        func resolve(_ probe: () -> String?) -> String? {
            lock.lock()
            if let resolved, CodexPathResolver.isExecutable(resolved) {
                lock.unlock()
                return resolved
            }
            if let lastAttemptAt,
               Date().timeIntervalSince(lastAttemptAt) < Self.failureCooldownSeconds {
                lock.unlock()
                return nil
            }
            lastAttemptAt = Date()
            lock.unlock()

            let found = probe()

            lock.lock()
            resolved = found
            lock.unlock()
            return found
        }
    }

    private static let shellProbeCache = ShellProbeCache()
}
