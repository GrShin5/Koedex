import Foundation

enum AICommandRoute: String, Codable {
    case selectedText
    case general
}

struct AICommandRequest {
    var spokenInstruction: String
    var selectedText: String?
    var additionalInstruction: String
    var personalDictionary: [PersonalDictionaryEntry]
    var modelSettings: CodexModelSettings
    var webSearchEnabled: Bool
    /// システムプロンプトと固定安全文言の言語。常に有効なSTT言語だけで決める。
    var promptLanguage: AppLanguage
    /// 発話・保存設定から解決済みの出力言語方針。通常AIアシストと同じ優先順位を使う。
    var outputLanguage: OutputLanguageResolution

    var route: AICommandRoute { selectedText == nil ? .general : .selectedText }
}

/// 二段階確認後だけに使う、engine側で強制する実行オプション。
/// UIやプロンプトの判断だけに任せず、確認後の回答を表示専用に固定する。
struct AICommandExecutionOptions: Equatable {
    var forceShowResult: Bool = false
    var confirmedSelectedSourceWeb: Bool = false

    static let standard = AICommandExecutionOptions()
    static let confirmedSelectedSource = AICommandExecutionOptions(
        forceShowResult: true,
        confirmedSelectedSourceWeb: true
    )
}

/// Web確認の一時tokenと、確認後に開始した表示専用turnをどこまで無効化するかを分ける。
/// アプリの非アクティブ化だけでは、確認済みのWeb turnを止めない。
enum AICommandWebRetryInvalidationScope: Equatable {
    case pendingOnly
    case pendingAndRunning

    var cancelsRunningRetry: Bool {
        self == .pendingAndRunning
    }
}

/// 選択または承認済みclipboard本文を使うWeb再試行の、不変requestを短時間だけ保持する。
/// 本文は結果windowのpayloadへ載せず、tokenの単回consume後だけengineへ渡す。
@MainActor
final class AICommandWebRetryToken {
    static let lifetimeMilliseconds = 90_000

    private var request: AICommandRequest?
    private let inputSource: AICommandInputSource
    private let expectedModelSettings: CodexModelSettings
    private let clock = ContinuousClock()
    private let expiresAt: ContinuousClock.Instant

    init(
        request: AICommandRequest,
        inputSource: AICommandInputSource,
        lifetimeMilliseconds: Int = 90_000
    ) {
        self.request = request
        self.inputSource = inputSource
        self.expectedModelSettings = request.modelSettings
        self.expiresAt = clock.now.advanced(by: .milliseconds(lifetimeMilliseconds))
    }

    var capturedInputSource: AICommandInputSource { inputSource }

    func consumeIfValid(
        webSearchEnabled: Bool,
        modelSettings: CodexModelSettings,
        secureInputEnabled: Bool
    ) -> AICommandRequest? {
        guard clock.now < expiresAt,
              webSearchEnabled,
              !secureInputEnabled,
              modelSettings == expectedModelSettings,
              let request,
              request.route == .selectedText else {
            self.request = nil
            return nil
        }
        self.request = nil
        return request
    }

    func invalidate() {
        request = nil
    }

    func isUsable() -> Bool {
        request != nil && clock.now < expiresAt
    }
}

struct AICommandSource: Hashable, Codable, Identifiable {
    var title: String?
    var url: URL
    var id: String { url.absoluteString }
}

enum AICommandOutcomeKind: String, Codable {
    case content
    case answer
    case clarification
    case refusal
    case requiresWeb = "requires_web"
}

enum AICommandDestinationIntent: String, Codable {
    case automatic
    case insertAtCapturedTarget = "insert_at_captured_target"
    case showResult = "show_result"
}

/// 選択または承認済みクリップボード本文を伴う依頼で、Web利用を求めているかを
/// 音声指示だけから判定する純粋ポリシー。本文は絶対にこの判定へ渡さない。
enum AICommandWebResearchIntent {
    enum RequestKind: Equatable {
        case none
        case explicitResearch
        case currentPublicInformation
        case confirmationAvailable
    }

