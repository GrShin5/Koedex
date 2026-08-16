import Foundation

/// 応答本文を保存せずに、開発者指示の実際の漏えいだけを検出する文脈。
/// ユーザーが発話、選択、辞書、カスタム指示に含めた語句は安全な出力として扱う。
struct OutputSafetyGateContext {
    enum Route {
        case cleanup
        case aiCommand
        case customInstructionOptimization
    }

    let route: Route
    let protectedInstruction: String
    let userSuppliedTexts: [String]

    init(route: Route, protectedInstruction: String, userSuppliedTexts: [String]) {
        self.route = route
        self.protectedInstruction = protectedInstruction
        self.userSuppliedTexts = userSuppliedTexts
    }
}

/// app-serverの最終応答を利用者へ渡す直前の、内容を保存しない安全ゲート。
/// コードフェンス、JSON、一般的な「system prompt」という語だけでは拒否しない。
/// 利用者本文にないdeveloper instructionの長い断片だけを漏えいとして扱う。
enum AppServerOutputSafetyGate {
    enum RejectionReason: Equatable {
        case emptyOutput
        case protectedInstructionFragment
        case internalRuntimeEnvelope
    }

    static func accepts(_ output: String, context: OutputSafetyGateContext) -> Bool {
        rejectionReason(for: output, context: context) == nil
    }

    static func rejectionReason(
        for output: String,
        context: OutputSafetyGateContext
    ) -> RejectionReason? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyOutput }

        let containsProtectedFragment = containsUnpromptedProtectedFragment(
            output: trimmed,
            protectedInstruction: context.protectedInstruction,
            userSuppliedTexts: context.userSuppliedTexts
        )
        guard containsProtectedFragment else { return nil }

        // 実行時JSONそのものが漏れた場合は理由を区別するが、JSONという記法だけでは
        // 拒否しない。利用者がJSONやコードを求めた正当な応答を守るためである。
        if looksLikeInternalRuntimeEnvelope(trimmed) {
            return .internalRuntimeEnvelope
        }
        return .protectedInstructionFragment
    }

    /// 既存呼び出しとの互換用。新規コードはcontext版を使い、全ての利用者入力源を渡す。
    static func accepts(
        _ output: String,
        protectedInstruction: String,
        userSuppliedText: String,
        allowsStructuredJSON _: Bool = false
    ) -> Bool {
        accepts(
            output,
            context: OutputSafetyGateContext(
                route: .cleanup,
                protectedInstruction: protectedInstruction,
                userSuppliedTexts: [userSuppliedText]
            )
        )
    }

    private static func looksLikeInternalRuntimeEnvelope(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return false
        }
        let keys = Set(dictionary.keys)
        let internalKeys: Set<String> = [
            "mode", "destination", "available_context", "unavailable_context",
            "output_policy", "raw_transcript", "personal_dictionary",
            "custom_instruction", "custom_style_preferences", "prompt_language",
        ]
        return keys.intersection(internalKeys).count >= 3
    }

    private static func containsUnpromptedProtectedFragment(
        output: String,
        protectedInstruction: String,
        userSuppliedTexts: [String]
    ) -> Bool {
        let normalizedOutput = normalize(output)
        let normalizedInputs = userSuppliedTexts.map(normalize)
        for line in protectedInstruction.components(separatedBy: .newlines) {
            let line = normalize(line)
            // 短い共通語を誤検知しない。開発者指示由来と判断できる十分に長い文だけ対象にする。
            guard line.count >= 24 else { continue }
            for fragment in protectedFragments(from: line) where normalizedOutput.contains(fragment) {
                if !normalizedInputs.contains(where: { $0.contains(fragment) }) {
                    return true
                }
            }
        }
        return false
    }

    /// 一行全体だけでなく、長い指示の途中だけが漏れた場合も検出する。
    /// 空白などを正規化した後に32文字ずつ重ねて照合する。48文字に粗く間引くと、
    /// 「途中の一節」だけが露出した場合に一致しないことがあるため、安全側に倒す。
    private static func protectedFragments(from line: String) -> Set<String> {
        let characters = Array(line)
        let windowLength = min(32, characters.count)
        guard windowLength >= 24 else { return [] }

        var fragments: Set<String> = [line]
        var start = 0
        while start + windowLength <= characters.count {
            fragments.insert(String(characters[start..<(start + windowLength)]))
            start += 1
        }
        let finalStart = characters.count - windowLength
        fragments.insert(String(characters[finalStart..<characters.count]))
        return fragments
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
