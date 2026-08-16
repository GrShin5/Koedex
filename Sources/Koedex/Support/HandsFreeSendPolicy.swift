import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// ハンズフリー送信モードのトリガーは、言語別の既定句か単一のカスタム句から選ぶ。
enum HandsFreeSendTriggerSource: String, Codable, CaseIterable, Hashable {
    case preset
    case custom
}

/// 通常モードの擬似送信に許可する、固定された3種類のキーストローク。
enum SendKeyStroke: String, Codable, CaseIterable, Hashable {
    case plainReturn = "return"
    case commandReturn = "command_return"
    case controlReturn = "control_return"

    var displayLabel: String {
        switch self {
        case .plainReturn: return "Enter"
        case .commandReturn: return "⌘ Enter"
        case .controlReturn: return "⌃ Enter"
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .plainReturn: return []
        case .commandReturn: return .maskCommand
        case .controlReturn: return .maskControl
        }
    }

    var keyCode: CGKeyCode { CGKeyCode(kVK_Return) }
}

/// ハンズフリー送信モードの永続設定。
/// 外部互換経路での自動送信同意は、既存のAI編集同意とは意図的に分離する。
struct HandsFreeSendSettings: Codable, Equatable {
    var enabled: Bool
    /// 開始と停止を兼ねる単一のトグルChord。停止専用bindingは持たない。
    var binding: HotkeyBinding
    var triggerSource: HandsFreeSendTriggerSource
    var customPhrase: String
    var sendKey: SendKeyStroke
    var allowExternalAutoSend: Bool
    /// ハンズフリー送信で安全に挿入できた出力だけを保存するか。
    /// 通常モードの履歴とは独立して保持期間を選べる。
    var historyEnabled: Bool
    /// ハンズフリー送信履歴の保存期間（日数）。0以下なら無期限。
    var historyRetentionDays: Int

    static let defaultBinding = HotkeyBinding.handsFreeSend
    /// v21より前の既定（Fn+左Shift）。移行の判定にだけ使う。
    /// 保存値がこれと一致する場合は「ユーザーが選んだ値」ではなく旧既定なので、
    /// 片手で押せる新しい既定へ移す。明示的に変更した値は尊重する。
    static let legacyDefaultBinding = HotkeyBinding(keys: [.function, .leftShift])

    static let `default` = HandsFreeSendSettings(
        enabled: false,
        binding: defaultBinding,
        triggerSource: .preset,
        customPhrase: "",
        sendKey: .plainReturn,
        allowExternalAutoSend: false,
        historyEnabled: true,
        historyRetentionDays: 0
    )

    init(
        enabled: Bool = false,
        binding: HotkeyBinding = HandsFreeSendSettings.defaultBinding,
        triggerSource: HandsFreeSendTriggerSource = .preset,
        customPhrase: String = "",
        sendKey: SendKeyStroke = .plainReturn,
        allowExternalAutoSend: Bool = false,
        historyEnabled: Bool = true,
        historyRetentionDays: Int = 0
    ) {
        self.enabled = enabled
        self.binding = binding.isValid ? binding : Self.defaultBinding
        self.triggerSource = triggerSource
        self.customPhrase = customPhrase
        self.sendKey = sendKey
        self.allowExternalAutoSend = allowExternalAutoSend
        self.historyEnabled = historyEnabled
        self.historyRetentionDays = Self.normalizedHistoryRetentionDays(historyRetentionDays)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 旧スキーマは開始/停止の2本を持っていた。旧stopBindingは破棄する。
        // 旧開始bindingが旧既定そのままなら新既定（Fn+右Shift）へ移す。ユーザーが
        // 明示的に選んだ値は尊重する。
        let storedBinding: HotkeyBinding
        if let current = try? container.decodeIfPresent(HotkeyBinding.self, forKey: .binding) {
            storedBinding = current
        } else if let legacy = try? container.decodeIfPresent(HotkeyBinding.self, forKey: .startBinding) {
            storedBinding = legacy == Self.legacyDefaultBinding ? Self.defaultBinding : legacy
        } else {
            storedBinding = Self.defaultBinding
        }
        self.init(
            enabled: (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
            binding: storedBinding,
            triggerSource: (try? container.decodeIfPresent(HandsFreeSendTriggerSource.self, forKey: .triggerSource)) ?? .preset,
            customPhrase: (try? container.decodeIfPresent(String.self, forKey: .customPhrase)) ?? "",
            sendKey: (try? container.decodeIfPresent(SendKeyStroke.self, forKey: .sendKey)) ?? .plainReturn,
            allowExternalAutoSend: (try? container.decodeIfPresent(Bool.self, forKey: .allowExternalAutoSend)) ?? false,
            historyEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .historyEnabled)) ?? true,
            historyRetentionDays: (try? container.decodeIfPresent(Int.self, forKey: .historyRetentionDays)) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(binding, forKey: .binding)
        try container.encode(triggerSource, forKey: .triggerSource)
        try container.encode(customPhrase, forKey: .customPhrase)
        try container.encode(sendKey, forKey: .sendKey)
        try container.encode(allowExternalAutoSend, forKey: .allowExternalAutoSend)
        try container.encode(historyEnabled, forKey: .historyEnabled)
        try container.encode(historyRetentionDays, forKey: .historyRetentionDays)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, binding, triggerSource, customPhrase, sendKey, allowExternalAutoSend
        case historyEnabled, historyRetentionDays
        /// 旧スキーマからの読み取り専用キー。書き出しはしない。
        case startBinding
    }

