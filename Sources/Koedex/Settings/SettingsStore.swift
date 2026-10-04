import Foundation
import Combine

/// アプリ設定。~/Library/Application Support/Koedex/settings.json にJSON永続化する。
struct KoedexSettings: Codable, Equatable {
    var customInstruction: String
    var cleanupEnabled: Bool
    var hotkeyKeyCode: UInt16
    /// true: fn・右⌘等の修飾キー系（flagsChanged監視・単独押し検出）
    /// false: F13等の通常キー系（keyDown/keyUp監視・イベント消費）
    var hotkeyIsModifier: Bool
    /// NSEvent.ModifierFlags.rawValue相当。修飾キー系の判定に使う（fnなら`.function`相当）。
    var hotkeyModifierMask: UInt64
    /// 通常モードの録音方式。"toggle" or "hold"。
    var recordingMode: String
    /// 自動停止までの秒数。60／180／300／600のいずれか。
    var autoStopSeconds: Int
    /// codex実行ファイルの絶対パス。空文字なら自動探索（CodexPathResolver参照）。
    var codexExecutablePath: String
    /// Koedex内のAIアシストで使うCodexモデル設定。CLI追従時はapp-server引数へ出さない。
    var modelSettings: CodexModelSettings
    /// 入力履歴・メモリ基盤を有効にする。本文保存はAIアシスト成功時のみ。
    var historyEnabled: Bool
    /// 履歴保存期間（日数）。0以下なら無期限。
    var historyRetentionDays: Int
    /// 履歴画面に表示する最大件数。0以下ならすべて表示。
    var historyDisplayLimit: Int
    /// 設定・履歴・ユーザー辞書画面に共通で適用する表示倍率。
    var settingsDisplayScale: Double
    /// カスタムインストラクションを最適化する時に使うモデル設定。
    var customInstructionOptimizationModelSettings: CodexModelSettings
    /// 新規インストールだけにLuna初期値を一度適用したか。
    /// 旧設定をデコードした場合はtrueとして扱い、既存モデル値を変更しない。
    var initialModelDefaultsResolved: Bool
    /// 優先マイクのCoreAudio UID。空文字ならシステムデフォルトを自動使用。
    var preferredMicrophoneUID: String
    /// 「AIに指示」専用設定。通常モードの設定・指示とは独立して扱う。
    /// 録音方式は常にワンタップで、この設定には保持しない。
    var aiCommandSettings: AICommandSettings
    /// Web/ElectronなどAXで入力欄を検証できないアプリの、明示同意済み互換経路。
    var externalAppCompatibilitySettings: ExternalAppCompatibilitySettings
    /// 通常モードを基盤にしたハンズフリー送信モードの明示設定。
    var handsFreeSendSettings: HandsFreeSendSettings
    /// 初回／アップグレードセットアップの再開位置。
    var setupProgress: SetupProgress
    /// UI表示、STT、AI出力を独立して保存する言語設定。
    var languagePreferences: LanguagePreferences
    /// 設定ファイルのスキーマバージョン。マイグレーション制御用。
    var schemaVersion: Int

    /// 通常モードのホットキーを`HotkeyBinding`として見る。3つのスカラーから
    /// 組み立てる処理が設定画面・HotkeyManager・Chord判定で重複しないよう、
    /// ここを唯一の出どころにする。
    var normalHotkeyBinding: HotkeyBinding {
        HotkeyBinding(keys: [HotkeyKey(
            keyCode: hotkeyKeyCode,
            isModifier: hotkeyIsModifier,
            modifierMask: hotkeyModifierMask
        )])
    }

    /// クリップボード入力バリアントの安全な有効化可否を判定する唯一の入口。
    /// 設定画面とオンボーディングの両方がこれを使い、判定式を二重実装しない。
    var clipboardVariantEligibility: AICommandClipboardChordPolicy.Eligibility {
        AICommandClipboardChordPolicy.eligibility(
            startBinding: aiCommandSettings.startHotkey,
            extraModifier: aiCommandSettings.clipboardVariantModifier,
            stopBinding: aiCommandSettings.stopHotkey,
            normalBinding: normalHotkeyBinding,
            handsFreeSendBinding: handsFreeSendSettings.binding,
            handsFreeSendEnabled: handsFreeSendSettings.enabled
        )
    }

