import AppKit
import Foundation

/// Every item on a pasteboard with every type it offers, as data, so text an
/// agent pastes can borrow the pasteboard and give back exactly what the
/// user had: rich text, images, file URLs and several items, not only the
/// plain string.
///
/// Some contents cannot be copied without loss: a file promise (the file is
/// only written when someone pastes it), or a type whose data the owner will
/// not hand over. `capture` refuses those, and a caller must then leave the
/// pasteboard alone rather than clear what it cannot put back.
public struct PasteboardSnapshot: Equatable {
    public struct Item: Equatable {
        /// The item's types in the order the owner offered them, with their data.
        public var entries: [Entry]
        public init(_ entries: [Entry]) { self.entries = entries }
    }

    public struct Entry: Equatable {
        public var type: NSPasteboard.PasteboardType
        public var data: Data
        public init(_ type: NSPasteboard.PasteboardType, _ data: Data) {
            self.type = type
            self.data = data
        }
    }

    public enum CaptureError: LocalizedError, Equatable {
        /// The contents include something that cannot be copied as data.
        case lossy(String)
        /// Larger than `capture`'s limit.
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .lossy(let why):
                return "the clipboard holds \(why), which cannot be saved and put back; "
                    + "nothing was pasted and the clipboard is untouched"
            case .tooLarge(let bytes):
                return "the clipboard holds \(bytes / 1_048_576) MB, too much to save and put back; "
                    + "nothing was pasted and the clipboard is untouched"
            }
        }
    }

    public var items: [Item]
    /// The pasteboard's change count when it was read.
    public var changeCount: Int

    public init(items: [Item], changeCount: Int = 0) {
        self.items = items
        self.changeCount = changeCount
    }

    /// Types that stand for data written only on demand; copying their bytes
    /// keeps a promise nobody will fulfil.
    static let promiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-name",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.NSFilePromiseItemMetaData",
        "NSPromiseContentsPboardType",
        "Apple files promise pasteboard type",
        "CorePasteboardFlavorType 0x70686673",  // 'phfs', HFS promise
    ]

    public static let defaultLimit = 64 * 1_048_576

    /// Everything on `pasteboard`, or why it cannot be copied without loss.
    public static func capture(_ pasteboard: NSPasteboard, limit: Int = defaultLimit) throws -> PasteboardSnapshot {
        let changeCount = pasteboard.changeCount
        var items: [Item] = []
        var total = 0
        for item in pasteboard.pasteboardItems ?? [] {
            var entries: [Entry] = []
            for type in item.types {
                if promiseTypes.contains(type.rawValue) || type.rawValue.lowercased().contains("promise") {
                    throw CaptureError.lossy("a file promise (\(type.rawValue))")
                }
                guard let data = item.data(forType: type) else {
                    throw CaptureError.lossy("data of type \(type.rawValue) its owner did not hand over")
                }
                total += data.count
                if total > limit { throw CaptureError.tooLarge(total) }
                entries.append(Entry(type, data))
            }
            items.append(Item(entries))
        }
        // Read again: the owner may have replaced the contents while we read.
        guard pasteboard.changeCount == changeCount else {
            throw CaptureError.lossy("contents that changed while they were read")
        }
        return PasteboardSnapshot(items: items, changeCount: changeCount)
    }

    /// Put the snapshot back, only if `pasteboard` still holds what we wrote
    /// (its change count is `ours`): something copied since is the user's
    /// and stays. Returns whether it was put back.
    @discardableResult
    public func restore(to pasteboard: NSPasteboard, ifChangeCountIs ours: Int) -> Bool {
        guard pasteboard.changeCount == ours else { return false }
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let objects = items.map { item -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for entry in item.entries { object.setData(entry.data, forType: entry.type) }
            return object
        }
        return pasteboard.writeObjects(objects)
    }
}

/// Borrows a pasteboard to hold `text` for the length of `body`, then gives
/// the user's contents back. Callers hold a `ClipboardLease` around it so
/// no other process writes the pasteboard meanwhile.
public enum PasteboardLoan {
    public struct Result<Value> {
        public var value: Value
        /// Whether the user's contents were put back; false when the user
        /// copied something meanwhile, which is then left in place.
        public var restored: Bool
    }

    /// Fails before touching the pasteboard when its contents cannot be
    /// saved without loss.
    public static func with<Value>(_ text: String, on pasteboard: NSPasteboard,
                                   _ body: () throws -> Value) throws -> Result<Value> {
        let snapshot = try PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ours = pasteboard.changeCount
        var finished = false
        // Also when `body` throws.
        defer { if !finished { snapshot.restore(to: pasteboard, ifChangeCountIs: ours) } }
        let value = try body()
        finished = true
        let restored = snapshot.restore(to: pasteboard, ifChangeCountIs: ours)
        return Result(value: value, restored: restored)
    }
}
