import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// F1-01 / F1-03: the events the Runtime writes on a Run are a frozen catalog
// (runtime.schema.json PlatformRunEvent), and a refused, failed or unknown
// action says why when read back later.

private func events(_ sc: Scene, _ runId: String) -> [JSONValue] {
    data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(runId)","after":0,"limit":500}"#))?["events"]?.arrayValue ?? []
}

@Test func everyEventTheRuntimeWritesIsInTheCatalog() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    let started = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let runId = try #require(started["run"]?["runId"]?.stringValue)
    // Delivered.
    #expect(data(act(sc, clickContinue, runId: runId)) != nil)
    // Refused before any input: a covering window (G0).
    let screen = sc.s.desktops.find(sc.desktop)!.screen.name
    sc.platform.inFront[screen] = [coveringWindow]
    #expect(code(act(sc, clickContinue, runId: runId)) == "stale_observation")
    sc.platform.inFront[screen] = nil
    // Refused: an unknown snapshot.
    #expect(code(act(sc, clickContinue, snapshot: "obs_gone", runId: runId)) == "stale_observation")
    // Failed before dispatch, and unknown.
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)","runId":"\#(runId)"}"#)))
    let snap = try #require(o["snapshotId"]?.stringValue)
    sc.platform.failNext = PlatformError(.refused, "the app said no", beforeDispatch: true)
    #expect(code(act(sc, clickContinue, snapshot: snap, runId: runId)) == "execution_failed")
    sc.platform.failNext = PlatformError(.refused, "no answer", beforeDispatch: false)
    #expect(code(act(sc, clickContinue, snapshot: snap, runId: runId)) == "action_delivery_unknown")
    // Stopped and ended.
    _ = call(sc.s, sc.c, "run.cancel", params: #"{"runId":"\#(runId)"}"#)

    let all = events(sc, runId)
    let types = all.compactMap { $0["type"]?.stringValue }
    for t in ["run.started", "action.accepted", "action.dispatched", "action.completed", "action.refused",
              "action.failed", "action.unknown", "stop.accepted", "run.quiescent", "run.ended"] {
        #expect(types.contains(t), "\(t) was not written: \(types)")
    }
    for e in all {
        let v = contract.validate(e, "PlatformRunEvent")
        #expect(v.isEmpty, "\(e["type"]?.stringValue ?? "?"): \(v.prefix(3))")
    }
    // Two refusals, each with its reason.
    let refused = all.filter { $0["type"]?.stringValue == "action.refused" }
    #expect(refused.count == 2)
    #expect(refused.allSatisfy { $0["data"]?["reason"]?["code"]?.stringValue == "stale_observation" })
}

@Test func aReceiptSaysWhyOnlyWhenItWasNotDelivered() throws {
    let sc = try scene()
    let ok = try #require(data(act(sc, clickContinue)))
    #expect(ok["reason"] == nil)
    #expect(contract.validate(ok, "ActionReceipt").isEmpty)
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let snap = try #require(o["snapshotId"]?.stringValue)
    sc.platform.failNext = PlatformError(.refused, "the app said no", beforeDispatch: true)
    let failed = act(sc, clickContinue, snapshot: snap)
    let receipt = try #require(failure(failed)?.details?["receipt"])
    #expect(receipt["delivery"]?.stringValue == "not_dispatched")
    #expect(receipt["reason"]?["code"]?.stringValue == "execution_failed")
    #expect(contract.validate(receipt, "ActionReceipt").isEmpty)
    // The ledger keeps it with the reason for request.show.
    let shown = try #require(data(call(sc.s, sc.c, "request.show", params: #"{"requestId":"\#(failure(failed)?.details?["receipt"]?["requestId"]?.stringValue ?? "")"}"#)))
    #expect(shown.encoded().contains("execution_failed"))
}
