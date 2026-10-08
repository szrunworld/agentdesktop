import AppKit
import Foundation
import Testing
@testable import SecondScreenCore

/// A private pasteboard per test; the user's clipboard is never touched.
func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("agentdesktop-test-\(UUID().uuidString)"))
}

/// What a pasteboard holds, item by item, as type → data.
func contents(_ pasteboard: NSPasteboard) -> [[String: Data]] {
    (pasteboard.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
            item.data(forType: type).map { (type.rawValue, $0) }
        })
    }
}

let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52])
let rtfBytes = Data("{\\rtf1\\ansi {\\b bold} text}".utf8)

@Suite struct PasteboardSnapshotTests {
    /// Fills `pasteboard` with several items of several types.
    func fill(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let rich = NSPasteboardItem()
        rich.setString("bold text", forType: .string)
        rich.setData(rtfBytes, forType: .rtf)
        rich.setString("<b>bold</b> text", forType: .html)
        let image = NSPasteboardItem()
        image.setData(pngBytes, forType: .png)
        image.setData(Data("custom".utf8), forType: NSPasteboard.PasteboardType("com.example.private"))
        let file = NSPasteboardItem()
        file.setString("file:///tmp/a%20b.txt", forType: .fileURL)
        #expect(pasteboard.writeObjects([rich, image, file]))
    }

    @Test func restoresEveryItemAndType() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        fill(pasteboard)
        let before = contents(pasteboard)
        #expect(before.count == 3)

        let loan = try PasteboardLoan.with("agent text", on: pasteboard) {
            pasteboard.string(forType: .string)
        }
        #expect(loan.value == "agent text")
        #expect(loan.restored)
        #expect(contents(pasteboard) == before)
        // Type order within each item survives too.
        #expect(pasteboard.pasteboardItems?[0].types.first == .string)
    }

    @Test func restoresAnImageWithNoString() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(pngBytes, forType: .png)
        _ = try PasteboardLoan.with("agent text", on: pasteboard) {}
        #expect(pasteboard.data(forType: .png) == pngBytes)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func restoresRichTextOnly() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(rtfBytes, forType: .rtf)
        _ = try PasteboardLoan.with("agent text", on: pasteboard) {}
        // The pasteboard also offers plain text derived from the RTF.
        let restored = contents(pasteboard)
        #expect(restored.count == 1)
        #expect(restored.first?[NSPasteboard.PasteboardType.rtf.rawValue] == rtfBytes)
    }

    @Test func restoresAnEmptyPasteboardAsEmpty() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let loan = try PasteboardLoan.with("agent text", on: pasteboard) {}
        #expect(loan.restored)
        #expect(contents(pasteboard).isEmpty)
    }

    @Test func leavesWhatTheUserCopiedMeanwhile() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        fill(pasteboard)
        let loan = try PasteboardLoan.with("agent text", on: pasteboard) {
            pasteboard.clearContents()
            pasteboard.setString("the user's new copy", forType: .string)
        }
        #expect(!loan.restored)
        #expect(pasteboard.string(forType: .string) == "the user's new copy")
        #expect(contents(pasteboard).count == 1)
    }

    @Test func restoresWhenTheBodyThrows() throws {
        struct Boom: Error {}
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        fill(pasteboard)
        let before = contents(pasteboard)
        #expect(throws: Boom.self) {
            try PasteboardLoan.with("agent text", on: pasteboard) { throw Boom() }
        }
        #expect(contents(pasteboard) == before)
    }

    @Test func refusesAFilePromiseWithoutTouchingThePasteboard() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("public.jpeg", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"))
        item.setString("photo.jpg", forType: .string)
        #expect(pasteboard.writeObjects([item]))
        let changeCount = pasteboard.changeCount
        let before = contents(pasteboard)

        var ran = false
        #expect(throws: PasteboardSnapshot.CaptureError.self) {
            try PasteboardLoan.with("agent text", on: pasteboard) { ran = true }
        }
        #expect(!ran)
        #expect(pasteboard.changeCount == changeCount)
        #expect(contents(pasteboard) == before)
    }

    @Test func refusesContentsOverTheLimit() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data(count: 2048), forType: .png)
        #expect(throws: PasteboardSnapshot.CaptureError.tooLarge(2048)) {
            try PasteboardSnapshot.capture(pasteboard, limit: 1024)
        }
    }

    @Test func restoreChecksTheChangeCount() throws {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        fill(pasteboard)
        let snapshot = try PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("x", forType: .string)
        #expect(!snapshot.restore(to: pasteboard, ifChangeCountIs: pasteboard.changeCount - 1))
        #expect(pasteboard.string(forType: .string) == "x")
        #expect(snapshot.restore(to: pasteboard, ifChangeCountIs: pasteboard.changeCount))
        #expect(contents(pasteboard).count == 3)
    }
}
