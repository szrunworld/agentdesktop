import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// PR2-2: act, control leases, stop path, unknown outcomes, wait.

struct Scene {
    let platform: FakePlatform
    let s: RuntimeService
    let c: ConnectionState
    let desktop: String
    let session: String
    let snapshot: String
}

func scene(_ platform: FakePlatform = FakePlatform(), backend: FixedBackend = FixedBackend(),
           ledger: RequestLedger? = nil, runs: RunStore? = nil) throws -> Scene {
    let s = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: backend, platform: platform, ledger: ledger, runs: runs); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; s.socketLaunchRequiresGrant = false; s.socketDiscoveryRequiresGrant = false; s.socketGuiRunRequiresGrant = false; s.socketsSeeOnlyTheirOwn = false; s.socketExtensionsAreReadOnly = false; return s }()
    let c = handshaken(s)
    let d = try created(s, c)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let snap = try #require(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#))?["snapshotId"]?.stringValue)
    return Scene(platform: platform, s: s, c: c, desktop: d, session: sid, snapshot: snap)
}

func act(_ sc: Scene, _ action: String, snapshot: String? = nil, id: String = RuntimeRequest.newId(),
         runId: String? = nil, on conn: ConnectionState? = nil, deadline: String? = nil) -> RuntimeResponse {
    var ctx = #"{"sessionId":"\#(sc.session)""#
    if let runId { ctx += #","runId":"\#(runId)""# }
    ctx += "}"
    let dl = deadline.map { #","deadline":"\#($0)""# } ?? ""
    let line = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(id)","method":"act","context":\#(ctx)\#(dl),"params":{"snapshotId":"\#(snapshot ?? sc.snapshot)","action":\#(action)}}"#
    return answer(sc.s, line, conn ?? sc.c)
}

let clickContinue = #"{"kind":"click","target":{"elementRef":"el_0"}}"#

@Test func aClickOnAnElementProducesAReceiptOnceAndARecordedRun() throws {
    let sc = try scene()
    let r = act(sc, clickContinue, id: "click-1")
    let receipt = try #require(data(r))
    #expect(contract.validate(receipt, "ActionReceipt").isEmpty, "\(receipt.encoded())")
    #expect(receipt["delivery"]?.stringValue == "dispatched")
    #expect(receipt["execution"]?.stringValue == "completed")
    #expect(receipt["target"]?["elementRef"]?.stringValue == "el_0")
    #expect(sc.platform.performed.first?.elementIndex == 0)
    // A retry from another connection gets the same receipt; no second click.
    #expect(data(act(sc, clickContinue, id: "click-1", on: handshaken(sc.s))) == receipt)
    #expect(sc.platform.performed.count == 1)

    let runId = try #require(receipt["runId"]?.stringValue)
    let run = try #require(data(call(sc.s, sc.c, "run.show", params: #"{"runId":"\#(runId)"}"#)))
    #expect(contract.validate(run, "Run").isEmpty)
    #expect(run["phase"]?.stringValue == "ended" && run["outcome"]?.stringValue == "success")
    #expect(run["quiescence"]?.stringValue == "confirmed")
    #expect(run["ownership"]?.stringValue == "external_client" && run["lifetime"]?.stringValue == "connection_scoped")
    #expect(run["receipts"] == .array([receipt["receiptId"]!]))
    let events = try #require(data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(runId)"}"#)))
    #expect(contract.validate(events, "RunEvents").isEmpty)
    let types = events["events"]?.arrayValue?.compactMap { $0["type"]?.stringValue } ?? []
    #expect(types == ["run.started", "action.accepted", "action.dispatched", "action.completed", "run.finishing", "run.quiescent", "run.ended"])
    let later = data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(runId)","after":4}"#))
    #expect(later?["events"]?.arrayValue?.first?["sequence"]?.intValue == 5)
}

@Test func anImagePointIsMappedThroughTheSnapshotTransform() throws {
    let sc = try scene()
    // The image is the bound window at (2100,100) 400x300, scale 2 (G0).
    let r = try #require(data(act(sc, #"{"kind":"click","target":{"imagePoint":{"x":100,"y":100}}}"#)))
    #expect(r["target"]?["point"]?["x"]?.doubleValue == 2150)
    #expect(r["target"]?["point"]?["y"]?.doubleValue == 150)
    #expect(sc.platform.performed.last?.point?.x == 2150)
    #expect(code(act(sc, #"{"kind":"click","target":{"imagePoint":{"x":900,"y":10}}}"#)) == "invalid_target")
    #expect(code(act(sc, #"{"kind":"click","target":{"imagePoint":{"x":99999,"y":10}}}"#)) == "invalid_target")
    #expect(code(act(sc, #"{"kind":"click","target":{"elementRef":"el_42"}}"#)) == "invalid_target")
    #expect(sc.platform.performed.count == 1)
}

@Test func actionsAgainstAStaleSnapshotAreRefusedWithoutInput() throws {
    let sc = try scene()
    #expect(code(act(sc, clickContinue, snapshot: "obs_unknown")) == "stale_observation")
    // A newer read of the window renumbers its elements.
    let newer = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    let r = act(sc, clickContinue)
    #expect(code(r) == "stale_observation")
    if case let .failure(e) = r.result { #expect(e.notSent == true) }
    // Image points of the older snapshot still hold: the window is unchanged.
    #expect(data(act(sc, #"{"kind":"click","target":{"imagePoint":{"x":300,"y":300}}}"#)) != nil)
    // The user moves the window: geometry no longer matches.
    sc.platform.moveWindow(11, by: 5)
    #expect(code(act(sc, clickContinue, snapshot: newer)) == "stale_observation")
    // Rebinding moves the generation on.
    _ = call(sc.s, sc.c, "window.bind", params: #"{"desktopId":"\#(sc.desktop)","pid":101}"#)
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#, snapshot: newer)) == "stale_observation")
    #expect(sc.platform.performed.count == 1)
    // Without a session: refused outright.
    let bare = answer(sc.s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"x1","method":"act","context":{"desktopId":"\#(sc.desktop)"},"params":{"snapshotId":"\#(newer)","action":{"kind":"key","key":"a"}}}"#, sc.c)
    #expect(code(bare) == "schema_invalid")
}

@Test func anExecRunHoldsTheDesktopAndItsOwnerLossStopsIt() throws {
    let sc = try scene()
    let owner = handshaken(sc.s)
    let start = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(contract.validate(start, "RunStart").isEmpty)
    let runId = try #require(start["run"]?["runId"]?.stringValue)
    let token = try #require(start["attachToken"]?.stringValue)

    // Someone else's one-shot act: the Desktop is controlled.
    #expect(code(act(sc, clickContinue)) == "control_busy")
    // A child connection joins with the token and acts in the Run.
    let child = handshaken(sc.s)
    #expect(code(call(sc.s, child, "run.attach", params: #"{"runId":"\#(runId)","token":"\#(String(repeating: "0", count: 64))"}"#)) == "permission_denied")
    #expect(code(act(sc, clickContinue, runId: runId, on: child)) == "permission_denied")
    #expect(data(call(sc.s, child, "run.attach", params: #"{"runId":"\#(runId)","token":"\#(token)"}"#)) != nil)
    #expect(data(act(sc, clickContinue, runId: runId, on: child))?["runId"]?.stringValue == runId)
    #expect(code(call(sc.s, sc.c, "desktop.destroy", params: #"{"desktopId":"\#(sc.desktop)"}"#)) == "conflict")

    // The owner goes away: no more input in this Run.
    sc.s.connectionClosed(owner)
    let run = try #require(data(call(sc.s, sc.c, "run.show", params: #"{"runId":"\#(runId)"}"#)))
    #expect(run["phase"]?.stringValue == "ended" && run["outcome"]?.stringValue == "cancelled")
    #expect(run["quiescence"]?.stringValue == "confirmed")
    #expect(run["closingReason"]?.stringValue == "owner_lost")
    let fresh = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    #expect(code(act(sc, clickContinue, snapshot: fresh, runId: runId, on: child)) == "run_not_active")
    #expect(sc.platform.performed.count == 1)
    // The Desktop is free again.
    #expect(data(act(sc, clickContinue, snapshot: fresh)) != nil)
}

@Test func cancelIsAcceptedAtOnceAndQuiescentOnlyAfterTheActionInFlight() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let owner = handshaken(sc.s)
    let start = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let runId = try #require(start["run"]?["runId"]?.stringValue)
    platform.gate = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var r: RuntimeResponse? }
    let box = Box()
    DispatchQueue.global().async {
        box.r = act(sc, clickContinue, runId: runId, on: owner)
        done.signal()
    }
    platform.entered.wait()  // the click is in flight
    let cancel = try #require(data(call(sc.s, sc.c, "run.cancel", id: "cancel-1", params: #"{"runId":"\#(runId)"}"#)))
    #expect(contract.validate(cancel, "CancelReceipt").isEmpty)
    #expect(cancel["execution"]?["phase"]?.stringValue == "stopping")
    #expect(cancel["execution"]?["quiescence"]?.stringValue == "pending")
    #expect(code(call(sc.s, sc.c, "run.wait", params: #"{"runId":"\#(runId)","timeoutMs":100}"#)) == "wait_timeout")
    platform.gate?.signal()
    done.wait()
    #expect(data(box.r!)?["delivery"]?.stringValue == "dispatched", "the action in flight finishes")
    let after = try #require(data(call(sc.s, sc.c, "run.wait", params: #"{"runId":"\#(runId)","timeoutMs":2000}"#)))
    #expect(after["phase"]?.stringValue == "ended" && after["outcome"]?.stringValue == "cancelled")
    #expect(after["quiescence"]?.stringValue == "confirmed")
    platform.gate = nil
    // A new action after the cancel is refused before anything is sent:
    // run_not_active with notSent, whether the Run is stopping or ended.
    let afterCancel = act(sc, clickContinue, runId: runId, on: owner)
    #expect(code(afterCancel) == "run_not_active")
    #expect(failure(afterCancel)?.notSent == true)
    // The same cancel requestId replays; a cancel of an ended Run says so.
    #expect(data(call(sc.s, sc.c, "run.cancel", id: "cancel-1", params: #"{"runId":"\#(runId)"}"#)) == cancel)
    let late = try #require(data(call(sc.s, sc.c, "run.cancel", params: #"{"runId":"\#(runId)"}"#)))
    #expect(late["alreadyTerminal"] == .bool(true))
    #expect(late["execution"]?["outcome"]?.stringValue == "cancelled")
}

@Test func failuresSayWhetherInputMayHaveBeenSent() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.failNext = PlatformError(.notFound, "no element 0 in the window; run state again", beforeDispatch: true)
    let before = act(sc, clickContinue, id: "f1")
    #expect(code(before) == "execution_failed")
    if case let .failure(e) = before.result {
        #expect(e.notSent == true)
        #expect(e.details?["receipt"]?["delivery"]?.stringValue == "not_dispatched")
        #expect(contract.validate(try #require(e.details?["receipt"]), "ActionReceipt").isEmpty)
    }
    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    let mid = act(sc, clickContinue, id: "f2")
    #expect(code(mid) == "action_delivery_unknown")
    if case let .failure(e) = mid.result { #expect(e.details?["receipt"]?["delivery"]?.stringValue == "unknown") }
    // Asking again never re-sends: the recorded outcome comes back.
    #expect(code(act(sc, clickContinue, id: "f2")) == "action_delivery_unknown")
    #expect(platform.performed.isEmpty)
    #expect(data(call(sc.s, sc.c, "request.show", params: #"{"requestId":"f2"}"#))?["state"]?.stringValue == "failed")
}

@Test func aPassedDeadlineSendsNothing() throws {
    let sc = try scene()
    #expect(code(act(sc, clickContinue, deadline: "2020-01-01T00:00:00Z")) == "deadline_exceeded")
    #expect(sc.platform.performed.isEmpty)
}

@Test func afterARestartUndispatchedActsFailAndDispatchedOnesAreUnknown() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    do {
        let ledger = try RequestLedger(path: dir + "/requests.sqlite")
        let runs = try RunStore(path: dir + "/runs.sqlite")
        _ = try ledger.begin(caller: getuid(), RuntimeRequest(requestId: "queued", method: "act", params: .obj([])))
        _ = try ledger.begin(caller: getuid(), RuntimeRequest(requestId: "sent", method: "act", params: .obj([])))
        try ledger.markDispatching(caller: getuid(), requestId: "sent")
        runs.create(testRun("run_x", lifetime: .connectionScoped))
        // A durable Run whose action crossed its delivery boundary unanswered.
        runs.create(testRun("run_y", lifetime: .platformDurable))
        runs.appendEvent("run_y", "action.dispatched", .obj([("requestId", .string("sent-y"))]))
    }
    let ledger = try RequestLedger(path: dir + "/requests.sqlite")
    #expect(try ledger.record(caller: getuid(), requestId: "queued")?.state == .failed)
    #expect(try ledger.record(caller: getuid(), requestId: "queued")?.outcome?["error"]?["details"]?["delivery"]?.stringValue == "not_dispatched")
    #expect(try ledger.record(caller: getuid(), requestId: "sent")?.state == .unknown)
    let runs = try RunStore(path: dir + "/runs.sqlite")
    let x = try #require(runs.find("run_x"))
    #expect(x.phase == .ended && x.quiescence == .confirmed && x.outcome == .cancelled)
    #expect(x.closingReason == "runtime_restarted")
    let y = try #require(runs.find("run_y"))
    #expect(y.phase == .ended && y.quiescence == .confirmed && y.outcome == .unknown, "never redone, never called success")
    #expect(y.unknownActions == 1)
}

@Test func waitPollsForAnElementCondition() throws {
    let sc = try scene()
    let ok = try #require(data(call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","role":"AXButton","label":"继续"},"timeoutMs":1000}"#,
                                    context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(contract.validate(ok, "WaitResult").isEmpty)
    #expect(ok["matches"]?.arrayValue?.first?["id"]?.stringValue == "el_0")
    // The wait's own read is the latest: its refs work for act.
    let snap = try #require(ok["snapshotId"]?.stringValue)
    #expect(data(act(sc, clickContinue, snapshot: snap)) != nil)
    let start = Date()
    #expect(code(call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementAbsent","labelContains":"名字"},"timeoutMs":300}"#,
                      context: #"{"sessionId":"\#(sc.session)"}"#)) == "wait_timeout")
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func finishEndsAnExecRunAndOnlyItsOwnerMayFinishIt() throws {
    let sc = try scene()
    let owner = handshaken(sc.s)
    let runId = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    #expect(code(call(sc.s, sc.c, "run.finish", params: #"{"runId":"\#(runId)"}"#)) == "permission_denied")
    let r = try #require(data(call(sc.s, owner, "run.finish", params: #"{"runId":"\#(runId)","exitCode":0}"#)))
    #expect(r["phase"]?.stringValue == "ended" && r["outcome"]?.stringValue == "success")
    #expect(r["closingReason"]?.stringValue == "exit 0")
    #expect(data(call(sc.s, sc.c, "runtime.status"))?["runs"]?.intValue == 0)
}


func testRun(_ id: String, lifetime: RunRecord.Lifetime) -> RunRecord {
    let durable = lifetime == .platformDurable
    return RunRecord(runId: id, kind: durable ? "unit" : "exec", origin: durable ? .guiExplorer : .agentHub,
                     ownership: durable ? .platform : .externalClient, lifetime: lifetime,
                     clientId: durable ? nil : "local:\(getuid())", connectionId: durable ? nil : "conn_test",
                     sessionId: "s", desktopId: "d", phase: .running, outcome: nil, quiescence: .notConfirmed,
                     closingReason: nil, revision: 1, createdAt: Timestamp.string(Date()), endedAt: nil, receipts: [], unknownActions: 0)
}

// 2ndscreen-af (BOSS M4 L2): a run.attach from a second connection can
// cancel; a new action then is run_not_active with notSent while the Run
// stops and after it ended; a Run this connection neither owns nor joined
// is refused with notSent too.
@Test func aCancelledRunRefusesNewActionsBeforeSendingAnything() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let owner = handshaken(sc.s)
    let start = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let runId = try #require(start["run"]?["runId"]?.stringValue)
    let token = try #require(start["attachToken"]?.stringValue)
    let second = handshaken(sc.s)
    #expect(data(call(sc.s, second, "run.attach", params: #"{"runId":"\#(runId)","token":"\#(token)"}"#)) != nil)
    #expect(data(call(sc.s, second, "run.cancel", params: #"{"runId":"\#(runId)"}"#)) != nil)
    let before = platform.performed.count
    for conn in [owner, second] {
        let r = act(sc, clickContinue, runId: runId, on: conn)
        #expect(code(r) == "run_not_active")
        #expect(failure(r)?.notSent == true)
    }
    let stranger = handshaken(sc.s)
    let refused = act(sc, clickContinue, runId: runId, on: stranger)
    #expect(code(refused) == "permission_denied")
    #expect(failure(refused)?.notSent == true)
    #expect(platform.performed.count == before)
}
