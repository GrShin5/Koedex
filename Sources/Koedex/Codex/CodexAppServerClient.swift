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

enum CodexRequestCancellationMode: Equatable {
    case legacy
    case cancelWithTask
}

struct CodexAppServerLifecycleTestTransport {
    let write: @Sendable (Data) throws -> Void
    var suspendStart: (@Sendable (CodexAppServerStartTestPoint, UUID) async throws -> Void)?
}

enum CodexAppServerStartTestPoint {
    case afterProcessLaunch
    case afterInitialize
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

/// codex子プロセスへ渡す環境変数を決めるポリシー。`CodexAppServerClient.buildChildEnvironment()`
/// および`prepareChildEnvironment()`の実体はここに集約する。
///
/// 既定は`.observe`: 現行どおり親環境を全継承したまま、allow-listで絞ったら何件
/// 落ちるか（`droppedCount`）だけを計測する（挙動は変えない）。`.enforce`はallow-listだけを
/// 通す将来モードで、実際に落とした件数を`droppedCount`へ返す。`.passthrough`はデバッグ用の
/// 明示オプトアウトで、`KOEDEX_CODEX_ENV_PASSTHROUGH=1`を親環境に立てた場合だけ有効になり、
/// allow-list判定そのものを行わず全継承する（`droppedCount`は常に0）。
enum CodexChildEnvironmentPolicy {
    enum Mode: Equatable {
        case observe
        case enforce
        case passthrough
    }

    struct Prepared {
        let environment: [String: String]
        let mode: Mode
        let keptNames: [String]
        let droppedCount: Int
    }

    /// この環境変数の値が"1"なら`.passthrough`（全継承）を強制する。
    static let passthroughFlagName = "KOEDEX_CODEX_ENV_PASSTHROUGH"

    /// 現行の全継承挙動を変えないための既定値。
    static let defaultMode: Mode = .observe

    /// 子プロセスへそのまま渡してよい環境変数名のallow-list（`.enforce`モード用）。
    /// 資格情報・トークン類（OPENAI_API_KEY、GITHUB_TOKEN等）は意図的に含めない。
    ///
    /// 注意: `SHELL`は意図的に含めない。`SHELL`は親プロセス側の
    /// `CodexPathResolver.swift:69`（ログインシェル解決）が読むためのものであり、
    /// 子プロセス（codex CLI）は使わない。
    private static let allowedNames: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "TERM", "TZ", "__CF_USER_TEXT_ENCODING",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
        "CODEX_HOME", "CODEX_CA_CERTIFICATE",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
        "RUST_LOG", "RUST_BACKTRACE",
        "NVM_DIR", "VOLTA_HOME", "FNM_DIR", "ASDF_DIR", "ASDF_DATA_DIR", "PNPM_HOME", "BUN_INSTALL", "NPM_CONFIG_PREFIX",
    ]

    private static func isAllowed(_ name: String) -> Bool {
        allowedNames.contains(name) || name.hasPrefix("LC_")
    }

    static func mode(passthroughFlag: String?) -> Mode {
        passthroughFlag == "1" ? .passthrough : defaultMode
    }

    /// PATHの再構築は現行の`buildChildEnvironment()`実装と挙動を変えていない
    /// （候補ディレクトリ＋既存PATH＋基本パスを順序を保って重複排除し連結する）。
    static func prepare(parent: [String: String], mode: Mode, toolDirectories: [String]) -> Prepared {
        let basePaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existingPath = (parent["PATH"] ?? "").split(separator: ":").map(String.init)
        var seenPath = Set<String>()
        var mergedPath: [String] = []
        for path in toolDirectories + existingPath + basePaths {
            guard !path.isEmpty, seenPath.insert(path).inserted else { continue }
            mergedPath.append(path)
        }
        let rebuiltPath = mergedPath.joined(separator: ":")

        let allowedKeysPresent = parent.keys.filter(isAllowed)

        var environment: [String: String]
        let droppedCount: Int
        switch mode {
        case .enforce:
            environment = [:]
            for key in allowedKeysPresent {
                environment[key] = parent[key]
            }
            // enforceが実際に落とした件数。
            droppedCount = parent.keys.count - allowedKeysPresent.count
        case .observe:
            environment = parent
            // 挙動は変えず全継承のまま、enforceに切り替えたら何件落ちるかだけを計測する。
            droppedCount = parent.keys.count - allowedKeysPresent.count
        case .passthrough:
            environment = parent
            // 明示オプトアウト: allow-list判定自体を行わない完全な迂回のため、常に0件。
            droppedCount = 0
        }
        environment["PATH"] = rebuiltPath

        return Prepared(
            environment: environment,
            mode: mode,
            keptNames: allowedKeysPresent.sorted(),
            droppedCount: droppedCount
        )
    }