    /// v16: Phase 2の同梱Runtime選択を破棄し、外部Codex CLI基線へ一方向移行する。
    /// v15の`codexRuntimeSelection`は読んでも実行判断に使わず、保存時には残さない。
    static let currentSchemaVersion = 24
    static let allowedAutoStopSeconds: Set<Int> = [60, 180, 300, 600]
    /// 保存値1.00は「設定画面の標準」。実表示はこの基準倍率を掛けて計算する。
    static let settingsDisplayScaleBase = 1.25
    static let settingsDisplayScaleMinimum = 0.65
    static let settingsDisplayScaleMaximum = 1.40
    static let settingsDisplayScaleStep = 0.05

    static let `default` = KoedexSettings(
        customInstruction: "",
        cleanupEnabled: true,
        hotkeyKeyCode: HotkeyDefaults.defaultKeyCode,
        hotkeyIsModifier: true,
        hotkeyModifierMask: HotkeyDefaults.functionModifierMask,
        recordingMode: RecordingMode.toggle.rawValue,
        autoStopSeconds: 300,
        codexExecutablePath: "",
        modelSettings: .default,
        historyEnabled: true,
        historyRetentionDays: 180,
        historyDisplayLimit: 50,
        settingsDisplayScale: 1,
        customInstructionOptimizationModelSettings: .optimizationDefault,
        initialModelDefaultsResolved: false,
        preferredMicrophoneUID: "",
        aiCommandSettings: .default,
        externalAppCompatibilitySettings: .default,
        setupProgress: .newInstall,
        languagePreferences: .newInstall,
        schemaVersion: KoedexSettings.currentSchemaVersion,
        handsFreeSendSettings: .default
    )

    /// 設定ファイルが存在するのに読めなかった時に使う一時的な状態。
    /// ファイルへは書き戻さないが、同意が要る機能まで新規インストール向けの既定へ
    /// 引き上げてしまうと、同意していない外部アプリ操作がその場で有効になる。
    static let safeFallback: KoedexSettings = {
        var settings = KoedexSettings.default
        settings.externalAppCompatibilitySettings = .legacyDefault
        return settings
    }()

    init(
        customInstruction: String,
        cleanupEnabled: Bool,
        hotkeyKeyCode: UInt16,
        hotkeyIsModifier: Bool,
        hotkeyModifierMask: UInt64,
        recordingMode: String,
        autoStopSeconds: Int,
        codexExecutablePath: String,
        modelSettings: CodexModelSettings,
        historyEnabled: Bool,
        historyRetentionDays: Int,
        historyDisplayLimit: Int,
        settingsDisplayScale: Double = 1,
        customInstructionOptimizationModelSettings: CodexModelSettings,
        initialModelDefaultsResolved: Bool = false,
        preferredMicrophoneUID: String,
        aiCommandSettings: AICommandSettings = .default,
        externalAppCompatibilitySettings: ExternalAppCompatibilitySettings = .default,
        setupProgress: SetupProgress = .newInstall,
        languagePreferences: LanguagePreferences = .newInstall,
        schemaVersion: Int,
        handsFreeSendSettings: HandsFreeSendSettings = .default
    ) {
        self.customInstruction = customInstruction
        self.cleanupEnabled = cleanupEnabled
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyIsModifier = hotkeyIsModifier
        self.hotkeyModifierMask = hotkeyModifierMask
        self.recordingMode = recordingMode
        self.autoStopSeconds = autoStopSeconds
        self.codexExecutablePath = codexExecutablePath
        self.modelSettings = modelSettings
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = historyRetentionDays
        self.historyDisplayLimit = historyDisplayLimit
        self.settingsDisplayScale = Self.normalizedSettingsDisplayScale(settingsDisplayScale)
        self.customInstructionOptimizationModelSettings = customInstructionOptimizationModelSettings
        self.initialModelDefaultsResolved = initialModelDefaultsResolved
        self.preferredMicrophoneUID = preferredMicrophoneUID
        self.aiCommandSettings = aiCommandSettings
        self.externalAppCompatibilitySettings = externalAppCompatibilitySettings
        self.setupProgress = setupProgress
        self.languagePreferences = languagePreferences
        self.schemaVersion = schemaVersion
        self.handsFreeSendSettings = handsFreeSendSettings
    }

