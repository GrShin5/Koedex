import Foundation

/// 通常音声入力に重ねるハンズフリー送信モードだけの、開始時固定状態と停止所有権。
/// `VoiceMode` を増やさず、二重停止・partial callbackの競合をこのsessionへ閉じ込める。
@MainActor
final class HandsFreeSendSession {
    enum StopIntent: Equatable {
        case send
        case insertOnly
    }

    enum StopEvidence: Equatable {
        case voiceTrigger
        case stopHotkey
        case autoStop
        case hudFinish
    }

    enum PartialObservation: Equatable {
        case none
        case pending(HandsFreeSendPendingCandidate)
        case ready(HandsFreeSendPartialTriggerCandidate)
    }

    struct HandsFreeSendPendingCandidate: Equatable {
        let candidate: HandsFreeSendPartialTriggerCandidate
        let deadline: Date
    }

    let snapshot: HandsFreeSendSnapshot
    private(set) var recordingStartedAt: Date?
    private(set) var claimedIntent: StopIntent?
    private(set) var claimedEvidence: StopEvidence?
    /// 音声トリガーで停止した時点のpartial。finalが空・不一致だった場合でも、
    /// 自動挿入せずコピー専用の結果ウィンドウへ退避するためだけに保持する。
    private(set) var voiceTriggerFallbackTranscript: String?

    private var partialCandidate: HandsFreeSendPartialTriggerCandidate?
    private var partialCandidateObservedAt: Date?
    private var partialObservationCount = 0
    /// 最初に候補を検出した時刻。fingerprint更新やリセットでは巻き戻らない（計測専用）。
    private(set) var firstCandidateDetectedAt: Date?
    /// 候補が崩れて`.none`へ戻った回数の通算（計測専用）。
    private(set) var candidateCollapseCount = 0
    /// このセッションで観測したvolatile件数（計測専用）。
    private(set) var volatileObservationCount = 0
    private var lastVolatileObservedAt: Date?
    /// volatile到着間隔(ms)。中央値算出はセッション終了時に1回だけ行うため、ここでは追記のみ。
    private var volatileIntervalMillisSamples: [Double] = []
    /// 直前の`observePartial`呼び出しで、候補が初めて検出／fingerprint更新されたか（計測専用、
    /// ログの間引き判定にのみ使う。トリガー判定ロジックには使わない）。
    private(set) var lastObservationWasFreshCandidate = false
    /// 直前の`observePartial`呼び出しで、既存の候補が崩れて`.none`になったか（計測専用）。
    private(set) var lastObservationCollapsed = false
    /// 句読点・空白だけのASR確定では待機をやり直さず、本文・トリガー・トリガー後の
    /// 尾語が変わった時だけ350msの安定窓を戻す。
    private var partialCandidateFingerprint: PartialStabilityFingerprint?
    /// タイマー世代の照合には全文を保持する。fingerprintが同じでも、新しいpartialに
    /// 差し替わった後は古いtimerがそのまま停止claimできないようにする。
    private var partialCandidateTranscript: String?

    /// 録音開始時に一度だけコンパイルする。partialごとの再コンパイルはMainActorを飽和させ、
    /// CGEvent tapのタイムアウトからアプリ全体のホットキー停止に至る（2026-07-30の実機障害）。
    let compiledTriggers: HandsFreeSendTriggerPolicy.CompiledTriggers

    private static let minimumRecordingDuration: TimeInterval = 0.5
    private static let partialStabilityDuration: TimeInterval = 0.35

    init(snapshot: HandsFreeSendSnapshot) {
        self.snapshot = snapshot
        self.compiledTriggers = HandsFreeSendTriggerPolicy.compileTriggers(
            settings: snapshot.settings,
            sttLanguage: snapshot.sttLanguage
        )
    }

    func markRecordingStarted(at date: Date = Date()) {
        recordingStartedAt = date
        resetPartialCandidate()
    }

    /// event tapがOSに無効化されると押下・解放イベントを取りこぼす。その状態のまま
    /// 不可逆な擬似送信まで進めないよう、送信権限だけを落とす（挿入は続行する）。
    private(set) var sendAuthorizationRevoked = false

