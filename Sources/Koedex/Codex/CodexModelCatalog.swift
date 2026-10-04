import Foundation

struct CodexReasoningLevel: Codable, Hashable, Identifiable {
    var effort: String
    var description: String

    var id: String { effort }

    init(effort: String, description: String) {
        self.effort = effort
        self.description = description
    }
}

struct CodexModelInfo: Codable, Hashable, Identifiable {
    var slug: String
    var displayName: String
    /// Codex CLIが返すモデル説明。UI向けの日本語要約はCatalog側で補う。
    var description: String
    var defaultReasoningLevel: String
    var supportedReasoningLevels: [CodexReasoningLevel]
    var visibility: String
    /// Codex CLIが返す検索ツール対応可否。欠落時は安全側でfalse。
    var supportsSearchTool: Bool
    /// 対応する検索ツール種別（例: web_search）。CLIが返さない場合はnil。
    var webSearchToolType: String?

    var id: String { slug }

    init(
        slug: String,
        displayName: String,
        description: String = "",
        defaultReasoningLevel: String,
        supportedReasoningLevels: [CodexReasoningLevel],
        visibility: String,
        supportsSearchTool: Bool = false,
        webSearchToolType: String? = nil
    ) {
        self.slug = slug
        self.displayName = displayName
        self.description = description
        self.defaultReasoningLevel = defaultReasoningLevel
        self.supportedReasoningLevels = supportedReasoningLevels
        self.visibility = visibility
        self.supportsSearchTool = supportsSearchTool
        self.webSearchToolType = webSearchToolType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? slug
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        defaultReasoningLevel = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel) ?? CodexModelSettings.defaultReasoningEffort
        supportedReasoningLevels = try container.decodeIfPresent([CodexReasoningLevel].self, forKey: .supportedReasoningLevels) ?? [
            CodexReasoningLevel(effort: defaultReasoningLevel, description: "")
        ]
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "list"
        supportsSearchTool = try container.decodeIfPresent(Bool.self, forKey: .supportsSearchTool) ?? false
        webSearchToolType = try container.decodeIfPresent(String.self, forKey: .webSearchToolType)
    }

    private enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case description
        case defaultReasoningLevel = "default_reasoning_level"
        case supportedReasoningLevels = "supported_reasoning_levels"
        case visibility
        case supportsSearchTool = "supports_search_tool"
        case webSearchToolType = "web_search_tool_type"
    }
}

enum CodexModelCatalog {
    /// UIでの表示順をCLIの辞書順から独立させる。新しいライブモデルは既知モデルの後ろに置く。
    private static let preferredModelSlugOrder = [
        "gpt-5.4-mini",
        "gpt-5.4",
        "gpt-5.5",
        "gpt-5.6-luna",
        "gpt-5.6-terra",
        "gpt-5.6-sol",
    ]

    private static let preferredModelSlugRanks = Dictionary(
        uniqueKeysWithValues: preferredModelSlugOrder.enumerated().map { ($0.element, $0.offset) }
    )

    static let builtInModels: [CodexModelInfo] = [
        CodexModelInfo(
            slug: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            description: "軽量で高速。短い定型処理や互換性が必要な用途向け。",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: [
                CodexReasoningLevel(effort: "low", description: "高速"),
                CodexReasoningLevel(effort: "medium", description: "バランス"),
                CodexReasoningLevel(effort: "high", description: "高精度"),
                CodexReasoningLevel(effort: "xhigh", description: "最高精度"),
            ],
            visibility: "list"
        ),
        CodexModelInfo(
            slug: "gpt-5.4",
            displayName: "GPT-5.4",
            description: "安定した旧世代モデル。既存ワークフローとの互換性向け。",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: [
                CodexReasoningLevel(effort: "low", description: "高速"),
                CodexReasoningLevel(effort: "medium", description: "バランス"),
                CodexReasoningLevel(effort: "high", description: "高精度"),
                CodexReasoningLevel(effort: "xhigh", description: "最高精度"),
            ],
            visibility: "list"
        ),
        CodexModelInfo(
            slug: "gpt-5.5",
            displayName: "GPT-5.5",
            description: "高性能な旧世代モデル。再現性や既存設定の維持向け。",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: [
                CodexReasoningLevel(effort: "low", description: "高速"),
                CodexReasoningLevel(effort: "medium", description: "バランス"),
                CodexReasoningLevel(effort: "high", description: "高精度"),
                CodexReasoningLevel(effort: "xhigh", description: "最高精度"),
            ],
            visibility: "list"
        ),
        CodexModelInfo(
            slug: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            description: "高速・低コスト。日常的なAIアシストや軽量な処理向け。",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: standardBuiltInReasoningLevels,
            visibility: "list"
        ),
        CodexModelInfo(
            slug: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            description: "日常利用向けのバランス型。品質と速度の両立を重視する用途向け。",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: standardBuiltInReasoningLevels,
            visibility: "list"
        ),
        CodexModelInfo(
            slug: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            description: "複雑な処理や高い精度が必要な用途向け。",
            defaultReasoningLevel: "medium",
            supportedReasoningLevels: standardBuiltInReasoningLevels,
            visibility: "list"
        ),
    ]

