import Foundation
import os

private let logger = Logger(subsystem: "com.koedex.app", category: "PidFileManager")

/// 過去に起動したcodex app-serverプロセスが孤児化して残っていないかを検出・後始末する。
/// 起動したPIDと起動時刻(lstart)を ~/Library/Application Support/Koedex/appserver.pid に
/// JSON 1行で記録し、次回起動時に「そのPIDが、Koedex自身がspawnしたapp-serverだと確証が
/// 持てる場合に限り」killする。
///
/// 重要: Codex.app本体（GUIアプリ）の子プロセスは絶対にkillしてはならない。
/// 過去に無差別な判定でCodex.app本体のapp-serverを巻き添えでSIGTERM殺害した実績があるため、
/// 以下すべてを満たす場合のみkill候補とする（1つでも欠けたら安全側に倒してkillしない）:
///   (a) `ps -o comm=` が "codex" を含む
///   (b) `ps -o command=` が "app-server" を含む
///   (c) `ps -o command=` が "/Applications/Codex.app/" を含まない（GUI本体除外）
///   (d) pidfileに記録した起動時刻(lstart)と `ps -o lstart=` の値が一致する
///       （PID再利用による誤爆を防ぐ）
final class PidFileManager: @unchecked Sendable {
    static let shared = PidFileManager()

    /// kill判定の結果と根拠。テスト/ドライラン出力用。
    struct GuardDecision: CustomStringConvertible {
        let shouldKill: Bool
        let reason: String
        var description: String { "kill=\(shouldKill), 理由=\(reason)" }
    }

    /// Codex.appバンドルのパス断片。このパスを含むcommandは絶対にkill対象にしない。
    static let codexAppBundleMarker = "/Applications/Codex.app/"

    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = OnboardingRuntimeProfile.storageRootURL
            ?? appSupport.appendingPathComponent("Koedex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("appserver.pid")
    }

