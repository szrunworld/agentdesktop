import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// PR4: inbox.list / show / resolve and run.reconcile. RT-19 and E2E-08
// (docs/plan/08): a reconciliation only appends; the original outcome stays
// unknown; the same requestId still answers unknown and sends nothing; a new
// action takes a new requestId. HB-12: another client's items are not_found.

/// An act whose delivery is unknown, on its own one-action Run; its runId.
private func unknownAct(_ sc: Scene, id: String) throws -> String {
    sc.platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    let r = act(sc, clickContinue, id: id)
    #expect(code(r) == "action_delivery_unknown")
    guard case let .failure(e) = r.result else { throw CancellationError() }
    return try #require(e.details?["receipt"]?["runId"]?.stringValue)
}

private func items(_ s: RuntimeService, _ c: ConnectionState, _ params: String = "{}") throws -> [JSONValue] {
    let page = try #require(data(call(s, c, "inbox.list", params: params)))
    #expect(contract.validate(page, "InboxList").isEmpty, "\(page.encoded())")
    return page["items"]?.arrayValue ?? []
}

private func reconcile(_ s: RuntimeService, _ c: ConnectionState, run: String, action: String, verdict: String,
                       revision: Int, id: String = RuntimeRequest.newId(), extra: String = "") -> RuntimeResponse {
    call(s, c, "run.reconcile", id: id,
         params: #"{"runId":"\#(run)","actionRequestId":"\#(action)","verdict":"\#(verdict)","expectedRevision":\#(revision)\#(extra)}"#)
}

/// A Run of `clientId` with one action whose delivery is unknown, written
/// into the store as the act path writes it.
@discardableResult
private func storedUnknownRun(_ s: RuntimeService, clientId: String?, desktopId: String = "d_other", requestId: String) -> String {
    let runId = DesktopRegistry.newId(prefix: "run")
    let at = Timestamp.string(Date())
    s.runs.create(RunRecord(runId: runId, kind: "act", origin: .agentHub, ownership: clientId == nil ? .platform : .externalClient,
                            lifetime: clientId == nil ? .platformDurable : .connectionScoped, clientId: clientId, connectionId: nil,
                            sessionId: "ses_x", desktopId: desktopId, phase: .ended, outcome: .unknown, quiescence: .confirmed,
                            closingReason: "completed", revision: 3, createdAt: at, endedAt: at, receipts: ["rcpt_x"], unknownActions: 1))
    s.runs.appendEvent(runId, "action.accepted", .obj([("requestId", .string(requestId)), ("kind", .string("type"))]))
    s.runs.appendEvent(runId, "action.dispatched", .obj([("requestId", .string(requestId))]))
    s.runs.appendEvent(runId, "action.unknown", .obj([("receipt", .obj([
        ("receiptId", .string("rcpt_x")), ("requestId", .string(requestId)),
        ("reason", .obj([("code", .string("action_delivery_unknown")), ("message", .string("typed: secret-canary"))])),
    ]))]))
    return runId
}

@Test func e2e08_reconcilingAnUnknownOnlyAppendsAndNeverResends() throws {
    let sc = try scene()
    let runId = try unknownAct(sc, id: "lost-1")
    let before = try #require(sc.s.runs.find(runId))
    #expect(before.phase == .ended && before.outcome == .unknown)

    // The Inbox shows it, open, with the action but not what was sent.
    let open = try items(sc.s, sc.c)
    #expect(open.count == 1)
    let item = try #require(open.first)
    #expect(item["kind"]?.stringValue == "unknown_reference" && item["state"]?.stringValue == "open")
    #expect(item["action"]?["requestId"]?.stringValue == "lost-1" && item["action"]?["kind"]?.stringValue == "click")
    #expect(item["action"]?["reasonCode"]?.stringValue == "action_delivery_unknown")
    #expect(item["revision"]?.intValue == 0)
    let inboxId = try #require(item["inboxId"]?.stringValue)

    // still_unknown appends and keeps it open.
    let first = try #require(data(reconcile(sc.s, sc.c, run: runId, action: "lost-1", verdict: "still_unknown", revision: 0)))
    #expect(contract.validate(first, "RunReconciliation").isEmpty, "\(first.encoded())")
    #expect(first["item"]?["state"]?.stringValue == "open" && first["item"]?["revision"]?.intValue == 1)

    // executed resolves it; the Run's outcome stays unknown.
    let done = try #require(data(reconcile(sc.s, sc.c, run: runId, action: "lost-1", verdict: "executed", revision: 1,
                                           extra: #","note":"saw it in the app","evidenceRefs":["obs_1"]"#)))
    #expect(done["run"]?["outcome"]?.stringValue == "unknown")
    #expect(done["item"]?["state"]?.stringValue == "resolved")
    #expect(done["item"]?["resolution"]?["verdict"]?.stringValue == "executed")
    #expect(done["reconciliation"]?["by"]?.stringValue == sc.c.clientId)
    let after = try #require(sc.s.runs.find(runId))
    #expect(after.outcome == .unknown && after.unknownActions == before.unknownActions && after.receipts == before.receipts)

    let shown = try #require(data(call(sc.s, sc.c, "inbox.show", params: #"{"inboxId":"\#(inboxId)"}"#)))
    #expect(contract.validate(shown, "InboxItem").isEmpty, "\(shown.encoded())")
    #expect(shown["reconciliations"]?.arrayValue?.map { $0["verdict"]?.stringValue ?? "" } == ["still_unknown", "executed"])
    #expect(try items(sc.s, sc.c).isEmpty, "no longer open")
    #expect(try items(sc.s, sc.c, #"{"state":"resolved"}"#).count == 1)

    // The same requestId still answers unknown and sends nothing.
    let performed = sc.platform.performed.count
    #expect(code(act(sc, clickContinue, id: "lost-1")) == "action_delivery_unknown")
    #expect(sc.platform.performed.count == performed)
    #expect(data(call(sc.s, sc.c, "request.show", params: #"{"requestId":"lost-1"}"#))?["state"]?.stringValue == "failed")
    // A new action is the caller's, with a new requestId.
    let snap = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    #expect(data(act(sc, clickContinue, snapshot: snap, id: "retry-new-id")) != nil)
    #expect(sc.platform.performed.count == performed + 1)
}

@Test func rt19_reconciliationsAreCompareAndAppendAndIdempotentPerRequestId() throws {
    let sc = try scene()
    let runId = try unknownAct(sc, id: "lost-2")
    let a = reconcile(sc.s, sc.c, run: runId, action: "lost-2", verdict: "executed", revision: 0, id: "rec-a")
    #expect(data(a) != nil)
    // Same requestId, same content: the original answer, nothing appended.
    #expect(data(reconcile(sc.s, sc.c, run: runId, action: "lost-2", verdict: "executed", revision: 0, id: "rec-a")) == data(a))
    // A second decision made on the same old view is refused, not layered.
    let stale = reconcile(sc.s, sc.c, run: runId, action: "lost-2", verdict: "not_executed", revision: 0, id: "rec-b")
    #expect(code(stale) == "conflict")
    if case let .failure(e) = stale.result {
        #expect(e.details?["reason"]?.stringValue == "revision_conflict" && e.details?["currentRevision"]?.intValue == 1)
    }
    #expect(code(reconcile(sc.s, sc.c, run: runId, action: "lost-2", verdict: "not_executed", revision: 0, id: "rec-a")) == "idempotency_conflict")
    #expect(sc.s.runs.reconciliations(runId: runId, requestId: "lost-2").count == 1)
    // The database itself refuses rewriting one.
    #expect(throws: (any Error).self) { try sc.s.runs.db.execute("UPDATE reconciliations SET verdict = 'not_executed'") }
    #expect(throws: (any Error).self) { try sc.s.runs.db.execute("DELETE FROM reconciliations") }
}

@Test func onlyAnUnknownOfAnEndedRunIsReconciled() throws {
    let sc = try scene()
    _ = act(sc, clickContinue, id: "fine-1")
    let okRun = try #require(sc.s.runs.list(RunStore.ListFilter(), after: nil, limit: 1).runs.first?.runId)
    let notUnknown = reconcile(sc.s, sc.c, run: okRun, action: "fine-1", verdict: "executed", revision: 0)
    #expect(code(notUnknown) == "invalid_argument")
    #expect(code(reconcile(sc.s, sc.c, run: okRun, action: "no-such", verdict: "executed", revision: 0)) == "not_found")
    #expect(code(reconcile(sc.s, sc.c, run: "run_nope", action: "fine-1", verdict: "executed", revision: 0)) == "not_found")

    // An exec Run that is still running: not yet.
    let started = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    sc.platform.failNext = PlatformError(.refused, "no answer", beforeDispatch: false)
    #expect(code(act(sc, clickContinue, id: "in-run", runId: started)) == "action_delivery_unknown")
    let early = reconcile(sc.s, sc.c, run: started, action: "in-run", verdict: "executed", revision: 0)
    #expect(code(early) == "conflict")
    if case let .failure(e) = early.result { #expect(e.details?["reason"]?.stringValue == "not_quiescent") }
    #expect(try items(sc.s, sc.c).first?["run"]?["phase"]?.stringValue == "running", "listed while the Run runs")
    _ = call(sc.s, sc.c, "run.cancel", params: #"{"runId":"\#(started)"}"#)
    #expect(data(reconcile(sc.s, sc.c, run: started, action: "in-run", verdict: "not_executed", revision: 0)) != nil)
    #expect(sc.s.runs.find(started)?.outcome == .unknown)
}

@Test func hb12_aPairedClientSeesOnlyItsOwnItemsAndDecidesNone() throws {
    let sc = try scene()
    let ownerRun = try unknownAct(sc, id: "owner-lost")
    let (app, appId) = try pairedConnection(sc.s, capabilities: ["observe", "act", "run"], desktops: [sc.desktop])
    let (other, otherId) = try pairedConnection(sc.s, capabilities: ["run"], name: "other-app")
    let appRun = storedUnknownRun(sc.s, clientId: appId, desktopId: sc.desktop, requestId: "app-lost")
    let otherRun = storedUnknownRun(sc.s, clientId: otherId, requestId: "other-lost")

    let mine = try items(sc.s, app)
    #expect(mine.map { $0["runId"]?.stringValue } == [appRun])
    #expect(try items(sc.s, app, #"{"clientId":"\#(otherId)"}"#).map { $0["runId"]?.stringValue } == [appRun],
            "clientId does not widen a paired client's view")
    #expect(Set(try items(sc.s, sc.c).compactMap { $0["runId"]?.stringValue }) == [ownerRun, appRun, otherRun], "the owner sees all")
    #expect(try items(sc.s, sc.c, #"{"clientId":"\#(otherId)"}"#).map { $0["runId"]?.stringValue } == [otherRun])

    // Another client's item, by id or by runId, does not exist for it.
    let otherItem = try #require(try items(sc.s, other).first?["inboxId"]?.stringValue)
    #expect(code(call(sc.s, app, "inbox.show", params: #"{"inboxId":"\#(otherItem)"}"#)) == "not_found")
    #expect(code(call(sc.s, app, "inbox.list", params: #"{"runId":"\#(otherRun)"}"#)) == "not_found")
    #expect(code(call(sc.s, app, "inbox.show", params: #"{"inboxId":"inb_q_\#(ownerRun)"}"#)) == "not_found")

    // Deciding is the owner's: reconcile and resolve are refused, even on its own.
    for (method, params) in [("run.reconcile", #"{"runId":"\#(appRun)","actionRequestId":"app-lost","verdict":"not_executed","expectedRevision":0}"#),
                             ("inbox.resolve", #"{"inboxId":"\#(mine.first?["inboxId"]?.stringValue ?? "")","resolution":"cancel_run","expectedRevision":0}"#)] {
        let r = call(sc.s, app, method, params: params)
        #expect(code(r) == "permission_denied", "\(method)")
        if case let .failure(e) = r.result { #expect(e.details?["reason"]?.stringValue == "owner_only") }
    }
    #expect(sc.s.runs.reconciliations(runId: appRun, requestId: "app-lost").isEmpty)

    // The client sees the owner's verdict on its action, not the owner's notes.
    _ = reconcile(sc.s, sc.c, run: appRun, action: "app-lost", verdict: "executed", revision: 0,
                  extra: #","note":"private owner note","evidenceRefs":["obs_9"]"#)
    let id = try #require(mine.first?["inboxId"]?.stringValue)
    let seen = try #require(data(call(sc.s, app, "inbox.show", params: #"{"inboxId":"\#(id)"}"#)))
    #expect(seen["reconciliations"]?.arrayValue?.first?["verdict"]?.stringValue == "executed")
    #expect(!seen.encoded().contains("private owner note") && !seen.encoded().contains("obs_9"))
    #expect(data(call(sc.s, sc.c, "inbox.show", params: #"{"inboxId":"\#(id)"}"#))?.encoded().contains("private owner note") == true)
    // Nothing the action carried leaks into the item (only the reason's code).
    #expect(!seen.encoded().contains("secret-canary"))

    // Without the run capability: no Inbox.
    let (observer, _) = try pairedConnection(sc.s, capabilities: ["observe"], desktops: [sc.desktop], name: "observer")
    #expect(code(call(sc.s, observer, "inbox.list")) == "grant_missing")
    _ = other
}

@Test func aWaitingUnitRunIsAQuestionTheOwnerResolvesByStoppingIt() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    let runId = try #require(data(await offPool(s, c, "unit.run", params: unitParams(d)))?["runId"]?.stringValue)
    executor.lastSink?.finished(.needsInput(reason: "login_required"))
    let q = try #require(try items(s, c, #"{"kind":"question"}"#).first)
    #expect(q["state"]?.stringValue == "open" && q["question"]?["reason"]?.stringValue == "login_required")
    #expect(q["run"]?["phase"]?.stringValue == "waiting_input")
    let inboxId = try #require(q["inboxId"]?.stringValue)
    let rev = try #require(q["revision"]?.intValue)

    #expect(code(call(s, c, "inbox.resolve", params: #"{"inboxId":"\#(inboxId)","resolution":"cancel_run","expectedRevision":\#(rev + 7)}"#)) == "conflict")
    let resolved = try #require(data(call(s, c, "inbox.resolve", params: #"{"inboxId":"\#(inboxId)","resolution":"cancel_run","expectedRevision":\#(rev)}"#)))
    #expect(contract.validate(resolved, "InboxResolution").isEmpty, "\(resolved.encoded())")
    #expect(resolved["item"]?["state"]?.stringValue == "resolved")
    #expect(resolved["item"]?["resolution"]?["how"]?.stringValue == "run_cancelled")
    let ended = try #require(s.runs.find(runId))
    #expect(ended.phase == .ended && ended.outcome == .cancelled && ended.closingReason == "inbox_cancel")
    let again = call(s, c, "inbox.resolve", params: #"{"inboxId":"\#(inboxId)","resolution":"cancel_run","expectedRevision":\#(ended.revision)}"#)
    #expect(code(again) == "conflict")
    if case let .failure(e) = again.result { #expect(e.details?["reason"]?.stringValue == "already_resolved") }
    #expect(try items(s, c).isEmpty)
}

@Test func anUnknownItemIsNotResolvedThroughInboxResolve() throws {
    let sc = try scene()
    _ = try unknownAct(sc, id: "lost-3")
    let id = try #require(try items(sc.s, sc.c).first?["inboxId"]?.stringValue)
    let r = call(sc.s, sc.c, "inbox.resolve", params: #"{"inboxId":"\#(id)","resolution":"cancel_run","expectedRevision":0}"#)
    #expect(code(r) == "invalid_argument")
    if case let .failure(e) = r.result { #expect(e.details?["reason"]?.stringValue == "use_run_reconcile") }
}

@Test func inboxPagesAreCompleteWithoutRepeats() throws {
    let sc = try scene()
    var expected: [String] = []
    for i in 0..<5 { expected.append(storedUnknownRun(sc.s, clientId: nil, requestId: "p-\(i)")) }
    var seen: [String] = []
    var cursor: String?
    repeat {
        let extra = cursor.map { #","cursor":"\#($0)""# } ?? ""
        let page = try #require(data(call(sc.s, sc.c, "inbox.list", params: #"{"limit":2\#(extra)}"#)))
        seen += page["items"]?.arrayValue?.compactMap { $0["runId"]?.stringValue } ?? []
        cursor = page["next"]?.stringValue
    } while cursor != nil
    #expect(seen.count == 5 && Set(seen) == Set(expected))
    #expect(code(call(sc.s, sc.c, "inbox.list", params: #"{"cursor":"nonsense"}"#)) == "invalid_argument")
}

@Test func aRunWithAnUnreconciledActionOutlivesTheRetention() throws {
    let dir = NSTemporaryDirectory() + "adt-inbox-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runs.sqlite"
    let old = Date().addingTimeInterval(-30 * 86400)
    func run(_ id: String, unknown: Int) -> RunRecord {
        RunRecord(runId: id, kind: "act", origin: .agentHub, ownership: .externalClient, lifetime: .connectionScoped,
                  clientId: "app:x", connectionId: nil, sessionId: "ses_x", desktopId: "d_x", phase: .ended,
                  outcome: unknown > 0 ? .unknown : .success, quiescence: .confirmed, closingReason: "completed", revision: 2,
                  createdAt: Timestamp.string(old), endedAt: Timestamp.string(old), receipts: [], unknownActions: unknown)
    }
    do {
        let store = try RunStore(path: path, now: { old })
        store.create(run("run_plain", unknown: 0))
        store.create(run("run_open", unknown: 1))
        store.create(run("run_settled", unknown: 1))
        for id in ["run_open", "run_settled"] {
            store.appendEvent(id, "action.unknown", .obj([("receipt", .obj([("requestId", .string("a-\(id)"))]))]))
        }
        _ = try store.appendReconciliation(runId: "run_settled", requestId: "a-run_settled", expectedRevision: 0, verdict: .notExecuted,
                                           source: .operatorAttestation, note: nil, evidenceRefs: [], by: "local:1",
                                           reconcileRequestId: "r1")
    }
    let reopened = try RunStore(path: path)
    #expect(reopened.find("run_plain") == nil && reopened.find("run_settled") == nil)
    #expect(reopened.find("run_open") != nil, "kept until reconciled")
    #expect(!reopened.events("run_open", after: 0, limit: 10).isEmpty)
    #expect(reopened.reconciliations(runId: "run_settled", requestId: "a-run_settled").count == 1, "reconciliations stay")
}

@Test func theDesktopStopsShowingUnknownOnceItsActionIsSettled() throws {
    let sc = try scene()
    let runId = try unknownAct(sc, id: "lost-4")
    func state() -> String? { data(call(sc.s, sc.c, "desktop.show", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["control"]?["state"]?.stringValue }
    #expect(state() == "unknown")
    _ = reconcile(sc.s, sc.c, run: runId, action: "lost-4", verdict: "still_unknown", revision: 0)
    #expect(state() == "unknown")
    _ = reconcile(sc.s, sc.c, run: runId, action: "lost-4", verdict: "executed", revision: 1)
    #expect(state() != "unknown")
    #expect(sc.s.runs.find(runId)?.outcome == .unknown)
}
