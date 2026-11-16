import Foundation

enum ContextualVocabularyRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        func entry(_ word: String, _ timestamp: TimeInterval, enabled: Bool = true) -> PersonalDictionaryEntry {
            PersonalDictionaryEntry(preferredForm: word, enabled: enabled,
                                    updatedAt: Date(timeIntervalSince1970: timestamp))
        }
        expect(ContextualVocabularyBuilder.build(from: []).isEmpty, "contextual vocabulary: empty dictionary")
        expect(ContextualVocabularyBuilder.build(from: [entry(" word ", 1), entry("word", 3), entry("other", 2)]) == ["word", "other"],
               "contextual vocabulary: trim, deduplicate and order newest first")
        expect(ContextualVocabularyBuilder.build(from: [entry("disabled", 2, enabled: false), entry("enabled", 1)]) == ["enabled"],
               "contextual vocabulary: disabled entries excluded")
        expect(ContextualVocabularyBuilder.build(from: [entry(" \n ", 3), entry(String(repeating: "語", count: 41), 2), entry(String(repeating: "語", count: 40), 1)]) == [String(repeating: "語", count: 40)],
               "contextual vocabulary: empty and overlong words excluded")
        let many = (0..<105).map { entry("word\($0)", TimeInterval($0)) }
        expect(ContextualVocabularyBuilder.build(from: many) == (5..<105).reversed().map { "word\($0)" },
               "contextual vocabulary: newest 100 entries retained")
        expect(ContextualVocabularyBuilder.build(from: [entry("first", 1), entry("second", 1)]) == ["first", "second"],
               "contextual vocabulary: equal timestamps preserve input order")
    }
}