    private static func normalizedHistoryRetentionDays(_ days: Int) -> Int {
        switch days {
        case ...0, 1, 30, 180:
            return days
        case 2...30:
            return 30
        default:
            return 180
        }
    }
}

/// ハンズフリー送信の起動キー（開始と停止を兼ねるトグル）を保存する前の競合判定。
/// 通常Fnと Fn+右Shift のような**前方一致は意図的に許可する**。既定値がまさにその形であり、
/// 取り合いは `shouldDeferNormalHoldStart` とChord成立時のトラッキングリセットで解決される。
enum HandsFreeSendHotkeyPolicy {
    static func canUse(
        _ binding: HotkeyBinding,
        normalStart: HotkeyBinding,
        aiCommandStart: HotkeyBinding,
        aiCommandStop: HotkeyBinding
    ) -> Bool {
        guard binding.isValid,
              !binding.isKnownSystemReserved,
              !binding.conflictsExactly(with: normalStart),
              !binding.conflictsExactly(with: aiCommandStart),
              !binding.conflictsExactly(with: aiCommandStop) else {
            return false
        }
        // AI開始Chordとの前方一致は、どちらを開始するかを安全に一意化できない。
        return !binding.isStrictPrefix(of: aiCommandStart)
            && !aiCommandStart.isStrictPrefix(of: binding)
    }
}

/// 録音開始時に固定するハンズフリー送信の判断材料。
/// ライブ設定は送信直前にも再確認するため、この値だけで後追い有効化はできない。
struct HandsFreeSendSnapshot: Equatable {
    let settings: HandsFreeSendSettings
    let sttLanguage: AppLanguage
    let streamID: UUID
    let externalCompatibilityEnabledAtRecordingStart: Bool
    /// 通常モードで保存した指示を、ハンズフリー録音の開始時点で固定する。
    /// 録音中の設定変更を進行中のAI整形へ混ぜないため、保存先には使わない。
    let normalModeCustomInstruction: String

    init(
        settings: HandsFreeSendSettings,
        sttLanguage: AppLanguage,
        streamID: UUID = UUID(),
        externalCompatibilityEnabledAtRecordingStart: Bool,
        normalModeCustomInstruction: String = ""
    ) {
        self.settings = settings
        self.sttLanguage = sttLanguage
        self.streamID = streamID
        self.externalCompatibilityEnabledAtRecordingStart = externalCompatibilityEnabledAtRecordingStart
        self.normalModeCustomInstruction = normalModeCustomInstruction
    }
}

/// 通常入力とハンズフリー送信で使うカスタムインストラクションの解決規則。
/// 通常入力は現在の保存値を使う一方、ハンズフリー送信は録音開始時の値を必ず使う。
enum NormalInputCustomInstructionPolicy {
    static func resolve(
        handsFreeSendSnapshot: HandsFreeSendSnapshot?,
        liveCustomInstruction: String
    ) -> String {
        handsFreeSendSnapshot?.normalModeCustomInstruction ?? liveCustomInstruction
    }
}

/// カスタムフレーズは、誤認時の不可逆送信を増やさない最小限の構文だけ許可する。
enum HandsFreeSendCustomPhrasePolicy {
    static let minimumGraphemeCount = 4
    static let maximumGraphemeCount = 20

