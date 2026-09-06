import Foundation
import CryptoKit
import Darwin

struct DictionaryRecoveryFileIO {
    var read: (URL) throws -> Data
    var atomicWrite: (Data, URL) throws -> Void
    var createExclusive: (Data, URL) throws -> Void
    var attributes: (URL) throws -> [FileAttributeKey: Any]
    var setAttributes: ([FileAttributeKey: Any], URL) throws -> Void
    var createDirectory: (URL) throws -> Void

    static let live = DictionaryRecoveryFileIO(
        read: { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DictionaryRecoveryError.unsafeFile
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        },
        atomicWrite: { data, url in
            try DictionarySafeFilePolicy.requireSafeDestination(url)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(StoragePermissions.fileAttributes, ofItemAtPath: url.path)
        },
        createExclusive: { try DictionaryRawBackupWriter.create($0, at: $1) },
        attributes: { try FileManager.default.attributesOfItem(atPath: $0.path) },
        setAttributes: { try FileManager.default.setAttributes($0, ofItemAtPath: $1.path) },
        createDirectory: { url in
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw DictionaryRecoveryError.unsafeFile }
            }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: StoragePermissions.directoryAttributes
            )
            try FileManager.default.setAttributes(StoragePermissions.directoryAttributes, ofItemAtPath: url.path)
        }
    )
}

/// Publish only a complete, verified file under the immutable content-addressed
/// name. A failed write leaves no partial final file that could block retry.
enum DictionaryRawBackupWriter {
    static func create(
        _ data: Data,
        at url: URL,
        writeContents: (Int32, Data) throws -> Void = writeAll
    ) throws {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".recovery-\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var needsClose = true
            defer {
                if needsClose { close(descriptor) }
                // This UUID temporary was created exclusively by this call.
                unlink(temporary.path)
            }
            try writeContents(descriptor, data)
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let closeResult = close(descriptor)
            needsClose = false
            guard closeResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard try Data(contentsOf: temporary) == data else { throw DictionaryRecoveryError.verificationFailed }
            // link is an atomic, exclusive publication: it never replaces an
            // existing raw backup, including a symlink or an unexpected file.
            guard link(temporary.path, url.path) == 0 else {
                if errno == EEXIST { throw DictionaryRecoveryError.backupAlreadyExists }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }
}

enum DictionaryRecoveryError: Error, Equatable {
    case unsafeFile
    case unreadable
    case unsupportedOrCorrupt
    case inputTooLarge
    case nestingTooDeep
    case ambiguousInput
    case noRecoverableEntries
    case backupAlreadyExists
    case backupFailed
    case verificationFailed
    case staleInput
    case writeFailed
    case preservationConfirmationRequired
}

struct DictionaryFileFingerprint: Equatable {
    let byteCount: Int
    let sha256: String
}

struct DictionaryRecoveryCandidate: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case lastKnownGood
        case preImportBackup
    }

    let kind: Kind
    let url: URL
    let modifiedAt: Date?
    let entryCount: Int
    let fingerprint: DictionaryFileFingerprint
    var id: String { kind.rawValue }
}

enum DictionarySafeFilePolicy {
    static func requireSafeDestination(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw DictionaryRecoveryError.unsafeFile }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct DictionaryRecoveryAnalysis: Equatable {
    static let maximumMalformedBytes = 8 * 1024 * 1024
    static let maximumNestingDepth = 32

    enum Reason: Equatable {
        case unreadable
        case unsafeFile
        case corruptOrUnsupported
        case tooLarge
        case tooDeep
        case ambiguous
    }

    let reason: Reason
    let fingerprint: DictionaryFileFingerprint?
    let rescuedEntries: [PersonalDictionaryEntry]
    let rejectedEntryCount: Int
    let hasUnknownRemainder: Bool
    let candidates: [DictionaryRecoveryCandidate]

    var canReplaceOriginal: Bool { fingerprint != nil }
}

enum StrictDictionaryCodec {
    private static let wrapperKeys: Set<String> = ["schemaVersion", "entries"]
    private static let entryKeys: Set<String> = [
        "id", "preferredForm", "spokenForms", "notes", "enabled",
        "createdAt", "updatedAt", "schemaVersion",
    ]

