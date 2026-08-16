import Foundation
import NaturalLanguage

/// AIアシストとAIに指示で共有する、最終出力の言語方針。
/// この値は保存しない。発話ごとの明示指示と入力言語から決め、保存済み設定はその次に使う。
enum OutputLanguageResolution: Equatable {
    case fixed(AppLanguage)
    case automatic(AppLanguage)
    case preserveMixed

    var developerInstructionValue: String {
        switch self {
        case .fixed(.japanese): return "fixed_japanese"
        case .fixed(.english): return "fixed_english"
        case .automatic(.japanese): return "automatic_japanese"
        case .automatic(.english): return "automatic_english"
        case .preserveMixed: return "preserve_mixed"
        }
    }

    var targetLanguage: AppLanguage? {
        switch self {
        case .fixed(let language), .automatic(let language): return language
        case .preserveMixed: return nil
        }
    }

    static func resolve(
        transcript: String,
        savedPreference: AIOutputLanguage,
        sttLanguage: AppLanguage
    ) -> OutputLanguageResolution {
        if let directive = SpokenOutputLanguageDirective.parse(transcript) {
            return .fixed(directive.language)
        }
        if let fixed = savedPreference.fixedLanguage {
            return .fixed(fixed)
        }
        switch SpeechLanguageClassifier.classify(transcript) {
        case .japanese:
            return .automatic(.japanese)
        case .english:
            return .automatic(.english)
        case .mixed:
            return .preserveMixed
        case .unknown:
            return .automatic(sttLanguage)
        }
    }
}

/// 明確にKoedexへ向けた、独立した出力言語制御句だけを扱う。
/// 引用・コード・「という文を入れて」などでは文字起こしの一部として残す。
struct SpokenOutputLanguageDirective: Equatable {
    let language: AppLanguage
    let transcriptWithoutDirective: String

    static func parse(_ transcript: String) -> SpokenOutputLanguageDirective? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !containsQuotedOrLiteralContext(trimmed) else { return nil }

        for candidate in japaneseCandidates(trimmed) + englishCandidates(trimmed) {
            let remainder = candidate.remainder
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !remainder.isEmpty else { continue }
            return SpokenOutputLanguageDirective(language: candidate.language, transcriptWithoutDirective: remainder)
        }
        return nil
    }

    private struct Candidate {
        let language: AppLanguage
        let remainder: String
    }

    private static func japaneseCandidates(_ text: String) -> [Candidate] {
        let targets: [(String, AppLanguage)] = [
            ("日本語", .japanese), ("英語", .english), ("English", .english), ("english", .english),
        ]
        let verbs = "(?:出力して|出力してください|回答して|回答してください|答えて|答えてください|返して|返してください|書いて|書いてください)"
        var candidates: [Candidate] = []
        for (target, language) in targets {
            let escaped = NSRegularExpression.escapedPattern(for: target)
            let prefix = "^(?:最終)?(?:出力|回答|答え)?(?:は)?\\s*\(escaped)(?:で|に)\\s*\(verbs)[、,。.!！?？\\s]+(.+)$"
            if let remainder = capture(text, pattern: prefix) {
                candidates.append(Candidate(language: language, remainder: remainder))
            }
            let suffix = "^(.+?)[、,。.!！?？\\s]+(?:最終)?(?:出力|回答|答え)?(?:は)?\\s*\(escaped)(?:で|に)\\s*\(verbs)[。.!！?？\\s]*$"
            if let remainder = capture(text, pattern: suffix) {
                candidates.append(Candidate(language: language, remainder: remainder))
            }
        }
        return candidates
    }

    private static func englishCandidates(_ text: String) -> [Candidate] {
        let targets: [(String, AppLanguage)] = [("Japanese", .japanese), ("English", .english)]
        var candidates: [Candidate] = []
        for (target, language) in targets {
            let escaped = NSRegularExpression.escapedPattern(for: target)
            let prefix = "^(?:please\\s+)?(?:answer|respond|write|output)(?:\\s+this)?\\s+in\\s+\(escaped)[,:;.!?\\s]+(.+)$"
            if let remainder = capture(text, pattern: prefix, options: [.caseInsensitive]) {
                candidates.append(Candidate(language: language, remainder: remainder))
            }
            let suffix = "^(.+?)[,:;.!?\\s]+(?:please\\s+)?(?:answer|respond|write|output)(?:\\s+in)?\\s+\(escaped)[.!?\\s]*$"
            if let remainder = capture(text, pattern: suffix, options: [.caseInsensitive]) {
                candidates.append(Candidate(language: language, remainder: remainder))
            }
        }
        return candidates
    }

    private static func capture(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range), match.numberOfRanges == 2,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func containsQuotedOrLiteralContext(_ text: String) -> Bool {
        let lower = text.lowercased()
        let literalMarkers = [
            "「", "」", "\"", "`", "という文", "と書いて", "と入力して", "と出力して",
            "write the phrase", "include the phrase", "code", "prompt",
        ]
        return literalMarkers.contains { lower.contains($0.lowercased()) }
    }
}

enum SpeechLanguageClassifier {
    enum Classification: Equatable {
        case japanese
        case english
        case mixed
        case unknown
    }

    static func classify(_ transcript: String) -> Classification {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }

        let hasJapanese = text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
        let latinWordCount = text.split { !$0.isLetter }.filter { word in
            word.unicodeScalars.allSatisfy { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
        }.count
        if hasJapanese && latinWordCount > 0 {
            return .mixed
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .japanese:
            return .japanese
        case .english:
            return .english
        default:
            return hasJapanese ? .japanese : .unknown
        }
    }
}