    static func normalizedPhrase(_ phrase: String) -> String? {
        guard !phrase.contains(where: { $0.isNewline }) else { return nil }
        let normalized = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count >= minimumGraphemeCount,
              normalized.count <= maximumGraphemeCount,
              !containsQuotedLiteralMarker(normalized),
              !HandsFreeSendTriggerPolicy.presetPhrases.contains(where: {
                  normalized.caseInsensitiveCompare($0) == .orderedSame
              }) else {
            return nil
        }
        return normalized
    }

    static func isValid(_ phrase: String) -> Bool { normalizedPhrase(phrase) != nil }

    private static func containsQuotedLiteralMarker(_ text: String) -> Bool {
        text.contains { "「」\"`".contains($0) }
    }
}

/// partial検出とfinal sanitizationを分けるための、UI非依存のトリガー解析器。
/// 検出は候補を返すだけで、録音停止の所有権を取得しない。
///
/// 設計上の制約（2026-07-30の実機障害の再発防止）:
/// この解析は録音中の暫定結果ごとにMainActor上で呼ばれる。MainActorは音声バッファの
/// 供給とCGEvent tapコールバックも担うため、ここが重いとtapがタイムアウトして
/// アプリ全体のホットキーが停止する。したがって
///   1. 正規表現は録音開始時に一度だけコンパイルし、呼び出しごとに作らない
///   2. 走査対象は末尾ウィンドウに限定し、本文側に遅延量指定子を置かない
///   3. 正規表現の前に文字列containsの足切りを通す
/// の3点を必ず維持すること。
enum HandsFreeSendTriggerPolicy {
    static let japanesePresetPhrases = ["ストップ送信", "ストップそうしん"]
    static let englishPresetPhrase = "send now"
    static let presetPhrases = japanesePresetPhrases + [englishPresetPhrase]

    /// 末尾だけを見る窓。トリガー句と許容尾語より十分長く、探索範囲を定数に固定する。
    static let tailWindowLength = 48
    /// トリガー句の後ろに許す、句読点・空白以外の文字数（「だね」「です」等の尾語）。
    static let maximumTrailingResidualLength = 4

    /// 録音セッション開始時に一度だけ構築する。partialごとの再コンパイルを避ける。
    struct CompiledTriggers {
        let expressions: [NSRegularExpression]
        /// 正規表現を走らせる前の安価な足切りに使う、小文字化済みの必須トークン。
        let prefilterTokens: [String]

        var isEmpty: Bool { expressions.isEmpty }

        static let disabled = CompiledTriggers(expressions: [], prefilterTokens: [])
    }

    static func compileTriggers(
        settings: HandsFreeSendSettings,
        sttLanguage: AppLanguage
    ) -> CompiledTriggers {
        guard settings.enabled else { return .disabled }
        var expressions: [NSRegularExpression] = []
        var prefilterTokens: [String] = []
        for segments in triggerSegments(settings: settings, sttLanguage: sttLanguage) {
            guard let lastSegment = segments.last,
                  !lastSegment.isEmpty,
                  let expression = try? NSRegularExpression(
                      pattern: pattern(for: segments),
                      options: [.caseInsensitive]
                  ) else {
                continue
            }
            expressions.append(expression)
            prefilterTokens.append(lastSegment.lowercased())
        }
        return CompiledTriggers(expressions: expressions, prefilterTokens: prefilterTokens)
    }

    /// 本文が空でも候補として返す。トリガー句だけの発話（例:「ストップ送信」単独）で
    /// 検出が一度も発火しなかった実機報告（2026-07-30）を受け、`terminalMatch` の
    /// 空本文除外をここでは外している。空本文の扱いは呼び出し側の
    /// `isTriggerOnlyUtterance` / `resolveHandsFreeSendTranscript` が既に正しく処理する。
    static func partialCandidate(
        in transcript: String,
        triggers: CompiledTriggers
    ) -> HandsFreeSendPartialTriggerCandidate? {
        guard let match = rawTerminalMatch(in: transcript, triggers: triggers) else { return nil }
        let trimmedBody = match.body.trimmingCharacters(in: bodyTrimCharacterSet)
        let outputBody = trimmedBody + terminalSentencePunctuation(in: match.separator)
        return HandsFreeSendPartialTriggerCandidate(body: outputBody, matchedTrigger: match.trigger)
    }

