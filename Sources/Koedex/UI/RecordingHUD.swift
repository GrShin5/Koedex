import SwiftUI
import AppKit

private enum HUDPalette {
    static let basePill = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let contentPrimary = Color.white.opacity(0.92)
    static let contentSecondary = Color.white.opacity(0.55)
    static let contentTertiary = Color.white.opacity(0.28)
    static let accent = Color(red: 0.345, green: 0.835, blue: 0.647)
    static let accentPressed = Color(red: 0.263, green: 0.725, blue: 0.541)
    static let glyphOnLight = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let errorFlash = Color(red: 1.0, green: 0.42, blue: 0.369).opacity(0.95)
    static let aiCommandIndigo = Color(red: 0.302, green: 0.298, blue: 0.604)
    /// クリップボード入力バリアント。indigoは紫寄り、こちらは青寄りで色相が離れている。
    /// 色だけに頼らず`statusBorder`の静的な外枠とaccessibility labelでも区別する。
    static let aiCommandClipboardSteel = Color(red: 0.145, green: 0.408, blue: 0.573)
    static let aiCommandClipboardOutline = Color(red: 0.612, green: 0.831, blue: 0.949).opacity(0.85)
    static let handsFreeSendTeal = Color(red: 0.184, green: 0.835, blue: 0.742)
    static let handsFreeSendPanel = Color(red: 0.043, green: 0.227, blue: 0.216).opacity(0.96)
    static let warningAmber = Color(red: 0.96, green: 0.68, blue: 0.24)
}

/// HUDパネルの見分けを状態表示から切り離す純粋な優先順位表。
/// クリップボードAI > 通常AI > ハンズフリー送信 > 通常の順に解決する。
enum HUDPanelAppearance: Equatable {
    case normal
    case handsFreeSend
    case aiCommand
    case clipboardAICommand

    static func resolve(
        aiCommandState: AICommandHUDState?,
        aiCommandInputSource: AICommandInputSource,
        handsFreeSendState: HandsFreeSendHUDState?
    ) -> Self {
        if aiCommandState != nil, aiCommandInputSource == .clipboard {
            return .clipboardAICommand
        }
        if aiCommandState != nil { return .aiCommand }
        if handsFreeSendState != nil { return .handsFreeSend }
        return .normal
    }
}

/// 「AIに指示」の入力源による見分けを、SwiftUIから切り離した純粋な判定にする。
/// `AICommandHUDState`を倍に増やさず、直交する軸として扱うための表。
enum AICommandHUDAppearance {
    /// クリップボード入力源の時だけパネル色を変える。
    static func usesClipboardPalette(
        aiCommandState: AICommandHUDState?,
        inputSource: AICommandInputSource
    ) -> Bool {
        aiCommandState != nil && inputSource == .clipboard
    }

    /// 色覚差で色相を読み取れない場合にも入力源が分かるよう、外枠でも示す。
    /// ただし終了間近（アンバー）と失敗（赤）の警告表示はそちらを優先する。
    /// 明滅させない静的な線にする（新しい常時アニメーションはHUDへ足さない）。
    static func showsClipboardOutline(
        aiCommandState: AICommandHUDState?,
        inputSource: AICommandInputSource,
        phaseIsError: Bool
    ) -> Bool {
        guard usesClipboardPalette(aiCommandState: aiCommandState, inputSource: inputSource) else {
            return false
        }
        guard !phaseIsError else { return false }
        return aiCommandState != .recordingEndingSoon && aiCommandState != .failure
    }
}

/// Capsule本体とパネルの座標を共有し、影だけがパネル境界で切れないようにする。
private enum HUDLayout {
    static let pillSize = CGSize(width: 180, height: 54)
    static let shadowInset: CGFloat = 20
    static let screenBottomInset: CGFloat = 80

    static var panelSize: CGSize {
        CGSize(
            width: pillSize.width + (shadowInset * 2),
            height: pillSize.height + (shadowInset * 2)
        )
    }
}

/// 「AIに指示」固有の文字なしHUD表現。nilなら従来の通常モード表示を保つ。
enum AICommandHUDState: Equatable {
    case recording
    case processing
    case webSearching
    case webDisabled
    case success
    case failure
    case recordingEndingSoon
}

/// ハンズフリー送信モード固有の文字なしHUD表現。
/// App側は、実際の擬似キー送信結果に合わせてこの状態だけを短時間表示する。
enum HandsFreeSendHUDState: Equatable {
    case recording
    /// partialで終端トリガーの候補を初めて見つけた状態。録音はまだ継続し、350msの
    /// 安定判定が崩れれば`.recording`へ戻る。
    case triggerCandidate
    case stopping
    /// 停止の収束アニメーションが終わってから挿入完了までの、ループする処理中表示。
    /// `.stopping` は一発きりの収束（約0.35秒）なので、AI整形の1〜6秒を通して
    /// 出したままにすると静止して固まって見える。
    case processing
    /// 音声トリガーを受理し、録音停止とAI整形を同時に進めている状態。
    /// `.stopping`の一発アニメーション完了を待たず、受理直後に表示する。
    case triggerConfirmedProcessing
    case sendArmed
    case sendPosted
    case sendSkipped
}

