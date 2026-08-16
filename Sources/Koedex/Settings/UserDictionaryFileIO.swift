import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum UserDictionaryFileIO {
    enum FileIOError: LocalizedError, Equatable {
        case cancelled
        case fileTooLarge
        case readFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .cancelled: return "cancelled"
            case .fileTooLarge: return "file too large"
            case .readFailed: return "read failed"
            case .writeFailed: return "write failed"
            }
        }
    }

    static func export(
        entries: [PersonalDictionaryEntry],
        language: AppLanguage,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        save(
            data: UserDictionaryCSV.export(entries: entries, language: language),
            suggestedName: datedExportName(),
            completion: completion
        )
    }

    static func saveTemplate(
        language: AppLanguage,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        save(
            data: UserDictionaryCSV.template(language: language),
            suggestedName: "Koedex-user-dictionary-template.csv",
            completion: completion
        )
    }

    static func chooseImportFile(completion: @escaping (Result<URL, Error>) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]

        presentOpen(panel: panel) { response in
            guard response == .OK, let url = panel.url else {
                completion(.failure(FileIOError.cancelled))
                return
            }
            guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                completion(.failure(FileIOError.readFailed))
                return
            }
            guard fileSize <= UserDictionaryCSV.maximumFileBytes else {
                completion(.failure(FileIOError.fileTooLarge))
                return
            }
            completion(.success(url))
        }
    }

    private static func save(
        data: Data,
        suggestedName: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.nameFieldStringValue = suggestedName

        presentSave(panel: panel) { response in
            guard response == .OK, let url = panel.url else {
                completion(.failure(FileIOError.cancelled))
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                completion(.success(()))
            } catch {
                completion(.failure(FileIOError.writeFailed))
            }
        }
    }

    private static func presentOpen(panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = settingsWindow() {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func presentSave(panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = settingsWindow() {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible })
    }

    private static func datedExportName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return "Koedex-user-dictionary-\(formatter.string(from: Date())).csv"
    }
}
