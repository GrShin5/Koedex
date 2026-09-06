import Foundation
@preconcurrency import Speech
import AVFoundation

/// 文字起こしストリームの処理時刻だけを集計する。音声・認識本文は保持しない。
/// AudioRecorderのdetached callbackからも呼ばれるためロックで保護する。
private final class TranscriptionStreamDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let correlationID: String
    private let startedAt = Date()
    private var firstSourceBufferAt: Date?
    private var firstConsumerBufferAt: Date?
    private var firstPartialAt: Date?
    private var finalResultAt: Date?
    private var sourceBufferCount = 0
    private var consumerBufferCount = 0
    private var maximumBacklog = 0

    // ここから下は「音声は届いたのに文字起こしが丸ごと空になる」短い発話の切り分け用。
    // 結果が来た時だけ記録する既存フィールドでは、`analyzer.start`が失敗したのか、
    // 結果ストリームが即終了したのか、モデルが何も返さなかったのかを区別できない。
    private var analyzerStartEnteredAt: Date?
    private var analyzerStartOutcome = "pending"
    private var resultsIterationStartedAt: Date?
    private var resultsStreamOutcome = "pending"
    private var partialResultCount = 0
    private var finalResultCount = 0
    /// stream ID照合で受理されなかった結果の件数。エンジンは返しているのにこちらが
    /// 捨てている場合、症状は「文字起こしが空」と完全に同じに見える。
    private var rejectedResultCount = 0
    private var streamSource = "unknown"

    init(correlationID: String) {
        self.correlationID = correlationID
    }
    private var finishTimedOut = false

    /// 例外は**型名だけ**を残す。`localizedDescription`はパスやユーザー文言を含みうるため、
    /// 公開ミラーへ流れるログに載せない。
    private static func outcomeLabel(for error: Error?) -> String {
        guard let error else { return "ok" }
        return "failed:\(String(describing: type(of: error)))"
    }

    func recordStreamSource(_ source: String) {
        lock.lock()
        streamSource = source
        lock.unlock()
    }

    func recordAnalyzerStartEntered() {
        lock.lock()
        analyzerStartEnteredAt = analyzerStartEnteredAt ?? Date()
        lock.unlock()
    }

    func recordAnalyzerStartFinished(error: Error?) {
        lock.lock()
        analyzerStartOutcome = Self.outcomeLabel(for: error)
        lock.unlock()
    }

    func recordResultsIterationStarted() {
        lock.lock()
        resultsIterationStartedAt = resultsIterationStartedAt ?? Date()
        lock.unlock()
    }

    func recordResultsStreamFinished(error: Error?) {
        lock.lock()
        resultsStreamOutcome = error == nil ? "ended" : Self.outcomeLabel(for: error)
        lock.unlock()
    }

    /// 注意: `handleResult`は常に**現行の**diagnosticsを参照するため、新しい録音が始まった後に
    /// 届いた古い結果は新しい方のセッションに計上される。切り分けには十分だが、
    /// 「このセッション自身の結果が捨てられた」ことの証明ではない。
    func recordRejectedResult() {
        lock.lock()
        rejectedResultCount += 1
        lock.unlock()
    }

    func recordSourceBuffer() {
        lock.lock()
        defer { lock.unlock() }
        sourceBufferCount += 1
        firstSourceBufferAt = firstSourceBufferAt ?? Date()
        maximumBacklog = max(maximumBacklog, sourceBufferCount - consumerBufferCount)
    }

    func recordConsumerBuffer() {
        lock.lock()
        defer { lock.unlock() }
        consumerBufferCount += 1
        firstConsumerBufferAt = firstConsumerBufferAt ?? Date()
    }

    func recordResult(isFinal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isFinal {
            finalResultAt = finalResultAt ?? Date()
            finalResultCount += 1
        } else {
            firstPartialAt = firstPartialAt ?? Date()
            partialResultCount += 1
        }
    }

    func recordFinishTimeout() {
        lock.lock()
        finishTimedOut = true
        lock.unlock()
    }

    func logSummary() {
        lock.lock()
        let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
        let firstSourceMilliseconds = firstSourceBufferAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let firstConsumerMilliseconds = firstConsumerBufferAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let firstPartialMilliseconds = firstPartialAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let finalResultMilliseconds = finalResultAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let sourceBufferCount = sourceBufferCount
        let consumerBufferCount = consumerBufferCount
        let maximumBacklog = maximumBacklog
        let finishTimedOut = finishTimedOut
        let analyzerStartMilliseconds = analyzerStartEnteredAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let resultsIterationMilliseconds = resultsIterationStartedAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let analyzerStartOutcome = analyzerStartOutcome
        let resultsStreamOutcome = resultsStreamOutcome
        let partialResultCount = partialResultCount
        let finalResultCount = finalResultCount
        let rejectedResultCount = rejectedResultCount
        let streamSource = streamSource
        lock.unlock()

        // 既存フィールドの並びは変えない。実機ログのgrep手順がそのまま使えるようにするため、
        // 切り分け用の項目は末尾へ足すだけにする。
        AppLog.shared.info(String(
            format: "[TranscriptionStreamDiagnostics] session=%@ elapsedMs=%.0f firstSourceMs=%@ firstConsumerMs=%@ firstPartialMs=%@ firstFinalMs=%@ sourceBuffers=%d consumerBuffers=%d maxBacklog=%d finishTimedOut=%@ source=%@ analyzerStartMs=%@ analyzerStart=%@ resultsIterMs=%@ resultsStream=%@ partials=%d finals=%d rejected=%d",
            correlationID,
            elapsedMilliseconds,
            firstSourceMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            firstConsumerMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            firstPartialMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            finalResultMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            sourceBufferCount,
            consumerBufferCount,
            maximumBacklog,
            finishTimedOut ? "true" : "false",
            streamSource,
            analyzerStartMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            analyzerStartOutcome,
            resultsIterationMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            resultsStreamOutcome,
            partialResultCount,
            finalResultCount,
            rejectedResultCount
        ))
    }
}