/// 擬似送信の安全判定とHUD表現を一対一に保つ純粋な対応表。
enum HandsFreeSendHUDFeedbackPolicy {
    static func state(for feedback: SendDispatchFeedback) -> HandsFreeSendHUDState {
        switch feedback {
        case .armed: return .sendArmed
        case .posted: return .sendPosted
        case .skipped: return .sendSkipped
        }
    }

    static func showsPressedReturnGlyph(for feedback: SendDispatchFeedback) -> Bool {
        feedback == .posted
    }
}

/// 録音中・整形中インジケータ、エラー表示を行うフローティングパネル。
/// 国際化不要の視覚表現にするため、HUD内には状態テキストを表示しない。
struct RecordingHUDView: View {
    @ObservedObject var appState: AppState
    var language: AppLanguage = .japanese
    /// phaseに関わらず一時的に表示する状態。nilなら通常表示。
    var overridePhase: PipelinePhase?
    var aiCommandState: AICommandHUDState?
    /// 「AIに指示」の入力源。`AICommandHUDState`を倍に増やさず、直交する軸として持つ。
    var aiCommandInputSource: AICommandInputSource = .selection
    var handsFreeSendState: HandsFreeSendHUDState?
    /// 挿入は成功したが整形へ戻れなかった時だけ使う、赤い失敗と独立した注意表示。
    var transientWarning = false
    /// HUDの常駐サイズを変えず、設定の表示倍率に合わせてglyphと操作部だけを拡大する。
    var glyphScale: CGFloat = 1
    var onCancel: () -> Void = {}
    var onFinish: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var errorBorderFlash = false
    @State private var errorBorderResetTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            if phase == .recording {
                HUDCircleButton(kind: .cancel, language: language, glyphScale: glyphScale, action: onCancel)
                    .transition(transition)
            }

            visual
                .id(phaseKey)
                .frame(width: 74, height: 40)
                .scaleEffect(glyphScale)
                .transition(transition)
                .accessibilityHidden(true)

