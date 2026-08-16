import AppKit
import SwiftUI

/// 初回セットアップを本番保存先と完全に分離して確認するための専用Debug.app入口。
/// Codex接続・履歴本文保存・辞書・通常Debugの設定画面は起動しない。
struct LanguageSetupDebugLauncherView: View {
    private enum Destination {
        case preview
        case rehearsal
    }

    @ObservedObject var settingsStore: SettingsStore
    @State private var destination: Destination?
    @State private var restartIntent: OnboardingRestartIntent?
    @State private var isWaitingForRestartHandoff = false
    @State private var restartHandoffTask: Task<Void, Never>?
    @StateObject private var permissionResetController = DebugPermissionResetController(target: .languageSetup)
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
                LanguageSetupPreviewHost(
                    settingsStore: settingsStore,
                    forcedInitialStep: restartIntent?.step,
                    onForcedInitialStepPresented: clearRestartIntent
                ) {
                    destination = nil
                    restartIntent = nil
                }
            case .rehearsal:
                LanguageSetupRehearsalHost(
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
        .environment(\.locale, uiLanguage.locale)
        .onAppear {
            restoreRestartIntentIfNeeded()
        }
        .sheet(isPresented: $showsPermissionResetConfirmation) {
            AppConfirmationSheet(
                title: uiText("権限と初回テスト状態をリセットしますか？"),
                message: uiText("Koedex Language Setup Debugだけのマイク・音声認識・アクセシビリティなどのmacOS権限と、隔離されたDebug設定・初回セットアップ状態を初期化します。本番Koedex、既存Debug.app、通常の履歴・辞書・設定には触れません。完了後はこのDebug.appを終了します。"),
                confirmTitle: uiText("リセット"),
                confirmRole: .destructive,
                metrics: PopupUIScaleMetrics(settingsMetrics: SettingsUIScaleMetrics(
                    scale: SettingsUIScaleMetrics.standardScale,
                    language: uiLanguage
                )),
                onConfirm: {
                    permissionResetController.resetPermissions {
                        resetFirstRunState()
                        NSApp.terminate(nil)
                    }
                },
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
            Text(uiText("言語セットアップ Debug"))
                .font(uiMetrics.font(.title))
                .bold()
            Text(uiText("初回セットアップの言語と履歴保存方針を、本番とは別の保存先で確認します。"))
                .foregroundStyle(.secondary)
            if !settingsStore.settings.languagePreferences.hasCompletedInitialLanguageSelection {
                Text(uiText("本番アプリとは別の保存先で、初回の言語と履歴保存方針を確認できます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
            }

            if settingsStore.settings.setupProgress.isComplete {
                confirmationPanel
            } else {
                Text(uiText("まだ完了していません。プレビューまたは実機確認から、初回セットアップを開始してください。"))
                    .foregroundStyle(.secondary)
            }

            languageSetupCard(
                title: uiText("画面をプレビュー"),
                detail: uiText("言語と履歴保存方針を含む初回セットアップを、権限・マイク・ショートカットの疑似状態で確認します。macOSの権限や本番データには触れません。"),
                buttonTitle: uiText("プレビューを開く")
            ) {
                resetFirstRunStateIfNeeded()
                destination = .preview
            }
            languageSetupCard(
                title: uiText("このMacで確認"),
                detail: uiText("この専用Debug.appの権限・マイク・グローバルショートカットだけを使います。Codex接続、Web検索、クリップボード読取、履歴本文の保存、本番設定には触れません。"),
                buttonTitle: uiText("実機確認を開く")
            ) {
                resetFirstRunStateIfNeeded()
                destination = .rehearsal
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    resetButtons
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    resetButtons
                }
            }

            if let statusMessage = permissionResetController.statusMessage(language: uiLanguage) {
                Text(statusMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(permissionResetController.didSucceed ? .green : .orange)
            }

            Text("~/Library/Application Support/Koedex Language Setup Debug/")
                .font(uiMetrics.font(.caption2))
                .foregroundStyle(.secondary)
        }
            .padding(uiMetrics.layout(28))
        }
    }

    private var resetButtons: some View {
        Group {
            Button(uiText("権限と初回テスト状態をリセット")) {
                showsPermissionResetConfirmation = true
            }
            .disabled(!settingsStore.canSave || permissionResetController.isResetting)
            Button(uiText("言語セットアップ Debug.appを終了")) {
                NSApp.terminate(nil)
            }
        }
    }

    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            Label(uiText("隔離された設定値の確認"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(uiMetrics.font(.headline))
            settingRow(uiText("表示言語"), settingsStore.settings.languagePreferences.uiLanguage.localizedDisplayName(for: uiLanguage))
            settingRow(uiText("音声認識言語"), settingsStore.settings.languagePreferences.sttLanguage.localizedDisplayName(for: uiLanguage))
            settingRow(uiText("AI出力言語"), settingsStore.settings.languagePreferences.aiOutputLanguage.localizedDisplayName(for: uiLanguage))
            settingRow(
                uiText("通常モードの出力履歴"),
                historyRetentionLabel(
                    isEnabled: settingsStore.settings.historyEnabled,
                    retentionDays: settingsStore.settings.historyRetentionDays
                )
            )
            settingRow(
                uiText("ハンズフリー送信モードの出力履歴"),
                historyRetentionLabel(
                    isEnabled: settingsStore.settings.handsFreeSendSettings.historyEnabled,
                    retentionDays: settingsStore.settings.handsFreeSendSettings.historyRetentionDays
                )
            )
            settingRow(
                uiText("AIに指示モードの入力履歴"),
                historyRetentionLabel(
                    isEnabled: settingsStore.settings.aiCommandSettings.historyEnabled,
                    retentionDays: settingsStore.settings.aiCommandSettings.historyRetentionDays
                )
            )
        }
        .padding(uiMetrics.layout(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(uiMetrics.font(.caption))
    }

    private func historyRetentionLabel(isEnabled: Bool, retentionDays: Int) -> String {
        guard isEnabled else { return uiText("保存しない") }
        switch retentionDays {
        case 1:
            return uiText("1日")
        case 30:
            return uiText("30日")
        case 180:
            return uiText("180日")
        default:
            return uiText("無期限")
        }
    }

    private func languageSetupCard(
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

    private func resetFirstRunStateIfNeeded() {
        if settingsStore.settings.setupProgress.isComplete {
            resetFirstRunState()
        }
    }

    private func resetFirstRunState() {
        guard settingsStore.canSave else { return }
        settingsStore.settings = LanguageSetupDebugResetPolicy.freshSettings()
        settingsStore.flushPendingSave()
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
        case .languageSetupPreview:
            destination = .preview
        case .languageSetupRehearsal:
            destination = .rehearsal
        case .firstRun, .upgrade, .permissionRecovery, .guide, .debugPreview, .debugRehearsal:
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
}

private struct LanguageSetupPreviewHost: View {
    @ObservedObject var settingsStore: SettingsStore
    let forcedInitialStep: OnboardingStep?
    let onForcedInitialStepPresented: (() -> Void)?
    let onClose: () -> Void
    @StateObject private var permissionManager = PermissionManager(simulatedStates: .initial)

    var body: some View {
        OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: .languageSetupPreview,
            forcedInitialStep: forcedInitialStep,
            onForcedInitialStepPresented: onForcedInitialStepPresented,
            onRestartPreparationCompleted: { NSApp.mainWindow?.orderOut(nil) },
            onRestartFailure: restoreWindow,
            onFinish: onClose
        )
    }

    private func restoreWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct LanguageSetupRehearsalHost: View {
    @ObservedObject var settingsStore: SettingsStore
    let forcedInitialStep: OnboardingStep?
    let onForcedInitialStepPresented: (() -> Void)?
    let onClose: () -> Void
    @StateObject private var permissionManager = PermissionManager()

    var body: some View {
        OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: .languageSetupRehearsal,
            forcedInitialStep: forcedInitialStep,
            onForcedInitialStepPresented: onForcedInitialStepPresented,
            onRestartPreparationCompleted: { NSApp.mainWindow?.orderOut(nil) },
            onRestartFailure: restoreWindow,
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

    private func restoreWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }
}
