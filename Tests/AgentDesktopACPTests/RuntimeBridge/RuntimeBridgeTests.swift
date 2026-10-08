import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

@Suite struct RuntimeBridgeIdentityTests {
    @Test func callerComesFromTheRuntimeNotTheEditor() async throws {
        let server = RTestRuntime()
        let port = try RTest.port(server)
        let c = try await port.caller()
        #expect(c.principalId == "local:501")
        #expect(c.clientId == "local:501")
        #expect(c.connectionId == "unissued:inst_test")
        #expect(server.methodCalls("runtime.status").count == 1)
    }

    @Test func callerConnectionIdIsTheOneTheRuntimeStampedOnARun() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        _ = try await port.caller()
        _ = try await port.submit(RTest.submission())
        let c = try await port.caller()
        #expect(c.connectionId == "conn_1")
    }
}

@Suite struct RuntimeBridgeTaskTests {
    @Test func noTaskEntryMeansNoTasks() async throws {
        let server = RTestRuntime()
        let port = try RTest.port(server)
        #expect(try await port.tasks().isEmpty)
    }

    @Test func unitRunBecomesOneGenericTaskWithTheContractSchema() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let tasks = try await RTest.port(server).tasks()
        #expect(tasks.map(\.taskType) == ["unit.run"])
        let props = tasks[0].inputSchema["properties"]?.objectMembers?.map(\.key) ?? []
        #expect(props.contains("goal"))
        #expect(!props.contains("desktopId"))
        #expect(!props.contains("guiProfileId"))
        #expect(tasks[0].requiresApproval)
    }

    @Test func enabledGuiProfilesBecomeTasks() async throws {
        let server = RTestRuntime()
        server.methods += ["unit.run", "ai.profiles.list"]
        server.profiles = [
            .obj([("guiProfileId", .string("gp_a")), ("revision", .int(3)), ("name", .string("A")), ("state", .string("enabled"))]),
            .obj([("guiProfileId", .string("gp_b")), ("revision", .int(1)), ("name", .string("B")), ("state", .string("disabled"))]),
        ]
        let port = try RTest.port(server)
        let tasks = try await port.tasks()
        #expect(tasks.map(\.taskType) == ["unit.run/gp_a"])
        let r = try await port.submit(RTest.submission(task: "unit.run/gp_a"))
        guard case .accepted = r else { Issue.record("\(r)"); return }
    }

    @Test func catalogPinsTheProfileRevisionAndRefusesIdentityFields() throws {
        let catalog = ACPTaskCatalog()
        let entries = catalog.entries(methods: ["unit.run", "ai.profiles.list"], profiles: [
            .obj([("guiProfileId", .string("gp_a")), ("revision", .int(3)), ("name", .string("A")), ("state", .string("enabled"))])])
        let ok = try catalog.params(for: entries[0], submission: RTest.submission(task: "unit.run/gp_a")).get()
        #expect(ok["guiProfileId"] == .string("gp_a"))
        #expect(ok["expectedProfileRevision"]?.intValue == 3)
        #expect(ok["desktopId"] == .string("desk_A"))
        for key in ["origin", "lifetime", "ownership", "clientId"] {
            let input = RTest.validInput.setting(key, .string("x"))
            let r = catalog.params(for: entries[0], submission: RTest.submission(input: input))
            #expect(r == .failure(.refused(code: "ownership_escalation_denied",
                                           message: "\(key) comes from the Runtime's authenticated context, never from input")))
        }
    }
}

@Suite struct RuntimeBridgeSubmitTests {
    @Test func withoutUnitRunSubmitIsCapabilityMissingAndSendsNothing() async throws {
        let server = RTestRuntime()
        let port = try RTest.port(server)
        let r = try await port.submit(RTest.submission())
        guard case let .refused(code, _) = r else { Issue.record("\(r)"); return }
        #expect(code == "capability_missing")
        #expect(server.methodCalls("unit.run").isEmpty)
    }

