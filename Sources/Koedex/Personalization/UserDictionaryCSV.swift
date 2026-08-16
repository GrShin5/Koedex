import Foundation

/// UIやローカライザに依存しない、ユーザー辞書CSVのcodec。
enum UserDictionaryCSV {
    static let maximumFileBytes = 8 * 1024 * 1024
    static let maximumDataRows = 1_000
    static let maximumHeaderColumns = 64
    static let maximumWordLength = 100
    static let maximumReadingLength = 100
    static let maximumReadings = 20
    static let maximumNotesLength = 500

    enum LogicalHeader: CaseIterable {
        case word
        case readings
        case notes
        case enabled

        func title(for language: AppLanguage) -> String {
            switch (self, language) {
            case (.word, .japanese): return "単語"
            case (.readings, .japanese): return "読み方"
            case (.notes, .japanese): return "補足メモ"
            case (.enabled, .japanese): return "有効"
            case (.word, .english): return "word"
            case (.readings, .english): return "readings"
            case (.notes, .english): return "notes"
            case (.enabled, .english): return "enabled"
            }
        }

        static func recognize(_ value: String) -> Self? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "単語": return .word
            case "読み方", "読み": return .readings
            case "補足メモ", "メモ": return .notes
            case "有効", "有効（TRUE/FALSE）": return .enabled
            default:
                switch trimmed.lowercased() {
                case "word": return .word
                case "readings", "reading": return .readings
                case "notes", "note": return .notes
                case "enabled", "enable", "enabled (true/false)": return .enabled
                default: return nil
                }
            }
        }

        func templateTitle(for language: AppLanguage) -> String {
            switch (self, language) {
            case (.enabled, .japanese): return "有効（TRUE/FALSE）"
            case (.enabled, .english): return "enabled (TRUE/FALSE)"
            default: return title(for: language)
            }
        }
    }

    struct Row: Equatable {
        let physicalLine: Int
        let preferredForm: String
        let spokenForms: [String]
        let notes: String
        let enabled: Bool
    }

    struct RowIssue: Equatable {
        enum Reason: Equatable {
            case tooManyColumns
            case emptyWord
            case invalidEnabled
            case wordTooLong
            case tooManyReadings
            case readingTooLong
            case notesTooLong
        }

        let physicalLine: Int
        let reason: Reason
    }

    struct ParseResult: Equatable {
        let rows: [Row]
        let issues: [RowIssue]
    }

    enum FileError: Error, Equatable {
        case fileTooLarge
        case unsupportedEncoding
        case malformedCSV(physicalLine: Int)
        case missingHeader
        case missingWordHeader
        case duplicateRecognizedHeader(LogicalHeader)
        case tooManyHeaderColumns
        case tooManyDataRows
    }

    static func template(language: AppLanguage) -> Data {
        exportRecords([LogicalHeader.allCases.map { $0.templateTitle(for: language) }])
    }

    static func export(entries: [PersonalDictionaryEntry], language: AppLanguage) -> Data {
        let header = LogicalHeader.allCases.map { $0.title(for: language) }
        let records = entries.map { entry in
            [
                hardened(entry.preferredForm),
                hardened(entry.spokenForms.joined(separator: ",")),
                hardened(entry.notes),
                entry.enabled ? "TRUE" : "FALSE",
            ]
        }
        return exportRecords([header] + records)
    }

    static func parse(data: Data) throws -> ParseResult {
        guard data.count <= maximumFileBytes else { throw FileError.fileTooLarge }
        let source = try decode(data)
        let records = try parseRecords(
            source,
            maximumRecords: maximumDataRows + 1,
            maximumStoredFields: maximumHeaderColumns
        )
        guard let headerRecord = records.first else { throw FileError.missingHeader }
        guard !headerRecord.hasExcessColumns else { throw FileError.tooManyHeaderColumns }

        var mapping: [LogicalHeader: Int] = [:]
        for (index, rawHeader) in headerRecord.fields.enumerated() {
            let header = unhardened(rawHeader)
            guard let logical = LogicalHeader.recognize(header) else { continue }
            guard mapping[logical] == nil else { throw FileError.duplicateRecognizedHeader(logical) }
            mapping[logical] = index
        }
        guard mapping[.word] != nil else { throw FileError.missingWordHeader }

        let dataRecords = records.dropFirst()
        var rows: [Row] = []
        var issues: [RowIssue] = []
        for record in dataRecords {
            if record.hasExcessColumns || record.fields.count > headerRecord.fields.count {
                issues.append(RowIssue(physicalLine: record.physicalLine, reason: .tooManyColumns))
                continue
            }
            var fields = record.fields
            fields += Array(repeating: "", count: headerRecord.fields.count - fields.count)
            let value: (LogicalHeader) -> String = { logical in
                guard let index = mapping[logical] else { return "" }
                return unhardened(fields[index])
            }
            let word = value(.word).trimmingCharacters(in: .whitespacesAndNewlines)
            let readings = value(.readings)
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let notes = value(.notes).trimmingCharacters(in: .whitespacesAndNewlines)
            let enabledText = value(.enabled).trimmingCharacters(in: .whitespacesAndNewlines)
            let enabled = parseEnabled(enabledText)

            let issue: RowIssue.Reason?
            if word.isEmpty { issue = .emptyWord }
            else if enabled == nil { issue = .invalidEnabled }
            else if word.count > maximumWordLength { issue = .wordTooLong }
            else if readings.count > maximumReadings { issue = .tooManyReadings }
            else if readings.contains(where: { $0.count > maximumReadingLength }) { issue = .readingTooLong }
            else if notes.count > maximumNotesLength { issue = .notesTooLong }
            else { issue = nil }
            if let issue {
                issues.append(RowIssue(physicalLine: record.physicalLine, reason: issue))
            } else {
                rows.append(Row(
                    physicalLine: record.physicalLine,
                    preferredForm: word,
                    spokenForms: readings,
                    notes: notes,
                    enabled: enabled!
                ))
            }
        }
        return ParseResult(rows: rows, issues: issues)
    }

    private static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(bytes: bytes.dropFirst(3), encoding: .utf8) else { throw FileError.unsupportedEncoding }
            return text
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            guard let text = String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) else { throw FileError.unsupportedEncoding }
            return text
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            guard let text = String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) else { throw FileError.unsupportedEncoding }
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .shiftJIS) { return text }
        throw FileError.unsupportedEncoding
    }

    private struct Record {
        let physicalLine: Int
        let fields: [String]
        let hasExcessColumns: Bool
    }

    private static func parseRecords(
        _ source: String,
        maximumRecords: Int,
        maximumStoredFields: Int
    ) throws -> [Record] {
        var records: [Record] = []
        var fields: [String] = []
        var field = ""
        var discardingField = false
        var hasExcessColumns = false
        var hasUnquotedFieldContent = false
        var line = 1
        var recordLine = 1
        var inQuotes = false
        var afterQuote = false
        var hasRecordContent = false
        let scalars = Array(source.unicodeScalars)
        var index = 0

        func finishField() {
            if fields.count < maximumStoredFields {
                fields.append(field)
            } else {
                hasExcessColumns = true
            }
            field = ""
            discardingField = fields.count >= maximumStoredFields
            hasUnquotedFieldContent = false
            afterQuote = false
        }
        func finishRecord() throws {
            finishField()
            if hasRecordContent {
                if records.isEmpty, hasExcessColumns { throw FileError.tooManyHeaderColumns }
                guard records.count < maximumRecords else { throw FileError.tooManyDataRows }
                records.append(Record(
                    physicalLine: recordLine,
                    fields: fields,
                    hasExcessColumns: hasExcessColumns
                ))
            }
            fields = []
            discardingField = false
            hasExcessColumns = false
            hasUnquotedFieldContent = false
            hasRecordContent = false
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value
            if inQuotes {
                if value == 0x22 {
                    if index + 1 < scalars.count, scalars[index + 1].value == 0x22 {
                        if !discardingField { field.append("\"") }
                        index += 2
                        continue
                    }
                    inQuotes = false
                    afterQuote = true
                } else {
                    if !discardingField { field.unicodeScalars.append(scalar) }
                    if value == 0x0A { line += 1 }
                    if value == 0x0D {
                        line += 1
                        if index + 1 < scalars.count, scalars[index + 1].value == 0x0A {
                            if !discardingField { field.unicodeScalars.append(scalars[index + 1]) }
                            index += 1
                        }
                    }
                }
                index += 1
                continue
            }

            if afterQuote, value != 0x2C, value != 0x0D, value != 0x0A {
                throw FileError.malformedCSV(physicalLine: line)
            }
            switch value {
            case 0x22:
                guard field.isEmpty && !hasUnquotedFieldContent && !afterQuote else {
                    throw FileError.malformedCSV(physicalLine: line)
                }
                inQuotes = true
                hasRecordContent = true
            case 0x2C:
                finishField()
                hasRecordContent = true
            case 0x0D, 0x0A:
                try finishRecord()
                if value == 0x0D, index + 1 < scalars.count, scalars[index + 1].value == 0x0A { index += 1 }
                line += 1
                recordLine = line
            default:
                if !discardingField { field.unicodeScalars.append(scalar) }
                hasUnquotedFieldContent = true
                hasRecordContent = true
            }
            index += 1
        }
        if inQuotes { throw FileError.malformedCSV(physicalLine: recordLine) }
        if hasRecordContent || !field.isEmpty || !fields.isEmpty { try finishRecord() }
        return records
    }

    private static func parseEnabled(_ value: String) -> Bool? {
        if value.isEmpty { return true }
        switch value.lowercased() {
        case "true", "1", "yes", "はい", "有効", "on", "○": return true
        case "false", "0", "no", "いいえ", "無効", "off", "×": return false
        default: return nil
        }
    }

    private static func hardened(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first == "'" || "=+-@\t\r\n".contains(first) ? "'" + value : value
    }

    private static func unhardened(_ value: String) -> String {
        guard value.first == "'", value.count >= 2 else { return value }
        let following = value.dropFirst().first!
        return following == "'" || "=+-@\t\r\n".contains(following) ? String(value.dropFirst()) : value
    }

    private static func exportRecords(_ records: [[String]]) -> Data {
        let body = records.map { record in
            record.map { field in
                if field.contains(",") || field.contains("\"") || field.contains("\r") || field.contains("\n") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
    }
}
