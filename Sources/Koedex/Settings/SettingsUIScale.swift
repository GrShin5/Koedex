import SwiftUI

enum SettingsTextStyle {
    case title
    case headline
    case subheadline
    case body
    case caption
    case monospacedCaption
}

/// 設定ウィンドウ専用の表示倍率。文字は倍率どおり、余白は緩やかに変化させる。
struct SettingsUIScaleMetrics: Equatable {
    /// 新しい100%は、旧UIの125%相当として扱う。
    static let standardScale = 1.0
    static let defaultWindowSize = CGSize(width: 1_060, height: 900)
    static let minimumWindowSize = CGSize(width: 940, height: 680)

    /// ユーザーが選ぶ「標準100%」に対する倍率。実表示倍率ではない。
    let scale: Double
    /// 表示言語。英語だけは従来の英語フォントサイズを125%にする。
    let language: AppLanguage

    init(scale: Double, language: AppLanguage = .japanese) {
        self.scale = KoedexSettings.normalizedSettingsDisplayScale(scale)
        self.language = language
    }

    /// 従来の設定UIに対する実際の表示倍率。
    var effectiveScale: Double { scale * KoedexSettings.settingsDisplayScaleBase }

    private var textLanguageMultiplier: CGFloat { language == .english ? 1.25 : 1 }
    private var fontScale: CGFloat { CGFloat(effectiveScale) * textLanguageMultiplier }
    private var layoutScale: CGFloat { CGFloat(1 + (effectiveScale - 1) * 0.55) }

    var controlSize: ControlSize {
        switch effectiveScale {
        case ..<0.95: return .small
        case 1.2...: return .large
        default: return .regular
        }
    }

    /// モデルと推論レベルのMenuを自然な近さで並べる。列の余白ではなく実際のMenu間にだけ適用する。
    var modelPickerGap: CGFloat { layout(12) }
    /// 左サイドバーの本体幅と、その外周の余白。
    var sidebarContentWidth: CGFloat { layout(180) }
    var sidebarShellInset: CGFloat { layout(8) }
    var sidebarOuterWidth: CGFloat { sidebarContentWidth + sidebarShellInset * 2 }
    /// 右ペイン見出しと揃えるための、サイドバー内のタブ上余白。
    var sidebarTabTopInset: CGFloat { layout(16) }

    func layout(_ value: CGFloat) -> CGFloat {
        max(1, value * layoutScale)
    }

    func contentWidth(_ value: CGFloat) -> CGFloat {
        value * min(max(layoutScale, 0.95), 1.16)
    }

    var minimumWindowWidth: CGFloat {
        max(Self.minimumWindowSize.width, contentWidth(810))
    }

    var idealWindowWidth: CGFloat {
        max(Self.defaultWindowSize.width, contentWidth(930))
    }

    var minimumWindowHeight: CGFloat {
        max(Self.minimumWindowSize.height, layout(600))
    }

    var idealWindowHeight: CGFloat {
        max(Self.defaultWindowSize.height, layout(780))
    }

    func fontPointSize(_ style: SettingsTextStyle) -> CGFloat {
        let specification: (size: CGFloat, weight: Font.Weight, design: Font.Design)
        switch style {
        case .title:
            specification = (22, .bold, .default)
        case .headline:
            specification = (13, .semibold, .default)
        case .subheadline:
            specification = (12, .regular, .default)
        case .body:
            specification = (13, .regular, .default)
        case .caption:
            specification = (11, .regular, .default)
        case .monospacedCaption:
            specification = (11, .regular, .monospaced)
        }
        return specification.size * fontScale
    }

    func font(_ style: SettingsTextStyle) -> Font {
        let specification: (weight: Font.Weight, design: Font.Design)
        switch style {
        case .title:
            specification = (.bold, .default)
        case .headline:
            specification = (.semibold, .default)
        case .subheadline, .body, .caption:
            specification = (.regular, .default)
        case .monospacedCaption:
            specification = (.regular, .monospaced)
        }
        return .system(
            size: fontPointSize(style),
            weight: specification.weight,
            design: specification.design
        )
    }
}

private struct SettingsUIScaleMetricsKey: EnvironmentKey {
    static let defaultValue = SettingsUIScaleMetrics(scale: 1, language: .japanese)
}

extension EnvironmentValues {
    var settingsUIScaleMetrics: SettingsUIScaleMetrics {
        get { self[SettingsUIScaleMetricsKey.self] }
        set { self[SettingsUIScaleMetricsKey.self] = newValue }
    }
}

extension View {
    func settingsUIScale(_ metrics: SettingsUIScaleMetrics) -> some View {
        environment(\.settingsUIScaleMetrics, metrics)
            .font(metrics.font(.body))
            .controlSize(metrics.controlSize)
    }
}
