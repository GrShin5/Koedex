import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

/// 録音ごとのパイプライン遅延を、音声内容を保持せずに集計する。
/// tap と detached consumer の両方から呼ばれるためロックで保護する。
private final class AudioRecorderDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let correlationID: String
    private let startedAt = Date()
    private var firstSourceAt: Date?
    private var firstConsumerAt: Date?
    private var sourceBufferCount = 0
    private var consumerBufferCount = 0
    private var maximumBacklog = 0

    init(correlationID: String) {
        self.correlationID = correlationID
    }

    func recordSourceBuffer() {
        lock.lock()
        defer { lock.unlock() }
        sourceBufferCount += 1
        firstSourceAt = firstSourceAt ?? Date()
        maximumBacklog = max(maximumBacklog, sourceBufferCount - consumerBufferCount)
    }

    func recordConsumerBuffer() {
        lock.lock()
        defer { lock.unlock() }
        consumerBufferCount += 1
        firstConsumerAt = firstConsumerAt ?? Date()
    }

    func logSummary() {
        lock.lock()
        let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
        let firstSourceMilliseconds = firstSourceAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let firstConsumerMilliseconds = firstConsumerAt.map { $0.timeIntervalSince(startedAt) * 1_000 }
        let sourceBufferCount = sourceBufferCount
        let consumerBufferCount = consumerBufferCount
        let maximumBacklog = maximumBacklog
        lock.unlock()

        AppLog.shared.info(String(
            format: "[AudioRecorderDiagnostics] session=%@ elapsedMs=%.0f firstSourceMs=%@ firstConsumerMs=%@ sourceBuffers=%d consumerBuffers=%d maxBacklog=%d",
            correlationID,
            elapsedMilliseconds,
            firstSourceMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            firstConsumerMilliseconds.map { String(format: "%.0f", $0) } ?? "none",
            sourceBufferCount,
            consumerBufferCount,
            maximumBacklog
        ))
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed(Error)
    case formatConversionUnavailable

    /// **この文字列をログへ出さないこと。**
    /// 内側のエラーの `localizedDescription` を含む。ログには `AppLog.safeDescription(_:)` を使う。
    /// （CIのログ衛生チェックはこの形を検出できない。束縛名が `error` ではないため。）
    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "マイクへのアクセスが許可されていません"
        case .engineStartFailed(let e): return "録音エンジンの起動に失敗しました: \(e.localizedDescription)"
        case .formatConversionUnavailable: return "音声フォーマット変換を初期化できませんでした"
        }
    }
}

