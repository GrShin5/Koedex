import SwiftUI

/// macOS標準alertではアプリ内の表示倍率を一貫して適用できないため、
/// 破壊的操作を含むアプリ所有の確認だけを同じ操作性のシートで表示する。
struct AppConfirmationSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    let confirmRole: ButtonRole?
    let metrics: PopupUIScaleMetrics
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var appLanguage: AppLanguage {
        locale.identifier.lowercased().hasPrefix("en") ? .english : .japanese
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.layout(16)) {
            Text(title)
                .font(metrics.font(.title))
                .bold()
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(metrics.font(.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: metrics.layout(10)) {
                Spacer()
                Button(AppLocalizer.text("キャンセル", language: appLanguage), role: .cancel) {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(confirmTitle, role: confirmRole) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(metrics.controlSize)
        }
        .padding(metrics.layout(24))
        .frame(
            minWidth: metrics.layout(420),
            idealWidth: metrics.layout(520),
            minHeight: metrics.layout(210),
            alignment: .leading
        )
    }
}
