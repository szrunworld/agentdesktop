import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

/// run.list with a real cursor (the mock answers every Run at once).
final class PagedRunsPort: RuntimePort, @unchecked Sendable {
    let inner: MockRuntime
    private let lock = NSLock()
    private var _params: [JSONValue] = []
    var isSample: Bool { true }
    init(_ inner: MockRuntime) { self.inner = inner }
    var listParams: [JSONValue] { lock.withLock { _params } }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        guard method == "run.list" else { return try await inner.call(method, params, context: context) }
        lock.withLock { _params.append(params) }
        var p = params.setting("limit", .int(200))
        if p["cursor"] != nil { p = .obj((p.objectMembers ?? []).filter { $0.key != "cursor" }) }
        let all = try await inner.call("run.list", p)["runs"]!.arrayValue!
        let offset = params["cursor"]?.stringValue.flatMap(Int.init) ?? 0
        let limit = params["limit"]?.intValue ?? 50
        let page = Array(all.dropFirst(offset).prefix(limit))
        let next: JSONValue = offset + page.count < all.count ? .string(String(offset + page.count)) : .null
        return .obj([("runs", .array(page)), ("next", next)])
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> { try await inner.subscribe(after: after) }
}

@MainActor
@Suite("Runs (U5)", .serialized)
struct RunsU5Tests {
    func run(_ kind: String, _ phase: String, _ outcome: String?, quiescence: String? = nil, unit: String? = nil) -> JSONValue {
        var m: [(String, JSONValue)] = [("kind", .string(kind)), ("phase", .string(phase)),
                                        ("outcome", outcome.map(JSONValue.string) ?? .null),
                                        ("quiescence", .string(quiescence ?? (phase == "ended" ? "confirmed" : "not_confirmed")))]
        if let unit { m.append(("unit", .obj([("verification", .obj([("status", .string(unit))]))]))) }
        return .obj(m)
    }

    // §6.4 for Runs: act success is only delivered; unknown asks for a
    // check; a unit's verification has its own three values.
    @Test func runWords() {
        #expect(RunsText.outcome(run("act", "ended", "success")).text == "已投递")
        #expect(RunsText.summary(run("act", "ended", "success")).text == "已投递")
        #expect(RunsText.outcome(run("exec", "ended", "success")).text == "成功")
        #expect(RunsText.outcome(run("act", "ended", "unknown")).text == "结果未知 · 需要核实")
        #expect(RunsText.summary(run("act", "ended", "unknown")).text == "结果未知 · 需要核实")
        #expect(RunsText.summary(run("act", "stopping", nil, quiescence: "pending")).text == "停止中")
        #expect(RunsText.quiescence(run("act", "stopping", nil, quiescence: "pending")).text == "等待静止证据")
        #expect(RunsText.outcome(run("act", "running", nil)).text == "尚无结果")
        #expect(RunsText.verification(run("act", "ended", "success"))?.text == "未请求验证")
        #expect(RunsText.verification(run("exec", "ended", "success")) == nil)
        #expect(RunsText.verification(run("unit", "ended", "success", unit: "matched"))?.text == "已验证成功")
        #expect(RunsText.verification(run("unit", "ended", "failed", unit: "contradicted"))?.text == "验证未通过")
        #expect(RunsText.verification(run("unit", "ended", "success", unit: "inconclusive"))?.text == "无法判定")
        #expect(RunsText.verification(run("unit", "ended", "success", unit: "not_run"))?.text == "未验证")
        // A unit that finished shows its verification, not "success".
        #expect(RunsText.summary(run("unit", "ended", "success", unit: "inconclusive")).text == "无法判定")
        #expect(RunsText.summary(run("unit", "ended", "failed", unit: "contradicted")).text == "失败")
        #expect(RunsText.outcome(run("unit", "ended", "success", unit: "matched")).text == "已完成")
    }

