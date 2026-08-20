import Foundation

/// GUI起動（Finder/Dock/`open`経由）のPATHは "/usr/bin:/bin:/usr/sbin:/sbin" 程度しかない。
/// codex CLIもnode本体も、Nodeのバージョン管理ツールがHOME配下に作る場所へ入っていることが多い。
/// 子プロセスへ渡すPATHの組み立て（`CodexAppServerClient.buildChildEnvironment()`）と、
/// codex実行ファイルの探索（`CodexPathResolver`）が同じ候補を使うよう、ここへ集約する。
enum CodexBinaryLocations {
    /// 候補ディレクトリを優先順で返す。実在するものだけに絞り込む。
    /// 先頭6件とnvm展開の並びは子プロセスPATHの解決順序として実績があるため変更しない。
    /// 追加の候補は、その後ろへ足す。
    static func toolDirectories() -> [String] {
        let fm = FileManager.default
        return allCandidateDirectories().filter { fm.fileExists(atPath: $0) }
    }

    /// 実在確認をかける前の候補。順序そのものを回帰テストで固定するために分けてある。
    static func allCandidateDirectories() -> [String] {
        let home = NSHomeDirectory()

        var candidates: [String] = [
            home + "/.npm-global/bin",      // npm prefix
            home + "/.volta/bin",           // Volta
            "/opt/homebrew/bin",            // Apple Silicon Homebrew
            "/opt/homebrew/opt/node/bin",   // Homebrew node keg (ARM)
            "/usr/local/bin",               // Intel Homebrew
            "/usr/local/opt/node/bin",      // Homebrew node keg (Intel)
        ]

        // nvm: ~/.nvm/versions/node/<version>/bin をバージョン降順（新しい順）で展開する
        candidates.append(contentsOf: versionedDirectories(
            root: home + "/.nvm/versions/node",
            leaf: "bin"
        ))

        // fnm: ~/Library/Application Support/fnm/node-versions/<version>/installation/bin
        candidates.append(contentsOf: versionedDirectories(
            root: home + "/Library/Application Support/fnm/node-versions",
            leaf: "installation/bin"
        ))

        candidates.append(contentsOf: [
            home + "/.asdf/shims",          // asdf
            home + "/Library/pnpm",         // pnpm
            home + "/.bun/bin",             // bun
            home + "/.local/bin",           // 汎用
            "/opt/local/bin",               // MacPorts
        ])

        return candidates
    }

    /// `codex`実行ファイルの候補を優先順で返す。
    static func codexCandidates() -> [String] {
        toolDirectories().map { $0 + "/codex" }
    }

    private static func versionedDirectories(root: String, leaf: String) -> [String] {
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(root)/\($0)/\(leaf)" }
    }
}
