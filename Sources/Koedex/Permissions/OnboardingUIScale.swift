import SwiftUI

/// 初回セットアップ専用の固定表示倍率。
/// 設定画面のユーザー選択倍率とは分離し、初回体験だけを常に読みやすい125%基準で表示する。
enum OnboardingTextStyle {
    case title
    case title3
    case headline
    case body
    case caption
    case caption2
    case monospacedCaption
}

struct OnboardingUIScaleMetrics: Equatable {
    static let standard = OnboardingUIScaleMetrics(language: .japanese)
    static let defaultWindowSize = CGSize(width: 835, height: 865)
    static let minimumWindowSize = CGSize(width: 696, height: 683)

    /// 初回セットアップの既存基準。英語のみ、この時点の英語フォントをさらに125%にする。
    let scale: CGFloat
    let language: AppLanguage

    init(language: AppLanguage = .japanese) {
        self.language = language
        self.scale = 1.25
    }

    private var textLanguageMultiplier: CGFloat { language == .english ? 1.25 : 1 }

    /// 余白まで機械的に125%にすると狭いウィンドウで窮屈になるため、緩やかに拡大する。
    private var layoutScale: CGFloat { 1 + (scale - 1) * 0.55 }

    var controlSize: ControlSize { .large }

    func layout(_ value: CGFloat) -> CGFloat {
        max(1, value * layoutScale)
    }

    func fontPointSize(_ style: OnboardingTextStyle) -> CGFloat {
        let specification: (size: CGFloat, weight: Font.Weight, design: Font.Design)
        switch style {
        case .title:
            specification = (22, .bold, .default)
        case .title3:
            specification = (17, .semibold, .default)
        case .headline:
            specification = (13, .semibold, .default)
        case .body:
            specification = (13, .regular, .default)
        case .caption:
            specification = (11, .regular, .default)
        case .caption2:
            specification = (10, .regular, .default)
        case .monospacedCaption:
            specification = (11, .regular, .monospaced)
        }
        return specification.size * scale * textLanguageMultiplier
    }

    func font(_ style: OnboardingTextStyle) -> Font {
        let specification: (weight: Font.Weight, design: Font.Design)
        switch style {
        case .title:
            specification = (.bold, .default)
        case .title3, .headline:
            specification = (.semibold, .default)
        case .body, .caption, .caption2:
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

private struct OnboardingUIScaleMetricsKey: EnvironmentKey {
    static let defaultValue = OnboardingUIScaleMetrics.standard
}

extension EnvironmentValues {
    var onboardingUIScaleMetrics: OnboardingUIScaleMetrics {
        get { self[OnboardingUIScaleMetricsKey.self] }
        set { self[OnboardingUIScaleMetricsKey.self] = newValue }
    }
}

extension View {
    func onboardingUIScale(_ metrics: OnboardingUIScaleMetrics = .standard) -> some View {
        environment(\.onboardingUIScaleMetrics, metrics)
            .font(metrics.font(.body))
            .controlSize(metrics.controlSize)
    }
}