    static func decode(_ data: Data, decoder: JSONDecoder) throws -> [PersonalDictionaryEntry] {
        _ = try JSONSerialization.jsonObject(with: data, options: [])
        let text = try utf8Characters(data)
        var cursor = 0
        skipWhitespace(text, &cursor)
        let entryFragments: [Data]
        if cursor < text.count, text[cursor] == "{" {
            let members = try objectMembers(text, from: cursor)
            guard members.end == text.countAfterWhitespace,
                  members.values.count == wrapperKeys.count,
                  Set(members.values.map(\.key)) == wrapperKeys,
                  let schema = members.values.first(where: { $0.key == "schemaVersion" }),
                  exactInteger(try JSONSerialization.jsonObject(with: schema.value, options: [.fragmentsAllowed])) == PersonalDictionaryEntry.currentSchemaVersion,
                  let entries = members.values.first(where: { $0.key == "entries" }) else {
                throw DictionaryRecoveryError.unsupportedOrCorrupt
            }
            entryFragments = try arrayElements(try utf8Characters(entries.value))
        } else if cursor < text.count, text[cursor] == "[" {
            entryFragments = try arrayElements(text)
        } else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        var decoded: [PersonalDictionaryEntry] = []
        var ids = Set<UUID>()
        for fragment in entryFragments {
            let entry = try decodeEntry(fragment, decoder: decoder)
            guard ids.insert(entry.id).inserted else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            decoded.append(entry)
        }
        return decoded
    }

    static func decodeEntry(_ data: Data, decoder: JSONDecoder) throws -> PersonalDictionaryEntry {
        let text = try utf8Characters(data)
        let members = try objectMembers(text, from: text.firstNonWhitespace)
        guard members.end == text.countAfterWhitespace,
              members.values.count == entryKeys.count,
              Set(members.values.map(\.key)) == entryKeys,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] is String,
              let preferredForm = object["preferredForm"] as? String,
              !preferredForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              object["spokenForms"] is [String],
              object["notes"] is String,
              object["enabled"] is Bool,
              object["createdAt"] is String,
              object["updatedAt"] is String,
              exactInteger(object["schemaVersion"]) == PersonalDictionaryEntry.currentSchemaVersion else {
            throw DictionaryRecoveryError.unsupportedOrCorrupt
        }
        let entry = try decoder.decode(PersonalDictionaryEntry.self, from: data)
        guard entry.schemaVersion == PersonalDictionaryEntry.currentSchemaVersion else {
            throw DictionaryRecoveryError.unsupportedOrCorrupt
        }
        return entry
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }

    private struct Member { let key: String; let value: Data }
    private static func objectMembers(_ text: [Character], from start: Int) throws -> (values: [Member], end: Int) {
        guard start < text.count, text[start] == "{" else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        var cursor = start + 1
        var result: [Member] = []
        while true {
            skipWhitespace(text, &cursor)
            guard cursor < text.count else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            if text[cursor] == "}" { cursor += 1; return (result, cursor) }
            let keyRange = try stringRange(text, from: cursor)
            let keyData = Data(String(text[keyRange]).utf8)
            guard let key = try? JSONDecoder().decode(String.self, from: keyData) else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            cursor = keyRange.upperBound
            skipWhitespace(text, &cursor)
            guard cursor < text.count, text[cursor] == ":" else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            cursor += 1
            skipWhitespace(text, &cursor)
            let valueRange = try valueRange(text, from: cursor)
            result.append(Member(key: key, value: Data(String(text[valueRange]).utf8)))
            cursor = valueRange.upperBound
            skipWhitespace(text, &cursor)
            guard cursor < text.count else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            if text[cursor] == "," { cursor += 1; continue }
            if text[cursor] == "}" { cursor += 1; return (result, cursor) }
            throw DictionaryRecoveryError.unsupportedOrCorrupt
        }
    }

    private static func arrayElements(_ text: [Character]) throws -> [Data] {
        var cursor = text.firstNonWhitespace
        guard cursor < text.count, text[cursor] == "[" else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        cursor += 1
        var result: [Data] = []
        while true {
            skipWhitespace(text, &cursor)
            guard cursor < text.count else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            if text[cursor] == "]" {
                cursor += 1; skipWhitespace(text, &cursor)
                guard cursor == text.count else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
                return result
            }
            let range = try valueRange(text, from: cursor)
            result.append(Data(String(text[range]).utf8))
            cursor = range.upperBound
            skipWhitespace(text, &cursor)
            guard cursor < text.count else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
            if text[cursor] == "," { cursor += 1; continue }
            if text[cursor] == "]" { continue }
            throw DictionaryRecoveryError.unsupportedOrCorrupt
        }
    }

