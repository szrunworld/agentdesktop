import ApplicationServices
import Foundation
@testable import SecondScreenCore
import Testing

// #173 (Kevin 2026-10-09): what an input did is recorded by its execution
// path, never read from an error's text. not performed → submitted →
// unknown, one way only; a composite input that submitted anything is
// never not performed, whatever fails after.
@Suite struct DeliveryRecorderTests {
    @Test func itOnlyMovesOneWay() {
        let r = DeliveryRecorder()
        #expect(r.state == .notPerformed)
        r.note(.submitted); #expect(r.state == .submitted)
        r.note(.notPerformed); #expect(r.state == .submitted, "never back to not performed")
        r.note(.unknown); #expect(r.state == .unknown)
        r.note(.submitted); #expect(r.state == .unknown)
    }

    @Test func aPressRecordsWhatItProved() {
        for (result, expected) in [(AXError.success, DeliveryState.submitted), (.cannotComplete, .unknown),
                                   (.invalidUIElement, .unknown), (.actionUnsupported, .notPerformed)] {
            let r = DeliveryRecorder()
            _ = DeliveryRecorder.$active.withValue(r) { AXActions.pressOnce(validate: { .success }, perform: { result }) }
            #expect(r.state == expected, "\(result.rawValue)")
        }
        // Checked gone before the press: nothing was asked.
        let r = DeliveryRecorder()
        _ = DeliveryRecorder.$active.withValue(r) { AXActions.pressOnce(validate: { .invalidUIElement }, perform: { .success }) }
        #expect(r.state == .notPerformed)
    }

    @Test func aWriteRecordsWhatItProved() {
        #expect(AXActions.writeOutcome(.success) == .pressed)
        #expect(AXActions.writeOutcome(.attributeUnsupported) == .notPerformed)
        #expect(AXActions.writeOutcome(.cannotComplete) == .unknown)
        #expect(AXActions.writeOutcome(.failure) == .unknown)
    }

    // "Click, then type": the click was submitted, the next step then fails
    // before submitting anything. The whole input is submitted. (The typing
    // loop's own cases come with #163's per-character check.)
    @Test func aCompositeInputThatSubmittedAnythingIsNeverNotPerformed() {
        struct Stop: Error {}
        let r = DeliveryRecorder()
        DeliveryRecorder.$active.withValue(r) {
            do {
                _ = try InputEngine.pressThenClick(press: { .notPerformed }, what: "field",
                                                   click: { DeliveryRecorder.submitting(); return "event.click" })
                throw Stop()
            } catch {}
        }
        #expect(r.state == .submitted)
    }

    @Test func nothingSubmittedStaysNotPerformed() {
        let r = DeliveryRecorder()
        DeliveryRecorder.$active.withValue(r) {
            _ = try? InputEngine.pressThenClick(press: { .unknown }, what: "x", click: { "event.click" })
        }
        #expect(r.state == .unknown, "an unclear press is unknown, not submitted and not not performed")
        let untouched = DeliveryRecorder()
        #expect(untouched.state == .notPerformed)
    }

    // b9 on merging #163: the typing loop (#163) stopped before its first
    // character leaves the recorder at not performed; after some characters
    // it is submitted. Posting goes through a function that notes it, as
    // SkyLight.postKey does.
    @Test func typingStoppedBeforeItsFirstCharacterIsNotPerformedAfterSomeIsSubmitted() {
        let none = DeliveryRecorder()
        DeliveryRecorder.$active.withValue(none) {
            _ = try? BackgroundInput.typeCharacters("abc", pid: 7, windowID: 11, focusedWindow: { _ in 99 },
                                                    post: { _, _ in DeliveryRecorder.submitting() }, pause: 0)
        }
        #expect(none.state == .notPerformed, "no character was submitted")
        let some = DeliveryRecorder()
        final class Reads { var n = 0 }
        let reads = Reads()
        DeliveryRecorder.$active.withValue(some) {
            _ = try? BackgroundInput.typeCharacters("abc", pid: 7, windowID: 11,
                                                    focusedWindow: { _ in reads.n += 1; return reads.n == 1 ? 11 : nil },
                                                    post: { _, _ in DeliveryRecorder.submitting() }, pause: 0)
        }
        #expect(some.state == .submitted, "one character went out before focus could not be read")
    }

    // A click into a web field went out, then the typing stops before its
    // first character: the input as a whole is submitted.
    @Test func aClickThenATypingStoppedAtOnceIsSubmitted() {
        let r = DeliveryRecorder()
        DeliveryRecorder.$active.withValue(r) {
            DeliveryRecorder.submitting()   // the click (BackgroundInput.click posts through SkyLight)
            _ = try? BackgroundInput.typeCharacters("abc", pid: 7, windowID: 11, focusedWindow: { _ in 99 },
                                                    post: { _, _ in DeliveryRecorder.submitting() }, pause: 0)
        }
        #expect(r.state == .submitted)
    }

    // Codex on 811833a: a focus or front change that stops at its own checks
    // (no such window or process) asked nothing of the system: the recorder
    // stays not performed. A window and a pid that do not exist make the
    // lookups (read only) fail before any call that changes anything.
    @Test func aFocusOrFrontChangeStoppedByItsChecksIsNotPerformed() {
        let missingWindow: CGWindowID = 0xFFFF_FFF0
        let r = DeliveryRecorder()
        DeliveryRecorder.$active.withValue(r) {
            #expect(!SkyLight.focusWithoutRaise(windowID: missingWindow, pid: -1))
            #expect(SkyLight.bringToFront(windowID: missingWindow, pid: -1) == nil)
            final class Ran { var body = false }
            let ran = Ran()
            SkyLight.withMenuShortcutActivation(windowID: missingWindow, pid: -1) { ran.body = true }
            #expect(ran.body, "the body still runs; what it posts marks itself")
        }
        #expect(r.state == .notPerformed)
    }
}
