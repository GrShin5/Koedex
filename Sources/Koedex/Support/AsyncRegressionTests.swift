import Foundation
import AVFoundation

private actor AsyncRegressionGate {
    private var released = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ key: String) async {
        if released.remove(key) != nil { return }
        let pendingObservers = observers.removeValue(forKey: key) ?? []
        pendingObservers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func waitUntilBlocked(_ key: String) async {
        if waiters[key]?.isEmpty == false { return }
        await withCheckedContinuation { continuation in
            observers[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        let pending = waiters.removeValue(forKey: key) ?? []
        if pending.isEmpty {
            released.insert(key)
        } else {
            pending.forEach { $0.resume() }
        }
    }
}

private actor OneShotStartGate {
    let gate = AsyncRegressionGate()
    private var didBlock = false

    func suspendOnce() async {
        guard !didBlock else { return }
        didBlock = true
        await gate.wait("start")
    }
}

private final class AsyncRegressionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed: [UUID: Int] = [:]
    private var callbacks: [UUID: [String]] = [:]

    func recordConsumed(_ streamID: UUID) {
        lock.lock()
        consumed[streamID, default: 0] += 1
        lock.unlock()
    }

    func recordCallback(_ streamID: UUID, text: String) {
        lock.lock()
        callbacks[streamID, default: []].append(text)
        lock.unlock()
    }

    func consumedCount(for streamID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return consumed[streamID, default: 0]
    }

    func callbackCount(for streamID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callbacks[streamID, default: []].count
    }
}

private final class CodexTestWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(id: Int, method: String)] = []

    func write(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let method = object["method"] as? String else { return }
        lock.lock()
        requests.append((id, method))
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func request(at index: Int) -> (id: Int, method: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard requests.indices.contains(index) else { return nil }
        return requests[index]
    }

    func firstRequest(method: String) -> (id: Int, method: String)? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first { $0.method == method }
    }

    func contains(method: String) -> Bool {
        firstRequest(method: method) != nil
    }
}

private final class FakeTemporaryCopyState: @unchecked Sendable {
    let firstSleepGate = AsyncRegressionGate()
    private let lock = NSLock()
    private var storedChangeCount = 0
    private var sleepCount = 0
    private var restoreCalls = 0
    var firstObservedChangeCount = 1
    var writesSecondChange = false

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedChangeCount
    }

    func setChangeCount(_ value: Int) {
        lock.lock()
        storedChangeCount = value
        lock.unlock()
    }

    func sleep(_ nanoseconds: UInt64) async {
        let count = nextSleepCount()
        if count == 1 {
            await firstSleepGate.wait("copy-poll")
        } else {
            setChangeCount(writesSecondChange && count >= 3 ? 2 : firstObservedChangeCount)
        }
    }

    private func nextSleepCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sleepCount += 1
        return sleepCount
    }

    func restore(expected: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedChangeCount == expected else { return false }
        restoreCalls += 1
        storedChangeCount += 1
        return true
    }

    var restoreCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return restoreCalls
    }
}

struct AsyncRegressionResult {
    let passed: Bool
    let name: String
}