    static func sanitizeFinalTranscript(
        _ transcript: String,
        triggers: CompiledTriggers
    ) -> HandsFreeSendSanitizedTranscript? {
        guard let match = terminalMatch(in: transcript, triggers: triggers) else { return nil }
        return HandsFreeSendSanitizedTranscript(
            transcriptWithoutTrigger: match.outputBody,
            matchedTrigger: match.trigger
        )
    }

    /// 録音中のホットパスでは使わない。設定値からその場でコンパイルする低頻度用。
    static func partialCandidate(
        in transcript: String,
        settings: HandsFreeSendSettings,
        sttLanguage: AppLanguage
    ) -> HandsFreeSendPartialTriggerCandidate? {
        partialCandidate(
            in: transcript,
            triggers: compileTriggers(settings: settings, sttLanguage: sttLanguage)
        )
    }

    static func sanitizeFinalTranscript(
        _ transcript: String,
        settings: HandsFreeSendSettings,
        sttLanguage: AppLanguage
    ) -> HandsFreeSendSanitizedTranscript? {
        sanitizeFinalTranscript(
            transcript,
            triggers: compileTriggers(settings: settings, sttLanguage: sttLanguage)
        )
    }

    /// 本文が無く、トリガー句だけで終わっている発話か。
    ///
    /// **末尾のトリガー句を繰り返し剥がしてから判定する。** 1回しか剥がさないと
    /// 「ストップ送信ストップ送信」で1回目が本文として残り、トリガー句そのものが
    /// 挿入・送信されてしまう（2026-07-30の実機報告）。
    ///
    /// この判定が真のとき、呼び出し側は本文を挿入せず送信キーだけを送る。
    /// 入力なしで改行・送信したい場面のための挙動である。
    static func isTriggerOnlyUtterance(
        _ transcript: String,
        triggers: CompiledTriggers
    ) -> Bool {
        guard rawTerminalMatch(in: transcript, triggers: triggers) != nil else { return false }
        return strippingTrailingTriggers(transcript, triggers: triggers).isEmpty
    }

    /// 末尾のトリガー句を繰り返し剥がし、残った本文を返す。
    /// トリガー句が1つも無ければ元の文字列をトリムして返す。
    static func strippingTrailingTriggers(
        _ transcript: String,
        triggers: CompiledTriggers
    ) -> String {
        var current = transcript
        // トリガー句は最短でも2文字あるため、入力長で必ず停止する。
        while let match = rawTerminalMatch(in: current, triggers: triggers) {
            let stripped = match.body.trimmingCharacters(in: bodyTrimCharacterSet)
            if stripped == current { break }
            current = stripped
            if current.isEmpty { break }
        }
        return current.trimmingCharacters(in: bodyTrimCharacterSet)
    }

    private static func terminalMatch(
        in transcript: String,
        triggers: CompiledTriggers
    ) -> TerminalMatch? {
        guard let match = rawTerminalMatch(in: transcript, triggers: triggers),
              !match.body.trimmingCharacters(in: bodyTrimCharacterSet).isEmpty else {
            return nil
        }
        return TerminalMatch(
            body: match.body.trimmingCharacters(in: bodyTrimCharacterSet),
            separator: match.separator,
            trigger: match.trigger
        )
    }

    /// 本文が空でも返す下位版。空判定は呼び出し側が行う。
    private static func rawTerminalMatch(
        in transcript: String,
        triggers: CompiledTriggers
    ) -> TerminalMatch? {
        guard !triggers.isEmpty else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 全文には正規表現を掛けない。末尾ウィンドウだけを見る。
        let window = tailWindow(of: trimmed)
        let loweredWindow = window.lowercased()
        guard triggers.prefilterTokens.contains(where: { loweredWindow.contains($0) }) else {
            return nil
        }

        // 複数のトリガー句が一致した場合は、最も後ろで一致したものを採用する。
        var bestRange: Range<String.Index>?
        for expression in triggers.expressions {
            let searchRange = NSRange(window.startIndex..<window.endIndex, in: window)
            guard let lastMatch = expression.matches(in: window, options: [], range: searchRange).last,
                  let range = Range(lastMatch.range, in: window),
                  !range.isEmpty else {
                continue
            }
            if let current = bestRange, range.lowerBound <= current.lowerBound { continue }
            bestRange = range
        }
        guard let bestRange else { return nil }
        guard acceptsTrailing(String(window[bestRange.upperBound...])) else { return nil }

        // 本文は正規表現から取らず、一致したトリガー句の開始位置で全文を切る。
        let distanceFromEnd = window.distance(from: bestRange.lowerBound, to: window.endIndex)
        let cutIndex = trimmed.index(trimmed.endIndex, offsetBy: -distanceFromEnd)
        let rawBody = String(trimmed[..<cutIndex])
        return TerminalMatch(
            body: rawBody,
            separator: trailingSeparatorRun(of: rawBody),
            trigger: String(window[bestRange])
        )
    }

