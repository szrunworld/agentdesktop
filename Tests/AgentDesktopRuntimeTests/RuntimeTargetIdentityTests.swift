import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopProtocol
@testable import AgentDesktopRuntime

// G0 (MAC-001): what is observed and what receives input is the bound
// window, or nothing is observed and nothing is sent.

let calculatorProcess = ProcessIdentity(pid: 101, startedAt: "2026-10-08T01:00:00.000Z")

/// A window of another app over the bound one (2100,100 400x300).
/// The error a response carries, if any.
func failure(_ r: RuntimeResponse) -> RuntimeError? {
    if case let .failure(e) = r.result { return e }
    return nil
}

let coveringWindow = PlatformWindow(windowId: 77, pid: 555, appName: "Notes", title: "盖住",
                                    frame: Rect(x: 2300, y: 200, width: 300, height: 200))

/// What Safari did in MAC-001: the same process opens a window in front.
func openSibling(_ backend: FixedBackend) {
    backend.opened.windows = [WindowSummary(windowId: 15, process: calculatorProcess, appName: "Calculator",
                                            bundleId: "com.apple.calculator", title: "新窗口",
                                            frame: Rect(x: 2600, y: 400, width: 300, height: 200), onScreen: true)]
}

@Test func aCoveredWindowIsNeitherObservedNorTyped() throws {
    let sc = try scene()
    sc.platform.inFront[sc.s.desktops.find(sc.desktop)!.screen.name] = [coveringWindow]
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "stale_observation")
    #expect(failure(o)?.details?["reason"]?.stringValue == "occluded")
    #expect(failure(o)?.details?["coveringWindowId"]?.intValue == 77)
    let a = act(sc, #"{"kind":"type","target":{"elementRef":"el_1"},"text":"Ada"}"#)
    #expect(code(a) == "stale_observation")
    #expect(failure(a)?.notSent == true)
    #expect(sc.platform.performed.isEmpty)
}

@Test func aNewWindowOfTheSameAppInheritsNothing() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    openSibling(backend)
    // Not even overlapping: keys would go to the app's front window.
    let a = act(sc, #"{"kind":"key","key":"return"}"#)
    #expect(code(a) == "stale_observation")
    #expect(failure(a)?.details?["reason"]?.stringValue == "other_window_of_process_in_front")
    #expect(failure(a)?.details?["coveringWindowId"]?.intValue == 15)
    #expect(code(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
    // Once the new window is gone, the bound one is usable again.
    backend.opened.windows = []
    #expect(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
}

@Test func aWindowAppearingWhileInputIsSentMakesItUnknownAndStopsTheNext() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    // The check passed; the window pops up as the input goes out.
    sc.platform.onPerform = { openSibling(backend) }
    let a = act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#)
    #expect(code(a) == "action_delivery_unknown")
    #expect(failure(a)?.details?["reason"]?.stringValue == "target_changed_during_dispatch")
    #expect(failure(a)?.details?["receipt"]?["delivery"]?.stringValue == "unknown")
    #expect(sc.platform.performed.count == 1)
    // Nothing more goes out, and nothing is retried or redirected.
    sc.platform.onPerform = nil
    let next = act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#)
    #expect(code(next) == "stale_observation")
    #expect(sc.platform.performed.count == 1)
}

@Test func windowsChangingDuringTheCaptureVoidTheObservation() throws {
    let sc = try scene()
    let screen = sc.s.desktops.find(sc.desktop)!.screen.name
    sc.platform.onCapture = { sc.platform.inFront[screen] = [coveringWindow] }
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "stale_observation")
    #expect(["changed_during_capture", "occluded"].contains(failure(o)?.details?["reason"]?.stringValue ?? ""))
}

@Test func theImageIsTheBoundWindowAndReceiptsSayDeliveryIsNotEffect() throws {
    let sc = try scene()
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let frame = try #require(o["target"]?["windowFrame"])
    #expect(o["image"]?["transform"]?["originX"] == frame["x"])
    #expect(o["image"]?["transform"]?["originY"] == frame["y"])
    #expect(o["image"]?["width"]?.doubleValue == (frame["width"]?.doubleValue ?? 0) * 2)
    #expect(sc.platform.calls.contains { $0.hasSuffix("window") })
    let snap = try #require(o["snapshotId"]?.stringValue)
    let r = try #require(data(act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#, snapshot: snap)))
    #expect(contract.validate(r, "ActionReceipt").isEmpty, "\(r.encoded())")
    #expect(r["businessResult"]?.stringValue == "not_evaluated")
    #expect(r["verification"]?.stringValue == "not_requested")
}

@Test func aDesktopWithoutABindingStillShowsTheWholeScreen() throws {
    let sc = try scene()
    let c = handshaken(sc.s)
    let d = try created(sc.s, c)
    let o = try #require(data(call(sc.s, c, "observe", context: #"{"desktopId":"\#(d)"}"#)))
    let screen = try #require(sc.s.desktops.find(d)?.screen)
    #expect(o["image"]?["transform"]?["originX"]?.doubleValue == screen.frame.x)
    #expect(o["target"] == .null)
}
