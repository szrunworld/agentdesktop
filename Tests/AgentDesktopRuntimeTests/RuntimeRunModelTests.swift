import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Architecture Decision v2.2: Delegated (external_client/connection_scoped)
// and Durable (platform/platform_durable) Runs on one Runtime. Test names
// carry the ADR regression IDs they cover at the Runtime level.

/// A Durable Run on the scene's Desktop, as GUI Explorer would start it.
func durable(_ sc: Scene, origin: RunRecord.Origin = .guiExplorer) throws -> RunRecord {
    let session = sc.s.sessions.open(desktopId: sc.desktop, caller: "local:\(getuid())", at: Timestamp.string(Date()))
    return try sc.s.execution.startDurable(kind: "unit", session: session, origin: origin).get()
}

func runJSON(_ sc: Scene, _ id: String, on c: ConnectionState? = nil) -> JSONValue? {
    data(call(sc.s, c ?? sc.c, "run.show", params: #"{"runId":"\#(id)"}"#))
}

@Test func adr01_aDelegatedRunCarriesItsOwnerAndActs() throws {
    let sc = try scene()
    let owner = handshaken(sc.s)
    let started = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let run = try #require(started["run"])
    #expect(contract.validate(run, "Run").isEmpty, "\(run.encoded())")
    #expect(run["origin"]?.stringValue == "agent_hub")
    #expect(run["ownership"]?.stringValue == "external_client" && run["lifetime"]?.stringValue == "connection_scoped")
    #expect(run["clientId"]?.stringValue == "local:\(getuid())")
    #expect(run["connectionId"]?.stringValue == owner.connectionId)
    #expect(run["phase"]?.stringValue == "running" && run["quiescence"]?.stringValue == "not_confirmed" && run["outcome"] == .null)
    let runId = try #require(run["runId"]?.stringValue)
    #expect(data(act(sc, clickContinue, runId: runId, on: owner))?["delivery"]?.stringValue == "dispatched")
}

@Test func adr03_controlConnectionLossBlocksNewInputAndStopsTheRun() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let owner = handshaken(sc.s)
    let runId = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    // An action in flight while the connection drops.
    platform.gate = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = act(sc, clickContinue, runId: runId, on: owner); done.signal() }
    platform.entered.wait()
    sc.s.connectionClosed(owner)
    let stopping = try #require(runJSON(sc, runId))
    #expect(stopping["phase"]?.stringValue == "stopping" && stopping["quiescence"]?.stringValue == "pending",
            "stopping first; stopped only with quiescence evidence")
    #expect(stopping["closingReason"]?.stringValue == "owner_lost")
    // New input of the Run is refused at once.
    #expect(sc.s.execution.beginAction(runId: runId)?.code == "run_not_active")
    platform.gate?.signal()
    done.wait()
    platform.gate = nil
    let ended = try #require(runJSON(sc, runId))
    #expect(ended["phase"]?.stringValue == "ended" && ended["quiescence"]?.stringValue == "confirmed")
    #expect(ended["outcome"]?.stringValue == "cancelled")
}

@Test func adr04_reconnectingDoesNotResumeTheOldRun() throws {
    let sc = try scene()
    let owner = handshaken(sc.s)
    let start = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let runId = try #require(start["run"]?["runId"]?.stringValue)
    let token = try #require(start["attachToken"]?.stringValue)
    sc.s.connectionClosed(owner)
    let again = handshaken(sc.s)   // same principal, new connection
    #expect(again.connectionId != owner.connectionId && again.clientId == owner.clientId)
    #expect(code(call(sc.s, again, "run.attach", params: #"{"runId":"\#(runId)","token":"\#(token)"}"#)) == "permission_denied")
    #expect(code(act(sc, clickContinue, runId: runId, on: again)) == "permission_denied")
    #expect(runJSON(sc, runId, on: again)?["phase"]?.stringValue == "ended")
    #expect(sc.platform.performed.isEmpty)
}

@Test func adr05_aClientCannotAskForPlatformOwnership() throws {
    let sc = try scene()
    for params in [#"{"lifetime":"platform_durable"}"#, #"{"ownership":"platform"}"#, #"{"origin":"gui_explorer"}"#] {
        #expect(code(call(sc.s, sc.c, "run.start", params: params, context: #"{"sessionId":"\#(sc.session)"}"#)) == "ownership_escalation_denied", "\(params)")
    }
    #expect(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue?.isEmpty == true, "nothing was created")
    // And inside the Runtime, an AgentHub origin cannot be made durable.
    let session = sc.s.sessions.open(desktopId: sc.desktop, caller: "local:\(getuid())", at: Timestamp.string(Date()))
    if case let .failure(e) = sc.s.execution.startDurable(kind: "unit", session: session, origin: .agentHub) {
        #expect(e.code == "ownership_escalation_denied")
    } else { Issue.record("agent_hub origin must not start a durable Run") }
}

