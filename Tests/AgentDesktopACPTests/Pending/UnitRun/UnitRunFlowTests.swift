import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Layer: Mock. ACP's adapter side end to end on the contract-shaped fake
// Runtime (URTestRuntime): ACPTaskCatalog → ACPBridgeRuntimePort.submit
// (unit.run) → events (events.subscribe / run.events) → ACPProjector →
// ACPWireV1 frames checked against the ACP v1 schema. The real ACP code is
// exercised; only the Runtime is fake. Not A6, not end-to-end
// (docs/acp/12-unit-run.md §五).

@Suite("UR · Mock · unit.run adapter flow (catalog → submit → events → projector → wire)", .serialized)
struct UnitRunFlowTests {
    private func setUp(_ name: String) throws -> (URTestRuntime, ACPBridgeRuntimePort) {
        let rt = URTestRuntime(try URTestScenario.load(name))
        return (rt, try URTestFlow.port(rt))
    }

    private func profile(_ id: String, revision: Int) -> JSONValue {
        .obj([("guiProfileId", .string(id)), ("name", .string(id)), ("state", .string("enabled")),
              ("revision", .int(revision)), ("modelProfileId", .string("model_test")), ("modelProfileRevision", .int(1)),
              ("adapterId", .string("fixture_json_v1")), ("adapterVersion", .string("1")),
              ("promptVersion", .string("1")), ("parserVersion", .string("1")), ("coordinateProtocol", .string("normalized_1000")),
              ("limits", .obj([("maxSteps", .int(10)), ("maxWallTimeMs", .int(120000)),
                               ("maxModelAttemptsPerStep", .int(1)), ("maxTotalModelAttempts", .int(10)),
                               ("maxOutputTokens", .int(1024)), ("maxWaitMs", .int(1000)), ("maxScreenshots", .int(5)),
                               ("maxImageEncodedBytes", .int(8388608)), ("requireReportedUsage", .bool(false))])),
              ("allowedFallbackProfileRefs", .array([])), ("createdAt", .string(URTestRuntime.at(0))),
              ("updatedAt", .string(URTestRuntime.at(0)))])
    }

    @Test("[Mock] profileQualifiedFlowSubmitsPinnedProfile")
    func profileQualifiedFlowSubmitsPinnedProfile() async throws {
        let (rt, port) = try setUp("ur-normal")
        rt.methods.insert("ai.profiles.list")
        rt.profiles = [profile("gp_gui_v1", revision: 3)]
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
        let params = try #require(rt.with { rt.unitRunParams.first })
        #expect(params["guiProfileId"] == .string("gp_gui_v1"))
        #expect(params["expectedProfileRevision"] == .int(3))
    }

    @Test("[Mock] multipleProfilesRequireExplicitTask")
    func multipleProfilesRequireExplicitTask() async throws {
        let (rt, port) = try setUp("ur-normal")
        rt.methods.insert("ai.profiles.list")
        rt.profiles = ["gp_a", "gp_b"].map { profile($0, revision: 1) }
        await #expect(throws: URTestError.self) { _ = try await URTestFlow.drive(rt, port) }
        #expect(rt.count("unit.run") == 0)
        let t = try await URTestFlow.drive(rt, port, taskType: "unit.run/gp_b")
        URTestFlow.checkExpectations(t, rt)
        #expect(rt.with { rt.unitRunParams.first?["guiProfileId"] } == .string("gp_b"))
    }

    // MARK: The five E2E classes (plus the time limit)

