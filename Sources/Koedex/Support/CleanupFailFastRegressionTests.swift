import Foundation

enum CleanupFailFastRegressionTests {
    static func run() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        for status in ["failed", "interrupted", "completed", "late"] {
            let writer = Writer()
            let client = CodexAppServerClient(lifecycleTestTransport: .init(write: { try writer.write($0) }))
            try? await client.start()
            let engine = CleanupEngine()
            await engine.debugReplaceClientForLifecycleTest(client, threadID: "test-thread")
            let task = Task { try await engine.debugRunTurnForLifecycleTest() }
            for _ in 0..<200 {
                if writer.id != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let id = writer.id, let session = await client.debugProcessSessionID else {
                task.cancel()
                _ = try? await task.value
                await engine.shutdown()
                results.append(.init(passed: false, name: "cleanup fake turn started"))
                continue
            }
            func send(_ object: [String: Any]) async {
                var data = try! JSONSerialization.data(withJSONObject: object)
                data.append(0x0A) // app-serverの出力は改行区切り。改行が無いと行として解釈されない。
                await client.debugConsume(data, sessionID: session)
            }
            await send(["id": id, "result": ["turn": ["id": "turn"]]])
            let start = ContinuousClock.now
            // 別turnの終了通知は猶予を開始させない。
            await send(["method": "turn/completed", "params": ["threadId": "test-thread", "turn": ["id": "other", "status": "failed"]]])
            await send(["method": "turn/completed", "params": ["threadId": "test-thread", "turn": ["id": "turn", "status": status == "late" ? "completed" : status]]])
            if status == "late" {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await send(["method": "item/completed", "params": ["threadId": "test-thread", "turnId": "turn", "item": ["type": "agentMessage", "phase": "final_answer", "text": "Test."]]])
            }
            var correct = false
            do {
                let text = try await task.value
                correct = status == "late" && text == "Test."
            } catch CleanupError.turnFailed {
                correct = status == "failed" || status == "interrupted"
            } catch CleanupError.turnEndedWithoutAnswer {
                correct = status == "completed"
            } catch {}
            let duration = start.duration(to: .now)
            correct = correct && duration < .seconds(1)
                && (status != "completed" || duration >= .milliseconds(480))
            await engine.shutdown()
            results.append(.init(passed: correct, name: "cleanup terminal grace: \(status)"))
        }
        let policy = CleanupThreadRotationPolicy.self
        results.append(.init(passed:
            !policy.shouldRotate(turnCount: 1, threadAgeSeconds: 0, absoluteAgeSeconds: 1799)
            && policy.shouldRotate(turnCount: 1, threadAgeSeconds: 0, absoluteAgeSeconds: 1800)
            && policy.shouldRotate(turnCount: 1, threadAgeSeconds: 600, absoluteAgeSeconds: 600)
            && !policy.shouldRotateBeforeRecording(turnCount: 1, threadAgeSeconds: 0, absoluteAgeSeconds: 1769)
            && policy.shouldRotateBeforeRecording(turnCount: 1, threadAgeSeconds: 0, absoluteAgeSeconds: 1770),
            name: "cleanup idle and absolute lifetime boundaries"))
        let tierEngine = CleanupEngine()
        await tierEngine.updateFastTierEnabled(true)
        await tierEngine.debugFastTierFailureForTest(.timeout)
        var state = await tierEngine.debugFastTierState
        results.append(.init(passed: state.failures == 0 && !state.disabled, name: "fast tier timeout does not count"))
        await tierEngine.debugFastTierFailureForTest(.turnFailed)
        state = await tierEngine.debugFastTierState
        results.append(.init(passed: state.failures == 1 && !state.disabled, name: "fast tier server failure counts"))
        await tierEngine.debugFastTierSuccessForTest()
        state = await tierEngine.debugFastTierState
        results.append(.init(passed: state.failures == 0, name: "fast tier success resets counter"))
        await tierEngine.debugFastTierFailureForTest(.turnFailed)
        await tierEngine.debugFastTierFailureForTest(.turnEndedWithoutAnswer)
        state = await tierEngine.debugFastTierState
        results.append(.init(passed: state.disabled, name: "fast tier two server failures disable"))
        await tierEngine.updateFastTierEnabled(true)
        state = await tierEngine.debugFastTierState
        results.append(.init(passed: state.failures == 0 && !state.disabled, name: "fast tier setting resets fallback"))
        await tierEngine.debugFastTierFailureForTest(.turnFailed)
        await tierEngine.debugFastTierFailureForTest(.turnFailed)
        await tierEngine.updateModelSettings(.default)
        state = await tierEngine.debugFastTierState
        results.append(.init(passed: state.failures == 0 && !state.disabled, name: "fast tier model change resets fallback"))
        return results
    }

    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: Int?
        var id: Int? { lock.lock(); defer { lock.unlock() }; return requestID }
        func write(_ data: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "turn/start" else { return }
            lock.lock()
            requestID = object["id"] as? Int
            lock.unlock()
        }
    }
}
