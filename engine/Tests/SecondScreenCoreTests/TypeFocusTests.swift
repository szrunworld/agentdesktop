import CoreGraphics
import Foundation
@testable import SecondScreenCore
import Testing

// #163, Kevin 2026-10-09: typed text goes one character at a time; before
// each one the focused window is read again, and typing stops as soon as it
// is not the bound window or cannot be read.
@Suite struct TypeFocusTests {
    final class Recorder { var posted = 0; var reads = 0 }

    @Test func everyCharacterIsSentWhileFocusStaysInTheWindow() throws {
        let r = Recorder()
        try BackgroundInput.typeCharacters("abc", pid: 7, windowID: 11,
                                           focusedWindow: { _ in r.reads += 1; return 11 },
                                           post: { _, _ in r.posted += 1 }, pause: 0)
        #expect(r.reads == 3, "read again before each character")
        #expect(r.posted == 6, "a key down and up per character")
    }

    @Test func focusMovingAwayMidwayStopsTheRestAndCountsWhatWentOut() {
        let r = Recorder()
        // A character opened a window that took focus after the second one.
        do {
            try BackgroundInput.typeCharacters("abcdef", pid: 7, windowID: 11,
                                               focusedWindow: { _ in r.reads += 1; return r.reads <= 2 ? 11 : 99 },
                                               post: { _, _ in r.posted += 1 }, pause: 0)
            Issue.record("typing went on after focus left")
        } catch {
            let m = "\(error)"
            #expect(m.contains("after 2 of 6 characters"), "\(m)")
            #expect(!m.contains("nothing was typed"))
        }
        #expect(r.posted == 4, "only the two characters before the move")
    }

    @Test(arguments: [Optional<CGWindowID>.none, 99])
    func focusElsewhereOrUnreadableBeforeTheFirstCharacterTypesNothing(_ focus: CGWindowID?) {
        let r = Recorder()
        do {
            try BackgroundInput.typeCharacters("abc", pid: 7, windowID: 11, focusedWindow: { _ in focus },
                                               post: { _, _ in r.posted += 1 }, pause: 0)
            Issue.record("typed without focus in the window")
        } catch {
            #expect("\(error)".contains("nothing was typed"))
        }
        #expect(r.posted == 0)
    }

    @Test func anUnreadableFocusMidwayStops() {
        let r = Recorder()
        do {
            try BackgroundInput.typeCharacters("abc", pid: 7, windowID: 11,
                                               focusedWindow: { _ in r.reads += 1; return r.reads == 1 ? 11 : nil },
                                               post: { _, _ in r.posted += 1 }, pause: 0)
            Issue.record("typing went on with focus unknown")
        } catch {
            #expect("\(error)".contains("after 1 of 3"))
        }
        #expect(r.posted == 2)
    }
}
