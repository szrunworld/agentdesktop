import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing

// Kevin 2026-10-09 (#163): menu authorization is the bound window's, and no
// click reaches a menu. Each refusal is checked to stop before the platform's
// input call (nothing performed), not only by its missing effect.

private func clickAt(_ x: Int, _ y: Int) -> String { #"{"kind":"click","target":{"imagePoint":{"x":\#(x),"y":\#(y)}}}"# }
private func refusedBeforeInput(_ sc: Scene, _ r: RuntimeResponse, path: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(failure(r)?.details?["reason"]?.stringValue == "clipboard_path_refused", sourceLocation: sourceLocation)
    #expect(failure(r)?.details?["path"]?.stringValue == path, sourceLocation: sourceLocation)
    #expect(failure(r)?.notSent == true, sourceLocation: sourceLocation)
    #expect(sc.platform.performed.isEmpty, "the platform's input call was never made", sourceLocation: sourceLocation)
}

@Test func menuClick1_anItemOfTheBoundWindowsOwnMenuIsRefused() throws {
    let sc = try scene()
    sc.platform.menuShown = true
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXMenuItem", texts: ["Look Up"], windowId: nil, inMenu: true,
                                              ancestorTexts: []) }
    refusedBeforeInput(sc, act(sc, clickAt(100, 100)), path: "menu_open")
}

@Test func menuClick2_anItemOfAnotherWindowsMenuIsRefused() throws {
    let sc = try scene()
    sc.platform.menuShown = true
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXMenuItem", texts: ["Close Window"], windowId: 4242, inMenu: true) }
    refusedBeforeInput(sc, act(sc, clickAt(100, 100)), path: "menu_open")
}

@Test func menuClick3_anotherWindowsMenuCoveringTheBoundWindowIsRefused() throws {
    // The point is inside the bound window's rectangle; what is there is the
    // other window's menu.
    let sc = try scene()
    sc.platform.menuShown = true
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXMenuItem", texts: ["Delete"], windowId: 4242, inMenu: true) }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "menu_open")
}

@Test func menuClick4_aMenuOverlappingTheBoundWindowIsRefused() throws {
    // Overlap is not ownership: an item whose window is reported as the bound
    // one, but which is in a menu, is still a menu item.
    let sc = try scene()
    sc.platform.menuShown = true
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXMenuItem", texts: ["Open"], windowId: 11, inMenu: true) }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "menu_open")
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXGroup", texts: ["Recent Items"], windowId: 11, inMenu: true) }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "menu_open")
}

@Test func menuClick5_anItemWhoseMenuCannotBeToldIsRefused() throws {
    let sc = try scene()
    sc.platform.menuShown = nil
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXMenuItem", texts: [], windowId: nil, inMenu: true) }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "menu_item_unverified")
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXMenuBarItem", texts: ["File"], windowId: nil) }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "menu_open")
}

@Test func menuClick6_anUncoveredSpotOfTheBoundWindowIsSent() throws {
    let sc = try scene()
    sc.platform.menuShown = true   // a menu is open elsewhere; this spot is the bound window's
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXGroup", texts: [], windowId: 11) }
    let r = try #require(data(act(sc, clickAt(60, 60))))
    #expect(r["delivery"]?.stringValue == "dispatched")
    #expect(sc.platform.performed.count == 1)
}

@Test func menuClick7_aMenuVanishingAfterTheRefusalDoesNotLetTheClickThrough() throws {
    // The menu covers the point when the click is judged; it closes right
    // after. The refused click is not sent then, nor retried.
    let sc = try scene()
    sc.platform.menuShown = true
    final class Reads: @unchecked Sendable { var n = 0 }
    let reads = Reads()
    sc.platform.hitAt = { _, _ in
        reads.n += 1
        return reads.n == 1 ? PlatformHit(role: "AXMenuItem", texts: ["Delete"], windowId: 4242, inMenu: true)
                            : PlatformHit(role: "AXGroup", texts: [], windowId: 11)
    }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "menu_open")
    sc.platform.menuShown = false
    #expect(sc.platform.performed.isEmpty, "nothing is sent later on the strength of the menu having gone")
}

@Test func menuClick8_aTargetG2CannotReadIsRefusedWithNoInput() throws {
    let sc = try scene()
    sc.platform.menuShown = true
    sc.platform.hitAt = { _, _ in nil }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "hit_unavailable")
    // Something under the point that is not in the bound window and not a menu.
    sc.platform.hitAt = { _, _ in PlatformHit(role: "AXButton", texts: ["OK"], windowId: 5555) }
    refusedBeforeInput(sc, act(sc, clickAt(60, 60)), path: "outside_bound_window")
}