    /// 旧バージョンの設定ファイル（R1-B以前、これらのフィールドが存在しない）を読み込んでも
    /// 落とさず、欠けているフィールドはデフォルト値で補ってデコードする。
    /// これにより次回保存時に自動的に最新schemaVersionへマイグレーションされる。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customInstruction = try container.decodeIfPresent(String.self, forKey: .customInstruction) ?? ""
        cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? true
        let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        schemaVersion = decodedSchemaVersion

        if decodedSchemaVersion == 15 {
            // Phase 2の設定キーは互換のために受け入れるが、CLI基線では必ず無視する。
            let phase2Container = try decoder.container(keyedBy: Phase2CodingKeys.self)
            _ = try? phase2Container.decodeIfPresent(String.self, forKey: .codexRuntimeSelection)
        }

        let decodedKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode)
        // 右Option→fnの既存マイグレーションはv8導入時だけのもの。
        // v8ユーザーが明示的に右Optionを選んでいても、v9移行で上書きしない。
        if decodedSchemaVersion < 8,
           let decodedKeyCode, decodedKeyCode == HotkeyDefaults.rightOptionKeyCode {
            // 旧デフォルト（右⌥）のままなら、新デフォルト（fn）へ一度だけ自動マイグレーションする。
            hotkeyKeyCode = HotkeyDefaults.defaultKeyCode
        } else {
            hotkeyKeyCode = decodedKeyCode ?? HotkeyDefaults.defaultKeyCode
        }

        hotkeyIsModifier = try container.decodeIfPresent(Bool.self, forKey: .hotkeyIsModifier) ?? true
        hotkeyModifierMask = try container.decodeIfPresent(UInt64.self, forKey: .hotkeyModifierMask) ?? HotkeyDefaults.functionModifierMask
        recordingMode = try container.decodeIfPresent(String.self, forKey: .recordingMode) ?? RecordingMode.toggle.rawValue
        // v8までの任意値はupgradeセットアップで本人に選び直してもらうため保持する。
        // 実行時はeffectiveAutoStopSecondsで必ず安全な値へ制限する。
        autoStopSeconds = try container.decodeIfPresent(Int.self, forKey: .autoStopSeconds) ?? 300
        codexExecutablePath = try container.decodeIfPresent(String.self, forKey: .codexExecutablePath) ?? ""
        modelSettings = try container.decodeIfPresent(CodexModelSettings.self, forKey: .modelSettings) ?? .default
        historyEnabled = try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        let decodedHistoryRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 0
        if decodedSchemaVersion < 7 {
            historyRetentionDays = Self.normalizedHistoryRetentionDays(decodedHistoryRetentionDays)
        } else {
            historyRetentionDays = decodedHistoryRetentionDays
        }
        historyDisplayLimit = try container.decodeIfPresent(Int.self, forKey: .historyDisplayLimit) ?? 50
        let decodedSettingsDisplayScale = try container.decodeIfPresent(Double.self, forKey: .settingsDisplayScale) ?? 1
        if decodedSchemaVersion < 14 {
            settingsDisplayScale = Self.migratedSettingsDisplayScaleFromV13(decodedSettingsDisplayScale)
        } else {
            settingsDisplayScale = Self.normalizedSettingsDisplayScale(decodedSettingsDisplayScale)
        }
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        customInstructionOptimizationModelSettings = try container.decodeIfPresent(CodexModelSettings.self, forKey: .customInstructionOptimizationModelSettings)
            ?? legacyContainer.decodeIfPresent(CodexModelSettings.self, forKey: .personalizationModelSettings)
            ?? .optimizationDefault
        // このキーがない設定は既存ユーザーのもの。モデル値を勝手に移行しない。
        initialModelDefaultsResolved = try container.decodeIfPresent(Bool.self, forKey: .initialModelDefaultsResolved) ?? true
        preferredMicrophoneUID = MicrophoneDeviceManager.normalizedPreferredInputUID(
            try container.decodeIfPresent(String.self, forKey: .preferredMicrophoneUID) ?? ""
        )
        aiCommandSettings = try container.decodeIfPresent(AICommandSettings.self, forKey: .aiCommandSettings) ?? .default
        // 設定ファイルが存在する＝既存ユーザーなので、セクションが欠けていても
        // 新規インストール用の既定（互換入力ON）は適用しない。
        var decodedExternalAppCompatibilitySettings = try container.decodeIfPresent(
            ExternalAppCompatibilitySettings.self,
            forKey: .externalAppCompatibilitySettings
        ) ?? .legacyDefault
        // v22まで公開UIから有効化できた一時貼り付け経路は、v23でサポート専用へ移す。
        // 通常の互換入力・AI置換の同意は保持し、この追加経路だけを一度OFFへ戻す。
        if decodedSchemaVersion <= 22 {
            decodedExternalAppCompatibilitySettings.allowScopedClipboardFallback = false
        }
        externalAppCompatibilitySettings = decodedExternalAppCompatibilitySettings
        // v19以前の旧音声送信設定は移行しない。ハンズフリー送信は必ず明示有効化から始める。
        if decodedSchemaVersion >= 20 {
            handsFreeSendSettings = (try? container.decodeIfPresent(
                HandsFreeSendSettings.self,
                forKey: .handsFreeSendSettings
            )) ?? .default
        } else {
            handsFreeSendSettings = .default
        }
        // v23までのハンズフリー出力は通常モード履歴と同じ設定で保存されていた。
        // 既存ユーザーの保存方針を変えないよう、新しい独立設定へその値を引き継ぐ。
        if decodedSchemaVersion < 24 {
            handsFreeSendSettings.historyEnabled = historyEnabled
            handsFreeSendSettings.historyRetentionDays = historyRetentionDays
        }
        var decodedProgress = try container.decodeIfPresent(SetupProgress.self, forKey: .setupProgress)
            ?? (decodedSchemaVersion < Self.currentSchemaVersion ? .upgrade : .newInstall)
        // v1の途中状態は旧画面のステップIDを指すため、そのまま再開しない。
        // 完了済みユーザーは設定を保持したまま任意ガイドだけを案内し、未完了の場合だけ
        // 新しいアップグレード用フローから安全に再開する。
        if decodedProgress.version < SetupProgress.currentVersion {
            let wasComplete = decodedProgress.isComplete
            decodedProgress.version = SetupProgress.currentVersion
            decodedProgress.lastSeenGuideVersion = 0
            if !wasComplete {
                decodedProgress.kind = .upgrade
                decodedProgress.completedStepIDs = []
            }
        }
        setupProgress = decodedProgress
        // このキーがない設定はPhase 4以前の既存ユーザーのもの。
        // 初回選択を再表示せず、日本語UI/STTと従来どおりのAI自動追従を維持する。
        languagePreferences = try container.decodeIfPresent(LanguagePreferences.self, forKey: .languagePreferences)
            ?? .legacyDefault

        if schemaVersion < KoedexSettings.currentSchemaVersion {
            schemaVersion = KoedexSettings.currentSchemaVersion
        }
    }

    private enum CodingKeys: String, CodingKey {
        case customInstruction, cleanupEnabled, hotkeyKeyCode, hotkeyIsModifier
        case hotkeyModifierMask, recordingMode, autoStopSeconds, codexExecutablePath, modelSettings
        case historyEnabled, historyRetentionDays, historyDisplayLimit, settingsDisplayScale
        case customInstructionOptimizationModelSettings
        case initialModelDefaultsResolved
        case preferredMicrophoneUID, aiCommandSettings, externalAppCompatibilitySettings, handsFreeSendSettings
        case setupProgress, languagePreferences, schemaVersion
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case personalizationModelSettings
    }

    private enum Phase2CodingKeys: String, CodingKey {
        case codexRuntimeSelection
    }

    private static func normalizedHistoryRetentionDays(_ days: Int) -> Int {
        switch days {
        case ...0, 1, 30, 180:
            return days
        case 2...30:
            return 30
        default:
            return 180
        }
    }

    static func normalizedAutoStopSeconds(_ seconds: Int) -> Int {
        allowedAutoStopSeconds.contains(seconds) ? seconds : 300
    }

    static func normalizedSettingsDisplayScale(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        let clamped = min(max(scale, settingsDisplayScaleMinimum), settingsDisplayScaleMaximum)
        let steps = ((clamped - settingsDisplayScaleMinimum) / settingsDisplayScaleStep).rounded()
        let snapped = settingsDisplayScaleMinimum + steps * settingsDisplayScaleStep
        return (snapped * 100).rounded() / 100
    }

    /// v13までの保存値は実表示倍率そのものだった。旧100%だけはユーザー合意に従い
    /// 新しい標準100%（従来125%相当）へ拡大し、それ以外は見た目を維持する。
    static func migratedSettingsDisplayScaleFromV13(_ legacyScale: Double) -> Double {
        guard legacyScale.isFinite else { return 1 }
        if abs(legacyScale - 1) < 0.001 { return 1 }
        return normalizedSettingsDisplayScale(legacyScale / settingsDisplayScaleBase)
    }

    var effectiveAutoStopSeconds: Int {
        if Self.allowedAutoStopSeconds.contains(autoStopSeconds) { return autoStopSeconds }
        if autoStopSeconds > 600 { return 600 }
        return 300
    }
}

