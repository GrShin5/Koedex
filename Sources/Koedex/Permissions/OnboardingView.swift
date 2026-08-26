import SwiftUI
import AppKit

/// 未完了または権限未解決の時だけ、メニューバーからセットアップ再開を案内する。
enum OnboardingResumePolicy {
    static func shouldOfferResume(allPermissionsGranted: Bool, setupIsComplete: Bool) -> Bool {
        !allPermissionsGranted || !setupIsComplete
    }
}

private extension Notification.Name {
    static let onboardingWindowWillClose = Notification.Name("com.koedex.onboarding.windowWillClose")
}

enum OnboardingVoiceGuideCopy {
    static let toggleKey = "ショートカットを押すと録音を始め、もう一度押すと終了します。現在のキーは %@ です。"
    static let holdKey = "ショートカットを押している間だけ録音し、離すと終了します。現在のキーは %@ です。"

    static func instruction(
        recordingMode: RecordingMode,
        hotkeyName: String,
        language: AppLanguage
    ) -> String {
        let key = recordingMode == .hold ? holdKey : toggleKey
        return AppLocalizer.format(key, language: language, hotkeyName)
    }
}

/// 初回セットアップ、アップグレード、任意ガイド、Debug.appで共用する導線。
/// 通常の音声入力と「AIに指示」を別々に説明し、失敗しても先へ進める練習を最後に置く。
struct OnboardingView: View {
    private enum ShortcutTarget {
        case normal
        case aiStart
        case aiStop
    }

    @ObservedObject var permissionManager: PermissionManager
    @ObservedObject var settingsStore: SettingsStore
    let mode: OnboardingPresentationMode
    let forcedInitialStep: OnboardingStep?
    let initialRestartFeedback: String?
    let onForcedInitialStepPresented: (() -> Void)?
    let onRestartPreparationCompleted: () -> Void
    let onRestartFailure: () -> Void
    let onFinish: () -> Void

    @StateObject private var microphoneProbe = MicrophoneLevelProbe()
    @StateObject private var practiceController: OnboardingPracticeController
    @StateObject private var shortcutCapture = HotkeyCaptureMonitor()
    @StateObject private var restartCoordinator = OnboardingRestartCoordinator()
    @State private var currentStepIndex = 0
    @State private var activeShortcutTarget: ShortcutTarget?
    @State private var normalShortcutCandidate: HotkeyBinding?
    @State private var aiStartShortcutCandidate: HotkeyBinding?
    @State private var aiStopShortcutCandidate: HotkeyBinding?
    @State private var normalShortcutMessage: String?
    @State private var aiStartShortcutMessage: String?
    @State private var aiStopShortcutMessage: String?
    @State private var normalShortcutState = OnboardingShortcutSetupState()
    @State private var aiStartShortcutState = OnboardingShortcutSetupState()
    @State private var aiStopShortcutState = OnboardingShortcutSetupState()
    @State private var selectedMicrophoneUID = ""
    @State private var microphoneCheckState: OnboardingMicrophoneCheckState = .idle
    @State private var microphoneCheckGeneration = UUID()
    @State private var microphoneProbeOperation: Task<Void, Never>?
    @State private var appRestartFeedback: String?
    @State private var didAcknowledgeForcedInitialStep = false
    @State private var hasMoreScrollableContent = false
    @State private var clipboardVariantOnboardingMessage: String?

    private var uiLanguage: AppLanguage {
        settingsStore.settings.languagePreferences.uiLanguage
    }

    /// 日英併記の最初の選択画面は既存倍率を保ち、選択後の英語画面だけを125%にする。
    private var uiMetrics: OnboardingUIScaleMetrics {
        currentStep == .language
            ? .standard
            : OnboardingUIScaleMetrics(language: uiLanguage)
    }

    private func uiText(_ japanese: String) -> String {
        AppLocalizer.text(japanese, language: uiLanguage)
    }

    private func uiFormat(_ japanese: String, _ arguments: CVarArg...) -> String {
        String(format: uiText(japanese), locale: uiLanguage.locale, arguments: arguments)
    }

    init(
        permissionManager: PermissionManager,
        settingsStore: SettingsStore,
        mode: OnboardingPresentationMode,
        forcedInitialStep: OnboardingStep?,
        initialRestartFeedback: String? = nil,
        onForcedInitialStepPresented: (() -> Void)?,
        onRestartPreparationCompleted: @escaping () -> Void,
        onRestartFailure: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        practiceTranscriptionEngine: TranscriptionEngine? = nil
    ) {
        self.permissionManager = permissionManager
        self.settingsStore = settingsStore
        self.mode = mode
        self.forcedInitialStep = forcedInitialStep
        self.initialRestartFeedback = initialRestartFeedback
        self.onForcedInitialStepPresented = onForcedInitialStepPresented
        self.onRestartPreparationCompleted = onRestartPreparationCompleted
        self.onRestartFailure = onRestartFailure
        self.onFinish = onFinish
        _practiceController = StateObject(
            wrappedValue: OnboardingPracticeController(
                transcriptionEngine: practiceTranscriptionEngine ?? TranscriptionEngine()
            )
        )
        _appRestartFeedback = State(initialValue: initialRestartFeedback.map {
            AppLocalizer.text($0, language: settingsStore.settings.languagePreferences.uiLanguage)
        })
    }

    private var steps: [OnboardingStep] {
        OnboardingFlow.steps(
            mode: mode,
            progress: settingsStore.settings.setupProgress,
            allPermissionsGranted: permissionManager.allGranted(),
            hasCompletedInitialLanguageSelection: settingsStore.settings.languagePreferences.hasCompletedInitialLanguageSelection,
            forcedInitialStep: forcedInitialStep
        )
    }

    private var currentStep: OnboardingStep {
        steps[min(currentStepIndex, steps.count - 1)]
    }

    private var normalShortcutIsConfirmed: Bool {
        normalShortcutState.isReady
    }

    private var aiStartShortcutIsConfirmed: Bool {
        aiStartShortcutState.isReady
    }

    private var aiStopShortcutIsConfirmed: Bool {
        aiStopShortcutState.isReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(18)) {
            header

            if settingsStore.canSave == false {
                Label(
                    uiText("既存の設定を安全に読み込めなかったため、上書きを停止しています。設定ファイルは削除されていません。"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            if mode.isDebug {
                Label(
                    mode.isPreview
                        ? uiText("プレビューは権限・マイク・ショートカットを疑似表示します。本番データには触れません。")
                        : uiText("実機確認ではこのDebug.appの権限・マイク・グローバルキーだけを使います。録音結果は保存・送信しません。"),
                    systemImage: "ladybug.fill"
                )
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.purple)
            }

            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let overflow = geometry.contentSize.height - geometry.containerSize.height
                return overflow > 1
                    && geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
            } action: { _, hasMoreContent in
                hasMoreScrollableContent = hasMoreContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if currentStep != .language && hasMoreScrollableContent {
                    VStack(spacing: uiMetrics.layout(2)) {
                        LinearGradient(
                            colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.94)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: uiMetrics.layout(28))
                        Label(uiText("下に設定が続きます"), systemImage: "chevron.down")
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, uiMetrics.layout(4))
                    }
                    .allowsHitTesting(false)
                }
            }

