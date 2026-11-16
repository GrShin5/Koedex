import Foundation

enum InputHistoryFlag {
    static let needsReview = "needs_review"
    static let cleanupFailed = "cleanup_failed"
    static let insertFailed = "insert_failed"
    static let secureInputBlocked = "secure_input_blocked"
    static let tooShort = "too_short"
    static let noiseCandidate = "noise_candidate"
    static let excludedByUser = "excluded_by_user"
    static let clipboardRestoreFailed = "clipboard_restore_failed"
}

enum InputHistoryStoredTextKind {
    static let aiCommandOutput = "ai_command_output"
    static let reviewText = "review_text"
    static let aiAssistedOutput = "ai_assisted_output"
    static let rawTranscriptOutput = "raw_transcript_output"
    static let aiCommandTranscript = "ai_command_transcript"
    static let none = "none"
}

enum InputHistoryMode {
    static let all = "all"
    static let voiceInput = "voice_input"
    static let handsFreeSend = "hands_free_send"
    static let aiCommand = "ai_command"
}

enum InputHistoryInsertStatus {
    static let shownInWindow = "shown_in_window"
    static let inserted = "inserted"
    static let pasteSentUnverified = "paste_sent_unverified"
    static let secureInputBlocked = "secure_input_blocked"
    static let failed = "failed"
    static let notApplicable = "not_applicable"
}

struct InputHistoryEntry: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 3

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
    /// AIに指示の入力元。値を持つ場合でも保存するのは経路ラベルだけで、
    /// 選択本文・クリップボード本文・URL・音声は保存しない。
    /// 回答は呼び出し側が保存を選んだ場合だけ保持する。
    var aiCommandInputSource: AICommandInputSource?
    var spokenInstruction: String?
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        mode: String = InputHistoryMode.voiceInput,
        storedText: String?,
        storedTextKind: String,
        cleanupEnabled: Bool,
        cleanupSucceeded: Bool,
        insertStatus: String,
        flags: [String],
        modelSlug: String?,
        reasoningEffort: String?,
        latencyMs: Int?,
        aiCommandInputSource: AICommandInputSource? = nil,
        spokenInstruction: String? = nil,
        schemaVersion: Int = InputHistoryEntry.currentSchemaVersion
    ) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.storedText = storedText
        self.storedTextKind = storedTextKind
        self.cleanupEnabled = cleanupEnabled
        self.cleanupSucceeded = cleanupSucceeded
        self.insertStatus = insertStatus
        self.flags = Array(Set(flags)).sorted()
        self.modelSlug = modelSlug
        self.reasoningEffort = reasoningEffort
        self.latencyMs = latencyMs
        self.aiCommandInputSource = aiCommandInputSource
        self.spokenInstruction = spokenInstruction
        self.schemaVersion = schemaVersion
    }

    var isExcludedByUser: Bool {
        flags.contains(InputHistoryFlag.excludedByUser)
    }

    /// この旧形式の履歴は音声指示の確定文字起こしだけを保持する。
    /// 選択元・回答・URL・音声をこのAPIへ渡せない形にして保存境界を狭める。
    static func aiCommandTranscript(
        _ transcript: String,
        createdAt: Date = Date(),
        modelSlug: String? = nil,
        reasoningEffort: String? = nil,
        latencyMs: Int? = nil,
        inputSource: AICommandInputSource? = nil
    ) -> InputHistoryEntry {
        InputHistoryEntry(
            createdAt: createdAt,
            mode: InputHistoryMode.aiCommand,
            storedText: transcript,
            storedTextKind: InputHistoryStoredTextKind.aiCommandTranscript,
            cleanupEnabled: false,
            cleanupSucceeded: false,
            insertStatus: InputHistoryInsertStatus.notApplicable,
            flags: [],
            modelSlug: modelSlug,
            reasoningEffort: reasoningEffort,
            latencyMs: latencyMs,
            aiCommandInputSource: inputSource
        )
    }

    /// 回答の保存は呼び出し側が判断する。入力元の本文や音声は受け取らない。
    static func aiCommandOutput(
        output: String, spokenInstruction: String?, status: String,
        id: UUID = UUID(), createdAt: Date = Date(),
        inputSource: AICommandInputSource? = nil, modelSlug: String? = nil,
        reasoningEffort: String? = nil, latencyMs: Int? = nil
    ) -> InputHistoryEntry {
        InputHistoryEntry(
            id: id, createdAt: createdAt, mode: InputHistoryMode.aiCommand,
            storedText: output, storedTextKind: InputHistoryStoredTextKind.aiCommandOutput,
            cleanupEnabled: false, cleanupSucceeded: false, insertStatus: status,
            flags: [], modelSlug: modelSlug, reasoningEffort: reasoningEffort,
            latencyMs: latencyMs, aiCommandInputSource: inputSource,
            spokenInstruction: spokenInstruction
        )
    }

    var isValidForStorage: Bool {
        guard mode == InputHistoryMode.aiCommand else { return true }
        guard [InputHistoryStoredTextKind.aiCommandTranscript, InputHistoryStoredTextKind.aiCommandOutput].contains(storedTextKind),
              let storedText else { return false }
        return !storedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func withFlag(_ flag: String, enabled: Bool) -> InputHistoryEntry {
        var copy = self
        var nextFlags = Set(copy.flags)
        if enabled {
            nextFlags.insert(flag)
        } else {
            nextFlags.remove(flag)
        }
        copy.flags = Array(nextFlags).sorted()
        return copy
    }
}