enum TranscriptionEngineInternalError: Error {
    case bufferAllocationFailed
    case converterCreationFailed
}

/// エラー型
enum TranscriptionError: Error, LocalizedError {
    case localeNotSupported(String)
    case assetInstallFailed(Error)
    case analyzerStartFailed(Error)
    case notWarmedUp
    case permissionNotGranted
    case languageChangeWhileRecording

    /// 画面へ出す文言は、内側のエラー本文を含めない。
    /// 診断ログが必要な場合は `AppLog.safeDescription(_:)` だけを使う。
    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let id): return "ロケール \(id) はSpeechTranscriberでサポートされていません"
        case .assetInstallFailed: return "音声モデルのインストールに失敗しました"
        case .analyzerStartFailed: return "文字起こしエンジンの開始に失敗しました"
        case .notWarmedUp: return "文字起こしエンジンがまだ初期化されていません"
        case .permissionNotGranted: return "マイクまたは音声認識の権限が許可されていません"
        case .languageChangeWhileRecording: return "録音または文字起こしの処理中は音声認識言語を変更できません"
        }
    }
}

/// SpeechAnalyzer / SpeechTranscriber のウォーム管理＋ストリーミング文字起こし。
///
/// M0b検証結果: 日本語モデル初期化に約7.9秒かかるため、アプリ起動時に一度だけ
/// `warmUp()` を呼びモデルアセットを事前準備しておく。
@MainActor
final class TranscriptionEngine: ObservableObject {
    enum LifecycleTestPoint: Equatable {
        case startAfterPriorStop
        case startAfterFormat
        case startAfterAnalyzerLaunch
        case reconfigureAfterLocale
        case reconfigureAfterAssets
        case reconfigureAfterRuntime
        case fakeResultsStream
    }

    struct LifecycleTestSeam {
        let suspend: @MainActor (LifecycleTestPoint, UUID) async throws -> Void
        let bypassSpeechFramework: Bool
        var finishTimeoutSeconds: TimeInterval = 5
        var didConsumeBuffer: (@Sendable (UUID) -> Void)?
    }

    @Published private(set) var isWarmedUp = false
    @Published private(set) var isWarmingUp = false
    @Published private(set) var partialText = ""

    private var locale: Locale
    /// 1録音の可変状態を1つの所有物へ閉じ込める。古い停止処理がawaitから戻っても、
    /// 次の録音が公開したruntimeへ触れないための境界。
    private final class StreamingRuntime {
        let streamID: UUID
        let diagnostics: TranscriptionStreamDiagnostics
        let partialResultHandler: ((UUID, String, Bool) -> Void)?
        var transcriber: SpeechTranscriber?
        var analyzer: SpeechAnalyzer?
        var resultsTask: Task<Void, Never>?
        var analyzerStartTask: Task<Void, Never>?
        var bufferQueue: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var bufferConsumerTask: Task<Void, Never>?
        var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
        var finalizedSegments: [String] = []
        var partialText = ""
        var acceptsResults = true
        var didTimeOutDuringFinish = false
        var stopTask: Task<String, Never>?

        init(
            streamID: UUID,
            diagnostics: TranscriptionStreamDiagnostics,
            partialResultHandler: ((UUID, String, Bool) -> Void)?,
            transcriber: SpeechTranscriber?,
            analyzer: SpeechAnalyzer?
        ) {
            self.streamID = streamID
            self.diagnostics = diagnostics
            self.partialResultHandler = partialResultHandler
            self.transcriber = transcriber
            self.analyzer = analyzer
        }
    }

