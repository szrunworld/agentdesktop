import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing

// #172 (P1, Kevin 2026-10-09): an authorized click is sent once. The engine
// no longer retries an accessibility press nor clicks after an unclear one;
// above it no layer retries either: the Runtime replays the outcome of a
// requestId, and an unknown delivery stays unknown through a cancel.

// The engine's words for an unclear press (BackgroundInput.pressUnknown).
let unclearPress = "the accessibility press of element 0 got no clear answer; it may have pressed, so no further click was sent"

@Test func anUnclearPressIsNeverTakenAsNotPerformed() {
    #expect(!EnginePlatform.preDispatchFailures.contains { unclearPress.lowercased().contains($0.lowercased()) })
}

@Test func anUnclearClickIsUnknownAndNotRunAgainOnRetryOrCancel() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    // Every call to the platform's perform, failed or not.
    func performs() -> Int { platform.calls.filter { $0.hasPrefix("perform ") }.count }
    let owner = handshaken(sc.s)
    let start = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let runId = try #require(start["run"]?["runId"]?.stringValue)
    platform.failNext = PlatformError(.refused, unclearPress, beforeDispatch: false)
    let first = act(sc, clickContinue, id: "click-once-1", runId: runId, on: owner)
    #expect(code(first) == "action_delivery_unknown")
    #expect(failure(first)?.notSent != true)
    #expect(performs() == 1)
    // The same requestId replays the outcome; the platform is not called again.
    let again = act(sc, clickContinue, id: "click-once-1", runId: runId, on: owner)
    #expect(code(again) == "action_delivery_unknown")
    #expect(performs() == 1, "a retry of the same request never clicks again")
    // A cancel keeps what is known: the Run ends unknown, not cancelled.
    #expect(data(call(sc.s, owner, "run.cancel", params: #"{"runId":"\#(runId)"}"#)) != nil)
    let ended = try #require(data(call(sc.s, owner, "run.wait", params: #"{"runId":"\#(runId)","timeoutMs":2000}"#)))
    #expect(ended["phase"]?.stringValue == "ended")
    #expect(ended["outcome"]?.stringValue == "unknown")
    #expect(performs() == 1)
}
