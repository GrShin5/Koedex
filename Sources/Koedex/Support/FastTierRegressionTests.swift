import Foundation

@MainActor
enum FastTierRegressionTests {
    static func run(_ expect: (Bool, String) -> Void) {
        expect(!CleanupFastTierFallbackPolicy.shouldDisable(consecutiveFailures: 1)
            && CleanupFastTierFallbackPolicy.shouldDisable(consecutiveFailures: 2),
            "fast tier is dropped after two consecutive cleanup failures, not one")
        for mode in [CodexModelSettings.default, CodexModelSettings(mode: .cli, selectedModelSlug: "", selectedReasoningEffort: "low")] {
            let normal = CodexAppServerClient.appServerArguments(modelSettings: mode)
            expect(Array(normal.prefix(5)) == ["app-server", "-c", "mcp_servers={}", "-c", "plugins={}"], "protected argument order")
            expect(!normal.contains(where: { $0.hasPrefix("service_tier=") }), "tier never changes launch arguments")
        }
        do {
            let decoder = JSONDecoder()
            let old = try decoder.decode(CodexModelInfo.self, from: Data(#"{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"low","description":""}]}"#.utf8))
            let fast = try decoder.decode(CodexModelInfo.self, from: Data(#"{"slug":"gpt-6-luna","supported_reasoning_levels":[{"effort":"low","description":""}],"service_tiers":[{"id":"priority"}]}"#.utf8))
            for fields in [#""service_tiers":42,"additional_speed_tiers":{}"#, #""service_tiers":[{"id":"fast"}],"additional_speed_tiers":["fast"]"#] {
                let model = try decoder.decode(CodexModelInfo.self, from: Data((#"{"slug":"test","# + fields + "}").utf8))
                expect(!model.supportsFastTier, "malformed or fast-only tiers preserve model without priority support")
            }
            expect(!CleanupFastTierFallbackPolicy.countsAsFailure(.unsafeOutput)
                && !CleanupFastTierFallbackPolicy.countsAsFailure(.emptyResult)
                && CleanupFastTierFallbackPolicy.countsAsFailure(.underlying(CodexClientError.rpcError(code: -1, kind: .other))), "fast tier counts server failures only")
            expect(!old.supportsFastTier && fast.supportsFastTier, "catalog tier decoding remains backward compatible")
            expect(CleanupModelRecommendation.model(in: [old, fast])?.slug == fast.slug, "recommendation chain prefers first available model")
            expect(CleanupModelRecommendation.model(in: [old])?.slug == old.slug && CleanupModelRecommendation.model(in: []) == nil, "recommendation falls back or retains settings without models")
            let recommended = CodexModelSettings(mode: .custom, selectedModelSlug: fast.slug, selectedReasoningEffort: "low")
            var higher = recommended
            higher.selectedReasoningEffort = "medium"
            var cli = recommended
            cli.mode = .cli
            expect(!CleanupModelRecommendation.shouldShow(settings: recommended, models: [fast]) && CleanupModelRecommendation.shouldShow(settings: higher, models: [fast]) && CleanupModelRecommendation.shouldShow(settings: cli, models: [fast]) && !CleanupModelRecommendation.shouldShow(settings: cli, models: []), "recommendation visibility handles effort CLI and unavailable catalog")
            let settings = try decoder.decode(KoedexSettings.self, from: Data("{}".utf8))
            expect(!settings.cleanupFastTierEnabled, "legacy settings default fast tier off")
            var enabled = settings
            enabled.cleanupFastTierEnabled = true
            let roundTrip = try decoder.decode(KoedexSettings.self, from: JSONEncoder().encode(enabled))
            expect(roundTrip.cleanupFastTierEnabled, "fast tier preference persists")
        } catch {
            expect(false, "fast tier fixtures decode")
        }
    }
}