    private var activeRuntime: StreamingRuntime?
    private var activeStartLease: (id: UUID, streamID: UUID)?
    private var activeReconfigurationLease: UUID?
    private let lifecycleTestSeam: LifecycleTestSeam?

    /// asset準備後、実録音を開始せずに構築した初回用のSpeech runtime。
    /// `SpeechAnalyzer.start`やAVAudioEngineはここでは呼ばないため、マイク利用表示・
    /// デバイス占有・空音声の推論を発生させない。最初の録音が同一localeならそのまま
    /// takeして使い、起動直後のTranscriber/format/Analyzer構築を前倒しする。
    private struct PreparedRuntime {
        let localeIdentifier: String
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let targetFormat: AVAudioFormat?
    }
    private var preparedRuntime: PreparedRuntime?

    init(localeIdentifier: String = "ja-JP", lifecycleTestSeam: LifecycleTestSeam? = nil) {
        self.locale = Locale(identifier: localeIdentifier)
        self.lifecycleTestSeam = lifecycleTestSeam
    }

    /// `.fastResults` を外すと、日本語モデルは約11.5秒ぶんの音声が溜まるまで
    /// volatile結果を1件も返さない（英語は約3.84秒）。ハンズフリー送信はvolatile結果から
    /// トリガー句を拾うため、この待ちがそのまま検出遅延になる。実測では
    /// 初回volatileが11.7秒→1.1秒、発話終了から検出までが約10.2秒→0.53秒。
    /// 到着間隔も1〜2msの連射から約930msのティックへ変わる（`HandsFreeSendSession`の
    /// 安定窓はこの前提で読むこと）。計測は `--test-stt-partials`。
    private func makeTranscriber(locale: Locale? = nil) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale ?? self.locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// アプリ起動時に一度だけ呼び、モデルアセットの確認・ダウンロードとTranscriber構築を済ませておく。
    /// 冒頭でマイク・音声認識権限を再確認し、未取得ならthrowする
    /// （Speech framework内SIGTRAP仮説への防御。未認可状態でのSpeechAnalyzer初期化を避ける）。
    /// また、SFSpeechRecognizer.requestAuthorizationをもう一度明示的に呼び、TCC登録の保険とする。
    func warmUp() async throws {
        guard !isWarmedUp else { return }
        let startedAt = Date()
        try Task.checkCancellation()

        let resolvedLocale = try await resolveSupportedLocale(for: locale)
        try Task.checkCancellation()
        try await installAssets(for: resolvedLocale)
        try Task.checkCancellation()
        let primeStartedAt = Date()
        let candidateRuntime = await makePreparedRuntime(for: resolvedLocale)
        try Task.checkCancellation()
        guard activeRuntime == nil, activeStartLease == nil else {
            throw TranscriptionError.languageChangeWhileRecording
        }
        locale = resolvedLocale
        preparedRuntime = candidateRuntime
        isWarmedUp = true
        AppLog.shared.info(String(
            format: "[Telemetry] stt_warmup_complete locale=%@ totalMs=%.0f runtimePrimeMs=%.0f prepared=%@",
            locale.identifier(.bcp47),
            Date().timeIntervalSince(startedAt) * 1_000,
            Date().timeIntervalSince(primeStartedAt) * 1_000,
            preparedRuntime == nil ? "false" : "true"
        ))
    }

    /// 指定言語のSpeechTranscriberを、録音していない時だけ事前準備して切り替える。
    /// locale/assetの検証と取得が成功するまで既存のlocaleとwarm-up状態には触れないため、
    /// 失敗しても次の録音は従来どおりの言語で安全に開始できる。
    func reconfigure(to language: AppLanguage) async throws {
        guard !isStreaming, activeStartLease == nil else {
            throw TranscriptionError.languageChangeWhileRecording
        }
        let lease = UUID()
        activeReconfigurationLease = lease
        defer {
            if activeReconfigurationLease == lease {
                activeReconfigurationLease = nil
            }
        }
        try Task.checkCancellation()

        let requestedLocale = Locale(identifier: language.preferredSpeechLocaleIdentifier)
        let resolvedLocale: Locale
        if lifecycleTestSeam?.bypassSpeechFramework == true {
            resolvedLocale = requestedLocale
        } else {
            resolvedLocale = try await resolveSupportedLocale(for: requestedLocale)
        }
        try await checkReconfigurationLease(lease, point: .reconfigureAfterLocale)
        if locale.identifier(.bcp47).caseInsensitiveCompare(resolvedLocale.identifier(.bcp47)) == .orderedSame,
           isWarmedUp {
            return
        }

        if lifecycleTestSeam?.bypassSpeechFramework != true {
            try await installAssets(for: resolvedLocale)
        }
        try await checkReconfigurationLease(lease, point: .reconfigureAfterAssets)
        let primeStartedAt = Date()
        let candidateRuntime: PreparedRuntime?
        if lifecycleTestSeam?.bypassSpeechFramework == true {
            candidateRuntime = nil
        } else {
            candidateRuntime = await makePreparedRuntime(for: resolvedLocale)
        }
        try await checkReconfigurationLease(lease, point: .reconfigureAfterRuntime)
        guard !isStreaming, activeStartLease == nil else {
            throw TranscriptionError.languageChangeWhileRecording
        }
        locale = resolvedLocale
        preparedRuntime = candidateRuntime
        isWarmedUp = true
        AppLog.shared.info(String(
            format: "[Telemetry] stt_language_ready locale=%@ runtimePrimeMs=%.0f prepared=%@",
            locale.identifier(.bcp47),
            Date().timeIntervalSince(primeStartedAt) * 1_000,
            preparedRuntime == nil ? "false" : "true"
        ))
    }

