import SwiftUI

struct UserDictionaryImportPreview: Identifiable {
    let id = UUID()
    let draft: UserDictionaryImportDraft
}

struct UserDictionaryImportSheet: View {
    let language: AppLanguage
    let metrics: SettingsUIScaleMetrics
    let onConfirm: (UserDictionaryImportDraft) -> Void
    let onCancel: () -> Void
    @State private var draft: UserDictionaryImportDraft

    init(
        preview: UserDictionaryImportPreview,
        language: AppLanguage,
        metrics: SettingsUIScaleMetrics,
        onConfirm: @escaping (UserDictionaryImportDraft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.language = language
        self.metrics = metrics
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _draft = State(initialValue: preview.draft)
    }

    private func uiText(_ japanese: String) -> String {
        AppLocalizer.text(japanese, language: language)
    }

    private func uiFormat(_ japanese: String, _ arguments: CVarArg...) -> String {
        String(format: uiText(japanese), locale: language.locale, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.layout(14)) {
            Text(uiText("CSV読み込みプレビュー"))
                .font(metrics.font(.title)).bold()
            Text(uiText("確定するまでユーザー辞書は変更されません。"))
                .font(metrics.font(.caption)).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.layout(12)) {
                    summary
                    singleConflicts
                    rowsSection(uiText("既存複数の手作業整理"), rows: draft.multipleExistingManualReview, message: uiText("同じ単語が既に複数あります。CSVからは追加せず、辞書画面で整理してください。"))
                    rowsSection(uiText("CSV内重複"), rows: draft.withinFileDuplicates, message: uiText("同じ単語がCSV内で重複しています。CSVを修正してから再読み込みしてください。"))
                    issueSection
                    if projectedEnabledCount > 300 {
                        Text(uiFormat("有効な辞書項目が%d件になります。300件を超えると認識・整形への反映量が増えるため、必要な項目だけを有効にしてください。", projectedEnabledCount))
                            .font(metrics.font(.caption)).foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                Text(uiFormat("確定対象: %d件", confirmableCount))
                    .font(metrics.font(.headline))
                Spacer()
                Button(uiText("キャンセル"), action: onCancel)
                Button(uiText("読み込みを確定")) { onConfirm(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(confirmableCount == 0)
            }
        }
        .padding(metrics.layout(20))
        .frame(minWidth: metrics.contentWidth(560), minHeight: metrics.contentWidth(420))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: metrics.layout(5)) {
            summaryLine("新規件数", draft.additions.count)
            summaryLine("単一既存競合", draft.singleExistingConflicts.count)
            summaryLine("既存複数の手作業整理", draft.multipleExistingManualReview.count)
            summaryLine("CSV内重複", draft.withinFileDuplicates.count)
            summaryLine("行エラー", draft.issues.count)
        }
        .padding(metrics.layout(10))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: metrics.layout(8)))
    }

    private func summaryLine(_ label: String, _ count: Int) -> some View {
        Text(uiFormat("%@: %d件", uiText(label), count))
            .font(metrics.font(.body))
    }

    @ViewBuilder
    private var singleConflicts: some View {
        if !draft.singleExistingConflicts.isEmpty {
            VStack(alignment: .leading, spacing: metrics.layout(8)) {
                Text(uiText("単一既存競合")).font(metrics.font(.headline))
                Text(uiText("既存項目が1件だけ見つかった行は、残す・置換・追加を選べます。初期値は既存のみを残すです。"))
                    .font(metrics.font(.caption)).foregroundStyle(.secondary)
                ForEach(Array(draft.singleExistingConflicts.enumerated()), id: \.offset) { index, conflict in
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(uiFormat("%d行目: %@", conflict.row.physicalLine, conflict.row.preferredForm))
                            Spacer()
                            conflictPicker(index: index, conflict: conflict)
                        }
                        VStack(alignment: .leading, spacing: metrics.layout(4)) {
                            Text(uiFormat("%d行目: %@", conflict.row.physicalLine, conflict.row.preferredForm))
                            conflictPicker(index: index, conflict: conflict)
                        }
                    }
                }
            }
        }
    }

    private func conflictPicker(index: Int, conflict: UserDictionaryImportConflict) -> some View {
        Picker(uiText("競合時の処理"), selection: Binding(
            get: { conflictActionKey(for: draft.action(for: index)) },
            set: { setConflictAction($0, index: index, conflict: conflict) }
        )) {
            Text(uiText("既存のみを残す")).tag("keep")
            Text(uiText("置換する")).tag("replace")
            Text(uiText("同じ語を追加する")).tag("append")
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private func rowsSection(_ title: String, rows: [UserDictionaryCSV.Row], message: String) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: metrics.layout(5)) {
                Text(title).font(metrics.font(.headline))
                Text(message).font(metrics.font(.caption)).foregroundStyle(.secondary)
                Text(rows.map { "\($0.physicalLine)" }.joined(separator: ", "))
                    .font(metrics.font(.caption)).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        if !draft.issues.isEmpty {
            VStack(alignment: .leading, spacing: metrics.layout(5)) {
                Text(uiText("行エラー")).font(metrics.font(.headline))
                ForEach(Array(draft.issues.enumerated()), id: \.offset) { _, issue in
                    Text(uiFormat("%d行目: %@", issue.physicalLine, issueText(issue.reason)))
                        .font(metrics.font(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var confirmableCount: Int {
        draft.additions.count + draft.singleExistingConflicts.enumerated().reduce(0) { count, pair in
            switch draft.action(for: pair.offset) {
            case .keepExisting: return count
            case .replace, .appendDuplicate: return count + 1
            }
        }
    }

    private var projectedEnabledCount: Int {
        var count = draft.existingEntriesSnapshot.filter(\.enabled).count
        count += draft.additions.filter(\.enabled).count
        for (index, conflict) in draft.singleExistingConflicts.enumerated() {
            switch draft.action(for: index) {
            case .keepExisting: break
            case .appendDuplicate:
                if conflict.row.enabled { count += 1 }
            case .replace:
                count += (conflict.row.enabled ? 1 : 0) - (conflict.existingEntry.enabled ? 1 : 0)
            }
        }
        return count
    }

    private func conflictActionKey(for action: UserDictionaryImportConflictAction) -> String {
        switch action {
        case .keepExisting: return "keep"
        case .replace: return "replace"
        case .appendDuplicate: return "append"
        }
    }

    private func setConflictAction(_ key: String, index: Int, conflict: UserDictionaryImportConflict) {
        switch key {
        case "replace": draft.setAction(.replace(existingID: conflict.existingEntry.id), for: index)
        case "append": draft.setAction(.appendDuplicate, for: index)
        default: draft.setAction(.keepExisting, for: index)
        }
    }

    private func issueText(_ reason: UserDictionaryCSV.RowIssue.Reason) -> String {
        switch reason {
        case .tooManyColumns: return uiText("列数が多すぎます")
        case .emptyWord: return uiText("単語が空です")
        case .invalidEnabled: return uiText("有効の値が正しくありません")
        case .wordTooLong: return uiText("単語が長すぎます")
        case .tooManyReadings: return uiText("読み方が多すぎます")
        case .readingTooLong: return uiText("読み方が長すぎます")
        case .notesTooLong: return uiText("補足メモが長すぎます")
        }
    }
}
