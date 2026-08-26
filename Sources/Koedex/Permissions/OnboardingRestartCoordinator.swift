import AppKit
import Combine
import Darwin
import Foundation

/// 権限反映のための再起動で、一度だけ復帰するオンボーディング表示先。
/// 設定スキーマへ混ぜず、Application Support内の専用ファイルへ保存する。
struct OnboardingRestartIntent: Codable, Equatable {
    enum Route: String, Codable, Equatable {
        case firstRun
        case upgrade
        case permissionRecovery
        case debugPreview
        case debugRehearsal
    }

    /// helperの結果を次の手動起動でも安全に復帰させるための、後方互換な記録。
    enum HandoffStatus: String, Codable, Equatable {
        case pending
        case helperLaunched
        case helperFailed
    }

    enum HandoffFailure: String, Codable, Equatable {
        case helperUnavailable
        case helperValidationFailed
        case sourceExitTimedOut
        case successorLaunchFailed
    }

    let route: Route
    let step: OnboardingStep
    let bundleIdentifier: String
    /// 後継プロセスが旧プロセスの終了を確認してからUIを表示するための情報。
    /// 旧版が書いたintentも読めるようoptionalにしている。
    let sourceProcessIdentifier: Int32?
    let generation: UUID?
    /// 旧版のintentを読めるよう、これらはoptionalのまま追加する。
    let createdAt: Date?
    let expiresAt: Date?
    var handoffStatus: HandoffStatus?
    var handoffFailure: HandoffFailure?

    init?(
        mode: OnboardingPresentationMode,
        step: OnboardingStep = .permissions,
        bundleIdentifier: String
    ) {
        guard let route = mode.restartRoute else { return nil }
        self.route = route
        self.step = step
        self.bundleIdentifier = bundleIdentifier
        self.sourceProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        self.generation = UUID()
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(OnboardingRestartHandoff.maximumWaitInterval)
        self.handoffStatus = .pending
        self.handoffFailure = nil
    }

    var presentationMode: OnboardingPresentationMode {
        OnboardingPresentationMode(restartRoute: route)
    }

    func matches(bundleIdentifier: String) -> Bool {
        self.bundleIdentifier == bundleIdentifier
    }
}

extension OnboardingPresentationMode {
    fileprivate var restartRoute: OnboardingRestartIntent.Route? {
        switch self {
        case .firstRun: return .firstRun
        case .upgrade: return .upgrade
        case .permissionRecovery: return .permissionRecovery
        case .debugPreview: return .debugPreview
        case .debugRehearsal: return .debugRehearsal
        case .guide: return nil
        }
    }

    fileprivate init(restartRoute: OnboardingRestartIntent.Route) {
        switch restartRoute {
        case .firstRun: self = .firstRun
        case .upgrade: self = .upgrade
        case .permissionRecovery: self = .permissionRecovery
        case .debugPreview: self = .debugPreview
        case .debugRehearsal: self = .debugRehearsal
        }
    }
}

/// 再起動意図を読み書きする小さなストア。壊れた・別アプリ用の内容は再利用しない。
final class OnboardingRestartIntentStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL = OnboardingRuntimeProfile.restartIntentURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func save(_ intent: OnboardingRestartIntent) throws {
        // セットアップ中はこの経路がストレージルートを最初に作ることがある。
        // ここで0700にしておかないと、次回起動の是正までルートが0755のまま残る。
        StoragePermissions.ensureDirectory(at: fileURL.deletingLastPathComponent())
        let data = try encoder.encode(intent)
        try data.write(to: fileURL, options: .atomic)
        StoragePermissions.applyFileMode(to: fileURL)
    }

    func load(bundleIdentifier: String) -> OnboardingRestartIntent? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let intent = try decoder.decode(OnboardingRestartIntent.self, from: Data(contentsOf: fileURL))
            guard intent.matches(bundleIdentifier: bundleIdentifier) else {
                clear()
                return nil
            }
            return intent
        } catch {
            clear()
            return nil
        }
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
    }

    func recordHelperFailure(
        _ failure: OnboardingRestartIntent.HandoffFailure,
        for intent: OnboardingRestartIntent
    ) {
        var failedIntent = intent
        failedIntent.handoffStatus = .helperFailed
        failedIntent.handoffFailure = failure
        do {
            try save(failedIntent)
        } catch {
            AppLog.shared.warn("[OnboardingRestartCoordinator] helper failure state save failed: \(AppLog.safeDescription(error))")
        }
    }
}

