import Foundation
import os
import CoreFoundation

enum CodexClientError: Error, LocalizedError {
    case processNotRunning
    case timeout
    case rpcError(code: Int, kind: CodexRPCFailureKind)
    case invalidResponse
    case processExited(status: Int32)
    case processLaunchFailed
    case codexNotFound
    /// thread/start が一時スレッドであることを応答側から確認できなかった。
    /// 未確認のthreadへはユーザー本文を送らない（fail closed）。
    case ephemeralNotConfirmed

    var errorDescription: String? {
        switch self {
        case .processNotRunning: return "codex app-serverプロセスが起動していません"
        case .timeout: return "codex app-serverからの応答がタイムアウトしました"
        case .rpcError(let code, let kind):
            return kind == .other ? "codex app-serverエラー (\(code))" : kind.userMessage
        case .invalidResponse: return "codex app-serverから不正な応答を受け取りました"
        case .processExited(let status):
            return "codex app-serverプロセスが終了しました (status=\(status))"
        case .processLaunchFailed:
            return "codex app-serverプロセスを起動できません"
        case .codexNotFound:
            return "codex CLIが見つかりません。設定でパスを指定してください"
        case .ephemeralNotConfirmed:
            return "プライベートなAI処理を確認できませんでした"
        }
    }
}

/// 一時thread開始の要求・応答に関する純粋な安全境界。
/// App Serverが一時実行を確認できない限り、thread IDを返さない。
enum EphemeralThreadStartPolicy {
    enum Decision: Equatable {
        case startTurn(threadID: String)
        case ephemeralNotConfirmed
    }

    static func parameters(from parameters: [String: Any]) -> [String: Any] {
        var result = parameters
        result["ephemeral"] = true
        return result
    }

    static func decision(from response: [String: Any]) -> Decision {
        guard let thread = response["thread"] as? [String: Any],
              let rawID = thread["id"] as? String else {
            return .ephemeralNotConfirmed
        }
        let threadID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty,
              let ephemeral = strictBoolean(thread["ephemeral"]),
              ephemeral else {
            return .ephemeralNotConfirmed
        }
        return .startTurn(threadID: threadID)
    }

    /// JSONの数値1/0をBoolとして誤受理しない。JSONのtrue/falseだけを許可する。
    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let value,
              let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }
}

private let logger = Logger(subsystem: "com.koedex.app", category: "CodexAppServerClient")

enum AppServerWebSearchMode: String {
    case disabled
    case live
}

/// 通知購読トークン。unsubscribeに使う。
struct NotificationSubscription {
    let id: UUID
}

/// JSON-RPC応答待ちのtimeout taskを所有し、応答・timeout・停止のいずれでも一度だけ解放する。
struct PendingTimeoutTaskRegistry {
    private var tasks: [Int: Task<Void, Never>] = [:]

    var count: Int { tasks.count }

    mutating func install(_ task: Task<Void, Never>, for id: Int) {
        tasks.removeValue(forKey: id)?.cancel()
        tasks[id] = task
    }

    @discardableResult
    mutating func remove(for id: Int, cancelling: Bool) -> Bool {
        guard let task = tasks.removeValue(forKey: id) else { return false }
        if cancelling {
            task.cancel()
        }
        return true
    }

    @discardableResult
    mutating func cancelAll() -> Int {
        let activeTasks = tasks
        tasks.removeAll()
        for task in activeTasks.values {
            task.cancel()
        }
        return activeTasks.count
    }
}

