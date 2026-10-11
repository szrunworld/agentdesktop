import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

/// Lane UI-E (U7 GUI Explorer, P27–P29). Component-level checks only: the
/// Mock Runtime, the presentation derived from contract data, and off-screen
/// renders. No real Runtime, window, model or input is involved.
@MainActor
@Suite("GUI Explorer (U7)", .serialized)
struct ExplorerTests {
    // MARK: Mock: one RunStore, two ways in

    @Test func wireUnitRunIsAlwaysDelegated() async throws {
        #expect(RuntimeCatalog.implemented.contains("unit.run"))
        #expect(MockRuntime.modeled.contains("unit.run"))
        let m = MockRuntime.sample()
        let calc = try #require(m.desktopIds.last)
        let run = try await m.call("unit.run", MockRuntime.sampleUnitParams(desktopId: calc))
        #expect(run["kind"]?.stringValue == "unit")
        #expect(run["origin"]?.stringValue == "agent_hub")
        #expect(run["ownership"]?.stringValue == "external_client")
        #expect(run["lifetime"]?.stringValue == "connection_scoped")
        // origin / lifetime / ownership in params are refused on the wire.
        for (k, v) in [("origin", "gui_explorer"), ("lifetime", "platform_durable"), ("ownership", "platform")] {
            let m2 = MockRuntime.sample()
            let p = MockRuntime.sampleUnitParams(desktopId: try #require(m2.desktopIds.last)).setting(k, .string(v))
            await #expect { try await m2.call("unit.run", p) } throws: { ($0 as? RuntimeError)?.code == "ownership_escalation_denied" }
            #expect(m2.durableStartCalls.isEmpty)
        }
        #expect(m.contractViolations.isEmpty && m.explorerContractViolations.isEmpty)
    }

    @Test func durableStartIsPlatformOwnedAndInTheSameRunList() async throws {
        let m = MockRuntime.sample()
        let calc = try #require(m.desktopIds.last)
        let started = m.startDurableUnitRun(params: MockRuntime.sampleUnitParams(desktopId: calc))
        let run = try started.get()
        #expect(run["origin"]?.stringValue == "gui_explorer")
        #expect(run["ownership"]?.stringValue == "platform")
        #expect(run["lifetime"]?.stringValue == "platform_durable")
        #expect(run["unit"]?["verification"]?["status"]?.stringValue == "not_run")
        // The same run.list the Runs entry reads.
        let list = try await m.call("run.list", .obj([("limit", .int(200))]))["runs"]!.arrayValue!
        #expect(list.contains { $0["runId"] == run["runId"] })
        #expect(!m.callLog.contains("unit.run"), "the main window never starts on the wire")
        // Escalation fields are refused here too, and nothing is created.
        let before = list.count
        let refused = m.startDurableUnitRun(params: MockRuntime.sampleUnitParams(desktopId: calc).setting("origin", .string("user")))
        if case let .failure(e) = refused { #expect(e.code == "ownership_escalation_denied") } else { Issue.record("not refused") }
        #expect(try await m.call("run.list", .obj([("limit", .int(200))]))["runs"]!.arrayValue!.count == before)
    }

    @Test func admissionRefusalsCreateNoRun() async throws {
        let m = MockRuntime.sample()
        let ids = m.desktopIds
        // Control busy: the first Desktop has an active act Run.
        if case let .failure(e) = m.startDurableUnitRun(params: MockRuntime.sampleUnitParams(desktopId: ids[0])) {
            #expect(e.code == "control_busy")
        } else { Issue.record("control busy started") }
        m.guiExecutionAvailable = false
        if case let .failure(e) = m.startDurableUnitRun(params: MockRuntime.sampleUnitParams(desktopId: ids[2])) {
            #expect(e.code == "unsupported_backend" && e.details?["reason"]?.stringValue == "gui_execution_off")
        } else { Issue.record("started without executor") }
        let units = try await m.call("run.list", .obj([("limit", .int(200))]))["runs"]!.arrayValue!.filter { $0["kind"]?.stringValue == "unit" }
        #expect(units.isEmpty)
    }

    @Test func eventsFollowTheContractAndCarryNoText() async throws {
        let m = MockRuntime.sample()
        let calc = try #require(m.desktopIds.last)
        for s in MockExplorerScenario.allCases {
            let id = try #require(m.addUnitRun(desktopId: calc, scenario: s))
            let events = try await m.call("run.events", .obj([("runId", .string(id))]))["events"]!.arrayValue!
            #expect(events.contains { $0["type"]?.stringValue == "unit.progress" })
            let text = String(decoding: JSONValue.array(events).encodedData(), as: UTF8.self)
            for secret in ["Ada", "已保存", "MAC-001", "本地表单"] {
                #expect(!text.contains(secret), "\(s): events leak \(secret)")
            }
            let run = try await m.call("run.show", .obj([("runId", .string(id))]))
            #expect(run["phase"]?.stringValue == "ended" && run["quiescence"]?.stringValue == "confirmed")
        }
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
        #expect(m.explorerContractViolations.isEmpty, "\(m.explorerContractViolations)")
    }

    // MARK: P27 form

    @Test func draftNeverCarriesOwnershipAndOnlyTightens() throws {
        var d = ExplorerDraft(desktopId: "desk_003")
        #expect(d.problems.contains("填写局部目标") && d.problems.contains("确认诊断范围"))
        d.goal = "  在表单里填写名称  "
        d.expectedText = "已保存"
        d.scopeConfirmed = true
        #expect(d.problems.isEmpty)
        let p = d.params
        for k in ["origin", "lifetime", "ownership"] { #expect(p[k] == nil) }
        #expect(p["goal"]?["description"]?.stringValue == "在表单里填写名称")
        #expect(RuntimeContract.shared.validate(p, "unit_run_params").isEmpty)
        d.maxSteps = 21
        #expect(d.problems.contains { $0.contains("步数") })
        d.maxSteps = 5
        d.allowed = []
        #expect(d.problems.contains("至少允许一种动作"))
        // Busy, unbound and closing Desktops cannot be targets (P27 rule).
        let m = MockRuntime.sample()
        let store = m.desktopsNow
        let active = m.runsNow.filter { $0["phase"]?.stringValue != "ended" }
        let eligible = ExplorerDraft.eligible(desktops: store, activeRuns: active)
        #expect(eligible.filter { $0.blocked == nil }.count == 1)
        #expect(eligible.filter { $0.blocked == "控制权已占用" }.count == 2)
    }

    @Test func starterGoesThroughTheInProcessEntry() async throws {
        let m = MockRuntime.sample()
        let start = ExplorerDurableStart.mock(m)
        var d = ExplorerDraft(desktopId: m.desktopIds.last)
        d.goal = "填写名称"
        d.expectedText = "已保存"
        d.scopeConfirmed = true
        let run = try await start(d.params).get()
        #expect(run["origin"]?.stringValue == "gui_explorer")
        #expect(m.durableStartCalls.count == 1 && !m.callLog.contains("unit.run"))
        // The bound Desktop is the one chosen (UC42).
        #expect(run["desktopId"]?.stringValue == m.desktopIds.last)
    }

    // MARK: Timeline

    func timeline(_ m: MockRuntime, _ id: String) async throws -> ExplorerTimeline {
        ExplorerTimeline(events: try await m.call("run.events", .obj([("runId", .string(id))]))["events"]!.arrayValue!)
    }

    @Test func verifiedRunCountsAttemptsApartFromInputs() async throws {
        let m = MockRuntime.sample()
        let id = try #require(m.addUnitRun(desktopId: m.desktopIds.last!, scenario: .verified))
        let t = try await timeline(m, id)
        #expect(t.modelAttempts == 4 && t.confirmedInputs == 2 && t.unknownInputs == 0)
        #expect(t.stepsUsed == 2 && t.stepBudget == 20)
        #expect(t.progress?.attemptsLeft == 27 && t.progress?.secondsLeft == 88)
        #expect(t.latestVerification?.status == "matched" && t.stage == 5)
        #expect(t.steps.last?.proposalText.contains("不作为成功依据") == true)
        let run = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(ExplorerText.runStatus(run).text == "已验证成功")
        #expect(run["closingReason"]?.stringValue == "goal_verified")
    }

    @Test func stallShowsOneRecoveryAndTheEndingReason() async throws {
        let m = MockRuntime.sample()
        let id = try #require(m.addUnitRun(desktopId: m.desktopIds.last!, scenario: .stalled))
        let t = try await timeline(m, id)
        #expect(t.recoveries.count == 1 && t.recoveries[0].kind == "repeated_action")
        #expect(t.recoveries[0].text.hasPrefix("恢复"))
        let run = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(run["outcome"]?.stringValue == "failed")
        #expect(ExplorerText.closingReason(run["closingReason"]?.stringValue)?.contains("no_progress") == true)
        #expect(ExplorerText.closingReason("loop_detected")?.contains("循环") == true)
    }

    @Test func inconclusiveIsNeverSuccessAndSaysWhy() async throws {
        let m = MockRuntime.sample()
        let id = try #require(m.addUnitRun(desktopId: m.desktopIds.last!, scenario: .inconclusive))
        let t = try await timeline(m, id)
        let v = try #require(t.latestVerification)
        #expect(v.status == "inconclusive" && v.text.text == "无法判定")
        #expect(v.reasonText?.contains("不完整") == true)
        #expect(t.steps.contains { $0.rejected == "stale_observation" })
        let run = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(run["outcome"]?.stringValue != "success")
    }

    @Test func unknownActionNeedsVerification() async throws {
        let m = MockRuntime.sample()
        let id = try #require(m.addUnitRun(desktopId: m.desktopIds.last!, scenario: .unknownAction))
        let t = try await timeline(m, id)
        #expect(t.unknownInputs == 1)
        #expect(t.allActions[0].status.text == "结果未知 · 需要核实")
        let run = try await m.call("run.show", .obj([("runId", .string(id))]))
        #expect(run["outcome"]?.stringValue == "unknown" && run["unknownActions"]?.intValue == 1)
        #expect(ExplorerText.runStatus(run).text == "结果未知 · 需要核实")
        // The loader's receipt level agrees (request.show), and never a retry.
        let loader = ExplorerRunLoader(runtime: m, runId: id)
        await loader.load()
        #expect(loader.status(of: loader.timeline.allActions[0]).text == "结果未知 · 需要核实")
    }

    @Test func unknownKindsAndTypesAreTolerated() {
        let events: [JSONValue] = [
            .obj([("runId", .string("r")), ("sequence", .int(1)), ("at", .string("2026-10-11T00:00:00Z")),
                  ("type", .string("unit.recovery")), ("data", .obj([("stepIndex", .int(0)), ("kind", .string("reobserve_after_stale")), ("count", .int(1))]))]),
            .obj([("runId", .string("r")), ("sequence", .int(2)), ("at", .string("2026-10-11T00:00:01Z")),
                  ("type", .string("unit.something_new")), ("data", .obj([]))]),
            .obj([("runId", .string("r")), ("sequence", .int(3)), ("at", .string("2026-10-11T00:00:02Z")),
                  ("type", .string("unit.action")), ("data", .obj([("stepIndex", .int(0)), ("actionId", .string("a")),
                                                                   ("proposalId", .string("p")), ("requestId", .string("q")),
                                                                   ("deliveryState", .string("not_sent"))]))]),
        ]
        let t = ExplorerTimeline(events: events)
        #expect(t.recoveries.map(\.text) == ["恢复"])
        #expect(t.allActions[0].status.text == "未发出")
        #expect(ExplorerText.delivery("rejected").text.hasPrefix("未发出"))
        #expect(ExplorerText.delivery("submitted").text == "已受理")
        #expect(ExplorerText.delivery("confirmed").text == "已执行，未验证")
    }

    // MARK: Stop and page lifetime

    @Test func stopWaitsForQuiescenceAndKeepsTheDesktop() async throws {
        let m = MockRuntime.sample()
        let calc = m.desktopIds.last!
        let id = try #require(m.addUnitRun(desktopId: calc, scenario: .verified, steps: 1))
        let otherActive = m.runsNow.filter { $0["phase"]?.stringValue == "running" && $0["runId"]?.stringValue != id }
        let loader = ExplorerRunLoader(runtime: m, runId: id)
        await loader.load()
        await loader.stop()
        #expect(loader.run?["phase"]?.stringValue == "stopping", "not ended before the executor confirms")
        #expect(loader.run?["quiescence"]?.stringValue == "pending")
        m.advanceUnitRun(id)
        await loader.load()
        #expect(loader.run?["phase"]?.stringValue == "ended" && loader.run?["outcome"]?.stringValue == "cancelled")
        #expect(loader.run?["quiescence"]?.stringValue == "confirmed")
        // No late proposal is recorded after the stop.
        let after = loader.events.drop { $0["type"]?.stringValue != "stop.accepted" }
        #expect(!after.contains { ($0["type"]?.stringValue ?? "").hasPrefix("unit.") })
        // Other Desktops' Runs and the Desktop itself stay (UC45, UC48).
        #expect(m.desktopIds.contains(calc))
        let stillRunning = m.runsNow.filter { r in otherActive.contains { $0["runId"] == r["runId"] } }
        #expect(stillRunning.allSatisfy { $0["phase"]?.stringValue == "running" })
    }

    @Test func closingThePageNeverStopsTheRun() async throws {
        let m = MockRuntime.sample()
        let id = try #require(m.addUnitRun(desktopId: m.desktopIds.last!, scenario: .verified, steps: 2))
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        let loader = ExplorerRunLoader(runtime: m, runId: id)
        await loader.load()
        // Render and tear down the detail page (the host view goes away).
        _ = SnapshotRenderer.png(ExplorerPage(store: store, navigation: ShellNavigation(section: .explorer), connectionState: .loaded,
                                              retry: {}, starter: .mock(m), route: .run(id), loader: loader))
        #expect(!m.callLog.contains("run.cancel"))
        #expect(m.runsNow.first { $0["runId"]?.stringValue == id }?["phase"]?.stringValue == "running")
        m.finishUnitRun(id)
        #expect(m.runsNow.first { $0["runId"]?.stringValue == id }?["outcome"]?.stringValue == "success")
    }

    @Test func historyListsOnlyUnitRunsFromBothSources() throws {
        let m = MockRuntime.explorerSample()
        let runs = m.runsNow
        let all = ExplorerHistoryView.unitRuns(runs)
        #expect(all.count == 4 && all.allSatisfy { $0["kind"]?.stringValue == "unit" })
        #expect(ExplorerHistoryView.unitRuns(runs, source: .mainWindow).count == 2)
        #expect(ExplorerHistoryView.unitRuns(runs, source: .agents).count == 2)
        #expect(ExplorerHistoryView.unitRuns(runs, scope: .active).isEmpty)
    }

    // MARK: Off-screen renders (component acceptance)

    static let outDir: URL = {
        if let d = ProcessInfo.processInfo.environment["AGENTDESKTOP_UI_SNAPSHOTS"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("agentdesktop-ui-e-\(getpid())", isDirectory: true)
    }()

    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: Self.outDir.appendingPathComponent(name + ".png"))
    }

    func frame<V: View>(_ store: ShellStore, @ViewBuilder _ page: () -> V) -> some View {
        MainFrame(selection: .constant(.explorer), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]!.stringValue!, name: d["name"]!.stringValue!,
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: [.desktops: store.desktops.count, .runs: store.activeRuns.count],
                  statusLeft: "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中",
                  statusRight: "样例数据", isSample: true, page: page)
    }

    func page(_ m: MockRuntime, _ store: ShellStore, route: ExplorerPage.Route = .history, composing: Bool = false,
              draft: ExplorerDraft = ExplorerDraft(), starter: Bool = true) async -> some View {
        var loader: ExplorerRunLoader?
        if case let .run(id) = route {
            loader = ExplorerRunLoader(runtime: m, runId: id)
            await loader!.load()
        }
        let l = loader
        return frame(store) {
            ExplorerPage(store: store, navigation: ShellNavigation(section: .explorer), connectionState: .loaded, retry: {},
                         starter: starter ? .mock(m) : nil, route: route, composing: composing, draft: draft, loader: l)
        }
    }

    @Test func rendersAgainstWireframes() async throws {
        let m = MockRuntime.explorerSample()
        let calc = m.desktopIds.last!
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()

        try write("explorer-history", await page(m, store))
        try write("explorer-history-start-pending", await page(m, store, starter: false))

        var draft = ExplorerDraft(desktopId: calc)
        draft.goal = "在本地表单的名称中填写 Ada，点击 Apply，并确认保存结果。"
        draft.expectedText = "已保存：Ada / MAC-001-A / 提交次数 1"
        try write("P27-new-diagnostic", await page(m, store, composing: true, draft: draft))
        var confirmed = draft
        confirmed.scopeConfirmed = true
        try write("P27-new-diagnostic-confirmed", await page(m, store, composing: true, draft: confirmed))

        // P28: a Durable Run mid-way (after its first input).
        let live = try #require(m.addUnitRun(desktopId: calc, scenario: .verified, steps: 2))
        await store.refreshRuns()
        try write("P28-diagnostic-running", await page(m, store, route: .run(live)))
        _ = try await m.call("run.cancel", .obj([("runId", .string(live))]))
        try write("P28-diagnostic-stopping", await page(m, store, route: .run(live)))
        m.advanceUnitRun(live)

        // P29 and the other endings.
        let units = ExplorerHistoryView.unitRuns(m.runsNow)
        func id(_ reason: String) -> String? { units.first { $0["closingReason"]?.stringValue == reason }?["runId"]?.stringValue }
        try write("P29-diagnostic-verified", await page(m, store, route: .run(try #require(id("goal_verified")))))
        try write("P29-diagnostic-no-progress", await page(m, store, route: .run(try #require(id("no_progress")))))
        try write("P29-diagnostic-inconclusive", await page(m, store, route: .run(try #require(id("deadline_exceeded")))))
        try write("P29-diagnostic-unknown", await page(m, store, route: .run(try #require(id("action_outcome_unknown")))))

        // Through the shared shell: MainWindowView › GUI Explorer, with the
        // starter coming from the environment as the host would give it.
        try write("explorer-in-main-window", MainWindowView(store: store, initial: .explorer)
            .environment(\.explorerDurableStart, .mock(m)))
        #expect(m.contractViolations.isEmpty && m.explorerContractViolations.isEmpty)
    }
}

extension MockRuntime {
    var desktopIds: [String] { lock.withLock { desktops.compactMap { $0["desktopId"]?.stringValue } } }
    var desktopsNow: [JSONValue] { lock.withLock { desktops } }
    var runsNow: [JSONValue] { lock.withLock { runs } }
}