    /// バグ報告等へそのまま貼れる要約。allow-listされた名前だけを含み、値や
    /// 落とした変数名は絶対に含めない（勤務先・利用サービスの推測材料になり得るため）。
    static func summary(_ prepared: Prepared) -> String {
        "mode=\(prepared.mode) kept=\(prepared.keptNames.count) dropped=\(prepared.droppedCount) names=[\(prepared.keptNames.joined(separator: ","))]"
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
    private var processSessionID: UUID?

    /// プロセス異常終了時に呼ばれる（呼び出し側で再起動判断に使う）。
    var onProcessExit: (@Sendable (Int32) -> Void)?

    /// 設定値（未解決時はnilまたは空文字）。実際に使う絶対パスはstart()内でCodexPathResolverが解決する。
    private let settingsExecutablePath: String?
    private let modelSettings: CodexModelSettings
    private let webSearchMode: AppServerWebSearchMode
    private let nativeToolsEnabled: Bool
    private let lifecycleTestTransport: CodexAppServerLifecycleTestTransport?

    init(
        executablePath: String? = nil,
        modelSettings: CodexModelSettings = .default,
        webSearchMode: AppServerWebSearchMode = .disabled,
        nativeToolsEnabled: Bool = true,
        lifecycleTestTransport: CodexAppServerLifecycleTestTransport? = nil
    ) {
        self.settingsExecutablePath = executablePath
        self.modelSettings = modelSettings
        self.webSearchMode = webSearchMode
        self.nativeToolsEnabled = nativeToolsEnabled
        self.lifecycleTestTransport = lifecycleTestTransport
    }

    /// GUI起動（Finder/Dock/`open`経由）のPATHは "/usr/bin:/bin:/usr/sbin:/sbin" 程度しかない。
    /// codex CLI本体は `#!/usr/bin/env node` shebangのNodeスクリプトのため、PATH上にnodeが
    /// 無いと起動の時点でexit 127で即死する。CodexPathResolverはcodexスクリプト自体の場所しか
    /// 解決しないため、ここで既知のNode配置場所をPATHへ前置して子プロセスに渡す。
    /// ProcessInfoの環境を土台にするので、HOME等（~/.codex解決に必須）はそのまま継承される。
    ///
    /// 実体は`CodexChildEnvironmentPolicy.prepare`。既定モード（`observe`）はここでの
    /// 全継承という現行挙動を変えず、allow-listで絞った場合に何件落ちるかを計測するだけに
    /// とどめる。summaryも併せて必要な呼び出し元は`prepareChildEnvironment()`を使うこと。
    static func buildChildEnvironment() -> [String: String] {
        prepareChildEnvironment().environment
    }

    /// `buildChildEnvironment()`と同じ環境変数を、適用モードや採否件数のsummary材料込みで返す。
    /// 起動ログへ残す用途はこちらを使う。
    static func prepareChildEnvironment() -> CodexChildEnvironmentPolicy.Prepared {
        let parent = ProcessInfo.processInfo.environment
        let mode = CodexChildEnvironmentPolicy.mode(
            passthroughFlag: parent[CodexChildEnvironmentPolicy.passthroughFlagName]
        )
        return CodexChildEnvironmentPolicy.prepare(
            parent: parent,
            mode: mode,
            toolDirectories: CodexBinaryLocations.toolDirectories()
        )
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
        guard process == nil, !isRunning else { return }
        let sessionID = UUID()
        processSessionID = sessionID
        lineBuffer.removeAll(keepingCapacity: true)
        if let lifecycleTestTransport {
            isRunning = true
            do {
                try await lifecycleTestTransport.suspendStart?(.afterProcessLaunch, sessionID)
                guard ownsSession(sessionID, process: nil) else { throw CancellationError() }
                try await lifecycleTestTransport.suspendStart?(.afterInitialize, sessionID)
                guard ownsSession(sessionID, process: nil) else { throw CancellationError() }
            } catch {
                cleanupStartedProcess(nil, stdoutHandle: nil, sessionID: sessionID)
                throw error
            }
            return
        }
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

        let preparedEnvironment = Self.prepareChildEnvironment()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedPath)
        proc.arguments = appServerArgs
        proc.environment = preparedEnvironment.environment

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
            Task { await self?.consume(data, process: proc, sessionID: sessionID) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { await self?.handleTermination(status: p.terminationStatus, process: p, sessionID: sessionID) }
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting

        do {
            AppLog.shared.info("[CodexAppServerClient] 子プロセス環境 \(CodexChildEnvironmentPolicy.summary(preparedEnvironment))")
            try proc.run()
            recordPidFile(pid: proc.processIdentifier)
            isRunning = true
        } catch {
            cleanupStartedProcess(proc, stdoutHandle: stdoutHandle, sessionID: sessionID)
            throw CodexClientError.processLaunchFailed
        }

        // 即死を検出して、半開きのapp-server状態を残さない。
        // 300msはprepare時だけで、常駐後のcleanupクリティカルパスには乗らない。
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard ownsSession(sessionID, process: proc) else {
            cleanupStartedProcess(proc, stdoutHandle: stdoutHandle, sessionID: sessionID)
            throw CancellationError()
        }
        guard proc.isRunning else {
            cleanupStartedProcess(proc, stdoutHandle: stdoutHandle, sessionID: sessionID)
            throw CodexClientError.processExited(status: proc.terminationStatus)
        }

        do {
            let remaining = startupDeadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexClientError.timeout }
            guard ownsSession(sessionID, process: proc) else { throw CancellationError() }
            _ = try await sendRequest("initialize", params: [
                "clientInfo": [
                    "name": "Koedex",
                    "title": "Koedex",
                // アプリ版数を名乗る。`scripts/make_app.sh` のCFBundleShortVersionStringと
                // 一緒に上げること。バンドル外実行でもnilにならないよう定数で持つ。
                "version": "0.1.10",
                ],
                "capabilities": [
                    "experimentalApi": false,
                    "requestAttestation": false,
                ],
            ], timeoutSeconds: remaining)
            guard ownsSession(sessionID, process: proc) else { throw CancellationError() }
            try sendNotification("initialized", params: nil)
        } catch {
            // initialize失敗時は半開き状態（isRunning=trueのまま等）を残さない。
            // terminationHandler待ちにせず、ここで即座に状態をリセットする。
            cleanupStartedProcess(proc, stdoutHandle: stdoutHandle, sessionID: sessionID)
            throw error
        }
    }

