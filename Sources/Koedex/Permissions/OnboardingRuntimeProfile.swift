import Foundation

/// 初回セットアップ専用の実行プロファイル。
/// 同じ実行バイナリでもDebug.appだけを明確に隔離し、本番の設定・履歴・ログへ
/// 触れないために使用する。
enum OnboardingRuntimeProfile {
    static let productionApplicationSupportName = "Koedex"
    /// `scripts/make_app.sh` が本番バンドルへ書き込むID。バンドル外から実行された時
    /// （`.build/debug/Koedex` を直接叩く場合）は `Bundle.main.bundleIdentifier` が
    /// nil になるため、起動中インスタンスの判定にはこれを既定として使う。
    static let productionBundleIdentifier = "com.koedex.app"
    static let debugBundleIdentifier = "com.koedex.onboarding-debug"
    static let debugApplicationSupportName = "Koedex Debug"

    enum RuntimeKind: Equatable {
        case normal
        case onboardingDebug
    }

    static var runtimeKind: RuntimeKind {
        switch Bundle.main.bundleIdentifier {
        case debugBundleIdentifier:
            return .onboardingDebug
        default:
            return .normal
        }
    }

    static var isDebug: Bool {
        runtimeKind != .normal
    }

    static var isOnboardingDebug: Bool {
        runtimeKind == .onboardingDebug
    }

    static func applicationSupportName(for runtimeKind: RuntimeKind) -> String {
        switch runtimeKind {
        case .normal:
            return productionApplicationSupportName
        case .onboardingDebug:
            return debugApplicationSupportName
        }
    }

    static func historyFileDisplayPath(for runtimeKind: RuntimeKind) -> String {
        "~/Library/Application Support/\(applicationSupportName(for: runtimeKind))/history/input_history.jsonl"
    }

    static var applicationSupportName: String {
        applicationSupportName(for: runtimeKind)
    }

    static var historyFileDisplayPath: String {
        historyFileDisplayPath(for: runtimeKind)
    }

    /// Debug.appだけが使う専用のApplication Supportルート。
    /// nilは通常のKoedex保存先を使うことを表す。
    static var storageRootURL: URL? {
        switch runtimeKind {
        case .normal:
            return nil
        case .onboardingDebug:
            return applicationSupportRootURL(named: applicationSupportName)
        }
    }

    /// 権限再起動の一時復帰情報も、本番とDebugで完全に分離する。
    static var restartIntentURL: URL {
        let root = storageRootURL ?? applicationSupportRootURL(named: productionApplicationSupportName)
        return root.appendingPathComponent("onboarding_restart_intent.json")
    }

    private static func applicationSupportRootURL(named name: String) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent(name, isDirectory: true)
    }
}

/// Debug.appを「新規インストール直後」へ戻すための初期状態を、実行時副作用なしで
/// 生成する純粋な方針。言語選択からやり直すために使う。
/// 実際にどの保存先へ適用するかは呼び出し側のSettingsStoreに委ねる。
enum DebugFreshSetupResetPolicy {
    static func freshSettings() -> KoedexSettings {
        .default
    }
}

/// 同じ画面部品を初回セットアップ・アップグレード・任意ガイド・Debugで安全に使い分ける。
enum OnboardingPresentationMode: Equatable {
    case firstRun
    case upgrade
    case permissionRecovery
    case guide
    case debugPreview
    case debugRehearsal

    var isPreview: Bool { self == .debugPreview }
    var isLiveDebugRehearsal: Bool { self == .debugRehearsal }
    var isDebug: Bool { isPreview || isLiveDebugRehearsal }
    var isGuide: Bool { self == .guide }
    /// Debugも初回セットアップと同じく言語選択から始める。専用のDebug.appを分けずに
    /// 言語選択を実機確認できるようにするため、ここで`.firstRun`と同じ扱いにする。
    var usesInitialLanguageSelection: Bool {
        self == .firstRun || isDebug
    }

    /// 任意ガイドは既存セットアップの完了状態を変更しない。
    var completesSetup: Bool { !isGuide }

    /// 任意ガイドは進捗を再開位置として利用しない。
    var persistsStepProgress: Bool { !isGuide }

    /// 新規インストールだけは、完了後に設定画面を開いて次に変更できる場所を示す。
    /// Debug・アップグレード・権限復旧では既存の画面遷移を維持する。
    var opensSettingsAfterFinish: Bool { self == .firstRun }

    func title(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .firstRun: japanese = "Koedexへようこそ"
        case .upgrade: japanese = "新しい使い方を確認"
        case .permissionRecovery: japanese = "必要な権限を確認"
        case .guide: japanese = "セットアップガイド"
        case .debugPreview: japanese = "Koedex Debug — プレビュー"
        case .debugRehearsal: japanese = "Koedex Debug — 実機確認"
        }
        return AppLocalizer.text(japanese, language: language)
    }

    var title: String {
        title(for: .japanese)
    }
}

