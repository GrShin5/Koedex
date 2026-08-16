import Foundation

enum SpeechLanguagePreparationFailure: Error, Equatable {
    case busy
    case timedOut
    case superseded
    case failed
}

/// STTモデル準備を一箇所で直列管理する。
///
/// リクエストは世代ごとに独立して終端する。古いasset取得が取消に即応しなくても、
/// 120秒の時点で利用者側には必ず結果を返す。`TranscriptionEngine`はasset取得後の
/// cancellationを確認してからlocaleをcommitするため、遅延完了が新しい選択を上書きしない。
@MainActor
final class SpeechLanguagePreparationCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(AppLanguage)
        case failed(AppLanguage, SpeechLanguagePreparationFailure)

        var isPreparing: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    private final class Request {
        let id = UUID()
        let language: AppLanguage
        var operation: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        private var result: Result<Void, SpeechLanguagePreparationFailure>?
        private var continuations: [CheckedContinuation<Result<Void, SpeechLanguagePreparationFailure>, Never>] = []

        init(language: AppLanguage) {
            self.language = language
        }

        func waitForResult() async -> Result<Void, SpeechLanguagePreparationFailure> {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        func resolve(_ result: Result<Void, SpeechLanguagePreparationFailure>) {
            guard self.result == nil else { return }
            self.result = result
            let waiting = continuations
            continuations.removeAll()
            waiting.forEach { $0.resume(returning: result) }
        }

        func cancelWork() {
            operation?.cancel()
            timeout?.cancel()
        }
    }

    @Published private(set) var state: State = .idle

    private let engine: TranscriptionEngine
    private var activeRequest: Request?
    private let timeoutNanoseconds: UInt64

    init(
        engine: TranscriptionEngine,
        timeoutNanoseconds: UInt64 = 120_000_000_000
    ) {
        self.engine = engine
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func prepare(
        to language: AppLanguage,
        isVoiceProcessing: Bool
    ) async -> Result<Void, SpeechLanguagePreparationFailure> {
        guard !isVoiceProcessing else { return .failure(.busy) }

        if let activeRequest, activeRequest.language == language {
            return await activeRequest.waitForResult()
        }

        cancelActiveRequest(as: .superseded)

        let request = Request(language: language)
        activeRequest = request
        state = .preparing(language)

        let requestID = request.id
        request.operation = Task { @MainActor [weak self, engine] in
            do {
                try await engine.reconfigure(to: language)
                self?.finish(requestID: requestID, result: .success(()))
            } catch is CancellationError {
                self?.finish(requestID: requestID, result: .failure(.superseded))
            } catch {
                self?.finish(requestID: requestID, result: .failure(.failed))
            }
        }
        request.timeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0)
            } catch {
                return
            }
            self?.timeOut(requestID: requestID)
        }

        return await request.waitForResult()
    }

    private func timeOut(requestID: UUID) {
        guard let activeRequest, activeRequest.id == requestID else { return }
        // downloadAndInstallが取消を遅延処理しても、呼び出し側はここで必ず再有効化される。
        activeRequest.operation?.cancel()
        finish(requestID: requestID, result: .failure(.timedOut))
    }

    private func finish(
        requestID: UUID,
        result: Result<Void, SpeechLanguagePreparationFailure>
    ) {
        guard let activeRequest, activeRequest.id == requestID else {
            // 取消済み世代の遅延完了。保存値・表示状態には反映しない。
            return
        }

        activeRequest.timeout?.cancel()
        activeRequest.resolve(result)
        self.activeRequest = nil
        switch result {
        case .success:
            state = .idle
        case .failure(let failure):
            state = .failed(activeRequest.language, failure)
        }
    }

    private func cancelActiveRequest(as failure: SpeechLanguagePreparationFailure) {
        guard let activeRequest else { return }
        activeRequest.cancelWork()
        activeRequest.resolve(.failure(failure))
        self.activeRequest = nil
    }
}
