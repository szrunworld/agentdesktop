import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A5: act kinds hover, press and drag. RT-21 (each has its receipt), RT-11
// (no background drag: unsupported_backend, never the foreground), RT-22
// (every receipt says businessResult not_evaluated).

private func reason(_ r: RuntimeResponse) -> String? { errorDetails(r)?["reason"]?.stringValue }

@Test func rt21_hoverByElementOrPointHasItsReceipt() throws {
    let sc = try scene()
    let byElement = try #require(data(act(sc, #"{"kind":"hover","target":{"elementRef":"el_0"}}"#)))
    #expect(contract.validate(byElement, "ActionReceipt").isEmpty, "\(byElement.encoded())")
    #expect(byElement["delivery"]?.stringValue == "dispatched")
    #expect(sc.platform.performed.last?.kind == .hover && sc.platform.performed.last?.elementIndex == 0)
    let byPoint = try #require(data(act(sc, #"{"kind":"hover","target":{"imagePoint":{"x":100,"y":100}}}"#)))
    #expect(byPoint["target"]?["point"]?["x"]?.doubleValue == 2150)
    #expect(sc.platform.performed.last?.kind == .hover && sc.platform.performed.last?.point?.x == 2150)
}

@Test func rt21_pressIsAnAccessibilityPressOfOneElement() throws {
    let sc = try scene()
    let receipt = try #require(data(act(sc, #"{"kind":"press","target":{"elementRef":"el_0"}}"#)))
    #expect(contract.validate(receipt, "ActionReceipt").isEmpty)
    #expect(receipt["delivery"]?.stringValue == "dispatched")
    let sent = try #require(sc.platform.performed.last)
    #expect(sent.kind == .press && sent.elementIndex == 0 && sent.point == nil)
    // An element only: a point, a button or modifiers are refused before anything is sent.
    let before = sc.platform.performed.count
    for bad in [#"{"kind":"press","target":{"imagePoint":{"x":10,"y":10}}}"#,
                #"{"kind":"press","target":{"elementRef":"el_0"},"button":"right"}"#,
                #"{"kind":"press","target":{"elementRef":"el_0"},"modifiers":["cmd"]}"#,
                #"{"kind":"press"}"#, #"{"kind":"hover"}"#, #"{"kind":"hover","target":{"elementRef":"el_0"},"text":"x"}"#] {
        #expect(code(act(sc, bad)) == "schema_invalid", "\(bad)")
    }
    #expect(sc.platform.performed.count == before)
}

@Test func aPressOnAPasteControlIsRefusedLikeAClick() throws {
    let platform = FakePlatform()
    platform.elements = [PlatformElement(index: 0, role: "AXButton", label: "Paste", value: nil, actions: ["AXPress"],
                                         frame: Rect(x: 2100, y: 100, width: 80, height: 30))]
    let sc = try scene(platform)
    let r = act(sc, #"{"kind":"press","target":{"elementRef":"el_0"}}"#)
    #expect(code(r) == "permission_denied" && reason(r) == "clipboard_path_refused")
    #expect(platform.performed.isEmpty)
}

@Test func rt11_aDragIsRefusedAsUnsupportedAndNothingIsSent() throws {
    let sc = try scene()
    let r = act(sc, #"{"kind":"drag","target":{"elementRef":"el_0"},"to":{"imagePoint":{"x":200,"y":200}}}"#, id: "drag-1")
    #expect(code(r) == "unsupported_backend" && reason(r) == "background_drag_unsupported")
    if case let .failure(e) = r.result { #expect(e.notSent == true) }
    #expect(sc.platform.performed.isEmpty, "never done in the foreground instead")
    #expect(!sc.platform.calls.contains { $0.hasPrefix("perform") })
    // Its one-action Run says so too.
    let run = try #require(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue?.first)
    #expect(run["outcome"]?.stringValue == "failed")
    let events = data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(run["runId"]?.stringValue ?? "")"}"#))?["events"]?.arrayValue ?? []
    #expect(events.contains { $0["type"]?.stringValue == "action.refused" && $0["data"]?["reason"]?["code"]?.stringValue == "unsupported_backend" })
    // A drag without its destination is not a drag.
    #expect(code(act(sc, #"{"kind":"drag","target":{"elementRef":"el_0"}}"#)) == "schema_invalid")
}

@Test func rt22_everyReceiptLeavesTheBusinessResultUnevaluated() throws {
    let sc = try scene()
    var receipts: [JSONValue] = []
    for action in [clickContinue, #"{"kind":"hover","target":{"elementRef":"el_0"}}"#,
                   #"{"kind":"press","target":{"elementRef":"el_0"}}"#,
                   #"{"kind":"scroll","direction":"down"}"#] {
        receipts.append(try #require(data(act(sc, action)), "\(action)"))
    }
    #expect(receipts.allSatisfy { $0["businessResult"]?.stringValue == "not_evaluated" })
}