    private static func valueRange(_ text: [Character], from start: Int) throws -> Range<Int> {
        guard start < text.count else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        if text[start] == "\"" { return try stringRange(text, from: start) }
        if text[start] == "{" || text[start] == "[" {
            let closing: Character = text[start] == "{" ? "}" : "]"
            var stack: [Character] = [closing]
            var cursor = start + 1, inString = false, escaped = false
            while cursor < text.count {
                let value = text[cursor]
                if inString {
                    if escaped { escaped = false }
                    else if value == "\\" { escaped = true }
                    else if value == "\"" { inString = false }
                } else if value == "\"" { inString = true }
                else if value == "{" { stack.append("}") }
                else if value == "[" { stack.append("]") }
                else if value == "}" || value == "]" {
                    guard stack.last == value else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
                    stack.removeLast()
                    if stack.isEmpty { return start..<(cursor + 1) }
                }
                cursor += 1
            }
            throw DictionaryRecoveryError.unsupportedOrCorrupt
        }
        var cursor = start
        while cursor < text.count, text[cursor] != ",", text[cursor] != "}", text[cursor] != "]" { cursor += 1 }
        var end = cursor
        while end > start, text[end - 1].isWhitespace { end -= 1 }
        guard end > start else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        return start..<end
    }

    private static func stringRange(_ text: [Character], from start: Int) throws -> Range<Int> {
        guard start < text.count, text[start] == "\"" else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        var cursor = start + 1, escaped = false
        while cursor < text.count {
            if escaped { escaped = false }
            else if text[cursor] == "\\" { escaped = true }
            else if text[cursor] == "\"" { return start..<(cursor + 1) }
            cursor += 1
        }
        throw DictionaryRecoveryError.unsupportedOrCorrupt
    }

    private static func utf8Characters(_ data: Data) throws -> [Character] {
        guard let string = String(data: data, encoding: .utf8) else { throw DictionaryRecoveryError.unsupportedOrCorrupt }
        return Array(string)
    }
    private static func skipWhitespace(_ text: [Character], _ cursor: inout Int) {
        while cursor < text.count, text[cursor].isWhitespace { cursor += 1 }
    }
}

private extension Array where Element == Character {
    var firstNonWhitespace: Int { var index = 0; while index < count, self[index].isWhitespace { index += 1 }; return index }
    var countAfterWhitespace: Int { var index = count; while index > 0, self[index - 1].isWhitespace { index -= 1 }; return index }
}

enum DictionaryMalformedScanner {
    struct Result: Equatable {
        let entries: [PersonalDictionaryEntry]
        let rejectedCount: Int
        let hasUnknownRemainder: Bool
    }

    static func scan(_ data: Data, decoder: JSONDecoder) throws -> Result {
        guard data.count <= DictionaryRecoveryAnalysis.maximumMalformedBytes else {
            throw DictionaryRecoveryError.inputTooLarge
        }
        guard let bytes = String(data: data, encoding: .utf8).map(Array.init) else {
            throw DictionaryRecoveryError.ambiguousInput
        }
        guard let envelope = try locateEntriesArray(in: bytes) else {
            throw DictionaryRecoveryError.ambiguousInput
        }

        var recovered: [PersonalDictionaryEntry] = []
        var rejected = 0
        var acceptedIndexByID: [UUID: Int] = [:]
        var duplicateIDs = Set<UUID>()
        func result(unknown: Bool) -> Result {
            Result(entries: recovered.filter { !duplicateIDs.contains($0.id) }, rejectedCount: rejected, hasUnknownRemainder: unknown || envelope.incomplete)
        }
        var index = envelope.start
        var afterComma = false
        while index < bytes.count {
            skipWhitespace(bytes, &index)
            guard index < bytes.count else {
                return result(unknown: true)
            }
            if bytes[index] == "]" { return result(unknown: afterComma) }
            if bytes[index] != "{" {
                if !recovered.isEmpty || rejected > 0 { return result(unknown: true) }
                throw DictionaryRecoveryError.ambiguousInput
            }
            let start = index
            let end: Int
            do { end = try completeObjectEnd(in: bytes, from: start) }
            catch {
                if !recovered.isEmpty || rejected > 0 { return result(unknown: true) }
                throw error
            }
            let fragment = Data(String(bytes[start...end]).utf8)
            do {
                let entry = try StrictDictionaryCodec.decodeEntry(fragment, decoder: decoder)
                if duplicateIDs.contains(entry.id) {
                    rejected += 1
                } else if acceptedIndexByID.removeValue(forKey: entry.id) != nil {
                    duplicateIDs.insert(entry.id)
                    rejected += 2
                } else {
                    acceptedIndexByID[entry.id] = recovered.count
                    recovered.append(entry)
                }
            } catch {
                rejected += 1
            }
            index = bytes.index(after: end)
            skipWhitespace(bytes, &index)
            guard index < bytes.count else {
                return result(unknown: true)
            }
            if bytes[index] == "," { index += 1; afterComma = true }
            else if bytes[index] == "]" { return result(unknown: false) }
            else {
                if !recovered.isEmpty || rejected > 0 { return result(unknown: true) }
                throw DictionaryRecoveryError.ambiguousInput
            }
        }
        return result(unknown: true)
    }

