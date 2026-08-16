import AppKit

enum PasteboardCleanupOutcome: Equatable {
    case restored
    case ownerLost
    case restoreFailed
}

enum PasteboardPasteTransactionOutcome: Equatable {
    case completed(PasteboardCleanupOutcome)
    case cancelled(PasteboardCleanupOutcome)
    case dispatchFailed(PasteboardCleanupOutcome)
}

/// Cmd-Vを送出した後、出力をクリップボードに保持する経路の結果。
/// Web/Electronは貼り付け完了をAXで確認できないため、この段階ではsnapshotを復元しない。
enum PasteboardPasteDispatchOutcome: Equatable {
    case dispatched
    case cancelled(PasteboardCleanupOutcome)
    case dispatchFailed(PasteboardCleanupOutcome)
}

enum PasteboardPasteTransactionInstallation {
    case installed(PasteboardPasteTransaction)
    case snapshotIncomplete
    /// `true` means clearContents() already ran and the caller must warn that
    /// the previous clipboard may have been lost rather than auto-copying.
    case writeFailed(mayHaveLostClipboard: Bool)
}

/// `NSPasteboard` exposes neither a writer identity nor an atomic
/// compare-and-swap. Exact change-count plus a private marker is therefore the
/// narrowest ownership check available before restoring the user's clipboard.
enum TemporaryPasteboardOwnership {
    static func isOwned(
        installedChangeCount: Int,
        currentChangeCount: Int,
        currentOwnerMarker: String?,
        expectedOwnerMarker: String
    ) -> Bool {
        currentChangeCount == installedChangeCount
            && currentOwnerMarker == expectedOwnerMarker
    }
}

enum ExternalPasteDwellPolicy {
    /// A short, fixed window gives the foreground app time to consume Cmd-V
    /// without turning the clipboard into an open-ended data provider.
    static let nanoseconds: UInt64 = 150_000_000
}

/// A single static-data Cmd-V attempt. Unlike a pasteboard data provider, this
/// transaction never treats a reader as proof that a paste occurred: clipboard
/// managers can read values speculatively. It restores only while the exact
/// pasteboard state it installed still belongs to Koedex.
@MainActor
final class PasteboardPasteTransaction {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// クリップボード読み取り側（`ClipboardSourceReadPolicy`）が自己再帰を弾くために
    /// 同じ文字列を必要とする。二重定義にすると片方だけ変わって黙って壊れるため、
    /// ここを唯一の出どころにする。
    nonisolated static let ownerTypeRawValue = "com.koedex.text-injector.owner"
    private static let ownerType = NSPasteboard.PasteboardType(ownerTypeRawValue)

    private let pasteboard: NSPasteboard
    private let snapshot: PasteboardSnapshot
    private let ownerMarker: String
    private let installedChangeCount: Int
    private var didCleanUp = false

    private init(
        pasteboard: NSPasteboard,
        snapshot: PasteboardSnapshot,
        ownerMarker: String,
        installedChangeCount: Int
    ) {
        self.pasteboard = pasteboard
        self.snapshot = snapshot
        self.ownerMarker = ownerMarker
        self.installedChangeCount = installedChangeCount
    }

    static func install(
        text: String,
        on pasteboard: NSPasteboard = .general
    ) -> PasteboardPasteTransactionInstallation {
        let snapshot = PasteboardSnapshot(pasteboard)
        guard snapshot.isComplete else { return .snapshotIncomplete }

        let ownerMarker = UUID().uuidString
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString("", forType: transientType),
              item.setString(ownerMarker, forType: ownerType) else {
            return .writeFailed(mayHaveLostClipboard: false)
        }

        guard snapshot.stillRepresentsCurrentContents(of: pasteboard) else {
            return .snapshotIncomplete
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            // Do not retry or roll back after mutation. NSPasteboard has no
            // atomic compare-and-swap and a retry could overwrite a concurrent
            // user copy. The caller keeps the output visible with a warning.
            return .writeFailed(mayHaveLostClipboard: true)
        }

        let installedChangeCount = pasteboard.changeCount
        guard TemporaryPasteboardOwnership.isOwned(
            installedChangeCount: installedChangeCount,
            currentChangeCount: pasteboard.changeCount,
            currentOwnerMarker: pasteboard.string(forType: ownerType),
            expectedOwnerMarker: ownerMarker
        ) else {
            return .writeFailed(mayHaveLostClipboard: true)
        }

        return .installed(PasteboardPasteTransaction(
            pasteboard: pasteboard,
            snapshot: snapshot,
            ownerMarker: ownerMarker,
            installedChangeCount: installedChangeCount
        ))
    }

    func dispatch(postCommandV: () -> Bool) async -> PasteboardPasteTransactionOutcome {
        switch await dispatchKeepingClipboard(postCommandV: postCommandV) {
        case .dispatched:
            return .completed(cleanUp())
        case .cancelled(let cleanup):
            return .cancelled(cleanup)
        case .dispatchFailed(let cleanup):
            return .dispatchFailed(cleanup)
        }
    }

    /// Cmd-V後の短いdwellまでは従来どおり待つが、成功時には旧クリップボードを
    /// 自動復元しない。呼び出し元はAXで反映を確認できた時だけ`restoreIfOwned()`を
    /// 呼び、未確認のWeb/Electronでは明示操作までtransactionを保持する。
    func dispatchKeepingClipboard(postCommandV: () -> Bool) async -> PasteboardPasteDispatchOutcome {
        guard postCommandV() else {
            return .dispatchFailed(cleanUp())
        }
        do {
            try await Task.sleep(nanoseconds: ExternalPasteDwellPolicy.nanoseconds)
        } catch {
            return .cancelled(cleanUp())
        }
        if Task.isCancelled {
            return .cancelled(cleanUp())
        }
        return .dispatched
    }

    /// Used by cancellation paths and isolated regression checks. Cleanup is
    /// still single-shot and subject to the same exact ownership condition.
    func cancel() -> PasteboardCleanupOutcome {
        cleanUp()
    }

    /// 所有マーカーとchange countが一致する場合だけ、開始前のsnapshotへ戻す。
    /// その間に利用者や他アプリがコピーしていれば`.ownerLost`となり、現在の内容を
    /// 上書きしない。
    func restoreIfOwned() -> PasteboardCleanupOutcome {
        cleanUp()
    }

    /// 復元せずに現在の所有権だけを確認する。未確認貼り付け後に利用者が別の内容を
    /// コピーしていれば、擬似Returnを送ってはいけないために使う。
    func stillOwnsPasteboard() -> Bool {
        guard !didCleanUp else { return false }
        return TemporaryPasteboardOwnership.isOwned(
            installedChangeCount: installedChangeCount,
            currentChangeCount: pasteboard.changeCount,
            currentOwnerMarker: pasteboard.string(forType: Self.ownerType),
            expectedOwnerMarker: ownerMarker
        )
    }

    private func cleanUp() -> PasteboardCleanupOutcome {
        guard !didCleanUp else { return .ownerLost }
        didCleanUp = true

        let currentChangeCount = pasteboard.changeCount
        guard TemporaryPasteboardOwnership.isOwned(
            installedChangeCount: installedChangeCount,
            currentChangeCount: currentChangeCount,
            currentOwnerMarker: pasteboard.string(forType: Self.ownerType),
            expectedOwnerMarker: ownerMarker
        ) else {
            return .ownerLost
        }
        return snapshot.restore(to: pasteboard, ifChangeCountIs: currentChangeCount)
            ? .restored
            : .restoreFailed
    }
}