enum OnboardingRestartError: LocalizedError, Equatable {
    case unsupportedMode
    case applicationBundleUnavailable
    case interactiveChecksDidNotStop
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedMode:
            return "この画面ではアプリを再起動できません。"
        case .applicationBundleUnavailable:
            return "アプリ本体を見つけられなかったため、再起動できませんでした。"
        case .interactiveChecksDidNotStop:
            return "録音やキー確認の停止を確認できなかったため、再起動を中止しました。少し待ってから、もう一度試してください。"
        case .launchFailed:
            return "新しいアプリを起動できませんでした。少し待ってから、もう一度試してください。"
        }
    }
}

/// 旧プロセスが残っている間に後継側がセットアップUIや録音を始めないための、
/// 小さくテスト可能なPID判定。OS上のプロセス生成そのものを完全に直列化する
/// のではなく、ユーザーに見えるウィンドウとマイク利用を一つに保つ。
enum OnboardingRestartHandoff {
    static let pollIntervalNanoseconds: UInt64 = 100_000_000
    static let maximumWaitInterval: TimeInterval = 15

    enum SourceProcessState: Equatable {
        case exited
        case alive
        case timedOut
    }

    static func shouldWaitForSourceProcessExit(
        _ intent: OnboardingRestartIntent,
        currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: (Int32) -> Bool = isProcessAlive
    ) -> Bool {
        guard let sourcePID = intent.sourceProcessIdentifier,
              sourcePID > 0,
              sourcePID != currentProcessIdentifier else {
            return false
        }
        return isProcessAlive(sourcePID)
    }

    static func waitForSourceProcessExit(_ intent: OnboardingRestartIntent) async {
        while shouldWaitForSourceProcessExit(intent) {
            if let expiresAt = intent.expiresAt, Date() >= expiresAt { return }
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    static func sourceProcessState(
        _ intent: OnboardingRestartIntent,
        now: Date = Date(),
        currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: (Int32) -> Bool = isProcessAlive
    ) -> SourceProcessState {
        if let expiresAt = intent.expiresAt, now >= expiresAt { return .timedOut }
        return shouldWaitForSourceProcessExit(
            intent,
            currentProcessIdentifier: currentProcessIdentifier,
            isProcessAlive: isProcessAlive
        ) ? .alive : .exited
    }

    /// helperへ渡す値が保存済みintentと完全に対応するかを、起動前にも確認する。
    static func validatesHelperInvocation(
        intent: OnboardingRestartIntent,
        bundleIdentifier: String,
        sourcePID: Int32,
        generation: UUID,
        createdAt: Date,
        expiresAt: Date,
        now: Date = Date()
    ) -> Bool {
        intent.bundleIdentifier == bundleIdentifier
            && intent.sourceProcessIdentifier == sourcePID
            && intent.generation == generation
            && intent.createdAt == createdAt
            && intent.expiresAt == expiresAt
            && now < expiresAt
    }

    private static func isProcessAlive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if Darwin.kill(processIdentifier, 0) == 0 {
            return true
        }
        // EPERM means the process exists but this process cannot inspect it.
        return errno == EPERM
    }
}

private final class RestartPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResolve = false

    func resolve(_ result: Bool, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResolve else { return }
        didResolve = true
        continuation.resume(returning: result)
    }
}

enum OnboardingRestartRequestPolicy {
    static func permitsRestart(isRestarting: Bool) -> Bool { !isRestarting }
}

enum OnboardingRestartFeedbackPolicy {
    static let helperFailureText = "アプリを再起動できませんでした。少し待ってから、もう一度試してください。"

    static func initialFeedbackKey(for intent: OnboardingRestartIntent) -> String? {
        intent.handoffStatus == .helperFailed ? helperFailureText : nil
    }
}

