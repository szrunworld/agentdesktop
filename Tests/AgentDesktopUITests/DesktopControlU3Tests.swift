import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

/// U3 (P12–P18) and the U2b degradations, against the mock's A5 lane.
/// Component level only: no real Runtime, window or app.
@MainActor
@Suite("Desktop control U3", .serialized)
struct DesktopControlU3Tests {
    /// Two Desktops, each with an agent's Run, Desktop.control on.
    func scenario() -> (MockRuntime, a: String, b: String, runA: String, runB: String) {
        let m = MockRuntime()
        let a = m.addDesktop(name: "表单验证", app: "Safari")
        let b = m.addDesktop(name: "文本编辑", app: "TextEdit")
        let client = m.addClient(name: "表单助手")
        let runA = m.addRun(desktopId: a, receipts: 2)
        let runB = m.addRun(desktopId: b, receipts: 1)
        m.setRunClient(runA, clientId: client)
        m.enableDesktopControl()
        return (m, a, b, runA, runB)
    }

    func desktop(_ m: MockRuntime, _ id: String) async throws -> JSONValue {
        try await m.call("desktop.show", .obj([("desktopId", .string(id))]))
    }

    func info(_ m: MockRuntime, _ id: String) async throws -> DesktopControlInfo {
        let runs = try await m.call("run.list", .obj([("active", .bool(true))]))["runs"]!.arrayValue!
        return DesktopControlInfo.make(desktop: try await desktop(m, id), activeRuns: runs)
    }

    func run(_ m: MockRuntime, _ id: String) async throws -> JSONValue {
        try await m.call("run.show", .obj([("runId", .string(id))]))
    }

    // UC06, UC07: a new Desktop waits; an agent's new Run becomes its
    // controller, named as Desktop.control names it.
    @Test func uc07_newConnectionBecomesController() async throws {
        let (m, a, _, runA, _) = scenario()
        let i = try await info(m, a)
        #expect(i.fromRuntime && i.state == "running")
        #expect(i.status == StatusText("Agent 操作中", .running))
        #expect(i.controller == "表单助手" && i.controllerRunId == runA && i.actionCount == 2)
        #expect(i.source == DesktopControlInfo.controlSource)
        #expect(i.transport == DesktopControlInfo.transportMissing, "runtime/1 has no transport field")

        let fresh = m.addDesktop(name: "空 Desktop")
        m.syncDesktopControls()
        #expect(try await info(m, fresh).status == StatusText("等待接入", .idle))
        let newRun = try m.agentStartsRun(fresh)
        let now = try await info(m, fresh)
        #expect(now.state == "running" && now.controllerRunId == newRun)
        #expect(m.contractViolations.isEmpty)
    }

    // UC08, UC09: a stop is accepted first; "已停止" only once the Run is
    // quiescent. UC10: B goes on.
    @Test func uc08to10_stopIsTwoStepAndLocal() async throws {
        let (m, a, b, runA, runB) = scenario()
        m.markActionInFlight(runA)
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.stop()
        #expect(flow.problems.isEmpty)
        #expect(flow.stopProgress == .accepted(runId: runA))
        #expect(flow.stopText?.title == "停止已受理，等待静止")
        let stopping = try await info(m, a)
        #expect(stopping.state == "stopping" && stopping.status.text == "正在停止")
        #expect(DesktopControlBannerText.make(stopping)?.title == "正在停止输入")
        #expect(!stopping.canStop, "the stop button greys out while stopping (P14)")
        // Re-reading while still in flight changes nothing.
        await flow.refresh()
        #expect(flow.stopProgress == .accepted(runId: runA))

        m.finishInFlight(runA)
        await flow.refresh()
        #expect(flow.stopProgress == .quiescent(runId: runA))
        #expect(flow.stopText?.title == "已停止")
        let stopped = try await info(m, a)
        #expect(stopped.state == "stopped" && stopped.status == StatusText("已停止", .idle))
        #expect(try await run(m, runA)["closingReason"]?.stringValue == "desktop_stop")

        // UC10: the other Desktop's Run and control are untouched.
        #expect(try await run(m, runB)["phase"]?.stringValue == "running")
        #expect(try await info(m, b).state == "running")
        // A new agent Run on the stopped Desktop is refused.
        #expect(throws: RuntimeError.self) { _ = try m.agentStartsRun(a) }
        #expect(m.contractViolations.isEmpty)
    }

