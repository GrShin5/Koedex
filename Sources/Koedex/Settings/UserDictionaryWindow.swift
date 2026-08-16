import SwiftUI
import AppKit
import Foundation

private enum DictionaryViewMode: String, CaseIterable, Identifiable {
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

private enum DictionaryDeletionKind {
    case single
    case selected
    case unselectedDisplayed

    func title(for language: AppLanguage) -> String {
        let japanese: String
        switch self {
        case .single: japanese = "ユーザー辞書項目を削除"
        case .selected: japanese = "チェックしたユーザー辞書項目を削除"
        case .unselectedDisplayed: japanese = "チェックしたもの以外のユーザー辞書項目を削除"
        }
        return AppLocalizer.text(japanese, language: language)
    }
}

private struct DictionaryDeletionRequest {
    var kind: DictionaryDeletionKind
    var targetIDs: Set<UUID>
}

enum UserDictionarySelectionPolicy {
    static func selectedVisibleIDs(selectedIDs: Set<UUID>, visibleIDs: Set<UUID>) -> Set<UUID> {
        selectedIDs.intersection(visibleIDs)
    }

    static func unselectedVisibleIDs(selectedIDs: Set<UUID>, visibleIDs: Set<UUID>) -> Set<UUID> {
        visibleIDs.subtracting(selectedIDs)
    }

    static func areAllVisibleSelected(selectedIDs: Set<UUID>, visibleIDs: Set<UUID>) -> Bool {
        !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIDs)
    }

    static func toggledVisibleSelection(selectedIDs: Set<UUID>, visibleIDs: Set<UUID>) -> Set<UUID> {
        if areAllVisibleSelected(selectedIDs: selectedIDs, visibleIDs: visibleIDs) {
            return selectedIDs.subtracting(visibleIDs)
        }
        return selectedIDs.union(visibleIDs)
    }
}

struct DictionaryImportExportBanner: Identifiable, Equatable {
    let id: UUID
    let message: String
    let isError: Bool

    init(message: String, isError: Bool, id: UUID = UUID()) {
        self.id = id
        self.message = message
        self.isError = isError
    }
}

@MainActor
final class DictionaryCSVBannerState: ObservableObject {
    @Published private(set) var banner: DictionaryImportExportBanner?
    @Published private(set) var isImportPreparing = false

    private var operationGeneration = 0
    private var dismissalTask: Task<Void, Never>?

    deinit {
        dismissalTask?.cancel()
    }

    func beginOperation() -> Int {
        operationGeneration += 1
        return operationGeneration
    }

    func beginImportOperation() -> Int {
        isImportPreparing = true
        return beginOperation()
    }

    /// Import button state belongs to the in-flight read, not its generation.
    /// A newer export/template operation makes the read result stale, but the
    /// read still has to release the disabled button when it completes.
    func finishImportOperation(operationGeneration: Int) -> Bool {
        isImportPreparing = false
        return isCurrent(operationGeneration: operationGeneration)
    }

    func isCurrent(operationGeneration: Int) -> Bool {
        operationGeneration == self.operationGeneration
    }

    static func dismissalDelay(isError: Bool) -> Duration {
        isError ? .seconds(6) : .seconds(4)
    }

    @discardableResult
    func show(
        message: String,
        isError: Bool,
        for operationGeneration: Int,
        dismissalDelay: Duration
    ) -> Bool {
        guard isCurrent(operationGeneration: operationGeneration) else { return false }

        dismissalTask?.cancel()
        let nextBanner = DictionaryImportExportBanner(message: message, isError: isError)
        banner = nextBanner
        dismissalTask = Task { [weak self, bannerID = nextBanner.id] in
            do {
                try await Task.sleep(for: dismissalDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.dismiss(bannerID: bannerID)
        }
        return true
    }

    func dismiss(bannerID: UUID) {
        guard banner?.id == bannerID else { return }
        banner = nil
        dismissalTask = nil
    }

    func cancelDismissal() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }
}

struct UserDictionaryWindow: View {
    @ObservedObject var dictionaryStore: PersonalDictionaryStore
    let language: AppLanguage
    @Environment(\.settingsUIScaleMetrics) private var uiMetrics