    // T09: one Run per submission.
    @Test func t09OneRunPerSubmission() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        let a = try await port.submit(RTest.submission("k1"))
        let b = try await port.submit(RTest.submission("k2"))
        guard case let .accepted(ra) = a, case let .accepted(rb) = b else { Issue.record("\(a) \(b)"); return }
        #expect(ra.runId != rb.runId)
        #expect(ra.lifetime == "connection_scoped")
        let calls = server.methodCalls("unit.run")
        #expect(calls.count == 2)
        #expect(calls[0].requestId == ACPSubmissionLog.requestId(principalId: "local:501", submissionKey: "k1"))
        #expect(calls[0].requestId.hasPrefix("acp-sub-"))
        #expect(server.runs.count == 2)
    }

    // T10: duplicate submission → the same Run, no second request.
    @Test func t10DuplicateSubmissionReturnsTheSameRunWithoutSending() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let path = RTest.tempLogPath()
        let port = try RTest.port(server, logPath: path)
        guard case let .accepted(first) = try await port.submit(RTest.submission()) else { Issue.record("not accepted"); return }
        let again = try await port.submit(RTest.submission())
        #expect(again == .duplicate(first))
        // A new bridge process (same log file) also only reads.
        let other = try RTest.port(server, logPath: path)
        let third = try await other.submit(RTest.submission())
        guard case let .duplicate(s) = third else { Issue.record("\(third)"); return }
        #expect(s.runId == first.runId)
        #expect(server.methodCalls("unit.run").count == 1)
    }

    @Test func lostAnswerIsUnconfirmedThenRecoveredFromTheLedger() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        server.unitRun = .loseAnswer
        let port = try RTest.port(server)
        #expect(try await port.submit(RTest.submission()) == .unconfirmed)
        let r = try await port.submit(RTest.submission())
        guard case let .duplicate(s) = r else { Issue.record("\(r)"); return }
        #expect(server.runs[s.runId] != nil)
        #expect(server.methodCalls("unit.run").count == 1)
        #expect(server.methodCalls("request.show").count == 1)
    }

    // T11: unknown is never retried.
    @Test func t11UnknownIsNeverResent() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        server.unitRun = .loseBeforeArrival
        let port = try RTest.port(server)
        #expect(try await port.submit(RTest.submission()) == .unconfirmed)
        // The ledger has nothing; the bridge still does not resend.
        #expect(try await port.submit(RTest.submission()) == .unconfirmed)
        server.requestShowFails = true
        #expect(try await port.submit(RTest.submission()) == .unconfirmed)
        #expect(server.methodCalls("unit.run").count == 1)
        #expect(server.methodCalls("request.show").count == 2)
    }

    @Test func ledgerUnknownStaysUnconfirmed() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        server.unitRun = .loseBeforeArrival
        let port = try RTest.port(server)
        _ = try await port.submit(RTest.submission())
        let rid = ACPSubmissionLog.requestId(principalId: "local:501", submissionKey: "sess-1/prompt-1")
        server.with { server.ledger[rid] = ("unit.run", "unknown", nil) }
        #expect(try await port.submit(RTest.submission()) == .unconfirmed)
        #expect(server.methodCalls("unit.run").count == 1)
    }

    @Test func refusalIsRememberedAndNotResent() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        server.unitRun = .refuse(code: "control_busy")
        let port = try RTest.port(server)
        let a = try await port.submit(RTest.submission())
        let b = try await port.submit(RTest.submission())
        guard case let .refused(code, _) = a else { Issue.record("\(a)"); return }
        #expect(code == "control_busy")
        #expect(a == b)
        #expect(server.methodCalls("unit.run").count == 1)
    }

    @Test func certainlyNotSentMayBeSentLater() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        server.unitRun = .offline
        let path = RTest.tempLogPath()
        let port = try RTest.port(server, logPath: path)
        guard case let .refused(code, _) = try await port.submit(RTest.submission()) else { Issue.record("not refused"); return }
        #expect(code == "runtime_offline")
        #expect(try ACPSubmissionLog(path: path).entry("sess-1/prompt-1") == nil)
        server.unitRun = .accept
        guard case .accepted = try await port.submit(RTest.submission()) else { Issue.record("not accepted"); return }
    }

    @Test func invalidInputIsRefusedLocally() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        let r1 = try await port.submit(RTest.submission(input: .obj([("goal", .string("x"))])))
        let r2 = try await port.submit(RTest.submission("k2", input: RTest.validInput.setting("lifetime", .string("platform_durable"))))
        let r3 = try await port.submit(RTest.submission("k3", desktop: nil))
        let r4 = try await port.submit(RTest.submission("k4", task: "recruiting.greet"))
        guard case let .refused(c1, _) = r1, case let .refused(c2, _) = r2, case let .refused(c3, _) = r3,
              case let .refused(c4, _) = r4 else { Issue.record("\(r1) \(r2) \(r3) \(r4)"); return }
        #expect([c1, c2, c3, c4] == ["schema_invalid", "ownership_escalation_denied", "invalid_argument", "not_found"])
        #expect(server.methodCalls("unit.run").isEmpty)
    }

    @Test func submitNeverSendsRunAxes() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        _ = try await port.submit(RTest.submission())
        // Checked on the wire params via the catalog: only unit_run_params keys.
        let p = try ACPTaskCatalog().params(for: ACPTaskCatalog().entries(methods: ["unit.run"], profiles: nil)[0],
                                            submission: RTest.submission()).get()
        let keys = Set(p.objectMembers?.map(\.key) ?? [])
        #expect(keys.isDisjoint(with: ["origin", "lifetime", "ownership"]))
    }
}