    /// Speech frameworkが返す対応ロケールから、優先BCP-47一致、次に同じ主言語を選ぶ。
    /// これは副作用を持たないため、回帰テストでは`resolvedSupportedLocaleIdentifier`を使う。
    static func resolvedSupportedLocaleIdentifier(
        requestedIdentifier: String,
        supportedIdentifiers: [String]
    ) -> String? {
        if let exact = supportedIdentifiers.first(where: {
            $0.caseInsensitiveCompare(requestedIdentifier) == .orderedSame
        }) {
            return exact
        }

        let requestedLanguage = requestedIdentifier
            .split(separator: "-", maxSplits: 1)
            .first?
            .lowercased()
        guard let requestedLanguage else { return nil }
        return supportedIdentifiers.first {
            $0.split(separator: "-", maxSplits: 1).first?.lowercased() == requestedLanguage
        }
    }

    private var isStreaming: Bool {
        activeRuntime != nil
    }

    private func makePreparedRuntime(for targetLocale: Locale) async -> PreparedRuntime? {
        guard !isStreaming else { return nil }
        let transcriber = makeTranscriber(locale: targetLocale)
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard !isStreaming else { return nil }
        return PreparedRuntime(
            localeIdentifier: targetLocale.identifier(.bcp47),
            transcriber: transcriber,
            analyzer: analyzer,
            targetFormat: targetFormat
        )
    }

    private func checkReconfigurationLease(
        _ lease: UUID,
        point: LifecycleTestPoint
    ) async throws {
        if let lifecycleTestSeam {
            try await lifecycleTestSeam.suspend(point, lease)
        }
        try Task.checkCancellation()
        guard activeReconfigurationLease == lease, !isStreaming, activeStartLease == nil else {
            throw CancellationError()
        }
    }

    private func takePreparedRuntime() -> PreparedRuntime? {
        defer { preparedRuntime = nil }
        guard let preparedRuntime,
              preparedRuntime.localeIdentifier.caseInsensitiveCompare(locale.identifier(.bcp47)) == .orderedSame else {
            return nil
        }
        return preparedRuntime
    }

    private func resolveSupportedLocale(for requestedLocale: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let supportedIdentifiers = supported.map { $0.identifier(.bcp47) }
        guard let resolvedIdentifier = Self.resolvedSupportedLocaleIdentifier(
            requestedIdentifier: requestedLocale.identifier(.bcp47),
            supportedIdentifiers: supportedIdentifiers
        ) else {
            throw TranscriptionError.localeNotSupported(requestedLocale.identifier(.bcp47))
        }
        return Locale(identifier: resolvedIdentifier)
    }

    /// permission確認とasset取得だけを行う。呼び出し側が成功後にlocaleをcommitする。
    private func installAssets(for targetLocale: Locale) async throws {
        try Task.checkCancellation()

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            throw TranscriptionError.permissionNotGranted
        }

        let speechStatus = await requestSpeechAuthorizationIfNeeded()
        guard speechStatus == .authorized else {
            throw TranscriptionError.permissionNotGranted
        }

        isWarmingUp = true
        defer { isWarmingUp = false }