    @State private var searchText = ""
    @State private var showDisabledEntries = true
    @State private var editingID: UUID?
    @State private var preferredForm = ""
    @State private var spokenForms = ""
    @State private var notes = ""
    @State private var enabled = true
    @State private var dictionaryViewMode: DictionaryViewMode = .normal
    @State private var selectedDictionaryIDs: Set<UUID> = []
    @State private var dictionaryDeletionRequest: DictionaryDeletionRequest?
    @State private var showOptionalFields = false
    @State private var importPreview: UserDictionaryImportPreview?
    @StateObject private var csvBannerState = DictionaryCSVBannerState()

    private func uiText(_ japanese: String) -> String {
        AppLocalizer.text(japanese, language: language)
    }

    private func uiFormat(_ japanese: String, _ arguments: CVarArg...) -> String {
        String(format: uiText(japanese), locale: language.locale, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(14)) {
            header
            addOrEditPanel
            Divider()
            controls
            entriesList
        }
        .padding(.horizontal, uiMetrics.layout(20))
        .padding(.bottom, uiMetrics.layout(20))
        .padding(.top, uiMetrics.layout(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: dictionaryDeletionConfirmationBinding) {
            AppConfirmationSheet(
                title: dictionaryDeletionTitle,
                message: dictionaryDeletionMessage,
                confirmTitle: uiText("削除"),
                confirmRole: .destructive,
                metrics: PopupUIScaleMetrics(settingsMetrics: uiMetrics),
                onConfirm: { performDictionaryDeletion() },
                onCancel: { dictionaryDeletionRequest = nil }
            )
        }
        .sheet(item: $importPreview) { preview in
            UserDictionaryImportSheet(
                preview: preview,
                language: language,
                metrics: uiMetrics,
                onConfirm: { draft in applyImport(draft) },
                onCancel: { importPreview = nil }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: uiMetrics.layout(14)) {
                    headerText
                    Spacer(minLength: uiMetrics.layout(12))
                    fileActions
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                    headerText
                    fileActions
                }
            }
            if let importExportBanner = csvBannerState.banner {
                Text(importExportBanner.message)
                    .font(uiMetrics.font(.caption))
                    .foregroundStyle(importExportBanner.isError ? .red : .green)
                    .padding(uiMetrics.layout(8))
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: uiMetrics.layout(6)))
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            Text(uiText("ユーザー辞書"))
                .font(uiMetrics.font(.title))
                .bold()
            Text(uiText("固有名詞、人名、会社名、プロジェクト名、略称など、AIアシストで優先したい表記を登録します。聞こえ方や補足メモは、1つの単語に対する任意の説明です。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var fileActions: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(6)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: uiMetrics.layout(8)) { fileActionButtons }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) { fileActionButtons }
            }
            Text(uiText("CSVファイルでは、データの区切りにカンマを使用します。そのため、1つの読み仮名の中にカンマ（,）を含めることはできません。「有効」には TRUE または FALSE を入力してください。空欄は TRUE として読み込みます。"))
                .font(uiMetrics.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: uiMetrics.contentWidth(500), alignment: .leading)
    }

    @ViewBuilder
    private var fileActionButtons: some View {
        Button(uiText("CSVを書き出す")) { exportDictionary() }
            .disabled(dictionaryStore.entries.isEmpty)
        Button(uiText("CSVを読み込む")) { chooseImportFile() }
            .disabled(csvBannerState.isImportPreparing)
        Button(uiText("テンプレートCSVをダウンロード")) { saveTemplate() }
    }

    private var addOrEditPanel: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
            HStack {
                Text(uiText(editingID == nil ? "単語を登録" : "単語を編集"))
                    .font(uiMetrics.font(.headline))
                Spacer()
                if editingID != nil {
                    Button(uiText("新規登録に戻る")) {
                        clearForm()
                    }
                }
            }

            TextField(uiText("単語・表記（例: Koedex）"), text: $preferredForm)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Button {
                showOptionalFields.toggle()
            } label: {
                HStack(spacing: uiMetrics.layout(6)) {
                    Image(systemName: showOptionalFields ? "chevron.down" : "chevron.right")
                        .font(uiMetrics.font(.caption))
                    Text(uiText("任意の補足を追加"))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showOptionalFields {
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    TextField(uiText("読み方・聞こえ方 等（カンマ区切りで列挙）"), text: $spokenForms)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: uiMetrics.contentWidth(760), alignment: .leading)
                    Text(uiText("音声認識で出やすい読み、呼び方、誤変換、別表記を入れます。例: コエデックス, Koedex"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    TextField(uiText("補足メモ（任意）"), text: $notes)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: uiMetrics.contentWidth(760), alignment: .leading)
                    Text(uiText("この単語だけに効く文脈説明です。全体の文体や出力ルールはカスタムインストラクションに書いてください。"))
                        .font(uiMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.leading, uiMetrics.layout(2))
                .padding(.trailing, uiMetrics.layout(14))
                .frame(maxWidth: uiMetrics.contentWidth(780), alignment: .leading)
            }

            Toggle(uiText("有効"), isOn: $enabled)
                .toggleStyle(.checkbox)

            HStack {
                Button(uiText(editingID == nil ? "辞書に追加" : "変更を保存")) {
                    saveForm()
                }
                .disabled(preferredForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if editingID != nil {
                    Button(uiText("キャンセル")) {
                        clearForm()
                    }
                }
            }
        }
        .padding(uiMetrics.layout(12))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: uiMetrics.layout(8)))
        .frame(maxWidth: uiMetrics.contentWidth(860), alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: uiMetrics.layout(12)) {
                    dictionaryControls
                    Spacer()
                }
                VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                    dictionaryControls
                }
            }