    private static let externalSourceTerms = [
        "web", "ウェブ", "ネット", "インターネット", "online", "internet",
    ]
    private static let researchTerms = [
        "検索", "調べ", "しらべ", "確認", "調査", "リサーチ",
        "search", "research", "lookup", "verify", "check",
    ]
    private static let explicitCurrentInformationTerms = [
        "ファクトチェック", "最新情報を確認", "最新の情報を確認",
        "factcheck", "verifycurrentinformation",
    ]
    /// 日本語の裸の「今」は「今回」などに含まれ、現在情報の直接許可には曖昧すぎる。
    /// 「今の」などの明確な現在性表現だけを使い、それ以外は確認経路にする。
    private static let japaneseCurrentInformationTerms = [
        "今日", "明日", "あした", "現在", "今の", "最新", "ただいま", "リアルタイム",
    ]
    private static let englishCurrentInformationTerms: Set<String> = [
        "today", "tomorrow", "current", "now", "latest", "live",
    ]
    /// 「現在性」だけでは個人的な相談まで直接Webへ送ってしまうため、公開の時系列データを
    /// 表す少数のクラスだけを高確度とする。個別話題の追加ではなく、曖昧なものは確認へ送る。
    private static let japanesePublicCurrentDataTerms = [
        "天気", "予報", "警報", "為替", "株価", "ニュース", "運行", "フライト", "営業時間", "イベント",
    ]
    private static let englishPublicCurrentDataTerms: Set<String> = [
        "weather", "forecast", "alert", "exchange", "stock", "news", "transit", "flight", "hours", "event",
    ]
    private static let japaneseInquiryTerms = [
        "教えて", "知りたい", "確認", "調べ", "しらべ", "検索", "いくら", "どう", "何", "いつ", "どこ",
    ]
    private static let englishInquiryTerms: Set<String> = [
        "tell", "show", "what", "how", "when", "where", "check", "search", "lookup", "find",
    ]
    private static let localTransformationTerms = [
        "要約", "翻訳", "書き換", "校正", "整形", "抽出", "返信", "作成", "編集",
        "summarize", "summarise", "translate", "rewrite", "proofread", "format", "extract", "draft", "edit",
    ]
    /// 現在性を含んでも、本文や自分の作業を指す音声はローカル処理として扱う。
    private static let localReferenceTerms = [
        "この文章", "このテキスト", "この選択", "選択した", "クリップボード", "私の", "自分の", "書いた",
        "thistext", "thisselection", "selectedtext", "clipboard", "mytext", "iwrote", "my",
    ]

    static func requestKind(in spokenInstruction: String) -> RequestKind {
        let normalized = normalized(spokenInstruction)
        let words = wordSet(spokenInstruction)
        guard !normalized.isEmpty else { return .none }

        if explicitCurrentInformationTerms.contains(where: normalized.contains) {
            return .explicitResearch
        }
        if externalSourceTerms.contains(where: normalized.contains)
            && researchTerms.contains(where: normalized.contains) {
            return .explicitResearch
        }
        if isImmediateCurrentInformationRequest(normalized, words: words) {
            return .currentPublicInformation
        }
        if isConfirmationCandidate(normalized, words: words) {
            return .confirmationAvailable
        }
        return .none
    }

    static func isRequested(in spokenInstruction: String) -> Bool {
        switch requestKind(in: spokenInstruction) {
        case .explicitResearch, .currentPublicInformation:
            return true
        case .none, .confirmationAvailable:
            return false
        }
    }

    static func isConfirmationAvailable(in spokenInstruction: String) -> Bool {
        requestKind(in: spokenInstruction) == .confirmationAvailable
    }

