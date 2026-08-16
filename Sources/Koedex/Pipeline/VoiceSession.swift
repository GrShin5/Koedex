import Foundation

enum VoiceMode: String, Codable {
    case voiceInput = "voice_input"
    case aiCommand = "ai_command"
}

/// AI応答の意味と、モデルが判定した届け先だけから出力経路を決める。
/// `hasActualSource` は `selectedText != nil` から渡し、`inputSource` だけで
/// 選択／クリップボード本文が実在すると推測してはならない。
enum AICommandOutputRoutingPolicy {
    enum Decision: Equatable {
        case showResult
        case automaticSourceReplacement
        case explicitTargetInsertion
    }

    static func decision(
        kind: AICommandOutcomeKind,
        destinationIntent: AICommandDestinationIntent,
        hasActualSource: Bool
    ) -> Decision {
        switch kind {
        case .clarification, .refusal, .requiresWeb:
            return .showResult
        case .content, .answer:
            break
        }

        switch destinationIntent {
        case .showResult:
            return .showResult
        case .insertAtCapturedTarget:
            return .explicitTargetInsertion
        case .automatic:
            return kind == .content && hasActualSource
                ? .automaticSourceReplacement
                : .showResult
        }
    }
}

@MainActor
final class VoiceSession {
    let id = UUID()
    let mode: VoiceMode
    let startedAt = Date()
    let selectedText: String?
    /// 出力transportの選択に使ってよいのはこの`inputSource`だけ。`selectedText`は
    /// 「モデル入力がある」「選択本文経路なのでWeb検索を禁止する」の判定にのみ使う。
    /// 選択取得もクリップボード取得も`selectedText != nil`になるため、`selectedText`
    /// では区別できない。
    let inputSource: AICommandInputSource
    let aiCommandSettings: AICommandSettings?
    /// ハンズフリー送信モードで開始した通常音声入力にだけ存在する状態。
    let handsFreeSendSession: HandsFreeSendSession?
    /// 外部互換入力が録音開始時に明示有効だったか。外部への擬似送信は、この値と
    /// 送出直前のライブ設定の両方がtrueの時だけ許可する。
    let externalCompatibilityEnabledAtRecordingStart: Bool
    /// 明示されたAI結果の直接挿入について、録音開始時に必要な同意がすべて
    /// 有効だったか。送出時のライブ設定とANDし、処理中の設定変更で権限を広げない。
    let aiCommandExplicitInsertionAllowedAtRecordingStart: Bool
    /// 通常モードはWeb入力欄でも⌘Vを送れるよう、AX要素ではなく前面アプリだけを保存する。
    var normalPasteTarget: NormalPasteTarget?
    /// 選択テキストの置換だけは、従来どおり厳格なAX対象を使う。
    var insertionDestination: InsertionDestination?
    /// `「AIに指示」モード`では、選択本文は録音開始時の`selectedText`を不変の
    /// AI入力として使う。一方、出力先は録音停止時に別途捕捉し、完了時に新しい
    /// キャレットへ再ターゲットしない。
    var aiCommandOutputTarget: NormalPasteTarget?
    var aiCommandOutputDestination: InsertionDestination?
    private(set) var isCancelled = false

    init(
        mode: VoiceMode,
        selectedText: String? = nil,
        inputSource: AICommandInputSource = .selection,
        aiCommandSettings: AICommandSettings? = nil,
        handsFreeSendSnapshot: HandsFreeSendSnapshot? = nil,
        externalCompatibilityEnabledAtRecordingStart: Bool = false,
        aiCommandExplicitInsertionAllowedAtRecordingStart: Bool = false,
        normalPasteTarget: NormalPasteTarget? = nil,
        insertionDestination: InsertionDestination? = nil
    ) {
        self.mode = mode
        self.selectedText = selectedText
        self.inputSource = inputSource
        self.aiCommandSettings = aiCommandSettings
        self.handsFreeSendSession = handsFreeSendSnapshot.map(HandsFreeSendSession.init)
        self.externalCompatibilityEnabledAtRecordingStart = externalCompatibilityEnabledAtRecordingStart
        self.aiCommandExplicitInsertionAllowedAtRecordingStart = aiCommandExplicitInsertionAllowedAtRecordingStart
        self.normalPasteTarget = normalPasteTarget
        self.insertionDestination = insertionDestination
    }

    func cancel() {
        isCancelled = true
    }
}