            if phase == .recording {
                HUDCircleButton(kind: .finish, language: language, glyphScale: glyphScale, action: onFinish)
                    .transition(transition)
            }
        }
        .padding(.horizontal, 13)
        .frame(width: HUDLayout.pillSize.width, height: HUDLayout.pillSize.height)
        .background(
            Capsule()
                .fill(panelColor)
        )
        .background {
            if aiCommandState == nil, handsFreeSendState == nil {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(statusBorder)
        // パネル自体には影を付けず、Capsuleだけに柔らかい影を付ける。
        // 外側の透明余白はこの影が矩形に切り取られないためのもの。
        .shadow(color: Color.black.opacity(0.20), radius: 12, x: 0, y: 4)
        .padding(HUDLayout.shadowInset)
        .frame(width: HUDLayout.panelSize.width, height: HUDLayout.panelSize.height)
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.22), value: phaseKey)
        .accessibilityLabel(accessibilityLabel)
        .onAppear {
            updateErrorFlash()
        }
        .onChange(of: phaseKey) {
            updateErrorFlash()
        }
    }

    private var phase: PipelinePhase {
        overridePhase ?? appState.phase
    }

    private var panelColor: Color {
        switch HUDPanelAppearance.resolve(
            aiCommandState: aiCommandState,
            aiCommandInputSource: aiCommandInputSource,
            handsFreeSendState: handsFreeSendState
        ) {
        case .clipboardAICommand:
            return HUDPalette.aiCommandClipboardSteel
        case .aiCommand:
            return HUDPalette.aiCommandIndigo
        case .handsFreeSend:
            return HUDPalette.handsFreeSendPanel
        case .normal:
            return HUDPalette.basePill.opacity(0.92)
        }
    }

    private var showsClipboardInputOutline: Bool {
        AICommandHUDAppearance.showsClipboardOutline(
            aiCommandState: aiCommandState,
            inputSource: aiCommandInputSource,
            phaseIsError: phase.isError
        )
    }

    @ViewBuilder
    private var visual: some View {
        if let aiCommandState {
            switch aiCommandState {
            case .recording, .recordingEndingSoon:
                RecordingWaveform(level: appState.audioLevel, reduceMotion: reduceMotion)
            case .processing:
                SparkleProcessing(reduceMotion: reduceMotion)
            case .webSearching:
                WebSearchingGlyph(reduceMotion: reduceMotion)
            case .webDisabled:
                WebDisabledGlyph()
            case .success:
                InsertingBar(reduceMotion: reduceMotion)
            case .failure:
                ErrorGlyph(reduceMotion: reduceMotion)
            }
        } else if let handsFreeSendState {
            switch handsFreeSendState {
            case .recording:
                HandsFreeSendWaveform(level: appState.audioLevel, reduceMotion: reduceMotion)
            case .triggerCandidate:
                HandsFreeSendCandidateWaveform(level: appState.audioLevel, reduceMotion: reduceMotion)
            case .stopping:
                HandsFreeSendConvergingWaveform(reduceMotion: reduceMotion)
            case .processing:
                // `SparkleProcessing`は「AIに指示」モードの表示なので使わない。ハンズフリーで
                // 出すとAIへ指示を出したように見え、実機で紛らわしいと報告された（2026-07-30）。
                // ティールの3点ドットにして、通常モード（白/緑）ともAIに指示とも区別する。
                ThinkingDots(color: HUDPalette.handsFreeSendTeal, reduceMotion: reduceMotion)
            case .triggerConfirmedProcessing:
                HandsFreeSendConfirmedProcessingGlyph(reduceMotion: reduceMotion)
            case .sendArmed:
                HandsFreeSendReturnGlyph(state: .armed, reduceMotion: reduceMotion)
            case .sendPosted:
                HandsFreeSendReturnGlyph(state: .posted, reduceMotion: reduceMotion)
            case .sendSkipped:
                EmptyView()
            }
        } else { switch phase {
        case .starting:
            StartingDot(reduceMotion: reduceMotion)
        case .recording:
            RecordingWaveform(level: appState.audioLevel, reduceMotion: reduceMotion)
        case .transcribing:
            ThinkingDots(color: HUDPalette.contentPrimary, reduceMotion: reduceMotion)
        case .cleaning:
            ThinkingDots(color: HUDPalette.accent.opacity(0.95), reduceMotion: reduceMotion)
        case .inserting:
            InsertingBar(reduceMotion: reduceMotion)
        case .error:
            ErrorGlyph(reduceMotion: reduceMotion)
        case .idle:
            EmptyView()
        } }
    }

    @ViewBuilder
    private var statusBorder: some View {
        if transientWarning {
            Capsule().stroke(HUDPalette.warningAmber, lineWidth: 2)
        } else if aiCommandState == .recordingEndingSoon {
            Capsule().stroke(HUDPalette.warningAmber, lineWidth: 2)
                .opacity(reduceMotion ? 1 : (errorBorderFlash ? 1 : 0.35))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: errorBorderFlash)
        } else if (aiCommandState == .failure || phase.isError), !reduceMotion {
            Capsule()
                .stroke(HUDPalette.errorFlash, lineWidth: 1.5)
                .opacity(errorBorderFlash ? 0.9 : 0)
                .animation(.easeInOut(duration: 0.18).repeatCount(4, autoreverses: true), value: errorBorderFlash)
        } else if showsClipboardInputOutline {
            Capsule().stroke(HUDPalette.aiCommandClipboardOutline, lineWidth: 1.5)
        }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92))
    }

    private var phaseKey: String {
        if transientWarning { return "transient-warning-\(String(describing: phase))" }
        if let aiCommandState { return "ai-command-\(String(describing: aiCommandState))" }
        if let handsFreeSendState { return "hands-free-send-\(String(describing: handsFreeSendState))" }
        switch phase {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .cleaning: return "cleaning"
        case .inserting: return "inserting"
        case .error: return "error"
        }
    }

    private var accessibilityLabel: String {
        if transientWarning {
            return language == .japanese
                ? "整形なしでテキストを挿入しました"
                : "Text inserted without cleanup"
        }
        if let aiCommandState {
            // 色と外枠だけに頼らず、入力源を読み上げでも区別できるようにする。
            let sourcePrefix: String
            if aiCommandInputSource == .clipboard {
                sourcePrefix = language == .japanese ? "クリップボードの内容で、" : "Using the clipboard. "
            } else {
                sourcePrefix = ""
            }
            switch aiCommandState {
            case .recording: return sourcePrefix + (language == .japanese ? "AIに指示を録音中" : "Recording AI command")
            case .processing: return sourcePrefix + (language == .japanese ? "AIに指示を処理中" : "Processing AI command")
            case .webSearching: return language == .japanese ? "Web検索中" : "Searching the web"
            case .webDisabled: return language == .japanese ? "Web検索はオフです" : "Web search is off"
            case .success: return sourcePrefix + (language == .japanese ? "AIに指示が完了しました" : "AI command completed")
            case .failure: return sourcePrefix + (language == .japanese ? "AIに指示に失敗しました" : "AI command failed")
            case .recordingEndingSoon: return language == .japanese ? "録音終了まで残り10秒です" : "Recording ends in ten seconds"
            }
        }
        if let handsFreeSendState {
            switch handsFreeSendState {
            case .recording:
                return language == .japanese ? "ハンズフリー送信モードで録音中" : "Recording in hands-free send mode"
            case .triggerCandidate:
                return language == .japanese ? "送信トリガー候補を検出しました。録音を継続しています" : "Send trigger candidate detected. Recording continues."
            case .stopping:
                return language == .japanese ? "録音を終了しています" : "Finishing recording"
            case .processing:
                return language == .japanese ? "整形しています" : "Cleaning up the text"
            case .triggerConfirmedProcessing:
                return language == .japanese ? "送信トリガーを認識し、整形しています" : "Send trigger recognized. Cleaning up the text."
            case .sendArmed:
                return language == .japanese ? "送信キーを準備しています" : "Preparing the send key"
            case .sendPosted:
                return language == .japanese ? "送信キーを入力しました" : "Send key entered"
            case .sendSkipped:
                return language == .japanese ? "送信を中止しました" : "Send skipped"
            }
        }
        switch phase {
        case .idle:
            return ""
        case .starting:
            return language == .japanese ? "録音準備中" : "Preparing to record"
        case .recording:
            return language == .japanese ? "録音中" : "Recording. Audio level responsive."
        case .transcribing:
            return language == .japanese ? "文字起こし中" : "Transcribing"
        case .cleaning:
            return language == .japanese ? "AIアシスト中" : "AI assist in progress"
        case .inserting:
            return language == .japanese ? "テキストを挿入中" : "Inserting text"
        case .error:
            return language == .japanese ? "エラーが発生しました" : "An error occurred"
        }
    }

    private func updateErrorFlash() {
        let shouldFlash = aiCommandState == .failure || aiCommandState == .recordingEndingSoon || phase.isError
        guard shouldFlash, !reduceMotion else {
            errorBorderResetTask?.cancel()
            errorBorderResetTask = nil
            errorBorderFlash = false
            return
        }
        errorBorderResetTask?.cancel()
        errorBorderFlash = false
        DispatchQueue.main.async {
            errorBorderFlash = true
        }
        errorBorderResetTask = Task {
            try? await Task.sleep(nanoseconds: 720_000_000)
            guard !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                errorBorderFlash = false
            }
        }
    }
}

