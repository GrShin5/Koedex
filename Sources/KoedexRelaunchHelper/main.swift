import Darwin
import Foundation

/// メインアプリに依存しない一回限りの再起動helper。
/// 常駐化・Login Item・強制終了は使わず、旧PIDが消えた時だけ一度起動する。
private struct RestartIntent: Codable {
    enum Route: String, Codable { case firstRun, upgrade, permissionRecovery, debugPreview, debugRehearsal }
    enum HandoffStatus: String, Codable { case pending, helperLaunched, helperFailed }
    enum HandoffFailure: String, Codable { case helperUnavailable, helperValidationFailed, sourceExitTimedOut, successorLaunchFailed }

    let route: Route
    let step: String
    let bundleIdentifier: String
    let sourceProcessIdentifier: Int32?
    let generation: UUID?
    let createdAt: Date?
    let expiresAt: Date?
    var handoffStatus: HandoffStatus?
    var handoffFailure: HandoffFailure?
}

private struct Arguments {
    let bundleIdentifier: String
    let sourcePID: Int32
    let generation: UUID
    let createdAt: TimeInterval
    let expiresAt: TimeInterval
    let intentURL: URL

    static func parse(_ values: [String]) -> Arguments? {
        guard values.count == 13 else { return nil }
        var pairs: [String: String] = [:]
        for index in stride(from: 1, to: values.count, by: 2) {
            pairs[values[index]] = values[index + 1]
        }
        guard let bundleIdentifier = pairs["--bundle-id"],
              let sourcePIDText = pairs["--source-pid"], let sourcePID = Int32(sourcePIDText), sourcePID > 0,
              let generationText = pairs["--generation"], let generation = UUID(uuidString: generationText),
              let createdAtText = pairs["--created-at"], let createdAt = TimeInterval(createdAtText),
              let expiresAtText = pairs["--expires-at"], let expiresAt = TimeInterval(expiresAtText), expiresAt > createdAt,
              let intentPath = pairs["--intent-path"], intentPath.hasPrefix("/") else { return nil }
        return Arguments(
            bundleIdentifier: bundleIdentifier,
            sourcePID: sourcePID,
            generation: generation,
            createdAt: createdAt,
            expiresAt: expiresAt,
            intentURL: URL(fileURLWithPath: intentPath)
        )
    }
}

private enum RelaunchHelper {
    static let allowedBundleIdentifiers: Set<String> = ["com.koedex.app", "com.koedex.onboarding-debug"]

    static func run() {
        guard let arguments = Arguments.parse(CommandLine.arguments),
              let bundleURL = bundleURLFromOwnLocation(),
              allowedBundleIdentifiers.contains(arguments.bundleIdentifier),
              Bundle(url: bundleURL)?.bundleIdentifier == arguments.bundleIdentifier,
              standardized(arguments.intentURL) == expectedIntentURL(for: arguments.bundleIdentifier) else {
            return
        }

        guard let data = try? Data(contentsOf: arguments.intentURL),
              var intent = try? JSONDecoder().decode(RestartIntent.self, from: data),
              intent.bundleIdentifier == arguments.bundleIdentifier,
              intent.sourceProcessIdentifier == arguments.sourcePID,
              intent.generation == arguments.generation,
              datesMatch(intent.createdAt, arguments.createdAt),
              datesMatch(intent.expiresAt, arguments.expiresAt),
              let expiresAt = intent.expiresAt,
              Date() < expiresAt else {
            markFailure(at: arguments.intentURL, failure: .helperValidationFailed)
            return
        }

        while processIsAlive(arguments.sourcePID) {
            if Date() >= expiresAt {
                markFailure(at: arguments.intentURL, failure: .sourceExitTimedOut)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // 後継がintentを読み終えて削除した後にhelperが再作成する競合を避けるため、
        // handoff状態は起動要求より先に確定する。起動失敗時だけfailedへ上書きする。
        intent.handoffStatus = .helperLaunched
        intent.handoffFailure = nil
        guard save(intent, at: arguments.intentURL) else { return }

        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-n", bundleURL.path]
        do {
            try openProcess.run()
            openProcess.waitUntilExit()
        } catch {
            markFailure(at: arguments.intentURL, failure: .successorLaunchFailed)
            return
        }
        guard openProcess.terminationStatus == 0 else {
            markFailure(at: arguments.intentURL, failure: .successorLaunchFailed)
            return
        }
    }

    private static func bundleURLFromOwnLocation() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().standardizedFileURL
        guard executable.lastPathComponent == "KoedexRelaunchHelper",
              executable.deletingLastPathComponent().lastPathComponent == "Helpers" else { return nil }
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", bundle.pathExtension == "app" else { return nil }
        return bundle
    }

    private static func expectedIntentURL(for bundleIdentifier: String) -> URL {
        let name = bundleIdentifier == "com.koedex.onboarding-debug" ? "Koedex Debug" : "Koedex"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return standardized(
            appSupport.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("onboarding_restart_intent.json")
        )
    }

    private static func standardized(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    private static func datesMatch(_ date: Date?, _ value: TimeInterval) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSince1970 - value) < 0.001
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func markFailure(at url: URL, failure: RestartIntent.HandoffFailure) {
        guard let data = try? Data(contentsOf: url), var intent = try? JSONDecoder().decode(RestartIntent.self, from: data) else { return }
        intent.handoffStatus = .helperFailed
        intent.handoffFailure = failure
        _ = save(intent, at: url)
    }

    @discardableResult
    private static func save(_ intent: RestartIntent, at url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(intent) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            _ = chmod(url.path, S_IRUSR | S_IWUSR)
            return true
        } catch {
            return false
        }
    }
}

RelaunchHelper.run()