    func revokeSendAuthorization() {
        sendAuthorizationRevoked = true
    }

    func claimStop(intent: StopIntent, evidence: StopEvidence) -> Bool {
        guard claimedIntent == nil, Self.isValidStopPair(intent: intent, evidence: evidence) else {
            return false
        }
        claimedIntent = intent
        claimedEvidence = evidence
        return true
    }

    func captureVoiceTriggerFallbackTranscript(_ transcript: String) {
        guard claimedIntent == .send,
              claimedEvidence == .voiceTrigger else {
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        voiceTriggerFallbackTranscript = trimmed
    }

    var isVoiceTriggerSend: Bool {
        claimedIntent == .send && claimedEvidence == .voiceTrigger
    }

    func observePartial(
        _ transcript: String,
        isFinal: Bool = false,
        now: Date = Date()
    ) -> PartialObservation {
        // volatile到着の件数・間隔はここで追記だけ行う（計測専用）。整形・ログ出力は
        // セッション終了時のサマリでまとめて1回だけ行い、ホットパスへ載せない。
        if !isFinal {
            volatileObservationCount += 1
            if let lastVolatileObservedAt {
                volatileIntervalMillisSamples.append(now.timeIntervalSince(lastVolatileObservedAt) * 1_000)
            }
            lastVolatileObservedAt = now
        }

        guard claimedIntent == nil,
              let recordingStartedAt,
              now.timeIntervalSince(recordingStartedAt) >= Self.minimumRecordingDuration,
              let candidate = HandsFreeSendTriggerPolicy.partialCandidate(
                  in: transcript,
                  triggers: compiledTriggers
              ) else {
            lastObservationCollapsed = partialCandidate != nil
            lastObservationWasFreshCandidate = false
            if lastObservationCollapsed {
                candidateCollapseCount += 1
            }
            resetPartialCandidate()
            return .none
        }

        let fingerprint = PartialStabilityFingerprint(candidate: candidate, transcript: transcript)
        // 「本文。ストップ送信」→「本文を説明。ストップ送信」や、トリガー後に
        // 「だね」のような尾語が伸びた場合は待機をやり直す。一方、句読点・空白だけの
        // volatile→final確定は同じ安定状態として扱い、候補表示後の不要な遅延を増やさない。
        let isFreshFingerprint = partialCandidateFingerprint != fingerprint
        if isFreshFingerprint {
            partialCandidateObservedAt = now
            partialObservationCount = 0
            if firstCandidateDetectedAt == nil {
                firstCandidateDetectedAt = now
            }
        }
        lastObservationWasFreshCandidate = isFreshFingerprint
        lastObservationCollapsed = false
        partialCandidate = candidate
        partialCandidateFingerprint = fingerprint
        partialCandidateTranscript = transcript
        partialObservationCount += 1

        guard let partialCandidateObservedAt else { return .none }

        // SpeechTranscriberの`isFinal`は録音全体の終端ではなく、ストリーム中の一部
        // 結果にも付く。ここで350msを短絡すると、続く発話の途中で送信され得る。
        _ = isFinal
        let deadline = partialCandidateObservedAt.addingTimeInterval(Self.partialStabilityDuration)
        if now >= deadline {
            return .ready(candidate)
        }
        return .pending(HandsFreeSendPendingCandidate(candidate: candidate, deadline: deadline))
    }

    /// 既に観測済みの候補を、timer起因で再評価する。timer自身を新しい音声partialとして
    /// 数えないため、検出メトリクスや安定判定を歪めずにdeadlineだけ確認できる。
    func reevaluatePendingCandidate(
        _ candidate: HandsFreeSendPartialTriggerCandidate,
        for transcript: String,
        now: Date = Date()
    ) -> PartialObservation {
        guard claimedIntent == nil,
              let recordingStartedAt,
              now.timeIntervalSince(recordingStartedAt) >= Self.minimumRecordingDuration,
              partialCandidate == candidate,
              partialCandidateTranscript == transcript,
              partialCandidateFingerprint == PartialStabilityFingerprint(
                  candidate: candidate,
                  transcript: transcript
              ),
              let recomputed = HandsFreeSendTriggerPolicy.partialCandidate(
                  in: transcript,
                  triggers: compiledTriggers
              ),
              recomputed == candidate,
              let partialCandidateObservedAt else {
            return .none
        }

        let deadline = partialCandidateObservedAt.addingTimeInterval(Self.partialStabilityDuration)
        if now >= deadline {
            return .ready(candidate)
        }
        return .pending(HandsFreeSendPendingCandidate(candidate: candidate, deadline: deadline))
    }

    /// 発火時のログ用。最初の候補検出からの経過秒数と、その間に観測したpartial数。
    func detectionMetrics(now: Date = Date()) -> (elapsedSeconds: Double, observations: Int)? {
        guard let partialCandidateObservedAt else { return nil }
        return (now.timeIntervalSince(partialCandidateObservedAt), partialObservationCount)
    }

    /// セッションで最初に候補を検出してから現在までの経過ms（計測専用）。
    /// `partialCandidateObservedAt`はfingerprintが変わるたびリセットされる別物なので、
    /// この値には使わない。
    func elapsedMillisSinceFirstCandidateDetected(now: Date = Date()) -> Double? {
        guard let firstCandidateDetectedAt else { return nil }
        return now.timeIntervalSince(firstCandidateDetectedAt) * 1_000
    }

    /// volatile到着間隔(ms)の中央値。セッション終了時のサマリ用に、ここでのみソートする（計測専用）。
    func volatileIntervalMedianMillis() -> Double? {
        guard !volatileIntervalMillisSamples.isEmpty else { return nil }
        let sorted = volatileIntervalMillisSamples.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    func isPendingCandidateCurrent(_ candidate: HandsFreeSendPartialTriggerCandidate, for transcript: String) -> Bool {
        guard let current = partialCandidate,
              current == candidate,
              let recomputed = HandsFreeSendTriggerPolicy.partialCandidate(
                  in: transcript,
                  triggers: compiledTriggers
              ),
              recomputed == candidate else {
            return false
        }
        return partialCandidateTranscript == transcript
    }

    private func resetPartialCandidate() {
        partialCandidate = nil
        partialCandidateObservedAt = nil
        partialCandidateFingerprint = nil
        partialCandidateTranscript = nil
        partialObservationCount = 0
    }

    private struct PartialStabilityFingerprint: Equatable {
        let normalizedBody: String
        let normalizedTrigger: String
        let trailingResidual: String

        init(candidate: HandsFreeSendPartialTriggerCandidate, transcript: String) {
            normalizedBody = Self.normalizeBoundary(candidate.body)
            normalizedTrigger = Self.normalizeAll(candidate.matchedTrigger)
            trailingResidual = Self.trailingResidual(
                after: candidate.matchedTrigger,
                in: transcript
            )
        }

        private static let boundaryCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "、,。.!！?？"))

        private static func normalizeBoundary(_ text: String) -> String {
            text.trimmingCharacters(in: boundaryCharacters).lowercased()
        }

        private static func normalizeAll(_ text: String) -> String {
            String(text.filter { !isBoundary($0) }).lowercased()
        }

        private static func trailingResidual(after trigger: String, in transcript: String) -> String {
            guard let range = transcript.range(
                of: trigger,
                options: [.caseInsensitive, .backwards]
            ) else {
                // 一致範囲を逆算できないpartialは安全側へ倒し、全文差分を残余として扱う。
                return normalizeAll(transcript)
            }
            return normalizeAll(String(transcript[range.upperBound...]))
        }

        private static func isBoundary(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { boundaryCharacters.contains($0) }
        }
    }

    private static func isValidStopPair(intent: StopIntent, evidence: StopEvidence) -> Bool {
        switch (intent, evidence) {
        case (.send, .voiceTrigger), (.send, .stopHotkey),
             (.insertOnly, .autoStop), (.insertOnly, .hudFinish):
            return true
        case (.send, .autoStop), (.send, .hudFinish),
             (.insertOnly, .voiceTrigger), (.insertOnly, .stopHotkey):
            return false
        }
    }
}