private extension PipelinePhase {
    var isError: Bool { if case .error = self { return true }; return false }
}

private struct SparkleProcessing: View {
    let reduceMotion: Bool
    @State private var pulse = false
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(Color.white.opacity(reduceMotion ? 0.9 : (pulse ? 1 : 0.45)))
            .scaleEffect(reduceMotion ? 1 : (pulse ? 1.05 : 0.92))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

private struct WebSearchingGlyph: View {
    let reduceMotion: Bool
    @State private var rotate = false
    var body: some View {
        ZStack {
            Image(systemName: "globe")
                .font(.system(size: 19, weight: .medium))
            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 29, height: 29)
                .rotationEffect(.degrees(reduceMotion ? 0 : (rotate ? 360 : 0)))
                .animation(reduceMotion ? nil : .linear(duration: 1.3).repeatForever(autoreverses: false), value: rotate)
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .onAppear { rotate = true }
    }
}

private struct WebDisabledGlyph: View {
    var body: some View {
        ZStack {
            Image(systemName: "globe").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
            Rectangle().fill(HUDPalette.errorFlash).frame(width: 29, height: 2.5).rotationEffect(.degrees(-45))
        }
    }
}

private enum HUDCircleButtonKind {
    case cancel
    case finish

    var systemName: String {
        switch self {
        case .cancel: return "xmark"
        case .finish: return "checkmark"
        }
    }

    func accessibilityLabel(for language: AppLanguage) -> String {
        switch self {
        case .cancel: return language == .japanese ? "音声入力をキャンセル" : "Cancel dictation"
        case .finish: return language == .japanese ? "録音を終了して挿入" : "Finish and insert"
        }
    }
}

private struct HUDCircleButton: View {
    let kind: HUDCircleButtonKind
    let language: AppLanguage
    let glyphScale: CGFloat
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.systemName)
                .font(.system(size: 11 * glyphScale, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(HUDCircleButtonStyle(kind: kind, isHovered: isHovered))
        .frame(width: 36, height: 36)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(kind.accessibilityLabel(for: language))
    }
}

private struct HUDCircleButtonStyle: ButtonStyle {
    let kind: HUDCircleButtonKind
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .background(fillColor(isPressed: configuration.isPressed), in: Circle())
            .overlay(cancelBorder)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch kind {
        case .cancel: return Color.white.opacity(0.85)
        case .finish: return HUDPalette.glyphOnLight
        }
    }

    private func fillColor(isPressed: Bool) -> Color {
        switch kind {
        case .cancel:
            if isPressed { return Color.white.opacity(0.22) }
            return isHovered ? Color.white.opacity(0.16) : Color.white.opacity(0.10)
        case .finish:
            if isPressed { return HUDPalette.accentPressed }
            return isHovered ? HUDPalette.accent : Color.white.opacity(0.92)
        }
    }