    // A stop with nothing in flight is quiescent at once (run quiescence
    // confirmed in the receipt); with no Run at all it says so.
    @Test func stopWithoutInFlightOrRun() async throws {
        let (m, a, _, runA, _) = scenario()
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.stop()
        #expect(flow.stopProgress == .quiescent(runId: runA))
        let idle = m.addDesktop(name: "空")
        m.syncDesktopControls()
        let f2 = DesktopControlFlow(runtime: m, desktopId: idle)
        await f2.stop()
        #expect(f2.stopProgress == .quiescent(runId: nil))
        #expect(f2.stopText?.detail.contains("没有运行持有") == true)
    }

    // UC11–UC13: takeover goes through stopping; stop_pending is shown as
    // the Runtime gave it; after quiescence a new takeover hands the
    // Desktop to the user, agents are refused, B is untouched.
    @Test func uc11to13_takeoverThroughStopping() async throws {
        let (m, a, b, runA, runB) = scenario()
        m.markActionInFlight(runA)
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        flow.dialog = .takeover
        await flow.takeover()
        guard case .stopPending(let holder, _) = flow.takeoverAnswer else {
            Issue.record("expected stop_pending, got \(String(describing: flow.takeoverAnswer))"); return
        }
        #expect(holder == runA)
        #expect(DesktopControlFlow.takeoverText(flow.takeoverAnswer!)?.code == "stop_pending")
        #expect(flow.dialog == .takeover, "nothing was taken over yet")
        #expect(try await info(m, a).state == "stopping")
        #expect(!flow.holderQuiescent)

        m.finishInFlight(runA)
        await flow.refresh()
        #expect(flow.holderQuiescent)
        await flow.takeover()
        guard case .done(let answer) = flow.takeoverAnswer else { Issue.record("takeover not done"); return }
        #expect(answer["run"]?["origin"]?.stringValue == "user")
        #expect(answer["run"]?["ownership"]?.stringValue == "platform")
        #expect(flow.dialog == nil)
        let manual = try await info(m, a)
        #expect(manual.state == "manual" && manual.controller == "你（人工控制）")
        #expect(manual.status == StatusText("由你控制", .attention))
        #expect(DesktopControlBannerText.make(manual)?.action == .handback)
        #expect(DesktopControlBannerText.make(manual)?.detail.contains("control_busy") == true)
        do {
            _ = try m.agentStartsRun(a)
            Issue.record("an agent's Run was accepted during manual control")
        } catch let e as RuntimeError {
            #expect(e.code == "control_busy" && e.details?["reason"]?.stringValue == "manual_control")
        }
        // UC13
        #expect(try await run(m, runB)["phase"]?.stringValue == "running")
        #expect(try await info(m, b).state == "running")
        #expect(m.contractViolations.isEmpty)
    }

    // A takeover overtaken by a handback or stop: conflict / superseded,
    // shown as is; nothing taken over.
    @Test func takeoverSupersededIsShownAsIs() async throws {
        let (m, a, _, _, _) = scenario()
        m.supersedeNextTakeover(a)
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.takeover()
        guard case .superseded(let message) = flow.takeoverAnswer else { Issue.record("expected superseded"); return }
        #expect(message.contains("handed back or stopped"))
        let text = try #require(DesktopControlFlow.takeoverText(flow.takeoverAnswer!))
        #expect(text.code == "conflict · superseded" && text.detail.contains(message))
        #expect(try await info(m, a).state == "running", "nothing was taken over")
    }

