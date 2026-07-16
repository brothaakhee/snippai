import AppKit

/// A full snapshot of a pasteboard's items, restorable after a transient use
/// (selection-grab via synthetic ⌘C, desktop-app paste injection). The user's
/// clipboard must always come back exactly as it was.
public struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    public static func take(from pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { dict[type] = data } }
            return dict
        })
    }

    public func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let restored = items.compactMap { dict -> NSPasteboardItem? in
            guard !dict.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