    @ViewBuilder
    private var cancelBorder: some View {
        if kind == .cancel {
            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct StartingDot: View {
    let reduceMotion: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(HUDPalette.contentSecondary)
            .frame(width: 8, height: 8)
            .scaleEffect(reduceMotion ? 1 : (animate ? 1.3 : 1.0))
            .opacity(reduceMotion ? 0.7 : (animate ? 0.95 : 0.55))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: animate)
            .onAppear {
                animate = true
            }
    }
}

/// Canvas描画クロージャ内から@Stateへ書き込むと「Modifying state during view update」の
/// 未定義動作になり、smoothedが0のまま更新されない（波形が無音ブリージングに固定され
/// 静止して見える）。参照型ホルダーに退避し、描画中の更新を合法化する。
/// @StateはWaveformSmootherインスタンスの保持のみに使う（プロパティ書き込みはSwiftUIの
/// 状態変更ではないため描画クロージャ内から安全に行える）。
private final class WaveformSmoother {
    var smoothed: Double = 0
    private var lastT: Double?

    func update(t: Double, target: Double) -> Double {
        let previous = lastT ?? (t - 1.0 / 60.0)
        let dt = min(t - previous, 1.0 / 15.0)
        lastT = t
        let clamped = min(max(target, 0), 1)
        let tau = (clamped > smoothed) ? 0.05 : 0.35
        let alpha = 1 - exp(-dt / tau)
        smoothed += (clamped - smoothed) * alpha
        return smoothed
    }
}

/// 録音中ずっと走る波形Canvasの再描画間隔。
///
/// 60fpsは過剰だった。1コマごとにMainActorを取るため、音声をSpeechAnalyzerへ
/// 届ける経路（同じMainActor上にある）と録音中ずっと競合し、音声がキューに溜まって
/// 停止後にまとめて処理されていた（2026-07-30の実機ログ: 文字起こし確定が録音長の
/// 約0.5倍に比例。同区間でCGEvent tapのタイムアウトも発生）。
/// 波形は音量に追従して見えれば十分で、`WaveformSmoother` が間を補間する。
///
/// 「視差効果を減らす」が有効なときはさらに大きく下げる。**以前はこの設定で描画内容を
/// 軽くするだけで、再描画の頻度は60fpsのままだった。**
enum WaveformRedrawCadencePolicy {
    static let standardInterval: Double = 1.0 / 30.0
    static let reducedMotionInterval: Double = 1.0 / 10.0

    static func minimumInterval(reduceMotion: Bool) -> Double {
        reduceMotion ? reducedMotionInterval : standardInterval
    }
}

private struct RecordingWaveform: View {
    let level: Double
    let reduceMotion: Bool
    @State private var smoother = WaveformSmoother()

    private let envelope: [Double] = [0.35, 0.55, 0.75, 0.92, 1.0, 0.92, 0.75, 0.55, 0.35]
    private let frequencies: [Double] = [1.7, 2.3, 1.3, 2.9, 2.1, 2.6, 1.5, 2.4, 1.9]

    var body: some View {
        TimelineView(
            .animation(minimumInterval: WaveformRedrawCadencePolicy.minimumInterval(reduceMotion: reduceMotion))
        ) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let smoothed = smoother.update(t: t, target: level)
                drawWaveform(context: &context, size: size, t: t, smoothed: smoothed)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawWaveform(context: inout GraphicsContext, size: CGSize, t: Double, smoothed: Double) {
        let barCount = 9
        let barWidth = 3.0
        let spacing = 3.5
        let minH = 4.0
        let maxH = 30.0
        let totalWidth = Double(barCount) * barWidth + Double(barCount - 1) * spacing
        let startX = (Double(size.width) - totalWidth) / 2
        let centerY = Double(size.height) / 2
        let activeBlend = min(max((smoothed - 0.04) / 0.06, 0), 1)
        let opacity = 0.28 + (0.92 - 0.28) * activeBlend

        for index in 0..<barCount {
            let env = envelope[index]
            let height: Double
            if smoothed >= 0.04 {
                let motion = reduceMotion ? 1.0 : 1 + 0.12 * sin(2 * Double.pi * frequencies[index] * t + 0.7 * Double(index))
                height = min(max(minH + (maxH - minH) * env * smoothed * motion, minH), maxH)
            } else if reduceMotion {
                height = minH
            } else {
                height = minH + 1.5 * env * (0.5 + 0.5 * sin(2 * Double.pi * 0.8 * t + 0.5 * Double(index)))
            }

            let x = startX + Double(index) * (barWidth + spacing)
            let y = centerY - height / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: height)
            let path = Path(roundedRect: rect, cornerSize: CGSize(width: 1.5, height: 1.5))
            context.fill(path, with: .color(Color.white.opacity(opacity)))
        }
    }
}

/// ハンズフリー送信モード用の青緑波形。通常モードの白い波形と見分けられるようにする。
private struct HandsFreeSendWaveform: View {
    let level: Double
    let reduceMotion: Bool
    @State private var smoother = WaveformSmoother()

    private let envelope: [Double] = [0.30, 0.52, 0.76, 0.94, 1.0, 0.94, 0.76, 0.52, 0.30]

