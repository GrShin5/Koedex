import SwiftUI
import AppKit

/// `Koedex Debug.app` の入口。通常アプリのメニューバー処理・Codex接続を起動せず、
/// 初回セットアップだけを安全に確認できる。
struct OnboardingDebugLauncherView: View {
    private enum Destination {
        case preview
        case rehearsal
    }

    @ObservedObject var settingsStore: SettingsStore
    @State private var destination: Destination?
    @State private var restartIntent: OnboardingRestartIntent?
    @State private var isWaitingForRestartHandoff = false
    @State private var restartHandoffTask: Task<Void, Never>?
    @StateObject private var permissionResetController = DebugPermissionResetController()
    @State private var showsPermissionResetConfirmation = false
    private let restartIntentStore = OnboardingRestartIntentStore()

    private var uiLanguage: AppLanguage {
        settingsStore.settings.languagePreferences.uiLanguage
    }

    private var uiMetrics: OnboardingUIScaleMetrics {
        OnboardingUIScaleMetrics(language: uiLanguage)
    }

    private func uiText(_ japanese: String) -> String {
        AppLocalizer.text(japanese, language: uiLanguage)
    }

    var body: some View {
        Group {
            switch destination {
            case .preview:
                OnboardingDebugPreviewHost(
                    settingsStore: settingsStore,
                    forcedInitialStep: restartIntent?.step,
                    onForcedInitialStepPresented: clearRestartIntent
                ) {
                    destination = nil
                    restartIntent = nil
                }
            case .rehearsal:
                OnboardingDebugRehearsalHost(
                    settingsStore: settingsStore,
                    forcedInitialStep: restartIntent?.step,
                    onForcedInitialStepPresented: clearRestartIntent
                ) {
                    destination = nil
                    restartIntent = nil
                }
            case nil:
                if isWaitingForRestartHandoff {
                    restartHandoffView
                } else {
                    launcher
                }
            }
        }
        .frame(
            minWidth: OnboardingUIScaleMetrics.minimumWindowSize.width,
            minHeight: OnboardingUIScaleMetrics.minimumWindowSize.height
        )
        .onboardingUIScale(uiMetrics)
        .dynamicTypeSize(.xxLarge)
        .onAppear {
            restoreRestartIntentIfNeeded()
        }
        .environment(\.locale, uiLanguage.locale)
        .sheet(isPresented: $showsPermissionResetConfirmation) {
            AppConfirmationSheet(
                title: uiText("Debug.appの権限をリセットしますか？"),
                message: uiText("Koedex Debugだけのマイク・音声認識・アクセシビリティなどのmacOS権限を初期化します。本番Koedexの権限・設定・履歴には触れません。完了後はDebug.appを終了して開き直してください。"),
                confirmTitle: uiText("リセット"),
                confirmRole: .destructive,
                metrics: PopupUIScaleMetrics(settingsMetrics: SettingsUIScaleMetrics(
                    scale: SettingsUIScaleMetrics.standardScale,
                    language: uiLanguage
                )),
                onConfirm: { permissionResetController.resetPermissions() },
                onCancel: {}
            )
        }
    }

