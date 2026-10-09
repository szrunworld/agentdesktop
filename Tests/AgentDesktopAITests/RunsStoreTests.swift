import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopAI

// Persistence of GUI runs (spec §05.3, §05.4, §07.4, §09.3). Case IDs from
// docs/ai-gui/tests/cases.csv. The full run through the explorer against
// this store is in AgentDesktopGUITests/RunsSQLiteTests.swift.

private func dbPath() throws -> String {
    let dir = ScratchDirectory.url("adruns")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("config.sqlite").path
}

private let credentials = InMemoryCredentialStore()

private func open(_ path: String) throws -> ConfigStore {
    try ConfigStore(path: path, credentials: credentials, digestKey: Data(repeating: 7, count: 32))
}

private func binding(_ runId: String, profile: String = "gp-1") -> JSONValue {
    .obj([("runId", .string(runId)), ("bindingEpoch", .int(1)), ("runGeneration", .int(1)),
          ("primary", .obj([("guiProfile", .obj([("guiProfileId", .string(profile))])),
                            ("modelProfile", .obj([("modelProfileId", .string("mp-1"))])),
                            ("connection", .obj([("connectionId", .string("c-1"))]))])),
          ("fallbackCandidates", .array([]))])
}

private func run(_ id: String, scope: String = "owner", state: String = "executing", profile: String = "gp-1") -> StoredGuiRun {
    let b = binding(id, profile: profile)
    let snap: JSONValue = .obj([("runId", .string(id)), ("state", .string(state)), ("currentGeneration", .int(1)),
                                ("binding", b), ("lastSequence", .int(0)), ("waitingReasonCode", .null),
                                ("latestActionReceipt", .null), ("error", .null)])
    return StoredGuiRun(runId: id, callerScope: scope, binding: b, startResult: .obj([("runId", .string(id))]), snapshot: snap)
}

private func proposal(runId: String, id: String = "prop-1", generation: UInt64 = 1) -> GuiProposal {
    GuiProposal(proposalId: id, runId: runId, stepIndex: 0, inferenceAttemptId: "att-1",
                stamp: ObservationStamp(sessionId: "sess-a", desktopId: "desk-a", snapshotId: "snap-1",
                                        bindingEpoch: 1, runGeneration: generation),
                screenshotId: "shot-1",
                provenance: AdapterProvenance(adapterId: .uitarsV1, adapterVersion: "1.0.0", promptVersion: "uitars-prompt-1",
                                              parserVersion: "uitars-parser-1", coordinateProtocol: .imagePixels),
                body: .action(.click(sourcePixel: Point(x: 10, y: 20))))
}

private func receipt(_ p: GuiProposal, actionId: String, _ state: DeliveryState) -> GuiActionReceipt {
    let t = Date(timeIntervalSince1970: 1_791_000_000)
    return GuiActionReceipt(actionId: actionId, proposalId: p.proposalId, runId: p.runId, stamp: p.stamp,
                            actionType: .click, deliveryState: state, executionTarget: nil, inputPath: "spy",
                            startedAt: t, endedAt: state == .confirmed ? t : nil, evidenceRefs: [],
                            createdAt: t, updatedAt: t, confirmationObservationId: nil, reasonCode: nil)
}

private func event(_ runId: String) -> @Sendable (Int) -> JSONValue {
    { seq in .obj([("sequence", .int(seq)), ("runId", .string(runId)), ("summary", .string("e\(seq)"))]) }
}

@Suite("Run store")
struct RunsStoreTests {
    @Test func migratesToV3AndKeepsOlderTables() async throws {
        let path = try dbPath()
        _ = try open(path)
        #expect(ConfigStore.schemaVersion == 3)
        let store = try open(path)   // reopening an up-to-date database is a no-op
        #expect(try await store.runtimeEpoch() == 1)
    }