    /// 内蔵一覧はCLI取得失敗時の暫定表示であり、max/ultraを推測で追加しない。
    private static let standardBuiltInReasoningLevels: [CodexReasoningLevel] = [
        CodexReasoningLevel(effort: "low", description: "高速"),
        CodexReasoningLevel(effort: "medium", description: "バランス"),
        CodexReasoningLevel(effort: "high", description: "高精度"),
        CodexReasoningLevel(effort: "xhigh", description: "最高精度"),
    ]

    static func merge(_ fetchedModels: [CodexModelInfo], selectedSlug: String) -> [CodexModelInfo] {
        _ = selectedSlug // source compatibility; stale selection is intentionally not synthesized.
        var bySlug: [String: CodexModelInfo] = [:]
        // built-inは取得失敗／未取得時だけのfallback。ライブ一覧が取れた時は
        // 消えた保存済みモデルをavailableとして復活させない。
        let sourceModels = fetchedModels.isEmpty ? builtInModels : fetchedModels
        for model in sourceModels where model.visibility == "list" {
            bySlug[model.slug] = model
        }

        return orderedModels(Array(bySlug.values))
    }

    /// 通常／AIに指示／最適化のPickerで共有するモデル順。
    /// 未知のライブモデルは、既知の6モデルの後ろで従来どおり文字順に並べる。
    static func orderedModels(_ models: [CodexModelInfo]) -> [CodexModelInfo] {
        models.sorted { lhs, rhs in
            let lhsRank = preferredModelSlugRanks[lhs.slug.lowercased()]
            let rhsRank = preferredModelSlugRanks[rhs.slug.lowercased()]

            switch (lhsRank, rhsRank) {
            case let (lhsRank?, rhsRank?):
                return lhsRank < rhsRank
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.slug.localizedStandardCompare(rhs.slug) == .orderedAscending
            }
        }
    }

    /// 保存済みslugが現在のカタログに存在するかを、架空のavailableモデルを合成せず返す。
    static func model(slug: String, in models: [CodexModelInfo]) -> CodexModelInfo? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return models.first { $0.slug == trimmed && $0.visibility == "list" }
    }

    /// UIと実行時検証が共有する、ユーザーが選べる推論レベル。
    /// ultraはCodex側の自動分担モードであり、Koedexの単一処理設定には使わせない。
    /// maxは実行中CLIがそのモデルへ返した場合だけ、この一覧に残る。
    static func userSelectableReasoningLevels(for model: CodexModelInfo?) -> [CodexReasoningLevel] {
        guard let model else { return [] }
        return model.supportedReasoningLevels.filter { level in
            let effort = level.effort.trimmingCharacters(in: .whitespacesAndNewlines)
            return isUserSelectableEffortIdentifier(effort)
        }
    }

    static func isUserSelectable(effort: String, for model: CodexModelInfo?) -> Bool {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        return userSelectableReasoningLevels(for: model).contains { $0.effort == normalized }
    }

    /// ultraは単一モデルの推論レベルではなく、Codex側の自動分担モード。
    /// live catalogに現れてもKoedexの保存設定・実行引数には渡さない。
    static func isUserSelectableEffortIdentifier(_ effort: String) -> Bool {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalized.isEmpty && normalized != "ultra"
    }

    static func userFacingDescription(
        for model: CodexModelInfo,
        language: AppLanguage = .japanese
    ) -> String {
        let japanese: String
        switch model.slug {
        case "gpt-5.4-mini":
            japanese = "軽量で高速。短い定型処理や互換性が必要な用途向け。"
        case "gpt-5.4":
            japanese = "安定した旧世代モデル。既存ワークフローとの互換性向け。"
        case "gpt-5.5":
            japanese = "高性能な旧世代モデル。再現性や既存設定の維持向け。"
        case "gpt-5.6-luna":
            japanese = "高速・低コスト。日常的なAIアシストや軽量な処理向け。"
        case "gpt-5.6-terra":
            japanese = "日常利用向けのバランス型。品質と速度の両立を重視する用途向け。"
        case "gpt-5.6-sol":
            japanese = "複雑な処理や高い精度が必要な用途向け。"
        default:
            return model.description
        }
        return AppLocalizer.text(japanese, language: language)
    }

    static func isAvailable(slug: String, in models: [CodexModelInfo]) -> Bool {
        model(slug: slug, in: models) != nil
    }

    static func supportsWebSearch(slug: String, in models: [CodexModelInfo]) -> Bool {
        model(slug: slug, in: models)?.supportsSearchTool == true
    }
}