@Test func adr06_07_aDurableRunOutlivesConnectionsAndReadsTheSameFromANewOne() throws {
    let sc = try scene()
    let run = try durable(sc)
    #expect(run.ownership == .platform && run.lifetime == .platformDurable && run.clientId == nil && run.connectionId == nil)
    // Pages and subscriptions come and go.
    for _ in 0..<3 { sc.s.connectionClosed(handshaken(sc.s)) }
    sc.s.connectionClosed(sc.c)
    let reloaded = handshaken(sc.s)
    let seen = try #require(runJSON(sc, run.runId, on: reloaded))
    #expect(contract.validate(seen, "Run").isEmpty)
    #expect(seen["phase"]?.stringValue == "running" && seen["revision"]?.intValue == run.revision)
    #expect(data(call(sc.s, reloaded, "run.events", params: #"{"runId":"\#(run.runId)"}"#))?["events"]?.arrayValue?.first?["type"]?.stringValue == "run.started")
    // It still holds its Desktop: a client's one-shot act is refused.
    #expect(code(act(sc, clickContinue, on: reloaded)) == "control_busy")
}

@Test func adr08_stoppingADurableRunIsAcceptedThenQuiescent() throws {
    let sc = try scene()
    let run = try durable(sc)
    #expect(sc.s.execution.beginAction(runId: run.runId) == nil)   // an action in flight
    let receipt = try #require(data(call(sc.s, sc.c, "run.cancel", params: #"{"runId":"\#(run.runId)"}"#)))
    #expect(contract.validate(receipt, "CancelReceipt").isEmpty)
    #expect(receipt["execution"]?["phase"]?.stringValue == "stopping" && receipt["execution"]?["quiescence"]?.stringValue == "pending")
    #expect(code(call(sc.s, sc.c, "run.wait", params: #"{"runId":"\#(run.runId)","timeoutMs":100}"#)) == "wait_timeout")
    sc.s.execution.endAction(runId: run.runId, receiptId: "rcpt_x", deliveryUnknown: false)
    let ended = try #require(data(call(sc.s, sc.c, "run.wait", params: #"{"runId":"\#(run.runId)","timeoutMs":1000}"#)))
    #expect(ended["phase"]?.stringValue == "ended" && ended["quiescence"]?.stringValue == "confirmed" && ended["outcome"]?.stringValue == "cancelled")
}

