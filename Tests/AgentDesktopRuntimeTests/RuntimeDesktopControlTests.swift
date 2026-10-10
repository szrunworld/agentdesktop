import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A5: Desktop.control and the owner's desktop.stop / takeover / handback.
// Test names carry the regression IDs of docs/plan/08 (RT-13…RT-15).

/// A second Desktop B with its own app (Notes, launched there), bound and
/// observed, so actions on A and B never share a window.
private struct Second {
    let desktop: String
    let session: String
    let snapshot: String
}

/// A backend that also lists the Notes window FakePlatform launches.
private func withNotes() -> FixedBackend {
    let b = FixedBackend()
    b.opened.windows = [WindowSummary(windowId: 31, process: ProcessIdentity(pid: 303, startedAt: "2026-10-08T01:00:00.000Z"),
                                      appName: "Notes", bundleId: "com.apple.Notes", title: "备忘录",
                                      frame: Rect(x: 3500, y: 100, width: 400, height: 300), onScreen: true)]
    return b
}

private func second(_ sc: Scene) throws -> Second {
    let d = try created(sc.s, sc.c)
    _ = call(sc.s, sc.c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.Notes"}"#)
    _ = call(sc.s, sc.c, "window.bind", params: #"{"desktopId":"\#(d)","pid":303}"#)
    let sid = try #require(data(call(sc.s, sc.c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let snap = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sid)"}"#))?["snapshotId"]?.stringValue)
    return Second(desktop: d, session: sid, snapshot: snap)
}

private func actOn(_ sc: Scene, _ b: Second, runId: String? = nil, on c: ConnectionState? = nil) -> RuntimeResponse {
    let run = runId.map { #","runId":"\#($0)""# } ?? ""
    return call(sc.s, c ?? sc.c, "act", params: #"{"snapshotId":"\#(b.snapshot)","action":{"kind":"click","target":{"imagePoint":{"x":20,"y":20}}}}"#,
                context: #"{"sessionId":"\#(b.session)"\#(run)}"#)
}

private func control(_ sc: Scene, _ desktop: String, on c: ConnectionState? = nil) -> JSONValue? {
    data(call(sc.s, c ?? sc.c, "desktop.show", params: #"{"desktopId":"\#(desktop)"}"#))?["control"]
}

/// Desktop.control read directly: desktop.show waits for the Desktop's lock,
/// which an action in flight holds.
private func liveControl(_ sc: Scene, _ desktop: String) -> JSONValue? {
    sc.s.desktops.find(desktop).map { sc.s.controlJSON($0, for: nil) }
}

private func reason(_ r: RuntimeResponse) -> String? { errorDetails(r)?["reason"]?.stringValue }

private func onThread(_ body: @escaping @Sendable () -> Void) -> DispatchSemaphore {
    let done = DispatchSemaphore(value: 0)
    Thread { body(); done.signal() }.start()
    return done
}

private final class Box: @unchecked Sendable { var response: RuntimeResponse? }

@Test func controlIsReadyRunningThenReadyAgainAndMatchesTheSchema() throws {
    let sc = try scene()
    let ready = try #require(control(sc, sc.desktop))
    #expect(ready["state"]?.stringValue == "ready" && ready["actionCount"]?.intValue == 0)
    let list = try #require(data(call(sc.s, sc.c, "desktop.list")))
    #expect(contract.validate(list, "DesktopList").isEmpty, "\(list.encoded())")
    let runId = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    _ = act(sc, clickContinue, runId: runId)
    let running = try #require(control(sc, sc.desktop))
    #expect(running["state"]?.stringValue == "running" && running["controllerRunId"]?.stringValue == runId)
    #expect(running["actionCount"]?.intValue == 1 && running["clientId"]?.stringValue == "local:\(getuid())")
    _ = call(sc.s, sc.c, "run.finish", params: #"{"runId":"\#(runId)"}"#)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "ready", "a finished Run leaves the Desktop ready")
}

@Test func rt13_stoppingDesktopAStopsItsRunWhileBKeepsActing() throws {
    let platform = FakePlatform()
    let sc = try scene(platform, backend: withNotes())
    let b = try second(sc)
    let owner = handshaken(sc.s)
    let runA = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let runB = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(b.session)"}"#))?["run"]?["runId"]?.stringValue)

    // An action of A in flight when A is stopped.
    platform.gate = DispatchSemaphore(value: 0)
    let inFlight = onThread { _ = act(sc, clickContinue, runId: runA, on: owner) }
    platform.entered.wait()
    let receipt = try #require(data(call(sc.s, sc.c, "desktop.stop", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(contract.validate(receipt, "DesktopStopReceipt").isEmpty, "\(receipt.encoded())")
    #expect(receipt["accepted"] == .bool(true))
    #expect(receipt["run"]?["runId"]?.stringValue == runA)
    #expect(receipt["run"]?["phase"]?.stringValue == "stopping" && receipt["run"]?["quiescence"]?.stringValue == "pending",
            "accepted is not stopped: the action in flight still runs")
    #expect(receipt["control"]?["state"]?.stringValue == "stopping")

    // A takes no new Run; B's Run keeps acting meanwhile.
    let refused = call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(refused) == "input_disabled" && reason(refused) == "desktop_stopped")
    // B acts while A's action is still in flight (it keeps waiting on its gate).
    let held = try #require(platform.gate)
    platform.gate = nil
    #expect(data(actOn(sc, b, runId: runB, on: owner))?["delivery"]?.stringValue == "dispatched", "B is untouched")
    #expect(control(sc, b.desktop)?["state"]?.stringValue == "running")
    #expect(runJSON(sc, runA)?["phase"]?.stringValue == "stopping")
    held.signal()
    inFlight.wait()

    let ended = try #require(runJSON(sc, runA))
    #expect(ended["phase"]?.stringValue == "ended" && ended["outcome"]?.stringValue == "cancelled")
    #expect(ended["closingReason"]?.stringValue == "desktop_stop")
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "stopped")
    // A one-shot act on A is refused too, before anything is sent.
    let before = platform.performed.count
    let oneShot = act(sc, clickContinue)
    #expect(code(oneShot) == "input_disabled" && reason(oneShot) == "desktop_stopped")
    #expect(platform.performed.count == before)
}

@Test func rt14_duringATakeoverAgentsAreRefusedAndTheDesktopIsManual() throws {
    let platform = FakePlatform()
    let sc = try scene(platform, backend: withNotes())
    let b = try second(sc)
    let agent = handshaken(sc.s)
    let runA = try #require(data(call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)

    let taken = try #require(data(call(sc.s, sc.c, "desktop.takeover", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(contract.validate(taken, "DesktopTakeover").isEmpty, "\(taken.encoded())")
    let userRun = try #require(taken["run"])
    #expect(userRun["origin"]?.stringValue == "user" && userRun["ownership"]?.stringValue == "platform")
    #expect(userRun["lifetime"]?.stringValue == "platform_durable" && userRun["phase"]?.stringValue == "running")
    #expect(taken["stopped"]?["runId"]?.stringValue == runA)
    #expect(taken["control"]?["state"]?.stringValue == "manual")
    #expect(taken["control"]?["controllerRunId"] == userRun["runId"])
    let stopped = try #require(runJSON(sc, runA))
    #expect(stopped["phase"]?.stringValue == "ended" && stopped["closingReason"]?.stringValue == "takeover")

    // The agent's old Run and any new one are refused; nothing is sent.
    let before = platform.performed.count
    #expect(code(act(sc, clickContinue, runId: runA, on: agent)) == "run_not_active")
    let oneShot = act(sc, clickContinue, on: agent)
    #expect(code(oneShot) == "control_busy" && reason(oneShot) == "manual_control")
    let newRun = call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(newRun) == "control_busy" && reason(newRun) == "manual_control")
    #expect(platform.performed.count == before)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "manual")
    // B is not taken over.
    #expect(data(actOn(sc, b, on: agent))?["delivery"]?.stringValue == "dispatched")
    #expect(control(sc, b.desktop)?["state"]?.stringValue == "ready")
    // Taking over again answers the same Run; destroying needs a handback first.
    #expect(data(call(sc.s, sc.c, "desktop.takeover", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["run"]?["runId"] == userRun["runId"])
    #expect(code(call(sc.s, sc.c, "desktop.destroy", params: #"{"desktopId":"\#(sc.desktop)"}"#)) == "conflict")
}

@Test func rt15_handbackEndsTheUsersRunAndNothingObservedBeforeIsReplayed() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let agent = handshaken(sc.s)
    let old = sc.snapshot
    let userRun = try #require(data(call(sc.s, sc.c, "desktop.takeover", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["run"]?["runId"]?.stringValue)

    let back = try #require(data(call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(contract.validate(back, "DesktopHandback").isEmpty, "\(back.encoded())")
    #expect(back["handedBack"] == .bool(true) && back["observationsCleared"] == .bool(true))
    #expect(back["endedRunId"]?.stringValue == userRun)
    #expect(back["control"]?["state"]?.stringValue == "ready")
    let ended = try #require(runJSON(sc, userRun))
    #expect(ended["phase"]?.stringValue == "ended" && ended["outcome"]?.stringValue == "success")
    #expect(ended["closingReason"]?.stringValue == "handback")

    // The snapshot taken before the takeover is gone: nothing is sent on it.
    let before = platform.performed.count
    #expect(code(act(sc, clickContinue, snapshot: old, on: agent)) == "stale_observation")
    #expect(platform.performed.count == before)
    // A new observation works again.
    let fresh = try #require(data(call(sc.s, agent, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    #expect(data(act(sc, clickContinue, snapshot: fresh, on: agent))?["delivery"]?.stringValue == "dispatched")

    // Handing back a Desktop nobody stopped or took over changes nothing.
    let runId = try #require(data(call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let noop = try #require(data(call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(noop["handedBack"] == .bool(false) && noop["observationsCleared"] == .bool(false))
    #expect(data(act(sc, clickContinue, snapshot: fresh, runId: runId, on: agent))?["delivery"]?.stringValue == "dispatched",
            "a running agent keeps its observations")
}

@Test func handbackReopensAStoppedDesktop() throws {
    let sc = try scene()
    _ = call(sc.s, sc.c, "desktop.stop", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "stopped")
    #expect(code(act(sc, clickContinue)) == "input_disabled")
    let back = try #require(data(call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(back["handedBack"] == .bool(true) && back["endedRunId"] == .null)
    #expect(back["control"]?["state"]?.stringValue == "ready")
    let fresh = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    #expect(data(act(sc, clickContinue, snapshot: fresh))?["delivery"]?.stringValue == "dispatched")
}

@Test func aTakeoverWaitsForTheActionInFlightOrSaysTheStopIsPending() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let agent = handshaken(sc.s)
    let runA = try #require(data(call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    platform.gate = DispatchSemaphore(value: 0)
    let inFlight = onThread { _ = act(sc, clickContinue, runId: runA, on: agent) }
    platform.entered.wait()

    // Past its deadline the takeover is accepted but not done: agents stay out.
    let line = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"take-1","method":"desktop.takeover","deadline":"\#(Timestamp.string(Date().addingTimeInterval(0.3)))","params":{"desktopId":"\#(sc.desktop)"}}"#
    let pending = answer(sc.s, line, sc.c)
    #expect(code(pending) == "stop_pending", "\(pending)")
    #expect(errorDetails(pending)?["holderRunId"]?.stringValue == runA)
    if case let .failure(e) = pending.result { #expect(e.notSent != true, "the takeover was accepted") }
    #expect(liveControl(sc, sc.desktop)?["state"]?.stringValue == "stopping")
    let refused = call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(refused) == "control_busy" && reason(refused) == "manual_control")

    // Without a deadline it waits for the action to end, then takes over.
    let box = Box()
    let taking = onThread { box.response = call(sc.s, sc.c, "desktop.takeover", params: #"{"desktopId":"\#(sc.desktop)"}"#) }
    Thread.sleep(forTimeInterval: 0.1)
    platform.gate?.signal()
    inFlight.wait()
    taking.wait()
    let taken = try #require(box.response.flatMap(data))
    #expect(taken["control"]?["state"]?.stringValue == "manual")
    let ended = try #require(runJSON(sc, runA))
    #expect(ended["phase"]?.stringValue == "ended" && ended["closingReason"]?.stringValue == "takeover")
    #expect(ended["receipts"]?.arrayValue?.count == 1, "the action in flight finished and kept its receipt")
}

@Test func onlyTheOwnerStopsTakesOverOrHandsBack() throws {
    let sc = try scene()
    let (app, _) = try pairedConnection(sc.s, capabilities: ["observe", "act", "run", "desktop.manage"], desktops: [sc.desktop])
    for method in ["desktop.stop", "desktop.takeover", "desktop.handback"] {
        let r = call(sc.s, app, method, params: #"{"desktopId":"\#(sc.desktop)"}"#)
        #expect(code(r) == "permission_denied" && reason(r) == "owner_only", "\(method)")
    }
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "ready", "nothing changed")
    // A paired app sees the state of a Desktop someone else controls, not who.
    _ = call(sc.s, sc.c, "desktop.takeover", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    let seen = try #require(control(sc, sc.desktop, on: app))
    #expect(seen["state"]?.stringValue == "manual")
    #expect(seen["controllerRunId"] == nil && seen["clientId"] == nil)
}

@Test func controlTellsDisconnectedAndUnknownApart() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let agent = handshaken(sc.s)
    _ = try #require(data(call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    sc.s.connectionClosed(agent)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "disconnected")
    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    _ = act(sc, clickContinue)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "unknown")
    // The owner hands it back after looking: the unknown Run stays unknown.
    _ = call(sc.s, sc.c, "desktop.stop", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    _ = call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "ready")
    let runs = try #require(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue)
    #expect(runs.contains { $0["outcome"]?.stringValue == "unknown" })
}

