import Foundation

/// Koedexが自前で作成する永続データディレクトリ・ファイルの権限。
/// ディレクトリは0700、ファイルは0600に固定し、リテラルをここへ一元化する。
enum StoragePermissions {
    static let directoryPosixPermissions = 0o700
    static let filePosixPermissions = 0o600

    static var directoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: directoryPosixPermissions]
    }

    static var fileAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: filePosixPermissions]
    }

    /// 権限付与は保存の成否契約に含めない。chmodだけ失敗しても書き込みは成功しており、
    /// ここでthrowするとメモリとディスクが食い違い、保存不能扱いになる環境が出る。
    static func applyFileMode(to url: URL) {
        try? FileManager.default.setAttributes(fileAttributes, ofItemAtPath: url.path)
    }

    /// `withIntermediateDirectories: true` のattributesは中間ディレクトリに適用されない。
    /// ストレージルートが中間として0755で作られる退行を避けるため、作成後に必ず引き締める。
    /// 既存ディレクトリに対してもべき等に効く。
    static func ensureDirectory(at url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try? FileManager.default.setAttributes(directoryAttributes, ofItemAtPath: url.path)
    }

    /// 既存のKoedexストレージルート配下の権限を是正する（べき等）。
    /// 作用範囲は`root`配下に閉じる。root自体がsymlinkの場合、リンク先ツリー全体へ
    /// 波及するため何もしない。配下のsymlinkとハードリンクも対象から外す。
    /// 失敗しても起動を止めず、件数をまとめて1回だけ記録する。
    static func remediateStorageRoot(_ root: URL) {
        let fm = FileManager.default
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isSymbolicLink != true, rootValues?.isDirectory == true else { return }

        var failureCount = 0
        apply(directoryAttributes, toPath: root.path, failureCount: &failureCount)

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            AppLog.shared.warn("[StoragePermissions] 既存ストレージの列挙に失敗（権限是正をスキップ）")
            return
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // setAttributesはchmodと同じくsymlinkを辿るため、リンクを是正対象にすると
            // ストレージルート外の権限を書き換えうる。root配下だけという保証を守るため飛ばす。
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = values?.isDirectory == true
            // ハードリンクは同じinodeを共有するため、chmodがルート外へ波及する。
            // リンク数が1を超えるファイルは対象外にして、作用範囲をroot配下に閉じる。
            if !isDirectory, linkCount(ofPath: url.path) > 1 { continue }
            apply(
                isDirectory ? directoryAttributes : fileAttributes,
                toPath: url.path,
                failureCount: &failureCount
            )
        }

        if failureCount > 0 {
            AppLog.shared.warn("[StoragePermissions] 権限是正に失敗した項目があります: \(failureCount)件")
        }
    }

    private static func linkCount(ofPath path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.referenceCount] as? Int) ?? 1
    }

    private static func apply(
        _ attributes: [FileAttributeKey: Any],
        toPath path: String,
        failureCount: inout Int
    ) {
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
        } catch {
            failureCount += 1
        }
    }
}