        let probeTranscriber = makeTranscriber(locale: targetLocale)

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probeTranscriber]) {
                try await request.downloadAndInstall()
            }
            try Task.checkCancellation()
        } catch {
            AppLog.shared.warn("[TranscriptionEngine] asset installation failed: \(AppLog.safeDescription(error))")
            throw TranscriptionError.assetInstallFailed(error)
        }
    }

    /// SFSpeechRecognizer.requestAuthorizationをもう一度明示的に呼ぶ。
    /// SpeechAnalyzer/SpeechTranscriber自体は旧APIを使わないが、TCCへの
    /// NSSpeechRecognitionUsageDescription登録・システム設定パネルへの出現のために必要。
    /// 既に決定済み（authorized/denied/restricted）の場合はそのまま返す。
    private func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 録音セッション開始。以後 `appendAudio` でバッファを流し込む。
    /// inputBuilder/bufferQueueはこのメソッドを抜ける時点で既に有効化されており、
    /// analyzer.start(inputSequence:)を呼ぶTaskの起動を待ってからreturnする。
    /// 先頭音声が欠落しない根拠は「Taskの起動を待つこと」自体ではなく、
    /// AsyncStream(unbounded)のバッファリング特性にある。appendAudioは
    /// bufferQueue（AsyncStream）へyieldするだけであり、analyzer.startのfor-await読み出しが
    /// まだ始まっていなくても、そのyieldはストリームのバッファに保持され失われない。
    /// そのため呼び出し順（Task起動前/後どちらでappendAudioが呼ばれても）に関わらず
    /// 欠落は起きない。
    /// 戻り値は、この録音セッションのtranscriberに対応する最適フォーマット。
    func startStreaming(
        streamID: UUID = UUID(),
        onPartialText: ((UUID, String, Bool) -> Void)? = nil
    ) async throws -> AVAudioFormat? {
        guard activeReconfigurationLease == nil else {
            throw TranscriptionError.languageChangeWhileRecording
        }
        let lease = UUID()
        activeStartLease = (lease, streamID)
        defer {
            if activeStartLease?.id == lease {
                activeStartLease = nil
            }
        }

        // Esc直後の再開始などで、前sessionのfinalizeがまだ終わっている場合は
        // 先に確実に回収する。旧taskが新しいinputBuilderを閉じる競合を防ぐ。
        if let currentRuntime = activeRuntime {
            _ = await stopStreaming(streamID: currentRuntime.streamID)
        }
        try await checkStartLease(lease, streamID: streamID, point: .startAfterPriorStop)
        guard isWarmedUp else { throw TranscriptionError.notWarmedUp }
        let streamPreparationStartedAt = Date()
        let diagnostics = TranscriptionStreamDiagnostics(correlationID: streamID.uuidString)

        if lifecycleTestSeam?.bypassSpeechFramework == true {
            try await checkStartLease(lease, streamID: streamID, point: .startAfterFormat)
            let runtime = StreamingRuntime(
                streamID: streamID,
                diagnostics: diagnostics,
                partialResultHandler: onPartialText,
                transcriber: nil,
                analyzer: nil
            )
            installBufferPipeline(on: runtime, inputContinuation: nil)
            if let lifecycleTestSeam {
                runtime.resultsTask = Task { [weak self, weak runtime] in
                    try? await lifecycleTestSeam.suspend(.fakeResultsStream, streamID)
                    guard let self, let runtime else { return }
                    self.acceptTextResult("late-fixture", isFinal: true, runtime: runtime)
                }
            }
            try await checkStartLease(lease, streamID: streamID, point: .startAfterAnalyzerLaunch)
            activeRuntime = runtime
            partialText = ""
            didTimeOutDuringFinishStreaming = false
            return nil
        }

        let prepared = takePreparedRuntime()
        let transcriber = prepared?.transcriber ?? makeTranscriber()
        let targetFormat: AVAudioFormat?
        if let prepared {
            targetFormat = prepared.targetFormat
        } else {
            targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        try await checkStartLease(lease, streamID: streamID, point: .startAfterFormat)

        let analyzer = prepared?.analyzer ?? SpeechAnalyzer(modules: [transcriber])
        let runtime = StreamingRuntime(
            streamID: streamID,
            diagnostics: diagnostics,
            partialResultHandler: onPartialText,
            transcriber: transcriber,
            analyzer: analyzer
        )
        diagnostics.recordStreamSource(prepared == nil ? "cold" : "prepared")
        AppLog.shared.info(String(
            format: "[Telemetry] stt_stream_ready session=%@ source=%@ elapsedMs=%.0f",
            streamID.uuidString,
            prepared == nil ? "cold" : "prepared",
            Date().timeIntervalSince(streamPreparationStartedAt) * 1_000
        ))

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        runtime.inputBuilder = inputContinuation

        // tapコールバック → AsyncStreamにyield → 単一の消費Taskが順番にinputBuilderへappend、
        // という直列パイプライン。Task実行順不定によるバッファ順序崩れを排除する。
        installBufferPipeline(on: runtime, inputContinuation: inputContinuation)
        // **`self` を捕捉しないこと。** このクラスは `@MainActor` なので、`self` に触れると
        // バッファ1つごとにMainActorへホップする。録音中はHUDの再描画やSwiftUIの
        // 再評価と同じMainActorを奪い合い、音声がキューに溜まって停止後にまとめて
        // 処理されていた（2026-07-30の実機ログ: 文字起こし確定が録音長の約0.5倍）。
        // すぐ下の `analyzerStartTask` と同じ「ローカル定数だけを捕捉する」形にそろえる。
        //
        // 束縛した continuation は、この録音が終われば finish 済みになり以後の yield は
        // 無視される。そのため stream ID を照合しなくても古い録音のバッファは混入しない。
        // MainActor据え置きが正しい。`diagnostics`はローカル定数として
        // 捕捉し、次の録音でstreamDiagnosticsが差し替わってもこの録音の集計へ書き続ける。
        runtime.resultsTask = Task { [weak self, weak runtime] in
            guard let runtime else { return }
            guard let self else { return }
            diagnostics.recordResultsIterationStarted()
            do {
                for try await result in transcriber.results {
                    self.handleResult(result, runtime: runtime)
                }
                diagnostics.recordResultsStreamFinished(error: nil)
            } catch {
                diagnostics.recordResultsStreamFinished(error: error)
                AppLog.shared.error("[TranscriptionEngine] 結果ストリーム読み取りエラー: \(AppLog.safeDescription(error))")
            }
        }

        // analyzer.startは入力ストリームの終了まで完了しないAPIのため、直接awaitはできない。
        // そのため投入自体は別Taskで行う。taskLaunchedSignalは「analyzerStartTaskが起動され
        // analyzer.startの呼び出しに入ったこと」のみを保証するものであり、
        // 「先頭バッファが欠落しないこと」の根拠ではない（欠落防止の実際の根拠は上のコメント通り
        // AsyncStreamのバッファリングによるもので、Task起動をここで待つかどうかとは無関係）。
        // ここで待つのはあくまでTask起動の完了を確実にするための同期であり、
        // startStreamingが返った時点でanalyzerStartTaskが必ず非nilであることを保証するため。
        let taskLaunchedSignal = AsyncStream<Void>.makeStream()
        runtime.analyzerStartTask = Task {
            taskLaunchedSignal.continuation.yield(())
            taskLaunchedSignal.continuation.finish()
            // `self`を捕捉しないこと（上の bufferConsumerTask と同じ理由）。`diagnostics` は
            // ローカル定数なのでMainActorホップを増やさない。
            diagnostics.recordAnalyzerStartEntered()
            do {
                try await analyzer.start(inputSequence: inputStream)
                diagnostics.recordAnalyzerStartFinished(error: nil)
            } catch {
                diagnostics.recordAnalyzerStartFinished(error: error)
                AppLog.shared.error("[TranscriptionEngine] analyzer.start失敗: \(AppLog.safeDescription(error))")
            }
        }
        for await _ in taskLaunchedSignal.stream {
            break
        }
        do {
            try await checkStartLease(lease, streamID: streamID, point: .startAfterAnalyzerLaunch)
        } catch {
            runtime.bufferQueue?.finish()
            runtime.inputBuilder?.finish()
            runtime.bufferConsumerTask?.cancel()
            runtime.resultsTask?.cancel()
            runtime.analyzerStartTask?.cancel()
            throw error
        }
        activeRuntime = runtime
        partialText = ""
        didTimeOutDuringFinishStreaming = false
        return targetFormat
    }

    private func checkStartLease(
        _ lease: UUID,
        streamID: UUID,
        point: LifecycleTestPoint
    ) async throws {
        if let lifecycleTestSeam {
            try await lifecycleTestSeam.suspend(point, streamID)
        }
        try Task.checkCancellation()
        guard activeStartLease?.id == lease,
              activeStartLease?.streamID == streamID,
              activeReconfigurationLease == nil else {
            throw CancellationError()
        }
    }

    func cancelPendingStart(streamID: UUID? = nil) {
        guard streamID == nil || activeStartLease?.streamID == streamID else { return }
        activeStartLease = nil
    }

    private func handleResult(_ result: SpeechTranscriber.Result, runtime: StreamingRuntime) {
        acceptTextResult(String(result.text.characters), isFinal: result.isFinal, runtime: runtime)
    }

    private func acceptTextResult(_ text: String, isFinal: Bool, runtime: StreamingRuntime) {
        guard activeRuntime === runtime, runtime.acceptsResults else {
            // 「音声は届いたのに文字起こしが空」の有力候補。ここで捨てていると、症状は
            // モデルが何も返さなかった場合と区別がつかないので件数だけ残す。
            runtime.diagnostics.recordRejectedResult()
            return
        }
        if isFinal {
            runtime.finalizedSegments.append(text)
            runtime.partialText = runtime.finalizedSegments.joined()
        } else {
            runtime.partialText = runtime.finalizedSegments.joined() + text
        }
        partialText = runtime.partialText
        runtime.diagnostics.recordResult(isFinal: isFinal)
        runtime.partialResultHandler?(runtime.streamID, runtime.partialText, isFinal)
    }

    private func installBufferPipeline(
        on runtime: StreamingRuntime,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    ) {
        let diagnostics = runtime.diagnostics
        let streamID = runtime.streamID
        let didConsumeBuffer = lifecycleTestSeam?.didConsumeBuffer
        let (bufferStream, bufferContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        runtime.bufferQueue = bufferContinuation
        runtime.bufferConsumerTask = Task.detached(priority: .userInitiated) {
            for await buffer in bufferStream {
                diagnostics.recordConsumerBuffer()
                inputContinuation?.yield(AnalyzerInput(buffer: buffer))
                didConsumeBuffer?(streamID)
            }
        }
    }

    /// 旧録音のcallbackが次の録音へ混入しないための、stream ID照合。
    static func acceptsCallback(streamID: UUID, activeStreamID: UUID?) -> Bool {
        streamID == activeStreamID
    }

    /// マイクから取得したPCMバッファを1つ流し込む。
    /// バッファのフォーマットは `bestAudioFormat()` に合わせて呼び出し側で変換しておくこと
    /// （Transcriberが期待するフォーマットと不一致だとクラッシュする）。
    /// 直接inputBuilderへappendせず、単一消費Taskが順番に処理するbufferQueueへyieldすることで
    /// 到着順を保証する。
    func appendAudio(_ buffer: AVAudioPCMBuffer, streamID: UUID? = nil) {
        guard let runtime = activeRuntime,
              streamID == nil || streamID == runtime.streamID else { return }
        runtime.diagnostics.recordSourceBuffer()
        runtime.bufferQueue?.yield(buffer)
    }

    /// 録音中のホットパス専用の受け口。**MainActorを経由しない。**
    ///
    /// `appendAudio` は `activeStreamID` を読むため `@MainActor` から出られない。
    /// 録音中はバッファ毎（秒約12回）に呼ばれるので、そこだけこの受け口へ置き換える。
    /// 呼び出し側はMainActor上（配線時）でこれを一度作り、以後はどのスレッドから
    /// 呼んでもよい。
    ///
    /// stream IDの照合を持たないが安全である理由: 返す関数は**その録音の
    /// continuation に束縛される**。録音が終わると continuation は finish 済みになり、
    /// 以後の yield は無視される。古い録音の受け口が残っていても次の録音へは混入しない。
    func makeAudioSink() -> @Sendable (AVAudioPCMBuffer) -> Void {
        let continuation = activeRuntime?.bufferQueue
        let diagnostics = activeRuntime?.diagnostics
        return { buffer in
            diagnostics?.recordSourceBuffer()
            continuation?.yield(buffer)
        }
    }

    /// 音声ファイル全体を読み込み、bestAudioFormatへ変換して一括で文字起こしする（CLIテストモード用）。
    func transcribeFile(url: URL) async throws -> String {
        let sourceFile = try AVAudioFile(forReading: url)
        guard let targetFormat = try await startStreaming() else {
            throw TranscriptionError.notWarmedUp
        }

        let sourceFormat = sourceFile.processingFormat
        let frameCount = AVAudioFrameCount(sourceFile.length)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw TranscriptionError.analyzerStartFailed(TranscriptionEngineInternalError.bufferAllocationFailed)
        }
        try sourceFile.read(into: sourceBuffer)

        let bufferToAppend: AVAudioPCMBuffer
        if sourceFormat == targetFormat {
            bufferToAppend = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw TranscriptionError.analyzerStartFailed(TranscriptionEngineInternalError.converterCreationFailed)
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw TranscriptionError.analyzerStartFailed(TranscriptionEngineInternalError.bufferAllocationFailed)
            }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return sourceBuffer
            }
            if let conversionError {
                throw TranscriptionError.analyzerStartFailed(conversionError)
            }
            bufferToAppend = converted
        }

        appendAudio(bufferToAppend)
        return await stopStreaming()
    }

    /// 録音終了。バッファを閉じ、確定結果が出揃うのを待って全文を返す。
    func stopStreaming(streamID: UUID? = nil) async -> String {
        if streamID == nil || streamID == activeStartLease?.streamID {
            activeStartLease = nil
        }
        guard let runtime = activeRuntime,
              streamID == nil || streamID == runtime.streamID else { return "" }
        if let stopTask = runtime.stopTask {
            return await stopTask.value
        }
        let task = Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return "" }
            return await self.finishStreaming(runtime: runtime)
        }
        runtime.stopTask = task
        let result = await task.value
        runtime.stopTask = nil
        return result
    }

    /// finalizeとドレインの上限。超えたらその時点の確定分で返す。
    private static let finalizeTimeoutSeconds: TimeInterval = 5

    /// 直前のfinishStreamingが打ち切りで終わったか。打ち切った本文は不完全なため、
    /// 呼び出し側は不可逆な擬似送信を行わない判断に使う。
    private(set) var didTimeOutDuringFinishStreaming = false

    /// `operation` が期限内に完了したら true。期限切れなら false を返す。
    /// structured task groupはcancel後も非協調的な子Taskの終了を待つため使わない。
    /// SpeechAnalyzerのfinalizeが取消に応じない場合でも、呼び出し元は期限で先へ進める。
    /// 遅延完了したoperationはstream IDを外した後の状態を書き換えない、ローカルに
    /// 捕捉したanalyzer/taskの回収だけを行う。
    private static func withTimeout(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let signal = AsyncStream<Bool>.makeStream()
        let operationTask = Task {
            await operation()
            signal.continuation.yield(true)
            signal.continuation.finish()
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            signal.continuation.yield(false)
            signal.continuation.finish()
        }
        var iterator = signal.stream.makeAsyncIterator()
        let completedInTime = await iterator.next() ?? false
        operationTask.cancel()
        timeoutTask.cancel()
        return completedInTime
    }

    private func finishStreaming(runtime: StreamingRuntime) async -> String {
        // まずbufferQueueを閉じ、単一消費Taskが溜まっているバッファを全てinputBuilderへ
        // append し終えるのを待つ（順序保証を崩さないため、inputBuilder.finish()は
        // consumerの完了後に呼ぶ）。
        runtime.bufferQueue?.finish()
        runtime.bufferQueue = nil
        await runtime.bufferConsumerTask?.value
        runtime.bufferConsumerTask = nil

        runtime.inputBuilder?.finish()
        runtime.inputBuilder = nil

        if let analyzer = runtime.analyzer {
            let finalized = await Self.withTimeout(Self.finalizeTimeoutSeconds) {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    AppLog.shared.error("[TranscriptionEngine] finalize失敗: \(AppLog.safeDescription(error))")
                }
            }
            if !finalized {
                // ここで無期限に待つと、HUDが固まりESCも実質的な打ち切りにならない
                // （2026-07-30の実機障害では12秒待った）。その時点の確定分で返す。
                runtime.didTimeOutDuringFinish = true
                runtime.diagnostics.recordFinishTimeout()
                AppLog.shared.warn(String(
                    format: "[TranscriptionEngine] finalizeが%.0f秒で完了しないため打ち切ります",
                    Self.finalizeTimeoutSeconds
                ))
            }
        }
        let finishTimeoutSeconds = lifecycleTestSeam?.finishTimeoutSeconds ?? Self.finalizeTimeoutSeconds
        if await !Self.withTimeout(finishTimeoutSeconds, operation: { await runtime.resultsTask?.value }) {
            runtime.didTimeOutDuringFinish = true
            runtime.acceptsResults = false
            runtime.diagnostics.recordFinishTimeout()
            AppLog.shared.warn("[TranscriptionEngine] 結果ストリームのドレインを打ち切ります")
            // 放棄したtaskが後から finalizedSegments を書き換えると、返す本文が
            // 実行タイミング依存になる。IDを外して以後の結果を受理しない。
            runtime.resultsTask?.cancel()
        }
        runtime.resultsTask = nil
        runtime.analyzer = nil
        runtime.transcriber = nil

        // 次回startStreamingとの並走リスクを排除するため、analyzer.startの投入Taskの
        // 終了を待ってからnil化する。
        //
        // ただし無期限に待ってはいけない。`analyzer.start(inputSequence:)` は入力終了と
        // 解析完了まで返らないため、上のfinalizeが固まっている状況ではここも返らず、
        // 打ち切りを入れた意味がなくなる（2026-07-30の実機障害の再現条件そのもの）。
        if await !Self.withTimeout(
            Self.finalizeTimeoutSeconds,
            operation: { await runtime.analyzerStartTask?.value }
        ) {
            runtime.didTimeOutDuringFinish = true
            runtime.diagnostics.recordFinishTimeout()
            AppLog.shared.warn("[TranscriptionEngine] analyzer.startの回収を打ち切ります")
            runtime.analyzerStartTask?.cancel()
        }
        runtime.analyzerStartTask = nil

        let transcript = runtime.finalizedSegments.joined()
        runtime.diagnostics.logSummary()
        if activeRuntime === runtime {
            didTimeOutDuringFinishStreaming = runtime.didTimeOutDuringFinish
            activeRuntime = nil
        }
        return transcript
    }

    var debugActiveStreamID: UUID? { activeRuntime?.streamID }
    var debugLocaleIdentifier: String { locale.identifier(.bcp47) }
    var debugHasActiveReconfigurationLease: Bool { activeReconfigurationLease != nil }
}
