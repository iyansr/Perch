import AppKit

/// Types dictated text into the front app: the text goes on the pasteboard, `Paster` posts ⌘V, and the
/// user's clipboard comes back afterwards. Without Accessibility ⌘V cannot be posted, so the text stays on the
/// clipboard instead.
enum DictationInserter {
    enum Outcome: Equatable {
        case pasted
        /// No Accessibility: the text is on the clipboard for the user to paste.
        case copied
    }

    /// How long the pasted text stays on the pasteboard before the old content returns. The target reads
    /// the pasteboard when it handles ⌘V, which can be a moment after the key event.
    static let restoreDelay: TimeInterval = 0.6

    @discardableResult
    static func insert(_ text: String, paster: Paster = .shared, pasteboard: NSPasteboard = .general) -> Outcome {
        guard paster.canPaste else {
            write(text, to: pasteboard)
            return .copied
        }
        let saved = PasteboardSnapshot(pasteboard)
        let stamp = write(text, to: pasteboard)
        paster.postPaste(to: nil, direct: false, prepare: {}, completion: {
            Task {
                try? await Task.sleep(for: .seconds(restoreDelay))
                // Someone copied in the meantime: their copy wins.
                guard pasteboard.changeCount == stamp else { return }
                saved.restore(to: pasteboard)
            }
        })
        return .pasted
    }

    /// Replaces the pasteboard with `text`, stamped so `ClipboardMonitor` skips it. Returns the new change count.
    @discardableResult
    private static func write(_ text: String, to pasteboard: NSPasteboard) -> Int {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data("1".utf8), forType: .perchInternal)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }
}

/// Everything on a pasteboard, so it can be put back.
struct PasteboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Writes the snapshot back, stamped `.perchInternal`: the monitor already has these items.
    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.filter { !$0.isEmpty }.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            item.setData(Data("1".utf8), forType: .perchInternal)
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
