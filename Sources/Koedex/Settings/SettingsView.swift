import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

private enum SettingsTab: String, CaseIterable, Identifiable {
    case settings
    case history
    case userDictionary

    var id: String { rawValue }

    func title(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .settings: japanese = "設定"
        case .history: japanese = "履歴"
        case .userDictionary: japanese = "ユーザー辞書"
        }
        return AppLocalizer.text(japanese, language: language)
    }

    var iconName: String {
        switch self {
        case .settings: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        case .userDictionary: return "book"
        }
    }
}

private enum HistoryRetentionOption: Int, CaseIterable, Identifiable {
    case doNotSaveFuture = -1
    case oneDay = 1
    case oneMonth = 30
    case sixMonths = 180
    case unlimited = 0

    var id: Int { rawValue }

    func label(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .doNotSaveFuture: japanese = "保存しない"
        case .oneDay: japanese = "1日"
        case .oneMonth: japanese = "30日"
        case .sixMonths: japanese = "180日"
        case .unlimited: japanese = "無期限"
        }
        return AppLocalizer.text(japanese, language: language)
    }

    var retentionDays: Int {
        switch self {
        case .doNotSaveFuture: return 0
        case .oneDay: return 1
        case .oneMonth: return 30
        case .sixMonths: return 180
        case .unlimited: return 0
        }
    }

    var isSavingEnabled: Bool {
        self != .doNotSaveFuture
    }

    static func current(enabled: Bool, retentionDays: Int) -> HistoryRetentionOption {
        guard enabled else { return .doNotSaveFuture }
        switch retentionDays {
        case 1:
            return .oneDay
        case 30:
            return .oneMonth
        case 180:
            return .sixMonths
        case ...0:
            return .unlimited
        default:
            return retentionDays <= 30 ? .oneMonth : .sixMonths
        }
    }
}

private enum HistoryViewMode: String, CaseIterable, Identifiable {
    case normal
    case selectToDelete

    var id: String { rawValue }

    func label(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .normal: japanese = "通常表示"
        case .selectToDelete: japanese = "選択して削除"
        }
        return AppLocalizer.text(japanese, language: language)
    }
}

private enum HistoryModeFilter: String, CaseIterable, Identifiable {
    case all
    case voiceInput
    case handsFreeSend
    case aiCommand

    var id: String { rawValue }
    func label(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .all: japanese = "すべて"
        case .voiceInput: japanese = "通常モード"
        case .handsFreeSend: japanese = "ハンズフリー送信モード"
        case .aiCommand: japanese = "AIに指示モード"
        }
        return AppLocalizer.text(japanese, language: language)
    }
    var storedMode: String {
        switch self {
        case .all: return InputHistoryMode.all
        case .voiceInput: return InputHistoryMode.voiceInput
        case .handsFreeSend: return InputHistoryMode.handsFreeSend
        case .aiCommand: return InputHistoryMode.aiCommand
        }
    }
}

private enum HistoryDeletionKind {
    case all
    case selected
    case unselectedDisplayed
    case metadataOnly

    func title(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .all: japanese = "履歴をすべて削除"
        case .selected: japanese = "チェックした履歴を削除"
        case .unselectedDisplayed: japanese = "チェックしたもの以外を削除"
        case .metadataOnly: japanese = "表示されていないメタデータを削除"
        }
        return AppLocalizer.text(japanese, language: language)
    }
}

private enum HistoryRetentionScope {
    case normal
    case handsFreeSend
    case aiCommand

    func title(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .normal:
            japanese = "通常モード（出力履歴）"
        case .handsFreeSend:
            japanese = "ハンズフリー送信モード（出力履歴）"
        case .aiCommand:
            japanese = "AIに指示モード（指示文の履歴）"
        }
        return AppLocalizer.text(japanese, language: language)
    }

    var historyMode: String {
        switch self {
        case .normal:
            return InputHistoryMode.voiceInput
        case .handsFreeSend:
            return InputHistoryMode.handsFreeSend
        case .aiCommand:
            return InputHistoryMode.aiCommand
        }
    }
}

private struct HistoryRetentionChangeRequest {
    var scope: HistoryRetentionScope
    var option: HistoryRetentionOption
}

private struct HistoryDeletionRequest {
    var kind: HistoryDeletionKind
    var targetIDs: Set<UUID>
    var storedTextCount: Int
    var metadataOnlyCount: Int
}

enum LanguageSettingsControlPolicy {
    static func isSpeechLanguagePickerDisabled(
        phase: PipelinePhase,
        isChangingSpeechLanguage: Bool
    ) -> Bool {
        isChangingSpeechLanguage || phase != .idle
    }
}

/// 表示用のphaseスナップショットは遅延し得るため、録音系を止める再設定の実行可否には
/// 必ずライブの`AppState.phase`を渡す。
enum SettingsActionSafetyPolicy {
    static func allowsReconfiguration(phase: PipelinePhase) -> Bool {
        phase == .idle
    }
}

/// `SettingsView`が`body`外で保持するクリップボード変種の派生状態。
///
/// 録音中のaudio-level更新でSettings全体が再評価されても、ここで持つ値の参照だけで
/// Pickerと警告を描画できるようにする。重いホットキー判定とローカライズは、設定または
/// 表示言語が変わった時だけ`make`で行う。
struct AICommandClipboardSettingsDerivedState {
    let eligibilities: [AICommandClipboardModifier: AICommandClipboardChordPolicy.Eligibility]
    let pickerOptions: [AICommandClipboardModifier]
    let ineligibilityMessage: String?

    static func make(
        startBinding: HotkeyBinding,
        stopBinding: HotkeyBinding,
        normalBinding: HotkeyBinding,
        handsFreeSendBinding: HotkeyBinding,
        handsFreeSendEnabled: Bool,
        clipboardVariantEnabled: Bool,
        currentModifier: AICommandClipboardModifier,
        language: AppLanguage
    ) -> Self {
        let eligibilities = AICommandClipboardChordPolicy.eligibilities(
            startBinding: startBinding,
            stopBinding: stopBinding,
            normalBinding: normalBinding,
            handsFreeSendBinding: handsFreeSendBinding,
            handsFreeSendEnabled: handsFreeSendEnabled
        )
        let currentEligibility = eligibilities[currentModifier] ?? .eligible
        return Self(
            eligibilities: eligibilities,
            pickerOptions: AICommandClipboardChordPolicy.pickerOptions(
                eligibilities: eligibilities,
                current: currentModifier
            ),
            ineligibilityMessage: clipboardVariantEnabled
                ? AICommandClipboardEligibilityCopy.message(
                    for: currentEligibility,
                    language: language
                )
                : nil
        )
    }
}

struct SettingsView: View {
    private enum KeyCaptureTarget { case normal, aiStart, aiStop, handsFreeSend }
    @ObservedObject var store: SettingsStore
    @ObservedObject var appDelegate: AppDelegate
    /// `audioLevel`を含むAppState全体の変更でSettings全体を再描画しない。
    /// `observedPipelinePhase`だけを`onReceive`で更新する。
    let appState: AppState
    @ObservedObject var historyStore: InputHistoryStore
    @ObservedObject var dictionaryStore: PersonalDictionaryStore
    @ObservedObject var customInstructionStateStore: CustomInstructionStateStore
    @ObservedObject var aiCommandCustomInstructionStateStore: CustomInstructionStateStore
    @State private var selectedTab: SettingsTab = .settings
    @State private var isCapturingKey = false
    @State private var keyCaptureTarget: KeyCaptureTarget = .normal
    @StateObject private var keyCaptureMonitor = HotkeyCaptureMonitor()
    @State private var microphones: [MicrophoneDevice] = []
    @State private var defaultMicrophoneName = ""
    @State private var fetchedModels: [CodexModelInfo] = CodexModelCatalog.builtInModels
    @State private var isRefreshingModels = false
    @State private var isModelCatalogVerified = false
    @State private var didResolveInitialModelDefaults = false
    @State private var isSavingModelSettings = false
    @State private var modelFetchMessage: String?
    @State private var normalModelSaveOperationID: UUID?
    @State private var aiCommandSettingsMessage: String?
    /// 初回描画だけは安全側に倒し、`onAppear`で現在のphaseを取り込む。
    @State private var observedPipelinePhase: PipelinePhase = .starting
    /// ホットキー由来の重い判定のキャッシュ。**`body`の中で計算しないこと。**
    ///
    /// `AppState`を全体購読すると、`audioLevel`の更新で録音中に`body`が毎秒数十回、
    /// MainActor上で再評価される。Settingsではphaseだけを購読し、ここで保存した
    /// 値だけを読むことでHUD描画とSpeechAnalyzerへの音声供給を阻害しない。
    ///
    /// そこで`HotkeyBinding(keys:)`（重複排除→正規化→ソート）や`Set`確保を伴う判定を
    /// `body`に置くと、SpeechAnalyzerへの音声供給とHUD描画からMainActorを奪う。
    /// これは`RecordingHUD.swift:483-492`に記録されている競合と同じ機構で、実機では
    /// `volatileIntervalMedianMs`が0→189〜286、ハンズフリー送信の応答が
    /// 362〜406ms→556〜709msへ悪化した（2026-08-08 実測）。
    @State private var cachedClipboardVariantEligibilities: [
        AICommandClipboardModifier: AICommandClipboardChordPolicy.Eligibility
    ] = Dictionary(
        uniqueKeysWithValues: AICommandClipboardModifier.allCases.map { ($0, .eligible) }
    )
    @State private var cachedClipboardVariantPickerOptions = AICommandClipboardModifier.allCases
    @State private var cachedClipboardVariantEligibilityMessage: String?
    @State private var cachedNormalHoldStartRequiresSpecialChordResolution = false
    @State private var aiCommandModelSettingsMessage: String?
    /// 保存中の再接続メッセージとは別に、Web検索を自動的にオフにした理由を残す。
    @State private var aiCommandModelSettingsNotice: String?
    @State private var isSavingAICommandModelSettings = false
    @State private var isResettingAIProcessing = false
    @State private var aiProcessingResetStatus: AIProcessingResetStatus?
    @State private var aiProcessingResetDismissTask: Task<Void, Never>?
    @State private var aiCommandModelSaveOperationID: UUID?
    @State private var historyViewMode: HistoryViewMode = .normal
    @State private var historyModeFilter: HistoryModeFilter = .all
    @State private var selectedHistoryIDs: Set<UUID> = []
    @State private var historyDeletionRequest: HistoryDeletionRequest?
    @State private var historyDeleteTarget: UUID?
    @State private var historySearchText = ""
    @State private var historyOperationMessage: String?
    @State private var pendingHistoryRetentionChange: HistoryRetentionChangeRequest?
    @State private var hoveredHistoryCopyID: UUID?
    @State private var copiedHistoryEntryID: UUID?
    @State private var isOptimizingCustomInstruction = false
    @State private var customInstructionMessage: String?
    @State private var optimizationDraft: CustomInstructionOptimizationDraft?
    @State private var customInstructionDraft = ""
    @State private var customInstructionHistoryCursor = -1
    @State private var isOptimizingAICommandCustomInstruction = false
    @State private var aiCommandCustomInstructionMessage: String?
    @State private var aiCommandCustomInstructionDraft = ""
    @State private var aiCommandCustomInstructionHistoryCursor = -1
    @State private var modelSettingsDraft = CodexModelSettings.default
    @State private var aiCommandModelSettingsDraft = AICommandSettings.default.modelSettings
    @State private var aiCommandWebSearchDraft = AICommandSettings.default.webSearchEnabled
    @State private var codexExecutablePathDraft = ""
    @State private var isChangingSpeechLanguage = false
    @State private var languageSettingsMessage: String?
    @State private var showsExternalSendConfirmation = false
    @State private var handsFreeSendSettingsMessage: String?
    @State private var handsFreeSendCustomPhraseDraft = ""
    @State private var handsFreeSendCustomPhraseError: String?
    /// 保存で確定したら入力欄をロックする。キャレットが点滅し続けると
    /// 保存されたのか分からない。「編集」で再び開く。
    @State private var handsFreeSendCustomPhraseIsEditing = false
    @FocusState private var handsFreeSendCustomPhraseFieldIsFocused: Bool

    private var uiMetrics: SettingsUIScaleMetrics {
        SettingsUIScaleMetrics(
            scale: store.settings.settingsDisplayScale,
            language: store.settings.languagePreferences.uiLanguage
        )
    }

    private var popupMetrics: PopupUIScaleMetrics {
        PopupUIScaleMetrics(settingsMetrics: uiMetrics)
    }

    private var uiLanguage: AppLanguage {
        store.settings.languagePreferences.uiLanguage
    }

    private func uiText(_ japanese: String) -> String {
        AppLocalizer.text(japanese, language: uiLanguage)
    }

    private func uiFormat(_ japanese: String, _ arguments: CVarArg...) -> String {
        String(format: uiText(japanese), locale: uiLanguage.locale, arguments: arguments)
    }

    private func updateSettingsWindowTitle() {
        guard !OnboardingRuntimeProfile.isDebug else { return }
        NSApp.mainWindow?.title = uiText("Koedex 設定")
    }

