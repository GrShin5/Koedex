import Foundation
import Combine

struct PersonalDictionaryEntry: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var id: UUID
    var preferredForm: String
    var spokenForms: [String]
    var notes: String
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(id: UUID = UUID(), preferredForm: String, spokenForms: [String] = [], notes: String = "", enabled: Bool = true, createdAt: Date = Date(), updatedAt: Date = Date(), schemaVersion: Int = PersonalDictionaryEntry.currentSchemaVersion) {
        self.id = id
        self.preferredForm = preferredForm
        self.spokenForms = spokenForms
        self.notes = notes
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

private struct PersonalDictionaryFile: Codable {
    var schemaVersion: Int
    var entries: [PersonalDictionaryEntry]
}

@MainActor
final class PersonalDictionaryStore: ObservableObject {
    struct ImportReceipt: Equatable {
        let insertedCount: Int
        let replacedCount: Int
        let keptExistingCount: Int
        let backupURL: URL?
        let hasBackupWarning: Bool
    }

    enum LoadStatus: Equatable {
        case missing
        case ready
        case recoveryRequired(DictionaryRecoveryAnalysis)
    }

    enum OperationError: Error, Equatable { case recoveryRequired, invalidInput, writeFailed }
    enum MutationResult: Equatable {
        case saved
        case savedWithBackupWarning
        case failed(OperationError)
        var succeeded: Bool {
            switch self { case .saved, .savedWithBackupWarning: return true; case .failed: return false }
        }
    }
    enum ImportError: Error, Equatable { case staleSnapshot, recoveryRequired, invalidResolution, writeFailed }

    @Published private(set) var entries: [PersonalDictionaryEntry] = []
    @Published private(set) var loadStatus: LoadStatus = .missing
    @Published private(set) var backupNeedsRetry = false

    private let fileURL: URL
    private let lastKnownGoodURL: URL
    private let preImportBackupURL: URL
    private let recoveryDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let atomicDataWriter: (Data, URL) throws -> Void
    private let recoveryFileIO: DictionaryRecoveryFileIO

    init(storageRootURL: URL? = nil, atomicDataWriter: @escaping (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
        StoragePermissions.applyFileMode(to: url)
    }, recoveryFileIO: DictionaryRecoveryFileIO = .live) {
        let root: URL
        if let storageRootURL { root = storageRootURL }
        else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = appSupport.appendingPathComponent("Koedex", isDirectory: true)
        }
        fileURL = root.appendingPathComponent("personal_dictionary.json")
        lastKnownGoodURL = root.appendingPathComponent("personal_dictionary.last-known-good.json")
        preImportBackupURL = root.appendingPathComponent("personal_dictionary.pre-import-backup.json")
        recoveryDirectoryURL = root.appendingPathComponent("Recovery", isDirectory: true)
        self.atomicDataWriter = atomicDataWriter
        self.recoveryFileIO = recoveryFileIO
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        StoragePermissions.ensureDirectory(at: root)
        load()
    }

    var enabledEntries: [PersonalDictionaryEntry] {
        guard case .ready = loadStatus else { return [] }
        return entries.filter { $0.enabled && !$0.preferredForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var storageDirectoryURL: URL { fileURL.deletingLastPathComponent() }
    var requiresRecovery: Bool { if case .recoveryRequired = loadStatus { return true }; return false }
    private var canMutate: Bool { !requiresRecovery }

    @discardableResult
    func add(preferredForm: String, spokenForms: [String], notes: String, enabled: Bool = true) -> MutationResult {
        guard canMutate else { return .failed(.recoveryRequired) }
        guard let value = normalized(preferredForm: preferredForm, spokenForms: spokenForms, notes: notes) else { return .failed(.invalidInput) }
        var candidate = entries
        candidate.insert(PersonalDictionaryEntry(preferredForm: value.preferredForm, spokenForms: value.spokenForms, notes: value.notes, enabled: enabled), at: 0)
        return persistAndPublish(candidate)
    }

    @discardableResult
    func update(id: UUID, preferredForm: String, spokenForms: [String], notes: String, enabled: Bool) -> MutationResult {
        guard canMutate else { return .failed(.recoveryRequired) }
        guard let value = normalized(preferredForm: preferredForm, spokenForms: spokenForms, notes: notes), let index = entries.firstIndex(where: { $0.id == id }) else { return .failed(.invalidInput) }
        var candidate = entries
        candidate[index].preferredForm = value.preferredForm
        candidate[index].spokenForms = value.spokenForms
        candidate[index].notes = value.notes
        candidate[index].enabled = enabled
        candidate[index].updatedAt = Date()
        candidate.sort { $0.updatedAt > $1.updatedAt }
        return persistAndPublish(candidate)
    }

    @discardableResult
    func setEnabled(id: UUID, enabled: Bool) -> MutationResult {
        guard canMutate else { return .failed(.recoveryRequired) }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .failed(.invalidInput) }
        var candidate = entries
        candidate[index].enabled = enabled
        candidate[index].updatedAt = Date()
        candidate.sort { $0.updatedAt > $1.updatedAt }
        return persistAndPublish(candidate)
    }

    @discardableResult func delete(id: UUID) -> MutationResult { delete(ids: [id]) }
    @discardableResult
    func delete(ids: Set<UUID>) -> MutationResult {
        guard canMutate else { return .failed(.recoveryRequired) }
        guard !ids.isEmpty else { return .saved }
        let candidate = entries.filter { !ids.contains($0.id) }
        guard candidate.count != entries.count else { return .saved }
        return persistAndPublish(candidate)
    }

    func applyImport(_ draft: UserDictionaryImportDraft) throws -> ImportReceipt {
        guard canMutate else { throw ImportError.recoveryRequired }
        guard entries == draft.existingEntriesSnapshot else { throw ImportError.staleSnapshot }
        var candidate = entries
        var inserted = 0, replaced = 0, kept = 0
        for row in draft.additions {
            guard let entry = entry(from: row) else { throw ImportError.invalidResolution }
            candidate.insert(entry, at: 0); inserted += 1
        }
        for (index, conflict) in draft.singleExistingConflicts.enumerated() {
            switch draft.action(for: index) {
            case .keepExisting: kept += 1
            case .appendDuplicate:
                guard let entry = entry(from: conflict.row) else { throw ImportError.invalidResolution }
                candidate.insert(entry, at: 0); inserted += 1
            case .replace(let existingID):
                guard existingID == conflict.existingEntry.id,
                      let candidateIndex = candidate.firstIndex(where: { $0.id == existingID }),
                      let value = normalized(preferredForm: conflict.row.preferredForm, spokenForms: conflict.row.spokenForms, notes: conflict.row.notes) else { throw ImportError.invalidResolution }
                candidate[candidateIndex].preferredForm = value.preferredForm
                candidate[candidateIndex].spokenForms = value.spokenForms
                candidate[candidateIndex].notes = value.notes
                candidate[candidateIndex].enabled = conflict.row.enabled
                candidate[candidateIndex].updatedAt = Date(); replaced += 1
            }
        }
        candidate.sort { $0.updatedAt > $1.updatedAt }
        if replaced > 0 {
            do {
                try DictionarySafeFilePolicy.requireSafeDestination(preImportBackupURL)
                try atomicDataWriter(try encodedFile(entries: entries), preImportBackupURL)
            } catch { throw ImportError.writeFailed }
        }
        let result = persistAndPublish(candidate)
        guard result.succeeded else { throw ImportError.writeFailed }
        let backupWarning = result == .savedWithBackupWarning
        return ImportReceipt(insertedCount: inserted, replacedCount: replaced, keptExistingCount: kept, backupURL: replaced > 0 ? preImportBackupURL : nil, hasBackupWarning: backupWarning)
    }

    @discardableResult func retryRecoveryLoad() -> Bool { load(); return !requiresRecovery }

    @discardableResult
    func retryLastKnownGoodBackup() -> MutationResult {
        guard case .ready = loadStatus else { return .failed(.recoveryRequired) }
        return updateLastKnownGood(with: entries) ? .saved : .savedWithBackupWarning
    }

    func recoverRescuedEntries(expectedFingerprint: DictionaryFileFingerprint) throws {
        guard case .recoveryRequired(let analysis) = loadStatus, analysis.fingerprint == expectedFingerprint, !analysis.rescuedEntries.isEmpty else { throw DictionaryRecoveryError.staleInput }
        try replaceDuringRecovery(analysis.rescuedEntries, expectedFingerprint: expectedFingerprint)
    }

    func recoverFromBackup(_ candidate: DictionaryRecoveryCandidate, expectedFingerprint: DictionaryFileFingerprint) throws {
        guard case .recoveryRequired(let analysis) = loadStatus, analysis.fingerprint == expectedFingerprint, analysis.candidates.contains(candidate) else { throw DictionaryRecoveryError.staleInput }
        let data = try recoveryFileIO.read(candidate.url)
        guard fingerprint(data) == candidate.fingerprint else {
            loadStatus = .recoveryRequired(makeAnalysis(data: try? recoveryFileIO.read(fileURL), readError: DictionaryRecoveryError.staleInput))
            throw DictionaryRecoveryError.staleInput
        }
        try replaceDuringRecovery(
            try StrictDictionaryCodec.decode(data, decoder: decoder),
            expectedFingerprint: expectedFingerprint,
            candidateData: data
        )
    }

    func restartEmpty(expectedFingerprint: DictionaryFileFingerprint, preservationConfirmed: Bool) throws {
        guard preservationConfirmed else { throw DictionaryRecoveryError.preservationConfirmationRequired }
        try replaceDuringRecovery([], expectedFingerprint: expectedFingerprint)
    }

    private func load() {
        let data: Data
        do { data = try recoveryFileIO.read(fileURL) }
        catch {
            entries = []
            if isMissingFile(error) { loadStatus = .missing }
            else { loadStatus = .recoveryRequired(makeAnalysis(data: nil, readError: error)) }
            return
        }
        do {
            let loaded = try StrictDictionaryCodec.decode(data, decoder: decoder).sorted { $0.updatedAt > $1.updatedAt }
            entries = loaded; loadStatus = .ready; _ = updateLastKnownGood(with: loaded)
        } catch {
            entries = []; loadStatus = .recoveryRequired(makeAnalysis(data: data, readError: error))
        }
    }

    private func makeAnalysis(data: Data?, readError: Error) -> DictionaryRecoveryAnalysis {
        let candidates = recoveryCandidates()
        guard let data else {
            let reason: DictionaryRecoveryAnalysis.Reason = (readError as? DictionaryRecoveryError) == .unsafeFile ? .unsafeFile : .unreadable
            return DictionaryRecoveryAnalysis(reason: reason, fingerprint: nil, rescuedEntries: [], rejectedEntryCount: 0, hasUnknownRemainder: true, candidates: candidates)
        }
        let fingerprint = self.fingerprint(data)
        do {
            let scan = try DictionaryMalformedScanner.scan(data, decoder: decoder)
            return DictionaryRecoveryAnalysis(reason: .corruptOrUnsupported, fingerprint: fingerprint, rescuedEntries: scan.entries, rejectedEntryCount: scan.rejectedCount, hasUnknownRemainder: scan.hasUnknownRemainder, candidates: candidates)
        } catch DictionaryRecoveryError.inputTooLarge {
            return DictionaryRecoveryAnalysis(reason: .tooLarge, fingerprint: fingerprint, rescuedEntries: [], rejectedEntryCount: 0, hasUnknownRemainder: true, candidates: candidates)
        } catch DictionaryRecoveryError.nestingTooDeep {
            return DictionaryRecoveryAnalysis(reason: .tooDeep, fingerprint: fingerprint, rescuedEntries: [], rejectedEntryCount: 0, hasUnknownRemainder: true, candidates: candidates)
        } catch {
            return DictionaryRecoveryAnalysis(reason: .ambiguous, fingerprint: fingerprint, rescuedEntries: [], rejectedEntryCount: 0, hasUnknownRemainder: true, candidates: candidates)
        }
    }

    private func recoveryCandidates() -> [DictionaryRecoveryCandidate] {
        [(DictionaryRecoveryCandidate.Kind.lastKnownGood, lastKnownGoodURL), (.preImportBackup, preImportBackupURL)].compactMap { kind, url in
            guard let data = try? recoveryFileIO.read(url), let candidateEntries = try? StrictDictionaryCodec.decode(data, decoder: decoder) else { return nil }
            return DictionaryRecoveryCandidate(kind: kind, url: url, modifiedAt: (try? recoveryFileIO.attributes(url))?[.modificationDate] as? Date, entryCount: candidateEntries.count, fingerprint: fingerprint(data))
        }
    }

    private func replaceDuringRecovery(
        _ candidate: [PersonalDictionaryEntry],
        expectedFingerprint: DictionaryFileFingerprint,
        candidateData: Data? = nil
    ) throws {
        guard case .recoveryRequired(let analysis) = loadStatus, analysis.canReplaceOriginal else { throw DictionaryRecoveryError.unreadable }
        let original = try recoveryFileIO.read(fileURL)
        guard fingerprint(original) == expectedFingerprint else { loadStatus = .recoveryRequired(makeAnalysis(data: original, readError: DictionaryRecoveryError.staleInput)); throw DictionaryRecoveryError.staleInput }
        try preserveRawOriginal(original)
        let encoded = try candidateData ?? encodedFile(entries: candidate)
        let expected = try StrictDictionaryCodec.decode(encoded, decoder: decoder)
        guard expected == candidate else { throw DictionaryRecoveryError.verificationFailed }
        let rechecked = try recoveryFileIO.read(fileURL)
        guard fingerprint(rechecked) == expectedFingerprint else { loadStatus = .recoveryRequired(makeAnalysis(data: rechecked, readError: DictionaryRecoveryError.staleInput)); throw DictionaryRecoveryError.staleInput }
        do {
            try DictionarySafeFilePolicy.requireSafeDestination(fileURL)
            try recoveryFileIO.atomicWrite(encoded, fileURL)
            let verifiedBytes = try recoveryFileIO.read(fileURL)
            let verified = try StrictDictionaryCodec.decode(verifiedBytes, decoder: decoder)
            guard verified == expected, candidateData == nil || verifiedBytes == encoded else { throw DictionaryRecoveryError.verificationFailed }
            entries = verified.sorted { $0.updatedAt > $1.updatedAt }; loadStatus = .ready
            _ = updateLastKnownGood(with: entries)
        } catch let error as DictionaryRecoveryError { throw error }
        catch { throw DictionaryRecoveryError.writeFailed }
    }

    private func preserveRawOriginal(_ data: Data) throws {
        do {
            try recoveryFileIO.createDirectory(recoveryDirectoryURL)
            try verifyMode(recoveryDirectoryURL, expected: StoragePermissions.directoryPosixPermissions)
            let backupURL = recoveryDirectoryURL.appendingPathComponent("original-\(data.dictionarySHA256).json")
            do { try recoveryFileIO.createExclusive(data, backupURL) }
            catch DictionaryRecoveryError.backupAlreadyExists {
                guard try recoveryFileIO.read(backupURL) == data else { throw DictionaryRecoveryError.verificationFailed }
            }
            try DictionarySafeFilePolicy.requireSafeDestination(backupURL)
            try recoveryFileIO.setAttributes(StoragePermissions.fileAttributes, backupURL)
            try verifyMode(backupURL, expected: StoragePermissions.filePosixPermissions)
            guard try recoveryFileIO.read(backupURL).dictionarySHA256 == data.dictionarySHA256 else { throw DictionaryRecoveryError.verificationFailed }
        } catch let error as DictionaryRecoveryError { throw error }
        catch { throw DictionaryRecoveryError.backupFailed }
    }

    private func verifyMode(_ url: URL, expected: Int) throws {
        let attributes = try recoveryFileIO.attributes(url)
        guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o777 == expected else { throw DictionaryRecoveryError.verificationFailed }
    }

    private func persistAndPublish(_ candidate: [PersonalDictionaryEntry]) -> MutationResult {
        do {
            let data = try encodedFile(entries: candidate)
            let expected = try StrictDictionaryCodec.decode(data, decoder: decoder)
            try DictionarySafeFilePolicy.requireSafeDestination(fileURL)
            try atomicDataWriter(data, fileURL)
            let persisted: Data
            do { persisted = try recoveryFileIO.read(fileURL) }
            catch {
                loadStatus = .recoveryRequired(makeAnalysis(data: nil, readError: error))
                return .failed(.writeFailed)
            }
            guard (try? StrictDictionaryCodec.decode(persisted, decoder: decoder)) == expected else {
                loadStatus = .recoveryRequired(makeAnalysis(data: persisted, readError: DictionaryRecoveryError.verificationFailed))
                return .failed(.writeFailed)
            }
            entries = expected; loadStatus = .ready
            return updateLastKnownGood(with: expected) ? .saved : .savedWithBackupWarning
        } catch {
            AppLog.shared.error("[PersonalDictionaryStore] 保存失敗: \(AppLog.safeDescription(error))")
            return .failed(.writeFailed)
        }
    }

    private func updateLastKnownGood(with entries: [PersonalDictionaryEntry]) -> Bool {
        do {
            let data = try encodedFile(entries: entries)
            try DictionarySafeFilePolicy.requireSafeDestination(lastKnownGoodURL)
            try atomicDataWriter(data, lastKnownGoodURL)
            let verified = try StrictDictionaryCodec.decode(recoveryFileIO.read(lastKnownGoodURL), decoder: decoder) == entries
            backupNeedsRetry = !verified
            return verified
        } catch {
            backupNeedsRetry = true
            AppLog.shared.warn("[PersonalDictionaryStore] last-known-good更新失敗")
            return false
        }
    }

    private func isMissingFile(_ error: Error) -> Bool { let value = error as NSError; return value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError }
    private func fingerprint(_ data: Data) -> DictionaryFileFingerprint { DictionaryFileFingerprint(byteCount: data.count, sha256: data.dictionarySHA256) }
    private func normalizedList(_ values: [String]) -> [String] { Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted() }
    private func normalized(preferredForm: String, spokenForms: [String], notes: String) -> (preferredForm: String, spokenForms: [String], notes: String)? {
        let preferred = preferredForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferred.isEmpty else { return nil }
        return (preferred, normalizedList(spokenForms), notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func entry(from row: UserDictionaryCSV.Row) -> PersonalDictionaryEntry? {
        guard let value = normalized(preferredForm: row.preferredForm, spokenForms: row.spokenForms, notes: row.notes) else { return nil }
        return PersonalDictionaryEntry(preferredForm: value.preferredForm, spokenForms: value.spokenForms, notes: value.notes, enabled: row.enabled)
    }
    private func encodedFile(entries: [PersonalDictionaryEntry]) throws -> Data { try encoder.encode(PersonalDictionaryFile(schemaVersion: PersonalDictionaryEntry.currentSchemaVersion, entries: entries)) }
}
