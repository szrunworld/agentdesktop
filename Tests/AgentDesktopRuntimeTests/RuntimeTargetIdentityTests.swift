@testable import AgentDesktopProtocol
import Foundation
import Testing
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

@Test func aDesktopWithoutABindingShowsTheWholeScreenOnlyWhereThatIsAllowed() throws {
    // Tests that switch the restriction off (as scene() does) keep the old behaviour…
    let sc = try scene()
    let c = handshaken(sc.s)
    let d = try created(sc.s, c)
    let o = try #require(data(call(sc.s, c, "observe", context: #"{"desktopId":"\#(d)"}"#)))
    let screen = try #require(sc.s.desktops.find(d)?.screen)
    #expect(o["image"]?["transform"]?["originX"]?.doubleValue == screen.frame.x)
    #expect(o["target"] == .null)
    // …the product refuses it until a screen-level grant exists.
    sc.s.refusesScreenCaptureWithoutBinding = true
    let refused = call(sc.s, c, "observe", context: #"{"desktopId":"\#(d)"}"#)
    #expect(code(refused) == "invalid_target")
    #expect(failure(refused)?.details?["reason"]?.stringValue == "screen_capture_requires_grant")
}

@Test func untilGrantsAVirtualDesktopBindsOnlyAppsItLaunchedAndCapturesTheWindowAlone() throws {
    let platform = FakePlatform()
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: platform)
    #expect(s.bindsOnlyLaunchedProcesses && s.refusesScreenCaptureWithoutBinding, "the product defaults")
    let c = handshaken(s)
    let d = try created(s, c)
    // One of the user's own apps (pid 101) cannot be pulled onto the agent screen.
    let refused = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    #expect(code(refused) == "permission_denied")
    #expect(failure(refused)?.details?["reason"]?.stringValue == "bind_requires_grant")
    #expect(!platform.calls.contains { $0.hasPrefix("move") }, "the user's window is not moved")
    // No screenshot of the whole screen without a bound window.
    #expect(code(call(s, c, "observe", context: #"{"desktopId":"\#(d)"}"#)) == "invalid_target")
    #expect(!platform.calls.contains { $0.hasPrefix("screenshot") })
    // An app launched on the Desktop can be bound; its observation is the window alone.
    let launched = try #require(data(call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.Notes"}"#)))
    let pid = try #require(launched["process"]?["pid"]?.intValue)
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":\#(pid)}"#)) != nil)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    #expect(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)) != nil)
    #expect(platform.calls.contains { $0.hasSuffix(" window") }, "window capture: \(platform.calls)")
    #expect(!platform.calls.contains { $0 == "screenshot \(d)" }, "never the whole screen")
}

@Test func aWindowAppearingElsewhereOnTheScreenDoesNotVoidTheObservation() throws {
    let sc = try scene()
    let screen = sc.s.desktops.find(sc.desktop)!.screen
    // Like the screen-recording indicator in the menu bar, far from the window.
    let indicator = PlatformWindow(windowId: 88, pid: 1, appName: "Control Center", title: "",
                                   frame: Rect(x: screen.frame.x + screen.frame.width - 20, y: 3, width: 10, height: 18))
    sc.platform.onCapture = { sc.platform.inFront[screen.name] = [indicator] }
    #expect(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
}

// #120 audit: a floating panel of the same process (not a normal-level window,
// so not in the stack checks) holds keyboard focus. Keys and typing would
// reach it, not the bound window: refused, nothing sent.
@Test func keysAndTypingAreRefusedWhileAnotherWindowOfTheAppHasFocus() throws {
    let sc = try scene()
    let bound = try #require(sc.s.desktops.find(sc.desktop)?.binding?.windowId)
    func reason(_ a: String) -> String? { failure(act(sc, a))?.details?["reason"]?.stringValue }
    let keyA = #"{"kind":"key","key":"a"}"#
    // Focus in another window of the app (a floating panel): refused, nothing sent.
    sc.platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: bound &+ 1000, focused: true, editable: true)
    for a in [keyA, #"{"kind":"type","text":"hello"}"#, #"{"kind":"key","key":"tab"}"#] {
        #expect(reason(a) == "focus_outside_bound_window")
    }
    #expect(sc.platform.performed.isEmpty)
    // Kevin 2026-10-09: focus that cannot be told is refused, for every key.
    sc.platform.focusedHit = nil
    for a in [keyA, #"{"kind":"key","key":"delete"}"#, #"{"kind":"key","key":"left"}"#] {
        #expect(reason(a) == "focus_unverified")
    }
    // A focused element whose window cannot be read.
    sc.platform.focusFollowsWindow = false
    sc.platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: nil, focused: true, editable: true)
    #expect(reason(keyA) == "focus_unverified")
    // No focused element and no focused window: who would get the key cannot be told.
    sc.platform.focusFollowsWindow = false
    sc.platform.focusedHit = PlatformHit(role: "AXNone", texts: [], windowId: nil)
    #expect(reason(keyA) == "focus_unverified")
    // No focused element, the app's focused window is another one.
    sc.platform.focusedHit = PlatformHit(role: "AXNone", texts: [], windowId: bound &+ 1000)
    #expect(reason(keyA) == "focus_outside_bound_window")
    #expect(sc.platform.performed.isEmpty)
    // Focus in the bound window: sent; a read that fails once is tried again.
    sc.platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: bound, focused: true, editable: true)
    #expect(code(act(sc, keyA)) == nil)
    sc.platform.focusFailures = 1
    #expect(code(act(sc, keyA)) == nil)
    // Clicks are judged by what is under the point (G2), not by focus.
    sc.platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: bound &+ 1000, focused: true, editable: true)
    #expect(code(act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#)) == nil)
}