    func receipt(_ d: String, _ e: String, reason: String? = nil) -> JSONValue {
        var m: [(String, JSONValue)] = [("receiptId", .string("rc")), ("requestId", .string("req_1")), ("delivery", .string(d)),
                                        ("execution", .string(e)), ("verification", .string("not_requested")),
                                        ("snapshotId", .string("snap_1"))]
        if let reason { m.append(("reason", .obj([("code", .string(reason)), ("message", .string("m"))]))) }
        return .obj(m)
    }

    // Three levels, each its own row, and one summary; no retry anywhere.
    @Test func actionLevels() {
        let done = ActionLevels.receipt(receipt("dispatched", "completed"))
        #expect(done.summary.text == "已执行，未验证")
        #expect(done.delivery == "已投递（dispatched）")
        #expect(done.execution == "已执行（completed）")
        #expect(done.verification == "未请求（平台不判断目标是否变化）")
        let notSent = ActionLevels.receipt(receipt("not_dispatched", "failed", reason: "target_moved"))
        #expect(notSent.summary.text == "未发出")
        #expect(notSent.reasonCode == "target_moved")
        let unknown = ActionLevels.receipt(receipt("unknown", "unknown"))
        #expect(unknown.summary.text == "结果未知 · 需要核实")
        #expect(unknown.needsReconciliation && !unknown.canRetry)
        #expect(ActionLevels.receipt(receipt("dispatched", "failed")).summary.text == "执行失败")
        #expect(ActionLevels.receipt(nil).summary.text == "已受理")
        let refused = ActionLevels.receipt(nil, refused: .obj([("code", .string("input_disabled")), ("message", .string("m"))]))
        #expect(refused.summary.text == "未发出" && refused.reasonCode == "input_disabled")

        // Records: input methods by their receipt, others by state.
        let rec: (String, JSONValue?) -> JSONValue = { state, outcome in
            .obj([("requestId", .string("req_9")), ("method", .string("desktop.create")), ("state", .string(state)),
                  ("acceptedAt", .string("2026-10-11T00:00:00Z"))] + (outcome.map { [("outcome", $0)] } ?? []))
        }
        #expect(ActionLevels.record(rec("completed", .obj([("desktopId", .string("d"))]))).summary.text == "已完成")
        #expect(ActionLevels.record(rec("accepted", nil)).summary.text == "已受理")
        #expect(ActionLevels.record(rec("unknown", nil)).summary.text == "结果未知 · 需要核实")
        #expect(ActionLevels.record(rec("completed", receipt("dispatched", "completed"))).summary.text == "已执行，未验证")
        // The ledger's shape: a success under outcome.data.
        let stored = ActionLevels.record(rec("completed", .obj([("data", receipt("dispatched", "completed"))])))
        #expect(stored.summary.text == "已执行，未验证" && stored.hasReceipt)
        #expect(ActionLevels.record(rec("completed", .obj([("data", .obj([("desktopId", .string("d"))]))]))).summary.text == "已完成")
        let err = RuntimeError("target_moved", "m", phase: .handler, notSent: true,
                               details: .obj([("receipt", receipt("not_dispatched", "failed"))])).json
        let r = ActionLevels.record(rec("failed", .obj([("error", err)])))
        #expect(r.summary.text == "未发出" && r.reasonCode == "target_moved")
        let refusal = ActionLevels.record(rec("failed", .obj([("error", RuntimeError("input_disabled", "m", phase: .handler, notSent: true).json)])))
        #expect(refusal.summary.text == "未发出" && refusal.reasonCode == "input_disabled")
    }