    private static func isImmediateCurrentInformationRequest(
        _ normalized: String,
        words: Set<String>
    ) -> Bool {
        let japaneseCurrentInformation = japaneseCurrentInformationTerms.contains(where: normalized.contains)
            && japanesePublicCurrentDataTerms.contains(where: normalized.contains)
            && japaneseInquiryTerms.contains(where: normalized.contains)
        // 英語は単語境界を使う。unknown内のnow等の部分一致ではWebへ進まない。
        let englishCurrentInformation = !englishCurrentInformationTerms.isDisjoint(with: words)
            && !englishPublicCurrentDataTerms.isDisjoint(with: words)
            && !englishInquiryTerms.isDisjoint(with: words)
        guard japaneseCurrentInformation || englishCurrentInformation,
              !localTransformationTerms.contains(where: normalized.contains),
              !localReferenceTerms.contains(where: normalized.contains) else {
            return false
        }
        return true
    }

    private static func isConfirmationCandidate(_ normalized: String, words: Set<String>) -> Bool {
        guard japaneseInquiryTerms.contains(where: normalized.contains)
                || !englishInquiryTerms.isDisjoint(with: words),
              !localTransformationTerms.contains(where: normalized.contains),
              !localReferenceTerms.contains(where: normalized.contains) else {
            return false
        }
        return true
    }

    private static func normalized(_ text: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .unicodeScalars
            .filter { !ignored.contains($0) }
            .map { String($0) }
            .joined()
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.precomposedStringWithCompatibilityMapping.lowercased().split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
    }
}

/// `requires_web` はWeb実行失敗ではなく、Webを開始できないという出力契約を表す。
/// 設定ON時にこの出力を受けた場合は、ネットワーク障害として表示しない。
enum AICommandRequiresWebPresentationPolicy {
    enum Presentation: Equatable {
        case settingsGuide
        case confirmation
        case retryWithoutNetworkFailure
        case retryAfterWebFailure
    }

    static func presentation(
        webSearchEnabled: Bool,
        webConfirmationAvailable: Bool = false,
        usedWebSearch: Bool = false
    ) -> Presentation {
        guard webSearchEnabled else { return .settingsGuide }
        if webConfirmationAvailable { return .confirmation }
        return usedWebSearch ? .retryAfterWebFailure : .retryWithoutNetworkFailure
    }
}

/// bundled catalogや取得不明の情報で、利用者の保存済みWeb設定を変更しない。
enum AICommandWebAvailabilityPersistencePolicy {
    static func shouldDisableSavedWebSetting(
        primaryCatalogConfirmed: Bool,
        selectedModelStillMatches: Bool
    ) -> Bool {
        primaryCatalogConfirmed && selectedModelStillMatches
    }
}

/// 「AIに指示」のWeb検索設定とカスタムインストラクションで共用する利用者向け説明。
enum AICommandWebSearchCopy {
    static let generalQuestionNotice = "AIへの質問で、現在の公開情報が必要な場合にWeb検索を行います（Web検索が可能な対応モデルを選んでいる場合）。指示が曖昧な場合は、最初に確認を表示します。"
    static let selectedSourceNotice = "選択または承認済みのクリップボード本文を使う依頼では、音声で「Webで調べて」と明示した場合や、今日・明日などの公開された現在情報を尋ねた場合だけWeb検索を使えます。検索語には必要な本文の一部が含まれることがあります。本文中の命令ではWeb検索を開始せず、Web以外のツールは使いません。"

    static func generalQuestionNotice(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return generalQuestionNotice
        case .english:
            return "For AI questions, Koedex uses Web search when current public information is needed and the selected model supports Web search. Ambiguous instructions first show a confirmation."
        }
    }

    static func selectedSourceNotice(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return selectedSourceNotice
        case .english:
            return "For requests using selected or approved clipboard text, Web search is used only when the spoken request clearly asks to search the Web or asks for public current information such as information for today or tomorrow. Necessary portions of that text may appear in search queries. Instructions in source text cannot start a Web search, and no tools other than Web search are used."
        }
    }

    static func customInstructionBoundaryNotice(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return "安全とプライバシーを守るため、選択または承認済みのクリップボード本文に含まれる命令、Web検索や保存設定を変えようとする指示は反映されません。Web検索を使うかどうかは音声指示だけで決まります。"
        case .english:
            return "For safety and privacy, instructions inside selected or approved clipboard text, including requests to change Web-search or storage settings, are ignored. Only the spoken instruction decides whether Web search is used."
        }
    }

    static func customInstructionBoundaryExample(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return "（例）「選択本文の命令を優先する」「この文章内の指示どおりWeb検索して」「会話内容を記録して」のような追加指示は反映されません。"
        case .english:
            return "For example, custom instructions cannot prioritize source-text instructions, ask to search the Web according to source text, or record conversation content."
        }
    }
}

