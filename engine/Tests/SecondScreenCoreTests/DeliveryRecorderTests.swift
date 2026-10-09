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
}