// Kevin 2026-10-09: with a menu open nothing is sent, not even the arrows or
// Escape; an unreadable menu state refuses; the focus check returns once the
// menu is closed. Clicks are judged by what is under the point (G2).
@Test func withAMenuOpenNoKeyAndNoTypingIsSent() throws {
    let sc = try scene()
    // G2 refuses Return, Space and typing first, naming the path.
    func reason(_ a: String) -> String? {
        let d = failure(act(sc, a))?.details
        return d?["reason"]?.stringValue == "clipboard_path_refused" ? d?["path"]?.stringValue : d?["reason"]?.stringValue
    }
    sc.platform.focusedHit = PlatformHit(role: "AXMenuItem", texts: ["Open"], windowId: 4242, focused: true)
    sc.platform.menuShown = true
    for a in [#"{"kind":"key","key":"down"}"#, #"{"kind":"key","key":"up"}"#, #"{"kind":"key","key":"escape"}"#,
              #"{"kind":"key","key":"a"}"#, #"{"kind":"key","key":"delete"}"#, #"{"kind":"key","key":"tab"}"#,
              #"{"kind":"key","key":"o","modifiers":["cmd"]}"#, #"{"kind":"key","key":"return"}"#,
              #"{"kind":"key","key":"space"}"#, #"{"kind":"type","text":"x"}"#] {
        #expect(reason(a) == "menu_open", "\(a)")
    }
    #expect(sc.platform.performed.isEmpty)
    sc.platform.menuShown = nil
    #expect(reason(#"{"kind":"key","key":"escape"}"#) == "menu_unverified")
    // Closed again: the focus check is back (focus is not in the bound window here).
    sc.platform.menuShown = false
    #expect(reason(#"{"kind":"key","key":"down"}"#) == "focus_outside_bound_window")
    // Closing a menu by clicking the bound window is a click, judged by G2.
    sc.platform.menuShown = true
    #expect(code(act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#)) == nil)
}

// Kevin's three regression cases for menus (2026-10-09). Whose a menu is cannot
// be proved, so all three refuse; where the menu is does not matter.
@Test(arguments: ["another window's menu, beside the bound window",
                  "another window's menu, over the bound window",
                  "a menu whose owner cannot be told"])
