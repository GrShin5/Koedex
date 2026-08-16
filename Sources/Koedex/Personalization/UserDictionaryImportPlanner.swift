import Foundation

enum UserDictionaryImportConflictAction: Equatable {
    case keepExisting
    case replace(existingID: UUID)
    case appendDuplicate
}

struct UserDictionaryImportConflict: Equatable {
    let row: UserDictionaryCSV.Row
    let existingEntry: PersonalDictionaryEntry
}

struct UserDictionaryImportDraft: Equatable {
    let existingEntriesSnapshot: [PersonalDictionaryEntry]
    let additions: [UserDictionaryCSV.Row]
    let singleExistingConflicts: [UserDictionaryImportConflict]
    let multipleExistingManualReview: [UserDictionaryCSV.Row]
    let withinFileDuplicates: [UserDictionaryCSV.Row]
    let issues: [UserDictionaryCSV.RowIssue]
    var resolutions: [Int: UserDictionaryImportConflictAction]

    func action(for conflictIndex: Int) -> UserDictionaryImportConflictAction {
        resolutions[conflictIndex] ?? .keepExisting
    }

    mutating func setAction(_ action: UserDictionaryImportConflictAction, for conflictIndex: Int) {
        guard singleExistingConflicts.indices.contains(conflictIndex) else { return }
        resolutions[conflictIndex] = action
    }
}

enum UserDictionaryImportPlanner {
    static func makeDraft(
        parseResult: UserDictionaryCSV.ParseResult,
        existingEntries: [PersonalDictionaryEntry]
    ) -> UserDictionaryImportDraft {
        let duplicateKeys = Set(
            Dictionary(grouping: parseResult.rows, by: key(for:))
                .filter { $0.value.count > 1 }
                .keys
        )
        let fileDuplicates = parseResult.rows.filter { duplicateKeys.contains(key(for: $0)) }
        let candidates = parseResult.rows.filter { !duplicateKeys.contains(key(for: $0)) }
        let existingByKey = Dictionary(grouping: existingEntries, by: key(for:))

        var additions: [UserDictionaryCSV.Row] = []
        var single: [UserDictionaryImportConflict] = []
        var multiple: [UserDictionaryCSV.Row] = []
        for row in candidates {
            switch existingByKey[key(for: row), default: []] {
            case []:
                additions.append(row)
            case let matches where matches.count == 1:
                single.append(UserDictionaryImportConflict(row: row, existingEntry: matches[0]))
            default:
                multiple.append(row)
            }
        }
        return UserDictionaryImportDraft(
            existingEntriesSnapshot: existingEntries,
            additions: additions,
            singleExistingConflicts: single,
            multipleExistingManualReview: multiple,
            withinFileDuplicates: fileDuplicates,
            issues: parseResult.issues,
            resolutions: [:]
        )
    }

    static func key(for value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func key(for row: UserDictionaryCSV.Row) -> String {
        key(for: row.preferredForm)
    }

    private static func key(for entry: PersonalDictionaryEntry) -> String {
        key(for: entry.preferredForm)
    }
}