    private var restartHandoffView: some View {
        VStack(spacing: uiMetrics.layout(12)) {
            ProgressView()
            Text(uiText("アプリを再起動しています…"))
                .font(uiMetrics.font(.headline))
            Text(uiText("前のアプリが終了したら、権限の確認画面を自動で開きます。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(uiMetrics.layout(28))
    }

    private var launcher: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: uiMetrics.layout(18)) {
            Text(uiText("Koedex 初回セットアップ Debug"))
                .font(uiMetrics.font(.title))
                .bold()
            Text(uiText("本番のKoedexとは別の保存先を使います。ここで完了・リセットしても、本番の設定、履歴、辞書、ログ、Codex接続には影響しません。"))
                .foregroundStyle(.secondary)

            debugModeCard(
                title: uiText("画面をプレビュー"),
                detail: uiText("権限、マイク、ショートカットを疑似状態で切り替えます。TCCダイアログや実機器には触れません。"),
                buttonTitle: uiText("プレビューを開く"),
                action: { destination = .preview }
            )
            debugModeCard(
                title: uiText("このMacで確認"),
                detail: uiText("このDebug.appの権限、マイク、グローバルショートカットを使って確認します。録音結果は画面だけに表示し、Codex処理・Web検索・クリップボード読取・履歴保存は行いません。"),
                buttonTitle: uiText("実機確認を開く"),
                action: { destination = .rehearsal }
            )

            VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                Text(uiText("セットアップ状態のリセットは進捗だけを初期化します。macOSの権限は変更しません。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        resetButtons
                    }
                    VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                        resetButtons
                    }
                }
            }

            if let statusMessage = permissionResetController.statusMessage(language: uiLanguage) {
                Text(statusMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(permissionResetController.didSucceed ? .green : .orange)
            }

            if settingsStore.canSave == false {
                Label(
                    uiText("既存の設定を安全に読み込めなかったため、上書きを停止しています。設定ファイルは削除されていません。"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.orange)
            }

            if settingsStore.settings.setupProgress.isComplete {
                Label(uiText("Debug用のセットアップは完了状態です。リセットすると最初から確認できます。"), systemImage: "checkmark.circle")
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.green)
            }

            Spacer()
            Text(uiText("保存先: ~/Library/Application Support/Koedex Debug/"))
                .font(uiMetrics.font(.caption2))
                .foregroundStyle(.secondary)
        }
            .padding(uiMetrics.layout(28))
        }
    }

    private var resetButtons: some View {
        Group {
            Button(uiText("Debug用セットアップ状態をリセット")) {
                settingsStore.settings.setupProgress = .newInstall
                settingsStore.flushPendingSave()
            }
            .disabled(!settingsStore.canSave)
            Button(uiText("Debug権限をリセット")) {
                showsPermissionResetConfirmation = true
            }
            .disabled(permissionResetController.isResetting)
            Button(uiText("Debug.appを終了")) { NSApp.terminate(nil) }
        }
    }

    private func restoreRestartIntentIfNeeded() {
        guard destination == nil, restartHandoffTask == nil else { return }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        guard let intent = restartIntentStore.load(bundleIdentifier: bundleIdentifier) else { return }
        restartIntent = intent
        if OnboardingRestartHandoff.shouldWaitForSourceProcessExit(intent) {
            isWaitingForRestartHandoff = true
            restartHandoffTask = Task {
                await OnboardingRestartHandoff.waitForSourceProcessExit(intent)
                guard !Task.isCancelled else { return }
                isWaitingForRestartHandoff = false
                restartHandoffTask = nil
                presentRestartIntent(intent)
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.mainWindow ?? NSApp.windows.first)?.makeKeyAndOrderFront(nil)
            }
            return
        }
        presentRestartIntent(intent)
    }

    private func presentRestartIntent(_ intent: OnboardingRestartIntent) {
        switch intent.presentationMode {
        case .debugPreview:
            destination = .preview
        case .debugRehearsal:
            destination = .rehearsal
        case .firstRun, .upgrade, .permissionRecovery, .guide, .languageSetupPreview, .languageSetupRehearsal:
            restartIntentStore.clear()
            restartIntent = nil
        }
    }

    private func clearRestartIntent() {
        restartIntentStore.clear()
        restartIntent = nil
        restartHandoffTask?.cancel()
        restartHandoffTask = nil
        isWaitingForRestartHandoff = false
    }

    private func debugModeCard(
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            Text(title).font(uiMetrics.font(.headline))
            Text(detail).font(uiMetrics.font(.caption)).foregroundStyle(.secondary)
            Button(buttonTitle, action: action)
        }
        .padding(uiMetrics.layout(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 権限をリセットできる隔離Debug.appだけを明示する。
enum DebugPermissionResetTarget: CaseIterable {
    case onboarding
    case languageSetup

    var bundleIdentifier: String {
        switch self {
        case .onboarding: return OnboardingRuntimeProfile.debugBundleIdentifier
        case .languageSetup: return OnboardingRuntimeProfile.languageSetupDebugBundleIdentifier
        }
    }

    var displayNameKey: String {
        switch self {
        case .onboarding: return "Koedex Debug"
        case .languageSetup: return "Koedex Language Setup Debug"
        }
    }

    /// 通常版や任意のbundle IDへTCC resetを向けないための、テスト可能な許可リスト。
    static func isIsolatedDebugBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return allCases.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func permitsReset(from bundleIdentifier: String?) -> Bool {
        Self.isIsolatedDebugBundleIdentifier(bundleIdentifier)
            && bundleIdentifier == self.bundleIdentifier
    }
}

/// 許可済みの隔離Debug.appだけを対象にTCCの登録を初期化する補助。
/// 本番バンドルIDや任意の入力値を受け取らないため、通常版には作用しない。
@MainActor
final class DebugPermissionResetController: ObservableObject {
    private enum Status {
        case idle
        case resetting
        case succeeded
        case failed
        case launchFailed
        case denied
    }

    private let target: DebugPermissionResetTarget
    @Published private var status: Status = .idle
    @Published private(set) var isResetting = false
    @Published private(set) var didSucceed = false

    private var process: Process?

    init(target: DebugPermissionResetTarget = .onboarding) {
        self.target = target
    }

    func statusMessage(language: AppLanguage) -> String? {
        let appName = AppLocalizer.text(target.displayNameKey, language: language)
        switch status {
        case .idle:
            return nil
        case .resetting:
            return AppLocalizer.format("%@の権限をリセットしています…", language: language, appName)
        case .succeeded:
            return AppLocalizer.format("%@の権限をリセットしました。アプリを終了して開き直すと、macOSの許可ダイアログをもう一度確認できます。", language: language, appName)
        case .failed:
            return AppLocalizer.format("%@の権限をリセットできませんでした。macOSのシステム設定から確認してください。", language: language, appName)
        case .launchFailed:
            return AppLocalizer.format("%@の権限リセットを開始できませんでした。macOSのシステム設定から確認してください。", language: language, appName)
        case .denied:
            return AppLocalizer.text("許可されていないアプリでは権限リセットを実行できません。", language: language)
        }
    }

    func resetPermissions(onSuccess: @escaping @MainActor () -> Void = {}) {
        guard target.permitsReset(from: Bundle.main.bundleIdentifier) else {
            didSucceed = false
            status = .denied
            return
        }

        isResetting = true
        didSucceed = false
        status = .resetting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "All", target.bundleIdentifier]
        process.terminationHandler = { [weak self] completedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.isResetting = false
                self.didSucceed = completedProcess.terminationStatus == 0
                self.status = self.didSucceed ? .succeeded : .failed
                if self.didSucceed {
                    onSuccess()
                }
            }
        }

        do {
            self.process = process
            try process.run()
        } catch {
            self.process = nil
            isResetting = false
            didSucceed = false
            status = .launchFailed
        }
    }
}