    private func ownsSession(_ sessionID: UUID, process expectedProcess: Process?) -> Bool {
        guard processSessionID == sessionID else { return false }
        if let expectedProcess { return process === expectedProcess }
        return lifecycleTestTransport != nil
    }

    private func cleanupStartedProcess(
        _ startedProcess: Process?,
        stdoutHandle: FileHandle?,
        sessionID: UUID
    ) {
        stdoutHandle?.readabilityHandler = nil
        if let startedProcess, startedProcess.isRunning { startedProcess.terminate() }
        let startedPID = startedProcess?.processIdentifier
        if let startedPID, startedPID > 0 { PidFileManager.shared.clearPidFile(pid: startedPID) }
        guard ownsSession(sessionID, process: startedProcess) else { return }
        process = nil
        stdinHandle = nil
        isRunning = false
        processSessionID = nil
        lineBuffer.removeAll(keepingCapacity: true)
        if recordedPid == startedPID { recordedPid = nil }
    }

    private func recordPidFile(pid: Int32) {
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
        processSessionID = nil
        lineBuffer.removeAll(keepingCapacity: true)
        if let recordedPid { PidFileManager.shared.clearPidFile(pid: recordedPid) }
        recordedPid = nil
        failAllPending(CodexClientError.processNotRunning)
        finishAllSubscribers()
    }

