import Foundation

/// アプリ全体の追記型ファイルロガー。
/// 書込先: ~/Library/Application Support/Koedex/logs/koedex.log
/// 5MBを超えたらローテーションし、直近2世代（.1, .2）を保持する。
///
/// `os.Logger`は各ファイルで`private let logger = Logger(...)`として既に使われているため、
/// 名前衝突を避けるためこのファイル内ロガーは`AppLog`という名前にしている。
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    /// ログへ載せてよい最小限のエラー識別子。**エラーを直接補間しないこと。**
    ///
    /// `\(error)` と `localizedDescription` は `NSError` の userInfo を展開するため、
    /// `NSFilePath` / `NSURL` / `NSUnderlyingError` 経由で絶対パスやユーザー文言が入りうる。
    /// このログは不具合報告の材料として外へ出るので、本文は載せず型名・ドメイン・コードに限る。
    ///
    /// Swiftの独自エラー型でも `as NSError` は成立し、`domain` は型名、`code` はケース番号に
    /// なる。どちらも自分たちのコード由来なので安全。
    static func safeDescription(_ error: Error) -> String {
        let nsError = error as NSError
        var description = "\(type(of: error)) domain=\(nsError.domain) code=\(nsError.code)"
        // 原因の連鎖も辿る。bridgeされたFoundationのエラーでは`type(of:)`が`NSError`へ潰れ、
        // アセット準備の失敗などでは連鎖の先だけが本当の原因を持つ。domainとcodeしか読まない
        // ので本文は載らない。循環と過度に深い連鎖を避けるため3段で打ち切る。
        var underlying = nsError.underlyingErrors.first.map { $0 as NSError }
        var depth = 0
        while let current = underlying, depth < 3 {
            description += " <- domain=\(current.domain) code=\(current.code)"
            underlying = current.underlyingErrors.first.map { $0 as NSError }
            depth += 1
        }
        return description
    }

    private let queue = DispatchQueue(label: "com.koedex.app.filelogger", qos: .utility)
    private let fileURL: URL
    private let directoryURL: URL
    private let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024
    private let maxRotatedGenerations = 2
    private let dateFormatter: DateFormatter

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = OnboardingRuntimeProfile.storageRootURL
            ?? appSupport.appendingPathComponent("Koedex", isDirectory: true)
        let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
        // ルートを中間ディレクトリとして作らせるとattributesが効かず0755になる。
        StoragePermissions.ensureDirectory(at: dir)
        StoragePermissions.ensureDirectory(at: logsDir)
        self.directoryURL = logsDir
        self.fileURL = logsDir.appendingPathComponent("koedex.log")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        self.dateFormatter = formatter
    }

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    func info(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        write(level: .info, message: message, file: file, function: function, line: line)
    }

    func warn(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        write(level: .warn, message: message, file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #fileID, function: String = #function, line: Int = #line) {
        write(level: .error, message: message, file: file, function: function, line: line)
    }

    /// 呼び出し元スレッドでは時刻の採取しか行わない。
    ///
    /// 以前は日時の整形・文字列の組み立て・`print` をすべて呼び出し元で同期実行して
    /// いた。録音中はMainActorから毎秒何度も呼ばれるため、音声をSpeechAnalyzerへ
    /// 届ける経路と同じMainActorをその都度奪っていた（2026-07-30の実機ログ）。
    /// 整形は順序を保つ直列キューの中で行う。`Date()` だけは呼び出し時点の値でないと
    /// タイムスタンプがずれるため、ここで採る。
    private func write(level: Level, message: String, file: String, function: String, line: Int) {
        let occurredAt = Date()

        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.dateFormatter.string(from: occurredAt)
            let fileName = (file as NSString).lastPathComponent
            let entry = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line) \(function)] \(message)\n"
            self.rotateIfNeeded()
            self.append(entry)
            // 開発中の可視性のため標準出力にも流す（既存のprint/NSLog置換の移行措置）。
            print(entry, terminator: "")
        }
    }

    /// 書込みは直列キューへ非同期に投げているため、強制終了の直前だけは時間を区切って
    /// 追いつくのを待つ。待ち切れなくても終了は止めない。
    func flush(timeout: TimeInterval) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: StoragePermissions.fileAttributes
            )
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // ログ書き込み失敗自体はアプリを止めない。
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxFileSizeBytes else { return }

        let fm = FileManager.default
        // .2 -> 削除, .1 -> .2, current -> .1 の順でシフトする。
        let gen2 = directoryURL.appendingPathComponent("koedex.log.\(maxRotatedGenerations)")
        let gen1 = directoryURL.appendingPathComponent("koedex.log.1")

        try? fm.removeItem(at: gen2)
        if fm.fileExists(atPath: gen1.path) {
            try? fm.moveItem(at: gen1, to: gen2)
        }
        try? fm.moveItem(at: fileURL, to: gen1)
    }
}
