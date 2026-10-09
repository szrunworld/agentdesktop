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
        for refused: AXError in [.actionUnsupported, .invalidUIElement, .illegalArgument, .notImplemented, .apiDisabled] {
            #expect(AXActions.pressOutcome(refused) == .notPerformed, "\(refused.rawValue)")
        }
        // No answer in time, or a failure that does not say: it may have pressed.
        for unclear: AXError in [.cannotComplete, .failure, .notEnoughPrecision] {
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
}
