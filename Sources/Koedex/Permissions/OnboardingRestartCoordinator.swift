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

    let route: Route
    let step: OnboardingStep
    let bundleIdentifier: String
    /// 後継プロセスが旧プロセスの終了を確認してからUIを表示するための情報。
    /// 旧版が書いたintentも読めるようoptionalにしている。
    let sourceProcessIdentifier: Int32?
    let generation: UUID?

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
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                return
            }
        }
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

/// 新しい.appの起動成功を確認してから、現在のプロセスを終了する。
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
        guard !isRestarting else { return }
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

            // 停止確認後にだけ旧オンボーディングを隠す。起動失敗時は同じ画面を戻せる。
            suspendOnboardingWindow()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isRestarting = false
                    guard application != nil, error == nil else {
                        if let error {
                            AppLog.shared.warn("[OnboardingRestartCoordinator] application relaunch failed: \(AppLog.safeDescription(error))")
                        }
                        self.intentStore.clear()
                        restoreOnboardingWindowAfterFailure()
                        completion(.failure(.launchFailed))
                        return
                    }
                    completion(.success(()))
                    NSApp.terminate(nil)
                }
            }
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
