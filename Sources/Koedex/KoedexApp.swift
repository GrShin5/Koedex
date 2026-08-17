import SwiftUI
import AppKit
import AVFoundation
import Combine
import Carbon.HIToolbox

struct AICommandFailureOwnership {
    private(set) var ownerID: UUID?

    var isPresented: Bool { ownerID != nil }

    mutating func present(ownerID: UUID) {
        self.ownerID = ownerID
    }

    func isOwned(by ownerID: UUID) -> Bool {
        self.ownerID == ownerID
    }

    mutating func clear() {
        ownerID = nil
    }
}

extension Notification.Name {
    static let koedexOpenSettings = Notification.Name("Koedex.openSettings")
}

/// Dockの再オープン時に、通常版がどの画面を優先するかをUI非依存で決める。
/// Debug.appは従来の通常macOSアプリ挙動を維持するため、ここでは介入しない。
enum DockLifecyclePolicy {
    enum ReopenDestination: Equatable {
        case unchanged
        case onboarding
        case settings
    }

    static func reopenDestination(
        isDebug: Bool,
        allPermissionsGranted: Bool,
        setupIsComplete: Bool
    ) -> ReopenDestination {
        guard !isDebug else { return .unchanged }
        return allPermissionsGranted && setupIsComplete ? .settings : .onboarding
    }

    static func keepsRunningAfterLastWindowClosed(isDebug: Bool) -> Bool {
        !isDebug
    }
}

/// 通常時だけ独自テンプレート画像を使い、既存状態アイコンはSF Symbolのままにする。
enum MenuBarIconPolicy {
    static func usesCustomTemplate(isDebug: Bool, systemImageName: String) -> Bool {
        !isDebug && systemImageName == "mic"
    }
}

private enum MenuBarBranding {
    static func templateImage() -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: "KoedexMenuBarTemplate",
            withExtension: "pdf"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

private struct MenuBarStatusIcon: View {
    let systemImageName: String

    var body: some View {
        if MenuBarIconPolicy.usesCustomTemplate(
            isDebug: OnboardingRuntimeProfile.isDebug,
            systemImageName: systemImageName
        ), let image = MenuBarBranding.templateImage() {
            Image(nsImage: image)
                .renderingMode(.template)
                .accessibilityLabel(Text("Koedex"))
        } else {
            Image(systemName: systemImageName)
        }
    }
}

private struct SettingsWindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow
    @State private var didOpenDebugMainWindow = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                // SwiftUIのWindow sceneは、MenuBarExtraだけで再起動した場合に
                // 自動生成されないことがある。Debug.appは起動直後に必ず
                // セットアップ用Windowを要求し、保存済みのrestart intentを
                // 表示できるようにする。
                guard OnboardingRuntimeProfile.isDebug, !didOpenDebugMainWindow else { return }
                didOpenDebugMainWindow = true
                openMainWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: .koedexOpenSettings)) { _ in
                openMainWindow()
            }
    }

    private func openMainWindow() {
        openWindow(id: "main-window")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MainWindowContent: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if OnboardingRuntimeProfile.isOnboardingDebug {
            OnboardingDebugLauncherView(settingsStore: appDelegate.settingsStore)
        } else if OnboardingRuntimeProfile.isLanguageSetupDebug {
            LanguageSetupDebugLauncherView(settingsStore: appDelegate.settingsStore)
        } else {
            SettingsView(
                store: appDelegate.settingsStore,
                appDelegate: appDelegate,
                appState: appDelegate.appState,
                historyStore: appDelegate.inputHistoryStore,
                dictionaryStore: appDelegate.personalDictionaryStore,
                customInstructionStateStore: appDelegate.customInstructionStateStore,
                aiCommandCustomInstructionStateStore: appDelegate.aiCommandCustomInstructionStateStore
            )
        }
    }
}

