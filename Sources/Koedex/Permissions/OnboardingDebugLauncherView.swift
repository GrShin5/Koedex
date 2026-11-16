import SwiftUI
import AppKit

/// `Koedex Debug.app` の入口。通常アプリのメニューバー処理・Codex接続を起動せず、
/// 初回セットアップだけを安全に確認できる。
struct OnboardingDebugLauncherView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var presentation: OnboardingDebugPresentationState
    @StateObject private var permissionResetController = DebugPermissionResetController()
    @State private var showsPermissionResetConfirmation = false
    @State private var showsFreshSetupResetConfirmation = false

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
            switch presentation.mode {
            case .debugPreview:
                OnboardingDebugPreviewHost(settingsStore: settingsStore, screenshotMode: presentation.screenshotMode) {
                    presentation.mode = nil
                }
            case .debugRehearsal:
                OnboardingDebugRehearsalHost(settingsStore: settingsStore, screenshotMode: presentation.screenshotMode) {
                    presentation.mode = nil
                }
            default:
                launcher
            }
        }
        .frame(
            minWidth: OnboardingUIScaleMetrics.minimumWindowSize.width,
            minHeight: OnboardingUIScaleMetrics.minimumWindowSize.height
        )
        .background(OnboardingDebugWindowAppearance(
            screenshotMode: presentation.screenshotMode && presentation.mode?.isDebug == true,
            title: presentation.screenshotMode && presentation.mode?.isDebug == true
                ? OnboardingPresentationMode.firstRun.title(for: uiLanguage) : uiText("Koedex Debug")
        ))
        .onboardingUIScale(uiMetrics)
        .dynamicTypeSize(.xxLarge)
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
        // 隣のボタンとラベル前半が似ているうえ、こちらは辞書・ショートカット・
        // 保持日数まで含めて捨てる。取り違えたまま実行させない。
        .sheet(isPresented: $showsFreshSetupResetConfirmation) {
            AppConfirmationSheet(
                title: uiText("Debug設定を新規インストール直後に戻しますか？"),
                message: uiText("このDebug.appの隔離された設定を全て初期化します。言語、ユーザー辞書、ショートカット、履歴の保持日数、Codexの設定も戻ります。本番Koedexの設定・履歴・辞書には触れません。"),
                confirmTitle: uiText("初期化"),
                confirmRole: .destructive,
                metrics: PopupUIScaleMetrics(settingsMetrics: SettingsUIScaleMetrics(
                    scale: SettingsUIScaleMetrics.standardScale,
                    language: uiLanguage
                )),
                onConfirm: {
                    guard settingsStore.canSave else { return }
                    settingsStore.settings = DebugFreshSetupResetPolicy.freshSettings()
                    settingsStore.flushPendingSave()
                },
                onCancel: {}
            )
        }
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
                action: { presentation.mode = .debugPreview }
            )
            debugModeCard(
                title: uiText("このMacで確認"),
                detail: uiText("このDebug.appの権限、マイク、グローバルショートカットを使って確認します。録音結果は画面だけに表示し、Codex処理・Web検索・クリップボード読取・履歴保存は行いません。"),
                buttonTitle: uiText("実機確認を開く"),
                action: { presentation.mode = .debugRehearsal }
            )

            Toggle(uiText("撮影用表示（本番と同じ見た目）"), isOn: $presentation.screenshotMode)
            Text(uiText("オンにしてからプレビューまたは実機確認を開くと、Debug用の表示を隠し、本番と同じ見た目で表示します。設定には保存されません。マイク確認は ⌘⇧V で「音声あり」にでき、⌘⇧D でDebugメニューへ戻れます。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                Text(uiText("セットアップ状態のリセットは進捗だけを初期化します。macOSの権限は変更しません。言語選択画面から確認したい場合は「Debug設定を新規インストール直後に戻す」を使ってください。"))
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

            // 未完了のまま実値を並べると、まだ選んでいない既定値を「選んだ結果」として
            // 読ませてしまう。確認したいのは選択後の値なので、完了時だけ出す。
            if settingsStore.settings.setupProgress.isComplete {
                Label(
                    uiText("Debug用のセットアップは完了状態です。「Debug設定を新規インストール直後に戻す」を押すと、言語選択から確認し直せます。"),
                    systemImage: "checkmark.circle"
                )
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.green)
                confirmationPanel
            } else {
                Text(uiText("まだ完了していません。プレビューまたは実機確認から、初回セットアップを開始してください。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
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
            // 進捗だけのリセットでは言語選択が済んだ状態が残るため、言語選択画面から
            // 確認したい場合はこちらを使う。Debug.appの保存先だけを初期化する。
            Button(uiText("Debug設定を新規インストール直後に戻す")) {
                showsFreshSetupResetConfirmation = true
            }
            .disabled(!settingsStore.canSave)
            Button(uiText("Debug権限をリセット")) {
                showsPermissionResetConfirmation = true
            }
            .disabled(permissionResetController.isResetting)
            Button(uiText("Debug.appを終了")) { NSApp.terminate(nil) }
        }
    }

    /// 隔離された保存先に実際に入っている値を、そのまま読める形で見せる。
    /// 言語選択の結果を実機で確かめるには、選んだ後の保存値を確認できる必要がある。
    private var confirmationPanel: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            Label(uiText("隔離された設定値の確認"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(uiMetrics.font(.headline))
            settingRow(
                uiText("表示言語"),
                settingsStore.settings.languagePreferences.uiLanguage.localizedDisplayName(for: uiLanguage)
            )
            settingRow(
                uiText("音声認識言語"),
                settingsStore.settings.languagePreferences.sttLanguage.localizedDisplayName(for: uiLanguage)
            )
            settingRow(
                uiText("AI出力言語"),
                settingsStore.settings.languagePreferences.aiOutputLanguage.localizedDisplayName(for: uiLanguage)
            )
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
            settingRow(uiText("高速モード"), fastTierSummary)
            settingRow(uiText("短い発話の即入力"), uiText(settingsStore.settings.shortUtteranceInstantInsertEnabled ? "オン" : "オフ"))
        }
        .padding(uiMetrics.layout(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var fastTierSummary: String {
        switch settingsStore.settings.fastTierAllModesState {
        case .allOn: return uiText("高速モード状態: すべてオン")
        case .allOff: return uiText("高速モード状態: すべてオフ")
        case .mixed: return uiText("モードごとに設定中")
        }
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

    var bundleIdentifier: String {
        switch self {
        case .onboarding: return OnboardingRuntimeProfile.debugBundleIdentifier
        }
    }

    var displayNameKey: String {
        switch self {
        case .onboarding: return "Koedex Debug"
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
    let screenshotMode: Bool
    let onClose: () -> Void
    @StateObject private var permissionManager = PermissionManager(simulatedStates: .initial)

    var body: some View {
        OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: .debugPreview,
            forcedInitialStep: nil,
            onForcedInitialStepPresented: nil,
            onQuitPreparationCompleted: hideDebugWindowForQuit,
            onFinish: onClose,
            screenshotMode: screenshotMode
        )
    }

    private func hideDebugWindowForQuit() {
        NSApp.mainWindow?.orderOut(nil)
    }
}

private struct OnboardingDebugRehearsalHost: View {
    @ObservedObject var settingsStore: SettingsStore
    let screenshotMode: Bool
    let onClose: () -> Void
    @StateObject private var permissionManager = PermissionManager()

    var body: some View {
        OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: .debugRehearsal,
            forcedInitialStep: nil,
            onForcedInitialStepPresented: nil,
            onQuitPreparationCompleted: hideDebugWindowForQuit,
            onFinish: onClose,
            screenshotMode: screenshotMode
        )
        .onAppear {
            permissionManager.refresh()
            permissionManager.startPolling()
        }
        .onDisappear {
            permissionManager.stopPolling()
        }
    }

    private func hideDebugWindowForQuit() {
        NSApp.mainWindow?.orderOut(nil)
    }
}

@MainActor
final class OnboardingDebugPresentationState: ObservableObject {
    @Published var screenshotMode = false
    @Published var mode: OnboardingPresentationMode?
}

struct OnboardingSimulateVoiceKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var onboardingSimulateVoice: (() -> Void)? {
        get { self[OnboardingSimulateVoiceKey.self] }
        set { self[OnboardingSimulateVoiceKey.self] = newValue }
    }
}

private struct OnboardingDebugWindowAppearance: NSViewRepresentable {
    let screenshotMode: Bool
    let title: String

    final class WindowView: NSView {
        var screenshotMode = false
        var windowTitle = ""
        private weak var appearanceWindow: NSWindow?
        private var original: (fullSizeContentView: Bool, titleVisibility: NSWindow.TitleVisibility, transparent: Bool)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func restore() {
            guard let window = appearanceWindow, let saved = original,
                  !window.styleMask.contains(.fullScreen) else { return }
            if saved.fullSizeContentView && !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.titleVisibility != saved.titleVisibility {
                window.titleVisibility = saved.titleVisibility
            }
            if window.titlebarAppearsTransparent != saved.transparent {
                window.titlebarAppearsTransparent = saved.transparent
            }
            original = nil
            appearanceWindow = nil
        }

        func apply() {
            if appearanceWindow !== window { restore() }
            guard let window else { return }
            if window.title != windowTitle { window.title = windowTitle }
            guard !window.styleMask.contains(.fullScreen) else { return }
            if screenshotMode {
                if original == nil {
                    appearanceWindow = window
                    original = (window.styleMask.contains(.fullSizeContentView), window.titleVisibility, window.titlebarAppearsTransparent)
                }
                if window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.remove(.fullSizeContentView)
                }
                if window.titleVisibility != .visible { window.titleVisibility = .visible }
                if window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = false }
            } else {
                restore()
            }
        }
    }

    static func dismantleNSView(_ view: WindowView, coordinator: ()) {
        view.restore()
    }

    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        view.screenshotMode = screenshotMode
        view.windowTitle = title
        view.apply()
    }
}