@Suite struct RuntimeBridgeRunTests {
    // T12: cancel → stopping, then quiescent.
    @Test func t12CancelIsAcceptedThenQuiescent() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        guard case let .accepted(run) = try await port.submit(RTest.submission()) else { Issue.record("no run"); return }
        let c = try await port.cancel(runId: run.runId, requestId: "acp-cancel-1")
        #expect(c.phase == "stopping")
        #expect(c.quiescence == "pending")
        #expect(c.lifetime == "connection_scoped")
        server.end(run.runId, outcome: "cancelled")
        let s = try await port.snapshot(runId: run.runId)
        #expect(s.phase == "ended")
        #expect(s.quiescence == "confirmed")
        #expect(s.outcome == "cancelled")
        // The same requestId repeats the same cancel.
        _ = try await port.cancel(runId: run.runId, requestId: "acp-cancel-1")
        #expect(server.methodCalls("run.cancel").map(\.requestId) == ["acp-cancel-1", "acp-cancel-1"])
    }

    @Test func snapshotOfUnknownRunThrowsNotFound() async throws {
        let server = RTestRuntime()
        let port = try RTest.port(server)
        do {
            _ = try await port.snapshot(runId: "run_x")
            Issue.record("no error")
        } catch let e as ACPError {
            #expect(e.reason == "not_found")
        }
    }

    // T14: connection loss closes the control connection; no reconnect, no resume.
    @Test func t14ConnectionLossClosesTheControlConnectionAndDoesNotResume() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        guard case let .accepted(run) = try await port.submit(RTest.submission()) else { Issue.record("no run"); return }
        let controlConn = server.methodCalls("unit.run")[0].connection
        let before = server.with { server.handshakes }
        await port.connectionLost()
        #expect(server.closed.contains(controlConn))
        #expect(server.runs[run.runId]?["phase"] == "stopping")
        #expect(server.runs[run.runId]?["closingReason"] == "owner_lost")
        let r = try await port.submit(RTest.submission("k-new"))
        guard case let .refused(code, _) = r else { Issue.record("\(r)"); return }
        #expect(code == "connection_lost")
        await #expect(throws: ACPError.self) { try await port.snapshot(runId: run.runId) }
        var ended = false
        do { for try await _ in port.events(runId: run.runId, after: nil) {} } catch { ended = true }
        #expect(ended)
        #expect(server.with { server.handshakes } == before)
        #expect(server.methodCalls("unit.run").count == 1)
        await port.connectionLost()
    }

    @Test func approvalsAndQuestionsAreCapabilityMissing() async throws {
        let port = try RTest.port(RTestRuntime())
        for op in [{ _ = try await port.pending(runId: "r") }, { try await port.decide(approvalId: "a", allow: true) },
                   { try await port.answer(questionId: "q", text: "t") }] as [() async throws -> Void] {
            do {
                try await op()
                Issue.record("no error")
            } catch let e as ACPError {
                #expect(e.reason == "capability_missing")
            }
        }
    }
}