/// restart helperを起動してから、現在のプロセスを安全に終了する。
@MainActor
final class OnboardingRestartCoordinator: ObservableObject {
    @Published private(set) var isRestarting = false

    private let intentStore: OnboardingRestartIntentStore
    private let preparationTimeoutNanoseconds: UInt64

    init(
        intentStore: OnboardingRestartIntentStore = OnboardingRestartIntentStore(),
        preparationTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.intentStore = intentStore
        self.preparationTimeoutNanoseconds = preparationTimeoutNanoseconds
    }

    func restart(
        mode: OnboardingPresentationMode,
        settingsStore: SettingsStore,
        prepareForRestart: @escaping @MainActor () async -> Bool,
        suspendOnboardingWindow: @escaping @MainActor () -> Void,
        restoreOnboardingWindowAfterFailure: @escaping @MainActor () -> Void,
        completion: @escaping (Result<Void, OnboardingRestartError>) -> Void
    ) {
        guard OnboardingRestartRequestPolicy.permitsRestart(isRestarting: isRestarting) else { return }
        guard mode.restartRoute != nil else {
            completion(.failure(.unsupportedMode))
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            completion(.failure(.applicationBundleUnavailable))
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        guard !bundleIdentifier.isEmpty else {
            completion(.failure(.applicationBundleUnavailable))
            return
        }

        isRestarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.waitForPreparation(prepareForRestart) else {
                self.isRestarting = false
                completion(.failure(.interactiveChecksDidNotStop))
                return
            }

            settingsStore.flushPendingSave()
            guard let intent = OnboardingRestartIntent(mode: mode, bundleIdentifier: bundleIdentifier) else {
                self.isRestarting = false
                completion(.failure(.unsupportedMode))
                return
            }
            do {
                try self.intentStore.save(intent)
            } catch {
                AppLog.shared.warn("[OnboardingRestartCoordinator] restart intent save failed: \(AppLog.safeDescription(error))")
                self.isRestarting = false
                completion(.failure(.launchFailed))
                return
            }

            // 停止確認後にだけ旧オンボーディングを隠す。後継の起動はhelperだけが行う。
            suspendOnboardingWindow()
            guard self.launchHelper(intent: intent) else {
                self.intentStore.recordHelperFailure(.helperUnavailable, for: intent)
                self.isRestarting = false
                restoreOnboardingWindowAfterFailure()
                completion(.failure(.launchFailed))
                return
            }
            completion(.success(()))
            // AppDelegateの単一終了state machineを必ず通す。
            NSApp.terminate(nil)
        }
    }

    private func launchHelper(intent: OnboardingRestartIntent) -> Bool {
        guard let sourcePID = intent.sourceProcessIdentifier,
              let generation = intent.generation,
              let createdAt = intent.createdAt,
              let expiresAt = intent.expiresAt,
              OnboardingRestartHandoff.validatesHelperInvocation(
                  intent: intent,
                  bundleIdentifier: intent.bundleIdentifier,
                  sourcePID: sourcePID,
                  generation: generation,
                  createdAt: createdAt,
                  expiresAt: expiresAt
              ) else {
            return false
        }
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/KoedexRelaunchHelper", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [
            "--bundle-id", intent.bundleIdentifier,
            "--source-pid", String(sourcePID),
            "--generation", generation.uuidString,
            "--created-at", String(createdAt.timeIntervalSince1970),
            "--expires-at", String(expiresAt.timeIntervalSince1970),
            "--intent-path", OnboardingRuntimeProfile.restartIntentURL.path,
        ]
        do {
            try process.run()
            return true
        } catch {
            AppLog.shared.warn("[OnboardingRestartCoordinator] helper launch failed: \(AppLog.safeDescription(error))")
            return false
        }
    }

    private func waitForPreparation(
        _ preparation: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = RestartPreparationGate()
            Task { @MainActor in
                gate.resolve(await preparation(), continuation: continuation)
            }
            Task {
                do {
                    try await Task.sleep(nanoseconds: preparationTimeoutNanoseconds)
                    gate.resolve(false, continuation: continuation)
                } catch {
                    // 再起動要求自体の完了を優先する。preparation側が先にresolveしている。
                }
            }
        }
    }
}