/// codex app-server 子プロセスとのJSONL JSON-RPC通信を担うクライアント。
/// プロトコル形状は codex app-server の実応答を実測して合わせたものであり、
/// 公開仕様にもとづくものではない。codex 側の更新で崩れうる。
actor CodexAppServerClient {
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingTimeoutTasks = PendingTimeoutTaskRegistry()
    /// 通知購読者。購読トークンID -> (対象method群, AsyncStream continuation)
    private var subscribers: [UUID: (methods: Set<String>, continuation: AsyncStream<CodexNotification>.Continuation)] = [:]
    private var lineBuffer = Data()
    private(set) var isRunning = false
    private var recordedPid: Int32?

    /// プロセス異常終了時に呼ばれる（呼び出し側で再起動判断に使う）。
    var onProcessExit: (@Sendable (Int32) -> Void)?

    /// 設定値（未解決時はnilまたは空文字）。実際に使う絶対パスはstart()内でCodexPathResolverが解決する。
    private let settingsExecutablePath: String?
    private let modelSettings: CodexModelSettings
    private let webSearchMode: AppServerWebSearchMode
    private let nativeToolsEnabled: Bool

    init(
        executablePath: String? = nil,
        modelSettings: CodexModelSettings = .default,
        webSearchMode: AppServerWebSearchMode = .disabled,
        nativeToolsEnabled: Bool = true
    ) {
        self.settingsExecutablePath = executablePath
        self.modelSettings = modelSettings
        self.webSearchMode = webSearchMode
        self.nativeToolsEnabled = nativeToolsEnabled
    }

    /// GUI起動（Finder/Dock/`open`経由）のPATHは "/usr/bin:/bin:/usr/sbin:/sbin" 程度しかない。
    /// codex CLI本体は `#!/usr/bin/env node` shebangのNodeスクリプトのため、PATH上にnodeが
    /// 無いと起動の時点でexit 127で即死する。CodexPathResolverはcodexスクリプト自体の場所しか
    /// 解決しないため、ここで既知のNode配置場所をPATHへ前置して子プロセスに渡す。
    /// ProcessInfoの環境を土台にするので、HOME等（~/.codex解決に必須）はそのまま継承される。
    static func buildChildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        // 候補ディレクトリはCodexPathResolverと共有する（CodexBinaryLocations）。
        // 実在するディレクトリのみ採用し、既存PATH＋基本パスと重複排除して連結する。
        let basePaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var merged: [String] = []
        for path in CodexBinaryLocations.toolDirectories() + existing + basePaths {
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            merged.append(path)
        }
        env["PATH"] = merged.joined(separator: ":")
        return env
    }

    static func appServerArguments(
        modelSettings: CodexModelSettings,
        webSearchMode: AppServerWebSearchMode = .disabled,
        nativeToolsEnabled: Bool = true
    ) -> [String] {
        var arguments = [
            "app-server",
            "-c", "mcp_servers={}",
            "-c", "plugins={}",
            "-c", configAssignment(key: "web_search", value: webSearchMode.rawValue),
        ]
        if !nativeToolsEnabled {
            // M5は任意文書を入力に含むため、Web以外のツール系featureを明示的に全て除外する。
            // Codex更新で名前が無効になった場合は起動失敗へ倒し、権限が広がった状態では続行しない。
            for feature in restrictedNativeFeatures {
                arguments += ["--disable", feature]
            }
        }
        guard modelSettings.mode != .cli else { return arguments }

        let modelSlug = modelSettings.selectedModelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = modelSettings.selectedReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelSlug.isEmpty, !effort.isEmpty else { return arguments }

        arguments.append(contentsOf: ["-c", configAssignment(key: "model", value: modelSlug)])
        arguments.append(contentsOf: ["-c", configAssignment(key: "model_reasoning_effort", value: effort)])
        return arguments
    }

    static let restrictedNativeFeatures = [
        "apps",
        "browser_use",
        "browser_use_external",
        "browser_use_full_cdp_access",
        "computer_use",
        "goals",
        "hooks",
        "image_generation",
        "in_app_browser",
        "memories",
        "multi_agent",
        "plugins",
        "remote_plugin",
        "shell_snapshot",
        "shell_tool",
        "skill_mcp_dependency_install",
        "tool_call_mcp_elicitation",
        "tool_suggest",
        "unified_exec",
        "workspace_dependencies",
    ]

    private static func configAssignment(key: String, value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key)=\"\(escaped)\""
    }

    /// codex app-server を起動し、initialize/initializedハンドシェイクまで完了させる。
    /// GUIアプリはシェルPATHを継承しないため、`/usr/bin/env codex`はexit 127で即死する。
    /// そのためCodexPathResolverで絶対パスを解決してから直接起動する。解決できなければ
    /// プロセスを一切起動せず`codexNotFound`をthrowする。
    func start(timeoutSeconds: Double = 20) async throws {
        guard process == nil else { return }
        let startupDeadline = Date().addingTimeInterval(timeoutSeconds)

        guard let resolvedPath = CodexPathResolver.resolve(settingsPath: settingsExecutablePath) else {
            throw CodexClientError.codexNotFound
        }

        // M0e推奨構成: `-c mcp_servers={} -c plugins={}` でコンテキストを削減する。
        // モデル指定はKoedex設定がCLI追従でない場合だけ追加する。
        let appServerArgs = Self.appServerArguments(
            modelSettings: modelSettings,
            webSearchMode: webSearchMode,
            nativeToolsEnabled: nativeToolsEnabled
        )

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedPath)
        proc.arguments = appServerArgs
        proc.environment = Self.buildChildEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // app-serverのstderrは認証URL等を含み得るため、読取・保存・表示しない。
        proc.standardError = FileHandle.nullDevice

        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { await self?.handleTermination(status: p.terminationStatus) }
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting

        do {
            try proc.run()
            try await recordPidFile(pid: proc.processIdentifier)
            isRunning = true
        } catch {
            if proc.isRunning {
                proc.terminate()
            }
            readabilityCleanup()
            process = nil
            stdinHandle = nil
            isRunning = false
            if let recordedPid { PidFileManager.shared.clearPidFile(pid: recordedPid) }
            recordedPid = nil
            throw CodexClientError.processLaunchFailed
        }

        // 即死を検出して、半開きのapp-server状態を残さない。
        // 300msはprepare時だけで、常駐後のcleanupクリティカルパスには乗らない。
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard proc.isRunning else {
            isRunning = false
            process = nil
            stdinHandle = nil
            if let recordedPid { PidFileManager.shared.clearPidFile(pid: recordedPid) }
            recordedPid = nil
            throw CodexClientError.processExited(status: proc.terminationStatus)
        }

        do {
            let remaining = startupDeadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexClientError.timeout }
            _ = try await sendRequest("initialize", params: [
                "clientInfo": [
                    "name": "Koedex",
                    "title": "Koedex",
                // アプリ版数を名乗る。`scripts/make_app.sh` のCFBundleShortVersionStringと
                // 一緒に上げること。バンドル外実行でもnilにならないよう定数で持つ。
                "version": "0.1.7",
                ],
                "capabilities": [
                    "experimentalApi": false,
                    "requestAttestation": false,
                ],
            ], timeoutSeconds: remaining)
            try sendNotification("initialized", params: nil)
        } catch {
            // initialize失敗時は半開き状態（isRunning=trueのまま等）を残さない。
            // terminationHandler待ちにせず、ここで即座に状態をリセットする。
            if let process, process.isRunning {
                process.terminate()
            }
            readabilityCleanup()
            process = nil
            stdinHandle = nil
            isRunning = false
            if let recordedPid { PidFileManager.shared.clearPidFile(pid: recordedPid) }
            recordedPid = nil
            throw error
        }
    }

    private func recordPidFile(pid: Int32) async throws {
        recordedPid = pid
        PidFileManager.shared.recordAppServerPid(pid)
    }

    func stop() {
        readabilityCleanup()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        isRunning = false
        if let recordedPid { PidFileManager.shared.clearPidFile(pid: recordedPid) }
        recordedPid = nil
        failAllPending(CodexClientError.processNotRunning)
        finishAllSubscribers()
    }

    private func readabilityCleanup() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    private func handleTermination(status: Int32) {
        AppLog.shared.warn("[CodexAppServerClient] app-serverが終了しました(status=\(status))")
        isRunning = false
        readabilityCleanup()
        process = nil
        stdinHandle = nil
        if let recordedPid { PidFileManager.shared.clearPidFile(pid: recordedPid) }
        recordedPid = nil
        failAllPending(CodexClientError.processExited(status: status))
        finishAllSubscribers()
        onProcessExit?(status)
    }

    private func failAllPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        _ = pendingTimeoutTasks.cancelAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }

    private func finishAllSubscribers() {
        let subs = subscribers
        subscribers.removeAll()
        for (_, sub) in subs {
            sub.continuation.finish()
        }
    }

    // MARK: - 通知購読（購読トークン方式）

    struct CodexNotification {
        let method: String
        let params: [String: Any]?
    }

    /// 指定methodsの通知だけを受け取るAsyncStreamを作る。使い終わったら必ずunsubscribe(id:)すること。
    func subscribe(methods: [String]) -> (id: UUID, stream: AsyncStream<CodexNotification>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CodexNotification>.makeStream()
        subscribers[id] = (methods: Set(methods), continuation: continuation)
        return (id, stream)
    }

    func unsubscribe(id: UUID) {
        if let sub = subscribers.removeValue(forKey: id) {
            sub.continuation.finish()
        }
    }

    /// 現在の通知購読者数（購読リーク検証用のデバッグアクセサ）。
    var subscriberCount: Int {
        subscribers.count
    }

    // MARK: - JSON-RPC送受信

    /// Koedexの全AI機能が使う一時thread開始境界。
    /// 応答でephemeral:trueを確認できなければ、呼出元はturn/startへ進めない。
    func startEphemeralThread(params: [String: Any], timeoutSeconds: Double = 20) async throws -> String {
        let response = try await sendRequest(
            "thread/start",
            params: EphemeralThreadStartPolicy.parameters(from: params),
            timeoutSeconds: timeoutSeconds
        )
        switch EphemeralThreadStartPolicy.decision(from: response) {
        case .startTurn(let threadID):
            return threadID
        case .ephemeralNotConfirmed:
            logger.warning("[CodexAppServerClient] ephemeral threadを確認できなかったためturn/startを中止")
            throw CodexClientError.ephemeralNotConfirmed
        }
    }

    @discardableResult
    func sendRequest(_ method: String, params: [String: Any]?, timeoutSeconds: Double = 20) async throws -> [String: Any] {
        guard isRunning, let stdinHandle else { throw CodexClientError.processNotRunning }
        let id = nextId
        nextId += 1

        var obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { obj["params"] = params }
        let line = try serialize(obj)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdinHandle.write(contentsOf: line)
            } catch {
                if pending.removeValue(forKey: id) != nil {
                    continuation.resume(throwing: error)
                }
                return
            }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.timeoutPending(id: id)
            }
            pendingTimeoutTasks.install(timeoutTask, for: id)
        }
    }

    private func timeoutPending(id: Int) {
        // 二重resume防止: removeValueの戻り値がnilでなければまだ未resumeということ。
        // timeout task自身も、continuationが既に解放済みの場合を含めて必ず辞書から外す。
        _ = pendingTimeoutTasks.remove(for: id, cancelling: false)
        if let c = pending.removeValue(forKey: id) {
            c.resume(throwing: CodexClientError.timeout)
        }
    }

    func sendNotification(_ method: String, params: [String: Any]?) throws {
        guard isRunning, let stdinHandle else { throw CodexClientError.processNotRunning }
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { obj["params"] = params }
        let line = try serialize(obj)
        try stdinHandle.write(contentsOf: line)
    }

    /// サーバー→クライアントのリクエスト（承認要求など）に応答する。デフォルトはdeniedで自動応答。
    private func respondToServerRequest(id: Any, result: [String: Any]) {
        guard isRunning, let stdinHandle else { return }
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        obj["id"] = id
        if let line = try? serialize(obj) {
            try? stdinHandle.write(contentsOf: line)
        }
    }

    private func serialize(_ obj: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: obj, options: [])
        var data = json
        data.append(0x0A) // 改行
        return data
    }

    // MARK: - 受信処理

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.debug("[CodexAppServerClient] 不正なJSON行を無視しました")
            return
        }

        // レスポンス（自分が送ったリクエストへの返信）
        if let idNum = obj["id"] as? Int {
            if obj["result"] != nil || obj["error"] != nil {
                _ = pendingTimeoutTasks.remove(for: idNum, cancelling: true)
                if let continuation = pending.removeValue(forKey: idNum) {
                    if let error = obj["error"] as? [String: Any] {
                        let code = error["code"] as? Int ?? -1
                        let kind = CodexErrorClassifier.classify(code: code)
                        continuation.resume(throwing: CodexClientError.rpcError(code: code, kind: kind))
                    } else {
                        continuation.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
                    }
                    return
                }
            }

            // サーバー→クライアントのリクエスト（承認要求等）: 安全側でdeniedを返す
            if let method = obj["method"] as? String {
                let params = obj["params"] as? [String: Any]
                dispatchNotification(method: method, params: params)
                respondToServerRequest(id: obj["id"] ?? idNum, result: ["decision": "denied"])
                return
            }
        }

        // 通知
        if let method = obj["method"] as? String {
            let params = obj["params"] as? [String: Any]
            dispatchNotification(method: method, params: params)
        }
    }

    private func dispatchNotification(method: String, params: [String: Any]?) {
        let notification = CodexNotification(method: method, params: params)
        for (_, sub) in subscribers where sub.methods.contains(method) {
            sub.continuation.yield(notification)
        }
    }
}