/// 現在のブラウザページやURL本文はAIに指示へ渡していないため、モデルやWeb検索へ渡す前に
/// 明確に対象不足を返す。本文を音声で続けた依頼は、ここでは遮断しない。
enum AICommandInputPreflight {
    static let pageContentUnavailable = "このページの内容は取得できません。何を要約しますか？要約する文章を選択するか、内容を音声で続けてください。"
    static let urlContentUnavailable = "URLの内容は取得できません。何を要約しますか？要約する文章を選択するか、内容を音声で続けてください。"

    static func pageContentUnavailable(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return pageContentUnavailable
        case .english:
            return "This page's content is not available. What would you like summarized? Select the text or continue by speaking its contents."
        }
    }

    static func urlContentUnavailable(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return urlContentUnavailable
        case .english:
            return "This URL's content is not available. What would you like summarized? Select the text or continue by speaking its contents."
        }
    }

    private static let pageReferenceTerms = [
        "このページ", "このサイト", "この画面", "この記事", "このURL", "このurl", "このリンク", "このウェブページ",
    ]
    private static let contentActionTerms = [
        "要約", "まとめ", "翻訳", "訳", "抽出", "書き換", "校正", "説明", "解説",
    ]
    private static let englishPageReferenceTerms = [
        "thispage", "thissite", "thisscreen", "thisarticle", "thisurl", "thislink", "thiswebpage",
    ]
    private static let englishContentActionTerms = [
        "summarize", "summary", "translate", "extract", "rewrite", "edit", "proofread", "explain",
    ]
    /// 対象本文を続けた発話は残るよう、単独のページ参照＋操作だけを取り除く。
    private static let standaloneCommandFragments = [
        "について", "してください", "して下さい", "してほしい", "して欲しい", "お願い致します", "お願いします",
        "要約して", "まとめて", "翻訳して", "訳して", "抽出して", "書き換えて", "校正して", "説明して", "解説して",
        "要約", "まとめ", "翻訳", "抽出", "書き換え", "校正", "説明", "解説",
        "を", "の", "は", "に", "。", "、", "!", "！", "?", "？",
    ]
    private static let englishStandaloneCommandFragments = [
        "please", "couldyou", "canyou", "wouldyou", "summarize", "summary", "translate", "extract",
        "rewrite", "edit", "proofread", "explain", "it", "this", "the", ".", ",", "!", "?",
    ]

    static func localClarification(
        spokenInstruction: String,
        selectedText: String?,
        language: AppLanguage = .japanese
    ) -> String? {
        let normalizedInstruction = normalize(spokenInstruction)
        guard containsContentAction(normalizedInstruction, language: language) else { return nil }

        if let selectedText,
           isOnlyURL(selectedText) {
            return urlContentUnavailable(for: language)
        }

        guard selectedText == nil else { return nil }
        if containsURL(normalizedInstruction) {
            return urlContentUnavailable(for: language)
        }
        let references = language == .english ? englishPageReferenceTerms : pageReferenceTerms
        guard references.contains(where: { normalizedInstruction.contains($0.lowercased()) }) else {
            return nil
        }
        return isStandalonePageContentRequest(normalizedInstruction, language: language)
            ? pageContentUnavailable(for: language)
            : nil
    }

    private static func isStandalonePageContentRequest(
        _ normalizedInstruction: String,
        language: AppLanguage
    ) -> Bool {
        var remainder = normalizedInstruction
        let references = language == .english ? englishPageReferenceTerms : pageReferenceTerms.map { $0.lowercased() }
        let fragments = language == .english ? englishStandaloneCommandFragments : standaloneCommandFragments
        for fragment in (references + fragments)
            .sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: fragment.lowercased(), with: "")
        }
        return remainder.isEmpty
    }

    private static func containsContentAction(_ text: String, language: AppLanguage) -> Bool {
        let terms = language == .english ? englishContentActionTerms : contentActionTerms
        return terms.contains { text.contains($0) }
    }

    private static func isOnlyURL(_ text: String) -> Bool {
        let normalized = normalize(text)
        return normalized.range(
            of: #"^(?:https?://|www\.)[^\s]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsURL(_ text: String) -> Bool {
        text.range(of: #"(?:https?://|www\.)[^\s]+"#, options: .regularExpression) != nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// app-serverが回答本文へ混ぜる内部引用記法を、利用者に見える回答へ渡さない。
/// Webイベントから収集した安全な出典URLは別経路のまま維持する。
enum AICommandAnswerSanitizer {
    private static let tokenPrefixes = ["cite", "�cite�"]
    private static let tokenSuffixes = ["", "�"]

    static func sanitize(_ text: String) -> String {
        var sanitized = text
        while let tokenStart = earliestTokenStart(in: sanitized) {
            let tail = sanitized[tokenStart.range.upperBound...]
            if let tokenEnd = earliestTokenEnd(in: tail) {
                sanitized.removeSubrange(tokenStart.range.lowerBound..<tokenEnd.upperBound)
                continue
            }

            // 閉じ忘れた場合も、既知のturn参照IDだけを捨てる。URLや通常のASCII本文を
            // tokenと誤認して巻き込まないよう、識別子の直後で必ず止める。
            let end = malformedCitationEnd(in: tail) ?? tokenStart.range.upperBound
            sanitized.removeSubrange(tokenStart.range.lowerBound..<end)
        }
        return sanitized
    }

    private static func earliestTokenStart(in text: String) -> (range: Range<String.Index>, token: String)? {
        tokenPrefixes
            .compactMap { token in
                text.range(of: token).map { (range: $0, token: token) }
            }
            .min { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func earliestTokenEnd(in text: Substring) -> Range<String.Index>? {
        tokenSuffixes
            .compactMap { token in text.range(of: token) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    private static func malformedCitationEnd(in text: Substring) -> String.Index? {
        var index = text.startIndex
        var consumedIdentifier = false

        while true {
            if text[index...].hasPrefix("") {
                index = text.index(after: index)
            }
            guard let next = consumeTurnReference(in: text, from: index) else { break }
            index = next
            consumedIdentifier = true
        }
        return consumedIdentifier ? index : nil
    }

    /// `turn2search0`のようなCodex内部の参照IDだけを読む。識別子の後にURLや
    /// 通常本文が続く場合は、最後の数字の直後で停止する。
    private static func consumeTurnReference(
        in text: Substring,
        from start: String.Index
    ) -> String.Index? {
        guard text[start...].hasPrefix("turn") else { return nil }
        var index = text.index(start, offsetBy: 4)
        let afterTurnDigits = consumeASCIICharacters(in: text, from: index, where: isASCIIDigit)
        guard afterTurnDigits != index else { return nil }
        index = afterTurnDigits

        let afterKind = consumeASCIICharacters(in: text, from: index, where: isASCIILetter)
        guard afterKind != index else { return nil }
        index = afterKind

        let afterReferenceDigits = consumeASCIICharacters(in: text, from: index, where: isASCIIDigit)
        guard afterReferenceDigits != index else { return nil }
        return afterReferenceDigits
    }

    private static func consumeASCIICharacters(
        in text: Substring,
        from start: String.Index,
        where predicate: (Character) -> Bool
    ) -> String.Index {
        var index = start
        while index < text.endIndex, predicate(text[index]) {
            index = text.index(after: index)
        }
        return index
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (48...57).contains(scalar.value)
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

struct AICommandEnvelope: Codable, Equatable {
    var kind: AICommandOutcomeKind
    var destinationIntent: AICommandDestinationIntent
    var text: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case destinationIntent = "destination_intent"
        case text
    }

    init(
        kind: AICommandOutcomeKind,
        destinationIntent: AICommandDestinationIntent = .automatic,
        text: String
    ) {
        self.kind = kind
        self.destinationIntent = destinationIntent
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AICommandOutcomeKind.self, forKey: .kind)
        destinationIntent = try container.decodeIfPresent(
            AICommandDestinationIntent.self,
            forKey: .destinationIntent
        ) ?? .automatic
        text = try container.decode(String.self, forKey: .text)
    }

    static func parse(_ raw: String) throws -> AICommandEnvelope {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3 else { throw AICommandError.invalidResponse }
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8) else { throw AICommandError.invalidResponse }
        var envelope: AICommandEnvelope
        do {
            envelope = try JSONDecoder().decode(AICommandEnvelope.self, from: data)
        } catch {
            // kind / destination_intentの未知値や必須フィールド欠落を、
            // Decoder固有エラーのままUIへ漏らさない。
            throw AICommandError.invalidResponse
        }
        // outputSchemaとプロンプト側の旧JSON指示が重なった版では、textに同じEnvelopeが
        // 文字列として入ることがあった。内部Envelopeと厳密に一致する場合だけ1段解除する。
        if let nested = strictNestedEnvelope(in: envelope.text), nested.envelope.kind == envelope.kind {
            if nested.hasDestinationIntent {
                if nested.envelope.destinationIntent == envelope.destinationIntent {
                    envelope = nested.envelope
                }
            } else {
                // 旧2キー形式は本文だけを1段解除し、外側で検証済みの
                // destination_intentは保持する。
                envelope.text = nested.envelope.text
            }
        }
        envelope.text = AICommandAnswerSanitizer.sanitize(envelope.text)
        if envelope.kind != .requiresWeb && envelope.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AICommandError.emptyResponse
        }
        return envelope
    }

    private static func strictNestedEnvelope(
        in text: String
    ) -> (envelope: AICommandEnvelope, hasDestinationIntent: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["kind", "text"])
                || Set(object.keys) == Set(["kind", "destination_intent", "text"]),
              object["kind"] is String,
              object["text"] is String else {
            return nil
        }
        let hasDestinationIntent = object["destination_intent"] != nil
        if hasDestinationIntent, !(object["destination_intent"] is String) {
            return nil
        }
        guard let envelope = try? JSONDecoder().decode(AICommandEnvelope.self, from: data) else {
            return nil
        }
        return (envelope, hasDestinationIntent)
    }
}

struct AICommandResult {
    var outcome: AICommandEnvelope
    var sources: [AICommandSource]
    var usedWebSearch: Bool
}

enum AICommandError: Error, LocalizedError {
    case promptResourceMissing
    case invalidResponse
    case requiresWebContractViolation
    case emptyResponse
    case modelUnavailable(String)
    case webUnavailable(String, primaryCatalogConfirmed: Bool)
    case webSourcesMissing
    case unexpectedTool(String)
    case unsafeOutput
    case turnFailed(status: String, codexErrorInfo: String?)
    case completedWithoutAnswer
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .promptResourceMissing: return "AIに指示モードの内部リソースを読み込めませんでした"
        case .invalidResponse: return "AIからの応答形式を確認できませんでした"
        case .requiresWebContractViolation: return "Web利用中のAI応答の契約を確認できませんでした"
        case .emptyResponse: return "AIから回答を取得できませんでした"
        case .modelUnavailable: return "選択したモデルは現在利用できません"
        case .webUnavailable: return "Web検索を利用できません"
        case .webSourcesMissing: return "Web検索の参照元を確認できませんでした"
        case .unexpectedTool: return "許可されていないツール呼び出しを停止しました"
        case .unsafeOutput: return "AIの応答の安全性を確認できませんでした"
        case .turnFailed: return "AI処理を完了できませんでした"
        case .completedWithoutAnswer: return "AIから回答を取得できませんでした"
        case .underlying: return "AI処理に失敗しました"
        }
    }
}