// Codex on 2aaf935 (#241, follow-up).

@Test func aTakeoverThatWaitedDoesNotUndoAHandbackMadeMeanwhile() throws {
    let sc = try scene()
    let desk = try #require(sc.s.desktops.find(sc.desktop))
    desk.lock.lock()   // an action in flight holds the Desktop
    let box = Box()
    let taking = onThread { box.response = call(sc.s, sc.c, "desktop.takeover", params: #"{"desktopId":"\#(sc.desktop)"}"#) }
    // The takeover closed the gate and waits for the lock…
    let deadline = Date().addingTimeInterval(5)
    while sc.s.execution.controlFacts(sc.desktop).gate != .manual, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    #expect(sc.s.execution.controlFacts(sc.desktop).gate == .manual)
    // …and a handback reopens the Desktop before it gets it.
    sc.s.execution.openDesktop(sc.desktop)
    desk.lock.unlock()
    taking.wait()
    let r = try #require(box.response)
    #expect(code(r) == "conflict" && reason(r) == "superseded", "\(r)")
    #expect(sc.s.execution.controlFacts(sc.desktop).holder == nil, "no manual Run was started")
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "ready")
}

@Test func handbackClearsADisconnectedOrUnknownDesktopWithoutAStopFirst() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let agent = handshaken(sc.s)
    _ = try #require(data(call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    sc.s.connectionClosed(agent)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "disconnected")
    let back = try #require(data(call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(back["handedBack"] == .bool(true) && back["control"]?["state"]?.stringValue == "ready")

    let fresh = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    _ = act(sc, clickContinue, snapshot: fresh)
    #expect(control(sc, sc.desktop)?["state"]?.stringValue == "unknown")
    #expect(data(call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["control"]?["state"]?.stringValue == "ready")
    // The unknown Run itself stays unknown.
    #expect(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue?.contains { $0["outcome"]?.stringValue == "unknown" } == true)
    // A global stop is not lifted by a handback.
    _ = call(sc.s, sc.c, "runtime.stopAll", params: #"{"scope":"all_platform_runs"}"#)
    let still = try #require(data(call(sc.s, sc.c, "desktop.handback", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(still["handedBack"] == .bool(false) && still["control"]?["state"]?.stringValue == "stopped")
}

@Test func desktopShowReadsControlAfterTheActionInFlightEnded() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let agent = handshaken(sc.s)
    let runId = try #require(data(call(sc.s, agent, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    platform.gate = DispatchSemaphore(value: 0)
    let inFlight = onThread { _ = act(sc, clickContinue, runId: runId, on: agent) }
    platform.entered.wait()
    _ = call(sc.s, sc.c, "desktop.stop", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    let box = Box()
    let showing = onThread { box.response = call(sc.s, sc.c, "desktop.show", params: #"{"desktopId":"\#(sc.desktop)"}"#) }
    Thread.sleep(forTimeInterval: 0.1)   // desktop.show is waiting for the lock
    platform.gate?.signal()
    inFlight.wait()
    showing.wait()
    let shown = try #require(box.response.flatMap(data))
    #expect(shown["control"]?["state"]?.stringValue == "stopped", "not the stopping seen before the wait")
}

// Codex P1 on 6d39332: a stop between the takeover's check and its Run's start.

@Test func aStopThatSlipsInBeforeTheTakeoversRunStandsAndStaysClosed() throws {
    let sc = try scene()
    let x = sc.s.execution
    let (_, previous, serial) = x.closeForTakeover(sc.desktop)
    #expect(previous == nil)
    // The owner stops the Desktop right then (desktop.stop takes no Desktop lock).
    _ = call(sc.s, sc.c, "desktop.stop", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    let session = sc.s.sessions.open(desktopId: sc.desktop, caller: "local:\(getuid())", at: Timestamp.string(Date()))
    // The takeover's Run is refused as superseded, in the same step as the check…
    guard case let .failure(e) = x.startTakeover(session: session, serial: serial) else {
        Issue.record("the takeover's Run started after the stop"); return
    }
    #expect(e.code == "conflict" && e.details?["reason"]?.stringValue == "superseded")
    // …and its failure path does not reopen what the stop closed.
    x.restoreGate(sc.desktop, previous, ifSerial: serial)
    #expect(x.controlFacts(sc.desktop).gate == .stopped)
    #expect(code(act(sc, clickContinue)) == "input_disabled", "agents stay out after the owner's stop")
}

@Test func aTakeoverThatCannotStartItsRunPutsItsOwnGateBack() throws {
    // Nothing changed meanwhile: the gate the takeover closed is undone.
    let sc = try scene()
    let x = sc.s.execution
    let (_, previous, serial) = x.closeForTakeover(sc.desktop)
    x.restoreGate(sc.desktop, previous, ifSerial: serial)
    #expect(x.controlFacts(sc.desktop).gate == nil)
    #expect(data(act(sc, clickContinue))?["delivery"]?.stringValue == "dispatched")
}
