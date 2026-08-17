import Foundation

/// アプリ同梱のプロンプトを、製品版とSwiftPM開発時の両方で同じ規則で読み込む。
///
/// `Package.swift` は `Resources/prompts` をディレクトリごとコピーするため、
/// 製品版では `Contents/Resources/Koedex_Koedex.bundle/prompts/` 配下を最初に探索する。
/// 開発時だけ、SwiftPMのリソースバンドルが利用できない実行形態を補うために
/// ソースツリーを最後のフォールバックとして使う。
enum PromptResourceLoader {
    static func load(named name: String) throws -> String {
        var lastReadError: Error?

        for url in candidateURLs(for: name) {
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                AppLog.shared.warn("[PromptResourceLoader] resource read failed: \(AppLog.safeDescription(error))")
                lastReadError = error
            }
        }

        if let lastReadError {
            throw PromptResourceLoaderError.unreadable(name: name, underlying: lastReadError)
        }
        throw PromptResourceLoaderError.missing(name: name)
    }

    private static func candidateURLs(for name: String) -> [URL] {
        var urls: [URL] = []

        // 手製の.appではSwiftPM bundleがContents/Resourcesに配置される。
        // Bundle.moduleは.app直下しか見ないため、製品版ではここから直接解決する。
        if let resourcesURL = Bundle.main.resourceURL,
           let productBundle = Bundle(path: resourcesURL
                .appendingPathComponent("Koedex_Koedex.bundle", isDirectory: true).path) {
            appendCandidates(named: name, from: productBundle, to: &urls)
        }

        // SwiftPMのresource_bundle_accessorは、手製.appでは存在しない.app直下のbundleを探して
        // fatalErrorになり得る。製品版では呼ばず、開発時にだけ利用する。
        if Bundle.main.bundleURL.pathExtension != "app" {
            appendCandidates(named: name, from: Bundle.module, to: &urls)

            // SwiftPMのリソースバンドルを経由しないローカル開発実行時だけの最終フォールバック。
            let sourcePromptDirectory = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Support
                .deletingLastPathComponent() // Koedex
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("prompts", isDirectory: true)
            let sourceURL = sourcePromptDirectory.appendingPathComponent("\(name).md")
            if FileManager.default.fileExists(atPath: sourceURL.path), !urls.contains(sourceURL) {
                urls.append(sourceURL)
            }
        }

        return urls
    }

    private static func appendCandidates(named name: String, from bundle: Bundle, to urls: inout [URL]) {
        if let prompt = bundle.url(forResource: name, withExtension: "md", subdirectory: "prompts"),
           !urls.contains(prompt) {
            urls.append(prompt)
        }
        if let prompt = bundle.url(forResource: name, withExtension: "md"), !urls.contains(prompt) {
            urls.append(prompt)
        }
    }
}

enum PromptResourceLoaderError: Error, LocalizedError {
    case missing(name: String)
    case unreadable(name: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "プロンプトリソースが見つかりません: \(name)"
        case .unreadable(let name, _):
            return "プロンプトリソースを読み込めません: \(name)"
        }
    }
}