/// Explicit consent for the narrowly scoped fallback used when an app does not
/// expose a usable Accessibility text element. The safer default for AI edits
/// is result display; automatic external replacement is opt-in separately.
struct ExternalAppCompatibilitySettings: Codable, Equatable {
    var enabled: Bool
    var autoReplaceAICommandSelection: Bool
    /// Mail本文とChrome版Google Docs本文だけで一時Cmd-Vを許可する追加同意。
    /// 通常の互換入力はUnicodeなので、この値がfalseでもclipboardは変更しない。
    var allowScopedClipboardFallback: Bool

    /// 新規インストール用。ONでないと挿入できない外部アプリが多く、
    /// 何も設定していないユーザーが「入力されない」と受け取ってしまうため、既定でONにする。
    /// サポート専用の一時貼り付け経路（allowScopedClipboardFallback）だけはOFFのままにする。
    static let `default` = ExternalAppCompatibilitySettings(
        enabled: true,
        autoReplaceAICommandSelection: true,
        allowScopedClipboardFallback: false
    )

    /// 既存ユーザー用。保存済みのsettings.jsonにこのセクション自体が無い場合に使う。
    /// 新しい既定値が既存の同意状態を勝手に書き換えないよう、旧既定値のままにしておく。
    /// LanguagePreferences.legacyDefaultと同じ考え方。
    static let legacyDefault = ExternalAppCompatibilitySettings(
        enabled: false,
        autoReplaceAICommandSelection: false,
        allowScopedClipboardFallback: false
    )

