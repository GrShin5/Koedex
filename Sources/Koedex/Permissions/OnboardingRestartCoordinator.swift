import AppKit
import Combine
import Foundation

/// 権限反映のために終了した後、次回起動で一度だけ復帰するオンボーディング表示先。
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

    init?(
        mode: OnboardingPresentationMode,
        step: OnboardingStep,
        bundleIdentifier: String
    ) {
        guard let route = mode.restartRoute else { return nil }
        self.route = route
        self.step = step
        self.bundleIdentifier = bundleIdentifier
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

enum OnboardingRestartIntentFilePolicy {
    static func isOrphanedClaim(
        _ candidate: URL,
        canonicalURL: URL,
        isDirectory: Bool = false
    ) -> Bool {
        let canonicalParent = canonicalURL.deletingLastPathComponent().standardizedFileURL
        let candidateParent = candidate.deletingLastPathComponent().standardizedFileURL
        let prefix = "\(canonicalURL.lastPathComponent).claim-"
        return candidate.isFileURL
            && !isDirectory
            && candidateParent == canonicalParent
            && candidate.lastPathComponent.hasPrefix(prefix)
    }
}

/// 次回起動の復帰位置を読み書きする小さなストア。
/// 壊れた内容・別アプリ用の内容は再利用しない。
final class OnboardingRestartIntentStore {
    private let canonicalFileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        canonicalFileURL = fileURL ?? OnboardingRuntimeProfile.restartIntentURL
        self.fileManager = fileManager
    }

    func save(_ intent: OnboardingRestartIntent) throws {
        // セットアップ中はこの経路がストレージルートを最初に作ることがある。
        // ここで0700にしておかないと、次回起動の是正までルートが0755のまま残る。
        StoragePermissions.ensureDirectory(at: canonicalFileURL.deletingLastPathComponent())
        let data = try encoder.encode(intent)
        try data.write(to: canonicalFileURL, options: .atomic)
        StoragePermissions.applyFileMode(to: canonicalFileURL)
    }

    func load(bundleIdentifier: String) -> OnboardingRestartIntent? {
        guard fileManager.fileExists(atPath: canonicalFileURL.path) else { return nil }
        do {
            let intent = try decoder.decode(
                OnboardingRestartIntent.self,
                from: Data(contentsOf: canonicalFileURL)
            )
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
        try? fileManager.removeItem(at: canonicalFileURL)
    }

    func cleanupOrphanedClaims() {
        let directoryURL = canonicalFileURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            AppLog.shared.warn(
                "[OnboardingRestartIntentStore] orphan cleanup enumeration failed: \(AppLog.safeDescription(error))"
            )
            return
        }
        for child in children {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  OnboardingRestartIntentFilePolicy.isOrphanedClaim(
                      child,
                      canonicalURL: canonicalFileURL,
                      isDirectory: isDirectory.boolValue
                  ) else { continue }
            do {
                try fileManager.removeItem(at: child)
            } catch {
                AppLog.shared.warn(
                    "[OnboardingRestartIntentStore] orphan cleanup remove failed: \(AppLog.safeDescription(error))"
                )
            }
        }
    }
}

enum OnboardingRestartError: LocalizedError, Equatable {
    case unsupportedMode
    case applicationBundleUnavailable
    case interactiveChecksDidNotStop
    case intentSaveFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedMode:
            return "この画面では終了後の再開位置を保存できません。"
        case .applicationBundleUnavailable:
            return "アプリ本体の情報を確認できないため、Koedexを終了できませんでした。"
        case .interactiveChecksDidNotStop:
            return "録音やキー確認の停止を確認できないため、終了を中止しました。少し待ってから、もう一度試してください。"
        case .intentSaveFailed:
            return "再開位置を保存できないため、Koedexを終了できませんでした。"
        }
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
    static func permitsRestart(isQuitting: Bool) -> Bool { !isQuitting }
}

/// 再開位置を保存し、対話的な確認を停止してから現在のプロセスを終了する。
@MainActor
final class OnboardingRestartCoordinator: ObservableObject {
    @Published private(set) var isQuitting = false

    private let intentStore: OnboardingRestartIntentStore
    private let preparationTimeoutNanoseconds: UInt64

    init(
        intentStore: OnboardingRestartIntentStore = OnboardingRestartIntentStore(),
        preparationTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.intentStore = intentStore
        self.preparationTimeoutNanoseconds = preparationTimeoutNanoseconds
    }

    func quitAndResumeOnNextLaunch(
        mode: OnboardingPresentationMode,
        step: OnboardingStep,
        settingsStore: SettingsStore,
        prepareForQuit: @escaping @MainActor () async -> Bool,
        suspendOnboardingWindow: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (OnboardingRestartError) -> Void
    ) {
        guard OnboardingRestartRequestPolicy.permitsRestart(isQuitting: isQuitting) else { return }
        guard mode.restartRoute != nil else {
            onFailure(.unsupportedMode)
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            onFailure(.applicationBundleUnavailable)
            return
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        guard !bundleIdentifier.isEmpty else {
            onFailure(.applicationBundleUnavailable)
            return
        }

        isQuitting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.waitForPreparation(prepareForQuit) else {
                self.isQuitting = false
                onFailure(.interactiveChecksDidNotStop)
                return
            }

            settingsStore.flushPendingSave()
            guard let intent = OnboardingRestartIntent(
                mode: mode,
                step: step,
                bundleIdentifier: bundleIdentifier
            ) else {
                self.isQuitting = false
                onFailure(.unsupportedMode)
                return
            }
            do {
                try self.intentStore.save(intent)
            } catch {
                AppLog.shared.warn("[OnboardingRestartCoordinator] restart intent save failed: \(AppLog.safeDescription(error))")
                self.isQuitting = false
                onFailure(.intentSaveFailed)
                return
            }

            suspendOnboardingWindow()
            // AppKitが`.terminateLater`でreplyを待っても、reply側のMainActor Taskが
            // 起動できるよう、現在のMainActor jobが終わった後に終了を要求する。
            DispatchQueue.main.async {
                NSApp.terminate(nil)
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
                    // 終了要求自体の完了を優先する。preparation側が先にresolveしている。
                }
            }
        }
    }
}