private struct MainMenuBarContent: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.openWindow) private var openWindow

    private var uiLanguage: AppLanguage {
        settingsStore.settings.languagePreferences.uiLanguage
    }

    var body: some View {
        if OnboardingRuntimeProfile.isOnboardingDebug {
            Button(AppLocalizer.text("初回セットアップ Debugを開く", language: uiLanguage)) {
                openWindow(id: "main-window")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(AppLocalizer.text("Debug.appを終了", language: uiLanguage)) { NSApp.terminate(nil) }
        } else if OnboardingRuntimeProfile.isLanguageSetupDebug {
            Button(AppLocalizer.text("言語セットアップ Debugを開く", language: uiLanguage)) {
                openWindow(id: "main-window")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button(AppLocalizer.text("言語セットアップ Debug.appを終了", language: uiLanguage)) { NSApp.terminate(nil) }
        } else {
            MenuBarContentView(
                appDelegate: appDelegate,
                settingsStore: settingsStore,
                permissionManager: appDelegate.permissionManager
            )
        }
    }
}

private enum CLITestModelOverride {
    enum ParseResult {
        case success(CodexModelSettings?)
        case failure(String)
    }

    static func parse(from args: [String]) -> ParseResult {
        let model = value(after: "--test-model", in: args)
        let effort = value(after: "--test-effort", in: args)

        if model == nil && effort == nil {
            return .success(nil)
        }

        guard let model, let effort else {
            return .failure("--test-model と --test-effort は両方指定してください")
        }

        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEffort = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, !trimmedEffort.isEmpty else {
            return .failure("--test-model と --test-effort には空でない値を指定してください")
        }

        return .success(CodexModelSettings(
            mode: .explicit,
            selectedModelSlug: trimmedModel,
            selectedReasoningEffort: trimmedEffort
        ))
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}

@main
struct KoedexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        Self.runEarlyCLITestIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MainMenuBarContent(appDelegate: appDelegate, settingsStore: appDelegate.settingsStore)
        } label: {
            MenuBarStatusIcon(
                systemImageName: OnboardingRuntimeProfile.isDebug ? "ladybug.fill" : appDelegate.menuBarIconName
            )
                .background(SettingsWindowOpenBridge())
        }

        Window(mainWindowTitle, id: "main-window") {
            MainWindowContent(appDelegate: appDelegate)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(
            width: OnboardingRuntimeProfile.isDebug
                ? OnboardingUIScaleMetrics.defaultWindowSize.width
                : SettingsUIScaleMetrics.defaultWindowSize.width,
            height: OnboardingRuntimeProfile.isDebug
                ? OnboardingUIScaleMetrics.defaultWindowSize.height
                : SettingsUIScaleMetrics.defaultWindowSize.height
        )
    }

    private var mainWindowTitle: String {
        let language = appDelegate.settingsStore.settings.languagePreferences.uiLanguage
        if OnboardingRuntimeProfile.isOnboardingDebug {
            return AppLocalizer.text("Koedex Debug", language: language)
        }
        if OnboardingRuntimeProfile.isLanguageSetupDebug {
            return AppLocalizer.text("言語セットアップ Debug", language: language)
        }
        return AppLocalizer.text("Koedex 設定", language: language)
    }

    /// 自分自身のプロセスを除いて、同じバンドルIDのKoedexが既に起動中かを判定する。
    private static func isAnotherKoedexInstanceRunning() -> Bool {
        // `.build/debug/Koedex` を直接叩く場合、実行ファイルはバンドルに入っていないので
        // `Bundle.main.bundleIdentifier` は nil になる。ここで false を返すと、
        // サポートコマンドの二重所有ガードが**そのCLI起動でだけ黙って無効**になり、
        // 起動中のKoedex.appと同時にsettings.jsonを持ってしまう。READMEが案内するのは
        // まさにこのbare binaryなので、既定の本番バンドルIDで判定する。
        // Debugビルドは`isDebug`側で別途拒否されるため、ここで区別する必要はない。
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? OnboardingRuntimeProfile.productionBundleIdentifier
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID }
    }

    private static func runEarlyCLITestIfRequested() {
        let args = CommandLine.arguments
        switch ScopedClipboardFallbackSupportCommand.parse(arguments: args) {
        case .notRequested:
            break
        case .failure:
            FileHandle.standardError.write(Data("support command failed\n".utf8))
            exit(1)
        case .success(let action):
            guard !OnboardingRuntimeProfile.isDebug else {
                FileHandle.standardError.write(Data("support command failed\n".utf8))
                exit(1)
            }
            let result = ScopedClipboardFallbackSupportCommand.execute(
                action: action,
                isDebug: false,
                settingsStore: SettingsStore(storageRootURL: OnboardingRuntimeProfile.storageRootURL),
                isAnotherInstanceRunning: isAnotherKoedexInstanceRunning()
            )
            switch result {
            case .success(let output):
                print(output)
            case .notRequested:
                break
            case .failure:
                FileHandle.standardError.write(Data("support command failed\n".utf8))
            }
            exit(result.exitCode)
        }

        if args.contains("--test-regressions") {
            // `--max-skips N` は「想定内のSKIP件数」の上限。CIが渡すことで、新しくSKIPされ
            // 始めた検証だけが失敗になる。無指定ならSKIPは終了コードに影響しない。
            var maxSkips: Int?
            if let idx = args.firstIndex(of: "--max-skips") {
                // 値の欠落やtypoで黙ってゲートが無効になると、CIは緑のまま守られなくなる。
                // 門として使うフラグなので、解釈できなければ実行せずに落とす。
                guard idx + 1 < args.count, let parsed = Int(args[idx + 1]) else {
                    FileHandle.standardError.write(Data(
                        "--max-skips には整数が必要です\n".utf8
                    ))
                    exit(2)
                }
                maxSkips = parsed
            }
            exit(RegressionTestSuite.run(maxSkips: maxSkips))
        }

        if let idx = args.firstIndex(of: "--test-pidfile-guard"), idx + 1 < args.count,
           let pid = Int32(args[idx + 1]) {
            runEarlyPidfileGuardTest(pid: pid)
        }

        if args.contains("--test-app-server-args") {
            runEarlyAppServerArgsTest()
        }

        if let probeConfig = StreamingPartialProbe.parse(arguments: args) {
            runEarlyStreamingPartialProbe(config: probeConfig)
        }

        guard let idx = args.firstIndex(of: "--test-cleanup"), idx + 1 < args.count else { return }
        let text = args[idx + 1]
        let modelSettings: CodexModelSettings?
        switch CLITestModelOverride.parse(from: args) {
        case .success(let settings):
            modelSettings = settings
        case .failure(let message):
            print("エラー: \(message)")
            exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1

        Task.detached {
            print("=== Koedex --test-cleanup ===")
            print("入力: \(text)")
            if let modelSettings {
                print("テストモデル: \(modelSettings.selectedModelSlug) / \(modelSettings.selectedReasoningEffort)")
            }
            let engine = CleanupEngine(modelSettings: modelSettings ?? .default)
            let start = Date()
            do {
                let prewarmStart = Date()
                try await engine.prewarmThread()
                print(String(format: "prewarm所要時間: %.2f秒", Date().timeIntervalSince(prewarmStart)))
                let result = try await engine.cleanup(rawTranscript: text, customInstruction: "")
                let elapsed = Date().timeIntervalSince(start)
                print("整形結果: \(result)")
                print(String(format: "所要時間: %.2f秒", elapsed))
                await engine.shutdown()
                exitCode = 0
            } catch {
                print("エラー: \(AppLog.safeDescription(error))")
                await engine.shutdown()
                exitCode = 1
            }
            semaphore.signal()
        }

        semaphore.wait()
        exit(exitCode)
    }

    /// 暫定結果の到着時刻だけを測るモード。AppDelegateの起動処理より前に実行し、
    /// 設定・履歴・ログといった保存先へ触れずに終了する。
    /// `RunLoop.main.run()` で待つのは、プローブ内でMainActorへホップする箇所
    /// （HandsFreeSendSessionの再生）をデッドロックさせないため。
    private static func runEarlyStreamingPartialProbe(config: StreamingPartialProbe.Config) -> Never {
        Task.detached {
            let exitCode = await StreamingPartialProbe.run(config: config)
            exit(exitCode)
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func runEarlyAppServerArgsTest() {
        print("=== Koedex --test-app-server-args ===")
        let defaultArgs = CodexAppServerClient.appServerArguments(modelSettings: .default)
        print("default: \(defaultArgs)")

        let explicit = CodexModelSettings(
            mode: .explicit,
            selectedModelSlug: "gpt-5.4-mini",
            selectedReasoningEffort: "low"
        )
        let explicitArgs = CodexAppServerClient.appServerArguments(modelSettings: explicit)
        print("explicit: \(explicitArgs)")

        let defaultOK = !defaultArgs.contains { $0.contains("model=") || $0.contains("model_reasoning_effort=") }
        let explicitOK = explicitArgs.contains("model=\"gpt-5.4-mini\"")
            && explicitArgs.contains("model_reasoning_effort=\"low\"")
        print("default_has_no_model_overrides: \(defaultOK)")
        print("explicit_has_model_overrides: \(explicitOK)")
        exit(defaultOK && explicitOK ? 0 : 1)
    }

    private static func runEarlyPidfileGuardTest(pid: Int32) {
        print("=== Koedex --test-pidfile-guard \(pid) ===")
        print("注意: これはドライランです。実際のkillは行いません。")

        let psProc = Process()
        psProc.executableURL = URL(fileURLWithPath: "/bin/ps")
        psProc.arguments = ["-p", String(pid), "-o", "lstart="]
        let pipe = Pipe()
        psProc.standardOutput = pipe
        psProc.standardError = Pipe()

        var lstart = ""
        do {
            try psProc.run()
            psProc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lstart = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            let reason = "lstartを取得できませんでした: \(AppLog.safeDescription(error))"
            print("判定結果: kill=false, 理由=\(reason)")
            exit(0)
        }

        if lstart.isEmpty {
            print("判定結果: kill=false, 理由=pid=\(pid) のlstartを取得できませんでした（プロセスが存在しない可能性）")
            exit(0)
        }

        print("取得したlstart: \(lstart)")
        let decision = PidFileManager.shared.evaluateGuard(pid: pid, expectedLstart: lstart)
        print("判定結果: \(decision)")
        exit(0)
    }
}

struct MenuBarContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var permissionManager: PermissionManager
    @Environment(\.openWindow) private var openWindow
    @State private var microphones: [MicrophoneDevice] = []
    @State private var defaultMicrophoneName = ""
    @State private var languageProfileMessage: String?

    private var uiLanguage: AppLanguage {
        settingsStore.settings.languagePreferences.uiLanguage
    }

    var body: some View {
        Group {
        Text(appDelegate.appState.statusText(language: uiLanguage))
        if case .failed(let reason) = appDelegate.codexStatus {
            Label(
                AppLocalizer.format(
                    "Codex接続エラー: %@",
                    language: uiLanguage,
                    AppLocalizer.textOrLiteral(reason, language: uiLanguage)
                ),
                systemImage: "exclamationmark.triangle"
            )
            Button(AppLocalizer.text("Codexへ再接続", language: uiLanguage)) {
                appDelegate.retryCodexConnection()
            }
        }
        if settingsStore.saveBlockedStatus != nil {
            Label(
                AppLocalizer.text("設定を保存できません。詳しくは設定画面を確認してください。", language: uiLanguage),
                systemImage: "exclamationmark.triangle"
            )
        }
        Divider()
        Menu(AppLocalizer.text("マイクを選択", language: uiLanguage)) {
            Button {
                settingsStore.settings.preferredMicrophoneUID = ""
            } label: {
                microphoneMenuLabel(
                    title: AppLocalizer.format("自動 (%@)", language: uiLanguage, defaultMicrophoneName),
                    isSelected: settingsStore.settings.preferredMicrophoneUID.isEmpty
                )
            }
            Divider()
            ForEach(microphones) { microphone in
                Button {
                    settingsStore.settings.preferredMicrophoneUID = microphone.uid
                } label: {
                    microphoneMenuLabel(
                        title: microphone.name,
                        isSelected: settingsStore.settings.preferredMicrophoneUID == microphone.uid
                    )
                }
            }
        }
        Divider()
        Menu(AppLocalizer.text("言語 / Language", language: uiLanguage)) {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    Task {
                        languageProfileMessage = nil
                        let result = await appDelegate.applyLanguageProfile(language)
                        if case .failure(let failure) = result {
                            languageProfileMessage = failure.message
                        }
                    }
                } label: {
                    microphoneMenuLabel(
                        title: language.localizedDisplayName(for: uiLanguage),
                        isSelected: settingsStore.settings.languagePreferences.uiLanguage == language
                            && settingsStore.settings.languagePreferences.sttLanguage == language
                            && settingsStore.settings.languagePreferences.aiOutputLanguage == .automatic
                    )
                }
            }
            if appDelegate.isApplyingLanguageProfile {
                Divider()
                Text(AppLocalizer.text("言語を準備しています…", language: uiLanguage))
            }
        }
        .disabled(appDelegate.isApplyingLanguageProfile)
        if let languageProfileMessage {
            Text(languageProfileMessage)
                .foregroundStyle(.red)
        }
        Divider()
        Toggle(AppLocalizer.text("AIアシスト", language: uiLanguage), isOn: Binding(
            get: { settingsStore.settings.cleanupEnabled },
            set: { settingsStore.settings.cleanupEnabled = $0 }
        ))
        if appDelegate.lastAICommandOutput != nil {
            Button(AppLocalizer.text("最後のAI出力をコピー", language: uiLanguage)) {
                appDelegate.copyLastAICommandOutput()
            }
        }
        Divider()
        if OnboardingResumePolicy.shouldOfferResume(
            allPermissionsGranted: permissionManager.allGranted(),
            setupIsComplete: settingsStore.settings.setupProgress.isComplete
        ) {
            Button(AppLocalizer.text("セットアップを再開…", language: uiLanguage)) {
                appDelegate.resumeOnboarding()
            }
        }
        Button(AppLocalizer.text("セットアップガイド...", language: uiLanguage)) {
            appDelegate.showOnboardingGuide()
        }
        Button(AppLocalizer.text("設定...", language: uiLanguage)) {
            openWindow(id: "main-window")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(AppLocalizer.text("終了", language: uiLanguage)) {
            NSApp.terminate(nil)
        }
        }
        .onAppear {
            refreshMicrophones()
        }
        .onChange(of: uiLanguage) {
            refreshMicrophones()
        }
        .environment(\.locale, uiLanguage.locale)
    }

    private func refreshMicrophones() {
        microphones = MicrophoneDeviceManager.inputDevices()
        defaultMicrophoneName = MicrophoneDeviceManager.defaultInputDevice()?.name
            ?? AppLocalizer.text("現在のデバイス", language: uiLanguage)
    }

    @ViewBuilder
    private func microphoneMenuLabel(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

/// 「AI処理をリセット」を押してよい条件。純関数にして回帰テストで固定する。
///
/// 録音中・処理中に走らせると、進行中のturnやthreadを足元から崩す。再接続中の二重実行も
/// 防ぐ。エラー表示中は復帰手段として押せる必要があるので許可する。
/// 「AI処理をリセット」の表示状態。**解決済み文字列ではなく状態を保持する。**
/// 以前は `uiText(...)` の結果を直接持っていたため、表示中にUI言語を切り替えても
/// 元の言語のまま残り続けた（2026-07-30の実機報告）。描画のたびにローカライズを
/// 通せるよう、ここでは言語に依存しない値だけを持つ。
///
/// `failed` が持つのは **ローカライズ前のメッセージ**。描画時に
/// `AppLocalizer.textOrLiteral(_:language:)` を通すことで、カタログにある文言は
/// 切替に追従し、無いものはそのまま表示される。
enum AIProcessingResetStatus: Equatable {
    case resetting
    case succeeded
    case failed(rawMessage: String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum AIProcessingResetPolicy {
    static func allowsReset(
        phase: PipelinePhase,
        codexStatus: AppDelegate.CodexConnectionStatus
    ) -> Bool {
        guard codexStatus != .checking else { return false }
        switch phase {
        case .idle, .error:
            return true
        case .starting, .recording, .transcribing, .cleaning, .inserting:
            return false
        }
    }
}

enum AICommandCaptureGuidanceSemanticAction: String, Equatable {
    case questionWithoutSelection
    case clipboardRecovery
}

/// 選択取得失敗後に提示してよい操作を、UIやclosureから分離して決める。
enum AICommandCaptureGuidanceActionPolicy {
    static func actions(
        for failure: SelectionCaptureFailure,
        clipboardVariantEnabled: Bool,
        hasSourceProcessIdentifier: Bool,
        allowsClipboardRecovery: Bool
    ) -> [AICommandCaptureGuidanceSemanticAction] {
        var actions: [AICommandCaptureGuidanceSemanticAction] = []

        switch failure {
        case .selectionUnsupported, .copyDidNotProduceText, .focusedElementUnavailable:
            actions.append(.questionWithoutSelection)
        case .externalCompatibilityDisabled, .accessibilityPermissionMissing, .secureInput,
             .clipboardChanged, .clipboardRestoreFailed:
            break
        }

        guard clipboardVariantEnabled,
              hasSourceProcessIdentifier,
              allowsClipboardRecovery else {
            return actions
        }
        switch failure {
        case .externalCompatibilityDisabled, .selectionUnsupported, .copyDidNotProduceText,
             .focusedElementUnavailable:
            actions.append(.clipboardRecovery)
        case .accessibilityPermissionMissing, .secureInput, .clipboardChanged, .clipboardRestoreFailed:
            break
        }
        return actions
    }
}

/// Debug用オンボーディングはHUDを作らないため、AppKitのactive通知でHUDへ触れない。
/// 通常版でのHUD未初期化も安全に無視するため、判定を純粋な規則として固定する。
enum RecordingHUDLifecyclePolicy {
    static func shouldReassert(isDebug: Bool, hasHUD: Bool) -> Bool {
        !isDebug && hasHUD
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    struct ModelReconnectFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    enum CodexConnectionStatus: Equatable {
        case unknown
        case checking
        case connected
        case failed(String)
    }

    let appState = AppState()
    // CLI回帰テストはAppDelegate生成直後に終了するため、通常の設定ファイルへ
    // 触れないよう設定ストアは実際に必要になった時だけ初期化する。
    lazy var settingsStore = SettingsStore(storageRootURL: OnboardingRuntimeProfile.storageRootURL)
    lazy var inputHistoryStore = InputHistoryStore(storageRootURL: OnboardingRuntimeProfile.storageRootURL)
    lazy var personalDictionaryStore = PersonalDictionaryStore(storageRootURL: OnboardingRuntimeProfile.storageRootURL)
    lazy var customInstructionStateStore = CustomInstructionStateStore(
        storageRootURL: OnboardingRuntimeProfile.storageRootURL
    )
    lazy var aiCommandCustomInstructionStateStore = CustomInstructionStateStore(
        fileName: "ai_command_custom_instruction_state.json",
        legacyFileName: nil,
        storageRootURL: OnboardingRuntimeProfile.storageRootURL
    )
    let transcriptionEngine = TranscriptionEngine()
    lazy var speechLanguagePreparationCoordinator = SpeechLanguagePreparationCoordinator(
        engine: transcriptionEngine
    )
    lazy var cleanupEngine = CleanupEngine(
        executablePath: nonEmptyCodexPath(settingsStore.settings.codexExecutablePath),
        modelSettings: settingsStore.settings.modelSettings
    )
    lazy var aiCommandEngine = AICommandEngine(
        executablePath: nonEmptyCodexPath(settingsStore.settings.codexExecutablePath)
    )
    let audioRecorder = AudioRecorder()
    let textInjector = TextInjector()
    let selectedTextCapture = SelectedTextCapture()
    let clipboardSourceReader = ClipboardSourceReader()
    lazy var aiCommandResultWindows = AICommandResultWindowController(
        metricsProvider: { [weak self] in
            PopupUIScaleMetrics(settingsScale: self?.settingsStore.settings.settingsDisplayScale ?? SettingsUIScaleMetrics.standardScale)
        },
        languageProvider: { [weak self] in
            self?.settingsStore.settings.languagePreferences.uiLanguage ?? .japanese
        }
    )
    lazy var permissionManager = PermissionManager()
    private var hotkeyManager: HotkeyManager!
    private var hud: RecordingHUDController!
    private var onboardingController: OnboardingWindowController!
    private lazy var onboardingRestartIntentStore = OnboardingRestartIntentStore()
    private var onboardingRestartPresentationTask: Task<Void, Never>?
    private var settingsCancellable: AnyObjectHolder?
    private var autoStopTask: Task<Void, Never>?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStartTaskSessionID: UUID?
    private var recordingStartTimeoutTask: Task<Void, Never>?
    private var recordingStartTimeoutSessionID: UUID?
    private var processingTask: Task<Void, Never>?
    private var processingTaskSessionID: UUID?
    private var aiCommandFailureDismissTask: Task<Void, Never>?
    private var aiCommandFailureOwnership = AICommandFailureOwnership()
    private var aiCommandDidObserveWebSearch = false
    /// 曖昧な選択／clipboard質問にだけ表示する、メモリ内・単回のWeb再試行権限。
    private var pendingAICommandWebRetryToken: AICommandWebRetryToken?
    private var pendingAICommandWebRetryExpiryTask: Task<Void, Never>?
    private var pendingAICommandWebRetryWindowID: UUID?
    private var confirmedAICommandWebRetryTask: Task<Void, Never>?
    private var confirmedAICommandWebRetryID: UUID?
    private var completedNormalInputCount = 0
    private var aiCommandCaptureTask: Task<Void, Never>?
    private var aiCommandCaptureID: UUID?
    private var aiCommandCaptureTimeoutTask: Task<Void, Never>?
    private var menuBarWarningTask: Task<Void, Never>?
    private var activeVoiceSession: VoiceSession? {
        didSet {
            // HotkeyManagerはFn停止を活動中のハンズフリーsessionだけへ振り分ける。
            // sessionの作成・破棄と同じ代入点で同期し、古い活動状態を残さない。
            hotkeyManager?.handsFreeSendIsActive = activeVoiceSession?.handsFreeSendSession != nil
            // 録音中に設定画面でキーを変更しても、開始時snapshotのChordで停止できるようにする。
            if hotkeyManager != nil {
                applyHandsFreeSendHotkeySettings(settingsStore.settings)
            }
        }
    }
    private var pendingNormalHold = false
    /// tapが落ちた時点で活動中のsessionが無かった場合に、次に生成されるハンズフリー
    /// sessionへ送信権限の剥奪を引き継ぐ一度限りのフラグ。
    private var pendingHandsFreeSendRevocation = false
    private var handsFreeSendTriggerTask: Task<Void, Never>?
    private var handsFreeSendTriggerTaskID: UUID?
    private var didWarmUp = false
    private var warmUpTask: Task<Void, Error>?
    private var consecutiveUnclassifiedRPCFailures = 0
    private static let unclassifiedRPCFailureWarningThreshold = 3

    @Published var menuBarIconName = "mic"
    @Published var codexStatus: CodexConnectionStatus = .unknown
    @Published private(set) var isApplyingLanguageProfile = false
    /// クリップボードバリアントの貼り付けを送出した直近のAI出力。メモリ上のみで、
    /// ディスクへは書かない。履歴（`InputHistoryStore`）へも渡さない。次のAI実行で
    /// 上書きされ、アプリ終了で消える。
    @Published private(set) var lastAICommandOutput: String?

    /// メニューバーの「最後のAI出力をコピー」からだけ呼ぶ、利用者の明示操作。
    ///
    /// ここではowner markerを付けない。利用者が自分で⌘Cしたのと同じ意味の操作であり、
    /// マーカーを付けると「出力をコピーして、続けてもう一度AIに指示する」という
    /// 正当な流れが`ClipboardSourceReadPolicy`の自己再帰ガードで塞がれてしまう。
    func copyLastAICommandOutput() {
        guard let lastAICommandOutput else { return }
        NSPasteboard.general.clearContents()
        // clearContentsは既に走っている。書込みに失敗すると利用者のクリップボードは
        // 空のままになるので、黙って捨てずに記録する。
        if !NSPasteboard.general.setString(lastAICommandOutput, forType: .string) {
            AppLog.shared.warn("最後のAI出力をクリップボードへ書き込めませんでした")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // GUI起動時、死んだ子プロセス（app-server起動失敗時等）のstdinへ書き込むと
        // SIGPIPEでプロセスごと即死するため、プロセス全体でSIGPIPEを無視する。
        // これによりFileHandle.writeはシグナルではなくEPIPEエラーをthrowする経路になり、
        // 既存のdo/catchで捕捉できるようになる。CLIテストモード判定より前に行う必要がある。
        signal(SIGPIPE, SIG_IGN)

        // Debug.appはここで通常アプリの副作用をすべて止める。これより後にはログ、履歴の
        // prune、PID掃除、hotkey、音声warm-up、Codex接続があるため、順序を変えないこと。
        if OnboardingRuntimeProfile.isDebug {
            NSApp.setActivationPolicy(.regular)
            return
        }

        // 通常版はDockと⌘Tabに表示し、最後の設定Windowを閉じても常駐する。
        NSApp.setActivationPolicy(.regular)

        AppLog.shared.info("=== Koedex起動 ===")
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let revision = bundle.object(forInfoDictionaryKey: "KoedexBuildGitSHA") as? String ?? "unknown"
        AppLog.shared.info("[Telemetry] launch version=\(version) build=\(build) revision=\(revision)")
        // 設定が読めなかった場合、settingsはメモリ上の既定値になっている。その既定の
        // 保持期間でpruneすると、ユーザーが選んでいない基準で履歴が削除される。
        // 保存が無効化されている間は、履歴も消さない。
        if settingsStore.canSave {
            inputHistoryStore.prune(retentionDays: settingsStore.settings.historyRetentionDays)
            inputHistoryStore.prune(
                mode: InputHistoryMode.aiCommand,
                retentionDays: settingsStore.settings.aiCommandSettings.historyRetentionDays
            )
            inputHistoryStore.prune(
                mode: InputHistoryMode.handsFreeSend,
                retentionDays: settingsStore.settings.handsFreeSendSettings.historyRetentionDays
            )
        } else {
            AppLog.shared.warn("設定を読めなかったため、履歴の保持期間による削除は行いません")
        }

        // 過去起動時の孤児app-serverプロセスが残っていれば後始末する。
        PidFileManager.shared.cleanupOrphanFromPreviousRun()

        // 起動のたびに一度、既存の保存済みディレクトリ・ファイルの権限を0700/0600へ是正する（べき等）。
        // 履歴やAICommandRuntimeの件数に上限がないため、全走査で起動を待たせない。
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storageRoot = OnboardingRuntimeProfile.storageRootURL
            ?? appSupportRoot.appendingPathComponent("Koedex", isDirectory: true)
        Task.detached(priority: .utility) {
            StoragePermissions.remediateStorageRoot(storageRoot)
        }

        // CLIテストモードの処理（--test-cleanup / --test-stt）。該当すれば実行して終了する。
        if handleCLITestModeIfRequested() {
            return
        }

        hud = RecordingHUDController(
            appState: appState,
            metricsProvider: { [weak self] in
                PopupUIScaleMetrics(settingsScale: self?.settingsStore.settings.settingsDisplayScale ?? SettingsUIScaleMetrics.standardScale)
            },
            languageProvider: { [weak self] in
                self?.settingsStore.settings.languagePreferences.uiLanguage ?? .japanese
            },
            onCancelRecording: { [weak self] in
                self?.cancelRecordingFromHUD()
            },
            onFinishRecording: { [weak self] in
                self?.finishRecordingFromHUD()
            }
        )
        onboardingController = OnboardingWindowController(
            permissionManager: permissionManager,
            settingsStore: settingsStore,
            practiceTranscriptionEngine: transcriptionEngine
        )

        setupHotkeyManager()
        observeSettingsChanges()

        permissionManager.refresh()
        logPermissionState()

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        if let restartIntent = onboardingRestartIntentStore.load(bundleIdentifier: bundleIdentifier) {
            if restartIntent.presentationMode.isDebug {
                onboardingRestartIntentStore.clear()
            } else {
                presentRestartIntentAfterSourceProcessExit(restartIntent)
                return
            }
        }

        if permissionManager.allGranted(), settingsStore.settings.setupProgress.isComplete {
            beginWarmUpAndStart()
            openSettingsWindow()
        } else {
            AppLog.shared.info("必要な権限または初回設定が未完了のため、セットアップを表示します")
            onboardingController.showIfNeeded { [weak self] mode in
                self?.finishOnboarding(mode: mode)
            }
        }
    }

    /// セットアップ完了時は、保存済み状態と権限をもう一度確認してから通常機能を開始する。
    /// 初回インストールだけは、開始後に設定画面を開いて以後の変更場所を示す。
    private func finishOnboarding(mode: OnboardingPresentationMode) {
        permissionManager.refresh()
        guard permissionManager.allGranted(), settingsStore.settings.setupProgress.isComplete else {
            AppLog.shared.warn("オンボーディング完了時の状態確認に失敗したため、必要な確認画面を再表示します")
            onboardingController.showIfNeeded { [weak self] retryMode in
                self?.finishOnboarding(mode: retryMode)
            }
            return
        }

        AppLog.shared.info("オンボーディング完了。warmUpを開始します")
        beginWarmUpAndStart()

        guard mode.opensSettingsAfterFinish else { return }
        openSettingsWindow()
    }

    /// 通常版の設定Windowは既存のSwiftUI Window sceneに一元化する。
    /// `Window(id:)` は同じWindowを前面化し、存在しなければ1枚だけ要求する。
    private func openSettingsWindow() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .koedexOpenSettings, object: nil)
        }
    }

    /// DockクリックやFinderからの再オープン時は、未完了セットアップを常に優先する。
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        guard !OnboardingRuntimeProfile.isDebug else { return false }
        permissionManager.refresh()
        switch DockLifecyclePolicy.reopenDestination(
            isDebug: false,
            allPermissionsGranted: permissionManager.allGranted(),
            setupIsComplete: settingsStore.settings.setupProgress.isComplete
        ) {
        case .unchanged:
            return false
        case .onboarding:
            onboardingController?.showIfNeeded { [weak self] mode in
                self?.finishOnboarding(mode: mode)
            }
        case .settings:
            openSettingsWindow()
        }
        return true
    }

    /// 通常版は設定Windowを閉じても、メニューバーとDockを維持する。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DockLifecyclePolicy.keepsRunningAfterLastWindowClosed(
            isDebug: OnboardingRuntimeProfile.isDebug
        )
    }

    /// 権限反映用の後継プロセスは、旧プロセスの終了前にセットアップやマイク利用を
    /// 始めない。旧側は自分の安全な終了処理を実行し、新側はそれを待つだけにする。
    private func presentRestartIntentAfterSourceProcessExit(_ intent: OnboardingRestartIntent) {
        onboardingRestartPresentationTask?.cancel()
        onboardingRestartPresentationTask = Task { [weak self] in
            await OnboardingRestartHandoff.waitForSourceProcessExit(intent)
            guard !Task.isCancelled, let self else { return }
            self.onboardingController.showRestartIntent(
                intent,
                onPresented: { [weak self] in
                    self?.onboardingRestartIntentStore.clear()
                },
                onFinish: { [weak self] mode in
                    self?.finishOnboarding(mode: mode)
                }
            )
            self.onboardingRestartPresentationTask = nil
        }
    }

    /// 設定値の空文字はnil（自動探索）として扱うためのヘルパー。
    private func nonEmptyCodexPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var uiLanguage: AppLanguage {
        settingsStore.settings.languagePreferences.uiLanguage
    }

    private func uiText(_ japanese: String) -> String {
        AppLocalizer.text(japanese, language: uiLanguage)
    }

    private func uiFormat(_ japanese: String, _ arguments: CVarArg...) -> String {
        String(format: uiText(japanese), locale: uiLanguage.locale, arguments: arguments)
    }

    private func logPermissionState() {
        let mic = permissionManager.microphoneState
        let speech = permissionManager.speechRecognitionState
        let accessibility = permissionManager.accessibilityState
        AppLog.shared.info("権限状態: mic=\(mic), speech=\(speech), accessibility=\(accessibility)")
    }

    /// warmUpとhotkeyManager起動を行う。権限が揃った後にのみ呼ばれる。
    /// warmUp失敗はキャッチしてHUD表示＋ログ記録のみに留め、プロセスは継続する。
    private func beginWarmUpAndStart() {
        guard !didWarmUp else { return }
        didWarmUp = true

        hotkeyManager.start()
        _ = startWarmUpTaskIfNeeded()

        // Codex接続チェックはwarmUpの成否と独立に実行する
        // （旧実装はwarmUp失敗時にprepareがスキップされ、整形が無通知で死ぬ一因だった）。
        Task { await resolveInitialModelDefaultsAndConnect() }
    }

    /// codex app-serverへの接続を先行試行し、結果をメニューバーへ反映する。
    private func verifyCodexConnection() async {
        codexStatus = .checking
        do {
            try await cleanupEngine.prewarmThread(
                promptLanguage: settingsStore.settings.languagePreferences.sttLanguage
            )
            consecutiveUnclassifiedRPCFailures = 0
            codexStatus = .connected
            AppLog.shared.info("Codex接続チェック成功（thread prewarm完了）")
        } catch CodexClientError.codexNotFound {
            codexStatus = .failed("codex CLIが見つかりません")
            AppLog.shared.error("codex CLIが見つかりません。設定でパスを指定してください")
            menuBarIconName = "exclamationmark.triangle.fill"
            appState.setPhase(.error(uiText("codex CLIが見つかりません。設定でパスを指定してください")))
            hud.flashError(durationSeconds: 5)
        } catch {
            codexStatus = .failed(Self.describeCodexError(error))
            AppLog.shared.warn("Codex接続チェック失敗（初回利用時に再試行されます）: \(Self.describeCodexError(error))")
        }
    }

    func retryCodexConnection() {
        Task {
            _ = await reconnectCleanupModel()
        }
    }

    /// 完了済みユーザーが必要な時だけ、短いセットアップガイドを開く。
    func showOnboardingGuide() {
        guard !OnboardingRuntimeProfile.isDebug else { return }
        onboardingController?.showGuide()
    }

    /// 左上×で閉じた未完了セットアップを、アプリを終了せず安全に再開する。
    func resumeOnboarding() {
        guard !OnboardingRuntimeProfile.isDebug else { return }
        permissionManager.refresh()
        onboardingController?.showIfNeeded { [weak self] mode in
            self?.finishOnboarding(mode: mode)
        }
    }

    /// 通常モードの保存後に、現在のCLIパスとモデル設定でapp-serverを作り直して先行接続する。
    /// 設定画面はこの完了結果を待って、再接続メッセージを確実に消せる。
    func reconnectCleanupModel() async -> Result<Void, ModelReconnectFailure> {
        let settings = settingsStore.settings
        if let failure = await validateCleanupModelSettings(
            settings.modelSettings,
            executablePath: nonEmptyCodexPath(settings.codexExecutablePath)
        ) {
            codexStatus = .failed(failure.message)
            return .failure(failure)
        }
        await cleanupEngine.updateExecutablePath(nonEmptyCodexPath(settings.codexExecutablePath))
        await cleanupEngine.updateModelSettings(settings.modelSettings)
        // app-serverは起動引数を途中で変更できないため、停止してからthreadまでprewarmする。
        await cleanupEngine.shutdown()
        await verifyCodexConnection()

        switch codexStatus {
        case .connected:
            return .success(())
        case .failed(let reason):
            return .failure(ModelReconnectFailure(message: reason))
        case .unknown, .checking:
            return .failure(ModelReconnectFailure(message: uiText("Codexへの再接続状態を確認できませんでした")))
        }
    }

    /// 新規インストールだけ、最初に取得できたライブモデル一覧でLunaの初期値を決める。
    /// 既存設定はSettingsStore側でresolved扱いとなるため、ここでは一切変更しない。
    private func resolveInitialModelDefaultsAndConnect() async {
        if !settingsStore.settings.initialModelDefaultsResolved {
            do {
                let models = try await CodexModelCatalogService().fetchModels(
                    settingsExecutablePath: nonEmptyCodexPath(settingsStore.settings.codexExecutablePath)
                )
                let resolution = settingsStore.resolveInitialModelDefaults(usingLiveModels: models)
                AppLog.shared.info("初期モデル設定を解決: \(String(describing: resolution))")
            } catch {
                // ライブ一覧を確認できない間は未解決のままにし、次回の一覧更新時に再試行する。
                AppLog.shared.warn("初期モデル設定の確認を延期: \(Self.describeCodexError(error))")
            }
        }
        _ = await reconnectCleanupModel()
        await prewarmAICommandClient()
    }

    /// ユーザーが「AI処理をリセット」を押した時の処理。
    ///
    /// 長時間使うと整形が遅くなるのは蓄積したthreadが原因なので、それを捨てて作り直す。
    /// **設定・ユーザー辞書・入力履歴には一切触らない。** 押した効果が測れるように、
    /// `CleanupEngine.discardThread()` 側でリセット時点のturn数とthread経過秒を記録する。
    func resetAIProcessingState() async -> Result<Void, ModelReconnectFailure> {
        guard AIProcessingResetPolicy.allowsReset(
            phase: appState.phase,
            codexStatus: codexStatus
        ) else {
            return .failure(ModelReconnectFailure(
                message: uiText("処理が終わってからもう一度お試しください。")
            ))
        }
        await cleanupEngine.discardThread()
        // 次の口述が待たされないよう、作り直しまで済ませる（実測0.14〜0.22秒）。
        await verifyCodexConnection()
        let aiCommandSettings = settingsStore.settings.aiCommandSettings
        // 「AIに指示」を使っていないユーザーのために、無効時は触らない。
        // 有効でも、失敗を全体の失敗として返さないこと。整形threadの作り直し
        // （このボタンの主目的）は既に成功しているので、失敗扱いにすると
        // ユーザーが効かなかったと判断して押し直してしまう。
        if aiCommandSettings.enabled {
            if case .failure(let failure) = await reconnectAICommandModel(
                modelSettings: aiCommandSettings.modelSettings,
                webSearchEnabled: aiCommandSettings.webSearchEnabled
            ) {
                AppLog.shared.warn("AI整形のリセットは成功しましたが、AIに指示の再接続に失敗: \(failure.message)")
            }
        }
        switch codexStatus {
        case .connected:
            AppLog.shared.info("AI処理をリセットしました")
            return .success(())
        case .failed(let reason):
            return .failure(ModelReconnectFailure(message: reason))
        case .unknown, .checking:
            return .failure(ModelReconnectFailure(message: uiText("Codexへの再接続状態を確認できませんでした")))
        }
    }

    /// 「AIに指示」のapp-serverプロセスを起動時に立ち上げておく。
    ///
    /// `CleanupEngine`は`verifyCodexConnection`から事前準備されていたが、`AICommandEngine`は
    /// 設定保存時にしか`reconnect`されず、初回実行でクライアント生成とモデル一覧取得を
    /// まとめて払っていた。実測で初回12.9秒、2回目以降3〜6秒（2026-07-30のログ）。
    ///
    /// threadは依頼本文を含むため毎回新規にする設計を維持する。ここで先行させるのは
    /// プロセスの起動だけである。
    private func prewarmAICommandClient() async {
        let settings = settingsStore.settings.aiCommandSettings
        // 機能をオフにしているユーザーのapp-serverプロセスを増やさない。
        guard settings.enabled else { return }
        await aiCommandEngine.updateExecutablePath(
            nonEmptyCodexPath(settingsStore.settings.codexExecutablePath)
        )
        do {
            // `forceRefresh: false`は「必要以上に取りに行かない」という意思表示にすぎない。
            // 起動直後は`AICommandEngine`側のモデル一覧キャッシュが空なので、実際には
            // ここで1回取得される（`updateExecutablePath`がキャッシュを破棄するため）。
            // 節約が起きると誤解しないこと。
            try await aiCommandEngine.reconnect(
                modelSettings: settings.modelSettings,
                webSearchEnabled: settings.webSearchEnabled,
                forceRefresh: false
            )
            AppLog.shared.info("AIに指示の事前準備完了")
        } catch {
            // 起動をブロックしない。初回実行時に通常の経路で再試行される。
            AppLog.shared.warn("AIに指示の事前準備を延期: \(Self.describeCodexError(error))")
        }
    }

    /// 通常モードの明示モデルは、実行中CLIが返すライブカタログで確認する。
    /// CLI追従モードはCLI自身の設定を使うため、Koedex側で置き換えない。
    private func validateCleanupModelSettings(
        _ modelSettings: CodexModelSettings,
        executablePath: String?
    ) async -> ModelReconnectFailure? {
        guard modelSettings.mode != .cli else { return nil }
        do {
            let models = try await CodexModelCatalogService().fetchModels(
                settingsExecutablePath: executablePath
            )
            guard let model = CodexModelCatalog.model(
                slug: modelSettings.selectedModelSlug,
                in: models
            ), CodexModelCatalog.isUserSelectable(
                effort: modelSettings.selectedReasoningEffort,
                for: model
            ) else {
                return ModelReconnectFailure(
                    message: uiText("選択したモデルまたは推論レベルは現在利用できません。モデル一覧を更新して選び直してください。")
                )
            }
            return nil
        } catch {
            return ModelReconnectFailure(
                message: uiText("モデル一覧を確認できませんでした。Codex CLIの接続とバージョンを確認してください。")
            )
        }
    }

    /// 「AIに指示」専用の保存後再接続。通常モードの接続状態は変更しない。
    /// モデル/推論レベル/Web検索可否をライブカタログで検証し、Webあり／なしの両クライアントを
    /// 必要な範囲で先行起動してから成功を返す。
    func reconnectAICommandModel(
        modelSettings: CodexModelSettings,
        webSearchEnabled: Bool
    ) async -> Result<Void, ModelReconnectFailure> {
        invalidateAICommandWebRetry(.pendingAndRunning)
        await aiCommandEngine.updateExecutablePath(
            nonEmptyCodexPath(settingsStore.settings.codexExecutablePath)
        )
        do {
            try await aiCommandEngine.reconnect(
                modelSettings: modelSettings,
                webSearchEnabled: webSearchEnabled
            )
            return .success(())
        } catch {
            let message = Self.describeCodexError(error)
            AppLog.shared.warn("AIに指示のCodex再接続に失敗: \(Self.describeCodexError(error))")
            return .failure(ModelReconnectFailure(message: message))
        }
    }

    private func startWarmUpTaskIfNeeded() -> Task<Void, Error> {
        if let warmUpTask {
            return warmUpTask
        }

        let task = Task { @MainActor in
            AppLog.shared.info("warmUp開始")
            let language = settingsStore.settings.languagePreferences.sttLanguage
            switch await speechLanguagePreparationCoordinator.prepare(
                to: language,
                isVoiceProcessing: false
            ) {
            case .success:
                AppLog.shared.info("warmUp完了")
            case .failure(.superseded):
                // 利用者が別言語を選んだ。新しい世代が準備を担当するため、起動失敗として表示しない。
                // ただし、このTaskを残すと新しい世代が失敗した後に再試行できない。
                self.warmUpTask = nil
                return
            case .failure:
            AppLog.shared.error("音声認識エンジンの初期化に失敗しました")
            appState.setPhase(.error(uiText("音声認識エンジンを初期化できませんでした。権限と音声モデルを確認して、もう一度試してください。")))
            self.warmUpTask = nil
            throw TranscriptionError.notWarmedUp
            }
        }
        warmUpTask = task
        return task
    }

    /// 設定画面からのSTT言語切替。録音・文字起こし中には切替を拒否し、
    /// asset取得やwarm-upが成功した時だけ呼び出し側が保存値を更新する。
    func prepareSpeechLanguageChange(to language: AppLanguage) async -> Result<Void, ModelReconnectFailure> {
        guard appState.phase == .idle else {
            return .failure(ModelReconnectFailure(
                message: uiText("録音または処理が完了してから音声認識言語を変更してください。")
            ))
        }
        switch await speechLanguagePreparationCoordinator.prepare(
            to: language,
            isVoiceProcessing: false
        ) {
        case .success:
            return .success(())
        case .failure(let failure):
            // Speech frameworkの内部詳細をUIや保存値に流さない。timeout・取消でも旧engineと
            // 旧設定を維持し、呼び出し側のPickerを必ず再有効化する。
            AppLog.shared.warn("音声認識言語の切替に失敗しました: \(String(describing: failure))")
            let message: String
            switch failure {
            case .timedOut:
                message = uiText("音声モデルの準備が時間内に完了しませんでした。現在の言語のままにして、しばらくしてからもう一度試してください。")
            case .busy:
                message = uiText("録音または処理が完了してから音声認識言語を変更してください。")
            case .superseded, .failed:
                message = uiText("音声認識言語を変更できませんでした。権限と音声モデルを確認して、もう一度試してください。")
            }
            return .failure(ModelReconnectFailure(
                message: message
            ))
        }
    }

    /// メニューバーの言語プロファイル。STTの準備に成功した時だけUI/STT/AI出力を一括で保存する。
    /// 失敗・timeout時は、3つの保存済み値を一切変更しない。
    func applyLanguageProfile(_ language: AppLanguage) async -> Result<Void, ModelReconnectFailure> {
        guard appState.phase == .idle else {
            return .failure(ModelReconnectFailure(
                message: uiText("録音または処理が完了してから音声認識言語を変更してください。")
            ))
        }
        guard !isApplyingLanguageProfile else {
            return .failure(ModelReconnectFailure(
                message: uiText("音声モデルを準備しています。完了してからもう一度試してください。")
            ))
        }
        isApplyingLanguageProfile = true
        defer { isApplyingLanguageProfile = false }

        let result = await prepareSpeechLanguageChange(to: language)
        guard case .success = result else { return result }
        settingsStore.settings.languagePreferences.uiLanguage = language
        settingsStore.settings.languagePreferences.sttLanguage = language
        settingsStore.settings.languagePreferences.aiOutputLanguage = .automatic
        settingsStore.flushPendingSave()
        return .success(())
    }

    private func waitForWarmUpBeforeRecording() async throws {
        if transcriptionEngine.isWarmedUp {
            return
        }
        let task = startWarmUpTaskIfNeeded()
        try await task.value
    }

    private func setupHotkeyManager() {
        let settings = settingsStore.settings
        hotkeyManager = HotkeyManager(
            targetKeyCode: settings.hotkeyKeyCode,
            isModifierKey: settings.hotkeyIsModifier,
            recordingMode: RecordingMode(rawValue: settings.recordingMode) ?? .toggle
        )
        hotkeyManager.modifierMaskFromSettings = settings.hotkeyModifierMask
        applyAICommandHotkeySettings(settings)
        applyHandsFreeSendHotkeySettings(settings)
        wireHotkeyCallbacks()
    }

    private func applyAICommandHotkeySettings(_ settings: KoedexSettings) {
        let ai = settings.aiCommandSettings
        hotkeyManager.aiCommandEnabled = ai.enabled && settings.setupProgress.isComplete
        hotkeyManager.aiCommandStartBinding = ai.startHotkey
        hotkeyManager.aiCommandStopBinding = ai.stopHotkey
        // 保存時のゲートだけでは足りない。設定JSONの手編集や、追加キーを保存した後で
        // ハンズフリー送信を有効化した場合に、成立しないChordが生きたまま残る。
        // 適用のたびに現在の全bindingで再検査する。
        let clipboardVariantIsUsable = ai.clipboardVariantEnabled
            && AICommandClipboardChordPolicy.eligibility(
                startBinding: ai.startHotkey,
                extraModifier: ai.clipboardVariantModifier,
                stopBinding: ai.stopHotkey,
                normalBinding: settings.normalHotkeyBinding,
                handsFreeSendBinding: settings.handsFreeSendSettings.binding,
                handsFreeSendEnabled: settings.handsFreeSendSettings.enabled
            ) == .eligible
        hotkeyManager.aiCommandClipboardModifier = clipboardVariantIsUsable ? ai.clipboardVariantModifier : nil
    }

    private func applyHandsFreeSendHotkeySettings(_ settings: KoedexSettings) {
        guard hotkeyManager != nil else { return }
        let liveHandsFree = settings.handsFreeSendSettings
        let sessionHandsFree = activeVoiceSession?.handsFreeSendSession?.snapshot.settings
        let effectiveBindings = sessionHandsFree ?? liveHandsFree
        hotkeyManager.handsFreeSendEnabled = liveHandsFree.enabled && settings.setupProgress.isComplete
        hotkeyManager.handsFreeSendBinding = effectiveBindings.binding
    }

    /// 設定画面でキーを捕捉している間だけ、グローバルhotkeyから録音を起動させない。
    /// 解除時は、確定に使ったキーが解放されるまで抑止を維持する。
    func setHotkeyCaptureActive(_ active: Bool, capturedKeys: [HotkeyKey] = []) {
        guard hotkeyManager != nil else { return }

        if active {
            hotkeyManager.setRecordingTriggersSuppressed(true)
            return
        }
        hotkeyManager.resumeRecordingTriggers(afterReleasing: capturedKeys)
    }

    private func wireHotkeyCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] in self?.handleHotkeyDown() }
        hotkeyManager.onKeyUp = { [weak self] in self?.handleHotkeyUp() }
        hotkeyManager.onSinglePress = { [weak self] in self?.handleHotkeyTogglePress() }
        hotkeyManager.onAICommandStart = { [weak self] source in self?.handleAICommandStart(source) }
        hotkeyManager.onAICommandStop = { [weak self] in self?.handleAICommandStop() ?? false }
        // 開始処理はNormalPasteTarget/InsertionDestinationのAX同期IPCを含む。
        // これをCGEvent tapのコールバック内で実行するとtapがタイムアウトし、
        // アプリ全体のホットキーが停止する（2026-07-30の実機障害）。
        // tapへは即座に制御を返し、実処理は次のmain loopへ逃がす。
        hotkeyManager.onHandsFreeSendToggle = { [weak self] in
            guard let self else { return false }
            let stopping = self.canHandleHandsFreeSendStop()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if stopping {
                    _ = self.handleHandsFreeSendStop()
                } else {
                    self.handleHandsFreeSendStart()
                }
            }
            return stopping
        }
        // `cancelRecording()` はAppLogの書き出しと状態遷移を同期で行う。すぐ上の
        // `onHandsFreeSendToggle` と同じ理由で、tapコールバック内に置いたままだと
        // tapを塞ぐ。消費するかどうかだけを同期で決め、実処理は次のmain loopへ逃がす。
        hotkeyManager.onEscape = { [weak self] in
            guard let self, self.canCancelWithEscape() else { return false }
            Task { @MainActor [weak self] in
                self?.cancelRecording()
            }
            return true
        }
        hotkeyManager.onEventTapDisabled = { [weak self] in
            guard let self else { return }
            if let handsFreeSession = self.activeVoiceSession?.handsFreeSendSession {
                handsFreeSession.revokeSendAuthorization()
                return
            }
            // Chord成立からsession生成までは1 main loop分の隙がある。その間にtapが
            // 落ちた場合も、生成直後のsessionから送信権限を落とす。
            self.pendingHandsFreeSendRevocation = true
        }
        hotkeyManager.onHoldTrackingInterrupted = { [weak self] in
            self?.cancelInterruptedNormalHoldRecording()
        }
        hotkeyManager.onPermissionDenied = { [weak self] in
            guard let self else { return }
            self.appState.setPhase(.error(
                self.uiText("Accessibility権限が必要です。システム設定から許可してください")
            ))
        }
    }

    /// SettingsStoreの変更を監視し、ホットキー関連設定が変わったらtapを作り直す。
    private func observeSettingsChanges() {
        var lastKeyCode = settingsStore.settings.hotkeyKeyCode
        var lastIsModifier = settingsStore.settings.hotkeyIsModifier
        var lastMode = settingsStore.settings.recordingMode
        var lastModifierMask = settingsStore.settings.hotkeyModifierMask
        var lastCodexExecutablePath = settingsStore.settings.codexExecutablePath
        var lastModelSettings = settingsStore.settings.modelSettings
        var lastAICommandSettings = settingsStore.settings.aiCommandSettings
        var lastHandsFreeSendSettings = settingsStore.settings.handsFreeSendSettings
        var lastSetupProgress = settingsStore.settings.setupProgress

        let cancellable = settingsStore.settingsPublisher.sink { [weak self] newSettings in
            guard let self else { return }
            let hotkeyRelevantChange = newSettings.hotkeyKeyCode != lastKeyCode
                || newSettings.hotkeyIsModifier != lastIsModifier
                || newSettings.recordingMode != lastMode
                || newSettings.hotkeyModifierMask != lastModifierMask
                || newSettings.aiCommandSettings.startHotkey != lastAICommandSettings.startHotkey
                || newSettings.aiCommandSettings.stopHotkey != lastAICommandSettings.stopHotkey
                || newSettings.aiCommandSettings.enabled != lastAICommandSettings.enabled
                || newSettings.aiCommandSettings.clipboardVariantEnabled != lastAICommandSettings.clipboardVariantEnabled
                || newSettings.aiCommandSettings.clipboardVariantModifier != lastAICommandSettings.clipboardVariantModifier
                || newSettings.handsFreeSendSettings.binding != lastHandsFreeSendSettings.binding
                || newSettings.handsFreeSendSettings.enabled != lastHandsFreeSendSettings.enabled
                || newSettings.setupProgress != lastSetupProgress

            lastKeyCode = newSettings.hotkeyKeyCode
            lastIsModifier = newSettings.hotkeyIsModifier
            lastMode = newSettings.recordingMode
            lastModifierMask = newSettings.hotkeyModifierMask

            let aiCommandWebAuthorizationChanged = newSettings.aiCommandSettings.webSearchEnabled
                != lastAICommandSettings.webSearchEnabled
                || newSettings.aiCommandSettings.modelSettings != lastAICommandSettings.modelSettings
                || newSettings.codexExecutablePath != lastCodexExecutablePath
            if aiCommandWebAuthorizationChanged {
                self.invalidateAICommandWebRetry(.pendingAndRunning)
            }

            if lastAICommandSettings.enabled && !newSettings.aiCommandSettings.enabled {
                if self.activeVoiceSession?.mode == .aiCommand || self.aiCommandCaptureID != nil {
                    _ = self.cancelRecording()
                }
            }
            if lastHandsFreeSendSettings.enabled && !newSettings.handsFreeSendSettings.enabled,
               self.activeVoiceSession?.handsFreeSendSession != nil {
                _ = self.cancelRecording()
            }
            lastAICommandSettings = newSettings.aiCommandSettings
            lastHandsFreeSendSettings = newSettings.handsFreeSendSettings
            lastSetupProgress = newSettings.setupProgress

            if newSettings.codexExecutablePath != lastCodexExecutablePath {
                lastCodexExecutablePath = newSettings.codexExecutablePath
                AppLog.shared.info("Codex CLIパス設定が変更されました。保存後の再接続または次回整形時から反映されます")
                Task {
                    await self.cleanupEngine.updateExecutablePath(self.nonEmptyCodexPath(newSettings.codexExecutablePath))
                    await self.aiCommandEngine.updateExecutablePath(self.nonEmptyCodexPath(newSettings.codexExecutablePath))
                }
            }

            if newSettings.modelSettings != lastModelSettings {
                lastModelSettings = newSettings.modelSettings
                AppLog.shared.info("AIモデル設定が変更されました。保存後の再接続またはアプリ再起動後に反映されます")
                Task {
                    await self.cleanupEngine.updateModelSettings(newSettings.modelSettings)
                }
            }

            guard hotkeyRelevantChange else { return }
            AppLog.shared.info("ホットキー設定が変更されました。tapを再作成します（keyCode=\(newSettings.hotkeyKeyCode), isModifier=\(newSettings.hotkeyIsModifier), mode=\(newSettings.recordingMode)）")

            self.hotkeyManager.targetKeyCode = newSettings.hotkeyKeyCode
            self.hotkeyManager.isModifierKey = newSettings.hotkeyIsModifier
            self.hotkeyManager.recordingMode = RecordingMode(rawValue: newSettings.recordingMode) ?? .toggle
            self.hotkeyManager.modifierMaskFromSettings = newSettings.hotkeyModifierMask
            self.applyAICommandHotkeySettings(newSettings)
            self.applyHandsFreeSendHotkeySettings(newSettings)
            self.wireHotkeyCallbacks()
            if self.didWarmUp {
                self.hotkeyManager.restart()
            }
        }
        settingsCancellable = AnyObjectHolder(cancellable)
    }

    func applicationWillTerminate(_ notification: Notification) {
        invalidateAICommandWebRetry(.pendingAndRunning)
        if OnboardingRuntimeProfile.isDebug {
            // Debug.appの進捗だけは保存し、本番のログ・PID・Codex終了処理には触れない。
            settingsStore.flushPendingSave()
            return
        }
        AppLog.shared.info("Koedex終了処理開始")
        textInjector.restorePendingScopedClipboardIfOwned()
        autoStopTask?.cancel()
        onboardingRestartPresentationTask?.cancel()
        recordingStartTask?.cancel()
        recordingStartTimeoutTask?.cancel()
        aiCommandCaptureTask?.cancel()
        aiCommandCaptureTimeoutTask?.cancel()
        processingTask?.cancel()
        hotkeyManager?.stop()
        aiCommandResultWindows.closeAll()
        settingsStore.flushPendingSave()
        AppLog.shared.info("Koedex終了")
    }

    func applicationDidResignActive(_ notification: Notification) {
        // 未承認tokenは外部アプリへ戻った時点で破棄する。一方、確認済みturnは
        // 結果表示専用であり、ここで止めると確認画面自身の前面化で自己取消になる。
        invalidateAICommandWebRetry(.pendingOnly)
        reassertHUDIfAvailable()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        reassertHUDIfAvailable()
    }

    /// Debug.appは通常アプリの副作用を止めるためHUDを作らない。
    /// AppKitのactive通知はその早期return後にも届くので、HUDだけを安全に無視する。
    private func reassertHUDIfAvailable() {
        guard RecordingHUDLifecyclePolicy.shouldReassert(
            isDebug: OnboardingRuntimeProfile.isDebug,
            hasHUD: hud != nil
        ), let hud else { return }
        hud.reassertFrontmostIfVisible()
    }

    /// 子プロセス（codex app-server）のゾンビ化を防ぐため、shutdown完了までアプリの終了を保留する。
    /// MainActor上でDispatchSemaphoreを使って同期的に待つと、shutdown内のcontinuation resumeが
    /// MainActorへhopする必要がある場合にデッドロックするため、`.terminateLater` + 非同期replyへ変更。
    /// 万一shutdownが長引いた場合に備え、3秒後に強制replyするタイムアウト保険も並走させる
    /// （二重replyを防ぐためフラグで排他制御する）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if OnboardingRuntimeProfile.isDebug {
            return .terminateNow
        }
        var didReply = false

        Task {
            await audioRecorder.stop()
            await cleanupEngine.shutdown()
            await aiCommandEngine.shutdown()
            guard !didReply else { return }
            didReply = true
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !didReply else { return }
            didReply = true
            AppLog.shared.warn("cleanupEngine.shutdownが3秒以内に完了しなかったため強制終了します")
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    // MARK: - 録音パイプライン

    private func handleAICommandStart(_ inputSource: AICommandInputSource) {
        guard appState.phase == .idle else {
            showBusyMessage()
            return
        }
        startAICommandRecording(inputSource: inputSource)
    }

    private func handleAICommandStop() -> Bool {
        guard appState.phase == .recording, activeVoiceSession?.mode == .aiCommand else { return false }
        stopRecordingAndProcess()
        return true
    }

    private func handleHandsFreeSendStart() {
        let settings = settingsStore.settings
        guard settings.handsFreeSendSettings.enabled,
              settings.setupProgress.isComplete else { return }
        guard appState.phase == .idle else {
            showBusyMessage()
            return
        }
        guard canStartRecordingOutsideSecureInput() else { return }

        invalidateAICommandWebRetry(.pendingAndRunning)
        invalidateAICommandFailureDismissal()
        appState.setPhase(.starting)
        hud.clearAICommandState()
        hud.show()

        // 設定値（トリガー句・STT言語・外部互換の可否）は開始時点で固定する。
        // 録音中に設定を変えても、その録音の判定は開始時のまま一貫させる。
        //
        // 貼り付け先は開始時にも取っておくが、**権威は停止時の取り直し**にある
        // （`stopRecordingAndProcess`）。ここで取る値は、万一停止経路が取り直しを
        // 行わなかった場合に備えた控えでしかない。
        let snapshot = HandsFreeSendSnapshot(
            settings: settings.handsFreeSendSettings,
            sttLanguage: settings.languagePreferences.sttLanguage,
            externalCompatibilityEnabledAtRecordingStart: settings.externalAppCompatibilitySettings.enabled,
            normalModeCustomInstruction: settings.customInstruction
        )
        let session = VoiceSession(
            mode: .voiceInput,
            handsFreeSendSnapshot: snapshot,
            externalCompatibilityEnabledAtRecordingStart: settings.externalAppCompatibilitySettings.enabled,
            normalPasteTarget: NormalPasteTarget.capture(),
            insertionDestination: InsertionDestination.capture()
        )
        if pendingHandsFreeSendRevocation {
            pendingHandsFreeSendRevocation = false
            session.handsFreeSendSession?.revokeSendAuthorization()
            AppLog.shared.warn("開始直前にevent tapが無効化されていたため、このsessionでは擬似送信しません")
        }
        beginRecording(session: session)
    }

    /// tapコールバックから同期的に呼べる軽量判定。イベントを消費するかだけを決める。
    /// 実際の停止処理は次のmain loopへ逃がし、tapを塞がない。
    private func canHandleHandsFreeSendStop() -> Bool {
        appState.phase == .recording
            && activeVoiceSession?.handsFreeSendSession != nil
    }

    private func handleHandsFreeSendStop() -> Bool {
        guard appState.phase == .recording,
              let session = activeVoiceSession,
              session.handsFreeSendSession != nil else {
            return false
        }
        return requestHandsFreeSendStop(
            for: session,
            intent: .send,
            evidence: .stopHotkey
        )
    }

    private func handleHandsFreeSendPartialText(
        _ partialText: String,
        streamID: UUID,
        isFinal: Bool
    ) {
        guard appState.phase == .recording,
              let session = activeVoiceSession,
              let handsFreeSession = session.handsFreeSendSession,
              handsFreeSession.snapshot.streamID == streamID else {
            return
        }

        switch handsFreeSession.observePartial(partialText, isFinal: isFinal) {
        case .none:
            if handsFreeSession.lastObservationCollapsed {
                AppLog.shared.info(String(
                    format: "[Telemetry] hfs_trigger_state state=none elapsedMs=%.0f collapseCount=%d",
                    handsFreeSendElapsedMs(for: handsFreeSession),
                    handsFreeSession.candidateCollapseCount
                ))
            }
            clearHandsFreeSendTriggerCandidate()
            // 候補が崩れたら、録音継続中であることが分かる通常のハンズフリー波形へ戻す。
            hud.showHandsFreeSendState(.recording)
        case .ready:
            _ = requestHandsFreeSendStop(
                for: session,
                intent: .send,
                evidence: .voiceTrigger
            )
        case .pending(let pending):
            if handsFreeSession.lastObservationWasFreshCandidate {
                AppLog.shared.info(String(
                    format: "[Telemetry] hfs_trigger_state state=pending elapsedMs=%.0f",
                    handsFreeSendElapsedMs(for: handsFreeSession)
                ))
            }
            // 安定判定はまだだが、候補を検出した事実は即時に見せる。ここで録音や
            // 挿入を開始しないため、発話継続時の誤送信リスクは増やさない。
            hud.showHandsFreeSendState(.triggerCandidate)
            scheduleHandsFreeSendTriggerCheck(
                for: session,
                candidate: pending.candidate,
                deadline: pending.deadline
            )
        }
    }

    /// 録音開始からの経過ms。計測ログ専用（判定には使わない）。
    private func handsFreeSendElapsedMs(for handsFreeSession: HandsFreeSendSession, now: Date = Date()) -> Double {
        guard let recordingStartedAt = handsFreeSession.recordingStartedAt else { return 0 }
        return now.timeIntervalSince(recordingStartedAt) * 1_000
    }

    private func scheduleHandsFreeSendTriggerCheck(
        for session: VoiceSession,
        candidate: HandsFreeSendPartialTriggerCandidate,
        deadline: Date
    ) {
        // partial全文が更新されたら以前のtimerを差し替える。句読点・空白だけの更新では
        // fingerprint由来のdeadlineを維持し、350msの安定時間をやり直さない。
        clearHandsFreeSendTriggerCandidate()
        let taskID = UUID()
        handsFreeSendTriggerTaskID = taskID
        let delay = max(0, deadline.timeIntervalSinceNow)
        handsFreeSendTriggerTask = Task { @MainActor [weak self] in
            let sleepStartedAt = Date()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let sleepResumedAt = Date()
            let plannedDelayMs = delay * 1_000
            let actualElapsedMs = sleepResumedAt.timeIntervalSince(sleepStartedAt) * 1_000
            AppLog.shared.info(String(
                format: "[Telemetry] hfs_timer_overshoot plannedMs=%.1f actualMs=%.1f overshootMs=%.1f",
                plannedDelayMs,
                actualElapsedMs,
                actualElapsedMs - plannedDelayMs
            ))
            guard !Task.isCancelled,
                  let self,
                  self.handsFreeSendTriggerTaskID == taskID,
                  self.activeVoiceSession?.id == session.id,
                  self.appState.phase == .recording,
                  let handsFreeSession = session.handsFreeSendSession,
                  handsFreeSession.isPendingCandidateCurrent(
                      candidate,
                      for: self.transcriptionEngine.partialText
                  ) else {
                return
            }
            // 現在のtimerだけを解放する。partialが直前に更新されていれば、新しいtimerを
            // 誤って消さないためtokenを確認してからnil化する。
            self.handsFreeSendTriggerTask = nil
            self.handsFreeSendTriggerTaskID = nil

            // deadline到達を新しい音声partialとして扱わない。ASR callbackだけが候補の
            // 安定窓を更新できるようにし、timer再評価による余分な遅延も防ぐ。
            switch handsFreeSession.reevaluatePendingCandidate(
                candidate,
                for: self.transcriptionEngine.partialText
            ) {
            case .ready:
                _ = self.requestHandsFreeSendStop(
                    for: session,
                    intent: .send,
                    evidence: .voiceTrigger
                )
            case .pending(let pending):
                self.scheduleHandsFreeSendTriggerCheck(
                    for: session,
                    candidate: pending.candidate,
                    deadline: pending.deadline
                )
            case .none:
                self.clearHandsFreeSendTriggerCandidate()
            }
        }
    }

    private func clearHandsFreeSendTriggerCandidate() {
        handsFreeSendTriggerTask?.cancel()
        handsFreeSendTriggerTask = nil
        handsFreeSendTriggerTaskID = nil
    }

    @discardableResult
    private func requestHandsFreeSendStop(
        for session: VoiceSession,
        intent: HandsFreeSendSession.StopIntent,
        evidence: HandsFreeSendSession.StopEvidence
    ) -> Bool {
        guard activeVoiceSession?.id == session.id,
              appState.phase == .recording,
              let handsFreeSession = session.handsFreeSendSession,
              handsFreeSession.claimStop(intent: intent, evidence: evidence) else {
            return false
        }
        if evidence == .voiceTrigger {
            // final callbackが空、またはトリガーを安全に除去できない場合でも、
            // 自動挿入・送信をせずユーザーが確認できるpartialを残す。
            handsFreeSession.captureVoiceTriggerFallbackTranscript(transcriptionEngine.partialText)
            // 検出の速さを体感でしか判断できなかったため、測れるようにする。
            if let metrics = handsFreeSession.detectionMetrics() {
                AppLog.shared.info(String(
                    format: "音声トリガー検出: 候補確認から%.2f秒, partial観測%d回",
                    metrics.elapsedSeconds,
                    metrics.observations
                ))
            }
            // セッション全体の内訳。ここでのみ中央値算出・文字列整形を行う（計測専用）。
            AppLog.shared.info(String(
                format: "[Telemetry] hfs_trigger_accepted totalMs=%.0f sinceFirstCandidateMs=%.0f "
                    + "collapseCount=%d volatileCount=%d volatileIntervalMedianMs=%.0f",
                handsFreeSendElapsedMs(for: handsFreeSession),
                handsFreeSession.elapsedMillisSinceFirstCandidateDetected() ?? -1,
                handsFreeSession.candidateCollapseCount,
                handsFreeSession.volatileObservationCount,
                handsFreeSession.volatileIntervalMedianMillis() ?? -1
            ))
        }
        clearHandsFreeSendTriggerCandidate()
        if intent == .send {
            // 350msの安定判定は既に通過している。ここで収束アニメーションを待つと、
            // 実処理が始まっているのに「まだ反応していない」ように見える。音声トリガー
            // の受理とAI整形を同時に示す状態へ直ちに遷移する。
            hud.showHandsFreeSendState(
                evidence == .voiceTrigger ? .triggerConfirmedProcessing : .processing
            )
        } else {
            hud.clearHandsFreeSendState()
        }
        stopRecordingAndProcess()
        return true
    }

    /// トグル/hold両モードに対応するハンドラ。recordingModeによって分岐する。
    /// - toggle: .idle→録音開始、.recording→停止して処理へ、それ以外はHUDに「処理中」表示
    /// - hold: 従来通りhandleHotkeyDown/onKeyUp経由のstopRecordingAndProcessに任せる
    private func handleHotkeyTogglePress() {
        // ハンズフリー録音中は一切アニメーションを動かさない。波形とボタンが一瞬
        // 置き換わると録音が止まったように見えて非常に紛らわしい。
        if activeVoiceSession?.handsFreeSendSession != nil { return }
        if activeVoiceSession?.mode == .aiCommand {
            showBusyMessage()
            return
        }
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecordingAndProcess()
        case .error:
            appState.setPhase(.idle)
            startRecording()
        case .starting, .transcribing, .cleaning, .inserting:
            showBusyMessage()
        }
    }

    /// ホットキーkeyDown時の分岐（holdモード用）:
    /// - idle: 録音開始
    /// - error: idleへ復帰してから録音開始（ロックアウト防止）
    /// - それ以外（transcribing/cleaning/inserting）: 「処理中です」を短く表示するのみ
    private func handleHotkeyDown() {
        if activeVoiceSession?.handsFreeSendSession != nil { return }
        if activeVoiceSession?.mode == .aiCommand {
            showBusyMessage()
            return
        }
        switch appState.phase {
        case .idle:
            pendingNormalHold = true
            startRecording()
        case .error:
            appState.setPhase(.idle)
            pendingNormalHold = true
            startRecording()
        case .recording:
            break
        case .starting, .transcribing, .cleaning, .inserting:
            showBusyMessage()
        }
    }

    /// holdモードのキー解放時。録音中のみ停止処理へ進む。
    private func handleHotkeyUp() {
        pendingNormalHold = false
        if activeVoiceSession?.handsFreeSendSession != nil { return }
        if appState.phase == .starting, activeVoiceSession?.mode == .voiceInput {
            _ = cancelRecording()
            return
        }
        guard appState.phase == .recording, activeVoiceSession?.mode == .voiceInput else { return }
        stopRecordingAndProcess()
    }

    /// event tap再起動やキー設定開始で、押下状態を追跡できなくなった通常モードの長押し録音だけを中断する。
    private func cancelInterruptedNormalHoldRecording() {
        guard pendingNormalHold else { return }
        pendingNormalHold = false
        _ = cancelRecording()
    }

    /// phaseを変えずにHUDへ短いbusyアニメーションを表示する（無反応をなくすためのフィードバック）。
    private func showBusyMessage() {
        hud.flashBusy()
    }

    /// 整形失敗をメニューバーで一時警告する（挿入自体は成功しているため塗りなしアイコン）。
    private func flashMenuBarWarning(seconds: Double = 8) {
        menuBarWarningTask?.cancel()
        menuBarIconName = "exclamationmark.triangle"
        menuBarWarningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.appState.phase == .idle else { return }
            self.menuBarIconName = "mic"
        }
    }

    private static func describeCleanupError(_ error: Error) -> String {
        switch error {
        case CleanupError.timeout: return "タイムアウト(15秒)"
        case CleanupError.emptyResult: return "整形結果が空"
        case CleanupError.underlying(let inner): return "内部エラー: \(describeCodexError(inner))"
        default: return "整形処理でエラーが発生しました"
        }
    }

    private static func describeCodexError(_ error: Error) -> String {
        switch error {
        case CodexClientError.codexNotFound: return "codex CLIが見つかりません"
        case CodexClientError.processNotRunning: return "codex app-serverが起動していません"
        case CodexClientError.timeout: return "Codexの応答がタイムアウトしました"
        case CodexClientError.processExited: return "codex app-serverが終了しました"
        case CodexClientError.processLaunchFailed: return "codex app-serverを起動できません"
        case CodexClientError.rpcError(_, let kind):
            return kind == .other ? "Codex接続に失敗しました" : kind.userMessage
        case CodexClientError.invalidResponse: return "Codexから不正な応答を受け取りました"
        default: return "Codex接続に失敗しました"
        }
    }

    /// 接続レベルの失敗と、分類可能なRPCエラーのみcodexStatusへ反映する。
    private func updateCodexStatusOnFailure(_ error: Error) {
        guard case CleanupError.underlying(let inner) = error else {
            consecutiveUnclassifiedRPCFailures = 0
            return
        }
        switch inner {
        case CodexClientError.codexNotFound:
            consecutiveUnclassifiedRPCFailures = 0
            codexStatus = .failed("codex CLIが見つかりません")
        case CodexClientError.processNotRunning, CodexClientError.processExited, CodexClientError.processLaunchFailed:
            consecutiveUnclassifiedRPCFailures = 0
            codexStatus = .failed("codex app-serverに接続できません")
        case CodexClientError.rpcError(_, let kind):
            if kind == .other {
                consecutiveUnclassifiedRPCFailures += 1
                if consecutiveUnclassifiedRPCFailures >= Self.unclassifiedRPCFailureWarningThreshold {
                    codexStatus = .failed("AIアシストが繰り返し失敗しています。Codex接続を確認してください")
                }
            } else {
                consecutiveUnclassifiedRPCFailures = 0
                codexStatus = .failed(kind.userMessage)
            }
        default:
            consecutiveUnclassifiedRPCFailures = 0
            break
        }
    }

    /// .errorフェーズの表示（3秒自動復帰）を妨げないよう、復帰後にHUDを閉じる。
    private func scheduleHUDHideAfterError(seconds: Double = 3.2) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.appState.phase == .idle else { return }
            self.hud.hide()
        }
    }

    private func finishRecordingFromHUD() {
        guard appState.phase == .recording else {
            showBusyMessage()
            return
        }
        if let session = activeVoiceSession,
           session.handsFreeSendSession != nil {
            _ = requestHandsFreeSendStop(
                for: session,
                intent: .insertOnly,
                evidence: .hudFinish
            )
            return
        }
        stopRecordingAndProcess()
    }

    private func cancelRecordingFromHUD() {
        if !cancelRecording() {
            showBusyMessage()
        }
    }

    /// tapコールバックから同期的に呼べる軽量判定。イベントを消費するかだけを決める。
    /// **`cancelRecording()` が true を返す条件と一致させること。**
    ///
    /// 判定と実処理の間に状態が変わると、消費だけして何も起きない場合がある。
    /// Escで消費し損ねるより無害で、`onHandsFreeSendToggle` も同じ性質を持つ。
    private func canCancelWithEscape() -> Bool {
        if aiCommandFailureOwnership.isPresented { return true }
        switch appState.phase {
        case .recording, .starting, .transcribing, .cleaning, .inserting:
            return true
        case .idle, .error:
            return false
        }
    }

    @discardableResult
    private func cancelRecording() -> Bool {
        invalidateAICommandWebRetry(.pendingAndRunning)
        // M5の失敗HUDはAppStateのphaseと独立して所有する。
        // 一般errorの自動復帰後でもEscで必ず閉じられる。
        if aiCommandFailureOwnership.isPresented {
            pendingNormalHold = false
            activeVoiceSession?.cancel()
            processingTask?.cancel()
            Task { await aiCommandEngine.cancelActive() }
            dismissAICommandFailure()
            return true
        }

        switch appState.phase {
        case .recording:
            break
        case .transcribing, .cleaning, .inserting:
            return cancelProcessing()
        case .starting:
            pendingNormalHold = false
            clearHandsFreeSendTriggerCandidate()
            aiCommandCaptureTask?.cancel()
            aiCommandCaptureTask = nil
            aiCommandCaptureID = nil
            clearAICommandCaptureTimeout()
            activeVoiceSession?.cancel()
            recordingStartTask?.cancel()
            recordingStartTask = nil
            recordingStartTaskSessionID = nil
            clearRecordingStartTimeout()
            activeVoiceSession = nil
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.clearHandsFreeSendState()
            hud.hide()
            return true
        case .idle, .error:
            return false
        }

        let cancelledSession = activeVoiceSession
        clearPendingNormalHoldState()
        clearHandsFreeSendTriggerCandidate()
        clearRecordingStartTimeout(for: cancelledSession)
        cancelledSession?.cancel()
        autoStopTask?.cancel()
        autoStopTask = nil
        menuBarIconName = "mic"
        appState.recordingStartedAt = nil
        appState.setPhase(.transcribing)
        AppLog.shared.info("録音キャンセル")

        Task {
            await audioRecorder.stop()
            if let streamID = cancelledSession?.handsFreeSendSession?.snapshot.streamID ?? cancelledSession?.id {
                _ = await transcriptionEngine.stopStreaming(streamID: streamID)
            }
            if self.activeVoiceSession?.id == cancelledSession?.id {
                self.activeVoiceSession = nil
            }
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.clearHandsFreeSendState()
            hud.hide()
        }
        return true
    }

    private func cancelProcessing() -> Bool {
        invalidateAICommandWebRetry(.pendingAndRunning)
        let cancelledSession = activeVoiceSession
        clearPendingNormalHoldState()
        clearHandsFreeSendTriggerCandidate()
        cancelledSession?.cancel()
        let cancelledTask = processingTask
        autoStopTask?.cancel()
        autoStopTask = nil
        cancelledTask?.cancel()
        menuBarIconName = "mic"
        appState.recordingStartedAt = nil
        AppLog.shared.info("処理キャンセル")

        Task {
            if cancelledSession?.mode == .aiCommand {
                await aiCommandEngine.cancelActive()
            }
            await audioRecorder.stop()
            if let streamID = cancelledSession?.handsFreeSendSession?.snapshot.streamID ?? cancelledSession?.id {
                _ = await transcriptionEngine.stopStreaming(streamID: streamID)
            }
            await cancelledTask?.value
            guard self.activeVoiceSession == nil
                    || self.activeVoiceSession?.id == cancelledSession?.id else { return }
            if self.activeVoiceSession?.id == cancelledSession?.id {
                self.activeVoiceSession = nil
            }
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.clearHandsFreeSendState()
            hud.hide()
        }
        return true
    }

    private func clearPendingNormalHoldState() {
        pendingNormalHold = false
    }

    private func startRecording() {
        guard appState.phase == .idle else { return }
        guard canStartRecordingOutsideSecureInput() else { return }
        invalidateAICommandWebRetry(.pendingAndRunning)
        invalidateAICommandFailureDismissal()
        appState.setPhase(.starting)
        hud.clearAICommandState()
        hud.show()
        let settings = settingsStore.settings
        beginRecording(session: VoiceSession(
            mode: .voiceInput,
            externalCompatibilityEnabledAtRecordingStart: settings.externalAppCompatibilitySettings.enabled
        ))
    }

    private func startAICommandRecording(
        expectedFrontmostProcessIdentifier: pid_t? = nil,
        inputSource: AICommandInputSource
    ) {
        let settings = settingsStore.settings
        guard settings.aiCommandSettings.enabled,
              settings.setupProgress.isComplete,
              appState.phase == .idle else { return }
        guard canStartRecordingOutsideSecureInput() else { return }
        guard ExternalCompatibilityFocusReturnPolicy.canResume(
            expectedProcessIdentifier: expectedFrontmostProcessIdentifier,
            currentProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        ) else {
            // The compatibility-consent panel must never turn an uncertain
            // focus return into an automatic general-question recording.
            if inputSource == .clipboard, expectedFrontmostProcessIdentifier != nil {
                presentAICommandClipboardRecoveryFocusFailure()
            } else {
                presentAICommandCaptureGuidance(
                    for: .focusedElementUnavailable,
                    inputSource: inputSource,
                    allowsClipboardRecovery: false
                )
            }
            return
        }
        invalidateAICommandWebRetry(.pendingAndRunning)
        invalidateAICommandFailureDismissal()
        appState.setPhase(.starting)
        // 新しい指示を始めた時点で前回の控えを捨てる。残すとメニューの
        // 「最後のAI出力をコピー」が、その後に実行した別の指示の結果ではなく
        // 古い出力を指したままになる。
        lastAICommandOutput = nil
        // 色・外枠・読み上げで入力源が分かるよう、最初の表示より前に渡す。
        hud.setAICommandInputSource(inputSource)
        hud.showAICommandState(.processing)

        // クリップボード入力源は同期で即座に終わるため、選択取得の非同期Task・
        // captureID・タイムアウトのどれも使わない。
        if inputSource == .clipboard {
            // クリップボードをモデルへ渡す同意を、実際に読む直前でもう一度確かめる。
            // `aiCommandClipboardModifier`は同意済みの時しか設定されないので現状は
            // 到達しないが、同意の検査を読み取り地点から離すと、呼び出し元が増えた時に
            // 不変条件が静かに壊れる。
            guard settings.aiCommandSettings.clipboardVariantEnabled else {
                AppLog.shared.warn("AIに指示のクリップボード入力は未同意のため中止")
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            let decision = clipboardSourceReader.read()
            switch decision {
            case .text(let text):
                beginRecording(session: VoiceSession(
                    mode: .aiCommand,
                    selectedText: text,
                    inputSource: inputSource,
                    aiCommandSettings: settings.aiCommandSettings,
                    aiCommandExplicitInsertionAllowedAtRecordingStart: aiCommandExplicitInsertionAllowedAtCurrentSettings()
                ))
                AppLog.shared.info("[Telemetry] ai_command_clipboard_read result=ok characters=\(text.count)")
            case .empty, .nonText, .rejectedSecureInput, .rejectedConcealed, .rejectedSelfGenerated, .tooLong:
                let reasonCode = aiCommandClipboardReasonCode(for: decision)
                AppLog.shared.warn("AIに指示のクリップボード読み取りを安全に中止: reason=\(reasonCode)")
                AppLog.shared.info("[Telemetry] ai_command_clipboard_read result=\(reasonCode)")
                presentAICommandClipboardCaptureGuidance(for: decision)
            }
            return
        }

        let captureID = UUID()
        aiCommandCaptureID = captureID
        aiCommandCaptureTask?.cancel()
        clearAICommandCaptureTimeout()
        scheduleAICommandCaptureTimeout(for: captureID)
        aiCommandCaptureTask = Task {
            defer {
                if self.aiCommandCaptureID == captureID {
                    self.aiCommandCaptureID = nil
                    self.aiCommandCaptureTask = nil
                }
                self.clearAICommandCaptureTimeout(for: captureID)
            }
            let capture = await selectedTextCapture.capture(
                allowingExternalCompatibility: settingsStore.settings.externalAppCompatibilitySettings.enabled
            )
            guard aiCommandCaptureID == captureID,
                  appState.phase == .starting,
                  settingsStore.settings.aiCommandSettings.enabled,
                  settingsStore.settings.setupProgress.isComplete else {
                if appState.phase == .starting {
                    appState.setPhase(.idle)
                    hud.clearAICommandState()
                    hud.hide()
                }
                return
            }
            aiCommandCaptureID = nil
            aiCommandCaptureTask = nil
            clearAICommandCaptureTimeout(for: captureID)
            switch capture {
            case .selected(let context):
                beginRecording(session: VoiceSession(
                    mode: .aiCommand,
                    selectedText: context.text,
                    inputSource: inputSource,
                    aiCommandSettings: settings.aiCommandSettings,
                    aiCommandExplicitInsertionAllowedAtRecordingStart: aiCommandExplicitInsertionAllowedAtCurrentSettings()
                ))
            case .none:
                beginRecording(session: VoiceSession(
                    mode: .aiCommand,
                    inputSource: inputSource,
                    aiCommandSettings: settings.aiCommandSettings,
                    aiCommandExplicitInsertionAllowedAtRecordingStart: aiCommandExplicitInsertionAllowedAtCurrentSettings()
                ))
            case .tooLong(_, let maximum):
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                aiCommandResultWindows.show(AICommandResultPayload(
                    spokenInstruction: "",
                    selectedText: nil,
                    answer: uiFormat(
                        "選択したテキストが%d文字を超えています。選択範囲を短くして、もう一度指示してください。",
                        maximum
                    ),
                    sources: [],
            title: uiText("AIに指示モード")
                ))
            case .unavailable(let failure):
                presentAICommandCaptureGuidance(for: failure, inputSource: inputSource)
            }
        }
    }

    /// 選択取得が曖昧だった案内で利用者が明示的に選んだ場合だけ、
    /// 再キャプチャせず「選択なし」のAI質問を開始する。
    ///
    /// `inputSource`は暗黙の既定に頼らず、案内を出した元のsessionから明示的に受け取る。
    /// 本文を持たない一般質問でも、利用者が音声で明示した届け先だけは別の安全経路で
    /// 処理できる。暗黙に`.selection`へ落とすと、sourceの有無と届け先の意味が混ざるため、
    /// 元の入力sourceを明示的に保持する。
    private func startAICommandRecordingWithoutSelection(inputSource: AICommandInputSource) {
        let settings = settingsStore.settings
        guard settings.aiCommandSettings.enabled,
              settings.setupProgress.isComplete,
              appState.phase == .idle else { return }
        guard canStartRecordingOutsideSecureInput() else { return }
        invalidateAICommandWebRetry(.pendingAndRunning)
        invalidateAICommandFailureDismissal()
        appState.setPhase(.starting)
        hud.setAICommandInputSource(inputSource)
        hud.showAICommandState(.processing)
        beginRecording(session: VoiceSession(
            mode: .aiCommand,
            inputSource: inputSource,
            aiCommandSettings: settings.aiCommandSettings,
            aiCommandExplicitInsertionAllowedAtRecordingStart: aiCommandExplicitInsertionAllowedAtCurrentSettings()
        ))
    }

    private func scheduleAICommandCaptureTimeout(for captureID: UUID) {
        aiCommandCaptureTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.aiCommandCaptureID == captureID,
                  self.appState.phase == .starting else { return }
            AppLog.shared.warn("AIに指示の選択取得が12秒以内に完了しなかったため中断します")
            self.aiCommandCaptureTask?.cancel()
            self.aiCommandCaptureTask = nil
            self.aiCommandCaptureID = nil
            self.appState.setPhase(.error(self.uiText("選択テキストの取得がタイムアウトしました")))
            self.hud.flashError()
            self.scheduleHUDHideAfterError()
            self.clearAICommandCaptureTimeout(for: captureID)
        }
    }

    private func clearAICommandCaptureTimeout(for captureID: UUID? = nil) {
        if let captureID,
           let activeCaptureID = aiCommandCaptureID,
           activeCaptureID != captureID {
            return
        }
        aiCommandCaptureTimeoutTask?.cancel()
        aiCommandCaptureTimeoutTask = nil
    }

    private func beginRecording(session: VoiceSession) {
        recordingStartTask?.cancel()
        clearRecordingStartTimeout()
        activeVoiceSession = session
        recordingStartTaskSessionID = session.id
        scheduleRecordingStartTimeout(for: session)
        let recordingRequestedAt = Date()
        AppLog.shared.info("[Telemetry] recording_requested session=\(session.id.uuidString) mode=\(session.mode.rawValue)")

        recordingStartTask = Task {
            defer {
                if self.recordingStartTaskSessionID == session.id {
                    self.recordingStartTask = nil
                    self.recordingStartTaskSessionID = nil
                }
            }
            do {
                try await waitForWarmUpBeforeRecording()
            } catch {
                guard ownsStartingSession(session) else { return }
                AppLog.shared.warn("音声認識エンジンの準備に失敗しました")
                finishStartingSessionWithError(
                    session,
                    message: uiText("音声認識エンジンを準備できませんでした。権限と音声モデルを確認して、もう一度試してください。")
                )
                return
            }

            guard ownsStartingSession(session) else { return }
            AppLog.shared.info(String(
                format: "[Telemetry] recording_speech_ready session=%@ elapsedMs=%.0f",
                session.id.uuidString,
                Date().timeIntervalSince(recordingRequestedAt) * 1_000
            ))

            let granted = await audioRecorder.requestMicrophonePermission()
            guard ownsStartingSession(session) else { return }
            guard granted else {
                finishStartingSessionWithError(session, message: uiText("マイクへのアクセスが許可されていません"))
                return
            }

            var didStartStreaming = false
            do {
                guard ownsStartingSession(session) else { return }
                let streamID = session.handsFreeSendSession?.snapshot.streamID ?? session.id
                // 通常モード・AIに指示では暫定結果の観測が不要。MainActorのホットパスに
                // 何も載せないため、ハンズフリー送信のsessionだけへ配線する。
                let partialTextObserver: ((UUID, String, Bool) -> Void)?
                if session.handsFreeSendSession != nil {
                    partialTextObserver = { [weak self] resultStreamID, partialText, isFinal in
                        self?.handleHandsFreeSendPartialText(
                            partialText,
                            streamID: resultStreamID,
                            isFinal: isFinal
                        )
                    }
                } else {
                    partialTextObserver = nil
                }
                let format = try await transcriptionEngine.startStreaming(
                    streamID: streamID,
                    onPartialText: partialTextObserver
                )
                didStartStreaming = true
                AppLog.shared.info(String(
                    format: "[Telemetry] recording_analyzer_ready session=%@ stream=%@ elapsedMs=%.0f",
                    session.id.uuidString,
                    streamID.uuidString,
                    Date().timeIntervalSince(recordingRequestedAt) * 1_000
                ))
                guard ownsStartingSession(session) else {
                    _ = await transcriptionEngine.stopStreaming(streamID: streamID)
                    return
                }
                // AudioRecorderの直列消費TaskはMainActor外で走る。ここで`self`を捕まえて
                // `appendAudio`（`@MainActor`）を呼ぶとバッファ毎にホップが戻ってしまうため、
                // その録音のcontinuationに束縛済みで、どのスレッドからでも呼べる受け口を使う。
                // 直列消費のままなので到着順は保たれる。
                audioRecorder.onBuffer = transcriptionEngine.makeAudioSink()
                let appState = self.appState
                audioRecorder.onLevel = { level in
                    // 音量表示だけはUI状態なのでMainActorへ戻す必要がある。
                    // `publishAudioLevel` が間引くので、`@Published` の書き込みと
                    // それに伴うHUD全体の再評価はバッファ毎には起こらない。
                    Task { @MainActor in
                        appState.publishAudioLevel(level, for: session.id)
                    }
                }
                guard ownsStartingSession(session) else {
                    _ = await transcriptionEngine.stopStreaming(streamID: streamID)
                    return
                }
                guard RecordingStartSafetyPolicy.decision(
                    isSecureInputEnabled: IsSecureEventInputEnabled()
                ) == .allow else {
                    finishStartingSessionWithError(
                        session,
                        message: uiText("安全な入力が有効な間は録音を開始できません。パスワード入力などを閉じてから、もう一度試してください。")
                    )
                    return
                }
                try await audioRecorder.start(
                    targetFormat: format,
                    preferredMicrophoneUID: settingsStore.settings.preferredMicrophoneUID,
                    correlationID: session.id.uuidString
                )
                clearRecordingStartTimeout(for: session)
                appState.recordingStartedAt = Date()
                appState.setPhase(.recording)
                appState.beginAudioLevelSession(session.id)
                menuBarIconName = "mic.fill.badge.plus"
                if session.mode == .aiCommand {
                    hud.showAICommandState(.recording)
                } else if let handsFreeSendSession = session.handsFreeSendSession {
                    handsFreeSendSession.markRecordingStarted()
                    hud.showHandsFreeSendState(.recording)
                } else {
                    hud.show()
                }
                AppLog.shared.info(String(
                    format: "[Telemetry] recording_started session=%@ mode=%@ elapsedMs=%.0f",
                    session.id.uuidString,
                    session.mode.rawValue,
                    Date().timeIntervalSince(recordingRequestedAt) * 1_000
                ))
                scheduleAutoStopIfNeeded()
            } catch {
                if didStartStreaming {
                    let streamID = session.handsFreeSendSession?.snapshot.streamID ?? session.id
                    _ = await transcriptionEngine.stopStreaming(streamID: streamID)
                }
                guard ownsStartingSession(session) else { return }
                AppLog.shared.warn("録音開始に失敗しました")
                finishStartingSessionWithError(
                    session,
                    message: uiText("録音を開始できませんでした。マイクの権限と接続を確認して、もう一度試してください。")
                )
            }
        }
    }

    private func scheduleRecordingStartTimeout(for session: VoiceSession) {
        clearRecordingStartTimeout()
        recordingStartTimeoutSessionID = session.id
        recordingStartTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.recordingStartTimeoutSessionID == session.id,
                  self.ownsStartingSession(session) else { return }
            AppLog.shared.warn("録音開始が12秒以内に完了しなかったため中断します")
            self.finishStartingSessionWithError(session, message: self.uiText("録音の開始がタイムアウトしました"))
        }
    }

    private func clearRecordingStartTimeout(for session: VoiceSession? = nil) {
        if let session, recordingStartTimeoutSessionID != session.id {
            return
        }
        recordingStartTimeoutTask?.cancel()
        recordingStartTimeoutTask = nil
        recordingStartTimeoutSessionID = nil
    }

    private func finishStartingSessionWithError(_ session: VoiceSession, message: String) {
        guard activeVoiceSession?.id == session.id else { return }
        session.cancel()
        if recordingStartTaskSessionID == session.id {
            recordingStartTask?.cancel()
            recordingStartTask = nil
            recordingStartTaskSessionID = nil
        }
        clearRecordingStartTimeout(for: session)
        clearPendingNormalHoldState()
        clearHandsFreeSendTriggerCandidate()
        activeVoiceSession = nil
        appState.setPhase(.error(message))
        hud.clearHandsFreeSendState()
        hud.flashError()
        scheduleHUDHideAfterError()
        Task {
            await audioRecorder.stop()
            let streamID = session.handsFreeSendSession?.snapshot.streamID ?? session.id
            _ = await transcriptionEngine.stopStreaming(streamID: streamID)
        }
    }

    /// Secure InputではSpaceのkeyDownだけが隠れ、modifierイベントだけが届くことがある。
    /// 入口ごとに先に止め、selection／clipboard読取りやsession生成を始めない。
    private func canStartRecordingOutsideSecureInput() -> Bool {
        guard RecordingStartSafetyPolicy.decision(
            isSecureInputEnabled: IsSecureEventInputEnabled()
        ) == .allow else {
            invalidateAICommandWebRetry(.pendingAndRunning)
            clearPendingNormalHoldState()
            clearHandsFreeSendTriggerCandidate()
            AppLog.shared.info("[Telemetry] recording_start_blocked reason=secure_input")
            // Secure Input拒否はsessionを作らず、次の操作をbusy扱いにしない。HUDだけを
            // 非活性のエラー表示にして、appのpipelineはidleのまま保つ。
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.clearHandsFreeSendState()
            hud.flashError()
            return false
        }
        return true
    }

    /// 録音開始時に取る、明示されたAI結果を外部入力先へ送るための同意snapshot。
    /// 送出時にも同じ条件を再確認するため、処理中にONへ変えて権限を広げることはない。
    private func aiCommandExplicitInsertionAllowedAtCurrentSettings() -> Bool {
        let compatibility = settingsStore.settings.externalAppCompatibilitySettings
        return compatibility.enabled && compatibility.autoReplaceAICommandSelection
    }

    private func ownsStartingSession(_ session: VoiceSession) -> Bool {
        !Task.isCancelled
            && !session.isCancelled
            && activeVoiceSession?.id == session.id
            && appState.phase == .starting
    }

    /// autoStopSeconds > 0 の場合、指定秒数後に自動停止して通常処理へ進むタイマーをセットする。
    private func scheduleAutoStopIfNeeded() {
        autoStopTask?.cancel()
        let seconds = settingsStore.settings.effectiveAutoStopSeconds
        guard seconds > 0 else { return }

        autoStopTask = Task { [weak self] in
            if seconds > 10 {
                try? await Task.sleep(nanoseconds: UInt64(seconds - 10) * 1_000_000_000)
                guard !Task.isCancelled, let self, self.appState.phase == .recording else { return }
                if self.activeVoiceSession?.mode == .aiCommand {
                    self.hud.showAICommandState(.recordingEndingSoon)
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            guard self.appState.phase == .recording else { return }
            AppLog.shared.info("自動停止タイマー超過（\(seconds)秒）。録音を停止します")
            if let session = self.activeVoiceSession,
               session.handsFreeSendSession != nil {
                _ = self.requestHandsFreeSendStop(
                    for: session,
                    intent: .insertOnly,
                    evidence: .autoStop
                )
            } else {
                self.stopRecordingAndProcess()
            }
        }
    }

    private func stopRecordingAndProcess() {
        guard appState.phase == .recording, let session = activeVoiceSession else { return }
        // 通常モードはWeb入力欄のAX可観測性に依存させず、前面アプリだけを保存する。
        // AIに指示の選択置換は従来どおり厳格なAX対象を要求する。
        //
        // ハンズフリー送信もここで取り直す。以前は録音開始時（`handleHandsFreeSendStart`）に
        // 固定していたため、AX情報が発話全体の長さ（数秒〜数十秒）ぶん古くなり、
        // `replaceSelection` が `.unconfirmed` を返しやすかった。そうなると再確認の
        // 待機（80+200+400ms）や互換貼り付けの待機（150+200ms）が積み上がり、
        // ハンズフリーだけが通常モードより目に見えて遅くなっていた（2026-07-30の実機報告）。
        //
        // **受け入れたトレードオフ（ユーザー承認済み・2026-07-31）**: 発話中に別の欄へ
        // フォーカスを移すと、移した先へ入力される（従来は話し始めた欄へ戻った）。
        // ハンズフリーは手を離して使う前提で、発話中のフォーカス変更はまれと判断した。
        // **これは不具合ではないので、元に戻さないこと。**
        //
        // 出力先の権威は録音停止時。取得失敗時にも開始時のtargetを残すと、録音中に
        // フォーカスが変わった後に古い場所へ挿入し得るため、nilで明示的に上書きする。
        // 外部互換または結果表示へ安全に退避する。
        if session.mode == .voiceInput {
            let stoppedTarget = NormalPasteTarget.capture()
            let stoppedDestination = InsertionDestination.capture()
            session.normalPasteTarget = stoppedTarget
            session.insertionDestination = stoppedDestination?.processIdentifier == stoppedTarget?.processIdentifier
                ? stoppedDestination
                : nil
        } else {
            // AI入力の選択本文は開始時の`selectedText`を不変のsourceとして保持する。
            // 出力先だけを停止時に捕捉し、完了時のフォーカス移動には追従しない。
            let stoppedTarget = NormalPasteTarget.capture()
            let stoppedDestination = InsertionDestination.capture()
            session.aiCommandOutputTarget = stoppedTarget
            session.aiCommandOutputDestination = stoppedDestination?.processIdentifier == stoppedTarget?.processIdentifier
                ? stoppedDestination
                : nil
        }
        autoStopTask?.cancel()
        autoStopTask = nil
        processingTask?.cancel()
        menuBarIconName = "mic"
        appState.recordingStartedAt = nil
        appState.setPhase(.transcribing)
        AppLog.shared.info("[Telemetry] recording_stopped session=\(session.id.uuidString) mode=\(session.mode.rawValue)")

        processingTaskSessionID = session.id
        processingTask = Task {
            defer {
                if self.processingTaskSessionID == session.id {
                    self.processingTask = nil
                    self.processingTaskSessionID = nil
                }
                if self.activeVoiceSession?.id == session.id {
                    self.activeVoiceSession = nil
                }
                if session.handsFreeSendSession != nil {
                    self.clearHandsFreeSendTriggerCandidate()
                    self.hud.clearHandsFreeSendState()
                }
            }

            let transcriptionStartedAt = Date()
            await audioRecorder.stop()
            let streamID = session.handsFreeSendSession?.snapshot.streamID ?? session.id
            let transcript = await transcriptionEngine.stopStreaming(streamID: streamID)
            AppLog.shared.info(String(
                format: "[Telemetry] transcription_final session=%@ elapsedMs=%.0f inputChars=%d",
                session.id.uuidString,
                Date().timeIntervalSince(transcriptionStartedAt) * 1_000,
                transcript.count
            ))
            if transcriptionEngine.didTimeOutDuringFinishStreaming {
                // 打ち切った本文は不完全な可能性があるため、不可逆な擬似送信はしない。
                session.handsFreeSendSession?.revokeSendAuthorization()
            }
            appState.lastTranscript = transcript

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if let handsFreeSession = session.handsFreeSendSession,
                   handsFreeSession.isVoiceTriggerSend {
                    appState.setPhase(.idle)
                    hud.clearHandsFreeSendState()
                    hud.hide()
                    presentNormalInputFallback(
                        handsFreeSession.voiceTriggerFallbackTranscript ?? transcriptionEngine.partialText,
                        notice: uiText("音声トリガー後の認識結果を安全に確定できなかったため、自動挿入・送信を中止しました。内容を確認してコピーしてください。")
                    )
                    return
                }
                appState.setPhase(.idle)
                hud.hide()
                return
            }

            let handsFreeResolution = resolveHandsFreeSendTranscript(
                transcript,
                for: session
            )
            switch handsFreeResolution {
            case .mismatch:
                appState.setPhase(.idle)
                hud.clearHandsFreeSendState()
                hud.hide()
                presentNormalInputFallback(
                    transcript,
                    notice: uiText("音声トリガーを安全に除去できなかったため、自動挿入・送信を中止しました。内容を確認してコピーしてください。")
                )
                return
            case .sendKeyOnly(let sendRequest):
                await dispatchHandsFreeSendKeyWithoutText(
                    request: sendRequest,
                    session: session
                )
                return
            case .pipeline(let transcriptForPipeline, let sendAfterInsert):
                await continueNormalPipeline(
                    transcript: transcript,
                    transcriptForPipeline: transcriptForPipeline,
                    session: session,
                    sendAfterInsert: sendAfterInsert
                )
            }
        }
    }

    private enum HandsFreeTranscriptResolution {
        case pipeline(transcript: String, sendAfterInsert: SendAfterInsertRequest?)
        /// トリガー句だけの発話。本文を挿入せず送信キーだけを送る。
        /// 入力なしで改行・送信したい場面のための経路。
        case sendKeyOnly(SendAfterInsertRequest)
        case mismatch
    }

    private func resolveHandsFreeSendTranscript(
        _ transcript: String,
        for session: VoiceSession
    ) -> HandsFreeTranscriptResolution {
        guard let handsFreeSession = session.handsFreeSendSession else {
            return .pipeline(transcript: transcript, sendAfterInsert: nil)
        }

        // 音声トリガー以外の停止でも、ユーザーはすでにトリガー句を言い終えている
        // ことがある。実機では「…、ストップ送信。」が本文に残ったまま送信された。
        // どの停止経路でも同じように除去する。
        let sanitizedTranscript = HandsFreeSendTriggerPolicy.sanitizeFinalTranscript(
            transcript,
            triggers: handsFreeSession.compiledTriggers
        )?.transcriptWithoutTrigger

        if handsFreeSession.sendAuthorizationRevoked {
            AppLog.shared.warn("event tapが無効化されたため、擬似送信は行わず挿入のみ実行します")
            return .pipeline(transcript: sanitizedTranscript ?? transcript, sendAfterInsert: nil)
        }

        // トリガー句だけの発話は、末尾のトリガー句を繰り返し剥がすと本文が空になる。
        // 挿入するものが無いので、送信キーだけを送る。
        let isTriggerOnly = HandsFreeSendTriggerPolicy.isTriggerOnlyUtterance(
            transcript,
            triggers: handsFreeSession.compiledTriggers
        )

        switch (handsFreeSession.claimedIntent, handsFreeSession.claimedEvidence) {
        case (.send, .voiceTrigger):
            if isTriggerOnly {
                AppLog.shared.info("トリガー句だけの発話のため、本文を挿入せず送信キーだけを送ります")
                return .sendKeyOnly(
                    makeHandsFreeSendRequest(for: session, handsFreeSession: handsFreeSession)
                )
            }
            // 暫定結果で検出したトリガー句が確定時に別語へ修正された場合は、
            // 本文の切り出しに責任を持てないため自動挿入・送信を中止する。
            guard let sanitizedTranscript else { return .mismatch }
            return .pipeline(
                transcript: sanitizedTranscript,
                sendAfterInsert: makeHandsFreeSendRequest(for: session, handsFreeSession: handsFreeSession)
            )
        case (.send, .stopHotkey):
            if isTriggerOnly {
                AppLog.shared.info("トリガー句だけの発話のため、本文を挿入せず送信キーだけを送ります")
                return .sendKeyOnly(
                    makeHandsFreeSendRequest(for: session, handsFreeSession: handsFreeSession)
                )
            }
            return .pipeline(
                transcript: sanitizedTranscript ?? transcript,
                sendAfterInsert: makeHandsFreeSendRequest(for: session, handsFreeSession: handsFreeSession)
            )
        case (.send, _):
            // send意図と対応しない証跡は内部不整合として扱い、本文だけを安全に挿入する。
            return .pipeline(transcript: sanitizedTranscript ?? transcript, sendAfterInsert: nil)
        case (.insertOnly, _), (nil, _):
            // 自動停止・HUD完了、または想定外の停止経路では本文だけを安全に挿入する。
            return .pipeline(transcript: sanitizedTranscript ?? transcript, sendAfterInsert: nil)
        }
    }

    private func makeHandsFreeSendRequest(
        for session: VoiceSession,
        handsFreeSession: HandsFreeSendSession
    ) -> SendAfterInsertRequest {
        SendAfterInsertRequest(
            sessionID: session.id,
            mode: session.mode,
            keyStroke: handsFreeSession.snapshot.settings.sendKey,
            externalCompatibilityEnabledAtRecordingStart: handsFreeSession.snapshot.externalCompatibilityEnabledAtRecordingStart,
            externalCompatibilityAutoSendEnabledAtRecordingStart: handsFreeSession.snapshot.settings.allowExternalAutoSend
        )
    }

    private func continueNormalPipeline(
        transcript: String,
        transcriptForPipeline: String,
        session: VoiceSession,
        sendAfterInsert: SendAfterInsertRequest?
    ) async {

        if session.mode == .aiCommand {
            saveAICommandTranscriptIfNeeded(
                transcript,
                settings: session.aiCommandSettings,
                inputSource: session.inputSource
            )
        }

        guard !Task.isCancelled, !session.isCancelled else {
            appState.setPhase(.idle)
            hud.clearHandsFreeSendState()
            hud.hide()
            AppLog.shared.info("処理キャンセル: 文字起こし後に停止")
            return
        }

        if session.mode == .aiCommand {
            await processAICommand(transcript: transcript, session: session)
            return
        }

        var cleanupDidFail = false
        var cleanupLatencyMs: Int?
        let textToInsert: String
        if settingsStore.settings.cleanupEnabled {
                appState.setPhase(.cleaning)
                let cleanupStartedAt = Date()
                AppLog.shared.info("整形開始: 入力\(transcript.count)字")
                let languagePreferences = settingsStore.settings.languagePreferences
                let directive = SpokenOutputLanguageDirective.parse(transcriptForPipeline)
                let transcriptForCleanup = directive?.transcriptWithoutDirective ?? transcriptForPipeline
                let outputLanguage = OutputLanguageResolution.resolve(
                    transcript: transcriptForPipeline,
                    savedPreference: languagePreferences.aiOutputLanguage,
                    sttLanguage: languagePreferences.sttLanguage
                )
                let customInstruction = NormalInputCustomInstructionPolicy.resolve(
                    handsFreeSendSnapshot: session.handsFreeSendSession?.snapshot,
                    liveCustomInstruction: settingsStore.settings.customInstruction
                )
                do {
                    textToInsert = try await cleanupEngine.cleanup(
                        rawTranscript: transcriptForCleanup,
                        customInstruction: customInstruction,
                        personalDictionary: personalDictionaryStore.enabledEntries,
                        promptLanguage: languagePreferences.sttLanguage,
                        outputLanguage: outputLanguage,
                        correlationID: session.id.uuidString
                    )
                    let elapsed = Date().timeIntervalSince(cleanupStartedAt)
                    cleanupLatencyMs = Int((elapsed * 1000).rounded())
                    guard !Task.isCancelled else {
                        appState.setPhase(.idle)
                        hud.hide()
                        AppLog.shared.info("処理キャンセル: AIアシスト後に停止")
                        return
                    }
                    AppLog.shared.info(String(format: "整形成功: %.2f秒, 出力%d字", elapsed, textToInsert.count))
                    consecutiveUnclassifiedRPCFailures = 0
                    codexStatus = .connected
                } catch {
                    guard !Task.isCancelled else {
                        appState.setPhase(.idle)
                        hud.hide()
                        AppLog.shared.info("処理キャンセル: AIアシスト中に停止")
                        return
                    }
                    let elapsed = Date().timeIntervalSince(cleanupStartedAt)
                    cleanupLatencyMs = Int((elapsed * 1000).rounded())
                    AppLog.shared.warn(String(
                        format: "整形失敗(%.2f秒): %@ — 生トランスクリプトへフォールバック",
                        elapsed, Self.describeCleanupError(error)
                    ))
                    cleanupDidFail = true
                    updateCodexStatusOnFailure(error)
                    // ハンズフリーの送信意図がある場合、生STTをそのまま外部へ挿入・
                    // Return送信してはいけない。時間切れや接続失敗はコピー可能な結果
                    // 表示へ退避し、本文と送信の最終判断を利用者へ戻す。
                    if sendAfterInsert != nil {
                        appState.setPhase(.idle)
                        hud.clearHandsFreeSendState()
                        hud.hide()
                        presentNormalInputFallback(
                            transcriptForPipeline,
                            notice: uiText("AI整形を完了できなかったため、ハンズフリーでの自動挿入・送信を中止しました。内容を確認してコピーしてください。")
                        )
                        return
                    }
                    textToInsert = transcriptForPipeline
                }
            } else {
                textToInsert = transcriptForPipeline
            }
            guard !Task.isCancelled else {
                appState.setPhase(.idle)
                hud.hide()
                AppLog.shared.info("処理キャンセル: 挿入前に停止")
                return
            }
            appState.lastCleanedText = textToInsert
            await performNormalTextInsertion(
                textToInsert,
                cleanupDidFail: cleanupDidFail,
                cleanupLatencyMs: cleanupLatencyMs,
                normalTarget: session.normalPasteTarget,
                verificationDestination: session.insertionDestination,
                session: session,
                sendAfterInsert: sendAfterInsert
            )
    }

    private func performNormalTextInsertion(
        _ textToInsert: String,
        cleanupDidFail: Bool,
        cleanupLatencyMs: Int?,
        normalTarget: NormalPasteTarget?,
        verificationDestination: InsertionDestination?,
        session: VoiceSession,
        sendAfterInsert: SendAfterInsertRequest?
    ) async {
        guard ownsCurrentNormalProcessing(session) else { return }
        // 挿入・送信キーの本文照合・履歴・手動フォールバックが同じ文字列を見るよう、
        // ここで一度だけ不可視文字を除去する。TextInjector側の除去はこの後は冪等に働く。
        // 除去して空になった場合は元の文字列を渡し、拒否の判断はTextInjectorへ委ねる。
        let sanitizedTextToInsert = InvisibleCharacterSanitizer.sanitize(textToInsert)
        let textToInsert = sanitizedTextToInsert.isEmpty ? textToInsert : sanitizedTextToInsert
        appState.setPhase(.inserting)
        let insertStartedAt = Date()
        let insertionOutcome = await textInjector.insert(
            textToInsert,
            forNormalTarget: normalTarget,
            verificationDestination: verificationDestination,
            allowExternalCompatibility: settingsStore.settings.externalAppCompatibilitySettings.enabled,
            allowScopedClipboardFallback: settingsStore.settings.externalAppCompatibilitySettings.allowScopedClipboardFallback,
            // 未確認Unicode本文中の改行が外部チャットで送信扱いになる余地を避ける。
            // 通常モードは許可し、HFS本文だけ結果表示へ戻す。
            allowUnverifiedMultilineText: sendAfterInsert == nil
        )
        let result = insertionOutcome.result
        guard ownsCurrentNormalProcessing(session) else {
            appState.setPhase(.idle)
            hud.hide()
            AppLog.shared.info("処理キャンセル: 挿入後・履歴保存前に停止")
            return
        }
        if NormalInputHistoryPolicy.shouldRecord(result) {
            let usesHandsFreeSendHistory = session.handsFreeSendSession != nil
            let currentSettings = settingsStore.settings
            recordInputHistoryIfNeeded(
                mode: usesHandsFreeSendHistory ? InputHistoryMode.handsFreeSend : InputHistoryMode.voiceInput,
                historyEnabled: usesHandsFreeSendHistory
                    ? currentSettings.handsFreeSendSettings.historyEnabled
                    : currentSettings.historyEnabled,
                historyRetentionDays: usesHandsFreeSendHistory
                    ? currentSettings.handsFreeSendSettings.historyRetentionDays
                    : currentSettings.historyRetentionDays,
                textToInsert: textToInsert,
                cleanupDidFail: cleanupDidFail,
                insertResult: result,
                cleanupLatencyMs: cleanupLatencyMs
            )
        } else {
            // 種別を出さないと切り分けができない。Safariの不具合調査では、失敗した
            // resultがログに残らないことが原因特定を長引かせた（2026-07-30）。
            AppLog.shared.warn(
                "挿入準備を確認できなかったため出力履歴は保存しません（result=\(Self.describeInsertionResult(result))）"
            )
        }
        logNormalInputCompletion(
            result: result,
            cleanupLatencyMs: cleanupLatencyMs,
            insertionStartedAt: insertStartedAt
        )
        AppLog.shared.info(String(
            format: "挿入処理応答: %.2f秒, 出力%d字",
            Date().timeIntervalSince(insertStartedAt),
            textToInsert.count
        ))

        let sendDispatchResult = await dispatchSendKeyIfRequested(
            request: sendAfterInsert,
            eligibility: insertionOutcome.sendEligibility,
            textToInsert: textToInsert,
            normalTarget: normalTarget,
            verificationDestination: verificationDestination,
            session: session
        )
        guard ownsCurrentNormalProcessing(session) else {
            appState.setPhase(.idle)
            hud.hide()
            AppLog.shared.info("処理キャンセル: 擬似送信待機中に停止")
            return
        }
        let sendWasBlocked = sendDispatchResult.map { $0 != .sent } ?? false

        switch result {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted:
            // 挿入バー1ショット(spring 0.35s)の視認保証: 最低500ms表示してから閉じる（§1.4）
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard ownsCurrentNormalProcessing(session) else { return }
            appState.setPhase(.idle)
            AppLog.shared.info(cleanupDidFail ? "挿入完了（整形は失敗し生テキストを挿入）" : "整形完了・挿入完了")
            if cleanupDidFail {
                flashMenuBarWarning()
                hud.flashWarning(durationSeconds: 1.5)
                return
            }
            finishSuccessfulNormalInsertion(sendWasBlocked: sendWasBlocked)
        case .externalCompatibilityDisabled:
            appState.setPhase(.idle)
            hud.hide()
            presentExternalCompatibilityGuide(
                returnToProcessIdentifier: normalTarget?.processIdentifier,
                deferredNormalOutput: textToInsert
            )
        case .clipboardMayHaveBeenLost:
            appState.setPhase(.idle)
            hud.hide()
            presentNormalInputFallback(
                textToInsert,
                notice: uiText("以前のクリップボード内容が失われた可能性があります。必要な内容を確認してください。")
            )
        case .secureInputBlocked, .manualFallbackRequired, .insertionUnconfirmed, .failed,
             // クリップボードバリアントの3ケースは「AIに指示」専用経路（`insertAICommandOutput`）
             // だけが返す。通常モードの`insert(...)`からは構築されないため、ここには到達しない。
             .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified,
             .clipboardVariantPasteMayHaveLostClipboard:
            appState.setPhase(.idle)
            hud.hide()
            presentNormalInputFallback(textToInsert)
        }
    }

    /// 現在の処理タスクだけが擬似送信とHUD更新を所有できる。
    private func ownsCurrentNormalProcessing(_ session: VoiceSession) -> Bool {
        !Task.isCancelled
            && !session.isCancelled
            && processingTaskSessionID == session.id
            && activeVoiceSession?.id == session.id
    }

    /// トリガー句だけの発話に対して、本文を挿入せず送信キーだけを送る。
    /// AI整形も履歴保存も行わない。入力なしで改行・送信したい場面のための経路。
    private func dispatchHandsFreeSendKeyWithoutText(
        request: SendAfterInsertRequest,
        session: VoiceSession
    ) async {
        // 所有権の確認より先にphaseを触ると、別sessionが処理中の場合にその状態を
        // 踏み潰す。所有していることを確かめてから遷移させる。
        guard ownsCurrentNormalProcessing(session),
              let handsFreeSession = session.handsFreeSendSession else {
            return
        }
        defer {
            // 待機中に所有権を失っていたら、後続sessionのphaseを壊さない。
            if ownsCurrentNormalProcessing(session) {
                appState.setPhase(.idle)
                hud.clearHandsFreeSendState()
                hud.hide()
            }
        }
        appState.setPhase(.inserting)
        guard let normalTarget = session.normalPasteTarget,
              let destination = session.insertionDestination else {
            AppLog.shared.warn("送信キーのみの送出を中止: 挿入先アプリを特定できません")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return
        }
        guard !handsFreeSession.sendAuthorizationRevoked else {
            AppLog.shared.warn("送信キーのみの送出を中止: 送信権限が取り消されています")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return
        }
        let currentSettings = settingsStore.settings.handsFreeSendSettings
        guard SendKeyDispatchPolicy.shouldDispatch(
            request: request,
            eligibility: .triggerOnlyValidated,
            currentSettings: currentSettings,
            externalCompatibilityEnabled: settingsStore.settings.externalAppCompatibilitySettings.enabled
        ) else {
            AppLog.shared.warn("送信キーのみの送出を安全条件で中止")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return
        }
        guard destination.initialState != .nonEditable,
              destination.currentFocusMatchesCapturedEditableElement() else {
            AppLog.shared.warn("送信キーのみの送出を中止: 停止時と同じ編集可能targetを確認できません")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return
        }
        guard ownsCurrentNormalProcessing(session),
              !handsFreeSession.sendAuthorizationRevoked,
              SendKeyDispatchPolicy.shouldDispatch(
                  request: request,
                  eligibility: .triggerOnlyValidated,
                  currentSettings: settingsStore.settings.handsFreeSendSettings,
                  externalCompatibilityEnabled: settingsStore.settings.externalAppCompatibilitySettings.enabled
              ) else {
            AppLog.shared.warn("送信キーのみの送出を送出直前の安全条件で中止")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return
        }
        showHandsFreeSendDispatchFeedback(.armed, for: session)
        let result = textInjector.postSendKey(
            request.keyStroke,
            forNormalTarget: normalTarget,
            verificationDestination: destination,
            verification: .exactCapturedEditableField
        )
        switch result {
        case .sent:
            AppLog.shared.info("本文なしで送信キーを送出")
            showHandsFreeSendDispatchFeedback(.posted, for: session)
            try? await Task.sleep(nanoseconds: 500_000_000)
        case .notAuthorized, .cancelledOrStale, .missingTarget,
             .secureInputBlocked, .targetChanged, .focusedElementOrTextChanged, .eventCreationFailed:
            AppLog.shared.warn("本文なしの送信キーを送出できなかった")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
        }
    }

    private func dispatchSendKeyIfRequested(
        request: SendAfterInsertRequest?,
        eligibility: SendAfterInsertEligibility,
        textToInsert: String,
        normalTarget: NormalPasteTarget?,
        verificationDestination: InsertionDestination?,
        session: VoiceSession
    ) async -> SendKeyDispatchResult? {
        guard let request else { return nil }
        guard request.sessionID == session.id else { return .cancelledOrStale }
        guard ownsCurrentNormalProcessing(session) else { return .cancelledOrStale }
        guard let handsFreeSession = session.handsFreeSendSession,
              !handsFreeSession.sendAuthorizationRevoked else {
            AppLog.shared.warn("擬似送信を中止: 送信権限が取り消されています")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }
        let currentSettings = settingsStore.settings.handsFreeSendSettings
        let externalCompatibilityEnabled = settingsStore.settings.externalAppCompatibilitySettings.enabled
        guard SendKeyDispatchPolicy.shouldDispatch(
            request: request,
            eligibility: eligibility,
            currentSettings: currentSettings,
            externalCompatibilityEnabled: externalCompatibilityEnabled
        ) else {
            AppLog.shared.warn("擬似送信を安全条件で中止")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }
        // 限定Cmd-V経路は本文を入れてもReturnを送らない。Unicodeは本文反映をAXで
        // 証明できないため、停止時と同一の編集可能AX要素をもう一度確認できる場合だけ。
        guard let verificationDestination else {
            AppLog.shared.warn("擬似送信を中止: 本文反映を確認できない外部入力経路です")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }
        let verification: SendKeyVerificationMode
        switch eligibility {
        case .directAXVerified:
            verification = .confirmedInsertedText(textToInsert)
        case .unicodeSubmitted:
            verification = .exactCapturedEditableField
        case .triggerOnlyValidated, .notEligible:
            AppLog.shared.warn("擬似送信を中止: この本文入力経路ではReturnを送出しません")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }

        showHandsFreeSendDispatchFeedback(.armed, for: session)

        // 送出直前にセッション・設定・前面アプリを再評価する。
        guard ownsCurrentNormalProcessing(session) else { return .cancelledOrStale }
        guard !handsFreeSession.sendAuthorizationRevoked else {
            AppLog.shared.warn("擬似送信を送出直前の安全条件で中止: 送信権限が取り消されています")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }
        let liveSettings = settingsStore.settings.handsFreeSendSettings
        guard SendKeyDispatchPolicy.shouldDispatch(
            request: request,
            eligibility: eligibility,
            currentSettings: liveSettings,
            externalCompatibilityEnabled: settingsStore.settings.externalAppCompatibilitySettings.enabled
        ) else {
            AppLog.shared.warn("擬似送信を送出直前の安全条件で中止")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }
        guard let normalTarget else {
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .missingTarget
        }

        // 同じMainActor turn内でも、送出条件はReturnの直前まで明示しておく。本文だけ
        // を挿入する経路と異なり、擬似Returnは別の場所へ届くと不可逆だからである。
        guard !handsFreeSession.sendAuthorizationRevoked else {
            AppLog.shared.warn("擬似送信をReturn直前の安全条件で中止: 送信権限が取り消されています")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
            return .notAuthorized
        }

        let result = textInjector.postSendKey(
            request.keyStroke,
            forNormalTarget: normalTarget,
            verificationDestination: verificationDestination,
            verification: verification
        )
        switch result {
        case .sent:
            AppLog.shared.info("擬似送信を送出")
            showHandsFreeSendDispatchFeedback(.posted, for: session)
        case .notAuthorized, .cancelledOrStale, .missingTarget,
             .secureInputBlocked, .targetChanged, .focusedElementOrTextChanged, .eventCreationFailed:
            AppLog.shared.warn("擬似送信を送出できなかった")
            showHandsFreeSendDispatchFeedback(.skipped, for: session)
        }
        return result
    }

    private func showHandsFreeSendDispatchFeedback(
        _ feedback: SendDispatchFeedback,
        for session: VoiceSession
    ) {
        guard session.handsFreeSendSession != nil else { return }
        hud.showHandsFreeSendState(HandsFreeSendHUDFeedbackPolicy.state(for: feedback))
        if feedback == .skipped {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.activeVoiceSession?.id == session.id else { return }
                self.hud.clearHandsFreeSendState()
            }
        }
    }

    /// 「AIに指示」の挿入結果をログ用の短い識別子にする。本文は含めない。
    /// `describeInsertionResult`は`TextInjectorResult`用で、`insertAICommandOutput`が返す
    /// `SafeTextInjectionResult`からは呼べないため、対応する写像をここに持つ。
    /// **Confirmed と Unverified を必ず別の識別子にする。** 同じにすると、
    /// 貼り付けが反映されなかった事実が事後に判別できなくなる。
    static func describeSafeInsertionResult(_ result: SafeTextInjectionResult) -> String {
        switch result {
        case .inserted: return "inserted"
        case .unicodeSubmitted: return "unicode_submitted"
        case .scopedClipboardFallbackSubmitted: return "scoped_clipboard_submitted"
        case .clipboardVariantPasteConfirmed: return "clipboard_variant_confirmed"
        case .clipboardVariantPasteSubmittedUnverified: return "clipboard_variant_unverified"
        case .clipboardVariantPasteMayHaveLostClipboard: return "clipboard_variant_clipboard_lost"
        case .externalCompatibilityDisabled: return "external_compatibility_disabled"
        case .manualFallbackRequired: return "manual_fallback_required"
        case .insertionUnconfirmed: return "insertion_unconfirmed"
        case .nonEditable: return "non_editable"
        case .selectionNotCollapsed: return "selection_not_collapsed"
        case .targetChanged: return "target_changed"
        case .secureInputBlocked: return "secure_input_blocked"
        case .failed(let error): return "failed(\(type(of: error)))"
        }
    }

    /// 失敗した挿入結果をログ用の短い識別子にする。本文は含めない。
    static func describeInsertionResult(_ result: TextInjectorResult) -> String {
        switch result {
        case .inserted: return "inserted"
        case .unicodeSubmitted: return "unicode_submitted"
        case .scopedClipboardFallbackSubmitted: return "scoped_clipboard_submitted"
        case .clipboardVariantPasteConfirmed: return "clipboard_variant_confirmed"
        case .clipboardVariantPasteSubmittedUnverified: return "clipboard_variant_unverified"
        case .clipboardVariantPasteMayHaveLostClipboard: return "clipboard_variant_clipboard_lost"
        case .externalCompatibilityDisabled: return "external_compatibility_disabled"
        case .manualFallbackRequired: return "manual_fallback_required"
        case .clipboardMayHaveBeenLost: return "clipboard_may_have_been_lost"
        case .insertionUnconfirmed: return "insertion_unconfirmed"
        case .secureInputBlocked: return "secure_input_blocked"
        case .failed(let error): return "failed(\(type(of: error)))"
        }
    }

    private func finishSuccessfulNormalInsertion(sendWasBlocked _: Bool) {
        // Unicode後にReturnを省略するのは通常仕様であり、本文入力を失敗扱いにしない。
        // HFSの短い非テキスト表示はdispatch側で完結させる。
        hud.hide()
    }

    private func saveAICommandTranscriptIfNeeded(
        _ transcript: String,
        settings: AICommandSettings?,
        inputSource: AICommandInputSource
    ) {
        guard let settings, settings.historyEnabled else { return }
        let modelSlug = settings.modelSettings.mode == .cli ? nil : settings.modelSettings.selectedModelSlug
        let effort = settings.modelSettings.mode == .cli ? nil : settings.modelSettings.selectedReasoningEffort
        let entry = InputHistoryEntry.aiCommandTranscript(
            transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            modelSlug: modelSlug,
            reasoningEffort: effort,
            inputSource: inputSource
        )
        inputHistoryStore.append(entry, retentionDays: settings.historyRetentionDays)
    }

    /// 結果window、設定変更、録音開始、Secure Input、非アクティブ化の全経路で呼ぶ。
    /// tokenと確認後taskはメモリだけで、本文を再取得・再読取しない。
    private func invalidateAICommandWebRetry(_ scope: AICommandWebRetryInvalidationScope) {
        invalidatePendingAICommandWebRetryToken(closeWindow: true)

        guard scope.cancelsRunningRetry, confirmedAICommandWebRetryID != nil else { return }
        confirmedAICommandWebRetryTask?.cancel()
        confirmedAICommandWebRetryTask = nil
        confirmedAICommandWebRetryID = nil
        appState.setPhase(.idle)
        hud.clearAICommandState()
        hud.hide()
        Task { [weak self] in
            await self?.aiCommandEngine.cancelActive()
        }
    }

    /// token期限・設定変更・window閉鎖を一箇所で片付ける。windowを閉じることでpayloadが
    /// 保持するaction closureも解放し、本文を持つtokenを90秒を超えて残さない。
    private func invalidatePendingAICommandWebRetryToken(closeWindow: Bool) {
        let windowID = pendingAICommandWebRetryWindowID
        pendingAICommandWebRetryToken?.invalidate()
        pendingAICommandWebRetryToken = nil
        pendingAICommandWebRetryExpiryTask?.cancel()
        pendingAICommandWebRetryExpiryTask = nil
        pendingAICommandWebRetryWindowID = nil
        if closeWindow, let windowID {
            aiCommandResultWindows.dismiss(id: windowID)
        }
    }

    private func discardAICommandWebRetryToken(_ token: AICommandWebRetryToken) {
        guard pendingAICommandWebRetryToken === token else { return }
        invalidatePendingAICommandWebRetryToken(closeWindow: false)
    }

    private func presentAICommandWebConfirmation(
        request: AICommandRequest,
        spokenInstruction: String,
        inputSource: AICommandInputSource
    ) {
        invalidatePendingAICommandWebRetryToken(closeWindow: true)
        let token = AICommandWebRetryToken(request: request, inputSource: inputSource)
        pendingAICommandWebRetryToken = token
        let payload = AICommandResultPayload(
            spokenInstruction: spokenInstruction,
            selectedText: nil,
            answer: uiText("この質問は外部情報の調査が必要になる可能性があります。Webで再試行しますか？"),
            sources: [],
            title: "Web検索",
            notice: uiText("捕捉済み本文の必要部分が検索語に含まれることがあります。現在のクリップボードは読み直さず、結果は別ウィンドウに表示します。"),
            answerSectionTitle: "確認",
            showsCopyButton: false,
            actions: [
                AICommandResultAction(
                    id: "retry_web",
                    title: "Webで再試行",
                    style: .primary,
                    handler: { [weak self, token] in
                        self?.consumeAICommandWebRetryToken(token, spokenInstruction: spokenInstruction)
                    }
                ),
            ],
            presentation: .nonactivatingConfirmation,
            onDismiss: { [weak self, weak token] in
                guard let token else { return }
                self?.discardAICommandWebRetryToken(token)
            }
        )
        pendingAICommandWebRetryWindowID = payload.id
        pendingAICommandWebRetryExpiryTask = Task { @MainActor [weak self, weak token] in
            do {
                try await Task.sleep(nanoseconds: UInt64(AICommandWebRetryToken.lifetimeMilliseconds) * 1_000_000)
            } catch {
                return
            }
            guard let self,
                  let token,
                  self.pendingAICommandWebRetryToken === token else { return }
            self.invalidatePendingAICommandWebRetryToken(closeWindow: true)
        }
        aiCommandResultWindows.show(payload)
    }

    private func consumeAICommandWebRetryToken(
        _ token: AICommandWebRetryToken,
        spokenInstruction: String
    ) {
        guard pendingAICommandWebRetryToken === token else { return }
        let currentSettings = settingsStore.settings.aiCommandSettings
        guard let request = token.consumeIfValid(
            webSearchEnabled: currentSettings.webSearchEnabled,
            modelSettings: currentSettings.modelSettings,
            secureInputEnabled: IsSecureEventInputEnabled()
        ) else {
            invalidatePendingAICommandWebRetryToken(closeWindow: false)
            return
        }
        let inputSource = token.capturedInputSource
        // handlerはwindowを閉じる前に呼ばれる。先にtimerとpayload所有を外す。
        invalidatePendingAICommandWebRetryToken(closeWindow: false)
        startConfirmedAICommandWebRetry(
            request: request,
            spokenInstruction: spokenInstruction,
            inputSource: inputSource
        )
    }

    private func startConfirmedAICommandWebRetry(
        request: AICommandRequest,
        spokenInstruction: String,
        inputSource: AICommandInputSource
    ) {
        let retryID = UUID()
        confirmedAICommandWebRetryID = retryID
        aiCommandDidObserveWebSearch = false
        appState.setPhase(.cleaning)
        hud.setAICommandInputSource(inputSource)
        hud.showAICommandState(.processing)

        confirmedAICommandWebRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.confirmedAICommandWebRetryID == retryID {
                    self.confirmedAICommandWebRetryID = nil
                    self.confirmedAICommandWebRetryTask = nil
                }
            }
            do {
                let result = try await self.aiCommandEngine.execute(
                    request,
                    options: .confirmedSelectedSource
                ) { [weak self] active in
                    guard let self, self.confirmedAICommandWebRetryID == retryID else { return }
                    if active { self.aiCommandDidObserveWebSearch = true }
                    self.hud.showAICommandState(active ? .webSearching : .processing)
                }
                guard !Task.isCancelled, self.confirmedAICommandWebRetryID == retryID else { return }
                self.appState.setPhase(.idle)
                self.hud.clearAICommandState()
                self.hud.hide()
                let answer: String
                if result.outcome.kind == .requiresWeb {
                    answer = self.uiText("Web検索を完了できませんでした。少し待ってから、もう一度お試しください。")
                } else {
                    answer = result.outcome.text
                }
                self.showAICommandResult(
                    instruction: spokenInstruction,
                    selectedText: nil,
                    answer: answer,
                    sources: result.sources
                )
            } catch is CancellationError {
                guard self.confirmedAICommandWebRetryID == retryID else { return }
                self.appState.setPhase(.idle)
                self.hud.clearAICommandState()
                self.hud.hide()
            } catch {
                guard !Task.isCancelled, self.confirmedAICommandWebRetryID == retryID else { return }
                self.appState.setPhase(.idle)
                self.hud.clearAICommandState()
                self.hud.hide()
                self.showAICommandResult(
                    instruction: spokenInstruction,
                    selectedText: nil,
                    answer: self.uiText("Web検索を完了できませんでした。少し待ってから、もう一度お試しください。"),
                    sources: []
                )
            }
        }
    }

    private func processAICommand(transcript: String, session: VoiceSession) async {
        guard let settings = session.aiCommandSettings else {
            finishAICommandWithFailure(ownerID: session.id)
            return
        }
        let languagePreferences = settingsStore.settings.languagePreferences
        let directive = SpokenOutputLanguageDirective.parse(transcript)
        let instructionForAI = directive?.transcriptWithoutDirective ?? transcript
        let outputLanguage = OutputLanguageResolution.resolve(
            transcript: transcript,
            savedPreference: languagePreferences.aiOutputLanguage,
            sttLanguage: languagePreferences.sttLanguage
        )
        if let clarification = AICommandInputPreflight.localClarification(
            spokenInstruction: instructionForAI,
            selectedText: session.selectedText,
            language: languagePreferences.sttLanguage
        ) {
            guard !Task.isCancelled, !session.isCancelled, activeVoiceSession?.id == session.id else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            // 現在ページ・URL本文はアプリが取得していない。CodexやWeb検索を起動せず、
            // 通常の結果ウィンドウで対象不足を明示する。
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.hide()
            activeVoiceSession = nil
            showAICommandResult(
                instruction: transcript,
                selectedText: session.selectedText,
                answer: clarification,
                sources: []
            )
            return
        }
        appState.setPhase(.cleaning)
        hud.showAICommandState(.processing)
        aiCommandDidObserveWebSearch = false
        let request = AICommandRequest(
            spokenInstruction: instructionForAI,
            selectedText: session.selectedText,
            additionalInstruction: settings.additionalInstruction,
            personalDictionary: personalDictionaryStore.enabledEntries,
            modelSettings: settings.modelSettings,
            webSearchEnabled: settings.webSearchEnabled,
            promptLanguage: languagePreferences.sttLanguage,
            outputLanguage: outputLanguage
        )
        let webPolicy = AICommandEngine.webExecutionPolicy(for: request)

        do {
            let result = try await aiCommandEngine.execute(request) { [weak self] active in
                guard let self else { return }
                if active {
                    self.aiCommandDidObserveWebSearch = true
                }
                self.hud.showAICommandState(active ? .webSearching : .processing)
            }
            guard !Task.isCancelled, !session.isCancelled, activeVoiceSession?.id == session.id else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            switch result.outcome.kind {
            case .requiresWeb:
                switch AICommandRequiresWebPresentationPolicy.presentation(
                    webSearchEnabled: settings.webSearchEnabled,
                    webConfirmationAvailable: webPolicy.webConfirmationAvailable,
                    usedWebSearch: result.usedWebSearch
                ) {
                case .settingsGuide:
                    hud.showAICommandState(.webDisabled)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard ownsAICommandSession(session) else { return }
                    appState.setPhase(.idle)
                    hud.clearAICommandState()
                    hud.hide()
                    showWebDisabledGuide(spokenInstruction: transcript)
                case .confirmation:
                    appState.setPhase(.idle)
                    hud.clearAICommandState()
                    hud.hide()
                    activeVoiceSession = nil
                    presentAICommandWebConfirmation(
                        request: request,
                        spokenInstruction: transcript,
                        inputSource: session.inputSource
                    )
                case .retryWithoutNetworkFailure:
                    AppLog.shared.error("[AICommand] Web検索設定ONでWeb未開始のrequires_webを受信")
                    appState.setPhase(.idle)
                    hud.clearAICommandState()
                    hud.hide()
                    aiCommandResultWindows.show(AICommandResultPayload(
                        spokenInstruction: transcript,
                        selectedText: nil,
                        answer: uiText("処理を完了できませんでした。少し待ってから、もう一度お試しください。"),
                        sources: [],
                        title: "Web検索"
                    ))
                case .retryAfterWebFailure:
                    AppLog.shared.error("[AICommand] Web検索開始後のrequires_webを受信")
                    appState.setPhase(.idle)
                    hud.clearAICommandState()
                    hud.hide()
                    aiCommandResultWindows.show(AICommandResultPayload(
                        spokenInstruction: transcript,
                        selectedText: nil,
                        answer: uiText("Web検索を完了できませんでした。少し待ってから、もう一度お試しください。"),
                        sources: [],
                        title: "Web検索"
                    ))
                }
            default:
                // `kind`（内容の意味）と`destinationIntent`（音声で明示された届け先）を
                // ここで初めて組み合わせる。文字列の局所判定や旧語句リストは使わない。
                switch AICommandOutputRoutingPolicy.decision(
                    kind: result.outcome.kind,
                    destinationIntent: result.outcome.destinationIntent,
                    hasActualSource: session.selectedText != nil
                ) {
                case .showResult:
                    appState.setPhase(.idle)
                    hud.clearAICommandState()
                    hud.hide()
                    showAICommandResult(
                        instruction: transcript,
                        selectedText: session.selectedText,
                        answer: result.outcome.text,
                        sources: result.sources
                    )
                case .automaticSourceReplacement:
                    await insertAICommandOutput(
                        result.outcome.text,
                        instruction: transcript,
                        sources: result.sources,
                        session: session,
                        operation: .automaticSourceReplacement(
                            inputSource: session.inputSource,
                            hasActualSource: session.selectedText != nil
                        )
                    )
                case .explicitTargetInsertion:
                    // モデルが明示挿入を分類しても、録音開始時と送出直前の両方で
                    // 互換入力・直接挿入の同意が有効でなければ外部へ送らない。
                    guard session.aiCommandExplicitInsertionAllowedAtRecordingStart,
                          aiCommandExplicitInsertionAllowedAtCurrentSettings() else {
                        presentAICommandOutputResult(
                            result.outcome.text,
                            instruction: transcript,
                            session: session,
                            sources: result.sources,
                            notice: explicitTargetInsertionFallbackNotice()
                        )
                        return
                    }
                    await insertAICommandOutput(
                        result.outcome.text,
                        instruction: transcript,
                        sources: result.sources,
                        session: session,
                        operation: .explicitTargetInsertion
                    )
                }
            }
        } catch AICommandError.modelUnavailable(let slug) {
            guard !Task.isCancelled, !session.isCancelled else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            hud.showAICommandState(.failure)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard ownsAICommandSession(session) else { return }
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.hide()
            showAICommandResult(
                instruction: transcript,
                selectedText: session.selectedText,
                answer: uiFormat(
                    "選択したモデル（%@）は現在利用できません。AIに指示モードの設定で利用可能なモデルを選んでください。",
                    slug
                ),
                sources: []
            )
        } catch AICommandError.webUnavailable(_, let primaryCatalogConfirmed) {
            guard !Task.isCancelled, !session.isCancelled else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            if primaryCatalogConfirmed {
                if AICommandWebAvailabilityPersistencePolicy.shouldDisableSavedWebSetting(
                    primaryCatalogConfirmed: primaryCatalogConfirmed,
                    selectedModelStillMatches: settingsStore.settings.aiCommandSettings.modelSettings.selectedModelSlug
                        == settings.modelSettings.selectedModelSlug
                ) {
                    settingsStore.settings.aiCommandSettings.webSearchEnabled = false
                }
                hud.showAICommandState(.webDisabled)
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard ownsAICommandSession(session) else { return }
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                aiCommandResultWindows.show(AICommandResultPayload(
                    spokenInstruction: transcript,
                    selectedText: nil,
                    answer: uiText("選択したモデルがWeb検索に対応していないため、Web検索をオフにしました。AIに指示モードの設定でWeb検索に対応するモデルを選べます。"),
                    sources: [],
                    title: "Web検索",
                    showsSettingsButton: true
                ))
            } else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                aiCommandResultWindows.show(AICommandResultPayload(
                    spokenInstruction: transcript,
                    selectedText: nil,
                    answer: uiText("選択したモデルのWeb検索対応を現在確認できませんでした。Web検索の設定は変更していません。少し待ってから、もう一度お試しください。"),
                    sources: [],
                    title: "Web検索"
                ))
            }
        } catch AICommandError.unexpectedTool(let type) {
            AppLog.shared.error("AIに指示で許可されていないitemを停止: \(type)")
            guard !Task.isCancelled, !session.isCancelled else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            finishAICommandWithFailure(ownerID: session.id)
        } catch AICommandError.promptResourceMissing {
            AppLog.shared.error("[AICommand] プロンプトリソースを読み込めませんでした")
            guard !Task.isCancelled, !session.isCancelled else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            finishAICommandWithFailure(ownerID: session.id)
        } catch AICommandError.unsafeOutput {
            AppLog.shared.error("[AICommand] 安全ゲートが応答を拒否しました")
            guard !Task.isCancelled, !session.isCancelled, ownsAICommandSession(session) else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.hide()
            showAICommandResult(
                instruction: transcript,
                selectedText: session.selectedText,
                answer: uiText("AIの応答を安全に確認できなかったため、表示または挿入を中止しました。もう一度試してください。"),
                sources: []
            )
        } catch where aiCommandDidObserveWebSearch {
            AppLog.shared.warn("[AICommand] Web検索開始後に処理が失敗しました")
            guard !Task.isCancelled, !session.isCancelled else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            hud.showAICommandState(.failure)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard ownsAICommandSession(session) else { return }
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.hide()
            aiCommandResultWindows.show(AICommandResultPayload(
                spokenInstruction: transcript,
                selectedText: nil,
                answer: uiText("Web検索を完了できませんでした。少し待ってから、もう一度お試しください。"),
                sources: [],
                title: "Web検索"
            ))
        } catch {
            AppLog.shared.warn("[AICommand] Web検索開始前に処理が失敗しました")
            guard !Task.isCancelled, !session.isCancelled else {
                appState.setPhase(.idle)
                hud.clearAICommandState()
                hud.hide()
                return
            }
            finishAICommandWithFailure(ownerID: session.id)
        }
    }

    private func ownsAICommandSession(_ session: VoiceSession) -> Bool {
        !Task.isCancelled
            && !session.isCancelled
            && activeVoiceSession?.id == session.id
    }

    private func insertAICommandOutput(
        _ text: String,
        instruction: String,
        sources: [AICommandSource],
        session: VoiceSession,
        operation: AICommandInsertionOperation
    ) async {
        let outputDestination = session.aiCommandOutputDestination
        let compatibility = settingsStore.settings.externalAppCompatibilitySettings
        let currentExplicitInsertionAllowed = compatibility.enabled
            && compatibility.autoReplaceAICommandSelection
        let isExplicitTargetInsertion: Bool
        let allowExternalCompatibility: Bool
        switch operation {
        case .automaticSourceReplacement:
            isExplicitTargetInsertion = false
            // 自動source置換は既存契約を維持する。AXで置換できる場合は、互換入力を
            // ONにしていなくても直接書込みを試せる。外部送出だけが既存同意を要する。
            allowExternalCompatibility = currentExplicitInsertionAllowed
        case .explicitTargetInsertion:
            isExplicitTargetInsertion = true
            // 経路選択時から送出時までの短い間に設定が変わっても権限を広げない。
            guard session.aiCommandExplicitInsertionAllowedAtRecordingStart,
                  currentExplicitInsertionAllowed else {
                presentAICommandOutputResult(
                    text,
                    instruction: instruction,
                    session: session,
                    sources: sources,
                    notice: explicitTargetInsertionFallbackNotice()
                )
                return
            }
            allowExternalCompatibility = true
        }

        guard let outputTarget = session.aiCommandOutputTarget else {
            presentAICommandOutputResult(
                text,
                instruction: instruction,
                session: session,
                sources: sources,
                notice: isExplicitTargetInsertion ? explicitTargetInsertionFallbackNotice() : nil
            )
            return
        }

        let clipboardVariantEnabled = settingsStore.settings.aiCommandSettings.clipboardVariantEnabled
        let usesClipboardVariant: Bool
        switch operation {
        case .automaticSourceReplacement(let inputSource, let hasActualSource):
            usesClipboardVariant = inputSource == .clipboard
                && hasActualSource
                && clipboardVariantEnabled
        case .explicitTargetInsertion:
            // 明示挿入は型上もclipboard sourceを持たず、variant pasteへは到達しない。
            usesClipboardVariant = false
        }

        appState.setPhase(.inserting)
        hud.showAICommandState(.success)
        if usesClipboardVariant {
            // ⌘Vは送出したら取り消せず、クリップボードは1秒後に復元される。
            // 送出より前に回収先へ控えておかないと、Escapeでのキャンセルや
            // session所有権の喪失で、利用者が出力を回収する手段を全て失う。
            lastAICommandOutput = text
        }
        let insertionResult = await textInjector.insertAICommandOutput(
            text,
            forNormalTarget: outputTarget,
            verificationDestination: outputDestination,
            allowExternalCompatibility: allowExternalCompatibility,
            allowScopedClipboardFallback: compatibility.allowScopedClipboardFallback,
            operation: operation,
            clipboardVariantEnabled: clipboardVariantEnabled
        )
        // 所有権を失った後でも、variant pasteの送出結果だけは必ず記録する。ここを
        // `guard`より後に置くと、Escape時に「⌘Vを送ったか」が記録から消える。
        if usesClipboardVariant {
            AppLog.shared.info(
                "[Telemetry] ai_command_clipboard_paste result=\(Self.describeSafeInsertionResult(insertionResult))"
            )
        }
        guard ownsAICommandSession(session) else { return }
        switch insertionResult {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted,
             .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified:
            // 貼り付けが成功した時は、何も表示しない。Confirmed/Unverifiedの区別は
            // テレメトリに残し、頻繁なポップアップは避ける。
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard ownsAICommandSession(session) else { return }
            appState.setPhase(.idle)
            hud.clearAICommandState()
            hud.hide()
        case .clipboardVariantPasteMayHaveLostClipboard,
             .externalCompatibilityDisabled, .manualFallbackRequired, .insertionUnconfirmed,
             .nonEditable, .selectionNotCollapsed, .targetChanged, .secureInputBlocked:
            // 明示挿入の安全退避では本文と出典を保ち、本文コピーに混ざらないnoticeを付ける。
            presentAICommandOutputResult(
                text,
                instruction: instruction,
                session: session,
                sources: sources,
                notice: isExplicitTargetInsertion ? explicitTargetInsertionFallbackNotice() : nil
            )
        case .failed:
            finishAICommandWithFailure(ownerID: session.id)
        }
    }

    /// 停止時targetが無い・変化した・非編集だった場合、別のフォーカス先には書かず
    /// いつものコピー可能な結果ウィンドウへ退避する。
    private func presentAICommandOutputResult(
        _ text: String,
        instruction: String,
        session: VoiceSession,
        sources: [AICommandSource] = [],
        notice: String? = nil
    ) {
        guard !session.isCancelled else { return }
        appState.setPhase(.idle)
        hud.clearAICommandState()
        hud.hide()
        showAICommandResult(
            instruction: instruction,
            selectedText: session.selectedText,
            answer: text,
            sources: sources,
            notice: notice
        )
    }

    private func explicitTargetInsertionFallbackNotice() -> String {
        uiText("指定された入力先への挿入を安全に確認できなかったため、結果を別ウィンドウに表示しています。")
    }

    private func showAICommandResult(
        instruction: String,
        selectedText: String?,
        answer: String,
        sources: [AICommandSource],
        notice: String? = nil
    ) {
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: instruction,
            selectedText: selectedText,
            answer: answer,
            sources: sources,
            notice: notice
        ))
    }

    private func presentNormalInputFallback(_ text: String, notice: String? = nil) {
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: "",
            selectedText: nil,
            answer: text,
            sources: [],
            title: "音声入力結果",
            notice: notice,
            answerSectionTitle: "出力",
            copyButtonTitle: "出力をコピー"
        ))
    }

    /// 外部互換入力の同意を案内する。選択取得は録音開始前だけ再開できるが、
    /// 完了済みの通常音声入力は再送・再貼り付けせず、出力をコピー可能な形で残す。
    private func presentExternalCompatibilityGuide(
        returnToProcessIdentifier: pid_t? = nil,
        deferredNormalOutput: String? = nil,
        aiCommandActions: [AICommandResultAction] = [],
        afterEnable: (() -> Void)? = nil
    ) {
        let compatibilityExplanation = uiText("互換入力モードをONにすると、外部アプリでの選択取得と、クリップボードを変更しない仮想入力を使った直接入力を許可します。入力欄によっては反映を確認できないことがあります。")
        let hasDeferredNormalOutput = deferredNormalOutput != nil
        let enableCompatibilityAction = AICommandResultAction(
            id: "enable-external-compatibility",
            title: "互換入力を使う",
            style: .primary,
            handler: { [weak self] in
                guard let self else { return }
                self.settingsStore.settings.externalAppCompatibilitySettings.enabled = true
                self.settingsStore.flushPendingSave()
                if let returnToProcessIdentifier,
                   returnToProcessIdentifier != ProcessInfo.processInfo.processIdentifier {
                    _ = NSRunningApplication(processIdentifier: returnToProcessIdentifier)?.activate(
                        options: []
                    )
                }
                afterEnable?()
            }
        )
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: "",
            selectedText: nil,
            answer: deferredNormalOutput ?? compatibilityExplanation,
            sources: [],
            title: hasDeferredNormalOutput ? "音声入力結果" : "ブラウザや各種アプリへ対応",
            notice: hasDeferredNormalOutput
                ? uiText("この出力は自動で再試行しません。コピーして貼り付けるか、互換入力モードをONにしてからもう一度音声入力してください。")
                : nil,
            answerSectionTitle: hasDeferredNormalOutput ? "出力" : "互換入力について",
            copyButtonTitle: "出力をコピー",
            showsCopyButton: hasDeferredNormalOutput,
            actions: [enableCompatibilityAction] + aiCommandActions
        ))
    }

    private func showWebDisabledGuide(spokenInstruction: String) {
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: spokenInstruction,
            selectedText: nil,
            answer: uiText("Web検索機能はオフになっています。\nAIに指示モードの設定でWeb検索をオンにできます。"),
            sources: [],
            title: "Web検索",
            showsSettingsButton: true
        ))
    }

    /// 録音開始前の選択取得失敗は、赤いHUDだけで終わらせない。
    /// 選択テキストは一切モデルへ渡さず、利用者が次に取れる安全な操作を示す。
    private func presentAICommandCaptureGuidance(
        for failure: SelectionCaptureFailure,
        inputSource: AICommandInputSource,
        allowsClipboardRecovery: Bool = true
    ) {
        // 結果パネルがKoedexを前面化する前に、復帰先を固定する。
        let sourceProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        invalidateAICommandFailureDismissal()
        appState.setPhase(.idle)
        hud.clearAICommandState()
        hud.hide()

        if failure == .externalCompatibilityDisabled {
            AppLog.shared.info("Web/Electron選択取得の互換入力は未同意のため案内を表示")
            let actions = aiCommandCaptureGuidanceActions(
                for: failure,
                sourceProcessIdentifier: sourceProcessIdentifier,
                inputSource: inputSource,
                allowsClipboardRecovery: allowsClipboardRecovery
            )
            presentExternalCompatibilityGuide(
                returnToProcessIdentifier: sourceProcessIdentifier,
                aiCommandActions: actions
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    self?.startAICommandRecording(
                        expectedFrontmostProcessIdentifier: sourceProcessIdentifier,
                        inputSource: inputSource
                    )
                }
            }
            return
        }

        let message: String
        let showsSettingsButton: Bool
        switch failure {
        case .externalCompatibilityDisabled:
            // Handled above before building the generic result payload.
            message = ""
            showsSettingsButton = false
        case .selectionUnsupported, .copyDidNotProduceText:
            message = uiText("このウィンドウの選択テキストは安全に取得できません。選択を解除してAIへの質問として使うか、テキストを選択できるアプリで試してください。")
            showsSettingsButton = false
        case .accessibilityPermissionMissing:
            message = uiText("AIに指示モードを使うにはアクセシビリティの許可が必要です。セットアップまたはシステム設定で、現在起動中のKoedexを許可してください。")
            showsSettingsButton = true
        case .secureInput:
            message = uiText("安全な入力が有効なため、選択テキストを取得できません。パスワード入力などを閉じてから、もう一度試してください。")
            showsSettingsButton = false
        case .clipboardChanged, .clipboardRestoreFailed:
            message = uiText("クリップボードを安全に保護できない状態だったため、選択テキストの処理を中止しました。少し待ってから、もう一度試してください。")
            showsSettingsButton = false
        case .focusedElementUnavailable:
            message = uiText("現在のウィンドウから選択テキストを確認できませんでした。選択を解除してAIへの質問として使うか、別のアプリで試してください。")
            showsSettingsButton = false
        }

        AppLog.shared.warn("AIに指示の選択取得を安全に中止: \(failure)")
        let actions = aiCommandCaptureGuidanceActions(
            for: failure,
            sourceProcessIdentifier: sourceProcessIdentifier,
            inputSource: inputSource,
            allowsClipboardRecovery: allowsClipboardRecovery
        )
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: "",
            selectedText: nil,
            answer: message,
            sources: [],
            title: uiText("AIに指示モード"),
            showsSettingsButton: showsSettingsButton,
            actions: actions
        ))
    }

    private func aiCommandCaptureGuidanceActions(
        for failure: SelectionCaptureFailure,
        sourceProcessIdentifier: pid_t?,
        inputSource: AICommandInputSource,
        allowsClipboardRecovery: Bool
    ) -> [AICommandResultAction] {
        AICommandCaptureGuidanceActionPolicy.actions(
            for: failure,
            clipboardVariantEnabled: settingsStore.settings.aiCommandSettings.clipboardVariantEnabled,
            hasSourceProcessIdentifier: sourceProcessIdentifier != nil,
            allowsClipboardRecovery: allowsClipboardRecovery
        ).compactMap { semanticAction in
            switch semanticAction {
            case .questionWithoutSelection:
                return AICommandResultAction(
                    id: AICommandCaptureGuidanceSemanticAction.questionWithoutSelection.rawValue,
                    title: "選択なしで質問する",
                    style: .primary,
                    handler: { [weak self] in
                        self?.startAICommandRecordingWithoutSelection(inputSource: inputSource)
                    }
                )
            case .clipboardRecovery:
                guard let sourceProcessIdentifier else { return nil }
                return AICommandResultAction(
                    id: AICommandCaptureGuidanceSemanticAction.clipboardRecovery.rawValue,
                    title: "クリップボードの内容でAIに指示をする",
                    style: .secondary,
                    handler: { [weak self] in
                        self?.resumeAICommandRecordingFromClipboard(
                            sourceProcessIdentifier: sourceProcessIdentifier
                        )
                    }
                )
            }
        }
    }

    private func resumeAICommandRecordingFromClipboard(sourceProcessIdentifier: pid_t) {
        guard appState.phase == .idle else { return }
        guard let sourceApplication = NSRunningApplication(
            processIdentifier: sourceProcessIdentifier
        ), sourceApplication.activate(options: []) else {
            presentAICommandClipboardRecoveryFocusFailure()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // 即時一致に加え、50ms待機を最大10回行う。最長500ms。
            for attempt in 0...10 {
                guard !Task.isCancelled, self.appState.phase == .idle else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier
                    == sourceProcessIdentifier {
                    self.startAICommandRecording(
                        expectedFrontmostProcessIdentifier: sourceProcessIdentifier,
                        inputSource: .clipboard
                    )
                    return
                }
                guard attempt < 10 else { break }
                do {
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch {
                    return
                }
            }
            guard self.appState.phase == .idle else { return }
            self.presentAICommandClipboardRecoveryFocusFailure()
        }
    }

    private func presentAICommandClipboardRecoveryFocusFailure() {
        guard appState.phase == .idle else { return }
        AppLog.shared.warn("AIに指示のクリップボード復帰を中止: 元のアプリを前面化できませんでした")
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: "",
            selectedText: nil,
            answer: uiText("元のアプリに戻れなかったため、クリップボードの内容でAIに指示モードを開始しませんでした。元のアプリを前面にして、もう一度お試しください。"),
            sources: [],
            title: uiText("AIに指示モード"),
            showsSettingsButton: false
        ))
    }

    /// クリップボード読み取り失敗のログ・テレメトリ用の短い理由コード。
    /// `\(decision)`は`.text`の本文を含みうるため、ログへ直接補間しない。
    private func aiCommandClipboardReasonCode(for decision: ClipboardSourceReadPolicy.Decision) -> String {
        switch decision {
        case .text: return "ok"
        case .empty: return "empty"
        case .nonText: return "non_text"
        case .rejectedSecureInput: return "rejected_secure_input"
        case .rejectedConcealed: return "rejected_concealed"
        case .rejectedSelfGenerated: return "rejected_self_generated"
        case .tooLong: return "too_long"
        }
    }

    /// クリップボード読み取り失敗の案内。`SelectionCaptureFailure`用の
    /// `presentAICommandCaptureGuidance`とは別関数にする。クリップボード側は
    /// 「選択なしで質問する」を出さないなど文言・後始末の形が異なり、
    /// `SelectionCaptureFailure`のケースを増やさずに済ませるため。
    private func presentAICommandClipboardCaptureGuidance(
        for decision: ClipboardSourceReadPolicy.Decision
    ) {
        invalidateAICommandFailureDismissal()
        appState.setPhase(.idle)
        hud.clearAICommandState()
        hud.hide()

        guard let message = ClipboardSourceGuidanceCopy.message(for: decision, language: uiLanguage) else {
            return
        }
        aiCommandResultWindows.show(AICommandResultPayload(
            spokenInstruction: "",
            selectedText: nil,
            answer: message,
            sources: [],
            title: uiText("AIに指示モード"),
            showsSettingsButton: false
        ))
    }

    private func finishAICommandWithFailure(ownerID: UUID) {
        invalidateAICommandFailureDismissal()
        aiCommandFailureOwnership.present(ownerID: ownerID)
        // M5失敗はこの所有IDと単一タイマーで完結させ、
        // AppState.errorの一般用3秒自動復帰と競合させない。
        appState.setPhase(.idle)
        hud.showAICommandState(.failure)
        aiCommandFailureDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.aiCommandFailureOwnership.isOwned(by: ownerID) else { return }
            self.dismissAICommandFailure()
        }
    }

    private func invalidateAICommandFailureDismissal() {
        aiCommandFailureDismissTask?.cancel()
        aiCommandFailureDismissTask = nil
        aiCommandFailureOwnership.clear()
    }

    private func dismissAICommandFailure() {
        invalidateAICommandFailureDismissal()
        appState.setPhase(.idle)
        hud.clearAICommandState()
        hud.hide()
    }

    private func recordInputHistoryIfNeeded(
        mode: String,
        historyEnabled: Bool,
        historyRetentionDays: Int,
        textToInsert: String,
        cleanupDidFail: Bool,
        insertResult: TextInjectorResult,
        cleanupLatencyMs: Int?
    ) {
        let settings = settingsStore.settings
        guard historyEnabled else { return }

        let cleanupSucceeded = settings.cleanupEnabled && !cleanupDidFail
        let insertStatus: String
        var flags: [String] = []

        switch insertResult {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted:
            insertStatus = InputHistoryInsertStatus.inserted
        case .externalCompatibilityDisabled, .manualFallbackRequired, .clipboardMayHaveBeenLost,
             .insertionUnconfirmed,
             // クリップボードバリアントの3ケースは「AIに指示」専用経路だけが返し、
             // 通常モードのここへは到達しない。将来到達しても成功扱いにしないための保険。
             .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified,
             .clipboardVariantPasteMayHaveLostClipboard:
            // 呼び出し元はこのケースを履歴保存前に除外する。将来ここが直接呼ばれても
            // 成功扱いにしないため、明示的に失敗として分類しておく。
            insertStatus = InputHistoryInsertStatus.failed
            flags.append(InputHistoryFlag.insertFailed)
        case .secureInputBlocked:
            insertStatus = InputHistoryInsertStatus.secureInputBlocked
            flags.append(InputHistoryFlag.secureInputBlocked)
        case .failed:
            insertStatus = InputHistoryInsertStatus.failed
            flags.append(InputHistoryFlag.insertFailed)
        }

        if !settings.cleanupEnabled {
            flags.append(InputHistoryFlag.noiseCandidate)
        }
        if cleanupDidFail {
            flags.append(InputHistoryFlag.cleanupFailed)
        }

        let trimmedOutput = textToInsert.trimmingCharacters(in: .whitespacesAndNewlines)
        let mayStoreText = NormalInputHistoryPolicy.shouldStoreText(
            historyEnabled: historyEnabled,
            cleanupEnabled: settings.cleanupEnabled,
            cleanupDidFail: cleanupDidFail,
            output: trimmedOutput,
            result: insertResult
        )

        let modelSlug: String?
        let reasoningEffort: String?
        if settings.modelSettings.mode == .cli {
            modelSlug = nil
            reasoningEffort = nil
        } else {
            modelSlug = settings.modelSettings.selectedModelSlug
            reasoningEffort = settings.modelSettings.selectedReasoningEffort
        }

        let entry = InputHistoryEntry(
            mode: mode,
            storedText: mayStoreText ? trimmedOutput : nil,
            storedTextKind: mayStoreText
                ? NormalInputHistoryPolicy.storedTextKind(cleanupEnabled: settings.cleanupEnabled)
                : InputHistoryStoredTextKind.none,
            cleanupEnabled: settings.cleanupEnabled,
            cleanupSucceeded: cleanupSucceeded,
            insertStatus: insertStatus,
            flags: flags,
            modelSlug: modelSlug,
            reasoningEffort: reasoningEffort,
            latencyMs: cleanupLatencyMs
        )

        inputHistoryStore.append(entry, retentionDays: historyRetentionDays)
    }

    private func logNormalInputCompletion(
        result: TextInjectorResult,
        cleanupLatencyMs: Int?,
        insertionStartedAt: Date
    ) {
        let resultName: String
        switch result {
        case .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted:
            resultName = InputHistoryInsertStatus.inserted
        default:
            return
        }
        completedNormalInputCount += 1
        let insertionLatencyMs = Int((Date().timeIntervalSince(insertionStartedAt) * 1_000).rounded())
        let cleanupLatencyDescription = cleanupLatencyMs.map(String.init) ?? "none"
        AppLog.shared.info(
            "[Telemetry] normal_input_completed count=\(completedNormalInputCount) "
                + "cleanupMs=\(cleanupLatencyDescription) insertionMs=\(insertionLatencyMs) result=\(resultName)"
        )
    }

    // MARK: - CLIテストモード

    private func handleCLITestModeIfRequested() -> Bool {
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--test-cleanup-repeat"), idx + 1 < args.count,
           let count = Int(args[idx + 1]), count > 0 {
            switch CLITestModelOverride.parse(from: args) {
            case .success(let modelSettings):
                runTestCleanupRepeat(count: count, modelSettings: modelSettings)
            case .failure(let message):
                print("エラー: \(message)")
                exit(1)
            }
            return true
        }

        if let idx = args.firstIndex(of: "--test-cleanup"), idx + 1 < args.count {
            let text = args[idx + 1]
            switch CLITestModelOverride.parse(from: args) {
            case .success(let modelSettings):
                runTestCleanup(text, modelSettings: modelSettings)
            case .failure(let message):
                print("エラー: \(message)")
                exit(1)
            }
            return true
        }

        if let idx = args.firstIndex(of: "--test-stt"), idx + 1 < args.count {
            let path = args[idx + 1]
            runTestSTT(path)
            return true
        }

        if let idx = args.firstIndex(of: "--test-stt-repeat"), idx + 2 < args.count,
           let count = Int(args[idx + 1]), count > 0 {
            let path = args[idx + 2]
            runTestSTTRepeat(count: count, path: path)
            return true
        }

        return false
    }

    /// 同一プロセス内でN回連続してcleanupを実行する検証モード。
    /// thread使い回しの効果（2回目以降のレイテンシ短縮）と、購読リーク・通知混入がないことを確認する。
    private func runTestCleanupRepeat(count: Int, modelSettings: CodexModelSettings?) {
        Task {
            print("=== Koedex --test-cleanup-repeat \(count) ===")
            if let modelSettings {
                print("テストモデル: \(modelSettings.selectedModelSlug) / \(modelSettings.selectedReasoningEffort)")
            }
            let engine = makeTestCleanupEngine(modelSettings: modelSettings)
            let baseText = "えーと明日のあーミーティングなんですけど10時からいややっぱり11時からに変更してもらえますか"
            var failed = false
            do {
                let prewarmStart = Date()
                try await engine.prewarmThread()
                print(String(format: "prewarm所要時間: %.2f秒", Date().timeIntervalSince(prewarmStart)))
            } catch {
                print("prepare失敗: \(AppLog.safeDescription(error))")
                exit(1)
            }

            for i in 1...count {
                let input = "\(baseText)（\(i)回目のテストです）"
                print("--- \(i)回目 ---")
                print("入力: \(input)")
                let start = Date()
                do {
                    let result = try await engine.cleanup(rawTranscript: input, customInstruction: "")
                    let elapsed = Date().timeIntervalSince(start)
                    print("整形結果: \(result)")
                    print(String(format: "所要時間: %.2f秒", elapsed))
                } catch {
                    print("エラー: \(AppLog.safeDescription(error))")
                    failed = true
                }
                // runTurnのunsubscribeはdefer内の別Taskで行われるため、少し待ってから購読者数を確認する。
                try? await Task.sleep(nanoseconds: 200_000_000)
                let subscribers = await engine.debugSubscriberCount()
                print("通知購読者数（実行後）: \(subscribers)")
            }

            await engine.shutdown()
            exit(failed ? 1 : 0)
        }
    }

    private func runTestCleanup(_ text: String, modelSettings: CodexModelSettings?) {
        Task {
            print("=== Koedex --test-cleanup ===")
            print("入力: \(text)")
            if let modelSettings {
                print("テストモデル: \(modelSettings.selectedModelSlug) / \(modelSettings.selectedReasoningEffort)")
            }
            let engine = makeTestCleanupEngine(modelSettings: modelSettings)
            let start = Date()
            do {
                let prewarmStart = Date()
                try await engine.prewarmThread()
                print(String(format: "prewarm所要時間: %.2f秒", Date().timeIntervalSince(prewarmStart)))
                let result = try await engine.cleanup(rawTranscript: text, customInstruction: "")
                let elapsed = Date().timeIntervalSince(start)
                print("整形結果: \(result)")
                print(String(format: "所要時間: %.2f秒", elapsed))
                await engine.shutdown()
                exit(0)
            } catch {
                print("エラー: \(AppLog.safeDescription(error))")
                await engine.shutdown()
                exit(1)
            }
        }
    }

    private func makeTestCleanupEngine(modelSettings: CodexModelSettings?) -> CleanupEngine {
        CleanupEngine(
            executablePath: nonEmptyCodexPath(settingsStore.settings.codexExecutablePath),
            modelSettings: modelSettings ?? settingsStore.settings.modelSettings
        )
    }

    private func runTestSTT(_ path: String) {
        Task {
            print("=== Koedex --test-stt ===")
            print("音声ファイル: \((path as NSString).lastPathComponent)")
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("エラー: ファイルが見つかりません")
                exit(1)
            }
            do {
                let warmupStart = Date()
                try await transcriptionEngine.warmUp()
                print(String(format: "ウォームアップ所要時間: %.2f秒", Date().timeIntervalSince(warmupStart)))

                let recognizeStart = Date()
                let result = try await transcriptionEngine.transcribeFile(url: url)
                let elapsed = Date().timeIntervalSince(recognizeStart)
                print("文字起こし結果: \(result)")
                print(String(format: "認識所要時間: %.2f秒", elapsed))
                exit(0)
            } catch {
                print("エラー: \(AppLog.safeDescription(error))")
                exit(1)
            }
        }
    }

    private func runTestSTTRepeat(count: Int, path: String) {
        Task {
            print("=== Koedex --test-stt-repeat \(count) ===")
            print("音声ファイル: \((path as NSString).lastPathComponent)")
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("エラー: ファイルが見つかりません")
                exit(1)
            }
            do {
                let warmupStart = Date()
                try await transcriptionEngine.warmUp()
                print(String(format: "ウォームアップ所要時間: %.2f秒", Date().timeIntervalSince(warmupStart)))

                for i in 1...count {
                    let recognizeStart = Date()
                    let result = try await transcriptionEngine.transcribeFile(url: url)
                    let elapsed = Date().timeIntervalSince(recognizeStart)
                    print("--- \(i)回目 ---")
                    print("文字起こし結果: \(result)")
                    print(String(format: "認識所要時間: %.2f秒", elapsed))
                }
                exit(0)
            } catch {
                print("エラー: \(AppLog.safeDescription(error))")
                exit(1)
            }
        }
    }
}

/// Combine Cancellableを型消去して保持するための軽量ラッパー（新規importを増やさないため）。
final class AnyObjectHolder {
    private let object: Any
    init(_ object: Any) { self.object = object }
}