    init(
        enabled: Bool = false,
        autoReplaceAICommandSelection: Bool = false,
        allowScopedClipboardFallback: Bool = false
    ) {
        self.enabled = enabled
        self.autoReplaceAICommandSelection = autoReplaceAICommandSelection
        self.allowScopedClipboardFallback = allowScopedClipboardFallback
    }

    /// 通常UIの互換入力をOFFにする時は、サポート専用の貼り付け互換も必ず解除する。
    mutating func setEnabledFromVisibleControl(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            allowScopedClipboardFallback = false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            autoReplaceAICommandSelection: try container.decodeIfPresent(
                Bool.self,
                forKey: .autoReplaceAICommandSelection
            ) ?? false,
            allowScopedClipboardFallback: try container.decodeIfPresent(
                Bool.self,
                forKey: .allowScopedClipboardFallback
            ) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, autoReplaceAICommandSelection, allowScopedClipboardFallback
    }
}

struct AICommandSettings: Codable, Equatable {
    var enabled: Bool
    var startHotkey: HotkeyBinding
    var stopHotkey: HotkeyBinding
    var modelSettings: CodexModelSettings
    var webSearchEnabled: Bool
    var additionalInstruction: String
    var historyEnabled: Bool
    var historyRetentionDays: Int
    var clipboardVariantEnabled: Bool
    var clipboardVariantModifier: AICommandClipboardModifier

    static let `default` = AICommandSettings(
        enabled: true,
        startHotkey: .aiCommandStart,
        stopHotkey: .aiCommandStop,
        modelSettings: CodexModelSettings(
            mode: .explicit,
            selectedModelSlug: "gpt-5.5",
            selectedReasoningEffort: "low"
        ),
        webSearchEnabled: true,
        additionalInstruction: "",
        historyEnabled: true,
        historyRetentionDays: 180,
        clipboardVariantEnabled: false,
        // Optionは製品上の既定値。CommandとControlも固有に使用不可ではなく、
        // 現在の開始Chordと組み合わせた結果に対してeligibilityを判定する。
        clipboardVariantModifier: .option
    )

