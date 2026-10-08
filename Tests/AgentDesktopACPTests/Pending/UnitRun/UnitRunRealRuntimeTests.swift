import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Layer: Real (not run). The same flows against a real Runtime test copy
// once A6 lands. Disabled: they must not be enabled before 40's unit.run is
// merged and announced in runtime.capabilities. Run only against a test copy
// under /tmp/adt-* (docs/acp/tests/e2e-runbook.md §二), never the product
// endpoint:
//
//   AGENTDESKTOP_ENDPOINT=/tmp/adt-acp/.../control.sock \
//   URTEST_DESKTOP_ID=<a test Desktop with Calculator bound> swift test --filter UnitRunRealRuntimeTests
//
// The scenario fixtures (Fixtures/ur-*.json) carry the expectations; the
// fake Runtime's own checks do not apply here.

enum URTestReal {
    static func endpoint() throws -> Endpoint {
        let raw = ProcessInfo.processInfo.environment["AGENTDESKTOP_ENDPOINT"] ?? ""
        // Never the product endpoint (README §四 rule 7): realpath-based
        // allowlist that throws (URTestEndpointGuard; the shared
        // ACPTestEndpointGuard after #141).
        return Endpoint(path: try URTestEndpointGuard.check(raw), source: .environment)
    }

    static func desktopId() throws -> String {
        guard let d = ProcessInfo.processInfo.environment["URTEST_DESKTOP_ID"], !d.isEmpty else { throw URTestRealError.noDesktop }
        return d
    }

    static func port() throws -> ACPBridgeRuntimePort {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("urtest-real-\(UUID().uuidString)")
        return ACPBridgeRuntimePort(makeClient: ACPBridgeConfiguration.socketFactory(endpoint: try endpoint()),
                                    log: try ACPSubmissionLog(path: dir.appendingPathComponent("submissions.json").path))
    }

    static func client() throws -> SocketRuntimeClient {
        SocketRuntimeClient(endpoint: try endpoint(), info: ClientInfo(name: "urtest-real", version: "0"), timeout: 10)
    }

    /// Drive one fixture against the real Runtime through the real bridge,
    /// projector and wire (same driver as the Mock flow).
    static func drive(_ name: String) async throws -> URTestTrace {
        var raw = try URTestScenario.json(name)
        raw = raw.setting("desktopId", .string(try desktopId()))
        let rt = URTestRuntime(URTestScenario(raw: raw)) // scenario holder only; never called
        return try await URTestFlow.drive(rt, try port(), key: "urtest-real-\(name)-\(UUID().uuidString)")
    }
}

enum URTestRealError: Error { case noDesktop }

@Suite("UR · Real (not run) · unit.run against a Runtime test copy", .serialized)
struct UnitRunRealRuntimeTests {
    @Test("[Real·not run] realRuntimeAdvertisesUnitRunAndACPOffersTheTask", .disabled("waiting for A6 unit.run: runtime.capabilities does not list unit.run yet (40, PR2d #50)"))
    func realRuntimeAdvertisesUnitRunAndACPOffersTheTask() async throws {
        let tasks = try await URTestReal.port().tasks()
        #expect(tasks.contains { $0.taskType.hasPrefix("unit.run") })
    }

    @Test("[Real·not run] realNormalCompletion", .disabled("waiting for A6 unit.run: no handler; G1-06/G1-11 normal class"))
    func realNormalCompletion() async throws {
        let t = try await URTestReal.drive("ur-normal")
        #expect(t.runId != nil)
        #expect(t.actionLevels.contains("executed"))
        #expect(!t.wireText.contains("已验证"))
        #expect(t.wireProblems.isEmpty)
    }

    @Test("[Real·not run] realCancel", .disabled("waiting for A6 unit.run: no handler; G2-05 cancel class"))
    func realCancel() async throws {
        let t = try await URTestReal.drive("ur-cancel")
        #expect(t.planResult == "结果：已取消")
        #expect(t.wireProblems.isEmpty)
    }