    /// アプリ起動時に一度だけ呼ぶ。前回起動時に記録されたPIDが、Koedex自身がspawnした
    /// app-serverだと確証が持てる場合のみkillする。判定できない場合は絶対にkillせず、
    /// pidfileだけ削除して安全側に倒す。
    func cleanupOrphanFromPreviousRun() {
        lock.lock()
        defer { lock.unlock() }

        let records = readPidRecords()
        guard !records.isEmpty else {
            // pidfileが存在しない、あるいはパースできない（旧形式含む）場合は
            // 起動時刻不明として絶対にkillせず、ファイルだけ削除する。
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        var retained: [PidRecord] = []
        for record in records {
            if let ownerPid = record.ownerPid,
               let ownerLstart = record.ownerLstart,
               isSameLiveProcess(pid: ownerPid, expectedLstart: ownerLstart) {
                // 別の稼働中Koedexインスタンスが所有するchildは孤児ではない。
                if kill(record.pid, 0) == 0 { retained.append(record) }
                continue
            }
            let decision = evaluateGuard(pid: record.pid, expectedLstart: record.lstart)
            if decision.shouldKill {
                logger.info("[PidFileManager] 前回起動の孤児app-serverプロセス(pid=\(record.pid))を検出。終了させます: \(decision.reason, privacy: .public)")
                kill(record.pid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.5)
                let recheck = evaluateGuard(pid: record.pid, expectedLstart: record.lstart)
                if recheck.shouldKill { kill(record.pid, SIGKILL) }
            } else {
                logger.info("[PidFileManager] pid=\(record.pid) はkill対象外と判定: \(decision.reason, privacy: .public)")
            }
        }

        writePidRecords(retained)
    }

    /// 現在起動したapp-serverのPIDと起動時刻(lstart)を記録する。
    /// lstartは`ps -p <pid> -o lstart=`で取得する。
    func recordAppServerPid(_ pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        let lstart = fetchLstart(pid: pid) ?? ""
        let ownerPid = getpid()
        let ownerLstart = fetchLstart(pid: ownerPid) ?? ""
        var records = readPidRecords().filter { $0.pid != pid }
        records.append(PidRecord(
            pid: pid,
            lstart: lstart,
            ownerPid: ownerPid,
            ownerLstart: ownerLstart
        ))
        writePidRecords(records)
    }

    /// 正常終了した1プロセスだけを記録から外す。nilは互換用の全削除。
    func clearPidFile(pid: Int32? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let pid else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let remaining = readPidRecords().filter { $0.pid != pid }
        guard !remaining.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        writePidRecords(remaining)
    }

    // MARK: - pidfile読み取り

    private struct PidRecord {
        let pid: Int32
        let lstart: String
        let ownerPid: Int32?
        let ownerLstart: String?
    }

    /// pidfileをJSON 1行 {"pid":12345,"lstart":"..."} として読み取る。
    /// 旧形式（数字のみ）やパース不能な内容は nil を返す（＝安全側でkillしない扱い）。
    private func readPidRecords() -> [PidRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let rawRecords = obj["records"] as? [[String: Any]] {
            return rawRecords.compactMap { raw in
                guard let pid = raw["pid"] as? NSNumber, let lstart = raw["lstart"] as? String else { return nil }
                return PidRecord(
                    pid: pid.int32Value,
                    lstart: lstart,
                    ownerPid: (raw["owner_pid"] as? NSNumber)?.int32Value,
                    ownerLstart: raw["owner_lstart"] as? String
                )
            }
        }
        // v1 single-record format.
        if let pid = obj["pid"] as? NSNumber, let lstart = obj["lstart"] as? String {
            return [PidRecord(pid: pid.int32Value, lstart: lstart, ownerPid: nil, ownerLstart: nil)]
        }
        return []
    }

    private func writePidRecords(_ records: [PidRecord]) {
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let objects: [[String: Any]] = records.map { record in
            var object: [String: Any] = ["pid": record.pid, "lstart": record.lstart]
            if let ownerPid = record.ownerPid { object["owner_pid"] = ownerPid }
            if let ownerLstart = record.ownerLstart { object["owner_lstart"] = ownerLstart }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["records": objects]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func isSameLiveProcess(pid: Int32, expectedLstart: String) -> Bool {
        guard kill(pid, 0) == 0,
              !expectedLstart.isEmpty,
              let actual = fetchLstart(pid: pid) else { return false }
        return actual.trimmingCharacters(in: .whitespacesAndNewlines)
            == expectedLstart.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - kill判定（ドライラン可能な形で分離）

    /// 指定PIDをkillすべきかどうかを判定する。実際のkillは行わない（呼び出し側の責務）。
    /// (a)(b)(c)(d) すべてを満たす場合のみ shouldKill = true。
    func evaluateGuard(pid: Int32, expectedLstart: String) -> GuardDecision {
        // 存在確認: kill(pid, 0) はシグナル送信せず存在確認のみ行う。
        guard kill(pid, 0) == 0 else {
            return GuardDecision(shouldKill: false, reason: "プロセスが存在しません(pid=\(pid))")
        }

        guard let comm = fetchComm(pid: pid), comm.lowercased().contains("codex") else {
            return GuardDecision(shouldKill: false, reason: "comm(実行ファイル名)がcodexを含みません")
        }

        guard let command = fetchCommand(pid: pid) else {
            return GuardDecision(shouldKill: false, reason: "commandを取得できませんでした")
        }

        guard command.contains("app-server") else {
            // command全文を載せないこと。`reason`は`privacy: .public`でunified logへ出るため、
            // codex CLIの置き場所（ホーム配下の絶対パス）がsysdiagnoseまで届いてしまう。
            // 実行ファイル名は直前の`comm`検査で既に見ており、全文が足すのはパスだけ。
            return GuardDecision(shouldKill: false, reason: "commandにapp-serverが含まれません")
        }

        if command.contains(Self.codexAppBundleMarker) {
            return GuardDecision(shouldKill: false, reason: "Codex.appバンドルパスを含むためkillしません（GUI本体保護）")
        }

        guard let actualLstart = fetchLstart(pid: pid) else {
            return GuardDecision(shouldKill: false, reason: "lstartを取得できませんでした")
        }

        let expectedTrimmed = expectedLstart.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualTrimmed = actualLstart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedTrimmed.isEmpty, expectedTrimmed == actualTrimmed else {
            return GuardDecision(
                shouldKill: false,
                reason: "起動時刻(lstart)が一致しません（PID再利用の可能性）。記録=\(expectedTrimmed) 実際=\(actualTrimmed)"
            )
        }

        return GuardDecision(
            shouldKill: true,
            reason: "codexプロセス・app-server・Codex.app配下でない・lstart一致（すべて確認済み）"
        )
    }

    // MARK: - ps呼び出しヘルパ

    private func runPs(_ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let s = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    private func fetchComm(pid: Int32) -> String? {
        runPs(["-p", String(pid), "-o", "comm="])
    }

    private func fetchCommand(pid: Int32) -> String? {
        runPs(["-p", String(pid), "-o", "command="])
    }

    private func fetchLstart(pid: Int32) -> String? {
        runPs(["-p", String(pid), "-o", "lstart="])
    }
}