    init(
        enabled: Bool,
        startHotkey: HotkeyBinding,
        stopHotkey: HotkeyBinding,
        modelSettings: CodexModelSettings,
        webSearchEnabled: Bool,
        additionalInstruction: String,
        historyEnabled: Bool,
        historyRetentionDays: Int,
        clipboardVariantEnabled: Bool,
        clipboardVariantModifier: AICommandClipboardModifier
    ) {
        self.enabled = enabled
        self.startHotkey = startHotkey.isValid ? startHotkey : .aiCommandStart
        self.stopHotkey = stopHotkey.keys.count == 1 ? stopHotkey : .aiCommandStop
        self.modelSettings = modelSettings
        self.webSearchEnabled = webSearchEnabled
        self.additionalInstruction = additionalInstruction
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = Self.normalizedRetentionDays(historyRetentionDays)
        self.clipboardVariantEnabled = clipboardVariantEnabled
        self.clipboardVariantModifier = clipboardVariantModifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            startHotkey: try container.decodeIfPresent(HotkeyBinding.self, forKey: .startHotkey) ?? .aiCommandStart,
            stopHotkey: try container.decodeIfPresent(HotkeyBinding.self, forKey: .stopHotkey) ?? .aiCommandStop,
            modelSettings: try container.decodeIfPresent(CodexModelSettings.self, forKey: .modelSettings) ?? Self.default.modelSettings,
            webSearchEnabled: try container.decodeIfPresent(Bool.self, forKey: .webSearchEnabled) ?? true,
            additionalInstruction: try container.decodeIfPresent(String.self, forKey: .additionalInstruction) ?? "",
            historyEnabled: try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true,
            historyRetentionDays: try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 0,
            clipboardVariantEnabled: try container.decodeIfPresent(Bool.self, forKey: .clipboardVariantEnabled) ?? false,
            clipboardVariantModifier: try container.decodeIfPresent(AICommandClipboardModifier.self, forKey: .clipboardVariantModifier) ?? AICommandSettings.default.clipboardVariantModifier
        )
    }

    private static func normalizedRetentionDays(_ days: Int) -> Int {
        [0, 1, 30, 180].contains(days) ? days : 0
    }
}

enum SetupKind: String, Codable {
    case newInstall
    case upgrade
}

struct SetupProgress: Codable, Equatable {
    /// v2は、旧オンボーディングの細かいステップIDを新フローの再開状態として
    /// 読み替えないための境界。完了済み設定はそのまま尊重する。
    static let currentVersion = 2
    static let currentGuideVersion = 1

    var version: Int
    var kind: SetupKind
    var completedStepIDs: Set<String>
    var isComplete: Bool
    /// 完了済みユーザーに任意ガイドを一度見せたかを記録する。0は未表示。
    var lastSeenGuideVersion: Int

    init(
        version: Int,
        kind: SetupKind,
        completedStepIDs: Set<String>,
        isComplete: Bool,
        lastSeenGuideVersion: Int = 0
    ) {
        self.version = version
        self.kind = kind
        self.completedStepIDs = completedStepIDs
        self.isComplete = isComplete
        self.lastSeenGuideVersion = lastSeenGuideVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        kind = try container.decodeIfPresent(SetupKind.self, forKey: .kind) ?? .upgrade
        completedStepIDs = try container.decodeIfPresent(Set<String>.self, forKey: .completedStepIDs) ?? []
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
        lastSeenGuideVersion = try container.decodeIfPresent(Int.self, forKey: .lastSeenGuideVersion) ?? 0
    }

    static let newInstall = SetupProgress(version: currentVersion, kind: .newInstall, completedStepIDs: [], isComplete: false)
    static let upgrade = SetupProgress(version: currentVersion, kind: .upgrade, completedStepIDs: [], isComplete: false)
}

enum CodexModelMode: String, Codable, CaseIterable {
    case cli
    case explicit
    case custom
}

struct CodexModelSettings: Codable, Equatable {
    var mode: CodexModelMode
    var selectedModelSlug: String
    var selectedReasoningEffort: String

    static let defaultModelSlug = "gpt-5.4-mini"
    static let defaultReasoningEffort = "low"

    static let `default` = CodexModelSettings(
        mode: .cli,
        selectedModelSlug: defaultModelSlug,
        selectedReasoningEffort: defaultReasoningEffort
    )

    static let optimizationDefault = CodexModelSettings(
        mode: .explicit,
        selectedModelSlug: "gpt-5.5",
        selectedReasoningEffort: "medium"
    )