    @Test("[Mock] normalCompletionIsExecutedNotVerified") func normalCompletionIsExecutedNotVerified() async throws {
        let (rt, port) = try setUp("ur-normal")
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
        // The params that reached the Runtime: frozen shape, no run axes.
        let sent = try #require(rt.with { rt.unitRunParams.first })
        #expect(RuntimeContract.shared.validate(sent, "unit_run_params").isEmpty)
        #expect(sent["origin"] == nil && sent["lifetime"] == nil && sent["ownership"] == nil)
        #expect(sent["desktopId"] == .string("desk_A"))
        // The Run as accepted is Delegated, and Run.unit says matched at the
        // end — ACP still does not say 已验证 (open question Q4).
        #expect(rt.onlyRun?.verification == "matched")
        if case let .accepted(s) = t.receipt { #expect(s.lifetime == "connection_scoped") }
        // accepted ≠ executed: the first action frame is pending, never completed.
        #expect(t.actionUpdates.first?["status"]?.stringValue == "pending")
        #expect(t.actionUpdates.dropLast().allSatisfy { $0["status"]?.stringValue != "completed" })
    }

    @Test("[Mock] cancelStopsAndEndsCancelled") func cancelStopsAndEndsCancelled() async throws {
        let (rt, port) = try setUp("ur-cancel")
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
        // Cancel goes as run.cancel with the caller's requestId; never a second unit.run.
        #expect(rt.with { rt.calls.filter { $0.method == "run.cancel" }.map(\.requestId) }.allSatisfy { $0.hasPrefix("acp-cancel-") })
    }

    /// ACP-29 shape at Mock level: the editor goes away mid-run.
    @Test("[Mock] disconnectStopsTheRunAsConnectionScoped") func disconnectStopsTheRunAsConnectionScoped() async throws {
        let (rt, port) = try setUp("ur-disconnect")
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
        let mutations: @Sendable () -> Int = { rt.with { rt.calls.filter { ["unit.run", "run.cancel", "act"].contains($0.method) }.count } }
        let callsAtLoss = mutations()
        // ACP saw nothing after the loss and asks nothing more.
        #expect(t.events.last?.type == "action.dispatched")
        let again = try await port.submit(ACPSubmission(submissionKey: "after-loss", acpSessionId: URTestFlow.sessionId,
                                                        taskType: "unit.run", input: rt.scenario.input, desktopId: "desk_A"))
        #expect(again == .refused(code: "connection_lost", message: ACPBridgeErrors.connectionLost.message))
        await #expect(throws: (any Error).self) { _ = try await port.snapshot(runId: t.runId ?? "") }
        #expect(mutations() == callsAtLoss, "an execution request left after the editor was gone")
        // The Runtime's own stream records owner_lost and the unknown action.
        let types = rt.with { (rt.events[t.runId ?? ""] ?? []).compactMap { $0["type"]?.stringValue } }
        #expect(types.suffix(4) == ["stop.accepted", "action.unknown", "run.quiescent", "run.ended"])
        #expect(rt.onlyRun?.unknownActions == 1)
    }

    /// Runtime-side approval: no inbox before PR4, so ACP never approves.
    @Test("[Mock] approvalWithoutAChannelIsNeverAnAllow") func approvalWithoutAChannelIsNeverAnAllow() async throws {
        let (rt, port) = try setUp("ur-approval-rejected")
        // Before the cancel trigger fires, the Run waits for approval.
        let task = try #require(try await port.tasks().first)
        let receipt = try await port.submit(ACPSubmission(submissionKey: "approval-probe", acpSessionId: "s", taskType: task.taskType,
                                                          input: rt.scenario.input, desktopId: "desk_A"))
        guard case let .accepted(snap) = receipt else { Issue.record("not accepted: \(receipt)"); return }
        #expect(snap.phase == "waiting_approval")
        await #expect { _ = try await port.pending(runId: snap.runId) } throws: { ($0 as? ACPError)?.reason == "capability_missing" }
        await #expect { try await port.decide(approvalId: "inbox_1", allow: false) } throws: { ($0 as? ACPError)?.reason == "capability_missing" }
        // Nothing approval-like ever reached the Runtime.
        #expect(rt.with { rt.calls.map(\.method) }.allSatisfy { !$0.hasPrefix("inbox.") })
        _ = try await port.cancel(runId: snap.runId, requestId: "acp-cancel-probe")
        #expect(rt.run(snap.runId)?.outcome == "cancelled")
        #expect(rt.with { (rt.events[snap.runId] ?? []).contains { $0["type"]?.stringValue?.hasPrefix("action.") == true } } == false)
    }

    @Test("[Mock] approvalScenarioFlow") func approvalScenarioFlow() async throws {
        let (rt, port) = try setUp("ur-approval-rejected")
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
        #expect(t.actionUpdates.isEmpty)
    }

    /// Ruling P2 through the wire: terminal, failed on v1, rawOutput says
    /// terminated/unknown, never retried.
    @Test("[Mock] unknownOutcomeIsTerminalAndNeverRetried") func unknownOutcomeIsTerminalAndNeverRetried() async throws {
        let (rt, port) = try setUp("ur-unknown")
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
        // Mid-run the unknown is in progress, not failed (P2 applies at run.ended).
        let mid = try #require(t.actionUpdates.first { $0["_meta"]?["agentdesktop"]?["actionLevel"]?.stringValue == "unknown" })
        #expect(mid["status"]?.stringValue == "in_progress")
        // A repeat of the same submission only reads back the original.
        let again = try await port.submit(ACPSubmission(submissionKey: "urtest-ur-unknown", acpSessionId: URTestFlow.sessionId,
                                                        taskType: "unit.run", input: rt.scenario.input, desktopId: "desk_A"))
        guard case let .duplicate(s) = again else { Issue.record("\(again)"); return }
        #expect(s.outcome == "unknown")
        #expect(rt.count("unit.run") == 1)
    }

    @Test("[Mock] timeLimitEndsFailedWithItsReason") func timeLimitEndsFailedWithItsReason() async throws {
        let (rt, port) = try setUp("ur-limit-exhausted")
        let t = try await URTestFlow.drive(rt, port)
        URTestFlow.checkExpectations(t, rt)
    }

    // MARK: Call timeout and lost answers

    /// The unit.run answer does not come back in time: unconfirmed, never
    /// resent; the retry reads the ledger and maps to the same Run.
    @Test("[Mock] callTimeoutIsUnconfirmedThenTheSameRun") func callTimeoutIsUnconfirmedThenTheSameRun() async throws {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        rt.answer = .hang(seconds: 0.6)
        let port = try URTestFlow.port(rt, timeout: 0.15)
        let task = try #require(try await port.tasks().first)
        let sub = ACPSubmission(submissionKey: "hang-1", acpSessionId: "s", taskType: task.taskType, input: rt.scenario.input, desktopId: "desk_A")
        #expect(try await port.submit(sub) == .unconfirmed)
        // The control queue is serial: the retry runs after the first call returned.
        var second = try await port.submit(sub)
        for _ in 0..<20 where second == .unconfirmed {
            try await Task.sleep(for: .milliseconds(100))
            second = try await port.submit(sub)
        }
        guard case let .duplicate(s) = second else { Issue.record("\(second)"); return }
        #expect(s.runId == rt.onlyRun?.id)
        #expect(rt.count("unit.run") == 1)
        #expect(rt.allViolations.isEmpty)
    }

    @Test("[Mock] lostAnswerIsQueriedNotResent") func lostAnswerIsQueriedNotResent() async throws {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        rt.answer = .loseAnswer
        let port = try URTestFlow.port(rt)
        let task = try #require(try await port.tasks().first)
        let sub = ACPSubmission(submissionKey: "lost-1", acpSessionId: "s", taskType: task.taskType, input: rt.scenario.input, desktopId: "desk_A")
        #expect(try await port.submit(sub) == .unconfirmed)
        let again = try await port.submit(sub)
        guard case .duplicate = again else { Issue.record("\(again)"); return }
        #expect(rt.count("unit.run") == 1)
        #expect(rt.count("request.show") == 1)
    }

    // MARK: Refusals

    /// F40-06 rows 2–15: refused, no Run, the ledger holds a failed record,
    /// a retry reads it back and never sends again.
    @Test("[Mock] precheckRefusalsCreateNoRunAndAreNotResent") func precheckRefusalsCreateNoRunAndAreNotResent() async throws {
        let table = try URTestScenario.json("ur-precheck-refusals")
        for row in table["rows"]?.arrayValue ?? [] {
            let code = row["code"]?.stringValue ?? ""
            let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
            rt.answer = .refuse(code: code, reason: row["reason"]?.stringValue, details: row["details"]?.objectMembers?.map { ($0.key, $0.value) } ?? [])
            let port = try URTestFlow.port(rt)
            let sub = ACPSubmission(submissionKey: "pre-\(row["row"]?.intValue ?? 0)", acpSessionId: "s", taskType: "unit.run",
                                    input: rt.scenario.input, desktopId: "desk_A")
            let r = try await port.submit(sub)
            guard case let .refused(got, _) = r else { Issue.record("row \(row): \(r)"); continue }
            #expect(got == code, "row \(row)")
            #expect(rt.with { rt.runs.isEmpty }, "row \(row): a Run was created")
            let rec = rt.with { rt.ledger.values.first }
            #expect(rec?["state"]?.stringValue == "failed", "row \(row): no failed RequestRecord")
            #expect(try await port.submit(sub) == r, "row \(row): retry changed the answer")
            #expect(rt.count("unit.run") == 1, "row \(row): resent")
            #expect(rt.allViolations.isEmpty, "row \(row): \(rt.allViolations)")
        }
    }

    /// Gap UR-G4: the fixed `details.reason` (gui_execution_off, …) does not
    /// reach the editor: ACPSubmissionReceipt.refused has code and message only.
    @Test("[Mock] precheckReasonShouldReachTheEditor") func precheckReasonShouldReachTheEditor() async throws {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        rt.answer = .refuse(code: "unsupported_backend", reason: "gui_execution_off", details: [])
        let port = try URTestFlow.port(rt)
        let r = try await port.submit(ACPSubmission(submissionKey: "g4", acpSessionId: "s", taskType: "unit.run",
                                                    input: rt.scenario.input, desktopId: "desk_A"))
        guard case let .refused(_, message) = r else { Issue.record("\(r)"); return }
        withKnownIssue("UR-G4: details.reason is dropped") {
            #expect(message.contains("gui_execution_off"))
        }
    }

    /// Escalation never leaves ACP, whatever the field (ur-escalation.json).
    @Test("[Mock] escalationNeverReachesTheRuntime") func escalationNeverReachesTheRuntime() async throws {
        let esc = try URTestScenario.json("ur-escalation")
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        let port = try URTestFlow.port(rt)
        for (i, k) in (esc["cases"]?.arrayValue ?? []).enumerated() {
            let field = k["field"]?.stringValue ?? ""
            let r = try await port.submit(ACPSubmission(submissionKey: "esc-\(i)", acpSessionId: "s", taskType: "unit.run",
                                                        input: (esc["base"] ?? .null).urAdding(field, k["value"] ?? .null), desktopId: "desk_A"))
            guard case let .refused(code, _) = r else { Issue.record("\(field): \(r)"); continue }
            #expect(code == k["localCode"]?.stringValue, "\(field)")
        }
        #expect(rt.count("unit.run") == 0)
        #expect(rt.with { rt.runs.isEmpty })
    }

    /// What the fake Runtime does if a raw client sends them anyway (the
    /// contract's answer, not ACP's): no Run, failed record.
    @Test("[Mock] runtimeSideEscalationAnswerFollowsTheContract") func runtimeSideEscalationAnswerFollowsTheContract() throws {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        let c = URTestClient(server: rt, role: .control)
        let params = rt.scenario.input.urAdding("desktopId", .string("desk_A")).urAdding("lifetime", .string("platform_durable"))
        #expect { _ = try c.call(RuntimeRequest(requestId: "req_esc0001", method: "unit.run", params: params)) } throws: {
            ($0 as? RuntimeError)?.code == "ownership_escalation_denied"
        }
        #expect(rt.with { rt.runs.isEmpty })
        #expect(rt.with { rt.ledger["req_esc0001"]?["state"] } == .string("failed"))
    }

