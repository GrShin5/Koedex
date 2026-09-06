import Foundation
import Darwin

@MainActor
enum StorageRegressionTests {
    struct Outcome { let passed: Bool; let name: String }

    static func run(storageRootURL: URL) -> [Outcome] {
        var results: [Outcome] = []
        func check(_ value: @autoclosure () -> Bool, _ name: String) { results.append(.init(passed: value(), name: name)) }
        func root(_ name: String) -> URL {
            let value = storageRootURL.appendingPathComponent("storage-\(name)", isDirectory: true)
            try? FileManager.default.removeItem(at: value)
            try? FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PersonalDictionaryEntry(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, preferredForm: "Alpha", spokenForms: ["A", "A", "alpha"], notes: "note", enabled: false, createdAt: date, updatedAt: date)
        let b = PersonalDictionaryEntry(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, preferredForm: "Beta", spokenForms: ["B"], notes: "escaped \\\" value", createdAt: date, updatedAt: date)
        func json(_ entry: PersonalDictionaryEntry) -> String { String(data: try! encoder.encode(entry), encoding: .utf8)! }
        func wrapped(_ values: [String]) -> Data { Data("{\"schemaVersion\":1,\"entries\":[\(values.joined(separator: ","))]}".utf8) }

        check((try? StrictDictionaryCodec.decode(wrapped([json(a), json(b)]), decoder: decoder)) == [a, b], "storage strict dictionary codec preserves all entry fields and spoken-form ordering")
        let duplicateEntryKey = json(a).replacingOccurrences(of: "\"notes\":", with: "\"notes\":\"shadow\",\"notes\":")
        check((try? StrictDictionaryCodec.decode(wrapped([duplicateEntryKey]), decoder: decoder)) == nil, "storage strict dictionary codec rejects duplicate entry keys")
        check((try? StrictDictionaryCodec.decode(Data("{\"schemaVersion\":1,\"schemaVersion\":1,\"entries\":[]}".utf8), decoder: decoder)) == nil, "storage strict dictionary codec rejects duplicate wrapper keys")
        let unknown = json(a).dropLast() + ",\"future\":1}"
        check((try? StrictDictionaryCodec.decode(wrapped([String(unknown)]), decoder: decoder)) == nil, "storage strict dictionary codec rejects unknown entry keys")
        check((try? StrictDictionaryCodec.decode(Data("{\"schemaVersion\":2,\"entries\":[]}".utf8), decoder: decoder)) == nil, "storage strict dictionary codec rejects unsupported schema")
        let emptyPreferred = json(a).replacingOccurrences(of: "\"preferredForm\":\"Alpha\"", with: "\"preferredForm\":\"   \"")
        check((try? StrictDictionaryCodec.decode(wrapped([emptyPreferred]), decoder: decoder)) == nil, "storage strict dictionary codec rejects empty preferred forms")

        let invalid = json(a).replacingOccurrences(of: "\"enabled\":false", with: "\"enabled\":\"false\"")
        let mixed = try? DictionaryMalformedScanner.scan(wrapped([json(a), invalid, json(b)]), decoder: decoder)
        check(mixed?.entries == [a, b] && mixed?.rejectedCount == 1 && mixed?.hasUnknownRemainder == false, "storage scanner rescues valid-invalid-valid complete boundaries")
        let legacy = try? DictionaryMalformedScanner.scan(Data("[\(json(a)),\(json(b))]".utf8), decoder: decoder)
        check(legacy?.entries == [a, b], "storage scanner supports legacy top-level arrays")
        let duplicates = try? DictionaryMalformedScanner.scan(wrapped([json(a), json(a), json(b)]), decoder: decoder)
        check(duplicates?.entries == [b] && duplicates?.rejectedCount == 2, "storage scanner excludes every member of a duplicate UUID group")
        let truncated = try? DictionaryMalformedScanner.scan(Data("[\(json(a)),{\"id\":\"unterminated".utf8), decoder: decoder)
        check(truncated?.entries == [a] && truncated?.hasUnknownRemainder == true, "storage scanner keeps verified prefix entries before a truncated remainder")
        let truncatedWrapper = try? DictionaryMalformedScanner.scan(Data("{\"schemaVersion\":1,\"entries\":[\(json(a)),{\"notes\":\"unfinished".utf8), decoder: decoder)
        check(truncatedWrapper?.entries == [a] && truncatedWrapper?.hasUnknownRemainder == true, "storage scanner rescues a known-schema wrapper prefix before truncation")
        let mismatched = try? DictionaryMalformedScanner.scan(Data("[\(json(a)),{\"spokenForms\":[},\(json(b))]".utf8), decoder: decoder)
        check(mismatched?.entries == [a] && mismatched?.hasUnknownRemainder == true, "storage scanner stops at mismatched brackets without resynchronizing")
        let badComma = try? DictionaryMalformedScanner.scan(Data("[\(json(a)),,\(json(b))]".utf8), decoder: decoder)
        check(badComma?.entries == [a] && badComma?.hasUnknownRemainder == true, "storage scanner stops at an invalid delimiter")
        let trailingComma = try? DictionaryMalformedScanner.scan(Data("[\(json(a)),]".utf8), decoder: decoder)
        check(trailingComma?.entries == [a] && trailingComma?.hasUnknownRemainder == true, "storage scanner marks a trailing comma as an uncertain remainder")
        let tooDeep = try? DictionaryMalformedScanner.scan(Data(("[" + json(a) + ",{\"nested\":" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}]").utf8), decoder: decoder)
        check(tooDeep?.entries == [a] && tooDeep?.hasUnknownRemainder == true, "storage scanner stops at depth limit while preserving the verified prefix")
        check((try? DictionaryMalformedScanner.scan(Data("{\"schemaVersion\":1,\"comment\":\"\\\"entries\\\":[{}]\"}".utf8), decoder: decoder)) == nil, "storage scanner ignores entries text inside unknown root strings")
        check((try? DictionaryMalformedScanner.scan(Data("{\"schemaVersion\":1,\"entries\":[],\"future\":true}".utf8), decoder: decoder)) == nil, "storage scanner rejects unknown wrapper keys after entries")
        var largeRejected = false
        do { _ = try DictionaryMalformedScanner.scan(Data(repeating: 0x20, count: DictionaryRecoveryAnalysis.maximumMalformedBytes + 1), decoder: decoder) }
        catch DictionaryRecoveryError.inputTooLarge { largeRejected = true }
        catch {}
        check(largeRejected, "storage scanner caps malformed input at 8 MiB")

        let partialRoot = root("partial")
        let main = partialRoot.appendingPathComponent("personal_dictionary.json")
        let corrupt = wrapped([json(a), invalid, json(b)])
        try? corrupt.write(to: main)
        let partialStore = PersonalDictionaryStore(storageRootURL: partialRoot)
        let analysis: DictionaryRecoveryAnalysis? = { if case .recoveryRequired(let value) = partialStore.loadStatus { return value }; return nil }()
        if let fingerprint = analysis?.fingerprint { try? partialStore.recoverRescuedEntries(expectedFingerprint: fingerprint) }
        let raw = partialRoot.appendingPathComponent("Recovery/original-\(corrupt.dictionarySHA256).json")
        let mode = ((try? FileManager.default.attributesOfItem(atPath: raw.path)[.posixPermissions]) as? NSNumber)?.intValue
        check(partialStore.entries == [a, b] && (try? Data(contentsOf: raw)) == corrupt && mode.map { $0 & 0o777 } == 0o600, "storage partial recovery preserves verified raw bytes before publishing rescued entries")

        let backupRoot = root("backup-bytes")
        let backupSeed = PersonalDictionaryStore(storageRootURL: backupRoot)
        _ = backupSeed.add(preferredForm: "Seed", spokenForms: ["seed"], notes: "kept")
        let lkgURL = backupRoot.appendingPathComponent("personal_dictionary.last-known-good.json")
        let lkgEntries = backupSeed.entries
        let exactBackup = Data("{ \"schemaVersion\" : 1, \"entries\" : [ \(json(lkgEntries[0])) ] }\n".utf8)
        try? exactBackup.write(to: lkgURL)
        let backupMain = backupRoot.appendingPathComponent("personal_dictionary.json"); try? corrupt.write(to: backupMain)
        let backupStore = PersonalDictionaryStore(storageRootURL: backupRoot)
        if case .recoveryRequired(let value) = backupStore.loadStatus,
           let fingerprint = value.fingerprint,
           let candidate = value.candidates.first(where: { $0.kind == .lastKnownGood }) {
            try? backupStore.recoverFromBackup(candidate, expectedFingerprint: fingerprint)
        }
        check((try? Data(contentsOf: backupMain)) == exactBackup && backupStore.entries == lkgEntries, "storage recovery restores verified backup bytes without re-encoding")

        let staleRoot = root("stale")
        let staleMain = staleRoot.appendingPathComponent("personal_dictionary.json")
        try? corrupt.write(to: staleMain)
        let staleStore = PersonalDictionaryStore(storageRootURL: staleRoot)
        let staleFingerprint: DictionaryFileFingerprint? = { if case .recoveryRequired(let value) = staleStore.loadStatus { return value.fingerprint }; return nil }()
        let changed = Data("{\"changed\":true}".utf8); try? changed.write(to: staleMain)
        var staleRejected = false
        if let staleFingerprint { do { try staleStore.recoverRescuedEntries(expectedFingerprint: staleFingerprint) } catch DictionaryRecoveryError.staleInput { staleRejected = true } catch {} }
        check(staleRejected && (try? Data(contentsOf: staleMain)) == changed && staleStore.requiresRecovery, "storage recovery rejects stale confirmation without overwriting changed input")

        let symlinkRoot = root("symlink")
        let outside = root("outside").appendingPathComponent("outside.json"); try? corrupt.write(to: outside)
        try? FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("personal_dictionary.json"), withDestinationURL: outside)
        let symlinkStore = PersonalDictionaryStore(storageRootURL: symlinkRoot)
        check(symlinkStore.add(preferredForm: "Blocked", spokenForms: [], notes: "") == .failed(.recoveryRequired) && (try? Data(contentsOf: outside)) == corrupt, "storage dictionary refuses symlink main files and blocks mutations")

        let recoveryLinkRoot = root("recovery-link")
        let recoveryLinkMain = recoveryLinkRoot.appendingPathComponent("personal_dictionary.json"); try? corrupt.write(to: recoveryLinkMain)
        let outsideDirectory = root("recovery-outside")
        try? FileManager.default.createSymbolicLink(at: recoveryLinkRoot.appendingPathComponent("Recovery"), withDestinationURL: outsideDirectory)
        let recoveryLinkStore = PersonalDictionaryStore(storageRootURL: recoveryLinkRoot)
        let linkFingerprint: DictionaryFileFingerprint? = { if case .recoveryRequired(let value) = recoveryLinkStore.loadStatus { return value.fingerprint }; return nil }()
        var linkRejected = false
        if let linkFingerprint { do { try recoveryLinkStore.recoverRescuedEntries(expectedFingerprint: linkFingerprint) } catch DictionaryRecoveryError.unsafeFile { linkRejected = true } catch {} }
        check(linkRejected && (try? FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path).isEmpty) == true, "storage recovery rejects a symlink Recovery directory")

        func recoveryFailure(
            _ name: String,
            mutate: (DictionaryRecoveryFileIO, URL) -> DictionaryRecoveryFileIO
        ) -> (threw: Bool, mainPreserved: Bool, rawExists: Bool) {
            let failureRoot = root(name)
            let failureMain = failureRoot.appendingPathComponent("personal_dictionary.json")
            try? corrupt.write(to: failureMain)
            let io = mutate(.live, failureRoot)
            let store = PersonalDictionaryStore(storageRootURL: failureRoot, recoveryFileIO: io)
            guard case .recoveryRequired(let value) = store.loadStatus, let fingerprint = value.fingerprint else { return (false, false, false) }
            var threw = false
            do { try store.recoverRescuedEntries(expectedFingerprint: fingerprint) } catch { threw = true }
            let rawURL = failureRoot.appendingPathComponent("Recovery/original-\(corrupt.dictionarySHA256).json")
            return (threw, (try? Data(contentsOf: failureMain)) == corrupt, FileManager.default.fileExists(atPath: rawURL.path))
        }
        let rawWriteFailure = recoveryFailure("raw-write-failure") { base, _ in
            DictionaryRecoveryFileIO(read: base.read, atomicWrite: base.atomicWrite, createExclusive: { _, _ in throw CocoaError(.fileWriteUnknown) }, attributes: base.attributes, setAttributes: base.setAttributes, createDirectory: base.createDirectory)
        }
        check(rawWriteFailure.threw && rawWriteFailure.mainPreserved && !rawWriteFailure.rawExists, "storage recovery raw-backup write failure preserves the original main file")
        let retryRoot = root("partial-backup-retry")
        let retryMain = retryRoot.appendingPathComponent("personal_dictionary.json")
        try? corrupt.write(to: retryMain)
        var partialIO = DictionaryRecoveryFileIO.live
        partialIO.createExclusive = { data, url in
            try DictionaryRawBackupWriter.create(data, at: url) { descriptor, bytes in
                _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, bytes.count / 2) }
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let interruptedStore = PersonalDictionaryStore(storageRootURL: retryRoot, recoveryFileIO: partialIO)
        if case .recoveryRequired(let value) = interruptedStore.loadStatus, let fingerprint = value.fingerprint {
            try? interruptedStore.recoverRescuedEntries(expectedFingerprint: fingerprint)
        }
        let retryRaw = retryRoot.appendingPathComponent("Recovery/original-\(corrupt.dictionarySHA256).json")
        let failedSafely = (try? Data(contentsOf: retryMain)) == corrupt && !FileManager.default.fileExists(atPath: retryRaw.path)
        let retryStore = PersonalDictionaryStore(storageRootURL: retryRoot)
        if case .recoveryRequired(let value) = retryStore.loadStatus, let fingerprint = value.fingerprint {
            try? retryStore.recoverRescuedEntries(expectedFingerprint: fingerprint)
        }
        check(failedSafely && retryStore.entries == [a, b] && (try? Data(contentsOf: retryRaw)) == corrupt, "storage raw backup partial write can retry without a poisoned final filename")

        let zeroRoot = root("empty-restart")
        let zeroMain = zeroRoot.appendingPathComponent("personal_dictionary.json")
        let zeroBytes = Data("{broken original".utf8)
        try? zeroBytes.write(to: zeroMain)
        let zeroStore = PersonalDictionaryStore(storageRootURL: zeroRoot)
        var confirmationRequired = false
        if case .recoveryRequired(let value) = zeroStore.loadStatus, let fingerprint = value.fingerprint {
            do { try zeroStore.restartEmpty(expectedFingerprint: fingerprint, preservationConfirmed: false) }
            catch DictionaryRecoveryError.preservationConfirmationRequired { confirmationRequired = (try? Data(contentsOf: zeroMain)) == zeroBytes }
            catch {}
            try? zeroStore.restartEmpty(expectedFingerprint: fingerprint, preservationConfirmed: true)
        }
        check(confirmationRequired && !zeroStore.requiresRecovery && zeroStore.entries.isEmpty && (try? Data(contentsOf: zeroRoot.appendingPathComponent("Recovery/original-\(zeroBytes.dictionarySHA256).json"))) == zeroBytes, "storage empty restart requires confirmation and a complete raw backup")
        let encoderOrderedPrefix = Data("{\"entries\":[\(json(a)),{\"id\":\"unterminated".utf8)
        check((try? DictionaryMalformedScanner.scan(encoderOrderedPrefix, decoder: decoder)) == nil, "storage entries-first truncation without schema refuses unverified-format rescue")
        let rawPermissionFailure = recoveryFailure("raw-permission-failure") { base, _ in
            DictionaryRecoveryFileIO(read: base.read, atomicWrite: base.atomicWrite, createExclusive: base.createExclusive, attributes: base.attributes, setAttributes: { _, _ in throw CocoaError(.fileWriteNoPermission) }, createDirectory: base.createDirectory)
        }
        check(rawPermissionFailure.threw && rawPermissionFailure.mainPreserved && rawPermissionFailure.rawExists, "storage recovery raw-backup permission failure preserves main and keeps the raw bytes")
        let rawHashFailure = recoveryFailure("raw-hash-failure") { base, _ in
            DictionaryRecoveryFileIO(read: { url in
                let data = try base.read(url)
                return url.deletingLastPathComponent().lastPathComponent == "Recovery" ? Data("mismatch".utf8) : data
            }, atomicWrite: base.atomicWrite, createExclusive: base.createExclusive, attributes: base.attributes, setAttributes: base.setAttributes, createDirectory: base.createDirectory)
        }
        check(rawHashFailure.threw && rawHashFailure.mainPreserved && rawHashFailure.rawExists, "storage recovery raw-backup hash mismatch preserves main and keeps the raw file")
        var didWriteMain = false
        let mainReadbackFailure = recoveryFailure("main-readback-failure") { base, failureRoot in
            DictionaryRecoveryFileIO(read: { url in
                if didWriteMain && url == failureRoot.appendingPathComponent("personal_dictionary.json") { throw CocoaError(.fileReadUnknown) }
                return try base.read(url)
            }, atomicWrite: { data, url in try base.atomicWrite(data, url); if url == failureRoot.appendingPathComponent("personal_dictionary.json") { didWriteMain = true } }, createExclusive: base.createExclusive, attributes: base.attributes, setAttributes: base.setAttributes, createDirectory: base.createDirectory)
        }
        check(mainReadbackFailure.threw && mainReadbackFailure.rawExists, "storage recovery main readback failure reports failure only after preserving raw input")

        let dateStoreRoot = root("date")
        let dateStore = PersonalDictionaryStore(storageRootURL: dateStoreRoot)
        let dateResult = dateStore.add(preferredForm: "Date", spokenForms: ["date"], notes: "fractional")
        let dateReload = PersonalDictionaryStore(storageRootURL: dateStoreRoot)
        check(dateResult.succeeded && dateStore.entries == dateReload.entries && dateStore.entries.count == 1, "storage CRUD publishes persisted date values and survives restart")

        let writeFailureStore = PersonalDictionaryStore(storageRootURL: root("write-failure"), atomicDataWriter: { _, _ in throw CocoaError(.fileWriteUnknown) })
        let writeFailure = writeFailureStore.add(preferredForm: "Nope", spokenForms: [], notes: "")
        check(writeFailure == .failed(.writeFailed) && writeFailureStore.entries.isEmpty, "storage dictionary write failure leaves memory unchanged")
        let warningStore = PersonalDictionaryStore(storageRootURL: root("lkg-warning"), atomicDataWriter: { data, url in
            if url.lastPathComponent.contains("last-known-good") { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        })
        check(warningStore.add(preferredForm: "Saved", spokenForms: [], notes: "") == .savedWithBackupWarning && warningStore.entries.count == 1, "storage dictionary LKG-only failure reports warning after primary success")
        let backupRetryRoot = root("backup-only-retry")
        var rejectBackup = true
        var mainWrites = 0
        let backupRetryStore = PersonalDictionaryStore(storageRootURL: backupRetryRoot, atomicDataWriter: { data, url in
            if url.lastPathComponent.contains("last-known-good"), rejectBackup { throw CocoaError(.fileWriteUnknown) }
            if url.lastPathComponent == "personal_dictionary.json" { mainWrites += 1 }
            try data.write(to: url, options: .atomic)
        })
        _ = backupRetryStore.add(preferredForm: "Saved", spokenForms: [], notes: "")
        let hadRetryNotice = backupRetryStore.backupNeedsRetry
        let beforeRetryEntries = backupRetryStore.entries
        rejectBackup = false
        check(backupRetryStore.retryLastKnownGoodBackup() == .saved && hadRetryNotice && !backupRetryStore.backupNeedsRetry && backupRetryStore.entries == beforeRetryEntries && mainWrites == 1, "storage backup retry updates only the backup without repeating the primary mutation")

        let blockedRoot = root("all-mutations-blocked")
        let blockedMain = blockedRoot.appendingPathComponent("personal_dictionary.json")
        try? corrupt.write(to: blockedMain)
        var blockedWrites = 0
        let blockedStore = PersonalDictionaryStore(storageRootURL: blockedRoot, atomicDataWriter: { _, _ in blockedWrites += 1 })
        let blockedResults = [
            blockedStore.add(preferredForm: "Blocked", spokenForms: [], notes: ""),
            blockedStore.update(id: a.id, preferredForm: "Blocked", spokenForms: [], notes: "", enabled: true),
            blockedStore.setEnabled(id: a.id, enabled: true),
            blockedStore.delete(id: a.id),
            blockedStore.delete(ids: [a.id, b.id]),
            blockedStore.retryLastKnownGoodBackup(),
        ]
        var importBlocked = false
        let emptyDraft = UserDictionaryImportDraft(existingEntriesSnapshot: [], additions: [], singleExistingConflicts: [], multipleExistingManualReview: [], withinFileDuplicates: [], issues: [], resolutions: [:])
        do { _ = try blockedStore.applyImport(emptyDraft) }
        catch PersonalDictionaryStore.ImportError.recoveryRequired { importBlocked = true }
        catch {}
        check(blockedResults.allSatisfy { $0 == .failed(.recoveryRequired) } && importBlocked && blockedWrites == 0 && (try? Data(contentsOf: blockedMain)) == corrupt, "storage every dictionary mutator and import refuse while recovery is required")

        var unreadableIO = DictionaryRecoveryFileIO.live
        unreadableIO.read = { _ in throw CocoaError(.fileReadNoPermission) }
        let unreadableStore = PersonalDictionaryStore(storageRootURL: blockedRoot, recoveryFileIO: unreadableIO)
        var unreadableResetBlocked = false
        do { try unreadableStore.restartEmpty(expectedFingerprint: .init(byteCount: corrupt.count, sha256: corrupt.dictionarySHA256), preservationConfirmed: true) }
        catch DictionaryRecoveryError.unreadable { unreadableResetBlocked = true }
        catch {}
        check(unreadableResetBlocked && (try? Data(contentsOf: blockedMain)) == corrupt, "storage an unreadable original cannot be replaced even after empty-restart confirmation")

        let linkedRoot = root("hardlinked-raw")
        let linkedMain = linkedRoot.appendingPathComponent("personal_dictionary.json")
        let linkedDirectory = linkedRoot.appendingPathComponent("Recovery")
        try? FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        try? corrupt.write(to: linkedMain)
        let sharedRaw = root("shared-raw").appendingPathComponent("shared.json")
        try? corrupt.write(to: sharedRaw)
        try? FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sharedRaw.path)
        try? FileManager.default.linkItem(at: sharedRaw, to: linkedDirectory.appendingPathComponent("original-\(corrupt.dictionarySHA256).json"))
        let linkedStore = PersonalDictionaryStore(storageRootURL: linkedRoot)
        var sharedRejected = false
        if case .recoveryRequired(let value) = linkedStore.loadStatus, let fingerprint = value.fingerprint {
            do { try linkedStore.recoverRescuedEntries(expectedFingerprint: fingerprint) }
            catch DictionaryRecoveryError.unsafeFile { sharedRejected = true }
            catch {}
        }
        let sharedMode = ((try? FileManager.default.attributesOfItem(atPath: sharedRaw.path)[.posixPermissions]) as? NSNumber)?.intValue
        check(sharedRejected && sharedMode.map { $0 & 0o777 } == 0o640 && (try? Data(contentsOf: linkedMain)) == corrupt, "storage reused raw backups cannot change permissions on a shared hardlinked inode")

        let malformedHistoryRoot = root("history-malformed")
        let historyDirectory = malformedHistoryRoot.appendingPathComponent("history", isDirectory: true); try? FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let oldHistory = InputHistoryEntry.aiCommandTranscript("kept", createdAt: date)
        let goodLine = try! encoder.encode(oldHistory) + Data([0x0A]); let malformedBytes = goodLine + Data("{bad row}\n".utf8)
        let historyURL = historyDirectory.appendingPathComponent("input_history.jsonl"); try? malformedBytes.write(to: historyURL)
        let malformedStore = InputHistoryStore(storageRootURL: malformedHistoryRoot)
        let blockedDelete = malformedStore.delete(id: oldHistory.id)
        let newHistory = InputHistoryEntry.aiCommandTranscript("new", createdAt: date.addingTimeInterval(1))
        let malformedAppend = malformedStore.append(newHistory, retentionDays: 1)
        check(blockedDelete == .blockedByMalformedHistory && malformedAppend == .savedWithCleanupWarning && (try? Data(contentsOf: historyURL))?.starts(with: malformedBytes) == true && malformedStore.entries.contains(where: { $0.id == oldHistory.id }), "storage history preserves malformed rows, blocks rewrites, appends complete lines, and reports cleanup warning")

        var fakeBytes = Data()
        let appendFailureIO = InputHistoryFileIO(read: { _ in fakeBytes }, append: { _, _ in throw CocoaError(.fileWriteUnknown) }, atomicWrite: { data, _ in fakeBytes = data }, remove: { _ in fakeBytes = Data() })
        let appendFailureStore = InputHistoryStore(storageRootURL: root("history-append-failure"), fileIO: appendFailureIO)
        check(appendFailureStore.append(newHistory, retentionDays: 1) == .failed && appendFailureStore.entries.isEmpty && fakeBytes.isEmpty, "storage history append failure does not publish memory or prune")

        var rewriteBytes = goodLine
        let rewriteFailureIO = InputHistoryFileIO(read: { _ in rewriteBytes }, append: { data, _ in rewriteBytes.append(data) }, atomicWrite: { _, _ in throw CocoaError(.fileWriteUnknown) }, remove: { _ in throw CocoaError(.fileWriteUnknown) })
        let rewriteStore = InputHistoryStore(storageRootURL: root("history-rewrite-failure"), fileIO: rewriteFailureIO)
        let beforeRewrite = rewriteStore.entries
        let rewriteResult = rewriteStore.delete(id: oldHistory.id); let removeResult = rewriteStore.deleteAll()
        check(rewriteResult == .failed && removeResult == .failed && rewriteStore.entries == beforeRewrite && rewriteBytes == goodLine, "storage history rewrite and remove failures preserve memory and persisted bytes")
        return results
    }
}
