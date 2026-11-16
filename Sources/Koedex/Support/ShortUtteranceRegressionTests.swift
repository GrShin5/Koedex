import Foundation

enum ShortUtteranceRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        func decision(_ text: String, handsFree: Bool = false, directive: Bool = false,
                      automatic: Bool = true, dictionary: [String] = []) -> ShortUtteranceCleanupPolicy.Decision {
            ShortUtteranceCleanupPolicy.evaluate(transcript: text, isHandsFree: handsFree,
                hasLanguageDirective: directive, outputPolicyIsAutomatic: automatic,
                dictionarySpokenForms: dictionary)
        }
        let cases: [(String, Bool)] = [
            ("", false), ("   ", false), ("猫", true),
            ("一二三四五六七八九十百千", true), ("一二三四五六七八九十百千万", false),
            ("猫\n犬", false), ("猫\r犬", false),
            ("ですです", false), ("abcabc", false), ("猫犬鳥", true),
            ("summer", true), ("alike", true), ("her", true)
        ]
        for (text, eligible) in cases {
            expect(decision(text).eligible == eligible, "short utterance predicate: \(text.debugDescription)")
        }
        for filler in ["えー", "えーと", "えっと", "あの", "あのー", "その", "まあ", "なんか", "うーん", "うん", "UM", "uh", "Er", "like", "you know"] {
            expect(decision(filler).reason == .filler, "short utterance rejects filler: \(filler)")
        }
        expect(decision("猫", handsFree: true).reason == .handsFree, "short utterance excludes hands-free")
        expect(decision("猫", directive: true).reason == .languageDirective, "short utterance excludes directive")
        expect(decision("猫", automatic: false).reason == .outputLanguageOverride, "short utterance excludes output override")
        expect(decision("ＡＢＣへ", dictionary: ["abc"]).reason == .dictionaryMatch,
               "short utterance dictionary normalizes width and case")
        expect(decision("猫", dictionary: [" "]).eligible, "short utterance ignores empty dictionary forms")
        expect(decision("  猫。  ").output == "猫", "short utterance drops fragment punctuation and trims")
        expect(decision("猫です。").output == "猫です。", "short utterance keeps complete sentence punctuation")
        expect(decision("猫！").output == "猫！", "short utterance keeps other punctuation")
        let legacy = try? JSONDecoder().decode(KoedexSettings.self, from: Data("{}".utf8))
        expect(legacy?.shortUtteranceInstantInsertEnabled == false,
               "short utterance settings missing key defaults off")
        expect(!KoedexSettings.default.shortUtteranceInstantInsertEnabled,
               "short utterance fresh settings default off")
        if var settings = legacy {
            settings.shortUtteranceInstantInsertEnabled = true
            let encoded = try? JSONEncoder().encode(settings)
            let restored = encoded.flatMap { try? JSONDecoder().decode(KoedexSettings.self, from: $0) }
            expect(restored?.shortUtteranceInstantInsertEnabled == true, "short utterance setting round trip")
        }
        let history = HistoryRecordingPolicy.decision(output: "猫", situation: .inserted,
            cleanupEnabled: true, extraFlags: [InputHistoryFlag.tooShort])
        expect(history?.flags == [InputHistoryFlag.tooShort], "short utterance history preserves skip flag")
    }
}