    // UC15: handback reopens input, forgets observations, starts nothing;
    // a second handback answers handedBack false.
    @Test func uc15_handbackDoesNotReplay() async throws {
        let (m, a, _, runA, _) = scenario()
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.takeover()
        let userRun = flow.takeoverAnswer.flatMap { if case .done(let r) = $0 { return r["run"]?["runId"]?.stringValue }; return nil }
        let before = try await m.call("run.list", .obj([]))["runs"]!.arrayValue!.count
        let forgotten = m.observationsForgotten(a)
        await flow.handback()
        let h = try #require(flow.handbackAnswer)
        #expect(h["handedBack"]?.boolValue == true && h["observationsCleared"]?.boolValue == true)
        #expect(h["endedRunId"]?.stringValue == userRun)
        #expect(flow.handbackText?.detail.contains("旧队列不重放") == true)
        #expect(m.observationsForgotten(a) == forgotten + 1)
        let runs = try await m.call("run.list", .obj([]))["runs"]!.arrayValue!
        #expect(runs.count == before, "handback starts no Run")
        #expect(try await run(m, runA)["phase"]?.stringValue == "ended", "the agent's old Run is not resumed")
        #expect(try await info(m, a).state == "ready")
        await flow.handback()
        #expect(flow.handbackAnswer?["handedBack"]?.boolValue == false)
        #expect(flow.handbackText?.title == "没有需要交还的控制")
    }

    // UC16–UC18: the close plan blocks while a Run holds the Desktop, keeps
    // the user's shared app, quits only what this Desktop launched; a stop
    // first, then close; records stay; B goes on.
    @Test func uc16to18_closePlan() async throws {
        let (m, a, b, runA, runB) = scenario()
        let probe = m.addLaunchedApp(a, name: "Probe")
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.openClose()
        #expect(flow.dialog == .close)
        let plan = try #require(flow.closePlan)
        #expect(plan["canClose"]?.boolValue == false)
        #expect(CloseDesktopDialog.runBlocks(plan))
        let lines = CloseDesktopDialog.lines(plan)
        #expect(lines.contains { $0.0 == "阻止关闭" && $0.1.contains(runA) })
        #expect(lines.contains { $0.0 == "应用处理" && $0.1.contains("Safari") && $0.1.contains("不退出") })
        #expect(lines.contains { $0.0 == "将退出" && $0.1.contains("Probe") && $0.1.contains("pid \(probe)") })
        await flow.close()
        #expect(!m.callLog.contains("desktop.destroy"), "no destroy while the plan says it cannot close")

        await flow.stopBeforeClose()
        #expect(flow.closePlan?["canClose"]?.boolValue == true)
        await flow.close()
        #expect(flow.closed?["destroyed"]?.boolValue == true)
        let list = try await m.call("desktop.list")["desktops"]!.arrayValue!
        #expect(!list.contains { $0["desktopId"]?.stringValue == a })            // UC16
        let kept = try await m.call("run.list", .obj([("desktopId", .string(a))]))["runs"]!.arrayValue!
        #expect(kept.contains { $0["runId"]?.stringValue == runA })               // UC17
        #expect(try await run(m, runB)["phase"]?.stringValue == "running")       // UC18
        #expect(list.contains { $0["desktopId"]?.stringValue == b })
        #expect(m.contractViolations.isEmpty)
    }

    // A physical Desktop keeps its display and quits nothing.
    @Test func physicalClosePlanKeepsTheDisplay() async throws {
        let m = MockRuntime()
        m.addDisplay(id: 1, name: "内建显示器")
        let client = m.addClient(name: "助手")
        let attached = try await m.call("hub.displays.attach", .obj([("displayId", .int(1)), ("clientId", .string(client))]))
        let id = attached["desktop"]!["desktopId"]!.stringValue!
        m.enableDesktopControl()
        let flow = DesktopControlFlow(runtime: m, desktopId: id)
        await flow.loadClosePlan()
        let plan = try #require(flow.closePlan)
        #expect(plan["display"]?.stringValue == "kept" && plan["canClose"]?.boolValue == true)
        #expect(CloseDesktopDialog.lines(plan).first?.1.contains("保留不动") == true)
        await flow.resize(width: 1280, height: 800)
        #expect(flow.problems[.resize]?.code == "invalid_target")
    }