            Picker(uiText("辞書操作"), selection: $dictionaryViewMode) {
                ForEach(DictionaryViewMode.allCases) { mode in
                    Text(mode.label(for: language)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: uiMetrics.contentWidth(360), alignment: .leading)

            if dictionaryViewMode == .selectToDelete {
                dictionarySelectionControls
            }
        }
    }

    @ViewBuilder
    private var dictionaryControls: some View {
        TextField(uiText("検索"), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: uiMetrics.contentWidth(360))
        Toggle(uiText("無効単語も表示"), isOn: $showDisabledEntries)
            .toggleStyle(.checkbox)
    }

    private var dictionarySelectionControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: uiMetrics.layout(8)) {
                dictionarySelectionActionButtons
            }
            VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
                dictionarySelectionActionButtons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var dictionarySelectionActionButtons: some View {
        Button(uiText(areAllVisibleDictionaryEntriesSelected ? "選択を解除" : "すべて選択")) {
            toggleVisibleDictionarySelection()
        }
        .disabled(filteredEntries.isEmpty)

        Button(uiText("チェックしたものをすべて削除"), role: .destructive) {
            requestDeleteSelectedDictionaryEntries()
        }
        .disabled(selectedVisibleDictionaryIDs.isEmpty)

        Button(uiText("チェックしたもの以外をすべて削除"), role: .destructive) {
            requestDeleteUnselectedDisplayedDictionaryEntries()
        }
        .disabled(unselectedVisibleDictionaryIDs.isEmpty)
    }

    private var entriesList: some View {
        Group {
            if filteredEntries.isEmpty {
                Text(uiText(dictionaryStore.entries.isEmpty ? "登録済みの単語はありません。" : "条件に一致する単語はありません。"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .textSelection(.enabled)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: uiMetrics.layout(10)) {
                        ForEach(filteredEntries) { entry in
                            entryRow(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func entryRow(_ entry: PersonalDictionaryEntry) -> some View {
        let isSelectionMode = dictionaryViewMode == .selectToDelete

        return VStack(alignment: .leading, spacing: uiMetrics.layout(8)) {
            HStack(alignment: .firstTextBaseline) {
                if isSelectionMode {
                    Toggle("", isOn: dictionarySelectionBinding(for: entry.id))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(uiFormat("ユーザー辞書項目を選択: %@", entry.preferredForm))
                } else {
                    Toggle("", isOn: Binding(
                        get: { entry.enabled },
                        set: { dictionaryStore.setEnabled(id: entry.id, enabled: $0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }

                VStack(alignment: .leading, spacing: uiMetrics.layout(4)) {
                    Text(entry.preferredForm)
                        .font(uiMetrics.font(.body))
                        .bold()
                        .textSelection(.enabled)
                    if !entry.spokenForms.isEmpty {
                        Text(uiFormat("聞こえ方・読み方・呼び方: %@", entry.spokenForms.joined(separator: ", ")))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if !entry.notes.isEmpty {
                        Text(uiFormat("補足メモ: %@", entry.notes))
                            .font(uiMetrics.font(.caption))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                if !isSelectionMode {
                    Button(uiText("編集")) {
                        startEditing(entry)
                    }
                    Button(uiText("削除"), role: .destructive) {
                        requestDeleteDictionaryEntry(entry.id)
                    }
                }
            }
        }
        .padding(uiMetrics.layout(10))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: uiMetrics.layout(8)))
        .opacity(entry.enabled ? 1 : 0.55)
    }

    private var filteredEntries: [PersonalDictionaryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return dictionaryStore.entries.filter { entry in
            if !showDisabledEntries && !entry.enabled {
                return false
            }
            guard !query.isEmpty else { return true }
            let haystack = ([entry.preferredForm] + entry.spokenForms + [entry.notes])
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private var visibleDictionaryIDs: Set<UUID> {
        Set(filteredEntries.map(\.id))
    }

    private var selectedVisibleDictionaryIDs: Set<UUID> {
        UserDictionarySelectionPolicy.selectedVisibleIDs(
            selectedIDs: selectedDictionaryIDs,
            visibleIDs: visibleDictionaryIDs
        )
    }

    private var unselectedVisibleDictionaryIDs: Set<UUID> {
        UserDictionarySelectionPolicy.unselectedVisibleIDs(
            selectedIDs: selectedDictionaryIDs,
            visibleIDs: visibleDictionaryIDs
        )
    }

    private var areAllVisibleDictionaryEntriesSelected: Bool {
        UserDictionarySelectionPolicy.areAllVisibleSelected(
            selectedIDs: selectedDictionaryIDs,
            visibleIDs: visibleDictionaryIDs
        )
    }

    private func dictionarySelectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedDictionaryIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedDictionaryIDs.insert(id)
                } else {
                    selectedDictionaryIDs.remove(id)
                }
            }
        )
    }

    private func toggleVisibleDictionarySelection() {
        selectedDictionaryIDs = UserDictionarySelectionPolicy.toggledVisibleSelection(
            selectedIDs: selectedDictionaryIDs,
            visibleIDs: visibleDictionaryIDs
        )
    }

    private func requestDeleteDictionaryEntry(_ id: UUID) {
        dictionaryDeletionRequest = DictionaryDeletionRequest(kind: .single, targetIDs: [id])
    }

    private func requestDeleteSelectedDictionaryEntries() {
        let ids = selectedVisibleDictionaryIDs
        guard !ids.isEmpty else { return }
        dictionaryDeletionRequest = DictionaryDeletionRequest(kind: .selected, targetIDs: ids)
    }

    private func requestDeleteUnselectedDisplayedDictionaryEntries() {
        let ids = unselectedVisibleDictionaryIDs
        guard !ids.isEmpty else { return }
        dictionaryDeletionRequest = DictionaryDeletionRequest(kind: .unselectedDisplayed, targetIDs: ids)
    }

    private var dictionaryDeletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { dictionaryDeletionRequest != nil },
            set: { if !$0 { dictionaryDeletionRequest = nil } }
        )
    }

    private var dictionaryDeletionTitle: String {
        dictionaryDeletionRequest?.kind.title(for: language)
            ?? uiText("ユーザー辞書項目を削除")
    }

    private var dictionaryDeletionMessage: String {
        guard let request = dictionaryDeletionRequest else {
            return uiText("このユーザー辞書項目を削除します。この操作は元に戻せません。")
        }
        switch request.kind {
        case .single:
            return uiText("このユーザー辞書項目を削除します。この操作は元に戻せません。")
        case .selected, .unselectedDisplayed:
            return uiFormat(
                "現在表示中のユーザー辞書項目 %d件を削除します。検索や表示設定で隠れている項目は削除しません。この操作は元に戻せません。",
                request.targetIDs.count
            )
        }
    }

    private func performDictionaryDeletion() {
        guard let request = dictionaryDeletionRequest else { return }
        dictionaryStore.delete(ids: request.targetIDs)
        selectedDictionaryIDs.subtract(request.targetIDs)
        if let editingID, request.targetIDs.contains(editingID) {
            clearForm()
        }
        dictionaryDeletionRequest = nil
    }

    private func exportDictionary() {
        let operationGeneration = csvBannerState.beginOperation()
        UserDictionaryFileIO.export(entries: dictionaryStore.entries, language: language) { result in
            switch result {
            case .success:
                showCSVBanner(
                    message: uiText("CSVを書き出しました。"),
                    isError: false,
                    operationGeneration: operationGeneration
                )
            case .failure(let error):
                guard !isUserCancelledFileOperation(error) else { return }
                showCSVBanner(
                    message: uiText("CSVを書き出せませんでした。"),
                    isError: true,
                    operationGeneration: operationGeneration
                )
            }
        }
    }

    private func saveTemplate() {
        let operationGeneration = csvBannerState.beginOperation()
        UserDictionaryFileIO.saveTemplate(language: language) { result in
            switch result {
            case .success:
                showCSVBanner(
                    message: uiText("テンプレートCSVを保存しました。"),
                    isError: false,
                    operationGeneration: operationGeneration
                )
            case .failure(let error):
                guard !isUserCancelledFileOperation(error) else { return }
                showCSVBanner(
                    message: uiText("テンプレートCSVを保存できませんでした。"),
                    isError: true,
                    operationGeneration: operationGeneration
                )
            }
        }
    }

    private func chooseImportFile() {
        let operationGeneration = csvBannerState.beginImportOperation()
        UserDictionaryFileIO.chooseImportFile { result in
            switch result {
            case .success(let url):
                prepareImport(
                    url: url,
                    existingEntries: dictionaryStore.entries,
                    operationGeneration: operationGeneration
                )
            case .failure(let error):
                guard csvBannerState.finishImportOperation(operationGeneration: operationGeneration) else { return }
                guard !isUserCancelledFileOperation(error) else { return }
                showCSVBanner(
                    message: isFileTooLarge(error)
                        ? uiText("CSVファイルは8 MiB以下にしてください。")
                        : uiText("CSVを読み込めませんでした。"),
                    isError: true,
                    operationGeneration: operationGeneration
                )
            }
        }
    }

    private func prepareImport(
        url: URL,
        existingEntries: [PersonalDictionaryEntry],
        operationGeneration: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<UserDictionaryImportDraft, Error>
            let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: UserDictionaryCSV.maximumFileBytes + 1) ?? Data()
                guard data.count <= UserDictionaryCSV.maximumFileBytes else {
                    throw UserDictionaryFileIO.FileIOError.fileTooLarge
                }
                let parsed = try UserDictionaryCSV.parse(data: data)
                result = .success(UserDictionaryImportPlanner.makeDraft(parseResult: parsed, existingEntries: existingEntries))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard csvBannerState.finishImportOperation(operationGeneration: operationGeneration) else { return }
                switch result {
                case .success(let draft):
                    importPreview = UserDictionaryImportPreview(draft: draft)
                case .failure(let error):
                    showCSVBanner(
                        message: isFileTooLarge(error)
                            ? uiText("CSVファイルは8 MiB以下にしてください。")
                            : uiText("CSVを読み込めませんでした。CSVの形式、文字コード、行数を確認してください。"),
                        isError: true,
                        operationGeneration: operationGeneration
                    )
                }
            }
        }
    }

    private func applyImport(_ draft: UserDictionaryImportDraft) {
        let operationGeneration = csvBannerState.beginOperation()
        do {
            let receipt = try dictionaryStore.applyImport(draft)
            searchText = ""
            showDisabledEntries = true
            dictionaryViewMode = .normal
            selectedDictionaryIDs = []
            importPreview = nil
            showCSVBanner(
                message: uiFormat("読み込みが完了しました。追加: %d件、置換: %d件、既存を維持: %d件。", receipt.insertedCount, receipt.replacedCount, receipt.keptExistingCount),
                isError: false,
                operationGeneration: operationGeneration
            )
        } catch PersonalDictionaryStore.ImportError.staleSnapshot {
            importPreview = nil
            showCSVBanner(
                message: uiText("辞書がプレビュー後に変更されました。CSVを再読み込みしてから、もう一度確定してください。"),
                isError: true,
                operationGeneration: operationGeneration
            )
        } catch {
            importPreview = nil
            showCSVBanner(
                message: uiText("CSVの読み込みを確定できませんでした。もう一度試してください。"),
                isError: true,
                operationGeneration: operationGeneration
            )
        }
    }

    private func showCSVBanner(message: String, isError: Bool, operationGeneration: Int) {
        _ = csvBannerState.show(
            message: message,
            isError: isError,
            for: operationGeneration,
            dismissalDelay: DictionaryCSVBannerState.dismissalDelay(isError: isError)
        )
    }

    private func isUserCancelledFileOperation(_ error: Error) -> Bool {
        guard let fileError = error as? UserDictionaryFileIO.FileIOError else { return false }
        return fileError == .cancelled
    }

    private func isFileTooLarge(_ error: Error) -> Bool {
        if let fileError = error as? UserDictionaryFileIO.FileIOError, fileError == .fileTooLarge {
            return true
        }
        if let csvError = error as? UserDictionaryCSV.FileError, csvError == .fileTooLarge {
            return true
        }
        return false
    }

    private func saveForm() {
        let forms = splitCommaSeparated(spokenForms)
        if let editingID {
            dictionaryStore.update(
                id: editingID,
                preferredForm: preferredForm,
                spokenForms: forms,
                notes: notes,
                enabled: enabled
            )
        } else {
            dictionaryStore.add(
                preferredForm: preferredForm,
                spokenForms: forms,
                notes: notes
            )
            if !enabled, let id = dictionaryStore.entries.first?.id {
                dictionaryStore.setEnabled(id: id, enabled: false)
            }
        }
        clearForm()
    }

    private func startEditing(_ entry: PersonalDictionaryEntry) {
        editingID = entry.id
        preferredForm = entry.preferredForm
        spokenForms = entry.spokenForms.joined(separator: ", ")
        notes = entry.notes
        enabled = entry.enabled
        showOptionalFields = !entry.spokenForms.isEmpty || !entry.notes.isEmpty
    }

    private func clearForm() {
        editingID = nil
        preferredForm = ""
        spokenForms = ""
        notes = ""
        enabled = true
        showOptionalFields = false
    }

    private func splitCommaSeparated(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}
