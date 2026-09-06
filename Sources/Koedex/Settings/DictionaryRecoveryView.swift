import SwiftUI
import AppKit

struct DictionaryRecoveryView: View {
    @ObservedObject var store: PersonalDictionaryStore
    let language: AppLanguage
    let metrics: SettingsUIScaleMetrics

    @State private var isExpanded = true
    @State private var confirmsEmptyRestart = false
    @State private var operationMessage: String?

    private func text(_ japanese: String) -> String { AppLocalizer.text(japanese, language: language) }
    private func format(_ japanese: String, _ values: CVarArg...) -> String {
        String(format: text(japanese), locale: language.locale, arguments: values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.layout(10)) {
            Label(text("ユーザー辞書を安全に読み込めませんでした"), systemImage: "exclamationmark.triangle.fill")
                .font(metrics.font(.headline))
                .foregroundStyle(.orange)
            Text(text("元の辞書は変更していません。復旧を完了するまで、辞書の追加・編集・削除・CSV読み込みは停止します。音声入力は辞書を使わずに続けられます。"))
                .font(metrics.font(.body))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isExpanded, case .recoveryRequired(let analysis) = store.loadStatus {
                recoveryChoices(analysis)
            } else {
                Button(text("辞書の復旧を再開")) { isExpanded = true }
            }
            if let operationMessage {
                Text(operationMessage).font(metrics.font(.caption)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(metrics.layout(14))
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: metrics.layout(8)))
        .sheet(isPresented: $confirmsEmptyRestart) {
            AppConfirmationSheet(
                title: text("空の辞書で再開"),
                message: text("元の辞書を復旧用バックアップへ安全に保存してから、空の辞書へ置き換えます。保存を確認できない場合は置き換えません。"),
                confirmTitle: text("バックアップして空で再開"),
                confirmRole: .destructive,
                metrics: PopupUIScaleMetrics(settingsMetrics: metrics),
                onConfirm: { confirmsEmptyRestart = false; restartEmpty() },
                onCancel: { confirmsEmptyRestart = false }
            )
        }
    }

    @ViewBuilder
    private func recoveryChoices(_ analysis: DictionaryRecoveryAnalysis) -> some View {
        if !analysis.canReplaceOriginal {
            Text(text("辞書ファイルを読み取れないか、安全な通常ファイルとして確認できません。Koedexから上書きせず、アクセス権や保存場所を確認してから再試行してください。"))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if !analysis.rescuedEntries.isEmpty {
                Text(format(
                    analysis.hasUnknownRemainder
                        ? "完全に確認できた%d件を救出できます。残りの件数は破損範囲が不明なため数えられません。"
                        : "完全に確認できた%d件を救出できます。除外される項目は%d件です。",
                    analysis.rescuedEntries.count,
                    analysis.rejectedEntryCount
                ))
                .fixedSize(horizontal: false, vertical: true)
                Button(text("確認できた項目を救出（推奨）")) { recoverPartial(analysis) }
                    .buttonStyle(.borderedProminent)
            } else {
                Text(text("完全に確認できた項目は0件です。破損範囲に未確認の項目が残っている可能性があります。空で再開すると、それらは新しい辞書には入りません。"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(analysis.candidates) { candidate in
                Button(candidateLabel(candidate)) { recover(candidate, analysis: analysis) }
            }
            Button(text("空の辞書で再開"), role: .destructive) { confirmsEmptyRestart = true }
        }
        HStack {
            Button(text("再試行")) {
                operationMessage = store.retryRecoveryLoad() ? nil : text("まだ辞書を読み込めません。元のファイルは変更していません。")
            }
            Button(text("保存場所をFinderで開く")) {
                NSWorkspace.shared.activateFileViewerSelecting([store.storageDirectoryURL])
            }
            Button(text("後で")) { isExpanded = false }
        }
    }

    private func candidateLabel(_ candidate: DictionaryRecoveryCandidate) -> String {
        let kind = candidate.kind == .lastKnownGood ? text("最後に正常だった辞書") : text("CSV読み込み前のバックアップ")
        let date = candidate.modifiedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? text("日時不明")
        return format("%@から復旧（%d件・%@）", kind, candidate.entryCount, date)
    }

    private func recoverPartial(_ analysis: DictionaryRecoveryAnalysis) {
        guard let fingerprint = analysis.fingerprint else { return }
        perform { try store.recoverRescuedEntries(expectedFingerprint: fingerprint) }
    }
    private func recover(_ candidate: DictionaryRecoveryCandidate, analysis: DictionaryRecoveryAnalysis) {
        guard let fingerprint = analysis.fingerprint else { return }
        perform { try store.recoverFromBackup(candidate, expectedFingerprint: fingerprint) }
    }
    private func restartEmpty() {
        guard case .recoveryRequired(let analysis) = store.loadStatus, let fingerprint = analysis.fingerprint else { return }
        perform { try store.restartEmpty(expectedFingerprint: fingerprint, preservationConfirmed: true) }
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); operationMessage = nil }
        catch DictionaryRecoveryError.staleInput {
            operationMessage = text("辞書ファイルが確認後に変更されました。内容を再解析したので、もう一度選んでください。")
        } catch {
            operationMessage = text("復旧の完了を確認できませんでした。復旧用バックアップは保全しています。再試行する前に現在の辞書内容を確認してください。")
        }
    }
}
