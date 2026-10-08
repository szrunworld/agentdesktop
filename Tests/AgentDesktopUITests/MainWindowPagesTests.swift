import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

@MainActor
@Suite("Main window pages (U1b-1)", .serialized)
struct MainWindowPagesTests {
    @Test func navigationKeepsOneSectionAndOneSelection() {
        let nav = ShellNavigation()
        #expect(nav.section == .desktops && nav.desktopId == nil)
        nav.showDesktop("desk_002")
        #expect(nav.section == .desktops && nav.desktopId == "desk_002")
        nav.showRun("run_003")
        #expect(nav.section == .runs && nav.runId == "run_003")
        nav.back()
        #expect(nav.runId == nil && nav.section == .runs)
        // Choosing an entry shows its top view.
        nav.showDesktop("desk_001")
        nav.open(.desktops)
        #expect(nav.desktopId == nil)
        nav.open(.inbox)
        #expect(nav.section == .inbox)
        #expect(MainSection.allCases.map(\.title) == ["Desktops", "Agents", "Runs", "GUI Explorer", "Inbox", "设置"])
        #expect(SettingsPage.allCases.map(\.rawValue) == ["通用", "权限", "AI 连接", "GUI 配置", "能力测试", "核实", "诊断与用量"])
    }

    // Every section and selection renders at the design size.
    @Test func everySectionRenders() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let run = store.runs.first!["runId"]!.stringValue!
        let navs: [ShellNavigation] = MainSection.allCases.map { ShellNavigation(section: $0) }
            + [ShellNavigation(section: .desktops, desktopId: "desk_001"), ShellNavigation(section: .runs, runId: run)]
            + SettingsPage.allCases.map { ShellNavigation(section: .settings, settingsPage: $0) }
        for nav in navs {
            let png = SnapshotRenderer.png(MainWindowView(store: store, navigation: nav))
            #expect((png?.count ?? 0) > 10_000, "\(nav.section) \(String(describing: nav.desktopId)) \(String(describing: nav.runId))")
        }
    }

    @Test func overviewFilterAndSearch() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        typealias O = DesktopsOverviewView
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "").count == 3)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .running, query: "").count == 2)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .idle, query: "").count == 1)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "desk_002").count == 1)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "textedit").count == 1)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "无此项").isEmpty)
        #expect(RunsListView.visible(store.runs, scope: .active).count == 2)
        #expect(RunsListView.visible(store.runs, scope: .ended).count == 1)
        #expect(RunsListView.visible(store.runs, scope: .all).count == 3)
    }

    // Loading, Empty, Ready, Error, Disconnected for Desktops and Runs.
    @Test func listPageStates() async {
        let m = MockRuntime()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        #expect(store.desktopsState == .loading && store.runsState == .loading)
        await store.start()
        store.stop()
        #expect(store.desktopsState == .empty && store.runsState == .empty)
        let d = m.addDesktop(name: "A")
        m.addRun(desktopId: d)
        await store.refreshDesktops()
        await store.refreshRuns()
        #expect(store.desktopsState == .loaded && store.runsState == .loaded)
        m.failNext("run.list", code: "internal_error")
        await store.refreshRuns()
        guard case .failed = store.runsState else { Issue.record("runs not failed"); return }
        #expect(store.runs.count == 1, "last good data stays")
        m.offline = true
        await store.refreshDesktops()
        guard case .disconnected = store.desktopsState else { Issue.record("not disconnected"); return }
    }

    @Test func desktopDetailStates() {
        typealias I = DesktopInspectorView
        let p = RuntimeProblem(code: "runtime_offline", title: "t", advice: "a")
        #expect(I.state(list: .loading, found: false) == .loading)
        #expect(I.state(list: .loaded, found: true) == .loaded)
        #expect(I.state(list: .loaded, found: false) == .empty, "a Desktop gone from a good list is closed")
        #expect(I.state(list: .empty, found: false) == .empty)
        #expect(I.state(list: .failed(p), found: true) == .failed(p))
        #expect(I.state(list: .disconnected(p), found: true) == .disconnected(p))
    }

    @Test func runDetailLoaderStates() async throws {
        let m = MockRuntime.sample()
        let runs = try await m.call("run.list", .obj([("active", .bool(true))]))["runs"]!.arrayValue!
        let id = runs.first { $0["desktopId"]?.stringValue == "desk_001" }!["runId"]!.stringValue!
        let loader = RunDetailLoader(runtime: m, runId: id)
        #expect(loader.state == .loading)
        await loader.load()
        #expect(loader.state == .loaded)
        #expect(loader.run?["runId"]?.stringValue == id)
        // Three actions: executed, not sent (target_moved), executed.
        #expect(loader.actions.map(\.presentation.level) == [.executedUnverified, .notDispatched, .executedUnverified])
        #expect(loader.actions[1].errorCode == "target_moved")
        let before = loader.events.count
        m.addAction(runId: id, delivery: "unknown", execution: "unknown")
        await loader.load()
        #expect(loader.events.count > before, "events are read incrementally")
        #expect(loader.actions.first?.presentation.level == .unknown)

        let missing = RunDetailLoader(runtime: m, runId: "run_none")
        await missing.load()
        guard case .failed(let p) = missing.state else { Issue.record("not failed"); return }
        #expect(p.code == "not_found")
        m.offline = true
        await loader.load()
        guard case .disconnected = loader.state else { Issue.record("not disconnected"); return }
        #expect(loader.run != nil, "the last read Run stays for the read-only view")
    }

    @Test func desktopActivity() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let a = DesktopActivityLoader(runtime: m, desktopId: "desk_002")
        await a.load(runs: store.runs)
        #expect(a.actions.map(\.presentation.level) == [.unknown, .executedUnverified])
        let none = DesktopActivityLoader(runtime: m, desktopId: "desk_003")
        await none.load(runs: store.runs)
        #expect(none.actions.isEmpty)
    }

    // Disconnected, then the Runtime answers again: the same poll loop
    // reconnects and the pages show data again.
    @Test func reconnectsAfterDisconnection() async {
        let m = MockRuntime.sample()
        m.offline = true
        let store = ShellStore(runtime: m, clock: FastClock(), pollMs: 1, allowSubscription: false)
        await store.start()
        guard case .disconnected = store.connection else { Issue.record("connected while offline"); return }
        #expect(store.isRunning, "the loop keeps trying")
        m.offline = false
        await waitFor("reconnected") { if case .connected = store.connection { return true }; return false }
        await waitFor("data back") { store.desktops.count == 3 && store.desktopsState == .loaded }
        // Lost again while connected: Disconnected with the last data kept.
        m.offline = true
        await waitFor("disconnected again") { if case .disconnected = store.connection { return true }; return false }
        #expect(store.desktops.count == 3)
        guard case .disconnected = store.desktopsState else { Issue.record("page not disconnected"); return }
        m.offline = false
        await waitFor("back again") { store.desktopsState == .loaded }
        store.stop()
    }

    // Polling is the only update source when subscription is not allowed,
    // and starting twice never makes a second loop.
    @Test func pollingIsTheOnlySource() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        await store.start()
        #expect(store.runUpdates == .polling && store.desktopUpdates == .polling)
        #expect(store.loopCount == 1)
        #expect(!m.callLog.contains("events.subscribe"))
        store.stop()
        #expect(store.loopCount == 0)
        let pushed = ShellStore(runtime: m, clock: StillClock())
        await pushed.start()
        #expect(pushed.runUpdates == .subscription)
        #expect(pushed.loopCount == 2, "one poll loop (status, Desktops) and one subscription; Runs are not polled")
        pushed.stop()
    }

    // The page re-reads on every update round, not on how it travelled.
    @Test func tickAdvancesEachRound() async {
        let m = MockRuntime()
        let store = ShellStore(runtime: m, clock: FastClock(), pollMs: 1, allowSubscription: false)
        await store.start()
        let t = store.tick
        await waitFor("ticks") { store.tick > t + 2 }
        store.stop()
    }

    @Test func stopAllShowsWhatTheRuntimeSays() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        await store.stopAllInput()
        #expect(store.inputAdmission == "stopped")
        #expect(store.lastStop?["pending"]?.arrayValue?.count == 2)
        // Accepted stops are shown as stopping, never as stopped.
        #expect(store.activeRuns.allSatisfy { RunStatusPresentation.make(run: $0).text == "停止中" })
        await store.enableInput()
        #expect(store.inputAdmission == "enabled")
        #expect(store.activeRuns.count == 2, "re-enabling input resumes no Run")
    }
}
