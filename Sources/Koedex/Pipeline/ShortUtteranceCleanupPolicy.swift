import Foundation

/// 本文を外部へ出さずに、短い通常入力の整形省略を判断する。
enum ShortUtteranceCleanupPolicy {
    enum Reason: String {
        case eligible, handsFree, languageDirective, outputLanguageOverride
        case length, multiline, filler, repeatedFragment, dictionaryMatch
    }

    struct Decision {
        let eligible: Bool
        let reason: Reason
        let output: String
    }

    static func evaluate(transcript: String, isHandsFree: Bool,
                         hasLanguageDirective: Bool, outputPolicyIsAutomatic: Bool,
                         dictionarySpokenForms: [String]) -> Decision {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        func reject(_ reason: Reason) -> Decision {
            Decision(eligible: false, reason: reason, output: text)
        }
        if isHandsFree { return reject(.handsFree) }
        if hasLanguageDirective { return reject(.languageDirective) }
        if !outputPolicyIsAutomatic { return reject(.outputLanguageOverride) }
        guard (1...12).contains(text.count) else { return reject(.length) }
        if transcript.rangeOfCharacter(from: .newlines) != nil { return reject(.multiline) }
        let normalized = normalize(text)
        let fillers = ["えー", "えーと", "えっと", "あの", "あのー", "その", "まあ", "なんか", "うーん", "うん"]
        if fillers.contains(where: { normalized.contains($0) }) ||
            normalized.range(of: #"(?i)\b(um|uh|er|like|you\s+know)\b"#, options: .regularExpression) != nil {
            return reject(.filler)
        }
        let chars = Array(normalized)
        if chars.count >= 4 {
            for size in 2...(chars.count / 2) {
                for start in 0...(chars.count - size * 2) {
                    if chars[start..<(start + size)].elementsEqual(chars[(start + size)..<(start + size * 2)]) {
                        return reject(.repeatedFragment)
                    }
                }
            }
        }
        if dictionarySpokenForms.contains(where: {
            let form = normalize($0).trimmingCharacters(in: .whitespacesAndNewlines)
            return !form.isEmpty && normalized.contains(form)
        }) { return reject(.dictionaryMatch) }
        var output = text
        // 句点を除いた本文で、既存の文末判定をそのまま利用する。
        if text.hasSuffix("。"), !CleanupEngine.isLikelyCompleteUtterance(String(text.dropLast())) {
            output.removeLast()
        }
        return Decision(eligible: true, reason: .eligible, output: output)
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
