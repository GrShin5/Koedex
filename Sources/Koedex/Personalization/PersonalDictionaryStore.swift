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

    init(
        id: UUID = UUID(),
        preferredForm: String,
        spokenForms: [String] = [],
        notes: String = "",
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = PersonalDictionaryEntry.currentSchemaVersion
    ) {
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
    }

    enum ImportError: Error, Equatable {
        case staleSnapshot
        case invalidResolution
        case writeFailed
    }

    @Published private(set) var entries: [PersonalDictionaryEntry] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let atomicDataWriter: (Data, URL) throws -> Void

    init(
        storageRootURL: URL? = nil,
        atomicDataWriter: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
            StoragePermissions.applyFileMode(to: url)
        }
    ) {
        let root: URL
        if let storageRootURL {
            root = storageRootURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = appSupport.appendingPathComponent("Koedex", isDirectory: true)
        }
        self.fileURL = root.appendingPathComponent("personal_dictionary.json")
        self.atomicDataWriter = atomicDataWriter

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
        entries.filter { $0.enabled && !$0.preferredForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func add(preferredForm: String, spokenForms: [String], notes: String) {
        guard let normalized = normalized(preferredForm: preferredForm, spokenForms: spokenForms, notes: notes) else { return }

        let entry = PersonalDictionaryEntry(
            preferredForm: normalized.preferredForm,
            spokenForms: normalized.spokenForms,
            notes: normalized.notes
        )
        entries.insert(entry, at: 0)
        save()
    }

    func update(id: UUID, preferredForm: String, spokenForms: [String], notes: String, enabled: Bool) {
        guard let normalized = normalized(preferredForm: preferredForm, spokenForms: spokenForms, notes: notes),
              let index = entries.firstIndex(where: { $0.id == id }) else { return }

        entries[index].preferredForm = normalized.preferredForm
        entries[index].spokenForms = normalized.spokenForms
        entries[index].notes = normalized.notes
        entries[index].enabled = enabled
        entries[index].updatedAt = Date()
        entries.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    func setEnabled(id: UUID, enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
        entries[index].updatedAt = Date()
        entries.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = entries.count
        entries.removeAll { ids.contains($0.id) }
        if entries.count != before {
            save()
        }
    }

    func applyImport(_ draft: UserDictionaryImportDraft) throws -> ImportReceipt {
        guard entries == draft.existingEntriesSnapshot else { throw ImportError.staleSnapshot }
        var candidate = entries
        var insertedCount = 0
        var replacedCount = 0
        var keptExistingCount = 0

        for row in draft.additions {
            guard let entry = entry(from: row) else { throw ImportError.invalidResolution }
            candidate.insert(entry, at: 0)
            insertedCount += 1
        }
        for (index, conflict) in draft.singleExistingConflicts.enumerated() {
            switch draft.action(for: index) {
            case .keepExisting:
                keptExistingCount += 1
            case .appendDuplicate:
                guard let entry = entry(from: conflict.row) else { throw ImportError.invalidResolution }
                candidate.insert(entry, at: 0)
                insertedCount += 1
            case .replace(let existingID):
                guard existingID == conflict.existingEntry.id,
                      let candidateIndex = candidate.firstIndex(where: { $0.id == existingID }),
                      let normalized = normalized(
                        preferredForm: conflict.row.preferredForm,
                        spokenForms: conflict.row.spokenForms,
                        notes: conflict.row.notes
                      ) else { throw ImportError.invalidResolution }
                candidate[candidateIndex].preferredForm = normalized.preferredForm
                candidate[candidateIndex].spokenForms = normalized.spokenForms
                candidate[candidateIndex].notes = normalized.notes
                candidate[candidateIndex].enabled = conflict.row.enabled
                candidate[candidateIndex].updatedAt = Date()
                replacedCount += 1
            }
        }
        candidate.sort { $0.updatedAt > $1.updatedAt }
        let candidateData: Data
        do {
            candidateData = try encodedFile(entries: candidate)
            let root = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: StoragePermissions.directoryAttributes
            )
            let backupURL = root.appendingPathComponent("personal_dictionary.pre-import-backup.json")
            if replacedCount > 0 {
                try atomicDataWriter(try encodedFile(entries: entries), backupURL)
            }
            try atomicDataWriter(candidateData, fileURL)
            entries = candidate
            return ImportReceipt(
                insertedCount: insertedCount,
                replacedCount: replacedCount,
                keptExistingCount: keptExistingCount,
                backupURL: replacedCount > 0 ? backupURL : nil
            )
        } catch {
            throw ImportError.writeFailed
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }

        if let file = try? decoder.decode(PersonalDictionaryFile.self, from: data) {
            entries = file.entries.sorted { $0.updatedAt > $1.updatedAt }
        } else if let legacyEntries = try? decoder.decode([PersonalDictionaryEntry].self, from: data) {
            entries = legacyEntries.sorted { $0.updatedAt > $1.updatedAt }
        } else {
            entries = []
        }
    }

    private func save() {
        do {
            let root = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: StoragePermissions.directoryAttributes
            )
            try atomicDataWriter(try encodedFile(entries: entries), fileURL)
        } catch {
            AppLog.shared.error("[PersonalDictionaryStore] 保存失敗: \(AppLog.safeDescription(error))")
        }
    }

    private func normalizedList(_ values: [String]) -> [String] {
        let trimmed = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(trimmed)).sorted()
    }

    private func normalized(preferredForm: String, spokenForms: [String], notes: String) -> (preferredForm: String, spokenForms: [String], notes: String)? {
        let preferred = preferredForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferred.isEmpty else { return nil }
        return (preferred, normalizedList(spokenForms), notes.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func entry(from row: UserDictionaryCSV.Row) -> PersonalDictionaryEntry? {
        guard let normalized = normalized(
            preferredForm: row.preferredForm,
            spokenForms: row.spokenForms,
            notes: row.notes
        ) else { return nil }
        return PersonalDictionaryEntry(
            preferredForm: normalized.preferredForm,
            spokenForms: normalized.spokenForms,
            notes: normalized.notes,
            enabled: row.enabled
        )
    }

    private func encodedFile(entries: [PersonalDictionaryEntry]) throws -> Data {
        try encoder.encode(PersonalDictionaryFile(schemaVersion: 1, entries: entries))
    }
}
