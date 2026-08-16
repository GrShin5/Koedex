import Foundation
import Combine

/// オンボーディングの任意練習用。結果はUI上だけに保持し、履歴・辞書・Codexには渡さない。
@MainActor
final class OnboardingPracticeController: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var resultText = ""
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var recordingStartedAt: Date?

    private let recorder = AudioRecorder()
    private let transcriptionEngine: TranscriptionEngine
    private var liveSessionID: UUID?
    private var pendingStartSessionID: UUID?
    private var activeStreamingSessionID: UUID?
    private var stoppingStreamingSessionID: UUID?
    private var isCleaningUp = false

    init(transcriptionEngine: TranscriptionEngine) {
        self.transcriptionEngine = transcriptionEngine
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func startLivePractice(preferredMicrophoneUID: String, language: AppLanguage) {
        guard !isRecording,
              liveSessionID == nil,
              pendingStartSessionID == nil,
              !isCleaningUp else { return }
        let sessionID = UUID()
        liveSessionID = sessionID
        pendingStartSessionID = sessionID
        state = .preparing
        resultText = ""
        audioLevel = 0
        recordingStartedAt = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pendingStartSessionID == sessionID {
                    self.pendingStartSessionID = nil
                    self.finishCleanupIfNeeded()
                }
            }
            do {
                // 通常録音と同じ保存済みSTT言語を使う。asset取得が失敗した場合は
                // 既存のengine設定へ戻したまま、練習を開始しない。
                try await self.transcriptionEngine.reconfigure(to: language)
                guard self.liveSessionID == sessionID else { return }
                let targetFormat = try await self.transcriptionEngine.startStreaming()
                self.activeStreamingSessionID = sessionID
                guard self.liveSessionID == sessionID else {
                    _ = await self.stopStreaming(for: sessionID)
                    return
                }
                // 通常録音と同じく、AudioRecorderの消費ループはMainActor外で走る。
                // バッファはその録音のcontinuationへ束縛済みの受け口で直接渡し、
                // UI状態を書く音量だけMainActorへ戻す。
                self.recorder.onBuffer = self.transcriptionEngine.makeAudioSink()
                self.recorder.onLevel = { [weak self] level in
                    Task { @MainActor [weak self] in
                        self?.audioLevel = level
                    }
                }
                try await self.recorder.start(
                    targetFormat: targetFormat,
                    preferredMicrophoneUID: preferredMicrophoneUID
                )
                guard self.liveSessionID == sessionID else {
                    await self.recorder.stop()
                    _ = await self.stopStreaming(for: sessionID)
                    return
                }
                self.recordingStartedAt = Date()
                self.state = .recording
            } catch {
                guard self.liveSessionID == sessionID else {
                    _ = await self.stopStreaming(for: sessionID)
                    return
                }
                self.liveSessionID = nil
                self.isCleaningUp = true
                _ = await self.stopStreaming(for: sessionID)
                self.audioLevel = 0
                self.recordingStartedAt = nil
                self.state = .failed(error.localizedDescription)
                self.finishCleanupIfNeeded()
            }
        }
    }

    func stopLivePractice() {
        guard (isRecording || state == .preparing), let sessionID = liveSessionID else { return }
        liveSessionID = nil
        isCleaningUp = true
        Task { [weak self] in
            guard let self else { return }
            await self.recorder.stop()
            let result = await self.stopStreaming(for: sessionID) ?? ""
            guard self.liveSessionID == nil else { return }
            self.audioLevel = 0
            self.recordingStartedAt = nil
            self.resultText = result.trimmingCharacters(in: .whitespacesAndNewlines)
            self.state = .finished
            self.finishCleanupIfNeeded()
        }
    }

    func showPreviewExample(language: AppLanguage) {
        resultText = language == .japanese
            ? "これはセットアップ画面のプレビューです。"
            : "This is a preview of the setup screen."
        audioLevel = 0
        recordingStartedAt = nil
        state = .finished
    }

    func reset() {
        Task { [weak self] in
            await self?.resetAndWait()
        }
    }

    /// ウィンドウを閉じる通常経路は非同期でよいが、再起動だけは旧プロセスの
    /// 録音を確実に停止してから後継プロセスを起動するため、この完了をawaitする。
    func resetAndWait() async {
        let sessionID = liveSessionID ?? activeStreamingSessionID ?? pendingStartSessionID
        liveSessionID = nil
        isCleaningUp = sessionID != nil || stoppingStreamingSessionID != nil
        await recorder.stop()
        if let sessionID {
            _ = await stopStreaming(for: sessionID)
        }
        finishCleanupIfNeeded()
        resultText = ""
        audioLevel = 0
        recordingStartedAt = nil
        state = .idle
    }

    private func stopStreaming(for sessionID: UUID) async -> String? {
        guard activeStreamingSessionID == sessionID else { return nil }
        activeStreamingSessionID = nil
        stoppingStreamingSessionID = sessionID
        let result = await transcriptionEngine.stopStreaming()
        if stoppingStreamingSessionID == sessionID {
            stoppingStreamingSessionID = nil
        }
        finishCleanupIfNeeded()
        return result
    }

    private func finishCleanupIfNeeded() {
        guard isCleaningUp,
              pendingStartSessionID == nil,
              activeStreamingSessionID == nil,
              stoppingStreamingSessionID == nil else { return }
        isCleaningUp = false
    }
}