    /// 設定画面と初回セットアップに表示するプリセット句。
    /// **音声認識言語だけに依存する。** UI表示言語では切り替わらないため、
    /// ローカライズキーではなくこのリテラルをそのまま表示すること。
    static func presetDisplayPhrase(sttLanguage: AppLanguage) -> String {
        switch sttLanguage {
        case .japanese: return "ストップ送信"
        case .english: return "Send Now"
        }
    }

    static func triggerSegments(
        settings: HandsFreeSendSettings,
        sttLanguage: AppLanguage
    ) -> [[String]] {
        switch settings.triggerSource {
        case .preset:
            return presetSegments(sttLanguage: sttLanguage)
        case .custom:
            guard let phrase = HandsFreeSendCustomPhrasePolicy.normalizedPhrase(settings.customPhrase) else {
                // 無効なカスタムフレーズで空を返すと音声トリガーが無言で死ぬ。
                // 設定画面が赤字で警告する前提で、プリセットへフォールバックする。
                return presetSegments(sttLanguage: sttLanguage)
            }
            return [phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)]
        }
    }

    private static func presetSegments(sttLanguage: AppLanguage) -> [[String]] {
        switch sttLanguage {
        case .japanese:
            return [["ストップ", "送信"], ["ストップ", "そうしん"]]
        case .english:
            return [["send", "now"]]
        }
    }

    /// 区切り許容は語の切れ目だけに置く。1文字ごとに置くと組合せ爆発の温床になる。
    private static func pattern(for segments: [String]) -> String {
        let joined = segments
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "[\\s、,。.!！?？]*")
        // ラテン文字の句だけ語境界を付ける。日本語には\bが効かない。
        let leadingBoundary = isASCIILetter(segments.first?.first) ? "\\b" : ""
        let trailingBoundary = isASCIILetter(segments.last?.last) ? "\\b" : ""
        return leadingBoundary + joined + trailingBoundary
    }

    private static func isASCIILetter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isASCII && character.isLetter
    }

    private static func tailWindow(of text: String) -> String {
        guard text.count > tailWindowLength else { return text }
        return String(text.suffix(tailWindowLength))
    }

    /// トリガー句の後ろに残る文字列は、句読点・空白に加えて短い尾語だけ許す。
    /// これにより「ストップ、送信だね。」は一致し、
    /// 「ストップ送信の設定を確認したい」は引き続き不一致になる。
    ///
    /// 長さだけで許すと「ストップ送信ボタン」のように別の語が続く発話も通ってしまう。
    /// 尾語として現れるのは活用語尾（ひらがな）と短い英単語だけなので、
    /// 漢字・カタカナが残る場合は別語の始まりと判断して不一致にする。
    private static func acceptsTrailing(_ trailing: String) -> Bool {
        guard !trailing.contains(where: { $0.isNewline }) else { return false }
        let residual = trailing.filter { !isSeparatorCharacter($0) }
        guard residual.count <= maximumTrailingResidualLength else { return false }
        return residual.allSatisfy(isAllowedTrailingCharacter)
    }

    private static func isAllowedTrailingCharacter(_ character: Character) -> Bool {
        if character.isASCII, character.isLetter { return true }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        // ひらがなブロックと、濁点・半濁点・繰り返し記号。
        return (0x3041...0x3096).contains(scalar.value)
            || (0x3099...0x309F).contains(scalar.value)
    }

    private static func isSeparatorCharacter(_ character: Character) -> Bool {
        character.isWhitespace || "、,。.!！?？".contains(character)
    }

    private static func trailingSeparatorRun(of text: String) -> String {
        String(text.reversed().prefix(while: isSeparatorCharacter).reversed())
    }

    private static let bodyTrimCharacterSet = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "、,。.!！?？"))

    private static func terminalSentencePunctuation(in separator: String) -> String {
        let sentenceTerminators: Set<Character> = ["。", ".", "!", "！", "?", "？"]
        for character in separator.reversed() where sentenceTerminators.contains(character) {
            return String(character)
        }
        return ""
    }

    private struct TerminalMatch {
        let body: String
        let separator: String
        let trigger: String

        var outputBody: String {
            body + terminalSentencePunctuation(in: separator)
        }
    }
}