    // The mock's request.list and request.export keep the contract (its
    // results are schema-checked) and the filters.
    @Test func mockLedger() async throws {
        let m = MockRuntime.sample()
        m.addAcceptedRequest(method: "desktop.create")
        let all = try await m.call("request.list", .obj([]))["requests"]!.arrayValue!
        #expect(all.count == 7)
        #expect(all.allSatisfy { $0["clientId"] != nil })
        #expect(all.filter { $0["desktopId"] != nil }.count == 6)
        // Successes are kept under outcome.data, as the Runtime's ledger does.
        let done = all.first { $0["state"]?.stringValue == "completed" }!
        #expect(done["outcome"]?["data"]?["delivery"]?.stringValue == "dispatched")
        #expect(ActionsRecord.receipt(of: done) != nil)
        let stamps = all.map { $0["acceptedAt"]!.stringValue! }
        #expect(stamps == stamps.sorted(by: >), "newest first")
        let unknown = try await m.call("request.list", .obj([("state", .string("unknown"))]))["requests"]!.arrayValue!
        #expect(unknown.count == 1)
        let page = try await m.call("request.list", .obj([("limit", .int(4))]))
        #expect(page["requests"]!.arrayValue!.count == 4)
        let rest = try await m.call("request.list", .obj([("limit", .int(4)), ("cursor", page["next"]!)]))
        #expect(rest["requests"]!.arrayValue!.count == 3 && rest["next"]!.isNull)
        let export = try await m.call("request.export", .obj([("desktopId", .string("desk_001"))]))
        #expect(export["count"]?.intValue == 4)
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func actionRecordsLoader() async throws {
        let m = MockRuntime.sample()
        let loader = ActionRecordsLoader(runtime: m, pageSize: 4)
        await loader.reload()
        #expect(loader.state == .loaded)
        #expect(loader.records.count == 4 && loader.next != nil)
        await loader.loadMore()
        #expect(loader.records.count == 6 && loader.next == nil)
        // A refresh keeps every loaded record.
        await loader.reload()
        #expect(loader.records.count == 6)
        #expect(loader.search("req_002").count == 1)
        #expect(loader.search("act").count == 6)
        await loader.apply(.init(desktopId: "desk_002"))
        #expect(loader.records.count == 2)
        #expect(Set(loader.records.map { ActionLevels.record($0).summary.text }) == ["已执行，未验证", "结果未知 · 需要核实"])
        await loader.apply(.init(state: "failed"))
        #expect(loader.records.count == 1)
        #expect(ActionLevels.record(loader.records[0]).reasonCode == "target_moved")
        await loader.exportRecords()
        let e = try #require(loader.export)
        #expect(e.count == 1)
        let doc = try StrictJSON.parse(e.data)
        #expect(doc["requests"]?.arrayValue?.first?["requestId"] == loader.records[0]["requestId"])
        #expect(doc["filter"]?["state"]?.stringValue == "failed")
        // Without request.list: an error, never sample records.
        m.failNext("request.list", code: "capability_missing")
        await loader.reload()
        if case .failed(let p) = loader.state { #expect(p.code == "capability_missing") } else { Issue.record("not failed") }
        m.offline = true
        await loader.reload()
        if case .disconnected = loader.state {} else { Issue.record("not disconnected") }
    }

    @Test func runListLoader() async {
        let m = MockRuntime.sample()
        let desk = "desk_003"
        m.addUnitRun(desktopId: desk, verification: "inconclusive")
        let u = m.addRun(desktopId: desk, phase: "ended", outcome: "unknown", unknownActions: 1)
        let port = PagedRunsPort(m)
        let loader = RunListLoader(runtime: port, pageSize: 2)
        await loader.reload()
        #expect(loader.runs.count == 2 && loader.next != nil)
        await loader.loadMore()
        #expect(loader.runs.count == 4 && loader.next != nil)
        await loader.loadMore()
        #expect(loader.runs.count == 5 && loader.next == nil)
        // A refresh re-reads from the top and keeps every loaded Run.
        await loader.reload()
        #expect(loader.runs.count == 5)
        await loader.apply(.init(origin: "gui_explorer"))
        #expect(loader.runs.map { $0["kind"]?.stringValue } == ["unit"])
        #expect(port.listParams.last?["origin"]?.stringValue == "gui_explorer")
        await loader.apply(.init(active: true))
        #expect(loader.runs.count == 2)
        #expect(port.listParams.last?["active"]?.boolValue == true)
        // Ended Runs are asked by phase: the Runtime reads active:false as no filter.
        await loader.apply(.init(active: false))
        #expect(port.listParams.last?["phase"]?.stringValue == "ended")
        #expect(port.listParams.last?["active"] == nil)
        #expect(loader.runs.allSatisfy { $0["phase"]?.stringValue == "ended" })
        await loader.apply(.init(unknownOnly: true))
        #expect(loader.shown.map { $0["runId"]?.stringValue } == [u], "the Run with an unknown result")
        await loader.apply(.init(desktopId: "desk_none"))
        #expect(loader.state == .empty)
    }

    // Stopping shows the Runtime's answer and stays 停止中 until quiescence.
    @Test func stopIsNotStopped() async throws {
        let m = MockRuntime.sample()
        let loader = RunDetailLoader(runtime: m, runId: "run_002")
        await loader.load()
        await loader.stop()
        #expect(loader.stopAnswer?.hasPrefix("已受理") == true)
        #expect(loader.run?["phase"]?.stringValue == "stopping")
        #expect(RunsText.summary(loader.run!).text == "停止中")
        m.confirmQuiescence("run_002")
        await loader.load()
        #expect(RunsText.phase(loader.run!).text == "已结束")
        #expect(loader.events.contains { $0["type"]?.stringValue == "run.quiescent" })
        await loader.stop()
        #expect(loader.stopAnswer == "运行已经结束，无需停止")
    }

    // A refused input is 未发出 with its reason, in the detail and on the
    // Desktop's recent actions.
    @Test func refusedActionsSayNotSent() async {
        let m = MockRuntime.sample()
        m.addRefusedAction(runId: "run_002", code: "input_disabled")
        let loader = RunDetailLoader(runtime: m, runId: "run_002")
        await loader.load()
        let a = loader.actions.first!
        #expect(a.levels.summary.text == "未发出")
        #expect(a.presentation.level == .notDispatched)
        #expect(a.levels.reasonCode == "input_disabled")
        #expect(RunsText.eventTitle("action.refused") == "动作被拒绝，未发出")
    }

    @Test func unitRunDetail() async {
        let m = MockRuntime.sample()
        let id = m.addUnitRun(desktopId: "desk_003", verification: "matched")
        let loader = RunDetailLoader(runtime: m, runId: id)
        await loader.load()
        #expect(loader.run?["unit"]?["verification"]?["status"]?.stringValue == "matched")
        #expect(loader.events.contains { $0["type"]?.stringValue == "unit.verification" })
        #expect(RunsText.summary(loader.run!).text == "已验证成功")
        #expect(m.contractViolations.isEmpty)
    }

    // A refresh after newer items arrived keeps the item pushed across the
    // page boundary, and drops one that left the first page's range.
    @Test func refreshKeepsThePageBoundary() {
        func r(_ id: String) -> JSONValue { .obj([("requestId", .string(id))]) }
        let old = (0..<6).map { r("o\($0)") }   // first page was o0…o3, then o4, o5
        let first = [r("n"), r("o0"), r("o1"), r("o2")]   // limit 4: o3 crossed the boundary
        #expect(RunListLoader.tail(after: first, of: old, key: "requestId")?.map { $0["requestId"]!.stringValue! } == ["o3", "o4", "o5"])
        let gone = [r("o0"), r("o2"), r("o3"), r("o4")]   // o1 left the range
        #expect(RunListLoader.tail(after: gone, of: old, key: "requestId")?.map { $0["requestId"]!.stringValue! } == ["o5"])
        // Nothing shared: more arrived than a page holds; old pages go.
        #expect(RunListLoader.tail(after: [r("x")], of: old, key: "requestId") == nil)
    }

    @Test func prettyJSONKeepsOrderAndParses() throws {
        let v = JSONValue.obj([("b", .int(1)), ("a", .array([.string("x\"y"), .null])), ("c", .obj([]))])
        let s = ActionsRecord.prettyJSON(v)
        #expect(s.firstIndex(of: "b")! < s.firstIndex(of: "a")!)
        #expect(try StrictJSON.parse(s) == v)
    }
}
