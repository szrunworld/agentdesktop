import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing

// #170, Kevin 2026-10-09: notSent means not_performed — the Runtime can
// prove the action sent no input and made no write with an outside effect,
// whether or not the request reached it. Partly sent, timed out, cut off or
// unknown is never notSent. Being not performed does not allow a retry to
// get past a stop, a refusal or the ledger.

// Received, refused, nothing performed: notSent, and the platform got nothing.
@Test func aRequestTheRuntimeRefusedIsNotPerformed() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    // A security policy (G2), a stale target, a passed deadline.
    let refusals = [
        act(sc, #"{"kind":"key","key":"v","modifiers":["cmd"]}"#),
        act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#, snapshot: "obs_unknown"),
        act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#, deadline: "2000-01-01T00:00:00Z"),
    ]
    for r in refusals {
        #expect(code(r) != nil)
        #expect(failure(r)?.notSent == true, "\(failure(r)?.code ?? "")")
    }
    #expect(platform.performed.isEmpty, "not performed means the platform's input call was never made")
}

// Sent, then the target changed: the input may have gone elsewhere. Never notSent.
@Test func anInputThatWentOutIsNeverNotPerformed() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    sc.platform.onPerform = { openSibling(backend) }
    let r = act(sc, #"{"kind":"click","target":{"elementRef":"el_0"}}"#)
    #expect(code(r) == "action_delivery_unknown")
    #expect(failure(r)?.notSent != true)
    #expect(failure(r)?.details?["receipt"]?["delivery"]?.stringValue == "unknown")
    #expect(sc.platform.performed.count == 1)
}

// After a stop, an action is refused before any input (not performed); a
// retry, with the same requestId or a new one, is refused again and sends
// nothing: not performed is no licence to retry past the stop.
@Test func aRefusalAfterAStopIsNotPerformedAndARetryStaysRefused() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    #expect(data(call(sc.s, sc.c, "runtime.stopAll", params: #"{"scope":"all_platform_runs"}"#)) != nil)
    let first = act(sc, #"{"kind":"key","key":"a"}"#, id: "after-stop-1")
    #expect(code(first) == "input_disabled")
    #expect(failure(first)?.notSent == true)
    let same = act(sc, #"{"kind":"key","key":"a"}"#, id: "after-stop-1")
    #expect(code(same) == "input_disabled")
    let fresh = act(sc, #"{"kind":"key","key":"a"}"#, id: "after-stop-2")
    #expect(code(fresh) == "input_disabled")
    #expect(platform.performed.isEmpty)
}

// A write in flight when the host stopped, which may have run: unknown after
// restart, never notSent, and a retry does not run it.
@Test func aWriteThatMayHaveRunIsUnknownNotNotPerformed() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/requests.sqlite"
    do {
        let ledger = try RequestLedger(path: path)
        #expect(try ledger.begin(caller: getuid(), RuntimeRequest(requestId: "w-1", method: "desktop.create", params: .obj([]))) == .fresh)
    }
    let s = platformService(ledger: try RequestLedger(path: path))
    let c = handshaken(s)
    let retry = call(s, c, "desktop.create", id: "w-1")
    #expect(code(retry) == "request_acceptance_unknown")
    #expect(failure(retry)?.notSent != true)
    #expect(s.desktops.count == 0)
}

// #173: the engine's structured record decides, never its message text.
// Only "notPerformed" is not performed; "submitted", "unknown" and a
// missing record (an engine that does not say) are not.
@Test func onlyTheEnginesRecordOfNoDeliveryIsNotPerformed() {
    #expect(EnginePlatform.notPerformed(delivery: "notPerformed"))
    for d in ["submitted", "unknown", nil, "", "NotPerformed"] as [String?] {
        #expect(!EnginePlatform.notPerformed(delivery: d), "\(d ?? "nil")")
    }
}