enum CodexModelCatalogError: Error, LocalizedError {
    case codexNotFound
    case commandFailed
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "codex CLIが見つかりません。設定で場所を確認してください"
        case .commandFailed:
            return "モデル一覧を取得できませんでした"
        case .invalidJSON:
            return "モデル一覧の応答を確認できませんでした"
        }
    }
}

struct CodexModelCatalogFetchResult {
    let models: [CodexModelInfo]
    /// `debug models --bundled` が成功したことだけを表す。実行ターンのモデルfallbackではない。
    let usedBundledCatalog: Bool
}

struct CodexModelCatalogService {
    func fetchModels(settingsExecutablePath: String?) async throws -> [CodexModelInfo] {
        try await fetchModelsWithDiagnostics(settingsExecutablePath: settingsExecutablePath).models
    }

    func fetchModelsWithDiagnostics(
        settingsExecutablePath: String?
    ) async throws -> CodexModelCatalogFetchResult {
        try await Task.detached(priority: .userInitiated) {
            guard let resolvedPath = CodexPathResolver.resolve(settingsPath: settingsExecutablePath) else {
                throw CodexModelCatalogError.codexNotFound
            }

            do {
                return CodexModelCatalogFetchResult(
                    models: try Self.runDebugModels(codexPath: resolvedPath, bundled: false),
                    usedBundledCatalog: false
                )
            } catch {
                return CodexModelCatalogFetchResult(
                    models: try Self.runDebugModels(codexPath: resolvedPath, bundled: true),
                    usedBundledCatalog: true
                )
            }
        }.value
    }

    private static func runDebugModels(codexPath: String, bundled: Bool) throws -> [CodexModelInfo] {
        var arguments = ["debug", "models"]
        if bundled {
            arguments.append("--bundled")
        }

        let output = try runProcess(executablePath: codexPath, arguments: arguments)
        return try parseModels(from: output)
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        proc.environment = CodexAppServerClient.buildChildEnvironment()

        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        // CLIのstderrは認証情報を含み得るため、読取・保存・表示しない。
        proc.standardError = FileHandle.nullDevice

        var stdout = Data()
        let lock = NSLock()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            stdout.append(data)
            lock.unlock()
        }
        do {
            try proc.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            throw CodexModelCatalogError.commandFailed
        }

        let deadline = Date().addingTimeInterval(15)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                throw CodexModelCatalogError.commandFailed
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        let output = stdout
        lock.unlock()

        guard proc.terminationStatus == 0 else {
            throw CodexModelCatalogError.commandFailed
        }

        return output
    }

    private static func parseModels(from data: Data) throws -> [CodexModelInfo] {
        let json = try JSONSerialization.jsonObject(with: extractJSONPayload(from: data), options: [])
        let rawModels: Any
        if let array = json as? [Any] {
            rawModels = array
        } else if let dict = json as? [String: Any], let models = dict["models"] {
            rawModels = models
        } else {
            throw CodexModelCatalogError.invalidJSON
        }

        guard JSONSerialization.isValidJSONObject(rawModels) else {
            throw CodexModelCatalogError.invalidJSON
        }

        let modelData = try JSONSerialization.data(withJSONObject: rawModels, options: [])
        let decoded = try JSONDecoder().decode([CodexModelInfo].self, from: modelData)
        return decoded.filter { $0.visibility == "list" }
    }

    private static func extractJSONPayload(from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(where: { $0 == UInt8(ascii: "{") || $0 == UInt8(ascii: "[") }) else {
            throw CodexModelCatalogError.invalidJSON
        }
        return data.subdata(in: start..<data.count)
    }
}