struct HandsFreeSendPartialTriggerCandidate: Equatable {
    let body: String
    let matchedTrigger: String
}

struct HandsFreeSendSanitizedTranscript: Equatable {
    let transcriptWithoutTrigger: String
    let matchedTrigger: String
}

/// 録音開始時点で固定する、送信後処理に必要な最小情報。
struct SendAfterInsertRequest: Equatable {
    let sessionID: UUID
    let mode: VoiceMode
    let keyStroke: SendKeyStroke
    let externalCompatibilityEnabledAtRecordingStart: Bool
    let externalCompatibilityAutoSendEnabledAtRecordingStart: Bool
}

enum SendAfterInsertEligibility: Equatable {
    case directAXVerified
    /// クリップボードを使わないUnicode本文イベントを送出した。本文反映はAXで確認
    /// できないため、Return直前に停止時と同一の編集可能AX要素を必ず再確認する。
    case unicodeSubmitted
    /// trigger-only発話。本文の反映確認はできないため、外部互換と自動送信の
    /// 二重同意を必須にし、停止時の編集可能targetも別途再確認する。
    case triggerOnlyValidated
    case notEligible
}

enum SendKeyDispatchResult: Equatable {
    case sent
    case notAuthorized
    case cancelledOrStale
    case missingTarget
    case secureInputBlocked
    case targetChanged
    case focusedElementOrTextChanged
    case eventCreationFailed
}

/// HUDなどが送信の実行状態を追うための内部フィードバック。
enum SendDispatchFeedback: Equatable {
    case armed
    case posted
    case skipped
}

/// 検出時の設定と、送出直前のライブ設定を分けて評価する。
enum SendKeyDispatchPolicy {
    static func shouldDispatch(
        request: SendAfterInsertRequest?,
        eligibility: SendAfterInsertEligibility,
        currentSettings: HandsFreeSendSettings,
        externalCompatibilityEnabled: Bool
    ) -> Bool {
        guard let request,
              request.mode == .voiceInput,
              currentSettings.enabled else {
            return false
        }
        switch eligibility {
        case .directAXVerified:
            return true
        case .unicodeSubmitted, .triggerOnlyValidated:
            return request.externalCompatibilityEnabledAtRecordingStart
                && request.externalCompatibilityAutoSendEnabledAtRecordingStart
                && currentSettings.allowExternalAutoSend
                && externalCompatibilityEnabled
        case .notEligible:
            return false
        }
    }
}

/// Koedexが送出した合成キーイベントを、HotkeyManagerが録音開始・停止として
/// 消費しないための用途別の印。外部入力transportを追加しても、ユーザー操作と
/// 自己送出イベントを区別できるようにする。
enum SyntheticInputEventTag {
    static let sendKeyUserData: Int64 = 0x4843_5345_4E44
    static let unicodeTextUserData: Int64 = 0x4843_554E_4943
    static let selectionCopyUserData: Int64 = 0x4843_434F_5059
    static let scopedClipboardPasteUserData: Int64 = 0x4843_5041_5354

    static func matches(userData: Int64) -> Bool {
        switch userData {
        case sendKeyUserData, unicodeTextUserData, selectionCopyUserData,
             scopedClipboardPasteUserData:
            return true
        default:
            return false
        }
    }

    static func matches(_ event: CGEvent) -> Bool { matches(userData: event.getIntegerValueField(.eventSourceUserData)) }
    static func markSendKey(_ event: CGEvent) { event.setIntegerValueField(.eventSourceUserData, value: sendKeyUserData) }
    static func markUnicodeText(_ event: CGEvent) { event.setIntegerValueField(.eventSourceUserData, value: unicodeTextUserData) }
    static func markSelectionCapture(_ event: CGEvent) { event.setIntegerValueField(.eventSourceUserData, value: selectionCopyUserData) }
    static func markScopedClipboardPaste(_ event: CGEvent) { event.setIntegerValueField(.eventSourceUserData, value: scopedClipboardPasteUserData) }
}
