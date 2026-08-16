import AppKit

/// Preserves every item and type on a pasteboard. Restoration is deliberately
/// conditional so a concurrent user copy is never overwritten.
struct PasteboardSnapshot {
    private struct Entry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private let items: [[Entry]]
    private let capturedChangeCount: Int?
    let isComplete: Bool

    init(_ pasteboard: NSPasteboard) {
        let beforeCapture = pasteboard.changeCount
        let sourceItems: [NSPasteboardItem]
        if let pasteboardItems = pasteboard.pasteboardItems {
            guard !pasteboardItems.isEmpty || (pasteboard.types?.isEmpty ?? true) else {
                items = []
                capturedChangeCount = nil
                isComplete = false
                return
            }
            sourceItems = pasteboardItems
        } else if pasteboard.types?.isEmpty ?? true {
            // NSPasteboard may report either nil or [] for an empty board.
            // Treat both as a complete, restorable empty snapshot.
            sourceItems = []
        } else {
            items = []
            capturedChangeCount = nil
            isComplete = false
            return
        }

        var capturedItems: [[Entry]] = []
        var capturedEveryType = true
        for item in sourceItems {
            var capturedItem: [Entry] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    capturedEveryType = false
                    break
                }
                capturedItem.append(Entry(type: type, data: data))
            }
            guard capturedEveryType else { break }
            capturedItems.append(capturedItem)
        }
        let afterCapture = pasteboard.changeCount
        items = capturedItems
        let capturedStableState = beforeCapture == afterCapture
        capturedChangeCount = capturedEveryType && capturedStableState ? afterCapture : nil
        isComplete = capturedEveryType && capturedStableState
    }

    func stillRepresentsCurrentContents(of pasteboard: NSPasteboard) -> Bool {
        guard isComplete, let capturedChangeCount else { return false }
        return pasteboard.changeCount == capturedChangeCount
    }

    @discardableResult
    func restore(to pasteboard: NSPasteboard, ifChangeCountIs expected: Int) -> Bool {
        guard isComplete else { return false }

        // Build every item before the final ownership check. There is no retry
        // or rollback after clear/write: NSPasteboard has no atomic compare and
        // exchange, so another attempt could overwrite a concurrent user copy.
        var restored: [NSPasteboardItem] = []
        for values in items {
            let item = NSPasteboardItem()
            for entry in values {
                guard item.setData(entry.data, forType: entry.type) else { return false }
            }
            restored.append(item)
        }
        guard pasteboard.changeCount == expected else { return false }
        pasteboard.clearContents()
        guard items.isEmpty || pasteboard.writeObjects(restored) else { return false }
        return matchesSnapshot(pasteboard)
    }

    private func matchesSnapshot(_ pasteboard: NSPasteboard) -> Bool {
        let currentItems = pasteboard.pasteboardItems ?? []
        guard currentItems.count == items.count else { return false }

        for (current, expected) in zip(currentItems, items) {
            let expectedTypes = Set(expected.map(\.type))
            guard Set(current.types) == expectedTypes else { return false }
            for entry in expected {
                guard current.data(forType: entry.type) == entry.data else { return false }
            }
        }
        return true
    }
}