    var body: some View {
        TimelineView(
            .animation(minimumInterval: WaveformRedrawCadencePolicy.minimumInterval(reduceMotion: reduceMotion))
        ) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let smoothed = smoother.update(t: t, target: level)
                let barCount = envelope.count
                let barWidth = 3.0
                let spacing = 3.5
                let totalWidth = Double(barCount) * barWidth + Double(barCount - 1) * spacing
                let startX = (Double(size.width) - totalWidth) / 2
                let centerY = Double(size.height) / 2
                for index in 0..<barCount {
                    let breathing = reduceMotion ? 1.0 : 1 + 0.10 * sin(t * 7 + Double(index))
                    let height = max(4, min(30, 4 + 26 * envelope[index] * max(smoothed, 0.08) * breathing))
                    let rect = CGRect(
                        x: startX + Double(index) * (barWidth + spacing),
                        y: centerY - height / 2,
                        width: barWidth,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerSize: CGSize(width: 1.5, height: 1.5)),
                        with: .color(HUDPalette.handsFreeSendTeal.opacity(0.42 + 0.54 * max(smoothed, 0.12)))
                    )
                }
            }
        }
    }
}

/// トリガー候補を検出した瞬間の表示。通常のティール波形を維持しつつ、中央の点滅と
/// 外周リングで「録音は続いているが候補を聞き取った」ことを即時に区別する。
private struct HandsFreeSendCandidateWaveform: View {
    let level: Double
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            HandsFreeSendWaveform(level: level, reduceMotion: reduceMotion)
            Circle()
                .stroke(HUDPalette.handsFreeSendTeal, lineWidth: 1.8)
                .frame(width: 34, height: 34)
                .scaleEffect(reduceMotion ? 1 : (pulse ? 1.16 : 0.88))
                .opacity(reduceMotion ? 0.9 : (pulse ? 0.35 : 0.95))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.32).repeatForever(autoreverses: true),
                    value: pulse
                )
            Circle()
                .fill(HUDPalette.handsFreeSendTeal)
                .frame(width: 6, height: 6)
        }
        .onAppear { pulse = true }
    }
}

/// 音声トリガーの受理とAI整形中を一つの短い視覚表現にする。
/// 受理直後にチェックを表示するため、旧350msの収束アニメーションが終わるまで
/// 「まだ録音中」に見える問題を避けられる。
private struct HandsFreeSendConfirmedProcessingGlyph: View {
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HUDPalette.handsFreeSendTeal)
            ThinkingDots(color: HUDPalette.handsFreeSendTeal, reduceMotion: reduceMotion)
        }
    }
}

/// 音声トリガーまたは停止キーを受け取った直後の合図。
///
/// **「棒が縮む」だけの変化にしてはいけない。** 録音中の`HandsFreeSendWaveform`は音声駆動で、
/// 言葉の切れ目では棒が既に4〜6ptまで下がっている。旧実装は収束後の高さを4ptにしていたため、
/// 発話の切れ目で発火すると見た目がほぼ変わらず合図が届かなかった（2026-07-30の実機報告）。
///
/// そこで「9本の棒」→「中心の点＋広がるリング」という**形の変化**にする。音量に関係なく
/// 認識できるので、ユーザーは安心して発話を止められる。リングは遅延を入れず、棒の収束と
/// 同時に全不透明度で開始する。
private struct HandsFreeSendConvergingWaveform: View {
    let reduceMotion: Bool
    @State private var converged = false
    @State private var pulsed = false

    var body: some View {
        ZStack {
            // 収束しつつ消える棒。高さだけでなく不透明度も落として形の変化を作る。
            HStack(spacing: 3.5) {
                ForEach(0..<9, id: \.self) { index in
                    Capsule()
                        .fill(HUDPalette.handsFreeSendTeal)
                        .frame(width: 3, height: converged ? 4 : 10 + CGFloat(abs(4 - index)) * 2.2)
                        .opacity(converged ? 0 : 0.9)
                }
            }
            .opacity(reduceMotion ? 0 : 1)
            // `.animation`は各Viewへ個別に付ける。ZStack全体に2つ重ねると、`converged`と
            // `pulsed`を同じトランザクションで立てているため片方しか効かない。
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: converged)

            // 合図の本体。検出の瞬間に全不透明度で出す。
            Circle()
                .fill(HUDPalette.handsFreeSendTeal)
                .frame(width: 9, height: 9)
                .opacity(reduceMotion ? 1 : (converged ? 1 : 0))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: converged)

            // 広がって消えるリング。
            Circle()
                .stroke(HUDPalette.handsFreeSendTeal, lineWidth: 2.5)
                .frame(width: 20, height: 20)
                .scaleEffect(reduceMotion ? 1 : (pulsed ? 1.7 : 0.5))
                .opacity(reduceMotion ? 0.85 : (pulsed ? 0 : 1))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.30), value: pulsed)
        }
        .onAppear {
            // 「動きを減らす」設定でも合図は消さない。静止した点＋リングは9本の棒と
            // 形が違うので、アニメーション無しでも録音中と見分けられる。
            guard !reduceMotion else { return }
            converged = true
            pulsed = true
        }
    }
}

private enum HandsFreeSendReturnGlyphState {
    case armed
    case posted
}

