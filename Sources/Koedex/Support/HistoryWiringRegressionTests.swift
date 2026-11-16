import Foundation

@MainActor
enum HistoryWiringRegressionTests {
    static func run() -> [StorageRegressionTests.Outcome] {
        var results: [StorageRegressionTests.Outcome] = []
        func check(_ value: Bool, _ name: String) {
            results.append(.init(passed: value, name: "history wiring " + name))
        }
        for start in [false, true] {
            for live in [false, true] {
                check(HistoryWiringPolicy.mayRecord(start: start, live: live) == (start && live), "start/live \(start) \(live)")
            }
        }
        let decoded = try? JSONDecoder().decode(AICommandSettings.self, from: Data("{}".utf8))
        check(decoded?.historyStoresOutput == true, "missing answer setting defaults true")
        let disabled = try? JSONDecoder().decode(AICommandSettings.self, from: Data("{\"historyStoresOutput\":false}".utf8))
        check(disabled?.historyStoresOutput == false, "explicit answer opt out")
        let rows: [(TextInjectorResult, HistoryRecordingPolicy.Situation)] = [
            (.inserted, .inserted), (.unicodeSubmitted, .inserted), (.scopedClipboardFallbackSubmitted, .inserted),
            (.secureInputBlocked, .secureInputBlocked), (.externalCompatibilityDisabled, .externalCompatibilityDisabledShown),
            (.manualFallbackRequired, .manualFallbackShown), (.clipboardMayHaveBeenLost, .manualFallbackShown),
            (.insertionUnconfirmed, .insertionUnconfirmedShown), (.failed(NSError(domain: "synthetic", code: 1)), .insertionFailedShown)
        ]
        for (result, expected) in rows { check(HistoryWiringPolicy.situation(for: result) == expected, "mapping \(expected)") }
        check(HistoryWiringPolicy.situation(for: .manualFallbackRequired, fallbackReason: .payloadTooLong) == .manualFallbackShown, "long payload fallback")
        var holder = LastOriginalTranscript()
        let now = Date(timeIntervalSince1970: 1000)
        check(holder.value(now: now) == nil, "starts empty")
        holder.store("synthetic original", now: now)
        check(holder.value(now: now.addingTimeInterval(599)) != nil, "available before expiry")
        check(holder.value(now: now.addingTimeInterval(600)) == nil, "expires at ten minutes")
        holder.clear()
        check(holder.value(now: now) == nil, "clear drops original")
        return results
    }
}