    /// No unit.run advertised: no task, a clear capability_missing, nothing sent.
    @Test("[Mock] withoutUnitRunNothingIsSent") func withoutUnitRunNothingIsSent() async throws {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        rt.methods = URTestRuntime.withoutUnitRun
        let port = try URTestFlow.port(rt)
        #expect(try await port.tasks().isEmpty)
        let r = try await port.submit(ACPSubmission(submissionKey: "none", acpSessionId: "s", taskType: "unit.run",
                                                    input: rt.scenario.input, desktopId: "desk_A"))
        guard case let .refused(code, _) = r else { Issue.record("\(r)"); return }
        #expect(code == "capability_missing")
        #expect(rt.count("unit.run") == 0)
    }

    /// Gap UR-G5: ACP takes whatever Run comes back. A unit.run over the wire
    /// must yield external_client / connection_scoped / agent_hub (ADR v2.2);
    /// anything else should be treated as a contract breach, not shown as ours.
    @Test("[Mock] aDurableRunFromTheWireShouldBeRejected") func aDurableRunFromTheWireShouldBeRejected() async throws {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        let port = try URTestFlow.port(rt)
        // Simulate a broken Runtime by rewriting the answer through a wrapper client.
        let broken: ACPBridgeClientFactory = { role in URTestDurableClient(server: rt, role: role) }
        var config = ACPBridgeConfiguration(); config.uid = rt.uid; config.pollInterval = 0.01
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("urtest-g5-\(UUID().uuidString)")
        let p2 = ACPBridgeRuntimePort(makeClient: broken, log: try ACPSubmissionLog(path: dir.appendingPathComponent("s.json").path), config: config)
        _ = port
        let r = try await p2.submit(ACPSubmission(submissionKey: "g5", acpSessionId: "s", taskType: "unit.run",
                                                  input: rt.scenario.input, desktopId: "desk_A"))
        withKnownIssue("UR-G5: returned Run axes are not checked") {
            if case .accepted = r { Issue.record("a platform_durable Run was accepted as this connection's") }
        }
    }

