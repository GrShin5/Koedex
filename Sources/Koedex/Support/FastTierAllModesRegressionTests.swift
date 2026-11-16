import Foundation

@MainActor
enum FastTierAllModesRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        do {
            var settings = try JSONDecoder().decode(KoedexSettings.self, from: Data("{}".utf8))
            expect(settings.fastTierAllModesState == .allOff, "legacy mode tiers default off")
            settings.setFastTierForAllModes(true)
            expect(settings.fastTierAllModesState == .allOn, "bulk tier on")
            let saved = try JSONDecoder().decode(KoedexSettings.self, from: JSONEncoder().encode(settings))
            expect(saved.fastTierAllModesState == .allOn, "all tier flags persist")
            settings.aiCommandSettings.fastTierEnabled = false
            expect(settings.fastTierAllModesState == .mixed, "individual tier creates mixed state")
            settings.setFastTierForAllModes(false)
            expect(settings.fastTierAllModesState == .allOff, "bulk tier off")
        } catch { expect(false, "mode tier settings decode") }
        for enabled in [false, true] {
            for disabled in [false, true] {
                let params = FastTierTurnPolicy.params(["threadId": "test"], enabled: enabled, disabled: disabled)
                expect((params["serviceTierForTurn"] as? String) == (enabled && !disabled ? "priority" : nil),
                       "turn tier is present only when enabled and available")
            }
        }
        expect(OfflineCleanupPolicy.shouldInstantInsert(enabled: true, eligible: true), "offline preserves instant insert")
        expect(!CleanupFastTierFallbackPolicy.countsAsFailure(.offline), "offline is not an RPC failure")
        for state in [NetworkReachabilityState.online, .offline, .unknown] {
            expect(OfflineCleanupPolicy.shouldSkipCleanup(state: state) == (state == .offline),
                   "only confirmed offline skips cleanup")
        }
    }
}

enum FastTierRetryRegressionTests {
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []
        func write(_ data: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "turn/start" else { return }
            lock.lock()
            requests.append(object)
            lock.unlock()
        }
        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    static func run() async -> [AsyncRegressionResult] {
        var extra: [AsyncRegressionResult] = []
        for code in [429, 401, 403, 402] {
            extra.append(await noRetry(code: code))
        }
        extra.append(await noRetry(code: nil))
        extra.append(await noRetry(code: nil, cancel: true))
        let engine = CleanupEngine()
        await engine.updateFastTierEnabled(true)
        await engine.debugFastTierFailureForTest(.turnFailed)
        await engine.debugFastTierSuccessForTest(carriedTier: false)
        await engine.debugFastTierFailureForTest(.turnFailed)
        let state = await engine.debugFastTierState
        extra.append(.init(passed: state.disabled && state.failures == 2, name: "tier-free success preserves tier failure counter"))
        let writer = Writer()
        let client = CodexAppServerClient(lifecycleTestTransport: .init(write: { try writer.write($0) }))
        do {
            try await client.start()
            guard let session = await client.debugProcessSessionID else { throw CleanupError.emptyResult }
            let task = Task { try await client.sendTurn(params: ["threadId": "test"], fastTier: true, timeoutSeconds: 2) }
            for count in 1...2 {
                for _ in 0..<200 {
                    if writer.snapshot().count >= count { break }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                let requests = writer.snapshot()
                guard requests.count >= count, let id = requests[count - 1]["id"] as? Int else {
                    task.cancel()
                    _ = try? await task.value
                    throw CleanupError.emptyResult
                }
                let object: [String: Any] = count == 1
                    ? ["id": id, "error": ["code": -32602, "message": "rejected"]]
                    : ["id": id, "result": ["turn": ["id": "test"]]]
                var data = try JSONSerialization.data(withJSONObject: object)
                data.append(0x0A)
                await client.debugConsume(data, sessionID: session)
            }
            _ = try await task.value
            let requests = writer.snapshot()
            let first = requests.first?["params"] as? [String: Any]
            let second = requests.last?["params"] as? [String: Any]
            let passed = requests.count == 2 && first?["serviceTierForTurn"] as? String == "priority"
                && second?["serviceTierForTurn"] == nil
            await client.stop()
            return extra + [.init(passed: passed, name: "rejected tier retries once without tier")]
        } catch {
            await client.stop()
            return extra + [.init(passed: false, name: "rejected tier retries once without tier")]
        }
    }
    private static func noRetry(code: Int?, cancel: Bool = false) async -> AsyncRegressionResult {
        let writer = Writer()
        let client = CodexAppServerClient(lifecycleTestTransport: .init(write: { try writer.write($0) }))
        var passed = false
        do {
            try await client.start()
            let task = Task { try await client.sendTurn(params: ["threadId": "test"], fastTier: true,
                timeoutSeconds: code == nil && !cancel ? 0.03 : 2, cancellationMode: .cancelWithTask) }
            for _ in 0..<200 {
                if !writer.snapshot().isEmpty { break }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            if cancel { task.cancel() }
            if let code, let id = writer.snapshot().first?["id"] as? Int,
               let session = await client.debugProcessSessionID {
                var data = try JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": code]])
                data.append(0x0A)
                await client.debugConsume(data, sessionID: session)
            }
            do { _ = try await task.value } catch { passed = writer.snapshot().count == 1 }
            let next = Task { try await client.sendTurn(params: ["threadId": "test"], fastTier: true,
                timeoutSeconds: 0.03, cancellationMode: .cancelWithTask) }
            _ = try? await next.value
            let params = writer.snapshot().last?["params"] as? [String: Any]
            passed = passed && writer.snapshot().count == 2 && params?["serviceTierForTurn"] as? String == "priority"
        } catch { passed = false }
        await client.stop()
        return .init(passed: passed, name: "tier preserves timeout cancellation or classified RPC failure (code=\(code ?? 0), cancel=\(cancel))")
    }

}

/// 一時停止の保持（AIに指示・最適化はclientが作り直されても停止を維持し、設定操作で解除）。
enum FastTierPauseRegistryRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        let registry = FastTierPauseRegistry()
        expect(registry.effective(true, for: .aiCommand) && !registry.effective(false, for: .aiCommand),
               "fast tier pause registry passes the setting through when nothing is paused")
        registry.pause(.aiCommand)
        expect(!registry.effective(true, for: .aiCommand) && registry.effective(true, for: .optimization),
               "fast tier pause is per mode and survives a new client")
        registry.reset(.aiCommand)
        expect(registry.effective(true, for: .aiCommand), "changing the mode setting clears its fast tier pause")
        registry.pause(.aiCommand); registry.pause(.optimization); registry.resetAll()
        expect(registry.effective(true, for: .aiCommand) && registry.effective(true, for: .optimization),
               "bulk apply clears every fast tier pause")
    }
}

