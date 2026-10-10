import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

@Test func aFailedDispatchIntentSendsNothingAndLatchesAdmissionClosed() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/requests.sqlite"
    let ledger = try RequestLedger(path: path)
    let sc = try scene(ledger: ledger)
    let db = try SQLiteDatabase(path: path)
    try db.execute("CREATE TRIGGER reject_dispatch BEFORE UPDATE OF dispatch_started_at ON requests BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END")
    let response = act(sc, clickContinue, id: "audit-before")
    #expect(code(response) == "audit_unavailable")
    if case let .failure(e) = response.result { #expect(e.notSent == true) }
    #expect(sc.platform.performed.isEmpty)
    #expect(sc.s.execution.activeCount == 0)
    #expect(sc.s.execution.inputAdmission == .stopped)
    try db.execute("DROP TRIGGER reject_dispatch")
    #expect(code(call(sc.s, sc.c, "runtime.enableInput")) == "audit_unavailable")
    #expect(code(act(sc, clickContinue, id: "audit-next")) == "audit_unavailable")
    #expect(sc.platform.performed.isEmpty)
    #expect(data(call(sc.s, sc.c, "runtime.status")) != nil)
    let restarted = try RequestLedger(path: path)
    #expect(try restarted.record(caller: "local:\(getuid())", requestId: "audit-before")?.outcome?["error"]?["notSent"] == .bool(true))
}

@Test func aFailedOutcomeWriteIsUnknownAfterRestartAndNeverReplaysInput() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/requests.sqlite"
    let ledger = try RequestLedger(path: path)
    let sc = try scene(ledger: ledger)
    let db = try SQLiteDatabase(path: path)
    try db.execute("CREATE TRIGGER reject_outcome BEFORE UPDATE OF state ON requests BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END")
    let response = act(sc, clickContinue, id: "audit-after")
    #expect(code(response) == "audit_unavailable")
    if case let .failure(e) = response.result { #expect(e.notSent != true) }
    #expect(sc.platform.performed.count == 1)
    #expect(code(act(sc, clickContinue, id: "audit-after")) == "request_acceptance_unknown")
    #expect(sc.platform.performed.count == 1)
    try db.execute("DROP TRIGGER reject_outcome")
    let restarted = try RequestLedger(path: path)
    let record = try #require(try restarted.record(caller: "local:\(getuid())", requestId: "audit-after"))
    #expect(record.state == .unknown)
    if case let .failure(e) = RequestLedger.replay(record) {
        #expect(e.code == "request_acceptance_unknown")
        #expect(e.notSent != true)
    } else { Issue.record("An unsaved delivery cannot replay success") }
}

@Test func aFailedRunDispatchEventRefusesInput() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runs.sqlite"
    let runs = try RunStore(path: path)
    let sc = try scene(runs: runs)
    let db = try SQLiteDatabase(path: path)
    try db.execute("CREATE TRIGGER reject_event BEFORE INSERT ON events WHEN NEW.type = 'action.dispatched' BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END")
    let response = act(sc, clickContinue)
    #expect(code(response) == "audit_unavailable")
    if case let .failure(e) = response.result { #expect(e.notSent == true) }
    #expect(sc.platform.performed.isEmpty)
    #expect(sc.s.execution.activeCount == 0)
    #expect(sc.s.execution.inputAdmission == .stopped)
}

@Test func concurrentRunEventsAreAllStoredWithUniqueContiguousSequences() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runs.sqlite"
    do {
        let store = try RunStore(path: path)
        store.create(testRun("run_concurrent", lifetime: .connectionScoped))
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            store.appendEvent("run_concurrent", "test.event", .obj([("index", .int(i))]))
        }
        try store.checkWritable()
        let events = store.events("run_concurrent", after: 0, limit: 1000)
        #expect(events.count == 501)
        #expect(events.compactMap { $0["sequence"]?.intValue } == Array(1...501))
        #expect(Set(events.compactMap { $0["data"]?["index"]?.intValue }) == Set(0..<500))
        // Avoid a recovery event in the persistence check below.
        var ended = testRun("run_concurrent", lifetime: .connectionScoped)
        ended.phase = .ended; ended.quiescence = .confirmed; ended.outcome = .success
        store.update(ended)
    }
    let reopened = try RunStore(path: path)
    #expect(reopened.events("run_concurrent", after: 0, limit: 1000).count == 501)
}