    @Test("[Real·not run] realDisconnectEndsOwnerLost", .disabled("waiting for A6 unit.run: no handler; ACP-29 / G1-10 / G3-03 disconnect class (Mock part runs today)"))
    func realDisconnectEndsOwnerLost() async throws {
        let t = try await URTestReal.drive("ur-disconnect")
        let runId = try #require(t.runId)
        // Read the Run on a fresh connection: ended, owner_lost, no new input.
        let c = try URTestReal.client()
        defer { c.close() }
        var run = try c.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))
        for _ in 0..<50 where run["phase"]?.stringValue != "ended" {
            try await Task.sleep(for: .milliseconds(200))
            run = try c.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))
        }
        #expect(run["phase"]?.stringValue == "ended")
        #expect(run["closingReason"]?.stringValue == "owner_lost")
        #expect(run["lifetime"]?.stringValue == "connection_scoped")
    }

    @Test("[Real·not run] realApprovalRejected", .disabled("waiting for A6 unit.run and PR4 inbox: approval-rejected class needs a Runtime approval source"))
    func realApprovalRejected() async throws {
        let t = try await URTestReal.drive("ur-approval-rejected")
        #expect(t.actionUpdates.isEmpty)
    }

    @Test("[Real·not run] realUnknownIsTerminal", .disabled("waiting for A6 unit.run: unknown class needs an executor without receipt (G3-01, G3-14)"))
    func realUnknownIsTerminal() async throws {
        let t = try await URTestReal.drive("ur-unknown")
        #expect(t.actionUpdates.last?["rawOutput"] == .obj([("execution", .string("terminated")), ("outcome", .string("unknown"))]))
    }

    @Test("[Real·not run] realRuntimeRefusesEscalationAndCreatesNoRun", .disabled("waiting for A6 unit.run: escalation refusal is the handler's (F40-06 row 1); code to be confirmed, Q1"))
    func realRuntimeRefusesEscalationAndCreatesNoRun() async throws {
        let c = try URTestReal.client()
        defer { c.close() }
        let before = try c.call(RuntimeRequest(.runList, params: .obj([])))["runs"]?.arrayValue?.count ?? 0
        let params = try URTestScenario.json("ur-escalation")["base"]!
            .urAdding("desktopId", .string(try URTestReal.desktopId())).urAdding("lifetime", .string("platform_durable"))
        let rid = "urtest-esc-\(UUID().uuidString.prefix(8).lowercased())"
        #expect { _ = try c.call(RuntimeRequest(requestId: rid, method: "unit.run", params: params)) } throws: {
            ["ownership_escalation_denied", "schema_invalid"].contains(($0 as? RuntimeError)?.code ?? "")
        }
        let after = try c.call(RuntimeRequest(.runList, params: .obj([])))["runs"]?.arrayValue?.count ?? 0
        #expect(after == before)
        let rec = try c.call(RuntimeRequest(.requestShow, params: .obj([("requestId", .string(rid))])))
        #expect(rec["state"]?.stringValue == "failed")
    }

    @Test("[Real·not run] realPrecheckRefusalWritesAFailedRecord", .disabled("waiting for A6 unit.run: precheck refusal writes a failed RequestRecord (07 §〇 R1)"))
    func realPrecheckRefusalWritesAFailedRecord() async throws {
        let c = try URTestReal.client()
        defer { c.close() }
        let params = try URTestScenario.json("ur-normal")["input"]!.urAdding("desktopId", .string("desk_doesnotexist"))
        let rid = "urtest-pre-\(UUID().uuidString.prefix(8).lowercased())"
        #expect { _ = try c.call(RuntimeRequest(requestId: rid, method: "unit.run", params: params)) } throws: {
            ($0 as? RuntimeError)?.code == "not_found"
        }
        let rec = try c.call(RuntimeRequest(.requestShow, params: .obj([("requestId", .string(rid))])))
        #expect(rec["state"]?.stringValue == "failed")
    }
}
