import Foundation

@MainActor
enum HistoryV3RegressionTests {
    private struct V2Entry: Codable {
        var id: UUID
        var createdAt: Date
        var mode: String
        var storedText: String?
        var storedTextKind: String
        var cleanupEnabled: Bool
        var cleanupSucceeded: Bool
        var insertStatus: String
        var flags: [String]
        var modelSlug: String?
        var reasoningEffort: String?
        var latencyMs: Int?
        var aiCommandInputSource: AICommandInputSource?
        var schemaVersion: Int
    }

    static func run(storageRootURL: URL) -> [StorageRegressionTests.Outcome] {
        var results: [StorageRegressionTests.Outcome] = []
        func check(_ value: Bool, _ name: String) { results.append(.init(passed: value, name: "history v3 " + name)) }
        typealias P = HistoryRecordingPolicy
        let rows: [(P.Situation, Bool, Bool, String, String, [String])] = [
            (.inserted, true, false, "ai_assisted_output", "inserted", []),
            (.inserted, false, false, "raw_transcript_output", "inserted", ["noise_candidate"]),
            (.inserted, true, true, "raw_transcript_output", "inserted", ["cleanup_failed"]),
            (.pasteSentUnverified, true, false, "ai_assisted_output", "paste_sent_unverified", []),
            (.pasteSentUnverified, false, false, "raw_transcript_output", "paste_sent_unverified", ["noise_candidate"]),
            (.pasteSentUnverified, true, true, "raw_transcript_output", "paste_sent_unverified", ["cleanup_failed"]),
            (.insertionFailedShown, true, false, "ai_assisted_output", "shown_in_window", ["insert_failed"]),
            (.insertionUnconfirmedShown, true, false, "ai_assisted_output", "shown_in_window", []),
            (.manualFallbackShown, true, false, "ai_assisted_output", "shown_in_window", []),
            (.externalCompatibilityDisabledShown, true, false, "ai_assisted_output", "shown_in_window", []),
            (.compatibilityGuideShown, true, true, "raw_transcript_output", "shown_in_window", ["cleanup_failed"]),
            (.handsFreeCleanupFailureShown, true, false, "raw_transcript_output", "shown_in_window", ["cleanup_failed"]),
            (.triggerMismatchShown, true, false, "review_text", "shown_in_window", ["needs_review"]),
            (.unsafeFinalizeShown, true, false, "review_text", "shown_in_window", ["needs_review"]),
            (.aiCommandInserted, false, false, "ai_command_output", "inserted", []),
            (.aiCommandPasteSentUnverified, false, false, "ai_command_output", "paste_sent_unverified", []),
            (.triggerMismatchShown, false, false, "review_text", "shown_in_window", ["needs_review"]),
            (.unsafeFinalizeShown, false, false, "review_text", "shown_in_window", ["needs_review"]),
            (.aiCommandShown, false, false, "ai_command_output", "shown_in_window", [])
        ]
        for (situation, enabled, failed, kind, status, flags) in rows {
            let d = P.decision(output: " \nsynthetic output \n", situation: situation,
                cleanupEnabled: enabled, cleanupDidFail: failed, spokenInstruction: "synthetic instruction")
            check(d?.storedText == "synthetic output" && d?.kind == kind && d?.status == status && d?.flags == flags.sorted()
                && d?.spokenInstruction == (kind == "ai_command_output" ? "synthetic instruction" : nil), "decision \(situation) \(enabled) \(failed)")
        }
        for situation in [P.Situation.triggerOnlySend, .cancelled, .emptyOutput, .customInstructionOptimization] {
            check(P.decision(output: "synthetic", situation: situation) == nil, "omits \(situation)")
        }
        check(P.decision(output: " \n", situation: .inserted) == nil, "omits blank output")
        let secure = P.decision(output: "synthetic secret", situation: .secureInputBlocked, spokenInstruction: "synthetic")
        check(secure?.storedText == nil && secure?.spokenInstruction == nil && secure?.kind == "none"
              && secure?.status == "secure_input_blocked" && secure?.flags == ["secure_input_blocked"], "secure input metadata only")
        let literal = #"{"id":"11111111-1111-1111-1111-111111111111","createdAt":"2026-01-01T00:00:00Z","mode":"ai_command","storedText":"synthetic instruction","storedTextKind":"ai_command_transcript","cleanupEnabled":false,"cleanupSucceeded":false,"insertStatus":"not_applicable","flags":[],"schemaVersion":2}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try? decoder.decode(InputHistoryEntry.self, from: Data(literal.utf8))
        check(old?.spokenInstruction == nil && old?.schemaVersion == 2 && old?.isValidForStorage == true, "literal v2 decodes unchanged")
        let root = storageRootURL.appendingPathComponent("history-v3")
        let store = InputHistoryStore(storageRootURL: root)
        let entry = InputHistoryEntry.aiCommandOutput(output: "synthetic answer", spokenInstruction: nil, status: "shown_in_window")
        let v3 = InputHistoryEntry.aiCommandOutput(output: "synthetic answer", spokenInstruction: "synthetic instruction", status: "inserted")
        let encoded = try? JSONEncoder().encode(v3)
        let v2 = encoded.flatMap { try? JSONDecoder().decode(V2Entry.self, from: $0) }
        // 旧ビルドでも未知のキーは無視されるが、再保存するとspokenInstructionは失われる。
        check(v2?.storedText == v3.storedText && v2?.schemaVersion == 3, "v2 shaped decoder accepts v3")
        check(entry.schemaVersion == 3 && entry.isValidForStorage, "output factory valid without instruction")
        var invalid = entry; invalid.storedText = " \n"
        check(!invalid.isValidForStorage, "blank AI output rejected")
        invalid.storedText = "synthetic"; invalid.storedTextKind = "review_text"
        check(!invalid.isValidForStorage, "unsupported AI kind rejected")
        check(store.recordOutput(entry, retentionDays: 0) == .saved, "records output")
        let file = root.appendingPathComponent("history/input_history.jsonl")
        let before = try? Data(contentsOf: file)
        var duplicate = entry; duplicate.storedText = "replacement"
        check(store.recordOutput(duplicate, retentionDays: 0) == .saved && store.entries == [entry]
              && (try? Data(contentsOf: file)) == before, "duplicate ID leaves bytes unchanged")
        check(store.updateInsertStatus(id: entry.id, status: "inserted") == .saved
              && InputHistoryStore(storageRootURL: root).entries.first?.insertStatus == "inserted", "status promotion persists")
        if let old {
            _ = store.recordOutput(old, retentionDays: 0)
            check(store.upgradeAICommandEntry(id: old.id, output: "synthetic answer", spokenInstruction: "synthetic instruction",
                status: "shown_in_window", retentionDays: 0) == .saved, "upgrade saved")
            let reloaded = InputHistoryStore(storageRootURL: root).entries.first { $0.id == old.id }
            check(reloaded?.createdAt == old.createdAt && reloaded?.mode == old.mode && reloaded?.storedTextKind == "ai_command_output"
                  && reloaded?.spokenInstruction == "synthetic instruction" && reloaded?.schemaVersion == 3, "upgrade preserves identity and date on disk")
        }
        let missingID = UUID()
        check(store.upgradeAICommandEntry(id: missingID, output: "synthetic answer", spokenInstruction: nil,
            status: "inserted", retentionDays: 0) == .saved && !store.entries.contains { $0.id == missingID }, "missing upgrade is no-op")
        var io = InputHistoryFileIO.live
        io.atomicWrite = { _, _ in throw CocoaError(.fileWriteUnknown) }
        let failing = InputHistoryStore(storageRootURL: root, fileIO: io)
        let snapshot = failing.entries
        if let old {
            let failureRoot = storageRootURL.appendingPathComponent("history-v3-failure")
            let seed = InputHistoryStore(storageRootURL: failureRoot)
            _ = seed.recordOutput(old, retentionDays: 0)
            let failure = InputHistoryStore(storageRootURL: failureRoot, fileIO: io)
            check(failure.upgradeAICommandEntry(id: old.id, output: "answer", spokenInstruction: nil, status: "inserted", retentionDays: 0) == .failed
                  && failure.entries == [old] && InputHistoryStore(storageRootURL: failureRoot).entries == [old], "failed atomic upgrade preserves memory and disk")
        }
        check(failing.updateInsertStatus(id: entry.id, status: "shown_in_window") == .failed && failing.entries == snapshot, "failed rewrite does not publish")
        try? Data("malformed\n".utf8).write(to: file)
        let blocked = InputHistoryStore(storageRootURL: root)
        // 従来の追記と同じく、壊れた行は残したまま末尾へ追記できる。全体の書き換えは拒否される。
        let appended = blocked.recordOutput(entry, retentionDays: 0)
        let afterAppend = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(appended == .saved && afterAppend.hasPrefix("malformed\n")
              && afterAppend.split(separator: "\n").count == 2, "malformed history keeps its bad line and still accepts an appended output")
        check(blocked.updateInsertStatus(id: entry.id, status: "inserted") == .blockedByMalformedHistory
              && ((try? String(contentsOf: file, encoding: .utf8)) ?? "") == afterAppend, "malformed history still blocks whole-file rewrites")
        return results
    }
}