    // app.quit ends only what this Desktop launched; exited false is
    // "asked", not proof.
    @Test func appQuitOnlyLaunched() async throws {
        let (m, a, _, _, _) = scenario()
        let pid = m.addLaunchedApp(a, name: "Probe", bind: true)
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        m.quitExits = false
        await flow.quit(pid: pid)
        #expect(DesktopControlFlow.quitText(flow.quitAnswers[pid]!) == "已请求退出，尚未确认退出")
        m.quitExits = true
        await flow.quit(pid: pid)
        #expect(DesktopControlFlow.quitText(flow.quitAnswers[pid]!) == "已退出")
        #expect(flow.closePlan?["quit"]?.arrayValue?.isEmpty == true)
        await flow.quit(pid: 4242)
        #expect(flow.problems[.quit]?.code == "permission_denied")
        #expect(m.contractViolations.isEmpty)
    }

    @Test func resizeForgetsObservations() async throws {
        let (m, a, _, _, _) = scenario()
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.resize(width: 1440, height: 900)
        #expect(DesktopControlPresentation.sizeText(try #require(flow.resized)) == "1440 × 900")
        #expect(m.observationsForgotten(a) == 1)
        #expect(m.contractViolations.isEmpty)
    }

    // UC29–UC31: unknown result: no retry; ending is closed until a new
    // observation; the new observation leaves the receipt alone; ending
    // keeps the Run's outcome unknown.
    @Test func uc29to31_unknownResult() async throws {
        let (m, a, _, runA, _) = scenario()
        let req = m.addAction(runId: runA, delivery: "unknown", execution: "unknown")
        m.endWithUnknownAction(runA)
        let i = try await info(m, a)
        #expect(i.state == "unknown" && i.status.text == "结果未知")
        #expect(DesktopControlBannerText.make(i)?.action == .review)
        let activity = DesktopActivityLoader(runtime: m, desktopId: a)
        await activity.load(runs: try await m.call("run.list", .obj([]))["runs"]!.arrayValue!)
        let entry = try #require(activity.actions.first { $0.requestId == req })
        #expect(entry.presentation.level == .unknown && !entry.presentation.canRetry)

        let original = try await m.call("request.show", .obj([("requestId", .string(req))]))
        let review = UnknownResultReview(runtime: m, desktopId: a, entry: entry)
        #expect(!review.canEnd)                                                    // UC29
        await review.reobserve()
        #expect(review.canEnd && review.observation?["snapshotId"] != nil && review.image != nil)
        #expect(try await m.call("request.show", .obj([("requestId", .string(req))])) == original) // UC30
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        flow.dialog = .unknown(requestId: req)
        await flow.handback()
        await review.ended()
        #expect(flow.dialog == nil)
        #expect(review.runAfter?["outcome"]?.stringValue == "unknown")              // UC31
        #expect(try await info(m, a).state == "ready")
        #expect(!m.callLog.contains("act"), "nothing is retried")
    }

    @Test func disconnectedState() async throws {
        let (m, a, _, runA, _) = scenario()
        m.loseControlConnection(runA)
        let i = try await info(m, a)
        #expect(i.state == "disconnected" && i.status.text == "连接断开")
        #expect(DesktopControlBannerText.make(i)?.title == "Agent 连接已断开")
        #expect(i.canHandback)
    }

