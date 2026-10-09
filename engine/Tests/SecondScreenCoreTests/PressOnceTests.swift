import ApplicationServices
import Foundation
@testable import SecondScreenCore
import Testing

// #172 (P1, Kevin 2026-10-09): one authorized click is sent once. An
// accessibility press is never retried, and is followed by an event click
// only when it certainly did nothing.
@Suite struct PressOnceTests {
    @Test func whatEachAccessibilityResultProves() {
        #expect(AXActions.pressOutcome(.success) == .pressed)
        for refused: AXError in [.actionUnsupported, .illegalArgument, .notImplemented, .apiDisabled] {
            #expect(AXActions.pressOutcome(refused) == .notPerformed, "\(refused.rawValue)")
        }
        // No answer in time, or a failure that does not say: it may have
        // pressed. An element gone after the call may be gone because of it
        // (b9 on d0131b4): "Send" or "Close" removes its own button.
        for unclear: AXError in [.cannotComplete, .failure, .notEnoughPrecision, .invalidUIElement,
                                 .attributeUnsupported, .noValue] {
            #expect(AXActions.pressOutcome(unclear) == .unknown, "\(unclear.rawValue)")
        }
    }

    final class Count { var presses = 0; var clicks = 0 }

    @Test func aPressThatWentThroughSendsNoClick() throws {
        let c = Count()
        let route = try InputEngine.pressThenClick(press: { c.presses += 1; return .pressed }, what: "element 3",
                                                   click: { c.clicks += 1; return "event.click" })
        #expect(route == "ax.press")
        #expect(c.presses == 1 && c.clicks == 0)
    }

    @Test func aPressWithNoClearAnswerIsNotRetriedNorFollowedByAClick() {
        let c = Count()
        do {
            _ = try InputEngine.pressThenClick(press: { c.presses += 1; return .unknown }, what: "element 3",
                                               click: { c.clicks += 1; return "event.click" })
            Issue.record("an unclear press went on")
        } catch {
            let m = (error as? AccessibilityError)?.message ?? "\(error)"
            #expect(m.contains("may have pressed") && m.contains("no further click was sent"), "\(m)")
        }
        #expect(c.presses == 1, "pressed once, never again")
        #expect(c.clicks == 0, "no event click after it")
    }

    @Test func aPressCertainlyRefusedFallsBackToOneClick() throws {
        let c = Count()
        let route = try InputEngine.pressThenClick(press: { c.presses += 1; return .notPerformed }, what: "element 3",
                                                   click: { c.clicks += 1; return "event.click" })
        #expect(route == "event.click")
        #expect(c.presses == 1 && c.clicks == 1)
    }

    @Test func anExplicitPressSaysWhetherItMayHavePressed() {
        var info = AXElementInfo(index: 3, role: "AXButton", label: "Send")
        info.actions = ["AXPress"]
        do { _ = try InputEngine.pressExplicitly(info) { .unknown }; Issue.record("went on") } catch {
            #expect(((error as? AccessibilityError)?.message ?? "").contains("may have pressed"))
        }
        do { _ = try InputEngine.pressExplicitly(info) { .notPerformed }; Issue.record("went on") } catch {
            #expect(((error as? AccessibilityError)?.message ?? "").contains("nothing was pressed"))
        }
    }

    // b9 on d0131b4: only a failure of the check before the press is not
    // performed; the same error after the press is unknown.
    @Test func anElementGoneBeforeThePressIsNotPerformedButGoneAfterItIsUnknown() {
        final class Asked { var perform = 0 }
        let a = Asked()
        #expect(AXActions.pressOnce(validate: { .invalidUIElement }, perform: { a.perform += 1; return .success }) == .notPerformed)
        #expect(a.perform == 0, "nothing was asked of the element")
        #expect(AXActions.pressOnce(validate: { .success }, perform: { a.perform += 1; return .invalidUIElement }) == .unknown)
        #expect(a.perform == 1)
        #expect(AXActions.pressOnce(validate: { .success }, perform: { .success }) == .pressed)
    }
}
