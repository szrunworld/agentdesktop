import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

func code(of body: () async throws -> Void) async -> String? {
    do { try await body(); return nil } catch let e as RuntimeError { return e.code } catch { return "\(error)" }
}

/// Field names the plan adds later (methods.json plannedFields). None may
/// appear in a Mock answer before the contract has them.
let plannedFieldNames: Set<String> = [
    "control", "targetKind", "businessResult", "elapsedMs", "geometryRevision", "dispatchSequence",
    "proposalId", "inferenceAttemptId", "reconciliations", "captureSequence", "coverage", "unit",
    "episodeEligible", "excludedReason", "launch", "bind", "principal",
]

func keys(_ v: JSONValue) -> Set<String> {
    switch v {
    case .object(let m): return m.reduce(into: Set(m.map(\.key))) { $0.formUnion(keys($1.value)) }
    case .array(let a): return a.reduce(into: Set<String>()) { $0.formUnion(keys($1)) }
    default: return []
    }
}

@Suite("Mock Runtime")
struct MockRuntimeTests {
    // Every modeled method answers within the contract: its result passes
    // the result schema, and no planned field appears anywhere.
    @Test func answersStayInsideTheContract() async throws {
        let m = MockRuntime.sample()
        let desk = try await m.call("desktop.list")["desktops"]!.arrayValue!.first!["desktopId"]!
        let runs = try await m.call("run.list", .obj([("limit", .int(50))]))["runs"]!.arrayValue!
        let runId = runs.first!["runId"]!
        let calls: [(String, JSONValue)] = [
            ("runtime.handshake", .obj([("apiVersions", .array([.string(RuntimeAPI.version)])),
                                        ("client", .obj([("name", .string("t")), ("version", .string("1"))]))])),
            ("runtime.status", .obj([])), ("runtime.capabilities", .obj([])),
            ("desktop.list", .obj([])), ("desktop.show", .obj([("desktopId", desk)])),
            ("app.list", .obj([])), ("window.list", .obj([])),
            ("run.list", .obj([("desktopId", desk), ("active", .bool(true))])),
            ("run.show", .obj([("runId", runId)])), ("run.events", .obj([("runId", runId)])),
            ("request.show", .obj([("requestId", .string("req_001"))])),
            ("request.show", .obj([("requestId", .string("req_003"))])),
            ("desktop.create", .obj([("name", .string("新 Desktop")), ("width", .int(1440)), ("height", .int(900))])),
            ("run.cancel", .obj([("runId", runId)])),
            ("runtime.stopAll", .obj([("scope", .string("all_platform_runs"))])),
            ("runtime.enableInput", .obj([])),
            ("desktop.destroy", .obj([("desktopId", desk)])),
        ]
        var seen = Set<String>()
        for (method, params) in calls {
            let result = try await m.call(method, params)
            seen.insert(method)
            let spec = try #require(RuntimeContract.shared.method(method))
            #expect(RuntimeContract.shared.validate(result, spec.result).isEmpty, "\(method)")
            #expect(keys(result).isDisjoint(with: plannedFieldNames), "\(method) carries a planned field")
        }
        #expect(seen == Set(MockRuntime.modeled))
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    // Only implemented catalog methods exist; reserved and frozen ones do not.
    @Test func reservedAndFrozenMethodsAreMissing() async {
        let m = MockRuntime.sample()
        for method in ["hub.clients.list", "inbox.list", "run.reconcile", "unit.run", "desktop.stop",
                       "desktop.takeover", "request.list", "ai.connections.list", "no.such.method"] {
            #expect(await code { _ = try await m.call(method) } == "capability_missing", "\(method)")
        }
        #expect(Set(MockRuntime.modeled).isSubset(of: RuntimeCatalog.implemented))
        #expect(!RuntimeCatalog.implemented.contains("hub.clients.list"))
    }

    @Test func capabilitiesAdvertiseOnlyWhatIsModeled() async throws {
        let m = MockRuntime.sample()
        let caps = try await m.call("runtime.capabilities")
        let listed = Set(caps["interface"]!["methods"]!.arrayValue!.compactMap { $0["method"]?.stringValue })
        #expect(listed == Set(MockRuntime.modeled).union(["events.subscribe", "events.unsubscribe"]))
        m.subscriptionEnabled = false
        let without = try await m.call("runtime.capabilities")
        #expect(!(without["interface"]!["methods"]!.arrayValue!.contains { $0["method"]?.stringValue == "events.subscribe" }))
        #expect(await code { _ = try await m.subscribe(after: nil) } == "capability_missing")
    }

    @Test func paramsAreChecked() async {
        let m = MockRuntime.sample()
        #expect(await code { _ = try await m.call("desktop.show", .obj([])) } == "schema_invalid")
        #expect(await code { _ = try await m.call("run.list", .obj([("color", .string("x"))])) } == "schema_invalid")
        #expect(await code { _ = try await m.call("desktop.show", .obj([("desktopId", .string("nope"))])) } == "not_found")
    }

    @Test func offlineAndQueuedFailures() async {
        let m = MockRuntime.sample()
        m.failNext("desktop.list", code: "internal_error")
        #expect(await code { _ = try await m.call("desktop.list") } == "internal_error")
        #expect(await code { _ = try await m.call("desktop.list") } == nil)
        m.offline = true
        #expect(await code { _ = try await m.call("runtime.status") } == "runtime_offline")
        #expect(await code { _ = try await m.subscribe(after: nil) } == "runtime_offline")
    }

    // Stopping is a two-step state: accepted → stopping/pending, then
    // ended/confirmed only when the execution side reports quiet.
    @Test func cancelIsTwoStep() async throws {
        let m = MockRuntime.sample()
        let active = try await m.call("run.list", .obj([("active", .bool(true))]))["runs"]!.arrayValue!
        let id = active.first!["runId"]!.stringValue!
        let receipt = try await m.call("run.cancel", .obj([("runId", .string(id))]))
        #expect(receipt["execution"]?["phase"]?.stringValue == "stopping")
        #expect(receipt["execution"]?["quiescence"]?.stringValue == "pending")
        m.confirmQuiescence(id)
        let r = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(r["phase"]?.stringValue == "ended")
        #expect(r["quiescence"]?.stringValue == "confirmed")
        #expect(RunStatusPresentation.make(run: r).text == "已停止")
    }

    @Test func subscriptionCursor() async throws {
        let m = MockRuntime.sample()
        let latest = m.latestCursor
        let stream = try await m.subscribe(after: latest - 2)
        var it = stream.makeAsyncIterator()
        let f1 = try #require(try await it.next())
        #expect(f1["cursor"]?.intValue == latest - 1)
        #expect(RuntimeContract.shared.validate(f1, "EventFrame").isEmpty)
        m.trimEvents(through: latest)
        #expect(await code { _ = try await m.subscribe(after: 1) } == "events_cursor_expired")
    }
}