@MainActor
enum AsyncRegressionTests {
    static func run() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        results += await transcriptionStartOwnership()
        results += await transcriptionRuntimeTeardown()
        results += await speechLanguageTimeout()
        results += await codexClientSessionOwnership()
        results += await codexRequestTerminals()
        results += await cleanupClientGeneration()
        results += await cleanupRecordingPrewarmCancellation()
        results += await aiExecutionLeaseBeforeTurnID()
        results += await aiExecutionLeaseDuringTurnStart()
        results += await aiExecutionLeaseWithTurnID()
        results += await clipboardCancellationReceipt()
        results += await clipboardCancellationSecondChange()
        results += await aiCaptureLateCompletionOwnership()
        return results
    }

    private static func transcriptionStartOwnership() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        for point in [
            TranscriptionEngine.LifecycleTestPoint.startAfterPriorStop,
            .startAfterFormat,
            .startAfterAnalyzerLaunch,
        ] {
            results.append(await transcriptionStartOwnership(at: point))
        }
        return results
    }

    private static func transcriptionStartOwnership(
        at suspendedPoint: TranscriptionEngine.LifecycleTestPoint
    ) async -> AsyncRegressionResult {
        let startGate = AsyncRegressionGate()
        let resultsGate = AsyncRegressionGate()
        let firstID = UUID()
        let secondID = UUID()
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, streamID in
                if point == suspendedPoint, streamID == firstID {
                    await startGate.wait("first-format")
                } else if point == .fakeResultsStream {
                    await resultsGate.wait(streamID.uuidString)
                }
            },
            bypassSpeechFramework: true,
            finishTimeoutSeconds: 0.05
        )
        let engine = TranscriptionEngine(lifecycleTestSeam: seam)
        try? await engine.reconfigure(to: .japanese)

        let firstStart = Task { @MainActor in
            do {
                _ = try await engine.startStreaming(streamID: firstID)
                return false
            } catch {
                return true
            }
        }
        await startGate.waitUntilBlocked("first-format")
        engine.cancelPendingStart(streamID: firstID)
        let secondStarted = (try? await engine.startStreaming(streamID: secondID)) != nil
            || engine.debugActiveStreamID == secondID
        await startGate.release("first-format")
        let firstRejected = await firstStart.value
        let secondStayedActive = engine.debugActiveStreamID == secondID
        await resultsGate.release(secondID.uuidString)
        _ = await engine.stopStreaming(streamID: secondID)

        let pointName: String
        switch suspendedPoint {
        case .startAfterPriorStop: pointName = "prior-stop"
        case .startAfterFormat: pointName = "format"
        case .startAfterAnalyzerLaunch: pointName = "analyzer-launch"
        default: pointName = "unexpected"
        }
        return AsyncRegressionResult(
            passed: firstRejected && secondStarted && secondStayedActive,
            name: "STT start lease rejects A at \(pointName) while B remains active"
        )
    }

    private static func transcriptionRuntimeTeardown() async -> [AsyncRegressionResult] {
        let resultsGate = AsyncRegressionGate()
        let recorder = AsyncRegressionRecorder()
        let streamID = UUID()
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, id in
                if point == .fakeResultsStream {
                    await resultsGate.wait(id.uuidString)
                }
            },
            bypassSpeechFramework: true,
            finishTimeoutSeconds: 0.02,
            didConsumeBuffer: { recorder.recordConsumed($0) }
        )
        let engine = TranscriptionEngine(lifecycleTestSeam: seam)
        try? await engine.reconfigure(to: .japanese)
        _ = try? await engine.startStreaming(streamID: streamID) { id, text, _ in
            recorder.recordCallback(id, text: text)
        }
        let oldSink = engine.makeAudioSink()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        oldSink(buffer)
        await waitUntil { recorder.consumedCount(for: streamID) == 1 }

        let transcript = await engine.stopStreaming(streamID: streamID)
        let timedOut = engine.didTimeOutDuringFinishStreaming
        oldSink(buffer)
        await Task.yield()
        let oldSinkClosed = recorder.consumedCount(for: streamID) == 1

        await resultsGate.release(streamID.uuidString)
        await Task.yield()
        await Task.yield()
        let lateResultRejected = recorder.callbackCount(for: streamID) == 0
            && engine.partialText.isEmpty
            && transcript.isEmpty

        return [
            AsyncRegressionResult(
                passed: timedOut && oldSinkClosed && lateResultRejected,
                name: "STT timeout closes the old sink and rejects a noncooperative late result"
            ),
        ]
    }

    private static func speechLanguageTimeout() async -> [AsyncRegressionResult] {
        let gate = AsyncRegressionGate()
        var blockFirstPreparation = true
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, _ in
                if point == .reconfigureAfterAssets, blockFirstPreparation {
                    blockFirstPreparation = false
                    await gate.wait("language-assets")
                }
            },
            bypassSpeechFramework: true
        )
        let engine = TranscriptionEngine(localeIdentifier: "ja-JP", lifecycleTestSeam: seam)
        let coordinator = SpeechLanguagePreparationCoordinator(
            engine: engine,
            timeoutNanoseconds: 10_000_000
        )
        let busyRefused: Bool
        switch await coordinator.prepare(to: .english, isVoiceProcessing: true) {
        case .failure(.busy): busyRefused = true
        default: busyRefused = false
        }
        let busyKeptCurrentLanguage = engine.debugLocaleIdentifier.lowercased().hasPrefix("ja")
        let preparation = Task { @MainActor in
            await coordinator.prepare(to: .english, isVoiceProcessing: false)
        }
        await gate.waitUntilBlocked("language-assets")
        let timedOut: Bool
        switch await preparation.value {
        case .failure(.timedOut): timedOut = true
        default: timedOut = false
        }
        await gate.release("language-assets")
        await waitUntil { !engine.debugHasActiveReconfigurationLease }
        let lateCommitRejected = engine.debugLocaleIdentifier.lowercased().hasPrefix("ja")

        let retry = await coordinator.prepare(to: .english, isVoiceProcessing: false)
        let retrySucceeded: Bool
        switch retry {
        case .success: retrySucceeded = true
        case .failure: retrySucceeded = false
        }
        let retryCommitted = retrySucceeded
            && engine.debugLocaleIdentifier.lowercased().hasPrefix("en")
        return [
            AsyncRegressionResult(
                passed: busyRefused
                    && busyKeptCurrentLanguage
                    && timedOut
                    && lateCommitRejected
                    && retryCommitted,
                name: "speech language refuses recording-time changes and rejects timeout late commits before retry"
            ),
        ]
    }

    private static func codexClientSessionOwnership() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        for point in [CodexAppServerStartTestPoint.afterProcessLaunch, .afterInitialize] {
            results.append(await codexClientSessionOwnership(at: point))
        }
        return results
    }

    private static func codexClientSessionOwnership(
        at suspendedPoint: CodexAppServerStartTestPoint
    ) async -> AsyncRegressionResult {
        let writer = CodexTestWriter()
        let startGate = OneShotStartGate()
        let client = CodexAppServerClient(
            lifecycleTestTransport: CodexAppServerLifecycleTestTransport(
                write: { try writer.write($0) },
                suspendStart: { point, _ in
                    if point == suspendedPoint { await startGate.suspendOnce() }
                }
            )
        )
        let firstStart = Task { try await client.start() }
        await startGate.gate.waitUntilBlocked("start")
        let firstSession = await client.debugProcessSessionID!
        await client.stop()
        let secondStart = Task { try await client.start() }
        try? await secondStart.value
        let secondSession = await client.debugProcessSessionID!
        await startGate.gate.release("start")
        _ = try? await firstStart.value
        await client.debugSimulateTermination(status: 9, sessionID: firstSession)
        let oldTerminationIgnored = await client.isRunning

        let request = Task {
            try await client.sendRequest("fixture/new-session", params: nil, timeoutSeconds: 1)
        }
        await waitUntil { writer.count == 1 }
        let currentRequest = writer.request(at: 0)!
        let stalePartial = Data("{\"jsonrpc\":\"2.0\",\"id\":\(currentRequest.id)".utf8)
        await client.debugConsume(stalePartial, sessionID: firstSession)
        await client.debugConsume(responseLine(id: currentRequest.id), sessionID: secondSession)
        let responseSucceeded = (try? await request.value) != nil
        let pendingCleared = await client.debugPendingRequestCount == 0
        await client.stop()

        return AsyncRegressionResult(
            passed: firstSession != secondSession
                && oldTerminationIgnored
                && responseSucceeded
                && pendingCleared,
            name: "Codex client ignores old start/stdout/termination at \(suspendedPoint)"
        )
    }

    private static func codexRequestTerminals() async -> [AsyncRegressionResult] {
        let writer = CodexTestWriter()
        let client = CodexAppServerClient(
            lifecycleTestTransport: CodexAppServerLifecycleTestTransport(write: { try writer.write($0) })
        )
        try? await client.start()

        let responseTask = Task {
            try await client.sendRequest("fixture/response", params: nil, timeoutSeconds: 1)
        }
        await waitUntil { writer.count == 1 }
        let responseRequest = writer.request(at: 0)!
        await client.debugConsume(responseLine(id: responseRequest.id), sessionID: await client.debugProcessSessionID!)
        let responseCompleted = (try? await responseTask.value) != nil

        let timeoutTask = Task {
            do {
                _ = try await client.sendRequest("fixture/timeout", params: nil, timeoutSeconds: 0.01)
                return false
            } catch CodexClientError.timeout {
                return true
            } catch {
                return false
            }
        }
        let timeoutCompleted = await timeoutTask.value

        let cancellationTask = Task {
            do {
                _ = try await client.sendRequest(
                    "fixture/cancel",
                    params: nil,
                    timeoutSeconds: 1,
                    cancellationMode: .cancelWithTask
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await waitUntil { writer.count == 3 }
        let cancellationRequest = writer.request(at: 2)!
        cancellationTask.cancel()
        let cancellationCompleted = await cancellationTask.value
        let sessionID = await client.debugProcessSessionID!
        await client.debugConsume(responseLine(id: cancellationRequest.id), sessionID: sessionID)

        let stopTask = Task {
            do {
                _ = try await client.sendRequest("fixture/stop", params: nil, timeoutSeconds: 1)
                return false
            } catch CodexClientError.processNotRunning {
                return true
            } catch {
                return false
            }
        }
        await waitUntil { writer.count == 4 }
        await client.stop()
        let stopCompleted = await stopTask.value
        let pendingCleared = await client.debugPendingRequestCount == 0

        let preCancelledWriter = CodexTestWriter()
        let preCancelledClient = CodexAppServerClient(
            lifecycleTestTransport: CodexAppServerLifecycleTestTransport(write: { try preCancelledWriter.write($0) })
        )
        try? await preCancelledClient.start()
        let preCancelled = Task {
            try await preCancelledClient.sendRequest(
                "fixture/pre-cancel",
                params: nil,
                cancellationMode: .cancelWithTask
            )
        }
        preCancelled.cancel()
        _ = try? await preCancelled.value
        let preCancelPreventedWrite = preCancelledWriter.count == 0
        await preCancelledClient.stop()

        return [AsyncRegressionResult(
            passed: responseCompleted
                && timeoutCompleted
                && cancellationCompleted
                && stopCompleted
                && pendingCleared
                && preCancelPreventedWrite,
            name: "Codex request response timeout cancel stop and pre-cancel each complete pending exactly once"
        )]
    }

    private static func cleanupClientGeneration() async -> [AsyncRegressionResult] {
        let first = CodexAppServerClient(lifecycleTestTransport: .init(write: { _ in }))
        let second = CodexAppServerClient(lifecycleTestTransport: .init(write: { _ in }))
        let cleanup = CleanupEngine()
        await cleanup.debugReplaceClientForLifecycleTest(first, threadID: "old-thread")
        await cleanup.debugReplaceClientForLifecycleTest(second, threadID: "current-thread")
        await first.debugInvokeProcessExitCallback(status: 9)
        await Task.yield()
        let oldExitIgnored = await cleanup.debugThreadID == "current-thread"
        await second.debugInvokeProcessExitCallback(status: 9)
        await Task.yield()
        let currentExitApplied = await cleanup.debugThreadID == nil
        return [AsyncRegressionResult(
            passed: oldExitIgnored && currentExitApplied,
            name: "Cleanup exit callback clears a thread only for the current client generation"
        )]
    }

    private static func cleanupRecordingPrewarmCancellation() async -> [AsyncRegressionResult] {
        let writer = CodexTestWriter()
        let client = CodexAppServerClient(
            lifecycleTestTransport: CodexAppServerLifecycleTestTransport(write: { try writer.write($0) })
        )
        try? await client.start()
        let engine = CleanupEngine()
        await engine.debugReplaceClientForLifecycleTest(client, threadID: "existing")

        await engine.prepareThreadForRecording(promptLanguage: .english, correlationID: "A")
        await waitUntil { writer.count == 1 }
        await engine.cancelRecordingPrewarm(correlationID: "A")
        let cancelledRequest = writer.request(at: 0)!
        await client.debugConsume(
            responseLine(
                id: cancelledRequest.id,
                result: ["thread": ["id": "late-A", "ephemeral": true]]
            ),
            sessionID: await client.debugProcessSessionID!
        )
        await waitUntilAsync { !(await engine.debugHasThreadPreparation) }
        let cancelledDidNotAdopt = await engine.debugThreadID == "existing"

        await engine.prepareThreadForRecording(promptLanguage: .english, correlationID: "B")
        await waitUntil { writer.count == 2 }
        await engine.cancelRecordingPrewarm(correlationID: "A")
        let currentRequest = writer.request(at: 1)!
        await client.debugConsume(
            responseLine(
                id: currentRequest.id,
                result: ["thread": ["id": "current-B", "ephemeral": true]]
            ),
            sessionID: await client.debugProcessSessionID!
        )
        await waitUntilAsync { await engine.debugThreadID == "current-B" }
        let otherSessionPreserved = await engine.debugThreadID == "current-B"
        await engine.shutdown()

        return [AsyncRegressionResult(
            passed: cancelledDidNotAdopt && otherSessionPreserved,
            name: "recording prewarm cancellation rejects its late thread and preserves another session"
        )]
    }

    private static func aiExecutionLeaseBeforeTurnID() async -> [AsyncRegressionResult] {
        let noWebWriter = CodexTestWriter()
        let webWriter = CodexTestWriter()
        let noWebClient = CodexAppServerClient(
            lifecycleTestTransport: .init(write: { try noWebWriter.write($0) })
        )
        let webClient = CodexAppServerClient(
            lifecycleTestTransport: .init(write: { try webWriter.write($0) })
        )
        let settings = lifecycleModelSettings()
        let engine = AICommandEngine(
            lifecycleWorkingDirectory: NSTemporaryDirectory(),
            lifecycleAvailableModels: [lifecycleModel()],
            lifecycleClientFactory: { webEnabled, _ in webEnabled ? webClient : noWebClient }
        )
        try? await engine.reconnect(
            modelSettings: settings,
            webSearchEnabled: true,
            forceRefresh: false
        )
        let execution = Task {
            try await engine.execute(lifecycleAIRequest(settings: settings)) { _ in }
        }
        await waitUntil { noWebWriter.contains(method: "thread/start") }
        await engine.cancelActive()
        _ = try? await execution.value
        let noTurnStarted = !noWebWriter.contains(method: "turn/start")
        let exactRouteStopped = await !noWebClient.isRunning
        let otherRouteStayedRunning = await webClient.isRunning
        let leaseReleased = await !engine.debugIsExecuting
        await webClient.stop()

        return [AsyncRegressionResult(
            passed: noTurnStarted && exactRouteStopped && otherRouteStayedRunning && leaseReleased,
            name: "AI cancellation before a turn ID stops only the leased route client"
        )]
    }

    private static func aiExecutionLeaseWithTurnID() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        results.append(await aiExecutionLeaseWithTurnID(interruptSucceeds: true))
        results.append(await aiExecutionLeaseWithTurnID(interruptSucceeds: false))
        return results
    }

    private static func aiExecutionLeaseDuringTurnStart() async -> [AsyncRegressionResult] {
        let writer = CodexTestWriter()
        let client = CodexAppServerClient(
            lifecycleTestTransport: .init(write: { try writer.write($0) })
        )
        let settings = lifecycleModelSettings()
        let engine = AICommandEngine(
            lifecycleWorkingDirectory: NSTemporaryDirectory(),
            lifecycleAvailableModels: [lifecycleModel()],
            lifecycleClientFactory: { _, _ in client }
        )
        let execution = Task {
            try await engine.execute(lifecycleAIRequest(settings: settings)) { _ in }
        }
        await waitUntil { writer.contains(method: "thread/start") }
        let sessionID = await client.debugProcessSessionID!
        let threadRequest = writer.firstRequest(method: "thread/start")!
        await client.debugConsume(
            responseLine(id: threadRequest.id, result: ["thread": ["id": "fixture-thread", "ephemeral": true]]),
            sessionID: sessionID
        )
        await waitUntil { writer.contains(method: "turn/start") }
        let turnRequest = writer.firstRequest(method: "turn/start")!
        execution.cancel()
        await engine.cancelActive()
        _ = try? await execution.value
        await client.debugConsume(
            responseLine(id: turnRequest.id, result: ["turn": ["id": "late-turn"]]),
            sessionID: sessionID
        )
        let lateIgnored = await client.debugPendingRequestCount == 0
        let stoppedExactRoute = await !client.isRunning
        let released = await !engine.debugIsExecuting
        return [AsyncRegressionResult(
            passed: lateIgnored && stoppedExactRoute && released && !writer.contains(method: "turn/interrupt"),
            name: "AI cancellation while turn/start is pending stops the route and ignores its late response"
        )]
    }

    private static func aiExecutionLeaseWithTurnID(
        interruptSucceeds: Bool
    ) async -> AsyncRegressionResult {
        let writer = CodexTestWriter()
        let otherWriter = CodexTestWriter()
        let client = CodexAppServerClient(
            lifecycleTestTransport: .init(write: { try writer.write($0) })
        )
        let otherClient = CodexAppServerClient(
            lifecycleTestTransport: .init(write: { try otherWriter.write($0) })
        )
        let settings = lifecycleModelSettings()
        let engine = AICommandEngine(
            lifecycleWorkingDirectory: NSTemporaryDirectory(),
            lifecycleAvailableModels: [lifecycleModel()],
            lifecycleClientFactory: { webEnabled, _ in webEnabled ? otherClient : client }
        )
        try? await engine.reconnect(modelSettings: settings, webSearchEnabled: true, forceRefresh: false)
        let execution = Task {
            try await engine.execute(lifecycleAIRequest(settings: settings)) { _ in }
        }
        await waitUntil { writer.contains(method: "thread/start") }
        let sessionID = await client.debugProcessSessionID!
        let threadRequest = writer.firstRequest(method: "thread/start")!
        await client.debugConsume(
            responseLine(
                id: threadRequest.id,
                result: ["thread": ["id": "fixture-thread", "ephemeral": true]]
            ),
            sessionID: sessionID
        )
        await waitUntil { writer.contains(method: "turn/start") }
        let turnRequest = writer.firstRequest(method: "turn/start")!
        await client.debugConsume(
            responseLine(id: turnRequest.id, result: ["turn": ["id": "fixture-turn"]]),
            sessionID: sessionID
        )
        await waitUntilAsync { await engine.debugHasActiveTurn }
        let cancellation = Task { await engine.cancelActive() }
        await waitUntil { writer.contains(method: "turn/interrupt") }
        await Task.yield()
        let replacementBlocked: Bool
        do {
            _ = try await engine.execute(lifecycleAIRequest(settings: settings)) { _ in }
            replacementBlocked = false
        } catch {
            replacementBlocked = true
        }
        let interrupt = writer.firstRequest(method: "turn/interrupt")!
        if interruptSucceeds {
            await client.debugConsume(responseLine(id: interrupt.id), sessionID: sessionID)
        } else {
            await client.debugConsume(errorLine(id: interrupt.id, code: -32000), sessionID: sessionID)
        }
        await cancellation.value
        _ = try? await execution.value
        let interruptWasSingle = writer.count == 3
        let routeStateIsExpected = await client.isRunning == interruptSucceeds
        let otherRoutePreserved = await otherClient.isRunning
        let leaseReleased = await !engine.debugIsExecuting
        let replacement = Task {
            try await engine.execute(lifecycleAIRequest(settings: settings)) { _ in }
        }
        await waitUntilAsync { await engine.debugIsExecuting }
        let replacementAccepted = await engine.debugIsExecuting
        await engine.cancelActive()
        _ = try? await replacement.value
        await client.stop()
        await otherClient.stop()

        return AsyncRegressionResult(
            passed: replacementBlocked
                && interruptWasSingle
                && routeStateIsExpected
                && otherRoutePreserved
                && leaseReleased
                && replacementAccepted,
            name: "AI known-turn cancellation joins one \(interruptSucceeds ? "successful" : "failed") interrupt before reuse"
        )
    }

    private static func lifecycleModelSettings() -> CodexModelSettings {
        CodexModelSettings(
            mode: .explicit,
            selectedModelSlug: "fixture-model",
            selectedReasoningEffort: "low"
        )
    }

    private static func lifecycleModel() -> CodexModelInfo {
        CodexModelInfo(
            slug: "fixture-model",
            displayName: "Fixture",
            defaultReasoningLevel: "low",
            supportedReasoningLevels: [.init(effort: "low", description: "")],
            visibility: "list",
            supportsSearchTool: true
        )
    }

    private static func lifecycleAIRequest(settings: CodexModelSettings) -> AICommandRequest {
        AICommandRequest(
            spokenInstruction: "fixture",
            selectedText: nil,
            additionalInstruction: "",
            personalDictionary: [],
            modelSettings: settings,
            webSearchEnabled: false,
            promptLanguage: .english,
            outputLanguage: .fixed(.english)
        )
    }

    private static func clipboardCancellationReceipt() async -> [AsyncRegressionResult] {
        let state = FakeTemporaryCopyState()
        let capture = SelectedTextCapture()
        let task = Task { @MainActor in
            await capture.debugCaptureTemporaryCopy(runtime: temporaryCopyRuntime(state))
        }
        await state.firstSleepGate.waitUntilBlocked("copy-poll")
        task.cancel()
        await state.firstSleepGate.release("copy-poll")
        let result = await task.value
        guard case .cancelledTemporaryCopy(let receipt) = result else {
            return [AsyncRegressionResult(
                passed: false,
                name: "clipboard cancellation receipt restores once and refuses a changed board"
            )]
        }
        let restored = receipt.resolve(restoreOriginal: true) == .restored
        let secondActionIgnored = receipt.resolve(restoreOriginal: true) == .alreadyResolved

        let changedReceipt = ClipboardCancellationReceipt(
            expectedChangeCount: 4,
            currentChangeCount: { 5 },
            restoreSnapshot: { _ in false }
        )
        let changedRefused = changedReceipt.resolve(restoreOriginal: true) == .clipboardChanged
        let expiredReceipt = ClipboardCancellationReceipt(
            expectedChangeCount: 7,
            lifetimeSeconds: 0,
            currentChangeCount: { 7 },
            restoreSnapshot: { _ in false }
        )
        let expiredRefused = expiredReceipt.resolve(restoreOriginal: true) == .expired
        return [AsyncRegressionResult(
            passed: restored
                && secondActionIgnored
                && state.restoreCallCount == 1
                && changedRefused
                && expiredRefused,
            name: "clipboard cancellation receipt restores once and refuses change or expiry"
        )]
    }

    private static func clipboardCancellationSecondChange() async -> [AsyncRegressionResult] {
        let state = FakeTemporaryCopyState()
        state.writesSecondChange = true
        let capture = SelectedTextCapture()
        let task = Task { @MainActor in
            await capture.debugCaptureTemporaryCopy(runtime: temporaryCopyRuntime(state))
        }
        await state.firstSleepGate.waitUntilBlocked("copy-poll")
        task.cancel()
        await state.firstSleepGate.release("copy-poll")
        let result = await task.value
        let rejected: Bool
        if case .unavailable(.clipboardChanged) = result {
            rejected = true
        } else {
            rejected = false
        }
        let directJumpState = FakeTemporaryCopyState()
        directJumpState.firstObservedChangeCount = 2
        let directJumpTask = Task { @MainActor in
            await capture.debugCaptureTemporaryCopy(runtime: temporaryCopyRuntime(directJumpState))
        }
        await directJumpState.firstSleepGate.waitUntilBlocked("copy-poll")
        directJumpTask.cancel()
        await directJumpState.firstSleepGate.release("copy-poll")
        let directJumpResult = await directJumpTask.value
        let directJumpRejected: Bool
        if case .unavailable(.clipboardChanged) = directJumpResult {
            directJumpRejected = true
        } else {
            directJumpRejected = false
        }
        return [AsyncRegressionResult(
            passed: rejected && state.restoreCallCount == 0,
            name: "clipboard cancellation observes only the remaining copy window and rejects a second change"
        ), AsyncRegressionResult(
            passed: directJumpRejected && directJumpState.restoreCallCount == 0,
            name: "clipboard cancellation rejects a direct two-change jump"
        )]
    }

    private static func aiCaptureLateCompletionOwnership() async -> [AsyncRegressionResult] {
        let zeroGate = AsyncRegressionGate()
        let zeroOwnership = AICommandCaptureCompletionGate()
        let oldZeroLease = zeroOwnership.begin()
        let oldZero = Task { @MainActor in
            await zeroGate.wait("zero")
            if case .stale = zeroOwnership.classify(.none, lease: oldZeroLease, appIsIdle: false) {
                return true
            }
            return false
        }
        await zeroGate.waitUntilBlocked("zero")
        let currentZeroLease = zeroOwnership.begin()
        await zeroGate.release("zero")
        let zeroIgnored = await oldZero.value
            && zeroOwnership.activeCaptureID == currentZeroLease.id

        let receiptGate = AsyncRegressionGate()
        let receiptOwnership = AICommandCaptureCompletionGate()
        let oldReceiptLease = receiptOwnership.begin()
        receiptOwnership.authorizeUserCancellation()
        let staleReceipt = ClipboardCancellationReceipt(
            expectedChangeCount: 1,
            currentChangeCount: { 1 },
            restoreSnapshot: { _ in true }
        )
        let oldReceipt = Task { @MainActor in
            await receiptGate.wait("receipt")
            if case .stale = receiptOwnership.classify(
                .cancelledTemporaryCopy(staleReceipt),
                lease: oldReceiptLease,
                appIsIdle: true
            ) {
                return true
            }
            return false
        }
        await receiptGate.waitUntilBlocked("receipt")
        let currentReceiptLease = receiptOwnership.begin()
        await receiptGate.release("receipt")
        let receiptIgnored = await oldReceipt.value
            && receiptOwnership.activeCaptureID == currentReceiptLease.id
            && !staleReceipt.isUsable()

        return [AsyncRegressionResult(
            passed: zeroIgnored && receiptIgnored,
            name: "late zero-change and receipt capture completions cannot mutate a replacement capture"
        )]
    }

    private static func temporaryCopyRuntime(
        _ state: FakeTemporaryCopyState
    ) -> SelectedTextCapture.TemporaryCopyTestRuntime {
        SelectedTextCapture.TemporaryCopyTestRuntime(
            snapshotIsComplete: true,
            snapshotStillCurrent: { state.changeCount == 0 },
            changeCount: { state.changeCount },
            copiedString: { nil },
            postCopy: { true },
            secureInputEnabled: { false },
            targetMatches: { true },
            restoreSnapshot: { state.restore(expected: $0) },
            sleep: { await state.sleep($0) }
        )
    }

    private static func responseLine(id: Int, result: [String: Any] = [:]) -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func errorLine(id: Int, code: Int) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": "fixture"],
        ]
        var data = try! JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 where !predicate() {
            await Task.yield()
        }
    }

    private static func waitUntilAsync(_ predicate: () async -> Bool) async {
        for _ in 0..<1_000 where !(await predicate()) {
            await Task.yield()
        }
    }
}
