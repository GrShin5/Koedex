import SwiftUI
import AppKit

struct AICommandResultAction: Identifiable {
    enum Style {
        case primary
        case secondary
    }

    let id: String
    let title: String
    let style: Style
    let handler: () -> Void
}

/// 結果表示は従来どおり前面化するが、外部アプリの操作中に出すWeb確認だけは
/// 入力フォーカスを奪わない。確認後のWeb turnは表示専用なので、この違いを明示する。
enum AICommandResultPresentation: Equatable {
    case activatesApplication
    case nonactivatingConfirmation
}

struct AICommandResultPayload: Identifiable {
    let id = UUID()
    var spokenInstruction: String
    var selectedText: String?
    var answer: String
    var sources: [AICommandSource]
    var title: String = "AIに指示"
    var showsSettingsButton = false
    var notice: String?
    var answerSectionTitle = "回答"
    var copyButtonTitle = "回答をコピー"
    var showsCopyButton = true
    var actions: [AICommandResultAction] = []
    var presentation: AICommandResultPresentation = .activatesApplication
    /// 閉じる・Esc・アプリ終了を含む全てのwindow終了で、一時的な再試行tokenを破棄する。
    var onDismiss: (() -> Void)?

    func copyText(language: AppLanguage) -> String {
        guard !sources.isEmpty else { return answer }
        let links = sources.prefix(3).map { source in
            let label = source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = AppLocalizer.text("参照元", language: language)
            return "- \((label?.isEmpty == false ? label! : source.url.host) ?? fallback): \(source.url.absoluteString)"
        }.joined(separator: "\n")
        let sourcesHeading = AppLocalizer.text("参照元", language: language)
        return "\(answer)\n\n\(sourcesHeading)\n\(links)"
    }

    var copyText: String { copyText(language: .japanese) }
}

@MainActor
final class AICommandResultWindowController {
    private var windows: [UUID: NSWindow] = [:]
    private var delegates: [UUID: WindowCloseDelegate] = [:]
    private let metricsProvider: @MainActor () -> PopupUIScaleMetrics
    private let languageProvider: @MainActor () -> AppLanguage

    init(
        metricsProvider: @escaping @MainActor () -> PopupUIScaleMetrics = {
            PopupUIScaleMetrics(settingsScale: SettingsUIScaleMetrics.standardScale)
        },
        languageProvider: @escaping @MainActor () -> AppLanguage = { .japanese }
    ) {
        self.metricsProvider = metricsProvider
        self.languageProvider = languageProvider
    }