    // RPC-006 across a restart: the same key still names the same run.
    @Test func rpc006_idempotentCreateSurvivesReopen() async throws {
        let path = try dbPath()
        let repo = SQLiteGuiRunRepository(store: try open(path))
        guard case .created = try await repo.create(run("run-1"), idempotencyKey: "k-0001", digest: "d1") else {
            Issue.record("first create"); return
        }
        let reopened = SQLiteGuiRunRepository(store: try open(path))
        guard case let .existing(r) = try await reopened.create(run("run-2"), idempotencyKey: "k-0001", digest: "d1") else {
            Issue.record("same key must return the existing run"); return
        }
        #expect(r.runId == "run-1")
        await #expect(throws: ContractError(.idempotencyConflict, "this idempotency key was used for a different run")) {
            _ = try await reopened.create(run("run-3"), idempotencyKey: "k-0001", digest: "other")
        }
        // Another caller's identical key is its own run, and run-1 is invisible to it.
        guard case .created = try await reopened.create(run("run-4", scope: "stranger"), idempotencyKey: "k-0001", digest: "d1") else {
            Issue.record("caller isolation"); return
        }
        #expect(try await reopened.load(runId: "run-1", callerScope: "stranger") == nil)
    }

    // RPC-008 across a restart: sequences keep increasing, pruned cursors stay expired.
    @Test func rpc008_eventsSurviveReopen() async throws {
        let path = try dbPath()
        let repo = SQLiteGuiRunRepository(store: try open(path))
        _ = try await repo.create(run("run-1"), idempotencyKey: "k-0001", digest: "d")
        for _ in 0..<3 { _ = try await repo.appendEvent(runId: "run-1", event("run-1")) }
        try await repo.prune(runId: "run-1", keepFrom: 2)

        let again = SQLiteGuiRunRepository(store: try open(path))
        #expect(try await again.appendEvent(runId: "run-1", event("run-1")) == 4)
        let all = try await again.events(runId: "run-1", afterSequence: 0, limit: 100)
        #expect(all.events.compactMap { $0["sequence"]?.intValue } == [2, 3, 4])
        #expect(all.oldestRetained == 2)
        #expect(all.lastSequence == 4)
        await #expect(throws: ContractError.self) { _ = try await again.events(runId: "nope", afterSequence: 0, limit: 10) }
    }

    @Test func eventLogCap() async throws {
        let repo = SQLiteGuiRunRepository(store: try open(try dbPath()), maxEventsPerRun: 2)
        _ = try await repo.create(run("run-1"), idempotencyKey: "k-0001", digest: "d")
        _ = try await repo.appendEvent(runId: "run-1", event("run-1"))
        _ = try await repo.appendEvent(runId: "run-1", event("run-1"))
        await #expect(throws: ContractError.self) { _ = try await repo.appendEvent(runId: "run-1", event("run-1")) }
    }

    // §09.3: no pending row, no input.
    @Test func auditUnavailableWhenThePendingRowCannotBeWritten() async throws {
        let store = try open(try dbPath())
        let repo = SQLiteGuiRunRepository(store: store)
        let audit = SQLiteGuiAuditPort(store: store, newActionId: { "act-1" })
        _ = try await repo.create(run("run-1"), idempotencyKey: "k-0001", digest: "d")
        await store.setRunStoreFault(.actionReservation, true)
        do {
            _ = try await audit.reserveAction(proposal(runId: "run-1"))
            Issue.record("reservation must fail")
        } catch let e as ContractError {
            #expect(e.code == .auditUnavailable)
        }
        #expect(try await store.actionReceipt(actionId: "act-1") == nil)
        await store.setRunStoreFault(.actionReservation, false)
        #expect(try await audit.reserveAction(proposal(runId: "run-1")) == "act-1")
        #expect(try await store.actionReceipt(actionId: "act-1")?.state == "pending")
    }

    // USG-001 for inputs: a settled receipt is final and counted once.
    @Test func usg001_settledActionReceiptIsFinal() async throws {
        let store = try open(try dbPath())
        _ = try await SQLiteGuiRunRepository(store: store).create(run("run-1"), idempotencyKey: "k-0001", digest: "d")
        let audit = SQLiteGuiAuditPort(store: store, newActionId: { "act-1" })
        let p = proposal(runId: "run-1")
        let id = try await audit.reserveAction(p)
        try await audit.recordAction(receipt(p, actionId: id, .confirmed))
        try await audit.recordAction(receipt(p, actionId: id, .confirmed))
        try await audit.recordAction(receipt(p, actionId: id, .unknown))
        #expect(try await store.actionReceipt(actionId: id)?.state == "confirmed")
        await #expect(throws: ContractError.self) { try await audit.recordAction(receipt(p, actionId: "never-reserved", .confirmed)) }
    }

    // EXE-003 / RET-004: written as pending, process gone before the
    // verdict, database reopened. The input becomes unknown, its run waits,
    // its desktop stays quarantined, and nothing is sent again.
    @Test func exe003_pendingInputAfterRestartIsUnknownAndQuarantined() async throws {
        let path = try dbPath()
        do {
            let store = try open(path)
            _ = try await SQLiteGuiRunRepository(store: store).create(run("run-1"), idempotencyKey: "k-0001", digest: "d")
            _ = try await SQLiteGuiAuditPort(store: store, newActionId: { "act-1" }).reserveAction(proposal(runId: "run-1"))
        }
        let store = try open(path)
        let report = try await RunRecovery(store: store).recover()
        #expect(report.runtimeEpoch == 2)
        #expect(report.quarantinedRuns == ["run-1"])
        #expect(report.unknownActions == ["act-1"])
        #expect(report.endedRuns.isEmpty)

        let stored = try #require(try await store.actionReceipt(actionId: "act-1"))
        #expect(stored.state == "unknown")
        #expect(stored.body?["deliveryState"]?.stringValue == "unknown")
        #expect(stored.body?["evidenceRefs"] == .array([]))
        #expect(stored.body?["executionTarget"]?.isNull == true)
        #expect(stored.body?["reasonCode"]?.stringValue == "ACTION_OUTCOME_UNKNOWN")
        #expect(try await store.unresolvedActions(desktopId: "desk-a").map(\.actionId) == ["act-1"])

        let r = try #require(try await store.loadRun(runId: "run-1", callerScope: "owner"))
        #expect(r.snapshot["state"]?.stringValue == "waiting_user")
        #expect(r.snapshot["waitingReasonCode"]?.stringValue == "ACTION_OUTCOME_UNKNOWN")
        #expect(r.snapshot["currentGeneration"]?.intValue == 2, "work stamped before the restart is void")
        #expect(r.snapshot["latestActionReceipt"]?["actionId"]?.stringValue == "act-1")
        let events = try await store.runEvents(runId: "run-1", afterSequence: 0, limit: 100).events
        #expect(events.compactMap { $0["type"]?.stringValue } == ["action_receipt", "state_changed", "waiting_user"])
        #expect(events.compactMap { $0["sequence"]?.intValue } == [1, 2, 3])

        // A second restart changes nothing but the epoch.
        let second = try await RunRecovery(store: try open(path)).recover()
        #expect(second.runtimeEpoch == 3)
        #expect(second.quarantinedRuns == ["run-1"])
        #expect(second.unknownActions.isEmpty)
        #expect(try await store.runEvents(runId: "run-1", afterSequence: 0, limit: 100).lastSequence == 3)

        // The Runtime's reconciliation lifts the quarantine; the row stays unknown.
        try await store.markActionReconciled(actionId: "act-1")
        #expect(try await store.unresolvedActions(desktopId: "desk-a").isEmpty)
        #expect(try await store.actionReceipt(actionId: "act-1")?.state == "unknown")
    }

    @Test func submittedReceiptKeepsItsFieldsAndBecomesUnknown() async throws {
        let path = try dbPath()
        let store = try open(path)
        _ = try await SQLiteGuiRunRepository(store: store).create(run("run-1"), idempotencyKey: "k-0001", digest: "d")
        let audit = SQLiteGuiAuditPort(store: store, newActionId: { "act-1" })
        let p = proposal(runId: "run-1")
        _ = try await audit.reserveAction(p)
        try await audit.recordAction(receipt(p, actionId: "act-1", .submitted))
        _ = try await RunRecovery(store: try open(path)).recover()
        let body = try #require(try await open(path).actionReceipt(actionId: "act-1")?.body)
        #expect(body["deliveryState"]?.stringValue == "unknown")
        #expect(body["inputPath"]?.stringValue == "spy", "what was recorded before the restart is kept")
    }

    @Test func cancelAcceptedBeforeRestartStaysCancellingOnUnknown() async throws {
        let path = try dbPath()
        let store = try open(path)
        _ = try await SQLiteGuiRunRepository(store: store).create(run("run-1", state: "cancelling"), idempotencyKey: "k-0001", digest: "d")
        _ = try await SQLiteGuiAuditPort(store: store, newActionId: { "act-1" }).reserveAction(proposal(runId: "run-1"))
        _ = try await RunRecovery(store: try open(path)).recover()
        let snap = try #require(try await open(path).loadRun(runId: "run-1", callerScope: "owner")).snapshot
        #expect(snap["state"]?.stringValue == "cancelling")
        #expect(snap["waitingReasonCode"]?.stringValue == "ACTION_OUTCOME_UNKNOWN")
    }

    // §07.4: a run with nothing in flight never continues on its own.
    @Test func runsWithNothingInFlightEnd() async throws {
        let path = try dbPath()
        let store = try open(path)
        let repo = SQLiteGuiRunRepository(store: store)
        _ = try await repo.create(run("inferencing", state: "inferencing"), idempotencyKey: "k-0001", digest: "d")
        _ = try await repo.create(run("needs-user", state: "waiting_user"), idempotencyKey: "k-0002", digest: "d")
        _ = try await repo.create(run("cancelling", state: "cancelling"), idempotencyKey: "k-0003", digest: "d")
        _ = try await repo.create(run("done", state: "succeeded"), idempotencyKey: "k-0004", digest: "d")
        let report = try await RunRecovery(store: try open(path)).recover()
        #expect(Set(report.endedRuns) == ["inferencing", "needs-user", "cancelling"])
        let after = try open(path)
        func state(_ id: String) async throws -> String? {
            try await after.loadRun(runId: id, callerScope: "owner")?.snapshot["state"]?.stringValue
        }
        #expect(try await state("inferencing") == "failed")
        #expect(try await state("needs-user") == "failed")
        #expect(try await state("cancelling") == "cancelled")
        #expect(try await state("done") == "succeeded")
        let err = try await after.loadRun(runId: "inferencing", callerScope: "owner")?.snapshot["error"]
        #expect(err?["message"]?.stringValue?.contains("restarted") == true)
        #expect(try await after.runEvents(runId: "done", afterSequence: 0, limit: 10).events.isEmpty)
    }

    @Test func interruptedModelCallsAreReported() async throws {
        let report = try await RunRecovery(store: try open(try dbPath())).recover()
        #expect(report.interruptedAttempts == 0)
    }

    @Test func activeRunReferencesComeFromTheBinding() async throws {
        let store = try open(try dbPath())
        let repo = SQLiteGuiRunRepository(store: store)
        _ = try await repo.create(run("run-1", profile: "gp-9"), idempotencyKey: "k-0001", digest: "d")
        #expect(try await store.referencedByActiveRun(.guiProfile, "gp-9"))
        #expect(try await store.referencedByActiveRun(.modelProfile, "mp-1"))
        #expect(try await store.referencedByActiveRun(.connection, "c-1"))
        #expect(try await store.referencedByActiveRun(.guiProfile, "gp-other") == false)
        try await repo.saveSnapshot(runId: "run-1", snapshot: run("run-1", state: "succeeded").snapshot)
        #expect(try await store.referencedByActiveRun(.guiProfile, "gp-9") == false)
    }
}