    private func readabilityCleanup() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    private func handleTermination(status: Int32, process expectedProcess: Process?, sessionID: UUID) {
        guard processSessionID == sessionID else { return }
        if let expectedProcess {
            guard process === expectedProcess else { return }
        } else {
            guard lifecycleTestTransport != nil else { return }
        }
        AppLog.shared.warn("[CodexAppServerClient] app-serverが終了しました(status=\(status))")
        isRunning = false
        readabilityCleanup()
        process = nil
        stdinHandle = nil
        processSessionID = nil
        lineBuffer.removeAll(keepingCapacity: true)
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
    func sendRequest(
        _ method: String,
        params: [String: Any]?,
        timeoutSeconds: Double = 20,
        cancellationMode: CodexRequestCancellationMode = .legacy
    ) async throws -> [String: Any] {
        guard isRunning, stdinHandle != nil || lifecycleTestTransport != nil else {
            throw CodexClientError.processNotRunning
        }
        if cancellationMode == .cancelWithTask {
            try Task.checkCancellation()
        }
        let id = nextId
        nextId += 1

        var obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { obj["params"] = params }
        let line = try serialize(obj)

        let operation: () async throws -> [String: Any] = {
            try await withCheckedThrowingContinuation { continuation in
                self.pending[id] = continuation
                if cancellationMode == .cancelWithTask, Task.isCancelled {
                    self.pending.removeValue(forKey: id)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try self.writeLine(line)
                } catch {
                    if self.pending.removeValue(forKey: id) != nil {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self.timeoutPending(id: id)
                }
                self.pendingTimeoutTasks.install(timeoutTask, for: id)
            }
        }
        guard cancellationMode == .cancelWithTask else { return try await operation() }
        return try await withTaskCancellationHandler(
            operation: operation,
            onCancel: { [weak self] in
                Task { await self?.cancelPending(id: id) }
            }
        )
    }

    private func cancelPending(id: Int) {
        _ = pendingTimeoutTasks.remove(for: id, cancelling: true)
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
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
        guard isRunning, stdinHandle != nil || lifecycleTestTransport != nil else {
            throw CodexClientError.processNotRunning
        }
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { obj["params"] = params }
        let line = try serialize(obj)
        try writeLine(line)
    }

    /// サーバー→クライアントのリクエスト（承認要求など）に応答する。デフォルトはdeniedで自動応答。
    private func respondToServerRequest(id: Any, result: [String: Any]) {
        guard isRunning, stdinHandle != nil || lifecycleTestTransport != nil else { return }
        var obj: [String: Any] = ["jsonrpc": "2.0", "result": result]
        obj["id"] = id
        if let line = try? serialize(obj) {
            try? writeLine(line)
        }
    }

    private func writeLine(_ line: Data) throws {
        if let lifecycleTestTransport {
            try lifecycleTestTransport.write(line)
        } else if let stdinHandle {
            try stdinHandle.write(contentsOf: line)
        } else {
            throw CodexClientError.processNotRunning
        }
    }

    private func serialize(_ obj: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: obj, options: [])
        var data = json
        data.append(0x0A) // 改行
        return data
    }

    // MARK: - 受信処理

    private func consume(_ data: Data, process expectedProcess: Process?, sessionID: UUID) {
        guard processSessionID == sessionID else { return }
        if let expectedProcess {
            guard process === expectedProcess else { return }
        } else {
            guard lifecycleTestTransport != nil else { return }
        }
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    var debugPendingRequestCount: Int { pending.count }
    var debugProcessSessionID: UUID? { processSessionID }

    func debugConsume(_ data: Data, sessionID: UUID) {
        consume(data, process: nil, sessionID: sessionID)
    }

    func debugSimulateTermination(status: Int32, sessionID: UUID) {
        handleTermination(status: status, process: nil, sessionID: sessionID)
    }

    func debugInvokeProcessExitCallback(status: Int32) {
        onProcessExit?(status)
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