/// 実際の擬似Return送信だけに対応する、Return記号の押下フィードバック。
private struct HandsFreeSendReturnGlyph: View {
    let state: HandsFreeSendReturnGlyphState
    let reduceMotion: Bool
    @State private var pressed = false
    @State private var visible = false

    var body: some View {
        Group {
            if #available(macOS 12.0, *) {
                Image(systemName: "return")
            } else {
                Text("⏎")
            }
        }
        .font(.system(size: 26, weight: .semibold))
        .foregroundStyle(HUDPalette.handsFreeSendTeal)
        .scaleEffect(reduceMotion ? 1 : (pressed ? 0.82 : 1))
        .offset(y: reduceMotion ? 0 : (pressed ? 3 : 0))
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeIn(duration: 0.09), value: pressed)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .easeOut(duration: 0.16), value: visible)
        .onAppear {
            switch state {
            case .armed:
                visible = true
            case .posted:
                visible = true
                guard !reduceMotion else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { visible = false }
                    return
                }
                pressed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                    pressed = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    visible = false
                }
            }
        }
    }
}

private struct ThinkingDots: View {
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                ThinkingDot(index: index, color: color, reduceMotion: reduceMotion)
            }
        }
    }
}

private struct ThinkingDot: View {
    let index: Int
    let color: Color
    let reduceMotion: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .scaleEffect(reduceMotion ? 1 : (animate ? 1.0 : 0.6))
            .opacity(reduceMotion ? 0.7 : (animate ? 0.95 : 0.35))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.45)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.15),
                value: animate
            )
            .onAppear {
                animate = true
            }
    }
}

private struct InsertingBar: View {
    let reduceMotion: Bool
    @State private var expanded = false
    @State private var opacityOn = false
    @State private var fallbackPulse = false

    var body: some View {
        Capsule()
            .fill(HUDPalette.accent)
            .frame(width: reduceMotion ? 46 : (expanded ? 46 : 10), height: 3)
            .opacity(reduceMotion ? 1 : (fallbackPulse ? 0.7 : (opacityOn ? 1 : 0)))
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: expanded)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: opacityOn)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: fallbackPulse)
            .onAppear {
                guard !reduceMotion else { return }
                expanded = true
                opacityOn = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    fallbackPulse = true
                }
            }
    }
}

private struct ErrorGlyph: View {
    let reduceMotion: Bool
    @State private var animate = false

    var body: some View {
        Image(systemName: "exclamationmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(HUDPalette.errorFlash)
            .opacity(reduceMotion ? 1.0 : (animate ? 1.0 : 0.55))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: animate)
            .onAppear {
                animate = true
            }
    }
}

@MainActor
final class RecordingHUDController {
    private var panel: NSPanel?
    private let appState: AppState
    private let metricsProvider: @MainActor () -> PopupUIScaleMetrics
    private let languageProvider: @MainActor () -> AppLanguage
    private let onCancelRecording: () -> Void
    private let onFinishRecording: () -> Void
    private var hostingView: NSHostingView<RecordingHUDView>?
    private var transientMessageTask: Task<Void, Never>?
    private var aiCommandState: AICommandHUDState?
    /// 「AIに指示」の入力源。session開始時に一度だけ設定し、`clearAICommandState`と
    /// `hide`で必ず既定へ戻す。残しておくと次のsessionが誤った色で始まる。
    private var aiCommandInputSource: AICommandInputSource = .selection
    private var handsFreeSendState: HandsFreeSendHUDState?
    private var transientWarning = false
    /// 直前の`handsFreeSendState`に切り替わった時刻。滞在時間の計測専用。
    private var handsFreeSendStateEnteredAt: Date?

    init(
        appState: AppState,
        metricsProvider: @escaping @MainActor () -> PopupUIScaleMetrics = {
            PopupUIScaleMetrics(settingsScale: SettingsUIScaleMetrics.standardScale)
        },
        languageProvider: @escaping @MainActor () -> AppLanguage = { .japanese },
        onCancelRecording: @escaping () -> Void,
        onFinishRecording: @escaping () -> Void
    ) {
        self.appState = appState
        self.metricsProvider = metricsProvider
        self.languageProvider = languageProvider
        self.onCancelRecording = onCancelRecording
        self.onFinishRecording = onFinishRecording
    }

    func show() {
        ensurePanel()
        panel?.orderFrontRegardless()
    }

    /// 処理中のHUDはアプリのactive状態に依存しない。外部アプリへ戻っても、
    /// 記録・整形・AI処理の所有権が続く限り表示だけを最前面へ戻す。
    func reassertFrontmostIfVisible() {
        guard panel?.isVisible == true else { return }
        panel?.orderFrontRegardless()
    }

    func hide() {
        // HUDを閉じたらオーバーレイ状態も畳む。残すと次の通常モード録音で
        // ハンズフリーや「AIに指示」の見た目が復活してしまう。
        // ハンズフリーの`.stopping`は挿入完了まで維持する運用なので、
        // 明示クリアを呼び忘れた経路でもここで必ず解除される必要がある。
        aiCommandState = nil
        aiCommandInputSource = .selection
        handsFreeSendState = nil
        transientWarning = false
        panel?.orderOut(nil)
    }