    /// Ruling P1 on unit.* events (not frozen): a window title in their data
    /// must not reach the editor; the event is shown as a neutral line.
    @Test("[Mock] unitEventsLeakNothing") func unitEventsLeakNothing() async throws {
        let (rt, port) = try setUp("ur-normal")
        let probe = JSONValue.obj([("type", .string("unit.observation")),
                                   ("data", .obj([("observationId", .string("obs_ac0000b9")), ("windowTitle", .string("王小明 的私信 – 微信")),
                                                  ("text", .string("验证码 834201"))]))])
        let t = try await URTestFlow.drive(rt, port, extra: [probe])
        for s in ["王小明", "微信", "834201"] { #expect(!t.wireText.contains(s), "\(s) leaked") }
        #expect(t.wireText.contains("unit.observation"))
        #expect(t.wireProblems.isEmpty)
    }
}

/// A broken Runtime for UR-G5: answers unit.run with a platform_durable Run.
final class URTestDurableClient: RuntimeClient {
    let inner: URTestClient
    var endpoint: Endpoint { inner.endpoint }
    init(server: URTestRuntime, role: ACPBridgeConnectionRole) { inner = URTestClient(server: server, role: role) }
    func handshake() throws -> RuntimeIdentity { try inner.handshake() }
    func call(_ request: RuntimeRequest) throws -> JSONValue {
        let v = try inner.call(request)
        guard request.method == "unit.run" else { return v }
        return v.setting("ownership", .string("platform")).setting("lifetime", .string("platform_durable"))
            .setting("origin", .string("gui_explorer"))
    }
    func subscribe(runId: String?, after: Int?) throws -> JSONValue { try inner.subscribe(runId: runId, after: after) }
    func nextEvent() throws -> PushedEvent { try inner.nextEvent() }
    func close() { inner.close() }
}