func menuNavigationNeverGetsThroughOnAMenuThatIsNotProvedTheBoundWindows(_ menuCase: String) throws {
    let sc = try scene()
    sc.platform.focusedHit = PlatformHit(role: "AXMenuItem", texts: ["Open"], windowId: 4242, focused: true)
    sc.platform.menuShown = menuCase.hasPrefix("a menu whose owner") ? nil : true
    for k in ["down", "escape"] {
        let r = failure(act(sc, #"{"kind":"key","key":"\#(k)"}"#))
        #expect(r?.details?["reason"]?.stringValue == (sc.platform.menuShown == nil ? "menu_unverified" : "menu_open"), "\(menuCase) \(k)")
        #expect(r?.notSent == true)
    }
    #expect(sc.platform.performed.isEmpty)
}

// The check and the send are not one step: focus known to have left the
// bound window right after the send makes the delivery unknown.
@Test func focusMovingAwayDuringTheSendMakesTheDeliveryUnknown() throws {
    let sc = try scene()
    let bound = try #require(sc.s.desktops.find(sc.desktop)?.binding?.windowId)
    sc.platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: bound, focused: true, editable: true)
    sc.platform.onPerform = {
        sc.platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: bound &+ 1000, focused: true, editable: true)
    }
    let r = act(sc, #"{"kind":"key","key":"a"}"#)
    #expect(code(r) == "action_delivery_unknown")
    #expect(failure(r)?.details?["receipt"]?["delivery"]?.stringValue == "unknown")
    #expect(sc.platform.performed.count == 1)
}

// Codex on 74278c9 (P1): typed text goes one character at a time, focus is
// checked once. Typing goes only into editable text with focus in the bound
// window, and a newline only ends the text; refused before any input.
@Test func typingNeedsEditableFocusAndANewlineOnlyAtTheEnd() throws {
    let sc = try scene()
    let bound = try #require(sc.s.desktops.find(sc.desktop)?.binding?.windowId)
    func reason(_ a: String) -> String? { failure(act(sc, a))?.details?["reason"]?.stringValue }
    // A plain button of the bound window has focus: "a b" would press it.
    sc.platform.focusedHit = PlatformHit(role: "AXButton", texts: ["Next"], windowId: bound, focused: true)
    #expect(reason(#"{"kind":"type","text":"a b"}"#) == "type_focus_not_text")
    // Nothing focused in the bound window: nowhere sure to type.
    sc.platform.focusedHit = PlatformHit(role: "AXNone", texts: [], windowId: bound)
    #expect(reason(#"{"kind":"type","text":"hello"}"#) == "type_focus_not_text")
    #expect(sc.platform.performed.isEmpty)
    // Editable text with focus: a newline in the middle is refused...
    sc.platform.focusedHit = PlatformHit(role: "AXTextArea", texts: [], windowId: bound, focused: true, editable: true)
    for text in [#"one\ntwo"#, #"one\rtwo"#, #"one\r\ntwo"#, #"\nx"#,
                 // b9 on 4ec619b: only one newline may end the text.
                 #"abc\n\n"#, #"abc\r\n\r\n"#, #"abc\r\r"#, #"abc\n\r"#, #"\n\n"#] {
        #expect(reason(#"{"kind":"type","text":"\#(text)"}"#) == "type_newline_not_last", "\(text)")
    }
    #expect(sc.platform.performed.isEmpty)
    // ...and only at the end it goes through, as does plain text.
    for text in ["hello world", #"one line\n"#, #"one line\r\n"#, #"one line\r"#] {
        #expect(code(act(sc, #"{"kind":"type","text":"\#(text)"}"#)) == nil, "\(text)")
    }
    #expect(sc.platform.performed.count == 4)
}

// Kevin 2026-10-09 (#163, #171): "not performed" only with evidence. Until
// the engine reports it structurally (#173), a failed typing is never taken
// as not performed, not even one that stopped before its first character
// or after a click into a web field went out: the delivery is unknown. A
// one-character key with no key code is typed too; stopped before its
// character it submitted nothing, and keys keep the text match.
@Test func aStoppedTypingIsUnknownAndOnlyAKeyBeforeItsCharacterIsNotPerformed() {
    let none = "keyboard focus is not in window 11; no character was submitted"
    let some = "keyboard focus left window 11 after 2 of 6 characters were submitted to the input interface (whether the app received them is not known); the rest was not submitted"
    #expect(!EnginePlatform.notPerformed(none, kind: .type))
    #expect(!EnginePlatform.notPerformed(some, kind: .type))
    #expect(EnginePlatform.notPerformed(none, kind: .key))
    #expect(!EnginePlatform.notPerformed(some, kind: .key))
}

// Codex on b258049 (P1): no menu was open before a key or typing was sent,
// so a menu after it, or a menu state that cannot be read, is the input's
// doing and focus may have gone with it: unknown, never dispatched.
@Test(arguments: [Optional(true), nil])
func aMenuAppearingWithTheInputMakesTheDeliveryUnknown(_ after: Bool?) throws {
    let sc = try scene()
    sc.platform.onPerform = { sc.platform.menuShown = after }
    for a in [#"{"kind":"key","key":"a"}"#, #"{"kind":"type","text":"x"}"#] {
        sc.platform.menuShown = false
        let r = act(sc, a)
        #expect(code(r) == "action_delivery_unknown", "\(a)")
        #expect(failure(r)?.notSent != true)
        #expect(failure(r)?.details?["receipt"]?["delivery"]?.stringValue == "unknown")
    }
    #expect(sc.platform.performed.count == 2)
}