    private static func locateEntriesArray(in bytes: [Character]) throws -> (start: Int, incomplete: Bool)? {
        var cursor = 0
        skipWhitespace(bytes, &cursor)
        guard cursor < bytes.count else { return nil }
        if bytes[cursor] == "[" { return (cursor + 1, false) }
        guard bytes[cursor] == "{" else { return nil }
        cursor += 1
        var seenKeys = Set<String>()
        var hasCurrentSchema = false
        var entriesStart: Int?
        while cursor < bytes.count {
            skipWhitespace(bytes, &cursor)
            guard cursor < bytes.count, bytes[cursor] == "\"" else { return nil }
            let keyStart = cursor
            let keyEnd = try completeStringEnd(in: bytes, from: keyStart)
            let keyData = Data(String(bytes[keyStart...keyEnd]).utf8)
            guard let key = try? JSONDecoder().decode(String.self, from: keyData),
                  key == "schemaVersion" || key == "entries",
                  seenKeys.insert(key).inserted else { return nil }
            cursor = keyEnd + 1
            skipWhitespace(bytes, &cursor)
            guard cursor < bytes.count, bytes[cursor] == ":" else { return nil }
            cursor += 1
            skipWhitespace(bytes, &cursor)
            if key == "schemaVersion" {
                let start = cursor
                while cursor < bytes.count, bytes[cursor].isNumber { cursor += 1 }
                hasCurrentSchema = String(bytes[start..<cursor]) == "1"
                guard hasCurrentSchema else { return nil }
            } else {
                guard cursor < bytes.count, bytes[cursor] == "[" else { return nil }
                entriesStart = cursor + 1
                do { cursor = try completeCompositeEnd(in: bytes, from: cursor) + 1 }
                catch {
                    // A known schema before a damaged entries array permits only its
                    // verified prefix. Never search past the ambiguous boundary.
                    return hasCurrentSchema ? (cursor + 1, true) : nil
                }
            }
            skipWhitespace(bytes, &cursor)
            guard cursor < bytes.count else {
                return hasCurrentSchema ? entriesStart.map { ($0, true) } : nil
            }
            if bytes[cursor] == "," { cursor += 1; continue }
            if bytes[cursor] == "}" {
                cursor += 1
                skipWhitespace(bytes, &cursor)
                guard cursor == bytes.count else { return nil }
                return hasCurrentSchema && seenKeys == ["schemaVersion", "entries"]
                    ? entriesStart.map { ($0, false) } : nil
            }
            return nil
        }
        return nil
    }

    private static func completeStringEnd(in bytes: [Character], from start: Int) throws -> Int {
        var cursor = start + 1, escaped = false
        while cursor < bytes.count {
            if escaped { escaped = false }
            else if bytes[cursor] == "\\" { escaped = true }
            else if bytes[cursor] == "\"" { return cursor }
            cursor += 1
        }
        throw DictionaryRecoveryError.ambiguousInput
    }

    private static func completeCompositeEnd(in bytes: [Character], from start: Int) throws -> Int {
        var stack: [Character] = [bytes[start] == "[" ? "]" : "}"]
        var cursor = start + 1, inString = false, escaped = false
        while cursor < bytes.count {
            let value = bytes[cursor]
            if inString {
                if escaped { escaped = false }
                else if value == "\\" { escaped = true }
                else if value == "\"" { inString = false }
            } else if value == "\"" { inString = true }
            else if value == "[" || value == "{" {
                stack.append(value == "[" ? "]" : "}")
                guard stack.count <= DictionaryRecoveryAnalysis.maximumNestingDepth else {
                    throw DictionaryRecoveryError.nestingTooDeep
                }
            }
            else if value == "]" || value == "}" {
                guard stack.last == value else { throw DictionaryRecoveryError.ambiguousInput }
                stack.removeLast()
                if stack.isEmpty { return cursor }
            }
            cursor += 1
        }
        throw DictionaryRecoveryError.ambiguousInput
    }

    private static func completeObjectEnd(in bytes: [Character], from start: Int) throws -> Int {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var index = start
        while index < bytes.count {
            let character = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                stack.append(character == "{" ? "}" : "]")
                guard stack.count <= DictionaryRecoveryAnalysis.maximumNestingDepth else {
                    throw DictionaryRecoveryError.nestingTooDeep
                }
            } else if character == "}" || character == "]" {
                guard stack.last == character else { throw DictionaryRecoveryError.ambiguousInput }
                stack.removeLast()
                if stack.isEmpty { return index }
            }
            index += 1
        }
        throw DictionaryRecoveryError.ambiguousInput
    }

    private static func skipWhitespace(_ bytes: [Character], _ index: inout Int) {
        while index < bytes.count, bytes[index].isWhitespace { index += 1 }
    }
}

extension Data {
    var dictionarySHA256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