@Test func adr09_globalStopCoversBothKindsAndReopensForNewRunsOnly() throws {
    let sc = try scene()
    let d = try durable(sc)
    #expect(sc.s.execution.beginAction(runId: d.runId) == nil)     // durable action in flight
    // A Delegated exec Run on a second Desktop.
    let d2 = try created(sc.s, sc.c)
    _ = call(sc.s, sc.c, "window.bind", params: #"{"desktopId":"\#(d2)","pid":101}"#)
    let s2 = try #require(data(call(sc.s, sc.c, "session.open", params: #"{"desktopId":"\#(d2)"}"#))?["sessionId"]?.stringValue)
    let owner = handshaken(sc.s)
    let delegated = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(s2)"}"#))?["run"]?["runId"]?.stringValue)

    let stop = try #require(data(call(sc.s, sc.c, "runtime.stopAll", id: "stop-all-1", params: #"{"scope":"all_platform_runs"}"#)))
    #expect(contract.validate(stop, "StopAllResult").isEmpty, "\(stop.encoded())")
    #expect(stop["admission"]?.stringValue == "stopping")
    #expect(Set(stop["runs"]?.arrayValue?.compactMap { $0["runId"]?.stringValue } ?? []) == [d.runId, delegated])
    #expect(stop["pending"] == .array([.string(d.runId)]), "the durable Run still has an action in flight")
    #expect(runJSON(sc, delegated)?["phase"]?.stringValue == "ended")
    // No new input anywhere while stopped or stopping.
    #expect(code(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)) == "input_disabled")
    #expect(code(call(sc.s, sc.c, "runtime.enableInput")) == "stop_pending")
    #expect(data(call(sc.s, sc.c, "runtime.status"))?["inputAdmission"]?.stringValue == "stopping")
    sc.s.execution.endAction(runId: d.runId, receiptId: nil, deliveryUnknown: false)
    #expect(data(call(sc.s, sc.c, "runtime.status"))?["inputAdmission"]?.stringValue == "stopped")
    #expect(data(call(sc.s, sc.c, "runtime.enableInput"))?["admission"]?.stringValue == "enabled")
    // Old Runs stay ended; a new one may start.
    #expect(runJSON(sc, d.runId)?["phase"]?.stringValue == "ended")
    #expect(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
}

@Test func adr10_anUnknownActionKeepsTheOutcomeUnknownWhateverStopsIt() throws {
    let sc = try scene()
    let run = try durable(sc)
    #expect(sc.s.execution.beginAction(runId: run.runId) == nil)
    sc.s.execution.endAction(runId: run.runId, receiptId: "rcpt_u", deliveryUnknown: true)
    _ = call(sc.s, sc.c, "run.cancel", params: #"{"runId":"\#(run.runId)"}"#)
    let ended = try #require(runJSON(sc, run.runId))
    #expect(ended["outcome"]?.stringValue == "unknown", "stop never turns unknown into cancelled")
    #expect(ended["unknownActions"]?.intValue == 1)
    #expect(ended["quiescence"]?.stringValue == "confirmed")
}

@Test func oneShotActsEndWithTheirDeliveryAsOutcome() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    _ = act(sc, clickContinue, id: "ok-1")
    platform.failNext = PlatformError(.refused, "no element 0 in the window", beforeDispatch: true)
    _ = act(sc, clickContinue, id: "fail-1")
    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    _ = act(sc, clickContinue, id: "unknown-1")
    let runs = try #require(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue)
    #expect(contract.validate(.obj([("runs", .array(runs)), ("next", .null)]), "RunList").isEmpty)
    #expect(runs.compactMap { $0["outcome"]?.stringValue }.sorted() == ["failed", "success", "unknown"])
}

@Test func runListFiltersPagesAndShowsOnlyOwnRunsToAClient() throws {
    let sc = try scene()
    let d = try durable(sc)
    _ = call(sc.s, sc.c, "run.cancel", params: #"{"runId":"\#(d.runId)"}"#)
    for i in 0..<3 { _ = act(sc, clickContinue, id: "list-\(i)") }
    let all = try #require(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue)
    #expect(all.count == 4)
    #expect(data(call(sc.s, sc.c, "run.list", params: #"{"origin":"gui_explorer"}"#))?["runs"]?.arrayValue?.count == 1)
    let page1 = try #require(data(call(sc.s, sc.c, "run.list", params: #"{"limit":2}"#)))
    let cursor = try #require(page1["next"]?.stringValue)
    let page2 = try #require(data(call(sc.s, sc.c, "run.list", params: #"{"limit":2,"cursor":"\#(cursor)"}"#)))
    let ids = (page1["runs"]?.arrayValue ?? []) + (page2["runs"]?.arrayValue ?? [])
    #expect(Set(ids.compactMap { $0["runId"]?.stringValue }).count == 4)
    #expect(page2["next"] == .null)
    // A paired client (future AgentHub principal) sees its own Runs only.
    let client = handshaken(sc.s)
    client.clientId = "client:paired-app"
    #expect(data(call(sc.s, client, "run.list"))?["runs"]?.arrayValue?.isEmpty == true)
    #expect(code(call(sc.s, client, "run.show", params: #"{"runId":"\#(d.runId)"}"#)) == "not_found")
    #expect(code(call(sc.s, client, "runtime.stopAll", params: #"{"scope":"all_platform_runs"}"#)) == "permission_denied")
}

@Test func thePersistentRuntimeKeepsRunsAcrossARestart() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let identity = RuntimeIdentity(instanceId: "rt_p", pid: getpid(), startedAt: Timestamp.string(Date()),
                                   endpoint: dir + "/r.sock", buildSource: "unknown")
    var runId = ""
    do {
        let s = try RuntimeService.persistent(identity: identity, backend: FixedBackend(), platform: FakePlatform(), records: dir)
        let c = handshaken(s)
        let d = try created(s, c)
        _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
        let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
        runId = try #require(data(call(s, c, "run.start", context: #"{"sessionId":"\#(sid)"}"#))?["run"]?["runId"]?.stringValue)
        // The host dies with the Run live.
    }
    for f in ["requests.sqlite", "runs.sqlite"] {
        var st = stat()
        #expect(stat(dir + "/" + f, &st) == 0 && st.st_mode & 0o777 == 0o600, "\(f)")
    }
    let again = try RuntimeService.persistent(identity: identity, backend: FixedBackend(), platform: FakePlatform(), records: dir)
    let c = handshaken(again)
    let run = try #require(data(call(again, c, "run.show", params: #"{"runId":"\#(runId)"}"#)))
    #expect(run["phase"]?.stringValue == "ended" && run["quiescence"]?.stringValue == "confirmed")
    #expect(run["closingReason"]?.stringValue == "runtime_restarted")
    #expect(data(call(again, c, "run.list"))?["runs"]?.arrayValue?.count == 1)
}
