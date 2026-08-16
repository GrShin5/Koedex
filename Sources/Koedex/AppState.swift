import Foundation

/// アプリ全体のパイプライン状態。
enum PipelinePhase: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case cleaning
    case inserting
    case error(String)
}

/// 録音中の音量をどれだけ間引いて公開するか。
///
/// `audioLevel` は `@Published` なので、書き込むたびにHUD全体のSwiftUI再評価が走る。
/// 音声バッファ毎（秒約12回）に無条件で書くと、音声をSpeechAnalyzerへ届ける経路と
/// 同じMainActorをその都度奪う。波形は `WaveformSmoother` が補間するため、
/// 間引いても見た目は変わらない。
enum AudioLevelPublishPolicy {
    static let minimumInterval: TimeInterval = 0.125
    static let minimumChange: Double = 0.05

    static func shouldPublish(
        newLevel: Double,
        lastPublishedLevel: Double?,
        secondsSinceLastPublish: TimeInterval?
    ) -> Bool {
        guard let lastPublishedLevel, let secondsSinceLastPublish else { return true }
        // 発話の立ち上がりを鈍らせないよう、大きな変化は間隔を待たずに通す。
        if abs(newLevel - lastPublishedLevel) >= minimumChange { return true }
        return secondsSinceLastPublish >= minimumInterval
    }
}

/// 停止済み・前回録音のaudio-level TaskがHUDへ戻るのを防ぐ世代判定。
enum AudioLevelSessionPolicy {
    static func accepts(
        phase: PipelinePhase,
        activeSessionID: UUID?,
        incomingSessionID: UUID
    ) -> Bool {
        phase == .recording && activeSessionID == incomingSessionID
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: PipelinePhase = .idle
    @Published var lastTranscript: String = ""
    @Published var lastCleanedText: String = ""
    @Published var lastErrorMessage: String?
    /// 録音開始時刻。自動停止タイマーの経過秒計算、HUDの経過時間表示に使う。
    @Published var recordingStartedAt: Date?
    /// 現在の入力音声レベル（0.0-1.0、対数スケール正規化済み）。録音HUDの波形が購読する。
    @Published var audioLevel: Double = 0

    /// .errorになってから自動的に.idleへ戻すためのタスク。次のsetPhaseで前回分はキャンセルされる。
    private var errorRecoveryTask: Task<Void, Never>?

    private var lastPublishedAudioLevel: Double?
    private var lastAudioLevelPublishedAt: Date?
    /// 音声tapは停止後にも短時間だけlevelを届けることがある。録音ごとの世代を
    /// 明示し、古いTaskが次のHUDや停止済みHUDを再点灯させないようにする。
    private var activeAudioLevelSessionID: UUID?

    /// 録音中の音量を間引いて公開する。`audioLevel` への直接代入の代わりに使う。
    func publishAudioLevel(
        _ level: Double,
        for recordingSessionID: UUID,
        now: Date = Date()
    ) {
        guard AudioLevelSessionPolicy.accepts(
            phase: phase,
            activeSessionID: activeAudioLevelSessionID,
            incomingSessionID: recordingSessionID
        ) else {
            return
        }
        guard AudioLevelPublishPolicy.shouldPublish(
            newLevel: level,
            lastPublishedLevel: lastPublishedAudioLevel,
            secondsSinceLastPublish: lastAudioLevelPublishedAt.map { now.timeIntervalSince($0) }
        ) else {
            return
        }
        lastPublishedAudioLevel = level
        lastAudioLevelPublishedAt = now
        audioLevel = level
    }

    /// 録音開始が確定した時だけ呼ぶ。`AudioRecorder.start`以前の遅延callbackは
    /// この世代と一致しないため自然に破棄される。
    func beginAudioLevelSession(_ recordingSessionID: UUID) {
        activeAudioLevelSessionID = recordingSessionID
        audioLevel = 0
        lastPublishedAudioLevel = nil
        lastAudioLevelPublishedAt = nil
    }

    /// .errorフェーズをHUDに表示する時間（秒）。この後自動的に.idleへ復帰する。
    private let errorDisplaySeconds: UInt64 = 3

    func setPhase(_ phase: PipelinePhase) {
        errorRecoveryTask?.cancel()
        errorRecoveryTask = nil

        let previousPhaseName = Self.telemetryName(for: self.phase)
        let nextPhaseName = Self.telemetryName(for: phase)
        self.phase = phase
        if previousPhaseName != nextPhaseName {
            // error本文や認識本文は含めず、HUD/パイプライン遷移だけを観測する。
            AppLog.shared.info("[Telemetry] pipeline_phase from=\(previousPhaseName) to=\(nextPhaseName)")
        }
        if phase != .recording {
            activeAudioLevelSessionID = nil
            audioLevel = 0
            // 次の録音が最初のバッファで必ず反映されるよう、間引きの履歴も捨てる。
            lastPublishedAudioLevel = nil
            lastAudioLevelPublishedAt = nil
        }
        switch phase {
        case .error(let message):
            self.lastErrorMessage = message
            scheduleAutoRecoveryFromError()
        default:
            self.lastErrorMessage = nil
        }
    }

    private func scheduleAutoRecoveryFromError() {
        errorRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.errorDisplaySeconds ?? 3) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if case .error = self.phase {
                self.setPhase(.idle)
            }
        }
    }

    private static func telemetryName(for phase: PipelinePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .cleaning: return "cleaning"
        case .inserting: return "inserting"
        case .error: return "error"
        }
    }

    func statusText(language: AppLanguage) -> String {
        switch phase {
        case .idle: return AppLocalizer.text("待機中", language: language)
        case .starting: return AppLocalizer.text("録音準備中...", language: language)
        case .recording: return AppLocalizer.text("録音中...", language: language)
        case .transcribing: return AppLocalizer.text("文字起こし中...", language: language)
        case .cleaning: return AppLocalizer.text("AIアシスト中...", language: language)
        case .inserting: return AppLocalizer.text("挿入中...", language: language)
        case .error(let message):
            return AppLocalizer.format(
                "エラー: %@",
                language: language,
                AppLocalizer.textOrLiteral(message, language: language)
            )
        }
    }

    var statusText: String { statusText(language: .japanese) }
}