@MainActor
enum OnboardingSpeedOptionsRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        expect(KoedexSettings.default.fastTierAllModesState == .allOff, "onboarding default fast tier off")
        var settings = DebugFreshSetupResetPolicy.freshSettings()
        expect(settings.fastTierAllModesState == .allOff, "fresh debug fast tier off")
        expect(!settings.shortUtteranceInstantInsertEnabled, "fresh debug instant insert off")
        for mode in [OnboardingPresentationMode.firstRun, .upgrade, .debugPreview, .debugRehearsal] {
            expect(OnboardingSpeedOptionsPolicy.showsOptionalToggles(in: mode), "speed options available: \(mode)")
        }
        for mode in [OnboardingPresentationMode.permissionRecovery, .guide] {
            expect(!OnboardingSpeedOptionsPolicy.showsOptionalToggles(in: mode), "speed options hidden: \(mode)")
        }
        OnboardingSpeedOptionsPolicy.applyFastTier(true, to: &settings)
        expect(settings.fastTierAllModesState == .allOn, "onboarding enables all fast tiers")
        OnboardingSpeedOptionsPolicy.applyFastTier(false, to: &settings)
        expect(settings.fastTierAllModesState == .allOff, "onboarding disables all fast tiers")
    }
}

enum OnboardingScreenshotModeRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        for mode in [OnboardingPresentationMode.debugPreview, .debugRehearsal] {
            for language in [AppLanguage.japanese, .english] {
                expect(mode.title(for: language, screenshotMode: true) == OnboardingPresentationMode.firstRun.title(for: language), "screenshot uses release title")
                expect(mode.title(for: language) != OnboardingPresentationMode.firstRun.title(for: language), "debug retains debug title")
            }
            expect(mode.completionButtonKey(screenshotMode: true) == "Koedexを開始", "screenshot completion label")
            expect(mode.completionButtonKey(screenshotMode: false) == "Debugメニューへ戻る", "debug completion label")
            expect(!mode.showsDebugUI(screenshotMode: true) && mode.showsDebugUI(screenshotMode: false), "screenshot hides debug UI")
        }
        for mode in [OnboardingPresentationMode.firstRun, .upgrade, .permissionRecovery, .guide] {
            for language in [AppLanguage.japanese, .english] {
                expect(mode.title(for: language, screenshotMode: true) == mode.title(for: language), "production title unaffected")
            }
            expect(mode.completionButtonKey(screenshotMode: true) == mode.completionButtonKey(screenshotMode: false), "production completion unaffected")
            expect(!mode.showsDebugUI(screenshotMode: true) && !mode.showsDebugUI(screenshotMode: false), "production hides debug UI")
        }
        expect(OnboardingPresentationMode.guide.completionButtonKey(screenshotMode: true) == "閉じる", "guide closes")
        expect(OnboardingPresentationMode.firstRun.completionButtonKey(screenshotMode: false) == "Koedexを開始", "first run starts")
    }
}

/// 初回セットアップの「終了して、もう一度開く」はrun loopからterminateする（main queueのブロック内から
/// 呼ぶと、`.terminateLater`のreplyが届かず強制終了の締切まで終わらない）。
enum RunLoopApplicationTerminationRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        let modes = RunLoopApplicationTermination.runLoopModes
        expect(modes.contains(.default), "restart quit runs terminate from the default run loop mode")
        expect(modes.contains(.eventTracking), "restart quit is not blocked while a menu is open")
        expect(modes.contains(.modalPanel), "restart quit is not blocked during a modal panel")
    }
}