    init(mode: CodexModelMode, selectedModelSlug: String, selectedReasoningEffort: String) {
        self.mode = mode
        self.selectedModelSlug = selectedModelSlug
        self.selectedReasoningEffort = selectedReasoningEffort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modeRaw = try container.decodeIfPresent(String.self, forKey: .mode) ?? CodexModelMode.cli.rawValue
        mode = CodexModelMode(rawValue: modeRaw) ?? .cli
        selectedModelSlug = try container.decodeIfPresent(String.self, forKey: .selectedModelSlug) ?? Self.defaultModelSlug
        selectedReasoningEffort = try container.decodeIfPresent(String.self, forKey: .selectedReasoningEffort) ?? Self.defaultReasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case mode, selectedModelSlug, selectedReasoningEffort
    }
}

enum RecordingMode: String, CaseIterable {
    case toggle
    case hold

    func displayName(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .toggle: japanese = "ワンタップ（1回タップで開始・もう1回タップで停止。）"
        case .hold: japanese = "長押し（押している間だけ録音）"
        }
        return AppLocalizer.text(japanese, language: language)
    }

    var displayName: String { displayName(for: .japanese) }
}

/// ホットキーのデフォルト値をSettingsとHotkeyManagerの双方から参照できるよう定数として切り出す。
enum HotkeyDefaults {
    /// 右⌥（Right Option）のCGEvent keyCode（旧デフォルト。マイグレーション判定に使用）
    static let rightOptionKeyCode: UInt16 = 0x3D
    /// fn（グローブ）キーのCGEvent keyCode。新デフォルト。
    static let fnKeyCode: UInt16 = 0x3F
    /// 現在のデフォルトキー。
    static let defaultKeyCode: UInt16 = fnKeyCode
    /// NSEvent.ModifierFlags.function.rawValue相当のビットマスク。
    static let functionModifierMask: UInt64 = 0x800000
}

@MainActor
final class SettingsStore: ObservableObject {
    enum LoadStatus: Equatable {
        case newInstall
        case loaded
        case migrated
        case failedToDecode
        case failedToMigrate
    }

    enum InitialModelDefaultsResolution: Equatable {
        case alreadyResolved
        case appliedLuna
        case retainedExistingDefaults
    }

    private enum MigrationError: Error {
        case backupMismatch
    }