private struct OnboardingDebugPreviewHost: View {
    @ObservedObject var settingsStore: SettingsStore
    let forcedInitialStep: OnboardingStep?
    let onForcedInitialStepPresented: (() -> Void)?
    let onClose: () -> Void
    @StateObject private var permissionManager = PermissionManager(simulatedStates: .initial)

    var body: some View {
        OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: .debugPreview,
            forcedInitialStep: forcedInitialStep,
            onForcedInitialStepPresented: onForcedInitialStepPresented,
            onRestartPreparationCompleted: hideDebugWindowForRestart,
            onRestartFailure: restoreDebugWindowAfterRestartFailure,
            onFinish: onClose
        )
    }

    private func hideDebugWindowForRestart() {
        NSApp.mainWindow?.orderOut(nil)
    }

    private func restoreDebugWindowAfterRestartFailure() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingDebugRehearsalHost: View {
    @ObservedObject var settingsStore: SettingsStore
    let forcedInitialStep: OnboardingStep?
    let onForcedInitialStepPresented: (() -> Void)?
    let onClose: () -> Void
    @StateObject private var permissionManager = PermissionManager()

    var body: some View {
        OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: .debugRehearsal,
            forcedInitialStep: forcedInitialStep,
            onForcedInitialStepPresented: onForcedInitialStepPresented,
            onRestartPreparationCompleted: hideDebugWindowForRestart,
            onRestartFailure: restoreDebugWindowAfterRestartFailure,
            onFinish: onClose
        )
        .onAppear {
            permissionManager.refresh()
            permissionManager.startPolling()
        }
        .onDisappear {
            permissionManager.stopPolling()
        }
    }

    private func hideDebugWindowForRestart() {
        NSApp.mainWindow?.orderOut(nil)
    }

    private func restoreDebugWindowAfterRestartFailure() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}