/// AVAudioEngineでマイク録音し、取得したバッファをコールバックへ渡す。
/// TranscriptionEngineへのフォーマット変換もここで行う。
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var lastLevelLogAt = Date.distantPast
    private(set) var isRecording = false

    /// 変換済みバッファの受け口。**MainActor上では呼ばれない。**
    /// UI状態に触る場合は受け取り側でMainActorへホップすること。
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// 入力バッファごとのRMSレベル（0.0-1.0）。**MainActor上では呼ばれない。**
    /// UI状態に触る場合は受け取り側でMainActorへホップすること。
    var onLevel: (@Sendable (Double) -> Void)?
    /// tapコールバック（非MainActorコンテキストから呼ばれる）→ AsyncStreamにyield →
    /// 単一の消費Taskが順番にprocess()を呼ぶ、という直列パイプライン。
    /// per-buffer Taskを都度spawnする方式はTask実行順が不定のためバッファ順序が崩れ得るので使わない。
    private var rawBufferQueue: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var rawBufferConsumerTask: Task<Void, Never>?
    private var recordingDiagnostics: AudioRecorderDiagnostics?

    /// マイク権限を確認（未決定なら要求）。
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// 録音開始。targetFormatを指定すると、そのフォーマットへ変換したバッファをonBufferへ渡す。
    func start(
        targetFormat: AVAudioFormat?,
        preferredMicrophoneUID: String = "",
        correlationID: String = "unknown"
    ) async throws {
        guard !isRecording else { return }
        self.targetFormat = targetFormat

        let inputNode = engine.inputNode
        applyPreferredInputDevice(uid: preferredMicrophoneUID, to: inputNode)
        let inputFormat = inputNode.outputFormat(forBus: 0)

        if let targetFormat, !Self.formatsMatch(inputFormat, targetFormat) {
            guard let createdConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw AudioRecorderError.formatConversionUnavailable
            }
            converter = createdConverter
        } else {
            converter = nil
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.rawBufferQueue = continuation
        let diagnostics = AudioRecorderDiagnostics(correlationID: correlationID)
        self.recordingDiagnostics = diagnostics

        // **`self` を捕捉しないこと。** このクラスは `@MainActor` なので、`self` に触れると
        // バッファ1つごと（約85ms毎）にMainActorへホップし、そこでRMS計算（全サンプルの
        // O(n)ループ）とフォーマット変換を同期実行することになる。録音中はHUDの再描画と
        // 同じMainActorを奪い合うため、音声がSpeechAnalyzerへ細くしか流れず、停止した
        // 瞬間にまとめて処理されていた（2026-07-30の実機ログ: 文字起こし確定が録音長の
        // 約0.5倍に比例。同区間でCGEvent tapのタイムアウトも発生）。
        //
        // 必要な状態はすべてローカル定数へ束ねてから捕捉する。`converter` と
        // `targetFormat` はこの時点で確定しており、録音中に変わらない。
        let localConverter = converter
        let localTargetFormat = targetFormat
        let bufferHandler = onBuffer
        let levelHandler = onLevel
        // **`AVAudioConverter` はスレッド安全ではない。** この消費ループは単一の直列
        // コンシューマであり、並列化してはならない。
        self.rawBufferConsumerTask = Task.detached(priority: .userInitiated) {
            var lastLevelLogAt = Date.distantPast
            for await buffer in stream {
                diagnostics.recordConsumerBuffer()
                Self.process(
                    buffer: buffer,
                    inputFormat: inputFormat,
                    converter: localConverter,
                    targetFormat: localTargetFormat,
                    lastLevelLogAt: &lastLevelLogAt,
                    onLevel: levelHandler,
                    onBuffer: bufferHandler
                )
            }
        }

        // installTapのコールバックはCoreAudioの専用スレッドから逐次(シリアル)に呼ばれる。
        // AsyncStream.Continuation.yieldはスレッドセーフなため、Taskでホップせず直接呼ぶことで
        // 到着順を保ったままバッファをストリームへ渡せる（per-buffer Task spawnによる順序不定を回避）。
        // Continuationは値型のためキャプチャしても循環参照にはならず、stop()でのfinish()呼び出しにより
        // tap取り外し後は新規yieldが発生しない。
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            diagnostics.recordSourceBuffer()
            continuation.yield(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            inputNode.removeTap(onBus: 0)
            rawBufferQueue?.finish()
            rawBufferQueue = nil
            // consumerを回収してから捨てる。`stop()` は `isRecording == false` で
            // 即returnするため、ここで待たないと消費中のtaskが次の録音まで残る。
            await rawBufferConsumerTask?.value
            rawBufferConsumerTask = nil
            recordingDiagnostics?.logSummary()
            recordingDiagnostics = nil
            isRecording = false
            throw AudioRecorderError.engineStartFailed(error)
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    /// 消費ループ本体。**MainActor外で走る。** 状態はすべて引数で受け取り、
    /// `self` には触れない。`isRecording` の確認は不要で、`stop()` が stream を
    /// finish させればループ自体が終わる。
    private nonisolated static func process(
        buffer: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        converter: AVAudioConverter?,
        targetFormat: AVAudioFormat?,
        lastLevelLogAt: inout Date,
        onLevel: (@Sendable (Double) -> Void)?,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        if let (level, db) = computeLevel(buffer) {
            let now = Date()
            if now.timeIntervalSince(lastLevelLogAt) >= 1.0 {
                lastLevelLogAt = now
                AppLog.shared.info(String(format: "[AudioLevel] level=%.3f db=%.1f frames=%d", level, db, Int(buffer.frameLength)))
            }
            onLevel?(level)
        }
        guard let converter, let targetFormat else {
            onBuffer?(buffer)
            return
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("[AudioRecorder] フォーマット変換エラー: \(AppLog.safeDescription(error))")
            return
        }
        onBuffer?(outBuffer)
    }

    private nonisolated static func computeLevel(_ buffer: AVAudioPCMBuffer) -> (level: Double, db: Double)? {
        let n = Int(buffer.frameLength)
        guard n > 0, let data = buffer.floatChannelData?[0] else { return nil }
        var sum: Float = 0
        for i in 0..<n {
            sum += data[i] * data[i]
        }
        let rms = sqrt(sum / Float(n))
        let db = 20 * log10(max(rms, 1e-7))
        let level = min(max((Double(db) + 50) / 44, 0), 1)
        return (level, Double(db))
    }

    private func applyPreferredInputDevice(uid: String, to inputNode: AVAudioInputNode) {
        let trimmedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUID.isEmpty else { return }
        guard let device = MicrophoneDeviceManager.device(forUID: trimmedUID) else {
            // 機器のUIDも名前もログへ出さない。Bluetooth機器名は所有者名を含みがちで
            // （「○○のAirPods」）、UIDは固定の機器識別子になる。どちらもログが不具合報告として
            // 外へ出る前提に合わない。選択中のUIDはsettings.jsonにあるので支援時はそちらを見る。
            AppLog.shared.warn("選択マイクが見つからないためシステムデフォルトへフォールバックします")
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            AppLog.shared.warn("inputNode.audioUnitを取得できないためマイク選択をスキップします")
            return
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            // `device.name`は出さない（上のフォールバックと同じ理由）。`status`はOSStatusの
            // 数値で、失敗の切り分けに実際に効くので残す。
            AppLog.shared.warn("選択マイクの適用に失敗したためシステムデフォルトへフォールバックします status=\(status)")
        }
    }

    func stop() async {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        rawBufferQueue?.finish()
        rawBufferQueue = nil
        await rawBufferConsumerTask?.value
        rawBufferConsumerTask = nil
        recordingDiagnostics?.logSummary()
        recordingDiagnostics = nil
        isRecording = false
        converter = nil
        targetFormat = nil
        onLevel?(0)
    }
}