    @Published var settings: KoedexSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleDebouncedSave()
        }
    }

    private let fileURL: URL
    private let migrationBackupURL: URL
    private(set) var loadStatus: LoadStatus
    private var writesEnabled: Bool
    /// didSetのたびに即時書き込みするのを避けるためのdebounce（0.5秒）。
    private var saveDebounceTask: Task<Void, Never>?
    private let debounceSeconds: UInt64 = 500_000_000

    var canSave: Bool { writesEnabled }

    /// 保存不可のとき、UIへ理由を渡すためのloadStatus。書き込み可能な間はnil。
    /// 新しい状態は持たず、既存のloadStatusから導出する。
    var saveBlockedStatus: LoadStatus? {
        canSave ? nil : loadStatus
    }

    init(storageRootURL: URL? = nil) {
        let dir: URL
        if let storageRootURL {
            dir = storageRootURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent("Koedex", isDirectory: true)
        }
        StoragePermissions.ensureDirectory(at: dir)
        self.fileURL = dir.appendingPathComponent("settings.json")
        // 設定の意味を変える移行ごとに、直前の完全なJSONを残す。
        // 既存のpre-v9バックアップは上書きしない。
        self.migrationBackupURL = dir.appendingPathComponent(
            "settings.pre-v\(KoedexSettings.currentSchemaVersion)-backup.json"
        )

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.settings = .default
            self.loadStatus = .newInstall
            self.writesEnabled = true
            return
        }

        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(KoedexSettings.self, from: data) else {
            // 壊れた既存設定をdefaultで上書きしない。UIはloadStatusを見て復旧を案内できる。
            // ファイルがある＝既存ユーザーなので、同意が要る設定は新規インストール向けの
            // 既定へ引き上げない（safeFallback）。書き込みも止めるが、この間の**挙動**も守る。
            self.settings = .safeFallback
            self.loadStatus = .failedToDecode
            self.writesEnabled = false
            AppLog.shared.error("[SettingsStore] 設定ファイルのデコードに失敗（既存設定は保持）")
            return
        }

        self.settings = loaded
        self.writesEnabled = true
        if Self.needsMigration(data: data) {
            do {
                try Self.backupOnce(data: data, to: migrationBackupURL)
                try Self.writeVerified(settings: loaded, to: fileURL)
                self.loadStatus = .migrated
            } catch {
                self.loadStatus = .failedToMigrate
                self.writesEnabled = false
                AppLog.shared.error("[SettingsStore] マイグレーション失敗（既存設定は保持）")
            }
        } else {
            self.loadStatus = .loaded
        }
    }

    private static func needsMigration(data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["schemaVersion"] as? Int else {
            return true
        }
        return version < KoedexSettings.currentSchemaVersion
    }

    private func scheduleDebouncedSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceSeconds ?? 500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard writesEnabled else {
            AppLog.shared.error("[SettingsStore] 読み込み／移行失敗のため既存設定への書き込みを拒否")
            return
        }
        do {
            try Self.writeVerified(settings: settings, to: fileURL)
        } catch {
            AppLog.shared.error("[SettingsStore] 保存失敗")
        }
    }

    /// サポート専用の貼り付け互換を即時保存する。失敗時はメモリ上の設定も変更しない。
    @discardableResult
    func setScopedClipboardFallbackForSupport(_ enabled: Bool) -> Bool {
        guard writesEnabled else { return false }
        guard !enabled || settings.externalAppCompatibilitySettings.enabled else { return false }

        var updated = settings
        updated.externalAppCompatibilitySettings.allowScopedClipboardFallback = enabled
        do {
            try Self.writeVerified(settings: updated, to: fileURL)
            settings = updated
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func setAutoStopSeconds(_ seconds: Int) -> Bool {
        guard KoedexSettings.allowedAutoStopSeconds.contains(seconds) else { return false }
        settings.autoStopSeconds = seconds
        return true
    }

    func setSettingsDisplayScale(_ scale: Double) {
        settings.settingsDisplayScale = KoedexSettings.normalizedSettingsDisplayScale(scale)
    }

    /// 新規インストール時だけ、最初に成功したライブカタログを基に既定モデルを決める。
    /// 既存設定はdecode時にresolved扱いになるため、このメソッドで書き換わらない。
    @discardableResult
    func resolveInitialModelDefaults(usingLiveModels models: [CodexModelInfo]) -> InitialModelDefaultsResolution {
        guard !settings.initialModelDefaultsResolved else { return .alreadyResolved }

        var updated = settings
        updated.initialModelDefaultsResolved = true

        guard let luna = CodexModelCatalog.model(slug: "gpt-6-luna", in: models),
              CodexModelCatalog.isUserSelectable(effort: "low", for: luna) else {
            settings = updated
            return .retainedExistingDefaults
        }

        let lunaLow = CodexModelSettings(
            mode: .custom,
            selectedModelSlug: luna.slug,
            selectedReasoningEffort: "low"
        )
        updated.modelSettings = lunaLow
        updated.aiCommandSettings.modelSettings = lunaLow
        updated.customInstructionOptimizationModelSettings = lunaLow
        settings = updated
        return .appliedLuna
    }

    private static func backupOnce(data: Data, to backupURL: URL) throws {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let existingData = try Data(contentsOf: backupURL)
            guard existingData == data else {
                throw MigrationError.backupMismatch
            }
            return
        }
        // Data.WritingOptionsはatomicとwithoutOverwritingを併用できない。
        // 既存バックアップを守ることを優先し、上書き禁止で一度だけ作成する。
        try data.write(to: backupURL, options: .withoutOverwriting)
        StoragePermissions.applyFileMode(to: backupURL)
    }

    private static func writeVerified(settings: KoedexSettings, to fileURL: URL) throws {
        let data = try JSONEncoder().encode(settings)
        _ = try JSONDecoder().decode(KoedexSettings.self, from: data)
        try data.write(to: fileURL, options: .atomic)
        StoragePermissions.applyFileMode(to: fileURL)
    }

    func flushPendingSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        save()
    }

    /// 設定変更を監視するためのCombine Publisher（HotkeyManagerのtap再作成トリガー等に使う）。
    var settingsPublisher: Published<KoedexSettings>.Publisher { $settings }
}