@Suite struct RuntimeBridgeEventTests {
    @Test func streamsOnItsOwnConnectionUntilTheRunEnds() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let port = try RTest.port(server)
        guard case let .accepted(run) = try await port.submit(RTest.submission()) else { Issue.record("no run"); return }
        for t in ["run.started", "action.accepted", "action.completed"] { server.emit(run.runId, t) }
        server.end(run.runId, outcome: "success")
        server.emit(run.runId, "run.ended")
        let got = try await RTest.collect(port.events(runId: run.runId, after: nil))
        #expect(got.map(\.cursor) == [1, 2, 3, 4])
        #expect(got.last?.type == "run.ended")
        // The control connection was never subscribed (it owns a live Run).
        let control = server.methodCalls("unit.run")[0].connection
        #expect(!server.methodCalls("events.subscribe").contains { $0.connection == control })
    }

    @Test func resumesAfterACursorWithoutRepeats() async throws {
        let server = RTestRuntime()
        server.addRun("run_r")
        for i in 1...5 { server.emit("run_r", "e\(i)") }
        server.end("run_r", outcome: "success")
        let got = try await RTest.collect(try RTest.port(server).events(runId: "run_r", after: 3))
        #expect(got.map(\.cursor) == [4, 5])
    }

    @Test func aDroppedStreamResubscribesFromTheLastCursorAndDeDuplicates() async throws {
        let server = RTestRuntime()
        server.addRun("run_d")
        for i in 1...6 { server.emit("run_d", "e\(i)") }
        server.dropAfterFrames = 2
        server.dropsLeft = 2
        let port = try RTest.port(server)
        let stream = port.events(runId: "run_d", after: nil)
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            server.end("run_d", outcome: "success")
        }
        let got = try await RTest.collect(stream)
        #expect(got.map(\.cursor) == [1, 2, 3, 4, 5, 6])
        #expect(server.methodCalls("events.subscribe").count >= 2)
    }

    @Test func pollsWhenTheRuntimeCannotPush() async throws {
        let server = RTestRuntime()
        server.supportsPush = false
        server.addRun("run_p")
        server.emit("run_p", "a")
        let stream = try RTest.port(server).events(runId: "run_p", after: nil)
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            server.emit("run_p", "b")
            server.end("run_p", outcome: "failed")
        }
        let got = try await RTest.collect(stream)
        #expect(got.map(\.type) == ["a", "b"])
        #expect(!server.methodCalls("run.events").isEmpty)
    }

    @Test func unknownRunEndsTheStreamWithNotFound() async throws {
        let server = RTestRuntime()
        server.supportsPush = false
        do {
            _ = try await RTest.collect(try RTest.port(server).events(runId: "run_none", after: nil))
            Issue.record("no error")
        } catch let e as ACPError {
            #expect(e.reason == "not_found")
        }
    }
}