            if currentStep != .language {
                HStack {
                    Button(uiText("戻る")) { moveBack() }
                        .disabled(currentStepIndex == 0)
                    Spacer()
                    if currentStep == .practice && !mode.isGuide {
                        Button(uiText("あとで試す")) { skipPractice() }
                    }
                    Button(primaryButtonTitle) { advance() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdvance)
                }
            }
        }
        .padding(uiMetrics.layout(24))
        .frame(
            minWidth: OnboardingUIScaleMetrics.minimumWindowSize.width,
            minHeight: OnboardingUIScaleMetrics.minimumWindowSize.height
        )
        .onboardingUIScale(uiMetrics)
        .dynamicTypeSize(.xxLarge)
        .onAppear {
            restoreProgress()
        }
        .onChange(of: currentStepIndex) {
            hasMoreScrollableContent = false
            stopShortcutCapture()
            if currentStep != .practice {
                practiceController.reset()
            }
            if currentStep != .voice {
                if microphoneCheckState != .confirmed {
                    microphoneCheckState = .idle
                }
                stopMicrophoneCheck()
            }
        }
        .onChange(of: microphoneProbe.hasDetectedVoice) { _, hasDetectedVoice in
            guard hasDetectedVoice, microphoneCheckState == .checking else { return }
            microphoneCheckState = .voiceDetected
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard currentStep == .permissions else { return }
            permissionManager.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .onboardingWindowWillClose)) { _ in
            stopInteractiveChecks()
        }
        .onDisappear {
            stopInteractiveChecks()
        }
        .environment(\.locale, settingsStore.settings.languagePreferences.uiLanguage.locale)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            Text(currentStep == .language ? "言語を選択 / Choose a language" : mode.title(for: settingsStore.settings.languagePreferences.uiLanguage))
                .font(uiMetrics.font(.title))
                .bold()
            Text(AppLocalizer.format(
                "ステップ %d / %d",
                language: settingsStore.settings.languagePreferences.uiLanguage,
                currentStepIndex + 1,
                steps.count
            ))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            ProgressView(value: Double(currentStepIndex + 1), total: Double(steps.count))
            Text(stepSubtitle)
                .font(uiMetrics.font(.body))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .language:
            languageSelectionContent
        case .welcome:
            welcomeContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .welcome) }
        case .permissions:
            permissionsContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .permissions) }
        case .voice:
            voiceContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .voice) }
        case .preferences:
            preferencesContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .preferences) }
        case .aiCommand:
            aiCommandContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .aiCommand) }
        case .practice:
            practiceContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .practice) }
        case .complete:
            completeContent
                .onAppear { acknowledgeForcedInitialStepIfNeeded(visibleStep: .complete) }
        }
    }

    private var languageSelectionContent: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(16)) {
            Text("このセットアップで使用する言語を選択してください。")
                .font(uiMetrics.font(.body))
            Text("Choose the language for this setup.")
                .font(uiMetrics.font(.body))

            HStack(spacing: uiMetrics.layout(12)) {
                Button {
                    selectInitialLanguage(.japanese)
                } label: {
                    VStack(alignment: .leading, spacing: uiMetrics.layout(4)) {
                        Text("日本語")
                            .font(uiMetrics.font(.headline))
                        Text("Japanese UI, speech recognition, and AI output")
                            .font(uiMetrics.font(.caption))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    selectInitialLanguage(.english)
                } label: {
                    VStack(alignment: .leading, spacing: uiMetrics.layout(4)) {
                        Text("English")
                            .font(uiMetrics.font(.headline))
                        Text("English UI, speech recognition, and AI output")
                            .font(uiMetrics.font(.caption))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()
            Text("セットアップ完了後は、設定画面から表示言語・音声認識言語・AI出力言語を個別に変更できます。")
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Text("After setup, you can change display, speech-recognition, and AI-output languages separately in Settings.")
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(14)) {
            Text(uiText("話すだけで、普段のタイピング入力がすばやく進められます。まずは3つのモードの使い方を分けて確認しましょう。"))

            onboardingModeCard(
                title: "通常モード（AIアシスト入力）",
                icon: "mic.fill",
                detail: "話した内容を文字起こしし、必要に応じてAIアシストで整えてから、現在のカーソル位置へ挿入されます。"
            )
            onboardingModeCard(
                title: "AIに指示モード",
                icon: "sparkles",
                detail: "選択したテキストに対して、編集や要約、翻訳などを行えます。また、AIに簡単な質問やウェブ検索を行ってもらうこともできます。"
            )
            onboardingModeCard(
                title: "ハンズフリー送信モード",
                icon: "paperplane.fill",
                detail: "通常モードと同じ文字起こし・AI整形を使います。音声トリガーまたはもう一度起動キーを押すと録音を終了します。本文を安全に挿入でき、送信が許可されている場合だけ、設定した送信キーを自動送信します。送信できた後は取り消せません。"
            )

            Text(uiText("録音中は画面下のHUDに状態が表示されます。×で取り消し、✓で停止できます。色や外枠はモードや状態の目安なので、色だけに頼らず表示内容を確認してください。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)

            Text(uiText("3つとも後から設定画面で変更できます。ここでは、まず安全に使い始めるための最小限だけを設定していきます。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                Text(uiText("Codex CLIとの接続"))
                    .font(uiMetrics.font(.headline))
                Text(uiText("Koedexの「AIアシスト」やAIに指示モードの機能を使うには、ログイン認証済みのCodex CLIが必要です。ログイン認証が完了していれば、Codex CLIを立ち上げていなくてもAI機能を使用することができます。"))
                Text(uiText("ChatGPTのアカウントを持っているだけでは利用できません。MacのChatGPT App（旧Codex App）ではなく、Codex CLIの準備が必要です。"))
                Text(uiText("AI機能が使えない場合も、macOSに標準搭載されているオンデバイス音声認識を使った、基本の音声入力・文字起こしは利用できます。"))
                Text(uiText("Codex CLIは、Koedexのセットアップ後に準備しても大丈夫です。インストールとログイン認証が終わったら、Koedexを再起動してください。通常は自動的に見つけて接続します。"))
                Text(uiText("自動的に接続できない場合は、設定画面の「Codex実行ファイルの場所」にCodex CLIのパスを入力して保存してください。"))
            }
            .font(uiMetrics.font(.caption))
            .foregroundStyle(.secondary)
            .padding(uiMetrics.layout(12))
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func onboardingModeCard(title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: uiMetrics.layout(12)) {
            Image(systemName: icon)
                .font(uiMetrics.font(.title3))
                .foregroundStyle(.tint)
                .frame(width: uiMetrics.layout(26))
            VStack(alignment: .leading, spacing: uiMetrics.layout(4)) {
                Text(uiText(title)).font(uiMetrics.font(.headline))
                Text(uiText(detail)).font(uiMetrics.font(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(uiMetrics.layout(12))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
            Text(uiText("最初に必要な権限を確認します"))
                .font(uiMetrics.font(.headline))
            Text(uiText("各項目を許可すると、その場で表示が更新されます。拒否済みの場合はシステム設定から変更できます。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            PermissionRow(
                title: AppLocalizer.text("マイク", language: settingsStore.settings.languagePreferences.uiLanguage),
                detail: AppLocalizer.text("話した内容を受け取るために必要です。", language: settingsStore.settings.languagePreferences.uiLanguage),
                isRequired: true,
                state: permissionManager.microphoneState,
                permission: .microphone,
                settingsLink: SystemSettingsLinks.microphone,
                language: settingsStore.settings.languagePreferences.uiLanguage,
                onRequest: { Task { await permissionManager.requestMicrophone() } }
            )
            PermissionRow(
                title: AppLocalizer.text("音声認識", language: settingsStore.settings.languagePreferences.uiLanguage),
                detail: AppLocalizer.text("音声をテキストに変換するために必要です。", language: settingsStore.settings.languagePreferences.uiLanguage),
                isRequired: true,
                state: permissionManager.speechRecognitionState,
                permission: .speechRecognition,
                settingsLink: SystemSettingsLinks.speechRecognition,
                language: settingsStore.settings.languagePreferences.uiLanguage,
                onRequest: { Task { await permissionManager.requestSpeechRecognition() } }
            )
            PermissionRow(
                title: AppLocalizer.text("アクセシビリティ", language: settingsStore.settings.languagePreferences.uiLanguage),
                detail: AppLocalizer.format(
                    "グローバルショートカットの監視とカーソル位置の入力に必要です。アクセシビリティの項目で%@を有効にしてください。",
                    language: settingsStore.settings.languagePreferences.uiLanguage,
                    accessibilityApplicationName
                ),
                isRequired: true,
                state: permissionManager.accessibilityState,
                permission: .accessibility,
                settingsLink: SystemSettingsLinks.accessibility,
                language: settingsStore.settings.languagePreferences.uiLanguage,
                onRequest: { _ = permissionManager.requestAccessibility() }
            )

            if permissionManager.accessibilityState != .authorized, !mode.isPreview {
                VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
                    Label(uiText("現在起動中のKoedexを確認"), systemImage: "app.badge.checkmark")
                        .font(uiMetrics.font(.headline))
                    Text(uiText("以前の開発版を使っていた場合、macOSの一覧に「Koedex」が残っていても、以前の署名のアプリを指していると現在起動中のアプリには許可が反映されません。安定署名版へ移行する最初の一度だけは、旧項目を削除してからこのアプリを許可し直す必要がある場合があります。"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                    Text(Bundle.main.bundleURL.path)
                        .font(uiMetrics.font(.monospacedCaption))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(uiText("Finderで現在のKoedexを表示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .font(uiMetrics.font(.caption))
                }
                .padding(uiMetrics.layout(10))
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            Text(uiText("上記で許可した権限が画面に反映されない場合は、下のボタンからアプリを再起動してください。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Button(uiText(restartCoordinator.isRestarting ? "アプリを再起動しています…" : "アプリの再起動")) {
                requestApplicationRestart()
            }
            .font(uiMetrics.font(.caption))
            .disabled(restartCoordinator.isRestarting)

            if let appRestartFeedback {
                Text(appRestartFeedback)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
            }

            if mode.isPreview {
                HStack {
                    Button(uiText("すべて許可済みにする")) {
                        permissionManager.setAllPreviewStates(.authorized)
                    }
                    Button(uiText("未確認に戻す")) {
                        permissionManager.setAllPreviewStates(.initial)
                    }
                }
                .font(uiMetrics.font(.caption))
            }
        }
    }

    private var accessibilityApplicationName: String {
        mode.isLiveDebugRehearsal ? "Koedex Debug" : "Koedex"
    }

    @ViewBuilder
    private var voiceContent: some View {
        if mode.isGuide {
            VStack(alignment: .leading, spacing: uiMetrics.layout(14)) {
                Text(uiText("通常モード"))
                    .font(uiMetrics.font(.headline))
                Text(OnboardingVoiceGuideCopy.instruction(
                    recordingMode: normalRecordingMode,
                    hotkeyName: normalHotkeyName,
                    language: uiLanguage
                ))
                Text(uiText("入力デバイス、録音方式、ショートカットは「設定」でいつでも変更できます。マイクの反応が不安定な場合は、設定のマイク一覧から使う機器を選び直してください。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                fnKeyNotice
            }
        } else {
            VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
                OnboardingSectionTitle(
                    "音声入力デバイスの設定",
                    language: uiLanguage,
                    isRequired: true,
                    requiredReason: "デバイスの確認と設定が必要です"
                )
                if mode.isPreview {
                    LabeledContent(uiText("入力デバイス")) {
                        Text(uiText("システムのデフォルト（プレビュー）"))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(uiText("入力デバイス"), selection: selectedMicrophoneBinding) {
                        Text(uiText("システムのデフォルト")).tag("")
                        ForEach(MicrophoneDeviceManager.inputDevices()) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if microphoneCheckState == .confirmed {
                    Label(uiText("このデバイスを設定しました。"), systemImage: "checkmark.circle.fill")
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.green)
                } else {
                    Button(uiText(microphoneCheckState == .checking ? "デバイスを確認しています…" : "デバイスを確認する")) {
                        beginMicrophoneCheck()
                    }
                    .disabled(microphoneCheckState == .checking)

                    if microphoneCheckState.showsMeter {
                        ProgressView(value: microphoneProbe.level)
                            .tint(microphoneCheckState == .voiceDetected ? .green : .accentColor)
                        Text(uiText(microphoneCheckState == .voiceDetected ? "音声入力を確認できました。" : "実際に話して、メーターが動くことを確認してください。"))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                        Text(uiText("この確認音声は録音・保存されません。選択したマイクが見つからない場合は、macOSのデフォルト入力を使います。"))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)

                        if mode.isPreview {
                            Button(uiText("音声入力ありとして表示")) {
                                microphoneProbe.simulateVoice()
                            }
                            .font(uiMetrics.font(.caption))
                        }

                        Button(uiText("このデバイスで設定")) {
                            confirmMicrophoneDevice()
                        }
                        .disabled(microphoneCheckState != .voiceDetected)
                    }

                    if case .failed = microphoneCheckState {
                        Text(uiText("デバイス確認を開始できませんでした。マイクの権限と接続を確認して、もう一度試してください。"))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.orange)
                    }
                }

                Divider()
                OnboardingSectionTitle(
                    "通常モードの起動キー設定",
                    language: uiLanguage,
                    isRequired: true,
                    requiredReason: "キー入力の確認と設定が必要です"
                )
                Text(uiText("初期設定: fn (🌐)"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiFormat("現在の起動キー: %@", normalHotkeyName))
                    .font(uiMetrics.font(.caption))
                shortcutSetupCard(
                    target: .normal,
                    currentBinding: normalBinding,
                    candidate: normalShortcutCandidate,
                    message: normalShortcutMessage,
                    showsSaveFeedback: normalShortcutState.showsSaveFeedback
                )
                Text(uiText("後から設定画面で変更できます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiText("文字やSpaceなどを設定すると、そのキーは入力先には送られず、Koedexの起動キーとして使われます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                fnKeyNotice
            }
        }
    }

    private var preferencesContent: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(14)) {
            Text(uiText("使い方の基本設定"))
                .font(uiMetrics.font(.headline))

            Picker(uiText("録音の自動停止"), selection: autoStopBinding) {
                if settingsStore.settings.autoStopSeconds == 60 {
                    Text(uiText("1分（現在の設定）")).tag(60)
                }
                Text(uiText("3分")).tag(180)
                Text(uiText("5分（おすすめ）")).tag(300)
                Text(uiText("10分")).tag(600)
            }
            .pickerStyle(.segmented)
            Text(uiText("録音の自動停止時間は、通常モードとAIに指示モードで共通です。録音は最長10分間で、自動停止時間を超えて録音が続くことはありません。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Text(uiText("パスワード入力などで安全な入力が有効な間は、通常モード・AIに指示モード・ハンズフリー送信モードを開始できません。入力を閉じてから開始してください。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)

            Divider()
            retentionPicker(title: "通常モードの出力履歴", enabled: normalHistoryEnabled, days: normalHistoryDays)
            Text(uiText("通常モードで挿入対象になった出力テキストと必要最小限の履歴メタデータを、このMacだけに保存します。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Text(uiFormat("保存先: %@", OnboardingRuntimeProfile.historyFileDisplayPath))
                .font(uiMetrics.font(.caption).monospaced())
                .foregroundStyle(.secondary)
            Text(uiText("「保存しない」は今後の保存を止めるだけで、既存履歴は削除しません。設定画面の「履歴」タブから、個別・選択・全件削除できます。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)

            if handsFreeSendOnboardingIsAvailable {
                Divider()
                Toggle(uiText("ハンズフリー送信モードを有効にする"), isOn: handsFreeSendEnabledBinding)
                Text(uiText("チェックを付けると、互換入力モードがONの場合に限り、設定画面の「外部アプリでも自動送信する」も同時にONになります。ブラウザやチャットアプリでも自動送信されるようになるため、不要な場合は設定画面でOFFにできます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiFormat(
                    "%@ で開始し、発話の最後に「%@」と言うか、もう一度 %@ を押すと録音を終了します。本文を安全に挿入でき、送信が許可されている場合だけ、設定した送信キー（%@）を自動送信します。送信できた後は取り消せません。送信キー、カスタムフレーズ、外部アプリでの自動送信は設定で変更できます。",
                    hotkeyName(settingsStore.settings.handsFreeSendSettings.binding),
                    HandsFreeSendTriggerPolicy.presetDisplayPhrase(
                        sttLanguage: settingsStore.settings.languagePreferences.sttLanguage
                    ),
                    hotkeyName(settingsStore.settings.handsFreeSendSettings.binding),
                    settingsStore.settings.handsFreeSendSettings.sendKey.displayLabel
                ))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiText("通常モードで保存したカスタムインストラクションは、ハンズフリー送信モードのAI整形にも適用されます。変更は次の録音から反映されます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Label(uiText("セットアップ完了後は、設定画面から「起動キー」や「トリガーフレーズ」などの詳細を変更できます。"), systemImage: "gearshape")
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                if handsFreeSendEnabledBinding.wrappedValue {
                    retentionPicker(
                        title: "ハンズフリー送信モードの出力履歴",
                        enabled: handsFreeHistoryEnabled,
                        days: handsFreeHistoryDays
                    )
                    Text(uiText("安全に本文を挿入できた出力だけを、通常モードとは別の履歴としてこのMacに保存します。送信キーだけの操作、取消、中断、失敗、結果表示への退避では本文を保存しません。"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var aiCommandContent: some View {
        if mode.isGuide {
            VStack(alignment: .leading, spacing: uiMetrics.layout(14)) {
                Text(uiText("AIに指示モード"))
                    .font(uiMetrics.font(.headline))
                Text(uiFormat(
                    "起動: %@\n停止: %@",
                    hotkeyName(settingsStore.settings.aiCommandSettings.startHotkey),
                    hotkeyName(settingsStore.settings.aiCommandSettings.stopHotkey)
                ))
                Text(uiText("起動キーで録音を始め、停止キーで止めるワンタップ方式です。通常モードの設定・履歴と分けて保存されます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(AICommandWebSearchCopy.selectedSourceNotice(
                    for: uiLanguage
                ))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
                Text(uiText("AIに指示モードの各種設定"))
                    .font(uiMetrics.font(.headline))
                Toggle(uiText("AIに指示モードを有効にする"), isOn: aiEnabledBinding)
                Text(uiText("オンにすると、起動キーで録音し、停止キーでAIへの依頼を確定できます。オフの間はショートカット監視・録音・AI処理を開始しません。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiText("モデルはセットアップ完了後に設定画面で確認・変更できます。Web検索は選択したモデルの対応状況に従います。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)

                Toggle(uiText("AIへの質問でWeb検索を使う"), isOn: aiWebBinding)
                    .disabled(!aiEnabledBinding.wrappedValue)
                Text(AICommandWebSearchCopy.generalQuestionNotice(
                    for: uiLanguage
                ))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiText("Web検索に対応したモデルを選んだ場合だけ使われます。オフの場合やモデルが対応しない場合は、最新情報が必要な依頼を実行せず設定方法を案内します。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(AICommandWebSearchCopy.selectedSourceNotice(
                    for: uiLanguage
                ))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)

                retentionPicker(title: "AIに指示モードの入力履歴", enabled: aiHistoryEnabled, days: aiHistoryDays)
                Text(uiText("保存されるのは音声指示内容の文字起こしだけです。クリップボードモードも同じAIに指示モードの履歴に「クリップボードモード」として表示します。選択元、クリップボード本文、AIの回答、音声、参照リンクなどは保存されません。通常モードと同じ履歴ファイルにモード別で保存されます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Text(uiFormat("保存先: %@", OnboardingRuntimeProfile.historyFileDisplayPath))
                    .font(uiMetrics.font(.caption).monospaced())
                    .foregroundStyle(.secondary)
                Text(uiText("「保存しない」は今後の保存を止めるだけで、既存履歴は削除しません。設定画面の「履歴」タブから、個別・選択・全件削除できます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)

                if aiEnabledBinding.wrappedValue {
                    Divider()
                    Text(uiText("AIに指示モードの起動キー確認"))
                        .font(uiMetrics.font(.headline))
                    OnboardingSectionTitle(
                        "起動キー",
                        language: uiLanguage,
                        isRequired: true,
                        requiredReason: "キー入力の確認と設定が必要です"
                    )
                    Text(uiText("起動キーの初期設定: fn (🌐)＋Space"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                    Text(uiFormat("現在の起動キー: %@", hotkeyName(settingsStore.settings.aiCommandSettings.startHotkey)))
                        .font(uiMetrics.font(.caption))
                    shortcutSetupCard(
                        target: .aiStart,
                        currentBinding: settingsStore.settings.aiCommandSettings.startHotkey,
                        candidate: aiStartShortcutCandidate,
                        message: aiStartShortcutMessage,
                        showsSaveFeedback: aiStartShortcutState.showsSaveFeedback
                    )
                    OnboardingSectionTitle(
                        "停止キー",
                        language: uiLanguage,
                        isRequired: true,
                        requiredReason: "キー入力の確認と設定が必要です"
                    )
                    Text(uiText("停止キーの初期設定: fn (🌐)"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                    Text(uiFormat("現在の停止キー: %@", hotkeyName(settingsStore.settings.aiCommandSettings.stopHotkey)))
                        .font(uiMetrics.font(.caption))
                    shortcutSetupCard(
                        target: .aiStop,
                        currentBinding: settingsStore.settings.aiCommandSettings.stopHotkey,
                        candidate: aiStopShortcutCandidate,
                        message: aiStopShortcutMessage,
                        showsSaveFeedback: aiStopShortcutState.showsSaveFeedback
                    )
                    Text(uiText("起動キーは1〜3個、停止キーは1個です。複数キーの起動設定には修飾キーを含めます。"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)

                    if aiCommandClipboardVariantOnboardingIsAvailable {
                        Divider()
                        Toggle(uiText("クリップボードモードを有効にする"), isOn: clipboardVariantEnabledBinding)
                        Text(uiFormat(
                            "Google Docsなど一部のアプリやWebサイトでは、選択したテキストをKoedexが認識できない場合があります。そうしたアプリ等では、このモードを使い、自分で ⌘C でコピーしたテキストに対してAIに編集指示や質問ができます。\n\n現在の追加キー（%@）を最初に押しながら、「AIに指示モード」で設定した起動キーを押してください。\n\n安全な入力が有効な間、秘匿指定・Koedex自身の出力・テキスト以外・長すぎる内容はAIへ渡さず中止します。Koedexが読めない場合に一般質問へ切り替えることはありません。クリップボード本文は履歴に保存せず、音声指示だけをAIに指示モードの履歴に保存します。追加キーは設定画面で変更できます。",
                            settingsStore.settings.aiCommandSettings.clipboardVariantModifier.displayLabel
                        ))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                        if let clipboardVariantOnboardingStatusMessage {
                            Text(clipboardVariantOnboardingStatusMessage)
                                .font(uiMetrics.font(.caption))
                                .foregroundStyle(.orange)
                            Text(uiText("設定画面で追加キーまたは起動キーを変更してから、クリップボードモードを有効にできます。"))
                                .font(uiMetrics.font(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Label(uiText("セットアップ完了後は、設定画面から「クリップボードモード」のON / OFFや「追加キー」の変更ができます。"), systemImage: "gearshape")
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var practiceContent: some View {
        if mode.isGuide {
            VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
                Label(uiText("必要なら、いつでも設定を見直せます"), systemImage: "checkmark.circle")
                    .font(uiMetrics.font(.headline))
                Text(uiText("マイク、ショートカット、録音の自動停止、AIに指示モードのオン／オフは設定画面から変更できます。うまく反応しない場合は、まずマイク選択とmacOSのアクセシビリティ権限を確認してください。"))
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
                if mode.isPreview {
                    Text(uiText("最後に、練習画面の見え方を確認"))
                        .font(uiMetrics.font(.headline))
                    Text(uiText("プレビューではマイクや音声認識を使いません。例文を表示して、成功・失敗時の表示を確認できます。"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                }
                Text(uiText("文字起こしの確認（任意）"))
                    .font(uiMetrics.font(.headline))
                Text(uiText("ローカル環境で話した内容を文字にできるかを確認します。AIアシストによるテキストの整形は行われません。出力された文章は、設定を閉じると削除され、履歴や辞書、Codexには送られません。失敗してもセットアップは完了できます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                practiceControls
                Text(uiText("テスト環境セットアップに少し時間がかかる場合があります。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                practiceResult
            }
        }
    }

    @ViewBuilder
    private var practiceControls: some View {
        switch practiceController.state {
        case .idle, .finished, .failed:
            Button(uiText("文字起こしを試す")) {
                if mode.isPreview {
                    practiceController.showPreviewExample(
                        language: settingsStore.settings.languagePreferences.uiLanguage
                    )
                } else {
                practiceController.startLivePractice(
                    preferredMicrophoneUID: settingsStore.settings.preferredMicrophoneUID,
                    language: settingsStore.settings.languagePreferences.sttLanguage
                )
                }
            }
        case .preparing:
            HStack { ProgressView(); Text(uiText("音声認識を準備しています…")).font(uiMetrics.font(.caption)) }
        case .recording:
            VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                practiceRecordingStatus
                SegmentedInputLevelMeter(level: practiceController.audioLevel, language: uiLanguage)
                Button(uiText("録音を停止")) { practiceController.stopLivePractice() }
            }
        }
    }

    private var practiceRecordingStatus: some View {
        HStack(spacing: uiMetrics.layout(6)) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
            Text(uiText("録音中"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.red)
            if let startedAt = practiceController.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsedTimeString(since: startedAt, now: context.date))
                        .font(uiMetrics.font(.monospacedCaption))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func elapsedTimeString(since startedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var practiceResult: some View {
        switch practiceController.state {
        case .finished:
            if practiceController.resultText.isEmpty {
                Text(uiText("文字起こし結果を受け取れませんでした。マイクや音声認識の設定を確認するか、あとで試してください。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: uiMetrics.layout(4)) {
                    Text(uiText("確認できたテキスト")).font(uiMetrics.font(.caption)).bold()
                    Text(practiceController.resultText)
                        .textSelection(.enabled)
                }
                .padding(uiMetrics.layout(10))
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        case .failed:
            Text(AppLocalizer.text(
                "文字起こしを確認できませんでした。マイク、音声認識の権限、音声モデルを確認してから、もう一度試してください。",
                language: settingsStore.settings.languagePreferences.uiLanguage
            ))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.orange)
        case .idle, .preparing, .recording:
            EmptyView()
        }
    }

    private var completeContent: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
            Label(
                uiText(mode.isGuide ? "ガイドを確認しました" : "セットアップが完了しました"),
                systemImage: "checkmark.circle.fill"
            )
            .font(uiMetrics.font(.title3))
            .foregroundStyle(.green)
            Text(uiText(mode.isGuide
                ? "迷った時は、メニューバーまたは設定画面からこのガイドをもう一度開けます。"
                : "すべての設定は後からKoedexの設定画面で変更できます。"))
                .foregroundStyle(.secondary)
            if mode.isDebug {
                Text(uiText("Debug.appを閉じても本番のKoedex設定・履歴・ログは変更されません。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.purple)
            }
        }
    }

    @ViewBuilder
    private func shortcutSetupCard(
        target: ShortcutTarget,
        currentBinding: HotkeyBinding,
        candidate: HotkeyBinding?,
        message: String?,
        showsSaveFeedback: Bool
    ) -> some View {
        let isCapturingThisTarget = shortcutCapture.isCapturing && activeShortcutTarget == target
        let isCaptureBusy = shortcutCapture.isCapturing && activeShortcutTarget != target
        let displayedBinding = candidate ?? currentBinding

        VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: uiMetrics.layout(10)) {
                    shortcutKeyDisplay(displayedBinding, isCandidate: candidate != nil, showsSaveFeedback: showsSaveFeedback)
                    Button(uiText(isCapturingThisTarget ? "キーを入力中…" : "キーを入力する")) {
                        startShortcutCapture(for: target)
                    }
                    .disabled(shortcutCapture.isCapturing || isCaptureBusy)
                }

                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    shortcutKeyDisplay(displayedBinding, isCandidate: candidate != nil, showsSaveFeedback: showsSaveFeedback)
                    Button(uiText(isCapturingThisTarget ? "キーを入力中…" : "キーを入力する")) {
                        startShortcutCapture(for: target)
                    }
                    .disabled(shortcutCapture.isCapturing || isCaptureBusy)
                }
            }

            if isCapturingThisTarget {
                Text(uiText("キーを入力してください。すべてのキーを離すと候補を表示します。Escで取消できます。"))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
            }

            if let candidate {
                Text(uiFormat("候補: %@", hotkeyName(candidate)))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Button(uiText("このキーを設定する")) {
                    saveShortcutCandidate(for: target)
                }
            }

            if let message {
                Text(message)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
            }

            if showsSaveFeedback {
                Label(uiText("このキーを設定しました"), systemImage: "checkmark.circle.fill")
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.green)
            }
        }
    }

    private func shortcutKeyDisplay(
        _ binding: HotkeyBinding,
        isCandidate: Bool,
        showsSaveFeedback: Bool
    ) -> some View {
        Text(hotkeyName(binding))
            .font(uiMetrics.font(.caption))
            .fontWeight(.medium)
            .multilineTextAlignment(.center)
            .frame(minWidth: uiMetrics.layout(180), minHeight: uiMetrics.layout(48))
            .padding(.horizontal, uiMetrics.layout(10))
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isCandidate ? Color.accentColor.opacity(0.8) : (showsSaveFeedback ? Color.green.opacity(0.7) : Color.secondary.opacity(0.25)),
                        lineWidth: 1
                    )
            )
    }

    private var stepSubtitle: String {
        let japanese: String
        switch currentStep {
        case .language: return ""
        case .welcome: japanese = "通常モード（AIアシスト入力）・AIに指示モード・ハンズフリー送信モードの違いを先に確認します。"
        case .permissions: japanese = "必要な権限だけを、理由と一緒に確認します。"
        case .voice: japanese = "普段の音声入力に使うマイクとショートカットを確認します。"
        case .preferences: japanese = "録音の安全な停止時間、通常モードの履歴保持期間、ハンズフリー送信モードの設定を確認します。"
        case .aiCommand: japanese = "AIに指示モードのON／OFF、Web検索機能のON／OFF、履歴保持期間、起動キーを設定します。"
        case .practice: japanese = "任意の確認です。失敗しても、あとからいつでも試せます。"
        case .complete: japanese = "準備は完了です。"
        }
        return AppLocalizer.text(japanese, language: settingsStore.settings.languagePreferences.uiLanguage)
    }

    private var primaryButtonTitle: String {
        switch currentStep {
        case .language:
            return ""
        case .complete:
            if mode.isGuide { return AppLocalizer.text("閉じる", language: settingsStore.settings.languagePreferences.uiLanguage) }
            if mode.isDebug { return AppLocalizer.text("Debugメニューへ戻る", language: settingsStore.settings.languagePreferences.uiLanguage) }
            return AppLocalizer.text("Koedexを開始", language: settingsStore.settings.languagePreferences.uiLanguage)
        default:
            return AppLocalizer.text("次へ", language: settingsStore.settings.languagePreferences.uiLanguage)
        }
    }

    private var canAdvance: Bool {
        guard settingsStore.canSave else { return false }
        switch currentStep {
        case .language:
            return false
        case .permissions:
            return permissionManager.allGranted()
        case .voice:
            return mode.isGuide || (microphoneCheckState == .confirmed && normalShortcutIsConfirmed)
        case .aiCommand:
            guard !mode.isGuide else { return true }
            guard OnboardingFlow.requiresAIShortcutVerification(
                mode: mode,
                aiEnabled: aiEnabledBinding.wrappedValue
            ) else { return true }
            return aiStartShortcutIsConfirmed && aiStopShortcutIsConfirmed
        case .welcome, .preferences, .practice, .complete:
            return true
        }
    }

    private func advance() {
        guard canAdvance else { return }
        let completedStep = currentStep
        markStepComplete(completedStep)
        if completedStep == .complete {
            if mode.completesSetup {
                settingsStore.settings.setupProgress.isComplete = true
                if mode.usesInitialLanguageSelection {
                    settingsStore.settings.languagePreferences.finalizeInitialLanguageSelection()
                }
            } else {
                settingsStore.settings.setupProgress.lastSeenGuideVersion = SetupProgress.currentGuideVersion
            }
            settingsStore.flushPendingSave()
            onFinish()
        } else {
            currentStepIndex = min(currentStepIndex + 1, steps.count - 1)
        }
    }

    private func skipPractice() {
        guard currentStep == .practice else { return }
        markStepComplete(.practice)
        currentStepIndex = min(currentStepIndex + 1, steps.count - 1)
    }

    private func moveBack() {
        currentStepIndex = max(0, currentStepIndex - 1)
    }

    private func restoreProgress() {
        guard mode.persistsStepProgress else {
            currentStepIndex = 0
            microphoneCheckState = .idle
            return
        }

        let progress = settingsStore.settings.setupProgress
        normalShortcutState.restore(isReady: progress.completedStepIDs.contains(OnboardingStep.voice.rawValue))
        microphoneCheckState = progress.completedStepIDs.contains(OnboardingStep.voice.rawValue) ? .confirmed : .idle
        selectedMicrophoneUID = settingsStore.settings.preferredMicrophoneUID
        let aiStepCompleted = progress.completedStepIDs.contains(OnboardingStep.aiCommand.rawValue)
        aiStartShortcutState.restore(isReady: aiStepCompleted && settingsStore.settings.aiCommandSettings.enabled)
        aiStopShortcutState.restore(isReady: aiStepCompleted && settingsStore.settings.aiCommandSettings.enabled)
        normalShortcutCandidate = nil
        aiStartShortcutCandidate = nil
        aiStopShortcutCandidate = nil
        normalShortcutMessage = nil
        aiStartShortcutMessage = nil
        aiStopShortcutMessage = nil

        currentStepIndex = OnboardingFlow.initialStepIndex(
            mode: mode,
            progress: progress,
            allPermissionsGranted: permissionManager.allGranted(),
            hasCompletedInitialLanguageSelection: settingsStore.settings.languagePreferences.hasCompletedInitialLanguageSelection,
            forcedInitialStep: forcedInitialStep
        )
    }

    private func selectInitialLanguage(_ language: AppLanguage) {
        guard mode.usesInitialLanguageSelection, settingsStore.canSave else { return }
        settingsStore.settings.languagePreferences.applyInitialSelection(language)
        // 言語ステップはセットアップ完了までフロー上に残す。こうすると再起動時は
        // 次の未完了ステップから再開しつつ、戻る操作ではここへ戻って選び直せる。
        settingsStore.settings.setupProgress.completedStepIDs.insert(OnboardingStep.language.rawValue)
        settingsStore.flushPendingSave()
        DispatchQueue.main.async {
            NSApp.mainWindow?.title = mode.title(for: language)
        }
        currentStepIndex = steps.firstIndex(of: .welcome) ?? 0
    }

    private func acknowledgeForcedInitialStepIfNeeded(visibleStep: OnboardingStep) {
        guard !didAcknowledgeForcedInitialStep,
              let forcedInitialStep,
              forcedInitialStep == visibleStep,
              currentStep == visibleStep else { return }
        didAcknowledgeForcedInitialStep = true
        // 実際の対象コンテンツがonAppearした後の次の描画ターンで消去する。
        // root viewの生成時には消さず、復帰先ページが表示できなかった場合に備える。
        let onPresented = onForcedInitialStepPresented
        DispatchQueue.main.async {
            onPresented?()
        }
    }

    private func markStepComplete(_ step: OnboardingStep) {
        guard mode.persistsStepProgress else { return }
        settingsStore.settings.setupProgress.completedStepIDs.insert(step.rawValue)
        settingsStore.flushPendingSave()
    }

    private func requestApplicationRestart() {
        appRestartFeedback = nil
        restartCoordinator.restart(
            mode: mode,
            settingsStore: settingsStore,
            prepareForRestart: {
                await stopInteractiveChecksForRestart()
            },
            suspendOnboardingWindow: onRestartPreparationCompleted,
            restoreOnboardingWindowAfterFailure: onRestartFailure
        ) { result in
            if case .failure = result {
                AppLog.shared.warn("オンボーディングの再起動に失敗しました")
                appRestartFeedback = uiText("アプリを再起動できませんでした。少し待ってから、もう一度試してください。")
            }
        }
    }

    private func beginMicrophoneCheck() {
        guard currentStep == .voice, !mode.isGuide else { return }
        let generation = UUID()
        microphoneCheckGeneration = generation
        microphoneCheckState = .checking
        microphoneProbe.setSimulationEnabled(mode.isPreview)
        let previousOperation = microphoneProbeOperation
        microphoneProbeOperation = Task { @MainActor in
            await previousOperation?.value
            guard microphoneCheckGeneration == generation, currentStep == .voice else { return }
            do {
                let didStart = try await microphoneProbe.start(preferredUID: selectedMicrophoneUID)
                guard microphoneCheckGeneration == generation else { return }
                guard didStart else {
                    microphoneCheckState = .idle
                    return
                }
            } catch {
                guard microphoneCheckGeneration == generation else { return }
                AppLog.shared.warn("[OnboardingView] microphone check failed: \(AppLog.safeDescription(error))")
                microphoneCheckState = .failed
            }
        }
    }

    private func resetMicrophoneCheck() {
        microphoneCheckState = .idle
        stopMicrophoneCheck()
    }

    private func stopMicrophoneCheck() {
        microphoneCheckGeneration = UUID()
        let previousOperation = microphoneProbeOperation
        microphoneProbeOperation = Task { @MainActor in
            await previousOperation?.value
            await microphoneProbe.stop()
        }
    }

    private func stopMicrophoneCheckAndWait() async {
        microphoneCheckGeneration = UUID()
        let previousOperation = microphoneProbeOperation
        previousOperation?.cancel()
        await previousOperation?.value
        await microphoneProbe.stop()
        microphoneProbeOperation = nil
    }

    /// 標準の左上×でも、進行中の録音確認とショートカット待受を直ちに無効化する。
    private func stopInteractiveChecks() {
        stopShortcutCapture()
        practiceController.reset()
        stopMicrophoneCheck()
    }

    /// 再起動だけは旧プロセスが録音を保持したまま次の.appを起動しないよう、
    /// すべての対話的な確認処理の停止をawaitしてからコーディネーターへ戻す。
    private func stopInteractiveChecksForRestart() async -> Bool {
        stopShortcutCapture()
        await practiceController.resetAndWait()
        await stopMicrophoneCheckAndWait()
        return true
    }

    private func confirmMicrophoneDevice() {
        guard microphoneCheckState == .voiceDetected else { return }
        settingsStore.settings.preferredMicrophoneUID = selectedMicrophoneUID
        settingsStore.flushPendingSave()
        microphoneCheckState = .confirmed
        stopMicrophoneCheck()
    }

    private func startShortcutCapture(for target: ShortcutTarget) {
        guard settingsStore.canSave else { return }
        stopShortcutCapture()
        resetShortcutState(for: target, resetsReadiness: false)
        activeShortcutTarget = target

        if mode.isPreview {
            receiveShortcutCaptureResult(.candidate(currentBinding(for: target)), for: target)
            return
        }

        shortcutCapture.start(policy: capturePolicy(for: target)) { result in
            receiveShortcutCaptureResult(result, for: target)
        }
    }

    private func capturePolicy(for target: ShortcutTarget) -> HotkeyCapturePolicy {
        switch target {
        case .normal: return .normalSingleKey
        case .aiStart: return .aiStart
        case .aiStop: return .aiStop
        }
    }

    private func receiveShortcutCaptureResult(_ result: HotkeyCaptureStatus, for target: ShortcutTarget) {
        activeShortcutTarget = nil
        switch result {
        case let .candidate(binding):
            setShortcutCandidate(binding, for: target)
            setShortcutMessage(uiText("候補を確認して「このキーを設定する」を押してください。"), for: target)
        case let .invalid(error):
            setShortcutCandidate(nil, for: target)
            setShortcutMessage(error.message(for: uiLanguage), for: target)
        case .cancelled:
            setShortcutCandidate(nil, for: target)
            setShortcutMessage(nil, for: target)
        case .capturing:
            break
        }
    }

    private func saveShortcutCandidate(for target: ShortcutTarget) {
        guard settingsStore.canSave, let candidate = shortcutCandidate(for: target) else { return }
        hideShortcutSaveFeedback(for: target)

        switch target {
        case .normal:
            guard !candidate.conflictsExactly(with: settingsStore.settings.aiCommandSettings.startHotkey) else {
                setShortcutMessage(uiText("AIに指示モードの起動キーと重複しています。別のキーを選んでください。"), for: target)
                return
            }
            guard let key = candidate.keys.first else { return }
            settingsStore.settings.hotkeyKeyCode = key.keyCode
            settingsStore.settings.hotkeyIsModifier = key.isModifier
            settingsStore.settings.hotkeyModifierMask = key.modifierMask

        case .aiStart:
            guard !candidate.isKnownSystemReserved else {
                setShortcutMessage(uiText("このキーの組み合わせはmacOSで予約されているため使用できません。"), for: target)
                return
            }
            guard !candidate.conflictsExactly(with: normalBinding) else {
                setShortcutMessage(uiText("通常モードですでに使われているキーです。別のキーを選んでください。"), for: target)
                return
            }
            guard !candidate.conflictsExactly(with: settingsStore.settings.aiCommandSettings.stopHotkey) else {
                setShortcutMessage(uiText("起動キーと停止キーを同じ組み合わせにはできません。"), for: target)
                return
            }
            settingsStore.settings.aiCommandSettings.startHotkey = candidate

        case .aiStop:
            guard !candidate.isKnownSystemReserved else {
                setShortcutMessage(uiText("このキーの組み合わせはmacOSで予約されているため使用できません。"), for: target)
                return
            }
            guard !candidate.conflictsExactly(with: settingsStore.settings.aiCommandSettings.startHotkey) else {
                setShortcutMessage(uiText("停止キーは起動キーと異なるキーを選んでください。"), for: target)
                return
            }
            settingsStore.settings.aiCommandSettings.stopHotkey = candidate
        }

        settingsStore.flushPendingSave()
        setShortcutCandidate(nil, for: target)
        setShortcutMessage(nil, for: target)
        markShortcutSaved(for: target)
    }

    private func stopShortcutCapture() {
        shortcutCapture.stop()
        activeShortcutTarget = nil
    }

    private func resetShortcutState(for target: ShortcutTarget, resetsReadiness: Bool) {
        setShortcutCandidate(nil, for: target)
        setShortcutMessage(nil, for: target)
        if resetsReadiness {
            resetShortcutRequirement(for: target)
        } else {
            beginShortcutCaptureState(for: target)
        }
    }

    private func currentBinding(for target: ShortcutTarget) -> HotkeyBinding {
        switch target {
        case .normal: return normalBinding
        case .aiStart: return settingsStore.settings.aiCommandSettings.startHotkey
        case .aiStop: return settingsStore.settings.aiCommandSettings.stopHotkey
        }
    }

    private func shortcutCandidate(for target: ShortcutTarget) -> HotkeyBinding? {
        switch target {
        case .normal: return normalShortcutCandidate
        case .aiStart: return aiStartShortcutCandidate
        case .aiStop: return aiStopShortcutCandidate
        }
    }

    private func setShortcutCandidate(_ candidate: HotkeyBinding?, for target: ShortcutTarget) {
        switch target {
        case .normal: normalShortcutCandidate = candidate
        case .aiStart: aiStartShortcutCandidate = candidate
        case .aiStop: aiStopShortcutCandidate = candidate
        }
    }

    private func setShortcutMessage(_ message: String?, for target: ShortcutTarget) {
        switch target {
        case .normal: normalShortcutMessage = message
        case .aiStart: aiStartShortcutMessage = message
        case .aiStop: aiStopShortcutMessage = message
        }
    }

    private func beginShortcutCaptureState(for target: ShortcutTarget) {
        switch target {
        case .normal: normalShortcutState.beginCapture()
        case .aiStart: aiStartShortcutState.beginCapture()
        case .aiStop: aiStopShortcutState.beginCapture()
        }
    }

    private func hideShortcutSaveFeedback(for target: ShortcutTarget) {
        switch target {
        case .normal: normalShortcutState.beginCapture()
        case .aiStart: aiStartShortcutState.beginCapture()
        case .aiStop: aiStopShortcutState.beginCapture()
        }
    }

    private func markShortcutSaved(for target: ShortcutTarget) {
        switch target {
        case .normal: normalShortcutState.save()
        case .aiStart: aiStartShortcutState.save()
        case .aiStop: aiStopShortcutState.save()
        }
    }

    private func resetShortcutRequirement(for target: ShortcutTarget) {
        switch target {
        case .normal: normalShortcutState.resetRequirement()
        case .aiStart: aiStartShortcutState.resetRequirement()
        case .aiStop: aiStopShortcutState.resetRequirement()
        }
    }

    private func hotkeyName(_ binding: HotkeyBinding) -> String {
        binding.keys.map {
            KeyNameFormatter.name(
                forKeyCode: $0.keyCode,
                isModifier: $0.isModifier,
                language: uiLanguage
            )
        }
            .joined(separator: " + ")
    }

    private var normalHotkeyName: String {
        KeyNameFormatter.name(
            forKeyCode: settingsStore.settings.hotkeyKeyCode,
            isModifier: settingsStore.settings.hotkeyIsModifier,
            language: uiLanguage
        )
    }

    private var normalRecordingMode: RecordingMode {
        RecordingMode(rawValue: settingsStore.settings.recordingMode) ?? .toggle
    }

    private var normalBinding: HotkeyBinding {
        HotkeyBinding(keys: [HotkeyKey(
            keyCode: settingsStore.settings.hotkeyKeyCode,
            isModifier: settingsStore.settings.hotkeyIsModifier,
            modifierMask: settingsStore.settings.hotkeyModifierMask
        )])
    }

    private func retentionPicker(title: String, enabled: Binding<Bool>, days: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            Text(uiText(title)).font(uiMetrics.font(.headline))
            Picker(uiText("保持期間"), selection: Binding(
                get: { enabled.wrappedValue ? days.wrappedValue : -1 },
                set: { value in
                    enabled.wrappedValue = value != -1
                    days.wrappedValue = max(value, 0)
                }
            )) {
                Text(uiText("保存しない")).tag(-1)
                Text(uiText("1日")).tag(1)
                Text(uiText("30日")).tag(30)
                Text(uiText("180日")).tag(180)
                Text(uiText("無期限")).tag(0)
            }
            .pickerStyle(.menu)
        }
    }

    private var selectedMicrophoneBinding: Binding<String> {
        Binding(
            get: { selectedMicrophoneUID },
            set: {
                selectedMicrophoneUID = $0
                resetMicrophoneCheck()
            }
        )
    }

    private var autoStopBinding: Binding<Int> {
        Binding(
            get: { settingsStore.settings.effectiveAutoStopSeconds },
            set: { settingsStore.settings.autoStopSeconds = $0 }
        )
    }

    private var normalHistoryEnabled: Binding<Bool> {
        Binding(get: { settingsStore.settings.historyEnabled }, set: { settingsStore.settings.historyEnabled = $0 })
    }

    private var handsFreeSendOnboardingIsAvailable: Bool {
        HandsFreeSendOnboardingPolicy.showsOptionalToggle(in: mode)
    }

    private var handsFreeSendEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.handsFreeSendSettings.enabled },
            set: { enabled in
                HandsFreeSendOnboardingActivation.apply(
                    enabled: enabled,
                    externalCompatibilityEnabled: settingsStore.settings
                        .externalAppCompatibilitySettings.enabled,
                    to: &settingsStore.settings.handsFreeSendSettings
                )
            }
        )
    }

    private var handsFreeHistoryEnabled: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.handsFreeSendSettings.historyEnabled },
            set: { settingsStore.settings.handsFreeSendSettings.historyEnabled = $0 }
        )
    }

    private var handsFreeHistoryDays: Binding<Int> {
        Binding(
            get: { settingsStore.settings.handsFreeSendSettings.historyRetentionDays },
            set: { settingsStore.settings.handsFreeSendSettings.historyRetentionDays = $0 }
        )
    }

    private var aiCommandClipboardVariantOnboardingIsAvailable: Bool {
        AICommandClipboardVariantOnboardingPolicy.showsOptionalToggle(in: mode)
    }

    private var clipboardVariantEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.aiCommandSettings.clipboardVariantEnabled },
            set: { enabled in
                switch AICommandClipboardActivationPolicy.decision(
                    requestedEnabled: enabled,
                    eligibility: settingsStore.settings.clipboardVariantEligibility
                ) {
                case .disabled:
                    settingsStore.settings.aiCommandSettings.clipboardVariantEnabled = false
                    clipboardVariantOnboardingMessage = nil
                case .enabled:
                    settingsStore.settings.aiCommandSettings.clipboardVariantEnabled = true
                    clipboardVariantOnboardingMessage = nil
                case let .rejected(eligibility):
                    settingsStore.settings.aiCommandSettings.clipboardVariantEnabled = false
                    clipboardVariantOnboardingMessage = AICommandClipboardEligibilityCopy.message(
                        for: eligibility,
                        language: uiLanguage
                    )
                }
            }
        )
    }

    private var clipboardVariantOnboardingStatusMessage: String? {
        if let clipboardVariantOnboardingMessage {
            return clipboardVariantOnboardingMessage
        }
        guard settingsStore.settings.aiCommandSettings.clipboardVariantEnabled else { return nil }
        return AICommandClipboardEligibilityCopy.message(
            for: settingsStore.settings.clipboardVariantEligibility,
            language: uiLanguage
        )
    }

    private var normalHistoryDays: Binding<Int> {
        Binding(get: { settingsStore.settings.historyRetentionDays }, set: { settingsStore.settings.historyRetentionDays = $0 })
    }

    private var aiHistoryEnabled: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.aiCommandSettings.historyEnabled },
            set: { settingsStore.settings.aiCommandSettings.historyEnabled = $0 }
        )
    }

    private var aiHistoryDays: Binding<Int> {
        Binding(
            get: { settingsStore.settings.aiCommandSettings.historyRetentionDays },
            set: { settingsStore.settings.aiCommandSettings.historyRetentionDays = $0 }
        )
    }

    private var aiEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.aiCommandSettings.enabled },
            set: {
                settingsStore.settings.aiCommandSettings.enabled = $0
                stopShortcutCapture()
                resetShortcutState(for: .aiStart, resetsReadiness: true)
                resetShortcutState(for: .aiStop, resetsReadiness: true)
            }
        )
    }

    private var aiWebBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.aiCommandSettings.webSearchEnabled },
            set: { settingsStore.settings.aiCommandSettings.webSearchEnabled = $0 }
        )
    }

    private var fnKeyNotice: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            Text(uiText("fnキー使用時の注意")).font(uiMetrics.font(.headline))
            Text(uiText("Koedexは初期設定でfn（🌐）キーを使います。macOSの「🌐キーを押して」機能と競合する場合は、システム設定 → キーボードで「何もしない」に変更してください。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Button(uiText("キーボード設定を開く")) {
                NSWorkspace.shared.open(SystemSettingsLinks.keyboard)
            }
            .font(uiMetrics.font(.caption))
        }
        .padding(uiMetrics.layout(10))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OnboardingSectionTitle: View {
    let title: String
    let isRequired: Bool
    let requiredReason: String?

    @Environment(\.onboardingUIScaleMetrics) private var uiMetrics

    let language: AppLanguage

    init(
        _ title: String,
        language: AppLanguage,
        isRequired: Bool = false,
        requiredReason: String? = nil
    ) {
        self.title = title
        self.language = language
        self.isRequired = isRequired
        self.requiredReason = requiredReason
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: uiMetrics.layout(6)) {
            Text(AppLocalizer.text(title, language: language)).font(uiMetrics.font(.headline))
            if isRequired {
                Text(requiredLabel)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var requiredLabel: String {
        guard let requiredReason else {
            return AppLocalizer.text("※必須", language: language)
        }
        return AppLocalizer.format(
            "※必須（%@）",
            language: language,
            AppLocalizer.text(requiredReason, language: language)
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let isRequired: Bool
    let state: PermissionState
    let permission: PermissionKind
    let settingsLink: URL
    let language: AppLanguage
    let onRequest: () -> Void

    @Environment(\.onboardingUIScaleMetrics) private var uiMetrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: uiMetrics.layout(12)) {
                rowInformation
                    .frame(minWidth: uiMetrics.layout(430), alignment: .leading)
                Spacer(minLength: uiMetrics.layout(12))
                actionButtons
            }
            VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                rowInformation
                actionButtons
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(uiMetrics.layout(10))
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rowInformation: some View {
        HStack(alignment: .top, spacing: uiMetrics.layout(12)) {
            statusIcon
            VStack(alignment: .leading, spacing: uiMetrics.layout(2)) {
                HStack {
                    Text(title).font(uiMetrics.font(.headline))
                    if isRequired {
                        Text(AppLocalizer.text("※必須", language: language))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.red)
                    }
                    Text(statusLabel).font(uiMetrics.font(.caption)).foregroundStyle(statusColor)
                }
                Text(detail).font(uiMetrics.font(.caption)).foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: some View {
        Group {
            switch state {
            case .authorized: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied, .restricted: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .notDetermined: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            }
        }
        .font(uiMetrics.font(.title3))
    }

    private var statusLabel: String {
        switch state {
        case .authorized: return AppLocalizer.text("許可済み", language: language)
        case .denied: return AppLocalizer.text("拒否", language: language)
        case .restricted: return AppLocalizer.text("制限あり", language: language)
        case .notDetermined: return AppLocalizer.text("未確認", language: language)
        }
    }

    private var statusColor: Color {
        switch state {
        case .authorized: return .green
        case .denied, .restricted: return .red
        case .notDetermined: return .orange
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: uiMetrics.layout(8)) {
            switch PermissionActionPolicy.primaryAction(for: state, permission: permission) {
            case .none:
                EmptyView()
            case .request:
                Button(AppLocalizer.text("許可する", language: language)) { onRequest() }
            case .openSystemSettings:
                Button(AppLocalizer.text("システム設定を開く", language: language)) { NSWorkspace.shared.open(settingsLink) }
            }

            if PermissionActionPolicy.showsSystemSettingsSecondaryAction(for: state, permission: permission) {
                Button(AppLocalizer.text("システム設定を開く", language: language)) { NSWorkspace.shared.open(settingsLink) }
            }
        }
        .font(uiMetrics.font(.caption))
    }
}

/// セットアップの入力デバイス確認の進行状態。実測開始前にはメーターを出さない。
enum OnboardingMicrophoneCheckState: Equatable {
    case idle
    case checking
    case voiceDetected
    case confirmed
    case failed

    var showsMeter: Bool {
        self == .checking || self == .voiceDetected
    }
}

/// 保存済みの通過可否と、直近の保存成功表示を分ける。
/// 再入力が失敗しても既存設定を壊さず、緑の成功表示だけは残さない。
struct OnboardingShortcutSetupState: Equatable {
    var isReady = false
    var showsSaveFeedback = false

    mutating func restore(isReady: Bool) {
        self.isReady = isReady
        showsSaveFeedback = false
    }

    mutating func beginCapture() {
        showsSaveFeedback = false
    }

    mutating func save() {
        isReady = true
        showsSaveFeedback = true
    }

    mutating func resetRequirement() {
        isReady = false
        showsSaveFeedback = false
    }
}

/// Step 6の分節メーター。生のPCM波形を保持せず、公開済みの入力レベルだけを表示する。
enum OnboardingAudioLevelMeter {
    static let segmentCount = 15

    static func activeSegmentCount(for level: Double) -> Int {
        let normalized = min(max(level, 0), 1)
        return max(1, min(segmentCount, Int((normalized * Double(segmentCount)).rounded(.up))))
    }
}

private struct SegmentedInputLevelMeter: View {
    let level: Double
    let language: AppLanguage

    @Environment(\.onboardingUIScaleMetrics) private var uiMetrics

    var body: some View {
        let activeCount = OnboardingAudioLevelMeter.activeSegmentCount(for: level)
        HStack(spacing: uiMetrics.layout(10)) {
            Text(AppLocalizer.text("入力レベル", language: language))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: uiMetrics.layout(8))
            HStack(spacing: uiMetrics.layout(6)) {
                ForEach(0..<OnboardingAudioLevelMeter.segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: uiMetrics.layout(3))
                        .fill(index < activeCount ? Color.secondary.opacity(0.65) : Color.secondary.opacity(0.16))
                        .frame(width: uiMetrics.layout(5), height: uiMetrics.layout(18))
                }
            }
        }
        .padding(.horizontal, uiMetrics.layout(12))
        .padding(.vertical, uiMetrics.layout(8))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: uiMetrics.layout(8)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalizer.text("入力レベル", language: language))
        .accessibilityValue("\(activeCount) / \(OnboardingAudioLevelMeter.segmentCount)")
    }
}

/// セットアップ専用の入力レベル確認。PCMをファイルや履歴へ渡さず、RMS値だけを公開する。
@MainActor
private final class MicrophoneLevelProbe: ObservableObject {
    @Published var level: Double = 0
    @Published var hasDetectedVoice = false

    private let recorder = AudioRecorder()
    private var simulationEnabled = false
    private var measurementToken = UUID()
    private var activeMeasurementToken: UUID?

    func setSimulationEnabled(_ enabled: Bool) {
        simulationEnabled = enabled
    }

    func simulateVoice() {
        guard simulationEnabled, activeMeasurementToken != nil else { return }
        level = 0.72
        hasDetectedVoice = true
    }

    func start(preferredUID: String) async throws -> Bool {
        let token = UUID()
        measurementToken = token
        activeMeasurementToken = nil
        await recorder.stop()
        guard measurementToken == token else { return false }
        level = 0
        hasDetectedVoice = false
        if simulationEnabled {
            activeMeasurementToken = token
            return true
        }
        recorder.onBuffer = nil
        // AudioRecorderの消費ループはMainActor外で走る。ここはUI状態しか触らないので、
        // まとめてMainActorへ戻してから判定する。
        recorder.onLevel = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.activeMeasurementToken == token else { return }
                self.level = value
                if value >= 0.08 { self.hasDetectedVoice = true }
            }
        }
        try await recorder.start(targetFormat: nil, preferredMicrophoneUID: preferredUID)
        guard measurementToken == token else {
            await recorder.stop()
            return false
        }
        activeMeasurementToken = token
        return true
    }

    func stop() async {
        measurementToken = UUID()
        activeMeasurementToken = nil
        recorder.onBuffer = nil
        recorder.onLevel = nil
        await recorder.stop()
        level = 0
        hasDetectedVoice = false
    }
}

/// OnboardingViewを保持するオーナー。通常アプリでは必要な時だけウィンドウを表示する。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var suspendedRestartWindow: NSWindow?
    private let permissionManager: PermissionManager
    private let settingsStore: SettingsStore
    private let practiceTranscriptionEngine: TranscriptionEngine?
    private var startsPermissionPolling = false
    private var didTearDownWindow = false

    init(
        permissionManager: PermissionManager,
        settingsStore: SettingsStore,
        practiceTranscriptionEngine: TranscriptionEngine? = nil
    ) {
        self.permissionManager = permissionManager
        self.settingsStore = settingsStore
        self.practiceTranscriptionEngine = practiceTranscriptionEngine
    }

    /// 未完了セットアップまたは後から失われた必須権限を修復する時だけ表示する。
    func showIfNeeded(onFinish: @escaping (OnboardingPresentationMode) -> Void) {
        let progress = settingsStore.settings.setupProgress
        guard !permissionManager.allGranted() || !progress.isComplete else { return }

        let mode: OnboardingPresentationMode
        if progress.isComplete {
            mode = .permissionRecovery
        } else if progress.kind == .upgrade {
            mode = .upgrade
        } else {
            mode = .firstRun
        }
        show(mode: mode, startsPolling: true, onFinish: { onFinish(mode) })
    }

    /// 権限反映のための再起動後だけ、保存済みの意図に従って権限ページを強制表示する。
    func showRestartIntent(
        _ intent: OnboardingRestartIntent,
        onPresented: @escaping () -> Void,
        onFinish: @escaping (OnboardingPresentationMode) -> Void
    ) {
        let mode = intent.presentationMode
        guard !mode.isDebug, !mode.isGuide else { return }
        show(
            mode: mode,
            forcedInitialStep: intent.step,
            initialRestartFeedback: OnboardingRestartFeedbackPolicy.initialFeedbackKey(for: intent),
            startsPolling: true,
            onForcedInitialStepPresented: onPresented,
            onFinish: { onFinish(mode) }
        )
    }

    /// 完了済みユーザー向けの任意ガイド。通常のセットアップ完了状態は変えない。
    func showGuide() {
        show(mode: .guide, startsPolling: false, onFinish: {})
    }

    private func show(
        mode: OnboardingPresentationMode,
        forcedInitialStep: OnboardingStep? = nil,
        initialRestartFeedback: String? = nil,
        startsPolling: Bool,
        onForcedInitialStepPresented: (() -> Void)? = nil,
        onFinish: @escaping () -> Void
    ) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            mode: mode,
            forcedInitialStep: forcedInitialStep,
            initialRestartFeedback: initialRestartFeedback,
            onForcedInitialStepPresented: onForcedInitialStepPresented,
            onRestartPreparationCompleted: { [weak self] in
                self?.suspendForRestart()
            },
            onRestartFailure: { [weak self] in
                self?.restoreAfterRestartFailure()
            },
            onFinish: { [weak self] in
                self?.closeAfterCompletion()
                onFinish()
            },
            practiceTranscriptionEngine: practiceTranscriptionEngine
        )
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = mode.title(for: settingsStore.settings.languagePreferences.uiLanguage)
        // 閉じても進捗を保持してメニューバーから再開できるため、macOS標準の閉じる操作を有効にする。
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(
            width: OnboardingUIScaleMetrics.defaultWindowSize.width,
            height: OnboardingUIScaleMetrics.defaultWindowSize.height
        ))
        window.contentMinSize = NSSize(
            width: OnboardingUIScaleMetrics.minimumWindowSize.width,
            height: OnboardingUIScaleMetrics.minimumWindowSize.height
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        startsPermissionPolling = startsPolling
        didTearDownWindow = false

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if startsPolling {
            permissionManager.startPolling()
        }
    }

    /// 完了時とユーザーが左上×を押した時の両方から呼ばれる。
    /// 完了以外ではonFinishを実行しないため、未完了の音声入力・hotkeyを起動しない。
    func windowWillClose(_ notification: Notification) {
        tearDownWindow()
    }

    private func closeAfterCompletion() {
        let closingWindow = window
        tearDownWindow()
        closingWindow?.close()
    }

    /// 新しい.appの起動を要求する前に、旧ウィンドウを一度だけ画面から外す。
    /// closeではなくorderOutにするため、起動失敗時は同じ進捗・同じ画面へ戻せる。
    private func suspendForRestart() {
        guard let window else { return }
        suspendedRestartWindow = window
        tearDownWindow()
        window.orderOut(nil)
    }

    private func restoreAfterRestartFailure() {
        guard let window = suspendedRestartWindow else { return }
        suspendedRestartWindow = nil
        self.window = window
        didTearDownWindow = false
        startsPermissionPolling = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        permissionManager.startPolling()
    }

    private func tearDownWindow() {
        guard !didTearDownWindow else { return }
        didTearDownWindow = true
        NotificationCenter.default.post(name: .onboardingWindowWillClose, object: nil)
        settingsStore.flushPendingSave()
        if startsPermissionPolling {
            permissionManager.stopPolling()
        }
        window = nil
        startsPermissionPolling = false
        // 通常版はDock常駐を維持する。Debug.appは従来どおりregularのままにする。
        if !OnboardingRuntimeProfile.isDebug {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