    /// 「AIに指示」の入力源を、そのsessionの最初の表示より前に一度だけ設定する。
    /// `showAICommandState`は12箇所から呼ばれ、その多くはsessionを持たない時点なので、
    /// 状態と入力源は別のAPIに分ける。
    func setAICommandInputSource(_ source: AICommandInputSource) {
        aiCommandInputSource = source
    }

    /// 通常phaseを変更せずに「AIに指示」の状態を表示する。
    func showAICommandState(_ state: AICommandHUDState) {
        ensurePanel()
        transientWarning = false
        handsFreeSendState = nil
        aiCommandState = state
        hostingView?.rootView = makeView(overridePhase: nil)
        panel?.orderFrontRegardless()
    }

    /// 「AIに指示」表示を解除し、通常モードのphase表示へ戻す。
    func clearAICommandState() {
        aiCommandState = nil
        aiCommandInputSource = .selection
        hostingView?.rootView = makeView(overridePhase: nil)
    }

    /// 通常phaseを変更せずにハンズフリー送信モードの状態を表示する。
    /// `sendPosted` は擬似キーを実際に送ったことを示す時だけ使用する。
    func showHandsFreeSendState(_ state: HandsFreeSendHUDState) {
        ensurePanel()
        transientWarning = false
        let now = Date()
        if let previousState = handsFreeSendState, let enteredAt = handsFreeSendStateEnteredAt {
            AppLog.shared.info(String(
                format: "[Telemetry] hfs_hud_dwell state=%@ dwellMs=%.0f",
                String(describing: previousState),
                now.timeIntervalSince(enteredAt) * 1_000
            ))
        }
        handsFreeSendStateEnteredAt = now
        aiCommandState = nil
        handsFreeSendState = state
        hostingView?.rootView = makeView(overridePhase: nil)
        panel?.orderFrontRegardless()
        if state == .sendPosted {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: languageProvider() == .japanese
                        ? "送信キーを入力しました"
                        : "Send key entered"
                ]
            )
        }
    }

    /// ハンズフリー送信モードの一時表示を解除し、通常phase表示へ戻す。
    func clearHandsFreeSendState() {
        handsFreeSendState = nil
        hostingView?.rootView = makeView(overridePhase: nil)
    }

    /// phaseを変えずに一時的なbusyアニメーションをHUDに表示し、
    /// 一定時間後に元の表示へ戻す。無反応をなくすためのフィードバック用。
    func flashBusy(durationSeconds: Double = 1.2) {
        ensurePanel()
        transientMessageTask?.cancel()
        transientWarning = false
        hostingView?.rootView = makeView(overridePhase: .cleaning)
        panel?.orderFrontRegardless()

        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hostingView?.rootView = self.makeView(overridePhase: nil)
            if self.appState.phase == .idle {
                self.hide()
            }
        }
    }

    func flashError(durationSeconds: Double = 2.0) {
        ensurePanel()
        transientMessageTask?.cancel()
        transientWarning = false
        hostingView?.rootView = makeView(overridePhase: .error(""))
        panel?.orderFrontRegardless()

        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hostingView?.rootView = self.makeView(overridePhase: nil)
            if self.appState.phase == .idle {
                self.hide()
            }
        }
    }

    /// 生テキストの挿入自体は成功したため、失敗glyphを出さず既存のamber外枠だけを短時間使う。
    func flashWarning(durationSeconds: Double = 1.5) {
        ensurePanel()
        transientMessageTask?.cancel()
        transientWarning = true
        hostingView?.rootView = makeView(overridePhase: nil)
        panel?.orderFrontRegardless()

        transientMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.transientWarning = false
            self.hostingView?.rootView = self.makeView(overridePhase: nil)
            if self.appState.phase == .idle {
                self.hide()
            }
        }
    }

    private func makeView(overridePhase: PipelinePhase? = nil) -> RecordingHUDView {
        RecordingHUDView(
            appState: appState,
            language: languageProvider(),
            overridePhase: overridePhase,
            aiCommandState: aiCommandState,
            aiCommandInputSource: aiCommandInputSource,
            handsFreeSendState: handsFreeSendState,
            transientWarning: transientWarning,
            glyphScale: metricsProvider().glyphScale,
            onCancel: onCancelRecording,
            onFinish: onFinishRecording
        )
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: makeView())
        hosting.frame = NSRect(origin: .zero, size: HUDLayout.panelSize)
        hosting.wantsLayer = true
        self.hostingView = hosting

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = hosting
        panel.ignoresMouseEvents = false

        positionPanel(panel)
        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        // パネルを影の余白分だけ大きくしても、Capsuleの中心は従来位置に保つ。
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.minY + HUDLayout.screenBottomInset - HUDLayout.shadowInset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