    private var uiLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { store.settings.languagePreferences.uiLanguage },
            set: { language in
                guard language != store.settings.languagePreferences.uiLanguage else { return }
                store.settings.languagePreferences.uiLanguage = language
                languageSettingsMessage = nil
                store.flushPendingSave()
            }
        )
    }

    private var sttLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { store.settings.languagePreferences.sttLanguage },
            set: { language in
                guard language != store.settings.languagePreferences.sttLanguage,
                      !isChangingSpeechLanguage,
                      SettingsActionSafetyPolicy.allowsReconfiguration(
                        phase: appState.phase
                      ) else { return }
                isChangingSpeechLanguage = true
                languageSettingsMessage = nil
                Task {
                    let result = await appDelegate.prepareSpeechLanguageChange(to: language)
                    await MainActor.run {
                        isChangingSpeechLanguage = false
                        switch result {
                        case .success:
                            store.settings.languagePreferences.sttLanguage = language
                            store.flushPendingSave()
                        case .failure:
                            languageSettingsMessage = uiText("音声認識言語を変更できませんでした。権限と音声モデルを確認して、もう一度試してください。")
                        }
                    }
                }
            }
        )
    }

    private var aiOutputLanguageBinding: Binding<AIOutputLanguage> {
        Binding(
            get: { store.settings.languagePreferences.aiOutputLanguage },
            set: { language in
                guard language != store.settings.languagePreferences.aiOutputLanguage else { return }
                store.settings.languagePreferences.aiOutputLanguage = language
                languageSettingsMessage = nil
                store.flushPendingSave()
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            saveBlockedBanner

            HStack(spacing: 0) {
                sidebar

                Group {
                    switch selectedTab {
                    case .settings:
                        settingsPage
                    case .history:
                        historyPage
                    case .userDictionary:
                        UserDictionaryWindow(dictionaryStore: dictionaryStore, language: uiLanguage)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(
            minWidth: uiMetrics.minimumWindowWidth,
            idealWidth: uiMetrics.idealWindowWidth,
            minHeight: uiMetrics.minimumWindowHeight,
            idealHeight: uiMetrics.idealWindowHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SettingsWindowBehaviorBridge())
        .settingsUIScale(uiMetrics)
        .environment(\.locale, store.settings.languagePreferences.uiLanguage.locale)
        .onAppear {
            observedPipelinePhase = appState.phase
            updateSettingsWindowTitle()
            initializeDraftsFromSettings()
            refreshMicrophones()
            refreshModelCatalog()
            refreshHotkeyDerivedState()
        }
        .onReceive(appState.$phase.removeDuplicates()) { phase in
            observedPipelinePhase = phase
        }
        .onReceive(NotificationCenter.default.publisher(for: .koedexOpenDictionaryRecovery)) { _ in
            selectedTab = .userDictionary
        }
        .onReceive(NotificationCenter.default.publisher(for: .koedexOpenHistoryStorage)) { _ in
            selectedTab = .history
        }
        .onChange(of: hotkeyDerivedStateKey) {
            refreshHotkeyDerivedState()
        }
        .onChange(of: uiLanguage) {
            updateSettingsWindowTitle()
            refreshMicrophones()
            refreshHotkeyDerivedState()
        }
        .onDisappear {
            stopKeyCapture()
            // 4秒の消去待ちが残っていると、閉じたあともViewを掴んだままになる。
            aiProcessingResetDismissTask?.cancel()
            aiProcessingResetDismissTask = nil
        }
        .sheet(item: $optimizationDraft) { draft in
            optimizationPreviewSheet(draft)
        }
        .sheet(isPresented: historyDeletionConfirmationBinding) {
            AppConfirmationSheet(
                title: historyDeletionTitle,
                message: historyDeletionMessage,
                confirmTitle: uiText("削除"),
                confirmRole: .destructive,
                metrics: popupMetrics,
                onConfirm: { performHistoryDeletion() },
                onCancel: { historyDeletionRequest = nil }
            )
        }
        .sheet(isPresented: historyRetentionConfirmationBinding) {
            AppConfirmationSheet(
                title: uiText("本当に変更しますか？"),
                message: historyRetentionConfirmationMessage,
                confirmTitle: uiText("変更"),
                confirmRole: nil,
                metrics: popupMetrics,
                onConfirm: {
                    if let request = pendingHistoryRetentionChange {
                        applyHistoryRetention(request.option, scope: request.scope)
                    }
                    pendingHistoryRetentionChange = nil
                },
                onCancel: { pendingHistoryRetentionChange = nil }
            )
        }
        .sheet(isPresented: historyDeleteConfirmationBinding) {
            AppConfirmationSheet(
                title: uiText("履歴を削除"),
                message: uiText("この履歴を削除します。"),
                confirmTitle: uiText("削除"),
                confirmRole: .destructive,
                metrics: popupMetrics,
                onConfirm: {
                    if let id = historyDeleteTarget {
                        let result = historyStore.delete(id: id)
                        if result == .saved { selectedHistoryIDs.remove(id) }
                        showHistoryMutationResult(result)
                    }
                    historyDeleteTarget = nil
                },
                onCancel: { historyDeleteTarget = nil }
            )
        }
        .sheet(isPresented: $showsExternalSendConfirmation) {
            AppConfirmationSheet(
                title: uiText("外部アプリでの自動送信を有効にしますか？"),
                message: uiText("ブラウザやElectronアプリでは、本文反映を確認できないことがあります。送信は取り消せません。本文入力後も録音停止時と同じ編集可能な入力欄を確認できた時だけ、Enter系キーを自動送信することを許可します。確認できない場合は文字だけ入力します。"),
                confirmTitle: uiText("有効にする"),
                confirmRole: nil,
                metrics: popupMetrics,
                onConfirm: {
                    guard store.settings.handsFreeSendSettings.enabled,
                          store.settings.externalAppCompatibilitySettings.enabled else {
                        return
                    }
                    store.settings.handsFreeSendSettings.allowExternalAutoSend = true
                    store.flushPendingSave()
                },
                onCancel: { showsExternalSendConfirmation = false }
            )
        }
    }

    @ViewBuilder
    private var saveBlockedBanner: some View {
        if let status = store.saveBlockedStatus {
            HStack(alignment: .top, spacing: uiMetrics.layout(10)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: uiMetrics.layout(4)) {
                    Text(uiText("設定を保存できません"))
                        .font(uiMetrics.font(.body))
                        .bold()
                    Text(saveBlockedReasonText(status))
                        .font(uiMetrics.font(.caption))
                    Text(uiText("ここでの変更は保存されません。次回起動時には元の状態に戻ります。"))
                        .font(uiMetrics.font(.caption))
                    Text(uiText(
                        "Koedexを終了し、~/Library/Application Support/Koedex/settings.json を退避または削除してから、Koedexを再起動してください。"
                    ))
                        .font(uiMetrics.font(.caption))
                }
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(uiMetrics.layout(12))
            .background(Color.red.opacity(0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.red.opacity(0.3)), alignment: .bottom)
        }
    }

    private func saveBlockedReasonText(_ status: SettingsStore.LoadStatus) -> String {
        switch status {
        case .failedToDecode:
            return uiText("原因: 設定ファイル（settings.json）を読み込めませんでした。")
        case .failedToMigrate:
            return uiText("原因: 設定ファイルの移行に失敗しました。")
        case .newInstall, .loaded, .migrated:
            return ""
        }
    }

    private var sidebar: some View {
        ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: uiMetrics.layout(16), style: .continuous)
            .fill(Color.secondary.opacity(0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: uiMetrics.layout(16), style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.title(for: uiLanguage), systemImage: tab.iconName)
                            .font(uiMetrics.font(.body))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, uiMetrics.layout(12))
                            .padding(.vertical, uiMetrics.layout(9))
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                }

                Spacer()

                displayScaleControl
            }
            .padding(.horizontal, uiMetrics.layout(14))
        .padding(.top, uiMetrics.sidebarTabTopInset)
            .padding(.bottom, uiMetrics.layout(14))
        }
        .frame(width: uiMetrics.sidebarContentWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(uiMetrics.sidebarShellInset)
        .frame(width: uiMetrics.sidebarOuterWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var displayScaleControl: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            Divider()
            Text(uiText("表示サイズ"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            HStack(spacing: uiMetrics.layout(5)) {
                Image(systemName: "textformat.size.smaller")
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                Slider(
                    value: settingsDisplayScaleBinding,
                    in: KoedexSettings.settingsDisplayScaleMinimum...KoedexSettings.settingsDisplayScaleMaximum,
                    step: KoedexSettings.settingsDisplayScaleStep
                )
                Image(systemName: "textformat.size.larger")
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Text("\(Int((store.settings.settingsDisplayScale * 100).rounded()))%")
                .font(uiMetrics.font(.caption))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
            Text(uiText("100%（標準）"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Button(uiText("100%（標準）に戻す")) {
                store.setSettingsDisplayScale(SettingsUIScaleMetrics.standardScale)
            }
            .buttonStyle(.plain)
            .font(uiMetrics.font(.caption))
            .foregroundStyle(store.settings.settingsDisplayScale == SettingsUIScaleMetrics.standardScale ? Color.secondary : Color.accentColor)
            .disabled(store.settings.settingsDisplayScale == SettingsUIScaleMetrics.standardScale)
        }
        .padding(.top, uiMetrics.layout(8))
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: uiMetrics.layout(16)) {
                Text(uiText("設定"))
                    .font(uiMetrics.font(.title))
                    .bold()
                    .textSelection(.enabled)

                onboardingGuideSection
                languageSettingsSection
                microphoneSettingsSection
                autoStopSettingsSection
                externalAppCompatibilitySettingsSection
                aiAssistToggleSection
                normalHotkeySettingsSection
                normalModelSettingsSection
                normalCustomInstructionSettingsSection
                aiCommandToggleSettingsSection
                aiCommandHotkeySettingsSection
                aiCommandModelSettingsSection
                aiCommandCustomInstructionSettingsSection
                handsFreeSendSettingsSection
                optimizationModelSettingsSection
                aiProcessingResetSettingsSection
                codexExecutablePathSettingsSection
            }
            .padding(.horizontal, uiMetrics.layout(24))
            .padding(.bottom, uiMetrics.layout(24))
            .padding(.top, uiMetrics.layout(24))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var aiAssistToggleSection: some View {
        settingsSection {
            Toggle(uiText("AIアシスト"), isOn: $store.settings.cleanupEnabled)
                .toggleStyle(.switch)
            helperText("オン：フィラー除去・句読点補正等、AIによる文章整形を行ってから挿入します。オフ：音声認識した結果をそのまま即挿入します。")
        }
    }

    private var languageSettingsSection: some View {
        settingsSection {
            sectionTitle("言語")

            VStack(alignment: .leading, spacing: uiMetrics.layout(7)) {
                HStack(alignment: .firstTextBaseline, spacing: uiMetrics.layout(12)) {
                    Text(uiText("表示言語"))
                        .font(uiMetrics.font(.subheadline))
                        .bold()
                        .lineLimit(1)
                    Spacer(minLength: uiMetrics.layout(12))
                    Picker("", selection: uiLanguageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.localizedDisplayName(for: store.settings.languagePreferences.uiLanguage))
                                .tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel(uiText("表示言語"))
                }
                helperText("設定画面、メニューバー、オンボーディング、HUDなどの表示言語です。")
            }

            VStack(alignment: .leading, spacing: uiMetrics.layout(7)) {
                HStack(alignment: .firstTextBaseline, spacing: uiMetrics.layout(12)) {
                    Text(uiText("音声認識言語"))
                        .font(uiMetrics.font(.subheadline))
                        .bold()
                        .lineLimit(1)
                    Spacer(minLength: uiMetrics.layout(12))
                    Picker("", selection: sttLanguageBinding) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.localizedDisplayName(for: store.settings.languagePreferences.uiLanguage))
                                .tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel(uiText("音声認識言語"))
                    .disabled(LanguageSettingsControlPolicy.isSpeechLanguagePickerDisabled(
                        phase: observedPipelinePhase,
                        isChangingSpeechLanguage: isChangingSpeechLanguage
                    ))
                }
                if isChangingSpeechLanguage {
                    HStack(spacing: uiMetrics.layout(6)) {
                        ProgressView()
                            .controlSize(.small)
                        Text(uiText("音声モデルを準備しています…"))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                helperText("対応する音声モデルを準備してから切り替えます。切り替えまでしばらく時間がかかります。録音中・処理中は変更できません。")
            }

            VStack(alignment: .leading, spacing: uiMetrics.layout(7)) {
                HStack(alignment: .firstTextBaseline, spacing: uiMetrics.layout(12)) {
                    Text(uiText("AI出力言語"))
                        .font(uiMetrics.font(.subheadline))
                        .bold()
                        .lineLimit(1)
                    Spacer(minLength: uiMetrics.layout(12))
                    Picker("", selection: aiOutputLanguageBinding) {
                        ForEach(AIOutputLanguage.allCases) { language in
                            Text(language.localizedDisplayName(for: store.settings.languagePreferences.uiLanguage))
                                .tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityLabel(uiText("AI出力言語"))
                }
            helperText("AIアシストが有効な場合、すべてのモードにおいて、選択した言語で出力されます。ただし、音声で明示した出力言語の指定は常に優先されます。")
            }

            if let languageSettingsMessage {
                helperText(languageSettingsMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    private var onboardingGuideSection: some View {
        settingsSection {
            sectionTitle("セットアップガイド")
            helperText("通常モードとAIに指示モードの違い、起動・停止キー、Web検索時の扱いをもう一度短く確認できます。既存の設定は変更されません。")
            Button(uiText("セットアップガイドを開く")) {
                appDelegate.showOnboardingGuide()
            }
        }
    }

    private var normalHotkeySettingsSection: some View {
        settingsSection {
            sectionTitle("通常モードの起動キー設定")

            VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                Text(uiFormat("現在の起動キー: %@", humanReadableKeyName))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(uiText(isCapturingKey && keyCaptureTarget == .normal ? "キーを押してください..." : "起動キーを変更")) {
                    startKeyCapture(target: .normal)
                }
                .disabled(isCapturingKey)
            }

            VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
                Text(uiText("録音方式"))
                    .font(uiMetrics.font(.subheadline))
                    .bold()
                Picker(uiText("録音方式"), selection: recordingModeBinding) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName(for: uiLanguage)).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if store.settings.hotkeyKeyCode == HotkeyDefaults.fnKeyCode {
                fnKeyNotice
            }
        }
    }

    private var normalModelSettingsSection: some View {
        settingsSection {
            sectionTitle("AIアシストのモデル選択")
            helperText("この設定はKoedex内のAIアシストにだけ使われ、Codex CLI全体の設定は変更しません。")
            helperText("新規インストール時は、モデル一覧で利用可能な場合にGPT-5.6 Luna/low がデフォルトとして設定されます。")

            Picker(uiText("モデルプリセット"), selection: modelPresetBinding) {
                Text(uiText("Codex CLI設定に従う")).tag("cli")
                ForEach(CodexModelCatalog.builtInPresets) { preset in
                    Text(preset.displayName(for: uiLanguage)).tag(preset.id)
                }
                Text(uiText("カスタム選択")).tag("custom")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!store.settings.cleanupEnabled || isSavingModelSettings)

            if modelSettingsDraft.mode != .cli {
                modelAndReasoningPickerRow(
                    model: {
                        modelPickerColumn(models: availableModels, selection: selectedModelBinding)
                    },
                    reasoning: {
                        reasoningPickerColumn(levels: supportedReasoningLevels, selection: selectedReasoningBinding)
                    }
                )
                .disabled(!store.settings.cleanupEnabled || isSavingModelSettings)

                if let selectedModelInfo {
                    helperText(
                        CodexModelCatalog.userFacingDescription(for: selectedModelInfo, language: uiLanguage),
                        localize: false
                    )
                } else if !normalModelIsAvailable {
                    helperText("保存済みのモデルは現在利用できません。利用可能なモデルを選び直してください。")
                }
            }

            helperTextVerbatim(modelCatalogNotice)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: uiMetrics.layout(10)) {
                    normalModelActionButtons
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    normalModelActionButtons
                }
            }

            if let modelFetchMessage {
                Text(modelFetchMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var normalModelActionButtons: some View {
        Button(uiText("モデル一覧を更新")) {
            refreshModelCatalog()
        }
        .disabled(isRefreshingModels || isSavingModelSettings)

        Button(uiText("保存")) {
            saveModelSettings()
        }
        .disabled(!store.settings.cleanupEnabled || !hasModelSettingsChanges || !normalModelIsAvailable || !isModelCatalogVerified || isSavingModelSettings || isVoiceProcessing)

        if isRefreshingModels || isSavingModelSettings {
            ProgressView()
                .controlSize(uiMetrics.controlSize)
        }
    }

    @ViewBuilder
    private func modelAndReasoningPickerRow<ModelColumn: View, ReasoningColumn: View>(
        @ViewBuilder model: () -> ModelColumn,
        @ViewBuilder reasoning: () -> ReasoningColumn
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: uiMetrics.modelPickerGap) {
                model()
                    .fixedSize(horizontal: true, vertical: false)
                reasoning()
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                model()
                    .frame(maxWidth: .infinity, alignment: .leading)
                reasoning()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: uiMetrics.contentWidth(640), alignment: .leading)
    }

    private func modelPickerColumn(
        models: [CodexModelInfo],
        selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(5)) {
            Text(uiText("モデル")).font(uiMetrics.font(.caption)).foregroundStyle(.secondary)
            Picker(uiText("モデル"), selection: selection) {
                ForEach(models) { model in
                    Text(model.displayName).tag(model.slug)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func reasoningPickerColumn(
        levels: [CodexReasoningLevel],
        selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(5)) {
            Text(uiText("推論レベル")).font(uiMetrics.font(.caption)).foregroundStyle(.secondary)
            Picker(uiText("推論レベル"), selection: selection) {
                ForEach(levels) { level in
                    Text(reasoningLevelLabel(level)).tag(level.effort)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var normalCustomInstructionSettingsSection: some View {
        settingsSection {
            sectionTitle("カスタムインストラクション（通常モード / ハンズフリー送信モード）")
            helperText("AIアシストの際に追加で伝えたい文体・形式の指示を記入してください（例: 敬語で統一する、箇条書きは使わない、等）。")
            helperText("通常モードとハンズフリー送信モードのAI整形に適用されます。変更は次の録音から反映されます。")

            VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                TextEditor(text: $customInstructionDraft)
                    .frame(minHeight: uiMetrics.layout(100))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(uiMetrics.font(.body))
                    .disabled(!store.settings.cleanupEnabled)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: uiMetrics.layout(10)) {
                        normalCustomInstructionActionRow
                    }
                    VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                        HStack(spacing: uiMetrics.layout(10)) {
                            normalCustomInstructionPrimaryButtons
                        }
                        HStack(spacing: uiMetrics.layout(10)) {
                            normalCustomInstructionHistoryButtons
                        }
                    }
                }
            }
            .frame(maxWidth: uiMetrics.contentWidth(640), alignment: .leading)

            if let customInstructionMessage {
                Text(customInstructionMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var normalCustomInstructionActionRow: some View {
        Button(uiText("最適化")) {
            optimizeCustomInstruction()
        }
        .disabled(!canOptimizeCustomInstruction)

        Spacer()
        normalCustomInstructionHistoryButtons
        Button(uiText("保存")) {
            saveCustomInstruction()
        }
        .disabled(!store.settings.cleanupEnabled || !hasCustomInstructionChanges)

        if isOptimizingCustomInstruction {
            ProgressView()
                .controlSize(uiMetrics.controlSize)
        }
    }

    @ViewBuilder
    private var normalCustomInstructionPrimaryButtons: some View {
        Button(uiText("最適化")) {
            optimizeCustomInstruction()
        }
        .disabled(!canOptimizeCustomInstruction)

        Button(uiText("保存")) {
            saveCustomInstruction()
        }
        .disabled(!store.settings.cleanupEnabled || !hasCustomInstructionChanges)

        if isOptimizingCustomInstruction {
            ProgressView()
                .controlSize(uiMetrics.controlSize)
        }
    }

    @ViewBuilder
    private var normalCustomInstructionHistoryButtons: some View {
        Button {
            stepCustomInstructionHistory(by: -1)
        } label: {
            Image(systemName: "arrow.left")
        }
        .disabled(!canStepCustomInstructionHistoryBackward)
        .help(uiText("保存済み履歴を1つ戻る"))

        Button {
            stepCustomInstructionHistory(by: 1)
        } label: {
            Image(systemName: "arrow.right")
        }
        .disabled(!canStepCustomInstructionHistoryForward)
        .help(uiText("保存済み履歴を1つ進む"))
    }

    private var aiCommandToggleSettingsSection: some View {
        settingsSection {
            Toggle(uiText("AIに指示モード"), isOn: aiCommandEnabledBinding)
                .toggleStyle(.switch)
            helperText("選択したテキストへの編集指示や質問ができます。また、テキスト選択をせずにAIへの質問も音声で行えます。オフの場合は起動／停止キーは無効になり、変更はできません。")
        }
    }

    private var externalAppCompatibilitySettingsSection: some View {
        settingsSection {
            sectionTitle("ブラウザや各種アプリへ対応（テキストを直接挿入できないアプリやWebページに対し、別の入力方法を使います）")
            Toggle(uiText("互換入力モード（ON推奨）"), isOn: externalAppCompatibilityEnabledBinding)
                .toggleStyle(.switch)
            helperText("ON: 外部アプリでの選択取得と直接入力を許可します。AXで反映を確認できない欄では、クリップボードを変更しない仮想入力を使います。入力先によってはアプリ側で反映確認できないことがあります。\nOFF: 互換が必要な外部アプリでは結果を別ウィンドウに表示します。")

            Toggle(uiText("AIに指示モードの結果を直接挿入する"), isOn: externalAICommandAutoReplaceBinding)
                .toggleStyle(.switch)
                .disabled(!store.settings.externalAppCompatibilitySettings.enabled)
            helperText("ON: 選択本文の編集結果に加え、音声で明示した回答も、録音停止時の同じアプリにある入力先へ直接挿入します。AXで欄を確認できない場合は、互換入力モードで試行します。明示的に別表示を指定した結果と、安全に入力先を確認できない結果は別ウィンドウに表示します。\nOFF：互換が必要な外部アプリでは結果を別ウィンドウに表示します（コピー可）。")
        }
    }

    private var handsFreeSendSettingsSection: some View {
        settingsSection {
            sectionTitle("ハンズフリー送信モード")
            Toggle(uiText("ハンズフリー送信モードを有効にする"), isOn: handsFreeSendEnabledBinding)
                .toggleStyle(.switch)
            helperText("通常モードと同じ文字起こし・AI整形を使います。音声トリガーまたはもう一度起動キーを押すと録音を終了します。本文を安全に挿入でき、送信が許可されている場合だけ、設定した送信キーを自動送信します。送信できた後は取り消せません。")
            helperText("パスワード入力などで安全な入力が有効な間は、通常モード・AIに指示モード・ハンズフリー送信モードを開始できません。入力を閉じてから開始してください。")

            VStack(alignment: .leading, spacing: uiMetrics.layout(7)) {
                Text(uiFormat("起動キー: %@", hotkeyBindingName(store.settings.handsFreeSendSettings.binding)))
                helperText("※表示される順番にキーを押してください")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: uiMetrics.layout(10)) {
                        handsFreeSendHotkeyCaptureButtons
                    }
                    VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                        handsFreeSendHotkeyCaptureButtons
                    }
                }
                .disabled(isCapturingKey)

                helperText("同じキーをもう一度押すと録音を終了します。1〜3個の組み合わせが使え、機能をオフにしている間も変更できます。")
                if cachedNormalHoldStartRequiresSpecialChordResolution {
                    helperText("通常モードと同じ起動キーを含むため、通常モードの長押し開始は最大150ms後になります。")
                }
            }

            HStack(spacing: uiMetrics.layout(10)) {
                Picker(uiText("音声トリガーフレーズ"), selection: handsFreeSendTriggerSourceBinding) {
                    Text(uiText("プリセットフレーズ")).tag(HandsFreeSendTriggerSource.preset)
                    Text(uiText("カスタムフレーズ")).tag(HandsFreeSendTriggerSource.custom)
                }
                .fixedSize()
                if store.settings.handsFreeSendSettings.triggerSource == .preset {
                    // プリセット句は音声認識言語だけに紐付く。UI表示言語では切り替わらないため
                    // ローカライズを通さずリテラルをそのまま出す。
                    // 角括弧はここだけで付ける。`presetDisplayPhrase`は初回セットアップの
                    // 文中にも埋め込まれるため、関数側に含めると文章として不自然になる。
                    Text("【\(HandsFreeSendTriggerPolicy.presetDisplayPhrase(sttLanguage: store.settings.languagePreferences.sttLanguage))】")
                        .font(uiMetrics.font(.headline))
                        .bold()
                        .textSelection(.enabled)
                }
            }
            .disabled(!store.settings.handsFreeSendSettings.enabled)

            if store.settings.handsFreeSendSettings.triggerSource == .custom {
                HStack(spacing: uiMetrics.layout(10)) {
                    TextField(uiText("カスタムフレーズ"), text: $handsFreeSendCustomPhraseDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: uiMetrics.layout(220))
                        .disabled(!handsFreeSendCustomPhraseIsEditing)
                        .focused($handsFreeSendCustomPhraseFieldIsFocused)
                    Button(uiText("保存")) { saveHandsFreeSendCustomPhrase() }
                        .disabled(!handsFreeSendCustomPhraseIsEditing || !hasHandsFreeSendCustomPhraseChanges)
                    Button(uiText("編集")) {
                        handsFreeSendCustomPhraseError = nil
                        handsFreeSendCustomPhraseIsEditing = true
                        handsFreeSendCustomPhraseFieldIsFocused = true
                    }
                    .disabled(handsFreeSendCustomPhraseIsEditing)
                }
                .disabled(!store.settings.handsFreeSendSettings.enabled)
                helperText("カスタムフレーズはスペースを含めて4〜20文字の1行にしてください。引用符は使えず、現在の音声認識言語のプリセットと同じ句は設定できません。")
                // 保存はメモリへ即時反映しディスクへも即書き出すが、トリガーは録音開始時に
                // 固定される（HandsFreeSendSnapshot / compiledTriggers）。時間差ではなく
                // 録音単位の境界であることを正しく伝える。
                helperText("保存した内容は次の録音から有効になります。録音中に保存した場合、その録音が終わるまでは保存前のフレーズが有効です。")
                // トリガー判定はAI整形前の生の文字起こしに対して行う。音声認識言語と
                // 違う言語の句は、認識結果が別表記（例: 英語発話が日本語STTでカタカナ）
                // になって一致しない（2026-07-30の実機報告）。仕様として案内する。
                helperText("カスタムフレーズは、音声認識言語と同じ言語で登録してください。異なる言語のフレーズは音声認識の結果と一致せず、トリガーとして機能しないことがあります。")
                if let handsFreeSendCustomPhraseError {
                    Text(handsFreeSendCustomPhraseError)
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.red)
                }
            }

            Picker(uiText("送信キー"), selection: handsFreeSendKeyBinding) {
                ForEach(SendKeyStroke.allCases, id: \.rawValue) { stroke in
                    Text(stroke.displayLabel).tag(stroke)
                }
            }
            .disabled(!store.settings.handsFreeSendSettings.enabled)

            Toggle(uiText("外部アプリでも自動送信する"), isOn: handsFreeSendExternalAutoSendBinding)
                .toggleStyle(.switch)
                .disabled(
                    !store.settings.handsFreeSendSettings.enabled
                        || !store.settings.externalAppCompatibilitySettings.enabled
                )
            helperText("外部アプリでは、本文入力後も録音停止時と同じ編集可能な入力欄を確認できた場合だけEnter系キーを自動送信します。確認できない場合は、文字だけ挿入し、「送信キー」は押されません。")

            if let handsFreeSendSettingsMessage {
                Text(handsFreeSendSettingsMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var handsFreeSendHotkeyCaptureButtons: some View {
        Button(uiText(isCapturingKey && keyCaptureTarget == .handsFreeSend ? "1〜3個のキーを押してください..." : "起動キーを変更")) {
            startKeyCapture(target: .handsFreeSend)
        }
        Button(uiText("デフォルトに戻す")) {
            handsFreeSendSettingsMessage = nil
            store.settings.handsFreeSendSettings.binding = .handsFreeSend
        }
    }

    private var hasHandsFreeSendCustomPhraseChanges: Bool {
        handsFreeSendCustomPhraseDraft != store.settings.handsFreeSendSettings.customPhrase
    }

    /// 打ちかけのフレーズが一瞬アクティブなトリガーになるのを避けるため、
    /// TextFieldはドラフトへ束縛し、保存ボタンでだけ設定へ確定する。
    private func saveHandsFreeSendCustomPhrase() {
        guard let normalized = HandsFreeSendCustomPhrasePolicy
            .normalizedPhrase(handsFreeSendCustomPhraseDraft) else {
            // 無効なら編集状態を保ったまま警告する。直せるようにしておく。
            handsFreeSendCustomPhraseError = uiText("*無効なフレーズです。プリセットフレーズが適用されます。")
            return
        }
        handsFreeSendCustomPhraseError = nil
        handsFreeSendCustomPhraseDraft = normalized
        store.settings.handsFreeSendSettings.customPhrase = normalized
        store.flushPendingSave()
        // フォーカスを外してキャレットを消し、入力欄をロックする。
        handsFreeSendCustomPhraseFieldIsFocused = false
        handsFreeSendCustomPhraseIsEditing = false
    }

    private var aiCommandHotkeySettingsSection: some View {
        settingsSection {
            sectionTitle("AIに指示モードの起動キー設定")

            VStack(alignment: .leading, spacing: uiMetrics.layout(7)) {
                Text(uiFormat("起動: %@", hotkeyBindingName(store.settings.aiCommandSettings.startHotkey)))
                helperText("※表示される順番にキーを押してください")
                Text(uiFormat("停止: %@", hotkeyBindingName(store.settings.aiCommandSettings.stopHotkey)))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: uiMetrics.layout(10)) {
                        aiCommandHotkeyCaptureButtons
                    }
                    VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                        aiCommandHotkeyCaptureButtons
                    }
                }
                .disabled(isCapturingKey)

                Button(uiText("デフォルトに戻す")) {
                    aiCommandSettingsMessage = nil
                    store.settings.aiCommandSettings.startHotkey = .aiCommandStart
                    store.settings.aiCommandSettings.stopHotkey = .aiCommandStop
                }
                .disabled(isCapturingKey)

                helperText("起動キーは1〜3個の組み合わせ、停止キーは1個です。キーの認識確認と衝突検査は初回セットアップで行います（キーを押す順番によっては起動しない場合があります）。")
                if cachedNormalHoldStartRequiresSpecialChordResolution {
                    helperText("通常モードと同じ起動キーを含むため、通常モードの長押し開始は最大150ms後になります。")
                }
                if isCapturingKey,
                   case let .capturing(preview) = keyCaptureMonitor.status,
                   let preview {
                    helperText(uiFormat("入力中: %@（Escで取消）", hotkeyBindingName(preview)), localize: false)
                } else if isCapturingKey {
                    helperText("キーを押してください。Escで取消できます。")
                }
            }

            helperText("AIに指示モードは、起動キーで録音を開始し、停止キーで停止するワンタップ方式です。")

            Divider()
            Toggle(uiText("クリップボードモードを有効にする"), isOn: clipboardVariantEnabledBinding)
                .toggleStyle(.switch)
            Picker(uiText("追加キー"), selection: clipboardVariantModifierBinding) {
                ForEach(cachedClipboardVariantPickerOptions, id: \.rawValue) { modifier in
                    Text(modifier.displayLabel).tag(modifier)
                }
            }
            .pickerStyle(.menu)
            if let cachedClipboardVariantEligibilityMessage {
                Text(cachedClipboardVariantEligibilityMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
            }
            Text(uiFormat(
                "Google DocsやNotionのように、Koedexが「いま選択されている文字」を読み取れないアプリがあります。この設定はその回避策で、選択のかわりに自分でコピーしたものをAIへ渡します。\n\n例：Google Docsで書いた段落を英訳したい\n　1. 段落を選んで、自分で ⌘C でコピーする\n　2. %@ を最初に押しながら、AIに指示モードの起動キーを押す（キーを押す順番が違うと起動しない場合があります）\n　3. 「英語にして」と話す\n　4. Koedexはカーソル位置への挿入を試みます\n\n・追加キー（%@）を最初に押しながら、「AIに指示モード」の起動キーを押してください\n・追加キーは左右どちらでも同じです\n・安全な入力が有効な間、秘匿指定・Koedex自身の出力・テキスト以外・長すぎる内容はAIへ渡さず中止します。読めない場合に一般質問へ切り替えることはありません\n・貼り付けが反映されたかをKoedexは確認できません\n・入力後、Koedexが所有していたクリップボードだけを復元します。途中であなたや他のアプリが新しくコピーした内容は上書きしません\n・この設定は「互換入力モード」とは別です。ONにしても他の設定は変わりません",
                store.settings.aiCommandSettings.clipboardVariantModifier.displayLabel,
                store.settings.aiCommandSettings.clipboardVariantModifier.displayLabel
            ))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 起動方法の案内は、実際に使える時だけ出す。使えない構成の時は
            // 代わりに`aiCommandSettingsMessage`が理由を出す。
            if store.settings.aiCommandSettings.clipboardVariantEnabled,
               cachedClipboardVariantEligibilities[
                store.settings.aiCommandSettings.clipboardVariantModifier
               ] == .eligible {
                Text(uiFormat(
                    "起動: %@ を押しながらAIに指示モードの起動キー",
                    store.settings.aiCommandSettings.clipboardVariantModifier.displayLabel
                ))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
            }

            if let aiCommandSettingsMessage {
                Text(aiCommandSettingsMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
            }
        }
        .disabled(!store.settings.aiCommandSettings.enabled)
    }

    @ViewBuilder
    private var aiCommandHotkeyCaptureButtons: some View {
        Button(uiText(isCapturingKey && keyCaptureTarget == .aiStart ? "1〜3個のキーを押してください..." : "起動キーを変更")) {
            startKeyCapture(target: .aiStart)
        }
        Button(uiText(isCapturingKey && keyCaptureTarget == .aiStop ? "停止キーを押してください..." : "停止キーを変更")) {
            startKeyCapture(target: .aiStop)
        }
    }

    private var aiCommandModelSettingsSection: some View {
        settingsSection {
            sectionTitle("AIに指示モードに使用するモデル")
            helperText("新規インストール時は、モデル一覧で利用可能な場合にGPT-5.6 Luna/low がデフォルトとして設定されます。")

            modelAndReasoningPickerRow(
                model: {
                    modelPickerColumn(models: aiCommandAvailableModels, selection: aiCommandModelBinding)
                },
                reasoning: {
                    reasoningPickerColumn(levels: aiCommandReasoningLevels, selection: aiCommandReasoningBinding)
                }
            )
            .disabled(isSavingAICommandModelSettings)

            if let selectedAICommandModelInfo {
                helperText(
                    CodexModelCatalog.userFacingDescription(for: selectedAICommandModelInfo, language: uiLanguage),
                    localize: false
                )
            } else if !aiCommandModelIsAvailable {
                helperText("保存済みのモデルは現在利用できません。利用可能なモデルを選び直してください。")
            }

            Toggle(uiText("AIへの質問でWeb検索を使用"), isOn: aiCommandWebBinding)
                .toggleStyle(.switch)
                .disabled(!aiCommandModelSupportsWeb || isSavingAICommandModelSettings)

            if !aiCommandModelSupportsWeb {
                helperText("選択したモデルではWeb検索を利用できません。Web検索に対応するモデルを選んでください。")
            } else {
                helperText(
                    AICommandWebSearchCopy.generalQuestionNotice(
                        for: uiLanguage
                    ),
                    localize: false
                )
                helperText(
                    AICommandWebSearchCopy.selectedSourceNotice(
                        for: uiLanguage
                    ),
                    localize: false
                )
            }
            helperTextVerbatim(modelCatalogNotice)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: uiMetrics.layout(10)) {
                    aiCommandModelActionButtons
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    aiCommandModelActionButtons
                }
            }

            if let aiCommandModelSettingsMessage {
                Text(aiCommandModelSettingsMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let aiCommandModelSettingsNotice {
                Text(aiCommandModelSettingsNotice)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .disabled(!store.settings.aiCommandSettings.enabled)
    }

    @ViewBuilder
    private var aiCommandModelActionButtons: some View {
        Button(uiText("モデル一覧を更新")) {
            refreshModelCatalog()
        }
        .disabled(isRefreshingModels || isSavingAICommandModelSettings)

        Button(uiText("保存")) {
            saveAICommandModelSettings()
        }
        .disabled(!hasAICommandModelSettingsChanges || !aiCommandModelIsAvailable || !isModelCatalogVerified || isSavingAICommandModelSettings || isVoiceProcessing)

        if isRefreshingModels || isSavingAICommandModelSettings {
            ProgressView()
                .controlSize(uiMetrics.controlSize)
        }
    }

    private var aiCommandCustomInstructionSettingsSection: some View {
        settingsSection {
            sectionTitle("カスタムインストラクション（AIに指示モード）")
            helperText("AIへの質問や選択テキストへの指示で追加したい、回答の文体・形式の好みを記入してください。")
            helperText("この指示はこのモードにだけ適用されます。")
            helperText(
                AICommandWebSearchCopy.selectedSourceNotice(
                    for: uiLanguage
                ),
                localize: false
            )
            helperText(
                AICommandWebSearchCopy.customInstructionBoundaryNotice(for: uiLanguage),
                localize: false
            )
            helperText(
                AICommandWebSearchCopy.customInstructionBoundaryExample(for: uiLanguage),
                localize: false
            )

            VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                TextEditor(text: $aiCommandCustomInstructionDraft)
                    .frame(minHeight: uiMetrics.layout(100))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(uiMetrics.font(.body))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: uiMetrics.layout(10)) {
                        aiCommandCustomInstructionActionRow
                    }
                    VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                        HStack(spacing: uiMetrics.layout(10)) {
                            aiCommandCustomInstructionPrimaryButtons
                        }
                        HStack(spacing: uiMetrics.layout(10)) {
                            aiCommandCustomInstructionHistoryButtons
                        }
                    }
                }
            }
            .frame(maxWidth: uiMetrics.contentWidth(640), alignment: .leading)

            if let aiCommandCustomInstructionMessage {
                Text(aiCommandCustomInstructionMessage)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .disabled(!store.settings.aiCommandSettings.enabled)
    }

    @ViewBuilder
    private var aiCommandCustomInstructionActionRow: some View {
        Button(uiText("最適化")) {
            optimizeAICommandCustomInstruction()
        }
        .disabled(!canOptimizeAICommandCustomInstruction)

        Spacer()
        aiCommandCustomInstructionHistoryButtons
        Button(uiText("保存")) {
            saveAICommandCustomInstruction()
        }
        .disabled(!hasAICommandCustomInstructionChanges)

        if isOptimizingAICommandCustomInstruction {
            ProgressView()
                .controlSize(uiMetrics.controlSize)
        }
    }

    @ViewBuilder
    private var aiCommandCustomInstructionPrimaryButtons: some View {
        Button(uiText("最適化")) {
            optimizeAICommandCustomInstruction()
        }
        .disabled(!canOptimizeAICommandCustomInstruction)

        Button(uiText("保存")) {
            saveAICommandCustomInstruction()
        }
        .disabled(!hasAICommandCustomInstructionChanges)

        if isOptimizingAICommandCustomInstruction {
            ProgressView()
                .controlSize(uiMetrics.controlSize)
        }
    }

    @ViewBuilder
    private var aiCommandCustomInstructionHistoryButtons: some View {
        Button {
            stepAICommandCustomInstructionHistory(by: -1)
        } label: {
            Image(systemName: "arrow.left")
        }
        .disabled(!canStepAICommandCustomInstructionHistoryBackward)
        .help(uiText("保存済み履歴を1つ戻る"))

        Button {
            stepAICommandCustomInstructionHistory(by: 1)
        } label: {
            Image(systemName: "arrow.right")
        }
        .disabled(!canStepAICommandCustomInstructionHistoryForward)
        .help(uiText("保存済み履歴を1つ進む"))
    }

    private var optimizationModelSettingsSection: some View {
        settingsSection {
            sectionTitle("最適化に使用するモデル（通常モード／ハンズフリー送信モード／AIに指示モード共通）")
            helperText("各カスタムインストラクションで「最適化」を実行する時だけ使います。選択中のモデルと推論レベルで最適化します。")
            helperText("新規インストール時は、モデル一覧で利用可能な場合にGPT-5.6 Luna/low がデフォルトとして設定されます。")

            modelAndReasoningPickerRow(
                model: {
                    modelPickerColumn(models: optimizationAvailableModels, selection: optimizationModelBinding)
                },
                reasoning: {
                    reasoningPickerColumn(levels: optimizationReasoningLevels, selection: optimizationReasoningBinding)
                }
            )

            if let selectedOptimizationModelInfo {
                helperText(
                    CodexModelCatalog.userFacingDescription(for: selectedOptimizationModelInfo, language: uiLanguage),
                    localize: false
                )
            }

            Button(uiText("モデル一覧を更新")) {
                refreshModelCatalog()
            }
            .disabled(isRefreshingModels)
            helperTextVerbatim(modelCatalogNotice)
        }
    }

    private var autoStopSettingsSection: some View {
        settingsSection {
            sectionTitle("録音の自動停止（通常モード／AIに指示モード共通）")
            Picker(uiText("録音の自動停止"), selection: $store.settings.autoStopSeconds) {
                Text(uiText("1分")).tag(60)
                Text(uiText("3分")).tag(180)
                Text(uiText("5分")).tag(300)
                Text(uiText("10分")).tag(600)
            }
            .pickerStyle(.menu)
            helperText("録音は最長10分です。設定した時間で自動停止し、10分を超えて録音することはできません。")
        }
    }

    private var microphoneSettingsSection: some View {
        settingsSection {
            sectionTitle("マイク")
            Picker(uiText("入力デバイス"), selection: $store.settings.preferredMicrophoneUID) {
                Text(uiFormat("自動 (%@)", defaultMicrophoneName)).tag("")
                ForEach(microphones) { microphone in
                    Text(microphone.name).tag(microphone.uid)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            helperText("選択したマイクが見つからない場合は、システムのデフォルト入力へ自動的にフォールバックします。")
        }
    }

    /// 長時間使うと整形が遅くなる（threadにサーバ側コンテキストが積み上がる）ため、
    /// 自動作り直しの閾値を待たずに手で捨てられる逃げ道を用意する。
    /// 全モードに効くので「AIに指示」のセクション内には置かず、独立させる。
    private var aiProcessingResetSettingsSection: some View {
        settingsSection {
            sectionTitle("AI処理のリセット")
            HStack(spacing: uiMetrics.layout(10)) {
                Button(uiText("AI処理をリセット")) { resetAIProcessing() }
                    .disabled(!canResetAIProcessing)
                if isResettingAIProcessing {
                    ProgressView().controlSize(.small)
                }
            }
            // 「消えません」の明記は必須。これが無いと、設定・辞書・履歴が失われると
            // 誤解される危険なUIになる。
            helperText("AI整形とAIに指示モードの接続を作り直します。設定・ユーザー辞書・入力履歴は消えません。")
            helperText("長時間使って整形が遅くなってきたと感じたときに使ってください。録音中と処理中は押せません。")
            if let aiProcessingResetStatus {
                Text(aiProcessingResetStatusText(aiProcessingResetStatus))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(aiProcessingResetStatus.isFailure ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// 「リセットしています」「リセットしました」はここで都度 `uiText` を通すことで、
    /// 表示中にUI言語を切り替えても再ローカライズされる（保持していたのは解決済み
    /// 文字列だったため、以前は切替後も元の言語のまま残っていた:2026-07-30の実機報告）。
    private func aiProcessingResetStatusText(_ status: AIProcessingResetStatus) -> String {
        switch status {
        case .resetting: return uiText("AI処理をリセットしています。")
        case .succeeded: return uiText("AI処理をリセットしました。")
        case .failed(let rawMessage):
            return AppLocalizer.textOrLiteral(rawMessage, language: uiLanguage)
        }
    }

    private var canResetAIProcessing: Bool {
        !isResettingAIProcessing
            && AIProcessingResetPolicy.allowsReset(
                phase: observedPipelinePhase,
                codexStatus: appDelegate.codexStatus
            )
    }

    private static let aiProcessingResetMessageDismissDelay: TimeInterval = 4

    private func resetAIProcessing() {
        guard !isResettingAIProcessing,
              AIProcessingResetPolicy.allowsReset(
                phase: appState.phase,
                codexStatus: appDelegate.codexStatus
              ) else { return }
        aiProcessingResetDismissTask?.cancel()
        aiProcessingResetDismissTask = nil
        isResettingAIProcessing = true
        aiProcessingResetStatus = .resetting
        Task {
            let result = await appDelegate.resetAIProcessingState()
            await MainActor.run {
                isResettingAIProcessing = false
                switch result {
                case .success:
                    aiProcessingResetStatus = .succeeded
                case .failure(let failure):
                    // ここでローカライズしない。解決済み文字列を持つと言語切替に
                    // 追従しなくなるため、描画時に通す。
                    aiProcessingResetStatus = .failed(rawMessage: failure.message)
                }
                scheduleAIProcessingResetMessageDismiss()
            }
        }
    }

    /// 一定時間で自動的に消す。前回の消去タスクは必ずキャンセルしてから貼り直す
    /// （連打してもタイマーが重複せず、最新の表示だけが正しい時刻に消える）。
    private func scheduleAIProcessingResetMessageDismiss() {
        aiProcessingResetDismissTask?.cancel()
        let delay = Self.aiProcessingResetMessageDismissDelay
        aiProcessingResetDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            aiProcessingResetStatus = nil
        }
    }

    private var codexExecutablePathSettingsSection: some View {
        settingsSection {
            HStack(spacing: uiMetrics.layout(6)) {
                sectionTitle("Codex実行ファイルの場所（詳細設定）")
                if case .failed = appDelegate.codexStatus {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if case .failed(let reason) = appDelegate.codexStatus {
                Text(uiFormat(
                    "Codexに接続できていません（%@）。［自動検出をやり直す］を押すか、［ファイルを選択…］でcodexの場所を指定してください。",
                    AppLocalizer.textOrLiteral(reason, language: uiLanguage)
                ))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: uiMetrics.layout(10)) {
                    codexExecutablePathControls
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    codexExecutablePathControls
                }
            }
            .frame(maxWidth: uiMetrics.contentWidth(620), alignment: .leading)
            codexExecutablePathHelp
        }
    }

    @ViewBuilder
    private var codexExecutablePathControls: some View {
        TextField(uiText("空欄で自動検出"), text: $codexExecutablePathDraft)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 520)

        HStack(spacing: uiMetrics.layout(8)) {
            Button(uiText("保存")) {
                saveCodexExecutablePath()
            }
            .disabled(!hasCodexExecutablePathChanges)

            Button(uiText("自動検出をやり直す")) {
                redetectCodexExecutablePath()
            }

            Button(uiText("ファイルを選択…")) {
                chooseCodexExecutablePath()
            }
        }
    }

    private var modelCatalogNotice: String {
        uiText("表示はインストール済みCodex CLIに基づきます。最新モデルが表示されない場合は、Codex CLIを最新版へ更新し、［モデル一覧を更新］を押してください。更新後も表示されない場合は、アカウントまたはワークスペースの提供状況を確認してください。")
    }

    @ViewBuilder
    private func settingsSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
            content()
            Divider()
                .padding(.top, uiMetrics.layout(6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(uiText(text))
            .font(uiMetrics.font(.headline))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func helperText(_ text: String, localize: Bool = true) -> some View {
        Text(localize ? uiText(text) : text)
            .font(uiMetrics.font(.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// すでに表示言語へ解決した非同期通知や動的文言を、翻訳キーとして再解決しない。
    private func helperTextVerbatim(_ text: String) -> some View {
        helperText(text, localize: false)
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(12)) {
            Text(uiText("履歴"))
                .font(uiMetrics.font(.title))
                .bold()
                .textSelection(.enabled)

            if historyNeedsAttention {
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    Text(uiText("履歴ファイルの一部を安全に読み込めませんでした。元の行を残すため、編集・削除・保持期間による整理を停止しています。新しい履歴の追記は続けられます。"))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button(uiText("履歴を再読み込み")) {
                        historyStore.load()
                        historyOperationMessage = historyNeedsAttention ? uiText("まだ履歴を安全に読み込めません。ファイルを確認してから再試行してください。") : nil
                        if !historyNeedsAttention { appDelegate.clearHistoryStorageNoticeIfRecovered() }
                    }
                }
                .padding(uiMetrics.layout(10))
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: uiMetrics.layout(6)))
            }
            if let historyOperationMessage {
                Text(historyOperationMessage).font(uiMetrics.font(.caption)).foregroundStyle(.red).textSelection(.enabled)
            }

            settingsSection {
                sectionTitle("履歴の保持")
                Text(uiText("デバイスに履歴をどのくらい保持したいですか？"))
                    .font(uiMetrics.font(.subheadline))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: uiMetrics.layout(14)) {
                        historyRetentionPickers
                    }
                    VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                        historyRetentionPickers
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)

                helperText("「保存しない」を選ぶと、そのモードの新しい履歴は保存されません。既存の履歴は削除されないため、消したい場合は「履歴をすべて削除」または各履歴の削除を使ってください。保持期間を短くする場合は、そのモードの古い履歴だけを確認後に削除します。")
                helperText("通常モードは安全に挿入できた出力本文だけを保存します。ハンズフリー送信モードは、安全に本文を挿入できた出力だけを別に保存します。AIに指示モードは音声指示の文字起こしだけを保存し、クリップボードモードも同じ履歴に「クリップボードモード」として表示します。選択テキスト、クリップボード本文、回答、音声、参照リンクは保存しません。")
            }

            settingsSection {
                sectionTitle("履歴の表示件数")
                Picker(uiText("履歴の表示件数"), selection: historyDisplayLimitBinding) {
                    Text(uiText("50件")).tag(50)
                    Text(uiText("100件")).tag(100)
                    Text(uiText("200件")).tag(200)
                    Text(uiText("すべて")).tag(0)
                }
                .pickerStyle(.menu)
                helperText("検索対象は、ここで選んだ表示件数内の履歴です。")
            }

            TextField(uiText("履歴を検索"), text: $historySearchText)
                .textFieldStyle(.roundedBorder)

            ViewThatFits(in: .horizontal) {
                Picker(uiText("履歴の種類"), selection: $historyModeFilter) {
                    ForEach(HistoryModeFilter.allCases) { filter in
                        Text(filter.label(for: uiLanguage)).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                Picker(uiText("履歴の種類"), selection: $historyModeFilter) {
                    ForEach(HistoryModeFilter.allCases) { filter in
                        Text(filter.label(for: uiLanguage)).tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }
            .frame(maxWidth: 540, alignment: .leading)

            helperText(historyDisplaySummary)

            Picker(uiText("履歴操作"), selection: $historyViewMode) {
                ForEach(HistoryViewMode.allCases) { mode in
                    Text(mode.label(for: uiLanguage)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360, alignment: .leading)

            if historyViewMode == .selectToDelete {
                historySelectionControls
            }

            if filteredHistoryEntries.isEmpty {
                Text(historyEmptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .textSelection(.enabled)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                        ForEach(filteredHistoryEntries) { entry in
                            historyEntryRow(entry, isSelectionMode: historyViewMode == .selectToDelete)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Button(uiText("履歴をすべて削除"), role: .destructive) {
                requestDeleteAllHistory()
            }
            .disabled(historyStore.entries.isEmpty || historyNeedsAttention)

            helperText("「履歴をすべて削除」は、履歴に表示される保存済み本文と、履歴には表示されないメタデータをすべて削除します。AIアシストを使用しない文字起こし、AIアシストに失敗した場合などは履歴には表示されませんが、Koedexの音声入力を使用した日時や使用モデル情報などが、このMacにメタデータとして残る可能性があります。")
        }
        .padding(.horizontal, uiMetrics.layout(20))
        .padding(.bottom, uiMetrics.layout(20))
        .padding(.top, uiMetrics.layout(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var historySelectionControls: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: uiMetrics.layout(8)) {
                    historySelectionActionButtons
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    historySelectionActionButtons
                }
            }

            Button(uiText("表示されていないメタデータをすべて削除"), role: .destructive) {
                requestDeleteMetadataOnlyHistory()
            }
            .disabled(historyStore.metadataOnlyCount == 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var historyRetentionPickers: some View {
        retentionPicker(
            title: "通常モード（出力履歴）",
            selection: normalHistoryRetentionBinding
        )
        retentionPicker(
            title: "ハンズフリー送信モード（出力履歴）",
            selection: handsFreeSendHistoryRetentionBinding
        )
        retentionPicker(
            title: "AIに指示モード（指示文の履歴）",
            selection: aiCommandHistoryRetentionBinding
        )
    }

    @ViewBuilder
    private var historySelectionActionButtons: some View {
        Button(uiText(areAllVisibleHistoryEntriesSelected ? "選択を解除" : "すべて選択")) {
            toggleVisibleHistorySelection()
        }
        .disabled(filteredHistoryEntries.isEmpty)

        Button(uiText("チェックしたものをすべて削除"), role: .destructive) {
            requestDeleteSelectedHistory()
        }
        .disabled(selectedVisibleHistoryIDs.isEmpty)

        Button(uiText("チェックしたもの以外をすべて削除"), role: .destructive) {
            requestDeleteUnselectedDisplayedHistory()
        }
        .disabled(unselectedVisibleHistoryIDs.isEmpty)
    }

    private func historyEntryRow(_ entry: InputHistoryEntry, isSelectionMode: Bool) -> some View {
        let displayText = entry.storedText ?? ""
        let displayFlags = entry.flags.compactMap { historyDisplayFlagLabel($0) }
        let displayContextLabels = historyContextLabels(for: entry)

        return VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            HStack(spacing: uiMetrics.layout(12)) {
                if isSelectionMode {
                    Toggle("", isOn: historySelectionBinding(for: entry.id))
                        .labelsHidden()
                }
                Text(historyDateFormatter.string(from: entry.createdAt))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
                if let storedText = entry.storedText, !storedText.isEmpty {
                    historyCopyButton(entryID: entry.id, text: storedText)
                }
                if !isSelectionMode {
                    Button(uiText("削除"), role: .destructive) {
                        historyDeleteTarget = entry.id
                    }
                    .disabled(historyNeedsAttention)
                }
            }

            if !displayContextLabels.isEmpty {
                Text(displayContextLabels.joined(separator: " ・ "))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(displayText)
                .font(uiMetrics.font(.body))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(uiMetrics.layout(8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            if !displayFlags.isEmpty {
                Text(displayFlags.joined(separator: ", "))
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(uiMetrics.layout(8))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func historyContextLabels(for entry: InputHistoryEntry) -> [String] {
        switch entry.mode {
        case InputHistoryMode.voiceInput:
            return [uiText("通常モード")]
        case InputHistoryMode.handsFreeSend:
            return [uiText("ハンズフリー送信モード")]
        case InputHistoryMode.aiCommand:
            var labels = [uiText("AIに指示モード")]
            if entry.aiCommandInputSource == .clipboard {
                labels.append(uiText("クリップボードモード"))
            }
            return labels
        default:
            return []
        }
    }

    private func historyDisplayFlagLabel(_ flag: String) -> String? {
        switch flag {
        case InputHistoryFlag.cleanupFailed:
            return uiText("AIアシストに失敗")
        case InputHistoryFlag.insertFailed:
            return uiText("挿入に失敗")
        case InputHistoryFlag.secureInputBlocked:
            return uiText("安全な入力のため中止")
        case InputHistoryFlag.tooShort:
            return uiText("短い入力")
        case InputHistoryFlag.excludedByUser:
            return uiText("除外済み")
        case InputHistoryFlag.clipboardRestoreFailed:
            return uiText("クリップボードの復元に失敗")
        case InputHistoryFlag.noiseCandidate:
            return nil
        default:
            return nil
        }
    }

    private func optimizationPreviewSheet(_ draft: CustomInstructionOptimizationDraft) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(14)) {
            Text(uiText(draft.mode.previewTitle))
                .font(uiMetrics.font(.title))
                .bold()

            helperText(draft.mode.previewHelp)

            ScrollView {
                Text(draft.optimizedInstruction)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(uiMetrics.layout(10))
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button(uiText("破棄")) {
                    optimizationDraft = nil
                }
                Spacer()
                Button(uiText("欄に読み込む")) {
                    applyOptimizationDraft(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(uiMetrics.layout(20))
        .frame(
            minWidth: uiMetrics.contentWidth(520),
            idealWidth: uiMetrics.contentWidth(620),
            minHeight: uiMetrics.layout(360),
            idealHeight: uiMetrics.layout(460)
        )
    }

    private func historyCopyButton(entryID: UUID, text: String) -> some View {
        let isHovered = hoveredHistoryCopyID == entryID
        let isCopied = copiedHistoryEntryID == entryID

        return Button {
            copyHistoryText(text, entryID: entryID)
        } label: {
            HStack(spacing: uiMetrics.layout(4)) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                if isHovered || isCopied {
                    Text(uiText(isCopied ? "コピー済み" : "コピー"))
                        .font(uiMetrics.font(.caption))
                }
            }
            .frame(minWidth: uiMetrics.layout(28), minHeight: uiMetrics.layout(28))
            .padding(.horizontal, (isHovered || isCopied) ? uiMetrics.layout(8) : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCopied ? .green : .primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered || isCopied ? Color.secondary.opacity(0.16) : Color.clear)
        )
        .onHover { hovering in
            hoveredHistoryCopyID = hovering ? entryID : nil
        }
    }

    private var codexExecutablePathHelp: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            Text(uiText("通常は空欄のままで問題ありません。空欄のときは、npm・nvm・fnm・Volta・Homebrew などの標準的な場所と、ログインシェルのPATHから自動で探します。"))
            Text(uiText("接続できていない場合は、まず［自動検出をやり直す］を押してください。それでも見つからないときは［ファイルを選択…］でcodex実行ファイルを直接指定できます。"))
            Text(uiText("ターミナルを使う場合は"))
            inlineCode("command -v codex")
            Text(uiText("を実行し、表示されたパス（例:"))
            inlineCode("~/.npm-global/bin/codex")
            Text(uiText("のようなパス）をこの欄に貼り付けてください。保存するとCodexに再接続され、設定が反映されます。"))
        }
        .font(uiMetrics.font(.caption))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func inlineCode(_ text: String) -> some View {
        Text(text)
            .font(uiMetrics.font(.monospacedCaption))
            .foregroundStyle(.primary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, uiMetrics.layout(5))
            .padding(.vertical, uiMetrics.layout(2))
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var fnKeyNotice: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            Text(uiText("fnキー使用時の注意"))
                .font(uiMetrics.font(.subheadline))
                .bold()
            Text(uiText("macOSの「🌐キーを押して」機能と競合するため、システム設定→キーボード→「🌐キーを押して」を「何もしない」に変更してください。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button(uiText("キーボード設定を開く")) {
                NSWorkspace.shared.open(SystemSettingsLinks.keyboard)
            }
        }
        .padding(uiMetrics.layout(10))
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var normalHistoryRetentionBinding: Binding<HistoryRetentionOption> {
        Binding(
            get: {
                HistoryRetentionOption.current(
                    enabled: store.settings.historyEnabled,
                    retentionDays: store.settings.historyRetentionDays
                )
            },
            set: { option in
                if shouldConfirmHistoryRetentionChange(to: option, scope: .normal) {
                    pendingHistoryRetentionChange = HistoryRetentionChangeRequest(scope: .normal, option: option)
                } else {
                    applyHistoryRetention(option, scope: .normal)
                }
            }
        )
    }

    private var handsFreeSendHistoryRetentionBinding: Binding<HistoryRetentionOption> {
        Binding(
            get: {
                HistoryRetentionOption.current(
                    enabled: store.settings.handsFreeSendSettings.historyEnabled,
                    retentionDays: store.settings.handsFreeSendSettings.historyRetentionDays
                )
            },
            set: { option in
                if shouldConfirmHistoryRetentionChange(to: option, scope: .handsFreeSend) {
                    pendingHistoryRetentionChange = HistoryRetentionChangeRequest(scope: .handsFreeSend, option: option)
                } else {
                    applyHistoryRetention(option, scope: .handsFreeSend)
                }
            }
        )
    }

    private func retentionPicker(
        title: String,
        selection: Binding<HistoryRetentionOption>
    ) -> some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(5)) {
            Text(uiText(title))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
            Picker(uiText(title), selection: selection) {
                ForEach(HistoryRetentionOption.allCases) { option in
                    Text(option.label(for: uiLanguage)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aiCommandEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.aiCommandSettings.enabled },
            set: { store.settings.aiCommandSettings.enabled = $0 }
        )
    }

    private var clipboardVariantEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.aiCommandSettings.clipboardVariantEnabled },
            set: { newValue in
                switch AICommandClipboardActivationPolicy.decision(
                    requestedEnabled: newValue,
                    eligibility: store.settings.clipboardVariantEligibility
                ) {
                case .disabled:
                    store.settings.aiCommandSettings.clipboardVariantEnabled = false
                    aiCommandSettingsMessage = nil
                case .enabled:
                    store.settings.aiCommandSettings.clipboardVariantEnabled = true
                    aiCommandSettingsMessage = nil
                case let .rejected(eligibility):
                    store.settings.aiCommandSettings.clipboardVariantEnabled = false
                    aiCommandSettingsMessage = AICommandClipboardEligibilityCopy.message(
                        for: eligibility,
                        language: uiLanguage
                    )
                }
                refreshHotkeyDerivedState()
            }
        )
    }

    private var clipboardVariantModifierBinding: Binding<AICommandClipboardModifier> {
        Binding(
            get: { store.settings.aiCommandSettings.clipboardVariantModifier },
            set: { newValue in
                store.settings.aiCommandSettings.clipboardVariantModifier = newValue
                aiCommandSettingsMessage = nil
                refreshHotkeyDerivedState()
            }
        )
    }

    private var externalAppCompatibilityEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.externalAppCompatibilitySettings.enabled },
            set: { store.settings.externalAppCompatibilitySettings.setEnabledFromVisibleControl($0) }
        )
    }

    private var externalAICommandAutoReplaceBinding: Binding<Bool> {
        Binding(
            get: { store.settings.externalAppCompatibilitySettings.autoReplaceAICommandSelection },
            set: { store.settings.externalAppCompatibilitySettings.autoReplaceAICommandSelection = $0 }
        )
    }

    private var handsFreeSendEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.settings.handsFreeSendSettings.enabled },
            set: { store.settings.handsFreeSendSettings.enabled = $0 }
        )
    }

    private var handsFreeSendTriggerSourceBinding: Binding<HandsFreeSendTriggerSource> {
        Binding(
            get: { store.settings.handsFreeSendSettings.triggerSource },
            set: { store.settings.handsFreeSendSettings.triggerSource = $0 }
        )
    }


    private var handsFreeSendKeyBinding: Binding<SendKeyStroke> {
        Binding(
            get: { store.settings.handsFreeSendSettings.sendKey },
            set: { store.settings.handsFreeSendSettings.sendKey = $0 }
        )
    }

    private var handsFreeSendExternalAutoSendBinding: Binding<Bool> {
        Binding(
            get: { store.settings.handsFreeSendSettings.allowExternalAutoSend },
            set: { enabled in
                guard enabled else {
                    store.settings.handsFreeSendSettings.allowExternalAutoSend = false
                    return
                }
                guard store.settings.handsFreeSendSettings.enabled,
                      store.settings.externalAppCompatibilitySettings.enabled,
                      !store.settings.handsFreeSendSettings.allowExternalAutoSend else {
                    return
                }
                showsExternalSendConfirmation = true
            }
        )
    }

    private var aiCommandModelBinding: Binding<String> {
        Binding(
            get: { aiCommandModelSettingsDraft.selectedModelSlug },
            set: { slug in
                let model = aiCommandAvailableModels.first { $0.slug == slug }
                let current = aiCommandModelSettingsDraft.selectedReasoningEffort
                aiCommandModelSettingsDraft = CodexModelSettings(
                    mode: .explicit,
                    selectedModelSlug: slug,
                    selectedReasoningEffort: normalizedEffort(for: model, preferred: current)
                )
                if model?.supportsSearchTool != true,
                   aiCommandWebSearchDraft {
                    aiCommandWebSearchDraft = false
                    aiCommandModelSettingsNotice = uiText("選択したモデルがWeb検索非対応のため、Web検索をオフにしました。")
                } else if model?.supportsSearchTool == true {
                    aiCommandModelSettingsNotice = nil
                }
            }
        )
    }

    private var aiCommandReasoningBinding: Binding<String> {
        Binding(
            get: { aiCommandModelSettingsDraft.selectedReasoningEffort },
            set: { effort in
                aiCommandModelSettingsDraft = CodexModelSettings(
                    mode: .explicit,
                    selectedModelSlug: aiCommandModelSettingsDraft.selectedModelSlug,
                    selectedReasoningEffort: effort
                )
            }
        )
    }

    private var aiCommandWebBinding: Binding<Bool> {
        Binding(
            get: { aiCommandWebSearchDraft && aiCommandModelSupportsWeb },
            set: {
                aiCommandWebSearchDraft = aiCommandModelSupportsWeb && $0
                if aiCommandWebSearchDraft {
                    aiCommandModelSettingsNotice = nil
                }
            }
        )
    }

    private var aiCommandHistoryRetentionBinding: Binding<HistoryRetentionOption> {
        Binding(
            get: {
                HistoryRetentionOption.current(
                    enabled: store.settings.aiCommandSettings.historyEnabled,
                    retentionDays: store.settings.aiCommandSettings.historyRetentionDays
                )
            },
            set: { option in
                if shouldConfirmHistoryRetentionChange(to: option, scope: .aiCommand) {
                    pendingHistoryRetentionChange = HistoryRetentionChangeRequest(scope: .aiCommand, option: option)
                } else {
                    applyHistoryRetention(option, scope: .aiCommand)
                }
            }
        )
    }

    private var selectedAICommandModelInfo: CodexModelInfo? {
        aiCommandAvailableModels.first { $0.slug == aiCommandModelSettingsDraft.selectedModelSlug }
    }

    private var aiCommandModelIsAvailable: Bool {
        CodexModelCatalog.isAvailable(
            slug: aiCommandModelSettingsDraft.selectedModelSlug,
            in: aiCommandAvailableModels
        )
    }

    private var aiCommandModelSupportsWeb: Bool {
        selectedAICommandModelInfo?.supportsSearchTool == true
    }

    private var aiCommandReasoningLevels: [CodexReasoningLevel] {
        let levels = CodexModelCatalog.userSelectableReasoningLevels(for: selectedAICommandModelInfo)
        if !levels.isEmpty { return levels }
        return [CodexReasoningLevel(
            effort: aiCommandModelSettingsDraft.selectedReasoningEffort,
            description: ""
        )]
    }

    private func hotkeyBindingName(_ binding: HotkeyBinding) -> String {
        binding.keys.map {
            KeyNameFormatter.name(
                forKeyCode: $0.keyCode,
                isModifier: $0.isModifier,
                language: uiLanguage
            )
        }
            .joined(separator: " + ")
    }

    private var historyDisplayLimitBinding: Binding<Int> {
        Binding(
            get: { store.settings.historyDisplayLimit },
            set: { store.settings.historyDisplayLimit = $0 }
        )
    }

    private var settingsDisplayScaleBinding: Binding<Double> {
        Binding(
            get: { store.settings.settingsDisplayScale },
            set: { store.setSettingsDisplayScale($0) }
        )
    }

    private var historyDisplaySummary: String {
        let limit = store.settings.historyDisplayLimit
        let countLabel = limit <= 0 ? uiText("すべて") : uiFormat("最新%d件", limit)
        return uiFormat("表示対象は、保存済み本文がある履歴の%@です。本文を保存していない履歴は一覧に表示されません。", countLabel)
    }

    private var filteredHistoryEntries: [InputHistoryEntry] {
        let entriesWithStoredText = historyStore.entries.filter(InputHistoryStore.hasStoredText).filter {
            historyModeFilter == .all || $0.mode == historyModeFilter.storedMode
        }
        let limit = store.settings.historyDisplayLimit
        let visible = limit <= 0 ? entriesWithStoredText : Array(entriesWithStoredText.prefix(limit))
        let query = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visible }
        return visible.filter { entry in
            guard let text = entry.storedText else { return false }
            return text.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleHistoryIDs: Set<UUID> {
        Set(filteredHistoryEntries.map(\.id))
    }

    private var selectedVisibleHistoryIDs: Set<UUID> {
        selectedHistoryIDs.intersection(visibleHistoryIDs)
    }

    private var unselectedVisibleHistoryIDs: Set<UUID> {
        visibleHistoryIDs.subtracting(selectedHistoryIDs)
    }

    private var areAllVisibleHistoryEntriesSelected: Bool {
        !visibleHistoryIDs.isEmpty && visibleHistoryIDs.isSubset(of: selectedHistoryIDs)
    }

    private var historyEmptyMessage: String {
        uiText(
            historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "保存済み本文の履歴はまだありません。"
                : "条件に一致する履歴はありません。"
        )
    }

    private func historySelectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedHistoryIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedHistoryIDs.insert(id)
                } else {
                    selectedHistoryIDs.remove(id)
                }
            }
        )
    }

    private func toggleVisibleHistorySelection() {
        if areAllVisibleHistoryEntriesSelected {
            selectedHistoryIDs.subtract(visibleHistoryIDs)
        } else {
            selectedHistoryIDs.formUnion(visibleHistoryIDs)
        }
    }

    private func requestDeleteAllHistory() {
        historyDeletionRequest = HistoryDeletionRequest(
            kind: .all,
            targetIDs: Set(historyStore.entries.map(\.id)),
            storedTextCount: historyStore.storedTextCount,
            metadataOnlyCount: historyStore.metadataOnlyCount
        )
    }

    private func requestDeleteSelectedHistory() {
        let ids = selectedVisibleHistoryIDs
        guard !ids.isEmpty else { return }
        historyDeletionRequest = HistoryDeletionRequest(
            kind: .selected,
            targetIDs: ids,
            storedTextCount: ids.count,
            metadataOnlyCount: 0
        )
    }

    private func requestDeleteUnselectedDisplayedHistory() {
        let ids = unselectedVisibleHistoryIDs
        guard !ids.isEmpty else { return }
        historyDeletionRequest = HistoryDeletionRequest(
            kind: .unselectedDisplayed,
            targetIDs: ids,
            storedTextCount: ids.count,
            metadataOnlyCount: 0
        )
    }

    private func requestDeleteMetadataOnlyHistory() {
        let ids = historyStore.metadataOnlyIDs
        guard !ids.isEmpty else { return }
        historyDeletionRequest = HistoryDeletionRequest(
            kind: .metadataOnly,
            targetIDs: ids,
            storedTextCount: 0,
            metadataOnlyCount: ids.count
        )
    }

    private func shouldConfirmHistoryRetentionChange(
        to option: HistoryRetentionOption,
        scope: HistoryRetentionScope
    ) -> Bool {
        let current: HistoryRetentionOption
        switch scope {
        case .normal:
            current = HistoryRetentionOption.current(
                enabled: store.settings.historyEnabled,
                retentionDays: store.settings.historyRetentionDays
            )
        case .handsFreeSend:
            current = HistoryRetentionOption.current(
                enabled: store.settings.handsFreeSendSettings.historyEnabled,
                retentionDays: store.settings.handsFreeSendSettings.historyRetentionDays
            )
        case .aiCommand:
            current = HistoryRetentionOption.current(
                enabled: store.settings.aiCommandSettings.historyEnabled,
                retentionDays: store.settings.aiCommandSettings.historyRetentionDays
            )
        }
        guard current != option,
              option.isSavingEnabled,
              option.retentionDays > 0 else {
            return false
        }
        // 無期限・保存停止から有限期間へ変える場合、または有限期間を短くする場合だけ、
        // 実際に古いデータが削除され得るため確認する。
        guard current.isSavingEnabled else { return true }
        guard current.retentionDays > 0 else { return true }
        return option.retentionDays < current.retentionDays
    }

    private func applyHistoryRetention(_ option: HistoryRetentionOption, scope: HistoryRetentionScope) {
        switch scope {
        case .normal:
            store.settings.historyEnabled = option.isSavingEnabled
            store.settings.historyRetentionDays = option.retentionDays
        case .handsFreeSend:
            store.settings.handsFreeSendSettings.historyEnabled = option.isSavingEnabled
            store.settings.handsFreeSendSettings.historyRetentionDays = option.retentionDays
        case .aiCommand:
            store.settings.aiCommandSettings.historyEnabled = option.isSavingEnabled
            store.settings.aiCommandSettings.historyRetentionDays = option.retentionDays
        }
        if option.isSavingEnabled, option.retentionDays > 0 {
            showHistoryMutationResult(historyStore.prune(mode: scope.historyMode, retentionDays: option.retentionDays))
        }
    }

    private var historyRetentionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingHistoryRetentionChange != nil },
            set: { if !$0 { pendingHistoryRetentionChange = nil } }
        )
    }

    private var historyDeletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { historyDeletionRequest != nil },
            set: { if !$0 { historyDeletionRequest = nil } }
        )
    }

    private var historyDeletionTitle: String {
        historyDeletionRequest?.kind.title(for: uiLanguage)
            ?? AppLocalizer.text("履歴を削除", language: uiLanguage)
    }

    private var historyDeletionMessage: String {
        guard let request = historyDeletionRequest else {
            return uiText("履歴を削除します。この操作は元に戻せません。")
        }
        return uiFormat(
            "保存済み本文の履歴 %d件\n本文のないメタデータ %d件\nを削除します。この操作は元に戻せません。",
            request.storedTextCount,
            request.metadataOnlyCount
        )
    }

    private func performHistoryDeletion() {
        guard let request = historyDeletionRequest else { return }

        let result: InputHistoryStore.MutationResult
        switch request.kind {
        case .all:
            result = historyStore.delete(ids: request.targetIDs)
            if result == .saved { selectedHistoryIDs.removeAll() }
        case .selected, .unselectedDisplayed:
            result = historyStore.delete(ids: request.targetIDs)
            if result == .saved { selectedHistoryIDs.subtract(request.targetIDs) }
        case .metadataOnly:
            result = historyStore.delete(ids: request.targetIDs)
        }
        if result == .saved { historyDeletionRequest = nil }
        showHistoryMutationResult(result)
    }

    private var historyNeedsAttention: Bool {
        switch historyStore.loadStatus { case .missing, .ready: return false; case .malformed, .unreadable: return true }
    }

    private func showHistoryMutationResult(_ result: InputHistoryStore.MutationResult) {
        switch result {
        case .saved: historyOperationMessage = nil
        case .savedWithCleanupWarning:
            historyOperationMessage = uiText("新しい履歴は保存しましたが、古い履歴を整理できませんでした。履歴ファイルを確認してください。")
        case .blockedByMalformedHistory:
            historyOperationMessage = uiText("読み込めない履歴行を保護するため、この操作を実行しませんでした。履歴を再読み込みしてから試してください。")
        case .failed:
            historyOperationMessage = uiText("履歴の変更を保存できませんでした。画面上の履歴は変更していません。もう一度試してください。")
        }
    }

    private var historyRetentionConfirmationMessage: String {
        guard let request = pendingHistoryRetentionChange else {
            return uiText("古い履歴はすべて削除されます。この操作は元に戻せません。")
        }
        return AppLocalizer.format(
            "%@のうち、%@より古い履歴だけを削除します。この操作は元に戻せません。",
            language: uiLanguage,
            request.scope.title(for: uiLanguage),
            request.option.label(for: uiLanguage)
        )
    }

    private var recordingModeBinding: Binding<RecordingMode> {
        Binding(
            get: { RecordingMode(rawValue: store.settings.recordingMode) ?? .toggle },
            set: { store.settings.recordingMode = $0.rawValue }
        )
    }

    private var modelPresetBinding: Binding<String> {
        Binding(
            get: {
                switch modelSettingsDraft.mode {
                case .cli:
                    return "cli"
                case .explicit:
                    if let preset = CodexModelCatalog.builtInPresets.first(where: {
                        $0.slug == modelSettingsDraft.selectedModelSlug
                            && $0.effort == modelSettingsDraft.selectedReasoningEffort
                    }) {
                        return preset.id
                    }
                    return "custom"
                case .custom:
                    return "custom"
                }
            },
            set: { value in
                if value == "cli" {
                    modelSettingsDraft.mode = .cli
                    return
                }

                if value == "custom" {
                    if modelSettingsDraft.mode == .cli {
                        let model = availableModels.first
                        modelSettingsDraft = CodexModelSettings(
                            mode: .custom,
                            selectedModelSlug: model?.slug ?? CodexModelSettings.defaultModelSlug,
                            selectedReasoningEffort: model?.defaultReasoningLevel ?? CodexModelSettings.defaultReasoningEffort
                        )
                    } else {
                        modelSettingsDraft.mode = .custom
                        normalizeSelectedReasoning()
                    }
                    return
                }

                guard let preset = CodexModelCatalog.builtInPresets.first(where: { $0.id == value }) else { return }
                modelSettingsDraft = CodexModelSettings(
                    mode: .explicit,
                    selectedModelSlug: preset.slug,
                    selectedReasoningEffort: preset.effort
                )
            }
        )
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { modelSettingsDraft.selectedModelSlug },
            set: { slug in
                let model = availableModels.first { $0.slug == slug }
                let currentEffort = modelSettingsDraft.selectedReasoningEffort
                modelSettingsDraft = CodexModelSettings(
                    mode: .custom,
                    selectedModelSlug: slug,
                    selectedReasoningEffort: normalizedEffort(for: model, preferred: currentEffort)
                )
            }
        )
    }

    private var selectedReasoningBinding: Binding<String> {
        Binding(
            get: { modelSettingsDraft.selectedReasoningEffort },
            set: { effort in
                modelSettingsDraft.mode = modelSettingsDraft.mode == .explicit ? .explicit : .custom
                modelSettingsDraft.selectedReasoningEffort = effort
            }
        )
    }

    private var optimizationModelBinding: Binding<String> {
        Binding(
            get: { store.settings.customInstructionOptimizationModelSettings.selectedModelSlug },
            set: { slug in
                let model = optimizationAvailableModels.first { $0.slug == slug }
                let currentEffort = store.settings.customInstructionOptimizationModelSettings.selectedReasoningEffort
                store.settings.customInstructionOptimizationModelSettings = CodexModelSettings(
                    mode: .explicit,
                    selectedModelSlug: slug,
                    selectedReasoningEffort: normalizedEffort(for: model, preferred: currentEffort)
                )
            }
        )
    }

    private var optimizationReasoningBinding: Binding<String> {
        Binding(
            get: { store.settings.customInstructionOptimizationModelSettings.selectedReasoningEffort },
            set: { effort in
                store.settings.customInstructionOptimizationModelSettings = CodexModelSettings(
                    mode: .explicit,
                    selectedModelSlug: store.settings.customInstructionOptimizationModelSettings.selectedModelSlug,
                    selectedReasoningEffort: effort
                )
            }
        )
    }

    private var availableModels: [CodexModelInfo] {
        CodexModelCatalog.merge(
            fetchedModels,
            selectedSlug: modelSettingsDraft.selectedModelSlug
        )
    }

    /// 既存の最適化モデル設定は勝手に消さず表示だけ維持する。通常/M5の選択肢には混ぜない。
    private var optimizationAvailableModels: [CodexModelInfo] {
        let models = availableModels
        let optimizationSlug = store.settings.customInstructionOptimizationModelSettings.selectedModelSlug
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !optimizationSlug.isEmpty,
           !models.contains(where: { $0.slug == optimizationSlug }) {
            let unavailableModel = CodexModelInfo(
                slug: optimizationSlug,
                displayName: uiFormat("%@（現在利用不可）", optimizationSlug),
                defaultReasoningLevel: CodexModelSettings.defaultReasoningEffort,
                supportedReasoningLevels: [
                    CodexReasoningLevel(effort: CodexModelSettings.defaultReasoningEffort, description: "")
                ],
                visibility: "list"
            )
            // 利用可能なモデルの固定順を保った後、保存済みだが利用不可の値だけを最後に残す。
            return CodexModelCatalog.orderedModels(models) + [unavailableModel]
        }
        return models
    }

    /// M5は消えた保存済みslugを利用可能として合成せず、現在のCLI一覧だけを表示する。
    private var aiCommandAvailableModels: [CodexModelInfo] {
        CodexModelCatalog.merge(
            fetchedModels,
            selectedSlug: aiCommandModelSettingsDraft.selectedModelSlug
        )
    }

    private var selectedModelInfo: CodexModelInfo? {
        availableModels.first { $0.slug == modelSettingsDraft.selectedModelSlug }
    }

    private var normalModelIsAvailable: Bool {
        modelSettingsDraft.mode == .cli || CodexModelCatalog.isAvailable(
            slug: modelSettingsDraft.selectedModelSlug,
            in: availableModels
        )
    }

    private var selectedOptimizationModelInfo: CodexModelInfo? {
        optimizationAvailableModels.first { $0.slug == store.settings.customInstructionOptimizationModelSettings.selectedModelSlug }
    }

    private var supportedReasoningLevels: [CodexReasoningLevel] {
        let levels = CodexModelCatalog.userSelectableReasoningLevels(for: selectedModelInfo)
        if !levels.isEmpty {
            return levels
        }
        let effort = modelSettingsDraft.selectedReasoningEffort
        return [CodexReasoningLevel(effort: effort.isEmpty ? CodexModelSettings.defaultReasoningEffort : effort, description: "")]
    }

    private var optimizationReasoningLevels: [CodexReasoningLevel] {
        let levels = CodexModelCatalog.userSelectableReasoningLevels(for: selectedOptimizationModelInfo)
        if !levels.isEmpty {
            return levels
        }
        let effort = store.settings.customInstructionOptimizationModelSettings.selectedReasoningEffort
        return [CodexReasoningLevel(effort: effort.isEmpty ? "medium" : effort, description: "")]
    }

    private var humanReadableKeyName: String {
        KeyNameFormatter.name(
            forKeyCode: store.settings.hotkeyKeyCode,
            isModifier: store.settings.hotkeyIsModifier,
            language: uiLanguage
        )
    }

    private func reasoningLevelLabel(_ level: CodexReasoningLevel) -> String {
        let effort = level.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        switch effort {
        case "low":
            return uiText("low（高速）")
        case "medium":
            return uiText("medium（バランス）")
        case "high":
            return uiText("high（高精度）")
        case "xhigh":
            return uiText("xhigh（最高精度）")
        case "max":
            return uiText("max（最大・長時間）")
        default:
            return effort.isEmpty ? CodexModelSettings.defaultReasoningEffort : effort
        }
    }

    private func normalizedEffort(for model: CodexModelInfo?, preferred: String) -> String {
        guard let model else {
            return preferred.isEmpty ? CodexModelSettings.defaultReasoningEffort : preferred
        }
        let selectableLevels = CodexModelCatalog.userSelectableReasoningLevels(for: model)
        if selectableLevels.contains(where: { $0.effort == preferred }) {
            return preferred
        }
        if CodexModelCatalog.isUserSelectable(effort: model.defaultReasoningLevel, for: model) {
            return model.defaultReasoningLevel
        }
        return selectableLevels.first?.effort ?? CodexModelSettings.defaultReasoningEffort
    }

    private func normalizeSelectedReasoning() {
        modelSettingsDraft.selectedReasoningEffort = normalizedEffort(
            for: selectedModelInfo,
            preferred: modelSettingsDraft.selectedReasoningEffort
        )
        store.settings.customInstructionOptimizationModelSettings.selectedReasoningEffort = normalizedEffort(
            for: selectedOptimizationModelInfo,
            preferred: store.settings.customInstructionOptimizationModelSettings.selectedReasoningEffort
        )
        let aiModel = aiCommandAvailableModels.first { $0.slug == aiCommandModelSettingsDraft.selectedModelSlug }
        aiCommandModelSettingsDraft.selectedReasoningEffort = normalizedEffort(
            for: aiModel,
            preferred: aiCommandModelSettingsDraft.selectedReasoningEffort
        )
    }

    private var hasCustomInstructionChanges: Bool {
        customInstructionDraft != store.settings.customInstruction
    }

    private var hasModelSettingsChanges: Bool {
        modelSettingsDraft != store.settings.modelSettings
    }

    private var hasAICommandModelSettingsChanges: Bool {
        aiCommandModelSettingsDraft != store.settings.aiCommandSettings.modelSettings
            || aiCommandWebSearchDraft != store.settings.aiCommandSettings.webSearchEnabled
    }

    private var hasAICommandCustomInstructionChanges: Bool {
        aiCommandCustomInstructionDraft != store.settings.aiCommandSettings.additionalInstruction
    }

    private var hasCodexExecutablePathChanges: Bool {
        codexExecutablePathDraft != store.settings.codexExecutablePath
    }

    private var isVoiceProcessing: Bool {
        observedPipelinePhase != .idle
    }

    private var canOptimizeCustomInstruction: Bool {
        store.settings.cleanupEnabled
            && !isOptimizingCustomInstruction
            && !customInstructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canStepCustomInstructionHistoryBackward: Bool {
        customInstructionHistoryCursor > 0
            && customInstructionHistoryCursor < customInstructionStateStore.state.customInstructionHistory.count
    }

    private var canStepCustomInstructionHistoryForward: Bool {
        customInstructionHistoryCursor >= 0
            && customInstructionHistoryCursor < customInstructionStateStore.state.customInstructionHistory.count - 1
    }

    private var canOptimizeAICommandCustomInstruction: Bool {
        store.settings.aiCommandSettings.enabled
            && !isOptimizingAICommandCustomInstruction
            && !aiCommandCustomInstructionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canStepAICommandCustomInstructionHistoryBackward: Bool {
        aiCommandCustomInstructionHistoryCursor > 0
            && aiCommandCustomInstructionHistoryCursor < aiCommandCustomInstructionStateStore.state.customInstructionHistory.count
    }

    private var canStepAICommandCustomInstructionHistoryForward: Bool {
        aiCommandCustomInstructionHistoryCursor >= 0
            && aiCommandCustomInstructionHistoryCursor < aiCommandCustomInstructionStateStore.state.customInstructionHistory.count - 1
    }

    private func initializeDraftsFromSettings() {
        customInstructionDraft = store.settings.customInstruction
        handsFreeSendCustomPhraseDraft = store.settings.handsFreeSendSettings.customPhrase
        // 未設定なら最初から入力できる。設定済みならロックした状態で開く。
        handsFreeSendCustomPhraseIsEditing = store.settings.handsFreeSendSettings.customPhrase.isEmpty
        modelSettingsDraft = store.settings.modelSettings
        aiCommandModelSettingsDraft = store.settings.aiCommandSettings.modelSettings
        aiCommandWebSearchDraft = store.settings.aiCommandSettings.webSearchEnabled
        aiCommandCustomInstructionDraft = store.settings.aiCommandSettings.additionalInstruction
        codexExecutablePathDraft = store.settings.codexExecutablePath
        let history = customInstructionStateStore.state.customInstructionHistory
        customInstructionHistoryCursor = history.isEmpty ? -1 : min(
            max(customInstructionStateStore.state.customInstructionHistoryIndex, 0),
            history.count - 1
        )
        let aiCommandHistory = aiCommandCustomInstructionStateStore.state.customInstructionHistory
        aiCommandCustomInstructionHistoryCursor = aiCommandHistory.isEmpty ? -1 : min(
            max(aiCommandCustomInstructionStateStore.state.customInstructionHistoryIndex, 0),
            aiCommandHistory.count - 1
        )
    }

    private func saveCustomInstruction() {
        let previous = store.settings.customInstruction
        store.settings.customInstruction = customInstructionDraft
        store.flushPendingSave()

        if customInstructionStateStore.state.optimizedInstruction == customInstructionDraft {
            customInstructionStateStore.recordOptimizedInstructionLoaded(
                previousCustomInstruction: previous,
                optimizedInstruction: customInstructionDraft
            )
        }
        customInstructionStateStore.recordCustomInstructionSave(
            customInstructionDraft,
            previousInstruction: previous
        )
        let history = customInstructionStateStore.state.customInstructionHistory
        customInstructionHistoryCursor = history.isEmpty ? -1 : history.count - 1
        customInstructionMessage = uiText("カスタムインストラクションを保存しました。")
    }

    private func stepCustomInstructionHistory(by offset: Int) {
        let history = customInstructionStateStore.state.customInstructionHistory
        guard !history.isEmpty else { return }
        let currentIndex = customInstructionHistoryCursor < 0 ? history.count - 1 : customInstructionHistoryCursor
        let nextIndex = currentIndex + offset
        guard history.indices.contains(nextIndex) else { return }
        customInstructionHistoryCursor = nextIndex
        customInstructionDraft = history[nextIndex]
        customInstructionMessage = uiText("保存済み履歴を読み込みました。保存すると反映されます。")
    }

    private func saveAICommandCustomInstruction() {
        let previous = store.settings.aiCommandSettings.additionalInstruction
        store.settings.aiCommandSettings.additionalInstruction = aiCommandCustomInstructionDraft
        store.flushPendingSave()

        if aiCommandCustomInstructionStateStore.state.optimizedInstruction == aiCommandCustomInstructionDraft {
            aiCommandCustomInstructionStateStore.recordOptimizedInstructionLoaded(
                previousCustomInstruction: previous,
                optimizedInstruction: aiCommandCustomInstructionDraft
            )
        }
        aiCommandCustomInstructionStateStore.recordCustomInstructionSave(
            aiCommandCustomInstructionDraft,
            previousInstruction: previous
        )
        let history = aiCommandCustomInstructionStateStore.state.customInstructionHistory
        aiCommandCustomInstructionHistoryCursor = history.isEmpty ? -1 : history.count - 1
        aiCommandCustomInstructionMessage = uiText("カスタムインストラクションを保存しました。")
    }

    private func stepAICommandCustomInstructionHistory(by offset: Int) {
        let history = aiCommandCustomInstructionStateStore.state.customInstructionHistory
        guard !history.isEmpty else { return }
        let currentIndex = aiCommandCustomInstructionHistoryCursor < 0
            ? history.count - 1
            : aiCommandCustomInstructionHistoryCursor
        let nextIndex = currentIndex + offset
        guard history.indices.contains(nextIndex) else { return }
        aiCommandCustomInstructionHistoryCursor = nextIndex
        aiCommandCustomInstructionDraft = history[nextIndex]
        aiCommandCustomInstructionMessage = uiText("保存済み履歴を読み込みました。保存すると反映されます。")
    }

    private func saveModelSettings() {
        guard !isSavingModelSettings,
              SettingsActionSafetyPolicy.allowsReconfiguration(
                phase: appState.phase
              ) else { return }
        let operationID = UUID()
        store.settings.modelSettings = modelSettingsDraft
        store.flushPendingSave()
        normalModelSaveOperationID = operationID
        isSavingModelSettings = true
        modelFetchMessage = uiText("AIモデル設定を保存しました。Codexへ再接続しています。")

        Task {
            let result = await appDelegate.reconnectCleanupModel()
            await MainActor.run {
                guard normalModelSaveOperationID == operationID else { return }
                isSavingModelSettings = false
                switch result {
                case .success:
                    modelFetchMessage = nil
                case .failure:
                    modelFetchMessage = uiText("AIモデル設定は保存しましたが、Codexへの再接続に失敗しました。もう一度試してください。")
                }
            }
        }
    }

    private func saveAICommandModelSettings() {
        guard !isSavingAICommandModelSettings,
              SettingsActionSafetyPolicy.allowsReconfiguration(
                phase: appState.phase
              ),
              aiCommandModelIsAvailable else { return }
        let operationID = UUID()
        let savedModelSettings = aiCommandModelSettingsDraft
        let savedWebSearchEnabled = aiCommandModelSupportsWeb && aiCommandWebSearchDraft
        if aiCommandWebSearchDraft && !aiCommandModelSupportsWeb {
            aiCommandWebSearchDraft = false
            aiCommandModelSettingsNotice = uiText("選択したモデルがWeb検索非対応のため、Web検索をオフにしました。")
        }
        store.settings.aiCommandSettings.modelSettings = savedModelSettings
        store.settings.aiCommandSettings.webSearchEnabled = savedWebSearchEnabled
        store.flushPendingSave()
        aiCommandModelSaveOperationID = operationID
        isSavingAICommandModelSettings = true
        aiCommandModelSettingsMessage = uiText("AIモデル設定を保存しました。Codexへ再接続しています。")

        Task {
            let result = await appDelegate.reconnectAICommandModel(
                modelSettings: savedModelSettings,
                webSearchEnabled: savedWebSearchEnabled
            )
            await MainActor.run {
                guard aiCommandModelSaveOperationID == operationID else { return }
                isSavingAICommandModelSettings = false
                switch result {
                case .success:
                    aiCommandModelSettingsMessage = nil
                case .failure:
                    aiCommandModelSettingsMessage = uiText("AIモデル設定は保存しましたが、Codexへの再接続に失敗しました。もう一度試してください。")
                }
            }
        }
    }

    private func saveCodexExecutablePath() {
        store.settings.codexExecutablePath = codexExecutablePathDraft
        store.flushPendingSave()
        appDelegate.retryCodexConnection()
    }

    /// 入力欄を空にして保存し直し、既知の場所とログインシェルからの自動探索をやり直させる。
    private func redetectCodexExecutablePath() {
        codexExecutablePathDraft = ""
        saveCodexExecutablePath()
    }

    /// ターミナルを一切使わずにcodexの場所を指定できるようにする。
    private func chooseCodexExecutablePath() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = uiText("codex実行ファイルを選択してください")
        panel.prompt = uiText("選択")

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            codexExecutablePathDraft = url.path
            saveCodexExecutablePath()
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyHistoryText(_ text: String, entryID: UUID) {
        copyToPasteboard(text)
        copiedHistoryEntryID = entryID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if copiedHistoryEntryID == entryID {
                copiedHistoryEntryID = nil
            }
        }
    }

    private func optimizeCustomInstruction() {
        guard canOptimizeCustomInstruction else {
            customInstructionMessage = uiText("最適化するカスタムインストラクションを入力してください。")
            return
        }

        isOptimizingCustomInstruction = true
        customInstructionMessage = nil
        let settings = store.settings
        let currentInstruction = customInstructionDraft
        let dictionaryEntries = dictionaryStore.enabledEntries
        let executablePath = nonEmptyCodexPath(settings.codexExecutablePath)
        let modelSettings = settings.customInstructionOptimizationModelSettings

        Task {
            let optimizer = CustomInstructionOptimizer(
                executablePath: executablePath,
                modelSettings: modelSettings,
                mode: .normal,
                language: settings.languagePreferences.sttLanguage
            )
            do {
                let result = try await optimizer.optimize(
                    customInstruction: currentInstruction,
                    dictionaryEntries: dictionaryEntries
                )
                await optimizer.shutdown()
                await MainActor.run {
                    customInstructionStateStore.recordOptimizationGenerated(result)
                    optimizationDraft = CustomInstructionOptimizationDraft(
                        mode: .normal,
                        optimizedInstruction: result.optimizedInstruction
                    )
                    customInstructionMessage = nil
                    isOptimizingCustomInstruction = false
                }
            } catch {
                await optimizer.shutdown()
                await MainActor.run {
                    AppLog.shared.warn("カスタムインストラクションの最適化に失敗しました")
                    customInstructionMessage = uiText("カスタムインストラクションを最適化できませんでした。少し待ってから、もう一度試してください。")
                    isOptimizingCustomInstruction = false
                }
            }
        }
    }

    private func optimizeAICommandCustomInstruction() {
        guard canOptimizeAICommandCustomInstruction else {
            aiCommandCustomInstructionMessage = uiText("最適化するカスタムインストラクションを入力してください。")
            return
        }

        isOptimizingAICommandCustomInstruction = true
        aiCommandCustomInstructionMessage = nil
        let settings = store.settings
        let currentInstruction = aiCommandCustomInstructionDraft
        let dictionaryEntries = dictionaryStore.enabledEntries
        let executablePath = nonEmptyCodexPath(settings.codexExecutablePath)
        let modelSettings = settings.customInstructionOptimizationModelSettings

        Task {
            let optimizer = CustomInstructionOptimizer(
                executablePath: executablePath,
                modelSettings: modelSettings,
                mode: .aiCommand,
                language: settings.languagePreferences.sttLanguage
            )
            do {
                let result = try await optimizer.optimize(
                    customInstruction: currentInstruction,
                    dictionaryEntries: dictionaryEntries
                )
                await optimizer.shutdown()
                await MainActor.run {
                    aiCommandCustomInstructionStateStore.recordOptimizationGenerated(result)
                    optimizationDraft = CustomInstructionOptimizationDraft(
                        mode: .aiCommand,
                        optimizedInstruction: result.optimizedInstruction
                    )
                    aiCommandCustomInstructionMessage = nil
                    isOptimizingAICommandCustomInstruction = false
                }
            } catch {
                await optimizer.shutdown()
                await MainActor.run {
                    AppLog.shared.warn("AIに指示用カスタムインストラクションの最適化に失敗しました")
                    aiCommandCustomInstructionMessage = uiText("カスタムインストラクションを最適化できませんでした。少し待ってから、もう一度試してください。")
                    isOptimizingAICommandCustomInstruction = false
                }
            }
        }
    }

    private func applyOptimizationDraft(_ draft: CustomInstructionOptimizationDraft) {
        optimizationDraft = nil
        switch draft.mode {
        case .normal:
            customInstructionDraft = draft.optimizedInstruction
            customInstructionMessage = uiText("カスタムインストラクション欄へ読み込みました。保存すると反映されます。")
        case .aiCommand:
            aiCommandCustomInstructionDraft = draft.optimizedInstruction
            aiCommandCustomInstructionMessage = uiText("カスタムインストラクション欄へ読み込みました。保存すると反映されます。")
        }
    }

    private func nonEmptyCodexPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var historyDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = uiLanguage.locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    private var historyDeleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { historyDeleteTarget != nil },
            set: { if !$0 { historyDeleteTarget = nil } }
        )
    }

    private func refreshModelCatalog() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true
        modelFetchMessage = nil

        let settingsPath = codexExecutablePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = CodexModelCatalogService()
        Task {
            do {
                let models = try await service.fetchModels(settingsExecutablePath: settingsPath.isEmpty ? nil : settingsPath)
                await MainActor.run {
                    fetchedModels = models
                    isModelCatalogVerified = true
                    if !didResolveInitialModelDefaults {
                        store.resolveInitialModelDefaults(usingLiveModels: models)
                        modelSettingsDraft = store.settings.modelSettings
                        aiCommandModelSettingsDraft = store.settings.aiCommandSettings.modelSettings
                        aiCommandWebSearchDraft = store.settings.aiCommandSettings.webSearchEnabled
                        didResolveInitialModelDefaults = true
                    }
                    normalizeSelectedReasoning()
                    isRefreshingModels = false
                    if let selected = models.first(where: { $0.slug == aiCommandModelSettingsDraft.selectedModelSlug }),
                       !selected.supportsSearchTool,
                       aiCommandWebSearchDraft {
                        aiCommandWebSearchDraft = false
                        aiCommandModelSettingsNotice = uiText("選択したモデルがWeb検索非対応のため、Web検索をオフにしました。")
                    } else if !models.contains(where: { $0.slug == aiCommandModelSettingsDraft.selectedModelSlug }) {
                        aiCommandModelSettingsMessage = uiText("選択したモデルは現在利用できません。利用可能なモデルを選んでください。")
                    } else {
                        aiCommandModelSettingsNotice = nil
                        modelFetchMessage = nil
                    }
                }
            } catch {
                await MainActor.run {
                    fetchedModels = CodexModelCatalog.builtInModels
                    isModelCatalogVerified = false
                    normalizeSelectedReasoning()
                    isRefreshingModels = false
                    modelFetchMessage = uiText("モデル一覧を取得できませんでした。保存済みの設定は保持されています。Codex CLIを最新バージョンに更新してから、もう一度モデル一覧を更新してください。")
                }
            }
        }
    }

    private func refreshMicrophones() {
        microphones = MicrophoneDeviceManager.inputDevices()
        defaultMicrophoneName = MicrophoneDeviceManager.defaultInputDevice()?.name ?? uiText("現在のデバイス")
    }

    /// 設定画面は従来どおり候補を取得後すぐに保存する。
    /// ただし入力解析はオンボーディングと共通化し、Fn + Spaceを全解放後に確定する。
    private func startKeyCapture(target: KeyCaptureTarget = .normal) {
        guard !isCapturingKey else { return }
        aiCommandSettingsMessage = nil
        handsFreeSendSettingsMessage = nil
        appDelegate.setHotkeyCaptureActive(true)
        isCapturingKey = true
        keyCaptureTarget = target
        keyCaptureMonitor.start(policy: capturePolicy(for: target)) { status in
            finishCapturedHotkey(status)
        }
    }

    private func capturePolicy(for target: KeyCaptureTarget) -> HotkeyCapturePolicy {
        switch target {
        case .normal: return .normalSingleKey
        case .aiStart: return .aiStart
        case .aiStop: return .aiStop
        case .handsFreeSend: return .aiStart
        }
    }

    private func finishCapturedHotkey(_ status: HotkeyCaptureStatus) {
        let capturedKeys = status.candidate?.keys ?? []
        defer { stopKeyCapture(afterReleasing: capturedKeys, stopMonitor: false) }

        switch status {
        case let .candidate(binding):
            switch keyCaptureTarget {
            case .normal:
                saveNormalHotkey(binding)
            case .aiStart, .aiStop:
                saveAICommandBinding(binding)
            case .handsFreeSend:
                saveHandsFreeSendBinding(binding)
            }
        case let .invalid(error):
            switch keyCaptureTarget {
            case .handsFreeSend:
                handsFreeSendSettingsMessage = error.message(for: uiLanguage)
            case .normal, .aiStart, .aiStop:
                aiCommandSettingsMessage = error.message(for: uiLanguage)
            }
        case .cancelled:
            aiCommandSettingsMessage = nil
            handsFreeSendSettingsMessage = nil
        case .capturing:
            break
        }
    }

    private func saveAICommandBinding(_ binding: HotkeyBinding) {
        guard binding.isValid, !isReservedAICommandBinding(binding) else {
            aiCommandSettingsMessage = uiText("このキーの組み合わせは使用できません。1〜3個のキーを選び、複数キーでは修飾キーを含めてください。")
            return
        }
        if keyCaptureTarget == .aiStart,
           (binding.conflictsExactly(with: normalHotkeyBinding)
                || binding.conflictsExactly(with: store.settings.handsFreeSendSettings.binding)
                || binding.isStrictPrefix(of: store.settings.handsFreeSendSettings.binding)
                || store.settings.handsFreeSendSettings.binding.isStrictPrefix(of: binding)) {
            aiCommandSettingsMessage = uiText("通常モードまたはハンズフリー送信モードですでに使われている起動キーです。別のキーを選んでください。")
            return
        }
        switch keyCaptureTarget {
        case .aiStart:
            guard !binding.conflictsExactly(with: store.settings.aiCommandSettings.stopHotkey) else {
                aiCommandSettingsMessage = uiText("起動キーと停止キーを同じ組み合わせにはできません。")
                return
            }
            store.settings.aiCommandSettings.startHotkey = binding
        case .aiStop:
            guard binding.keys.count == 1,
                  !binding.conflictsExactly(with: store.settings.aiCommandSettings.startHotkey) else {
                aiCommandSettingsMessage = uiText("停止キーは1個にし、起動キーと異なるキーを選んでください。")
                return
            }
            store.settings.aiCommandSettings.stopHotkey = binding
        case .normal:
            break
        case .handsFreeSend:
            break
        }
        refreshHotkeyDerivedState()
    }

    private func saveHandsFreeSendBinding(_ binding: HotkeyBinding) {
        guard keyCaptureTarget == .handsFreeSend else { return }
        guard HandsFreeSendHotkeyPolicy.canUse(
            binding,
            normalStart: normalHotkeyBinding,
            aiCommandStart: store.settings.aiCommandSettings.startHotkey,
            aiCommandStop: store.settings.aiCommandSettings.stopHotkey
        ) else {
            handsFreeSendSettingsMessage = uiText("起動キーは通常モード・AIに指示モードのキーと同じ組み合わせや、AIに指示モードの起動キーと前方一致する組み合わせにはできません。")
            return
        }
        store.settings.handsFreeSendSettings.binding = binding
        handsFreeSendSettingsMessage = nil
        refreshHotkeyDerivedState()
    }

    private func saveNormalHotkey(_ binding: HotkeyBinding) {
        guard let key = binding.keys.first,
              !binding.conflictsExactly(with: store.settings.aiCommandSettings.startHotkey),
              !binding.conflictsExactly(with: store.settings.handsFreeSendSettings.binding) else {
            aiCommandSettingsMessage = uiText("AIに指示モードまたはハンズフリー送信モードのキーと重複しています。別のキーを選んでください。")
            return
        }
        store.settings.hotkeyKeyCode = key.keyCode
        store.settings.hotkeyIsModifier = key.isModifier
        store.settings.hotkeyModifierMask = key.modifierMask
        refreshHotkeyDerivedState()
    }

    private func isReservedAICommandBinding(_ binding: HotkeyBinding) -> Bool {
        binding.isKnownSystemReserved
    }

    /// 重い判定の再計算が必要かを見分けるための、依存する設定値だけの小さなキー。
    ///
    /// `body`の中で作られるが、やるのは値のコピーと比較だけで、`HotkeyBinding`の
    /// 構築（重複排除→正規化→ソート）も`Set`確保も起きない。
    /// 保存経路を1つずつ拾うより、この差分検知の方が取りこぼしが無い
    /// （新しい保存箇所が増えても自動的に追随する）。
    private struct HotkeyDerivedStateKey: Equatable {
        let normalKeyCode: UInt16
        let normalIsModifier: Bool
        let normalModifierMask: UInt64
        let recordingMode: String
        let aiCommandEnabled: Bool
        let aiCommandStart: HotkeyBinding
        let aiCommandStop: HotkeyBinding
        let handsFreeSendEnabled: Bool
        let handsFreeSendBinding: HotkeyBinding
        let clipboardVariantEnabled: Bool
        let clipboardVariantModifier: AICommandClipboardModifier
    }

    private var hotkeyDerivedStateKey: HotkeyDerivedStateKey {
        let ai = store.settings.aiCommandSettings
        return HotkeyDerivedStateKey(
            normalKeyCode: store.settings.hotkeyKeyCode,
            normalIsModifier: store.settings.hotkeyIsModifier,
            normalModifierMask: store.settings.hotkeyModifierMask,
            recordingMode: store.settings.recordingMode,
            aiCommandEnabled: ai.enabled,
            aiCommandStart: ai.startHotkey,
            aiCommandStop: ai.stopHotkey,
            handsFreeSendEnabled: store.settings.handsFreeSendSettings.enabled,
            handsFreeSendBinding: store.settings.handsFreeSendSettings.binding,
            clipboardVariantEnabled: ai.clipboardVariantEnabled,
            clipboardVariantModifier: ai.clipboardVariantModifier
        )
    }

    private var normalHotkeyBinding: HotkeyBinding {
        store.settings.normalHotkeyBinding
    }

    /// `body`からは呼ばない。`hotkeyDerivedStateKey`が変わった時だけ評価し、
    /// 結果は`@State`へ持つ（理由は`HotkeyDerivedStateKey`のコメント）。
    private func computeNormalHoldStartRequiresSpecialChordResolution() -> Bool {
        RecordingMode(rawValue: store.settings.recordingMode) == .hold
            && (
                (store.settings.aiCommandSettings.enabled
                    && normalHotkeyBinding.isStrictPrefix(of: store.settings.aiCommandSettings.startHotkey))
                || (store.settings.handsFreeSendSettings.enabled
                    && normalHotkeyBinding.isStrictPrefix(of: store.settings.handsFreeSendSettings.binding))
            )
    }

    /// ホットキー由来の重い判定を再計算する。`body`の中では呼ばない。
    private func refreshHotkeyDerivedState() {
        cachedNormalHoldStartRequiresSpecialChordResolution =
            computeNormalHoldStartRequiresSpecialChordResolution()
        let ai = store.settings.aiCommandSettings
        let clipboardVariantState = AICommandClipboardSettingsDerivedState.make(
            startBinding: ai.startHotkey,
            stopBinding: ai.stopHotkey,
            normalBinding: normalHotkeyBinding,
            handsFreeSendBinding: store.settings.handsFreeSendSettings.binding,
            handsFreeSendEnabled: store.settings.handsFreeSendSettings.enabled,
            clipboardVariantEnabled: ai.clipboardVariantEnabled,
            currentModifier: ai.clipboardVariantModifier,
            language: uiLanguage
        )
        cachedClipboardVariantEligibilities = clipboardVariantState.eligibilities
        cachedClipboardVariantPickerOptions = clipboardVariantState.pickerOptions
        cachedClipboardVariantEligibilityMessage = clipboardVariantState.ineligibilityMessage
    }

    private func cancelKeyCapture() {
        aiCommandSettingsMessage = nil
        handsFreeSendSettingsMessage = nil
        stopKeyCapture()
    }

    private func stopKeyCapture(afterReleasing capturedKeys: [HotkeyKey] = [], stopMonitor: Bool = true) {
        if stopMonitor {
            keyCaptureMonitor.cancel()
        }
        isCapturingKey = false
        appDelegate.setHotkeyCaptureActive(false, capturedKeys: capturedKeys)
    }
}

private enum CustomInstructionDraftMode {
    case normal
    case aiCommand

    var previewTitle: String {
        switch self {
        case .normal:
            return "カスタムインストラクションを最適化"
        case .aiCommand:
            return "AIに指示モードのカスタムインストラクションを最適化"
        }
    }

    var previewHelp: String {
        switch self {
        case .normal:
            return "最適化結果をカスタムインストラクション欄へ読み込んだ後、保存すると反映されます。"
        case .aiCommand:
            return "最適化結果をAIに指示モード用のカスタムインストラクション欄へ読み込んだ後、保存すると反映されます。"
        }
    }
}

private struct CustomInstructionOptimizationDraft: Identifiable {
    let id = UUID()
    var mode: CustomInstructionDraftMode
    var optimizedInstruction: String
}

/// keyCodeを人間可読な名前へ変換するユーティリティ。
enum KeyNameFormatter {
    /// keyCodeから決まる安定した内部ID。表示文字列を翻訳キーとして再利用しない。
    private enum NamedKey {
        case fnGlobe, leftCommand, rightCommand, rightOption, leftOption
        case rightShift, leftShift, rightControl, leftControl
        case space, `return`, enter, tab, escape, delete, forwardDelete
        case leftArrow, rightArrow, downArrow, upArrow, home, end, pageUp, pageDown
        case function(String)

        func displayName(for language: AppLanguage) -> String {
            switch (self, language) {
            case (.fnGlobe, .japanese): return "fn (🌐)"
            case (.fnGlobe, .english): return "Fn (Globe)"
            case (.leftCommand, .japanese): return "左⌘ (Command)"
            case (.leftCommand, .english): return "Left Command"
            case (.rightCommand, .japanese): return "右⌘ (Command)"
            case (.rightCommand, .english): return "Right Command"
            case (.rightOption, .japanese): return "右⌥ (Option)"
            case (.rightOption, .english): return "Right Option"
            case (.leftOption, .japanese): return "左⌥ (Option)"
            case (.leftOption, .english): return "Left Option"
            case (.rightShift, .japanese): return "右⇧ (Shift)"
            case (.rightShift, .english): return "Right Shift"
            case (.leftShift, .japanese): return "左⇧ (Shift)"
            case (.leftShift, .english): return "Left Shift"
            case (.rightControl, .japanese): return "右⌃ (Control)"
            case (.rightControl, .english): return "Right Control"
            case (.leftControl, .japanese): return "左⌃ (Control)"
            case (.leftControl, .english): return "Left Control"
            case (.space, .japanese): return "Space"
            case (.space, .english): return "Space"
            case (.return, .japanese): return "Return"
            case (.return, .english): return "Return"
            case (.enter, .japanese): return "Enter"
            case (.enter, .english): return "Enter"
            case (.tab, .japanese): return "Tab"
            case (.tab, .english): return "Tab"
            case (.escape, .japanese): return "Esc"
            case (.escape, .english): return "Escape"
            case (.delete, .japanese): return "Delete"
            case (.delete, .english): return "Delete"
            case (.forwardDelete, .japanese): return "Forward Delete"
            case (.forwardDelete, .english): return "Forward Delete"
            case (.leftArrow, _): return "←"
            case (.rightArrow, _): return "→"
            case (.downArrow, _): return "↓"
            case (.upArrow, _): return "↑"
            case (.home, _): return "Home"
            case (.end, _): return "End"
            case (.pageUp, _): return "Page Up"
            case (.pageDown, _): return "Page Down"
            case (.function(let key), _): return key
            }
        }
    }

    private static let namedKeyCodes: [UInt16: NamedKey] = [
        0x3F: .fnGlobe, 0x37: .leftCommand, 0x36: .rightCommand,
        0x3D: .rightOption, 0x3A: .leftOption, 0x3C: .rightShift,
        0x38: .leftShift, 0x3E: .rightControl, 0x3B: .leftControl,
        0x31: .space, 0x24: .return, 0x4C: .enter, 0x30: .tab,
        0x35: .escape, 0x33: .delete, 0x75: .forwardDelete,
        0x7B: .leftArrow, 0x7C: .rightArrow, 0x7D: .downArrow, 0x7E: .upArrow,
        0x73: .home, 0x77: .end, 0x74: .pageUp, 0x79: .pageDown,
        0x7A: .function("F1"), 0x78: .function("F2"), 0x63: .function("F3"),
        0x76: .function("F4"), 0x60: .function("F5"), 0x61: .function("F6"),
        0x62: .function("F7"), 0x64: .function("F8"), 0x65: .function("F9"),
        0x6D: .function("F10"), 0x67: .function("F11"), 0x6F: .function("F12"),
        0x69: .function("F13"), 0x6B: .function("F14"), 0x71: .function("F15"),
        0x6A: .function("F16"), 0x40: .function("F17"), 0x4F: .function("F18"),
        0x50: .function("F19"), 0x5A: .function("F20"),
    ]

    static func name(
        forKeyCode keyCode: UInt16,
        isModifier: Bool,
        language: AppLanguage = .japanese
    ) -> String {
        if let named = namedKeyCodes[keyCode] {
            return named.displayName(for: language)
        }
        if !isModifier, let printable = printableName(forKeyCode: keyCode) {
            return printable
        }
        return AppLocalizer.format(
            isModifier ? "修飾キー (code %d)" : "キー (code %d)",
            language: language,
            Int(keyCode)
        )
    }

    /// 現在のキーボードレイアウトで印字可能なキー名を取得する。特殊キーは上の固定名を優先する。
    private static func printableName(forKeyCode keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboardLayout in
            var deadKeyState: UInt32 = 0
            var actualLength = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &actualLength,
                &characters
            )
            guard status == noErr, actualLength > 0 else { return nil }

            let value = String(utf16CodeUnits: characters, count: actualLength)
            guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value
        }
    }
}
