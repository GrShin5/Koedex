import Foundation

enum ContextualVocabularyBuilder {
    /// 新しい優先表記から、音声認識に渡す短い語句だけを選ぶ。
    static func build(from entries: [PersonalDictionaryEntry]) -> [String] {
        let ordered = entries.enumerated().sorted {
            if $0.element.updatedAt != $1.element.updatedAt {
                return $0.element.updatedAt > $1.element.updatedAt
            }
            return $0.offset < $1.offset
        }
        var seen = Set<String>()
        var vocabulary: [String] = []
        for (_, entry) in ordered where entry.enabled {
            let word = entry.preferredForm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 40, seen.insert(word).inserted else { continue }
            vocabulary.append(word)
            if vocabulary.count == 100 { break }
        }
        return vocabulary
    }
}