/// ハンズフリー送信は新規・アップグレード・Debugのセットアップで任意に案内する。
enum HandsFreeSendOnboardingPolicy {
    static func showsOptionalToggle(in mode: OnboardingPresentationMode) -> Bool {
        switch mode {
        case .firstRun, .upgrade, .debugPreview, .debugRehearsal:
            return true
        case .permissionRecovery, .guide:
            return false
        }
    }
}

/// セットアップでハンズフリー送信を選んだ時に、何を一緒に切り替えるか。
/// 選んだ人は外部アプリでも使えることを期待しているため、設定画面で個別に
/// 有効化し直さずに済むよう「外部アプリでも自動送信する」も同時に切り替える。
/// 送信は取り消せないので、この連動はセットアップ画面の説明文に明記してある。
///
/// ただし設定画面は、この同意を互換入力モードがONの時しか受け付けない
/// （OFFの間はトグル自体が操作できない）。互換入力OFFのまま同意だけを立てると、
/// 本人が下ろせない状態が残り、あとで互換入力をONに戻した瞬間に自動送信が
/// 有効になってしまう。そのため、ここでも同じ前提を要求する。
enum HandsFreeSendOnboardingActivation {
    static func apply(
        enabled: Bool,
        externalCompatibilityEnabled: Bool,
        to settings: inout HandsFreeSendSettings
    ) {
        settings.enabled = enabled
        settings.allowExternalAutoSend = enabled && externalCompatibilityEnabled
    }
}

/// AIに指示クリップボード入力バリアントも、新規・アップグレード・Debugのセットアップで
/// 任意に案内する（ハンズフリー送信と同じ扱い）。
enum AICommandClipboardVariantOnboardingPolicy {
    static func showsOptionalToggle(in mode: OnboardingPresentationMode) -> Bool {
        switch mode {
        case .firstRun, .upgrade, .debugPreview, .debugRehearsal:
            return true
        case .permissionRecovery, .guide:
            return false
        }
    }
}

enum OnboardingStep: String, CaseIterable, Equatable, Codable {
    case language
    case welcome
    case permissions
    case voice
    case preferences
    case aiCommand
    case practice
    case complete
}

/// UIに依存しないセットアップ遷移。CLI回帰テストでも同じ判断を確認できる。
enum OnboardingFlow {
    static func steps(
        mode: OnboardingPresentationMode,
        progress: SetupProgress,
        allPermissionsGranted: Bool,
        hasCompletedInitialLanguageSelection: Bool = true,
        forcedInitialStep: OnboardingStep? = nil
    ) -> [OnboardingStep] {
        var result: [OnboardingStep]
        switch mode {
        case .firstRun, .debugPreview, .debugRehearsal:
            result = [.welcome, .permissions, .voice, .preferences, .aiCommand, .practice, .complete]
            if !hasCompletedInitialLanguageSelection {
                result.insert(.language, at: 0)
            }
        case .upgrade:
            result = []
            if !allPermissionsGranted {
                result.append(.permissions)
            }
            result += [.preferences, .aiCommand, .practice, .complete]
        case .permissionRecovery:
            result = [.permissions, .complete]
        case .guide:
            result = [.welcome, .voice, .aiCommand, .complete]
        }

        if let forcedInitialStep, !result.contains(forcedInitialStep) {
            result.insert(forcedInitialStep, at: 0)
        }
        return result
    }

    /// 保存済み進捗と現在の権限状態から、セットアップを再開するステップを決める。
    /// 進捗が空の新規インストール／Debugリセットでは、権限未許可でも必ず歓迎画面から始める。
    static func initialStepIndex(
        mode: OnboardingPresentationMode,
        progress: SetupProgress,
        allPermissionsGranted: Bool,
        hasCompletedInitialLanguageSelection: Bool = true,
        forcedInitialStep: OnboardingStep? = nil
    ) -> Int {
        let flowSteps = steps(
            mode: mode,
            progress: progress,
            allPermissionsGranted: allPermissionsGranted,
            hasCompletedInitialLanguageSelection: hasCompletedInitialLanguageSelection,
            forcedInitialStep: forcedInitialStep
        )
        guard mode.persistsStepProgress else { return 0 }

        if let forcedInitialStep,
           let forcedIndex = flowSteps.firstIndex(of: forcedInitialStep) {
            return forcedIndex
        }

        if !progress.completedStepIDs.isEmpty,
           !allPermissionsGranted,
           let permissionIndex = flowSteps.firstIndex(of: .permissions) {
            return permissionIndex
        }

        return flowSteps.firstIndex { !progress.completedStepIDs.contains($0.rawValue) }
            ?? max(flowSteps.count - 1, 0)
    }

    /// AIモードを無効にしたセットアップでは、AI用のショートカット確認を通過条件にしない。
    static func requiresAIShortcutVerification(
        mode: OnboardingPresentationMode,
        aiEnabled: Bool
    ) -> Bool {
        !mode.isGuide && aiEnabled
    }
}