    // U2b: without Desktop.control the controller is derived and says so;
    // the reserved states read as such; "已停止" never comes from runs.
    @Test func u2b_degradationAndReservedStates() async throws {
        let m = MockRuntime.sample()
        let d = try await desktop(m, "desk_001")
        #expect(d["control"] == nil)
        let runs = try await m.call("run.list", .obj([("active", .bool(true))]))["runs"]!.arrayValue!
        let i = DesktopControlInfo.make(desktop: d, activeRuns: runs)
        #expect(!i.fromRuntime && i.source == DesktopControlPresentation.derivedSource)
        #expect(DesktopControlBannerText.make(i)?.detail == DesktopControlInfo.missingNote)

        m.enableDesktopControl()
        m.forceControlState("desk_003", "creating")
        let creating = try await info(m, "desk_003")
        #expect(creating.status == StatusText("创建中", .idle) && !creating.canStop && !creating.canTakeover)
        m.forceControlState("desk_003", "error")
        #expect(try await info(m, "desk_003").status.tone == .danger)
        #expect(DesktopControlInfo.status("stopping").text != "已停止")
        #expect(DesktopControlInfo.status("somethingNew").text.contains("somethingNew"))
        #expect(m.contractViolations.isEmpty)
    }

    // A Runtime without an A5 method greys its button out with the reason.
    @Test func missingMethodsGreyOut() {
        let caps: JSONValue = .obj([("interface", .obj([("methods", .array([
            .obj([("method", .string("desktop.list")), ("mutation", .bool(false)), ("stage", .string("P0"))]),
        ]))]))])
        let methods = DesktopControlMethods(capabilities: caps)
        let i = DesktopControlInfo(state: "running", status: DesktopControlInfo.status("running"), controller: "x",
                                   controllerRunId: nil, clientId: nil, since: nil, actionCount: 0,
                                   transport: DesktopControlInfo.transportMissing, source: DesktopControlInfo.controlSource)
        #expect(DesktopInspectorView.stopBlocked(i, methods: methods, connected: true) == "当前 Runtime 不提供 desktop.stop")
        #expect(DesktopInspectorView.takeoverBlocked(i, methods: methods, connected: true) == "当前 Runtime 不提供 desktop.takeover")
        #expect(DesktopInspectorView.stopBlocked(i, methods: .all, connected: true) == nil)
        #expect(DesktopInspectorView.stopBlocked(i, methods: .all, connected: false) == "Runtime 未连接")
    }

    // ADR-02: dropping the page's control model calls nothing.
    @Test func closingThePageStopsNothing() async throws {
        let (m, a, _, runA, _) = scenario()
        var flow: DesktopControlFlow? = DesktopControlFlow(runtime: m, desktopId: a)
        flow?.dialog = .takeover
        let calls = m.callLog.count
        flow = nil
        #expect(m.callLog.count == calls)
        #expect(try await run(m, runA)["phase"]?.stringValue == "running")
    }

    // Overview / side by side / preview stops: one flow per Desktop.
    @Test func perDesktopStopsAreIndependent() async throws {
        let (m, a, b, _, runB) = scenario()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let stops = DesktopStops(store: store)
        await stops.stop(a)
        #expect(stops.note(a) == "已停止")
        #expect(stops.note(b) == nil)
        #expect(try await run(m, runB)["phase"]?.stringValue == "running")
        let infoA = DesktopControlInfo.make(desktop: store.desktops.first { $0["desktopId"]?.stringValue == a }!, activeRuns: store.activeRuns)
        #expect(infoA.state == "stopped", "the store re-read the Desktops after the stop")
        #expect(!stops.canStop(a, info: infoA, methods: .all))
    }
}

@MainActor
@Suite("Desktop control answers")
struct DesktopControlAnswerTests {
    // An old "已停止" goes once a new Run holds the Desktop again.
    @Test func oldAnswersGoWhenTheStateMovesOn() async throws {
        let m = MockRuntime()
        let a = m.addDesktop(name: "A")
        _ = m.addRun(desktopId: a)
        m.enableDesktopControl()
        let flow = DesktopControlFlow(runtime: m, desktopId: a)
        await flow.stop()
        flow.settle(state: "stopped")
        #expect(flow.stopText?.title == "已停止")
        await flow.handback()
        #expect(flow.stopText == nil && flow.handbackText?.title == "已交还")
        flow.settle(state: "running")
        #expect(flow.handbackText != nil)
        flow.settle(state: "stopping")
        #expect(flow.handbackText == nil)
    }
}
