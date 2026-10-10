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
    let terminals = all.filter { ["action.completed", "action.failed", "action.unknown", "action.refused"].contains($0["type"]?.stringValue ?? "") }
    let terminalIds = terminals.compactMap { $0["data"]?["requestId"]?.stringValue ?? $0["data"]?["receipt"]?["requestId"]?.stringValue }
    #expect(terminalIds.count == terminals.count)
    #expect(Set(terminalIds).count == terminalIds.count, "one terminal per action")
    for e in terminals {
        if e["type"]?.stringValue == "action.refused" { #expect(e["data"]?["receipt"] == nil) }
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

@Test func wireRunEventsAndFramesUseTheFrozenCatalog() throws {
    let valid = try StrictJSON.parse(#"{"runId":"run_test","sequence":1,"at":"2026-10-10T00:00:00Z","type":"run.quiescent","data":{"revision":1}}"#)
    #expect(contract.validate(valid, "RunEvent").isEmpty)
    let frame = { (event: JSONValue) in JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)), ("event", event)]) }
    #expect(contract.validate(frame(valid), "EventFrame").isEmpty)
    for bad in [valid.setting("type", .string("run.invented")),
                valid.setting("type", .string("action.invented")),
                valid.setting("type", .string("stop.invented")),
                valid.setting("data", .obj([])),
                valid.setting("data", .obj([("revision", .string("wrong"))]))] {
        #expect(!contract.validate(bad, "RunEvent").isEmpty)
        #expect(!contract.validate(frame(bad), "EventFrame").isEmpty)
    }
    #expect(contract.validate(valid.setting("type", .string("x.example")), "RunEvent").isEmpty)
    #expect(contract.validate(valid.setting("type", .string("unit.example")), "RunEvent").isEmpty)
}

@Test func frozenEventDocumentationReferencesTheAuthorityWithoutATableCopy() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent("docs/architecture/runtime-api-v1-freeze.md"), encoding: .utf8)
    let tail = try #require(text.components(separatedBy: "### 4.1 ").last)
    let section = try #require(tail.components(separatedBy: "## 5.").first)
    #expect(section.contains("$defs/PlatformRunEvent"))
    #expect(!section.contains("| type | data |"))
    #expect(!section.contains("| `run."))
    #expect(!section.contains("| `action."))
}

@Test func historicalFailureAfterDispatchRemainsValid() throws {
    let sc = try scene()
    let receipt = try #require(data(act(sc, clickContinue)))
    let failed = receipt.setting("execution", .string("failed"))
        .setting("reason", .obj([("code", .string("execution_failed")), ("message", .string("failure after submission"))]))
    #expect(failed["delivery"]?.stringValue == "dispatched")
    let event = JSONValue.obj([("runId", failed["runId"] ?? .string("run_test")), ("sequence", .int(1)),
                               ("at", .string("2026-10-10T00:00:00Z")), ("type", .string("action.failed")),
                               ("data", .obj([("receipt", failed)]))])
    #expect(contract.validate(event, "RunEvent").isEmpty)
}

// The outer type of a terminal action event cannot contradict its receipt:
// it is `action.<receipt.execution>` (RuntimeService+Act).
@Test func terminalActionTypeAgreesWithReceiptExecution() throws {
    let sc = try scene()
    let receipt = try #require(data(act(sc, clickContinue)))
    let event = { (type: String, data: JSONValue) in
        JSONValue.obj([("runId", receipt["runId"] ?? .string("run_test")), ("sequence", .int(1)),
                       ("at", .string("2026-10-10T00:00:00Z")), ("type", .string(type)), ("data", data)])
    }
    let frame = { (e: JSONValue) in JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)), ("event", e)]) }
    let outcomes = ["completed", "failed", "unknown"]
    for type in outcomes {
        for execution in outcomes {
            let e = event("action.\(type)", .obj([("receipt", receipt.setting("execution", .string(execution)))]))
            for (v, def) in [(e, "RunEvent"), (frame(e), "EventFrame"), (e, "PlatformRunEvent")] {
                let ok = contract.validate(v, def).isEmpty
                #expect(ok == (type == execution), "action.\(type) with execution \(execution) as \(def): valid=\(ok)")
            }
        }
    }
}
