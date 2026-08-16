import SwiftUI

enum PopupTextStyle {
    case title
    case headline
    case body
    case caption
}

/// 設定画面の新しい100%（旧125%相当）へ、アプリ所有のパネル・確認画面を揃える。
/// 初回セットアップ側は固定125%なので、同じ標準値を渡して独立して使える。
struct PopupUIScaleMetrics: Equatable {
    private let settingsMetrics: SettingsUIScaleMetrics

    init(settingsScale: Double) {
        settingsMetrics = SettingsUIScaleMetrics(scale: settingsScale)
    }

    init(settingsMetrics: SettingsUIScaleMetrics) {
        self.settingsMetrics = settingsMetrics
    }

    var effectiveScale: Double { settingsMetrics.effectiveScale }
    var controlSize: ControlSize { settingsMetrics.controlSize }

    /// HUDは常時表示領域を壊さないよう、文字の見え方に対応するglyphだけを穏やかに拡大する。
    var glyphScale: CGFloat { min(max(CGFloat(effectiveScale), 0.9), 1.35) }

    func layout(_ value: CGFloat) -> CGFloat {
        settingsMetrics.layout(value)
    }

    func font(_ style: PopupTextStyle) -> Font {
        switch style {
        case .title: return settingsMetrics.font(.title)
        case .headline: return settingsMetrics.font(.headline)
        case .body: return settingsMetrics.font(.body)
        case .caption: return settingsMetrics.font(.caption)
        }
    }

    func panelSize(_ base: CGSize) -> CGSize {
        CGSize(width: layout(base.width), height: layout(base.height))
    }
}
