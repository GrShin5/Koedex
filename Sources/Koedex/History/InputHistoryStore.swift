import Foundation
import Combine

@MainActor
final class InputHistoryStore: ObservableObject {
    @Published private(set) var entries: [InputHistoryEntry] = []

    private let directoryURL: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storageRootURL: URL? = nil) {
        let root: URL
        if let storageRootURL {
            root = storageRootURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            root = appSupport.appendingPathComponent("Koedex", isDirectory: true)
        }
        self.directoryURL = root.appendingPathComponent("history", isDirectory: true)
        self.fileURL = directoryURL.appendingPathComponent("input_history.jsonl")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8) else {
            entries = []
            return
        }

        entries = content
            .split(separator: "\n")
            .compactMap { line -> InputHistoryEntry? in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(InputHistoryEntry.self, from: lineData)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func append(_ entry: InputHistoryEntry, retentionDays: Int) {
        guard entry.isValidForStorage else {
            AppLog.shared.error("[InputHistoryStore] AIに指示の不正な履歴形式を拒否")
            return
        }
        entries.insert(entry, at: 0)
        appendLine(entry)
        prune(mode: entry.mode, retentionDays: retentionDays)
    }

    func visibleEntries(limit: Int) -> [InputHistoryEntry] {
        visibleEntries(limit: limit, mode: InputHistoryMode.all)
    }

    func visibleEntries(limit: Int, mode: String) -> [InputHistoryEntry] {
        let filtered = mode == InputHistoryMode.all ? entries : entries.filter { $0.mode == mode }
        guard limit > 0 else { return filtered }
        return Array(filtered.prefix(limit))
    }

    var storedTextCount: Int {
        entries.filter(Self.hasStoredText).count
    }

    var metadataOnlyCount: Int {
        entries.filter { !Self.hasStoredText($0) }.count
    }

    var metadataOnlyIDs: Set<UUID> {
        Set(entries.filter { !Self.hasStoredText($0) }.map(\.id))
    }

    func setExcluded(id: UUID, excluded: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = entries[index].withFlag(InputHistoryFlag.excludedByUser, enabled: excluded)
        rewriteFile()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        rewriteFile()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = entries.count
        entries.removeAll { ids.contains($0.id) }
        if entries.count != before {
            rewriteFile()
        }
    }

    func deleteDisplayedEntries(except selectedIDs: Set<UUID>, displayedIDs: Set<UUID>) {
        guard !displayedIDs.isEmpty else { return }
        let before = entries.count
        entries.removeAll { displayedIDs.contains($0.id) && !selectedIDs.contains($0.id) }
        if entries.count != before {
            rewriteFile()
        }
    }

    func deleteEntriesWithoutStoredText() {
        let before = entries.count
        entries.removeAll { !Self.hasStoredText($0) }
        if entries.count != before {
            rewriteFile()
        }
    }

    func deleteAll() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    func prune(retentionDays: Int) {
        prune(mode: InputHistoryMode.voiceInput, retentionDays: retentionDays)
    }

    /// 指定モードだけをpruneし、別モードの保持期間を巻き込まない。
    func prune(mode: String, retentionDays: Int) {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        let before = entries.count
        entries.removeAll { $0.mode == mode && $0.createdAt < cutoff }
        if entries.count != before {
            rewriteFile()
        }
    }

    private func appendLine(_ entry: InputHistoryEntry) {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(entry)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            AppLog.shared.error("[InputHistoryStore] 履歴追記失敗: \(AppLog.safeDescription(error))")
        }
    }

    private func rewriteFile() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let ordered = entries.sorted { $0.createdAt < $1.createdAt }
            var data = Data()
            for entry in ordered {
                data.append(try encoder.encode(entry))
                data.append(0x0A)
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.error("[InputHistoryStore] 履歴書き換え失敗: \(AppLog.safeDescription(error))")
        }
    }

    static func hasStoredText(_ entry: InputHistoryEntry) -> Bool {
        guard let text = entry.storedText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
