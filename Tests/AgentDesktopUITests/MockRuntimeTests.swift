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
            ("hub.clients.list", .obj([])), ("hub.grants.list", .obj([])), ("hub.displays.list", .obj([])),
            ("hub.displays.attach", .obj([("displayId", .int(1)), ("clientId", .string("app:mock-001"))])),
            ("hub.displays.detach", .obj([("desktopId", .string("desk_004"))])),
            ("desktop.create", .obj([("name", .string("新 Desktop")), ("width", .int(1440)), ("height", .int(900))])),
            ("run.cancel", .obj([("runId", runId)])),
            ("runtime.stopAll", .obj([("scope", .string("all_platform_runs"))])),
            ("runtime.enableInput", .obj([])),
            ("app.launch", .obj([("desktopId", desk), ("bundleId", .string("com.example.probe")), ("newInstance", .bool(true))])),
            ("window.bind", .obj([("desktopId", desk), ("pid", .int(4242))])),
            ("observe", .obj([("elements", .bool(false))])),
            ("desktop.destroy", .obj([("desktopId", desk)])),
        ]
        m.addFreeWindow(pid: 4242, windowId: 9001)
        var seen = Set<String>()
        for (method, params) in calls {
            let context = method == "observe" ? RequestContext(desktopId: desk.stringValue) : RequestContext()
            let result = try await m.call(method, params, context: context)
            if method == "observe" {
                let art = result["image"]!["artifactId"]!
                for (am, ap) in [("artifact.show", JSONValue.obj([("artifactId", art)])), ("artifact.read", .obj([("artifactId", art)]))] {
                    let r = try await m.call(am, ap)
                    seen.insert(am)
                    #expect(RuntimeContract.shared.validate(r, RuntimeContract.shared.method(am)!.result).isEmpty, "\(am)")
                }
            }
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
        for method in ["hub.clients.show", "inbox.list", "run.reconcile", "unit.run", "desktop.closePlan",
                       "desktop.resize", "request.list", "ai.connections.list", "no.such.method"] {
            #expect(await code { _ = try await m.call(method) } == "capability_missing", "\(method)")
        }
        #expect(Set(MockRuntime.modeled).isSubset(of: RuntimeCatalog.implemented))
        #expect(!RuntimeCatalog.implemented.contains("inbox.list"))
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

    // Stop events mirror production ExecutionCoordinator: `stop.accepted`
    // with the stop's reason (run.cancel → stopped, stopAll → global_stop),
    // and the terminal events carry the Run's revision and that reason.
    @Test(arguments: [("run.cancel", "stopped"), ("runtime.stopAll", "global_stop")])
    func stopEventsCarryRevisionAndReason(_ method: String, _ reason: String) async throws {
        let m = MockRuntime.sample()
        let active = try await m.call("run.list", .obj([("active", .bool(true))]))["runs"]!.arrayValue!
        let id = active.first!["runId"]!.stringValue!
        let start = m.latestCursor
        let stream = try await m.subscribe(after: start)
        _ = try await m.call(method, method == "run.cancel" ? .obj([("runId", .string(id))]) : .obj([("scope", .string("all_platform_runs"))]))
        m.confirmQuiescence(id)
        let r = try await m.call("run.show", .obj([("runId", .string(id))]))
        var it = stream.makeAsyncIterator()
        var byType: [String: JSONValue] = [:]
        for _ in 0..<(m.latestCursor - start) {
            let e = try #require(try await it.next())["event"]!
            guard e["runId"]?.stringValue == id else { continue }
            byType[e["type"]!.stringValue!] = e["data"]
        }
        #expect(byType["run.finishing"] == nil)
        let accepted = try #require(byType["stop.accepted"])
        let quiescent = try #require(byType["run.quiescent"])
        let ended = try #require(byType["run.ended"])
        #expect(accepted["reason"]?.stringValue == reason)
        #expect(accepted["revision"]?.intValue ?? 0 > 1)
        #expect(quiescent["revision"] == r["revision"])
        #expect(quiescent["revision"]?.intValue ?? 0 > accepted["revision"]?.intValue ?? 0)
        #expect(r["closingReason"]?.stringValue == reason)
        #expect(ended["reason"]?.stringValue == reason)
        #expect(ended["outcome"]?.stringValue == r["outcome"]?.stringValue)
    }

    // A second stop of an already-stopping Run (run.cancel, then stopAll
    // before quiescence) keeps the first reason and revision, as
    // ExecutionCoordinator.stop does; the event still reports the new
    // request's reason at the unchanged revision.
    @Test func secondStopKeepsTheFirstReason() async throws {
        let m = MockRuntime.sample()
        let active = try await m.call("run.list", .obj([("active", .bool(true))]))["runs"]!.arrayValue!
        let id = active.first!["runId"]!.stringValue!
        let start = m.latestCursor
        let stream = try await m.subscribe(after: start)
        _ = try await m.call("run.cancel", .obj([("runId", .string(id))]))
        let stopping = try await m.call("run.show", .obj([("runId", .string(id))]))
        _ = try await m.call("runtime.stopAll", .obj([("scope", .string("all_platform_runs"))]))
        let again = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(again["closingReason"]?.stringValue == "stopped")
        #expect(again["revision"] == stopping["revision"])
        m.confirmQuiescence(id)
        var it = stream.makeAsyncIterator()
        var mine: [JSONValue] = []
        for _ in 0..<(m.latestCursor - start) {
            let e = try #require(try await it.next())["event"]!
            if e["runId"]?.stringValue == id { mine.append(e) }
        }
        let stops = mine.filter { $0["type"]?.stringValue == "stop.accepted" }.compactMap { $0["data"] }
        #expect(stops.map { $0["reason"]?.stringValue } == ["stopped", "global_stop"])
        #expect(stops.map { $0["revision"] } == [stopping["revision"], stopping["revision"]])
        let ended = try #require(mine.last { $0["type"]?.stringValue == "run.ended" }?["data"])
        #expect(ended["reason"]?.stringValue == "stopped")
    }

    // A Run with an unknown action ends unknown whatever the stop asked for.
    @Test func unknownIsNeverOverwrittenAtQuiescence() async throws {
        let m = MockRuntime()
        let d = m.addDesktop(name: "D", app: "Probe")
        let id = m.addRun(desktopId: d, unknownActions: 1)
        _ = try await m.call("run.cancel", .obj([("runId", .string(id))]))
        m.confirmQuiescence(id)
        let r = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(r["outcome"]?.stringValue == "unknown")
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