@Suite struct ACPSubmissionLogTests {
    @Test func persistsWithOwnerOnlyPermissionsAndNoInput() throws {
        let path = RTest.tempLogPath()
        let log = try ACPSubmissionLog(path: path)
        try log.record(.init(submissionKey: "k", requestId: "acp-sub-1", method: "unit.run", state: .accepted,
                             runId: "run_1", updatedAt: ""))
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let reloaded = try ACPSubmissionLog(path: path)
        #expect(reloaded.entry("k")?.runId == "run_1")
    }

    @Test func corruptLogIsAnErrorNotAnEmptyLog() throws {
        let path = RTest.tempLogPath()
        _ = try ACPSubmissionLog(path: path)
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try ACPSubmissionLog(path: path) }
    }

    @Test func oldEntriesExpireWithTheLedger() throws {
        let path = RTest.tempLogPath()
        let then = Date(timeIntervalSince1970: 1_000_000)
        try ACPSubmissionLog(path: path, now: { then }).record(.init(submissionKey: "old", requestId: "r", method: "unit.run",
                                                                      state: .sending, updatedAt: ""))
        let later = try ACPSubmissionLog(path: path, now: { then.addingTimeInterval(8 * 86400) })
        #expect(later.entry("old") == nil)
    }

    @Test func requestIdsAreStableNamespacedAndValidIds() {
        let a = ACPSubmissionLog.requestId(principalId: "local:501", submissionKey: "s/1")
        #expect(a == ACPSubmissionLog.requestId(principalId: "local:501", submissionKey: "s/1"))
        #expect(a != ACPSubmissionLog.requestId(principalId: "local:501", submissionKey: "s/2"))
        #expect(a != ACPSubmissionLog.requestId(principalId: "local:502", submissionKey: "s/1"))
        #expect(RuntimeContract.shared.validate(.string(a), "Id").isEmpty)
    }
}

@Suite struct RuntimeBridgeExecutorTests {
    @Test func aBlockedCallTimesOutWithoutBlockingTheCaller() async throws {
        let ex = ACPBridgeExecutor(label: "rtest")
        let start = Date()
        do {
            _ = try await ex.run(timeout: 0.1) { Thread.sleep(forTimeInterval: 1); return 1 }
            Issue.record("no timeout")
        } catch is ACPBridgeTimeout {}
        #expect(Date().timeIntervalSince(start) < 0.9)
    }

    @Test func submitThatOutlivesTheTimeoutIsUnconfirmedThenRecovered() async throws {
        let server = RTestRuntime()
        server.methods.append("unit.run")
        let slow = SlowFactory(server: server)
        var config = ACPBridgeConfiguration()
        config.callTimeout = 0.1
        config.uid = 501
        let port = ACPBridgeRuntimePort(makeClient: slow.factory, log: try ACPSubmissionLog(path: RTest.tempLogPath()), config: config)
        #expect(try await port.submit(RTest.submission()) == .unconfirmed)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        slow.delay = 0
        let r = try await port.submit(RTest.submission())
        guard case .duplicate = r else { Issue.record("\(r)"); return }
        #expect(server.methodCalls("unit.run").count == 1)
    }
}

/// Clients whose calls block for `delay` seconds first.
final class SlowFactory: @unchecked Sendable {
    let server: RTestRuntime
    var delay: Double = 0.3
    init(server: RTestRuntime) { self.server = server }
    var factory: ACPBridgeClientFactory {
        { [self] role in RTestSlowClient(server: server, role: role, owner: self) }
    }
}

final class RTestSlowClient: RTestClient {
    let owner: SlowFactory
    init(server: RTestRuntime, role: ACPBridgeConnectionRole, owner: SlowFactory) {
        self.owner = owner
        super.init(server: server, role: role)
    }
    override func call(_ request: RuntimeRequest) throws -> JSONValue {
        if owner.delay > 0 { Thread.sleep(forTimeInterval: owner.delay) }
        return try super.call(request)
    }
}