    func show(_ payload: AICommandResultPayload) {
        let metrics = metricsProvider()
        let language = languageProvider()
        let view = AICommandResultView(payload: payload, metrics: metrics, language: language) { [weak self] in
            self?.close(id: payload.id)
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSPanel(contentViewController: hosting)
        window.title = AppLocalizer.text(payload.title, language: language)
        switch payload.presentation {
        case .activatesApplication:
            window.styleMask = [.titled, .closable, .resizable]
        case .nonactivatingConfirmation:
            window.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.becomesKeyOnlyIfNeeded = true
        }
        let defaultSize = metrics.panelSize(CGSize(width: 680, height: 520))
        let minimumSize = metrics.panelSize(CGSize(width: 460, height: 320))
        window.setContentSize(NSSize(width: defaultSize.width, height: defaultSize.height))
        window.minSize = NSSize(width: minimumSize.width, height: minimumSize.height)
        window.isReleasedWhenClosed = false
        window.center()
        let delegate = WindowCloseDelegate { [weak self] in
            payload.onDismiss?()
            self?.windows.removeValue(forKey: payload.id)
            self?.delegates.removeValue(forKey: payload.id)
        }
        delegates[payload.id] = delegate
        window.delegate = delegate
        windows[payload.id] = window
        switch payload.presentation {
        case .activatesApplication:
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case .nonactivatingConfirmation:
            window.orderFrontRegardless()
        }
    }

    func closeAll() {
        let current = windows.values
        current.forEach { $0.close() }
        windows.removeAll()
        delegates.removeAll()
    }

    /// 確認tokenの期限切れではwindowごと閉じ、payloadが保持するaction closureも解放する。
    func dismiss(id: UUID) {
        windows[id]?.close()
    }

    private func close(id: UUID) {
        dismiss(id: id)
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct AICommandResultView: View {
    let payload: AICommandResultPayload
    let metrics: PopupUIScaleMetrics
    let language: AppLanguage
    let onClose: () -> Void
    @State private var showsFullSelection = false
    @State private var didRunAction = false

    private var selectionPreview: String? {
        guard let selected = payload.selectedText else { return nil }
        if showsFullSelection || selected.count <= 1_000 { return selected }
        return String(selected.prefix(1_000)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.layout(14)) {
            HStack(spacing: metrics.layout(10)) {
                Text(AppLocalizer.text(payload.title, language: language)).font(metrics.font(.headline))
                Spacer()
                if payload.showsSettingsButton {
                    Button(AppLocalizer.text("設定を開く", language: language)) {
                        NotificationCenter.default.post(name: .koedexOpenSettings, object: nil)
                    }
                }
                Button(AppLocalizer.text("閉じる", language: language), action: onClose)
            }
            .controlSize(metrics.controlSize)

            ScrollView {
                VStack(alignment: .leading, spacing: metrics.layout(14)) {
                    if !payload.spokenInstruction.isEmpty {
                        section(title: AppLocalizer.text("音声指示", language: language)) {
                            Text(payload.spokenInstruction)
                                .font(metrics.font(.body))
                                .textSelection(.enabled)
                        }
                    }

                    if let selectionPreview {
                        section(title: AppLocalizer.text("選択したテキスト", language: language)) {
                            Text(selectionPreview)
                                .font(metrics.font(.body))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let selected = payload.selectedText, selected.count > 1_000 {
                                Button(AppLocalizer.text(
                                    showsFullSelection ? "一部表示" : "全文を表示",
                                    language: language
                                )) {
                                    showsFullSelection.toggle()
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }

                    if let notice = payload.notice {
                        section(title: AppLocalizer.text("注意", language: language)) {
                            Text(notice)
                                .font(metrics.font(.body))
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }

                    section(title: AppLocalizer.text(payload.answerSectionTitle, language: language)) {
                        Text(payload.answer)
                            .font(metrics.font(.body))
                            .textSelection(.enabled)
                        if !payload.sources.isEmpty {
                            VStack(alignment: .leading, spacing: metrics.layout(6)) {
                                Text(AppLocalizer.text("参照元", language: language)).font(metrics.font(.headline)).bold()
                                ForEach(Array(payload.sources.prefix(3))) { source in
                                    Link(source.title ?? source.url.host ?? source.url.absoluteString, destination: source.url)
                                        .font(metrics.font(.body))
                                }
                            }
                        }
                        if payload.showsCopyButton {
                            Button(AppLocalizer.text(payload.copyButtonTitle, language: language)) { copyAnswer() }
                        }
                    }

                    if !payload.actions.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: metrics.layout(8)) {
                                actionButtons(expands: false)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: metrics.layout(8)) {
                                actionButtons(expands: true)
                            }
                        }
                        .controlSize(metrics.controlSize)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(metrics.layout(20))
        .frame(minWidth: metrics.layout(460), minHeight: metrics.layout(320))
        .environment(\.locale, language.locale)
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: metrics.layout(8)) {
            Text(title).font(metrics.font(.headline)).bold()
            content()
        }
        .padding(metrics.layout(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func actionButtons(expands: Bool) -> some View {
        ForEach(payload.actions) { action in
            actionButton(action, expands: expands)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: AICommandResultAction, expands: Bool) -> some View {
        let button = Button {
            runActionOnce(action)
        } label: {
            Text(AppLocalizer.text(action.title, language: language))
                .frame(maxWidth: expands ? .infinity : nil, alignment: .center)
        }
        .disabled(didRunAction)

        switch action.style {
        case .primary:
            button.buttonStyle(.borderedProminent)
        case .secondary:
            button.buttonStyle(.bordered)
        }
    }

    private func runActionOnce(_ action: AICommandResultAction) {
        guard !didRunAction else { return }
        didRunAction = true
        // 確認tokenはwindowを閉じる前に同期でconsumeする。閉鎖通知は未consume tokenを
        // 破棄するため、この順序を逆にすると再試行が常に失われる。
        action.handler()
        onClose()
    }

    private func copyAnswer() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.copyText(language: language), forType: .string)
    }
}
