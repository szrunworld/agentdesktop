import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

/// Off-screen renders of U3 (P12–P18) and the U2b states at 1440 × 1000,
/// for docs/acceptance/ui-b/ beside docs/design/v2/Pxx.webp. With
/// AGENTDESKTOP_UI_SNAPSHOTS=<dir> the PNGs go there; otherwise to a
/// temporary directory. Nothing is shown on screen; live pictures use no
/// capture source (the frame view says the picture is unavailable).
@MainActor
@Suite("Desktop control renders", .serialized)
struct DesktopControlRenderTests {
    static let outDir: URL = {
        if let d = ProcessInfo.processInfo.environment["AGENTDESKTOP_UI_SNAPSHOTS"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("agentdesktop-ui-b-\(getpid())", isDirectory: true)
    }()

    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: Self.outDir.appendingPathComponent(name + ".png"))
    }

    func frame<V: View>(_ store: ShellStore, @ViewBuilder _ page: () -> V) -> some View {
        MainFrame(selection: .constant(.desktops), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]!.stringValue!, name: d["name"]!.stringValue!,
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: [.desktops: store.desktops.count],
                  statusLeft: "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中",
                  statusRight: "运行状态：轮询", isSample: true, page: page)
    }

    struct Fixture {
        let m: MockRuntime
        let store: ShellStore
        let a: String
        let runA: String
    }

    func fixture(sample: Bool = false) async -> Fixture {
        let m = MockRuntime()
        let a = m.addDesktop(name: "表单验证", app: "Safari")
        let b = m.addDesktop(name: "文本编辑", app: "TextEdit")
        _ = m.addDesktop(name: "计算器", app: "Calculator")
        let client = m.addClient(name: "表单助手")
        let runA = m.addRun(desktopId: a, receipts: 3)
        m.addAction(runId: runA, delivery: "dispatched", execution: "completed")
        m.setRunClient(runA, clientId: client)
        _ = m.addRun(desktopId: b, receipts: 1)
        m.addLaunchedApp(a, name: "Probe")
        if !sample { m.enableDesktopControl() }
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        return Fixture(m: m, store: store, a: a, runA: runA)
    }

    func detail(_ f: Fixture, control: DesktopControlFlow? = nil, review: UnknownResultReview? = nil) async -> some View {
        let nav = ShellNavigation(section: .desktops, desktopId: f.a)
        let activity = DesktopActivityLoader(runtime: f.m, desktopId: f.a)
        await activity.load(runs: f.store.runs)
        let c = control ?? DesktopControlFlow(runtime: f.m, desktopId: f.a)
        if c.closePlan == nil { await c.loadClosePlan() }
        return frame(f.store) { DesktopInspectorView(store: f.store, navigation: nav, activity: activity, control: c, review: review) }
    }

    @Test func p06to18() async throws {
        // P06 with Desktop.control (running).
        var f = await fixture()
        try write("ui-b-P06-detail-control", await detail(f))

        // P12: takeover confirmation.
        let p12 = DesktopControlFlow(runtime: f.m, desktopId: f.a)
        p12.dialog = .takeover
        try write("ui-b-P12-takeover-confirm", await detail(f, control: p12))

        // P12 answered stop_pending.
        f.m.markActionInFlight(f.runA)
        await p12.takeover()
        await f.store.refreshDesktops()
        try write("ui-b-P12-takeover-stop-pending", await detail(f, control: p12))
        f.m.finishInFlight(f.runA)

        // P13: manual control.
        let p13 = DesktopControlFlow(runtime: f.m, desktopId: f.a)
        await p13.takeover()
        await f.store.refreshDesktops()
        await f.store.refreshRuns()
        try write("ui-b-P13-manual", await detail(f, control: p13))

        // P14 / P15: stopping, then stopped.
        f = await fixture()
        f.m.markActionInFlight(f.runA)
        let p14 = DesktopControlFlow(runtime: f.m, desktopId: f.a)
        await p14.stop()
        await f.store.refreshDesktops()
        await f.store.refreshRuns()
        try write("ui-b-P14-stopping", await detail(f, control: p14))
        f.m.finishInFlight(f.runA)
        await p14.refresh()
        await f.store.refreshDesktops()
        await f.store.refreshRuns()
        try write("ui-b-P15-stopped", await detail(f, control: p14))

        // P16: connection lost.
        f = await fixture()
        f.m.loseControlConnection(f.runA)
        await f.store.refreshDesktops()
        await f.store.refreshRuns()
        try write("ui-b-P16-disconnected", await detail(f))

        // P17: unknown result, before and after the new observation.
        f = await fixture()
        let req = f.m.addAction(runId: f.runA, delivery: "unknown", execution: "unknown")
        f.m.endWithUnknownAction(f.runA)
        await f.store.refreshDesktops()
        await f.store.refreshRuns()
        let activity = DesktopActivityLoader(runtime: f.m, desktopId: f.a)
        await activity.load(runs: f.store.runs)
        let entry = try #require(activity.actions.first { $0.requestId == req })
        let review = UnknownResultReview(runtime: f.m, desktopId: f.a, entry: entry)
        let p17 = DesktopControlFlow(runtime: f.m, desktopId: f.a)
        p17.dialog = .unknown(requestId: req)
        try write("ui-b-P17-unknown-review", await detail(f, control: p17, review: review))
        await review.reobserve()
        try write("ui-b-P17-unknown-reobserved", await detail(f, control: p17, review: review))

        // P18: close plan, blocked by the running agent, then closable.
        f = await fixture()
        let p18 = DesktopControlFlow(runtime: f.m, desktopId: f.a)
        await p18.openClose()
        try write("ui-b-P18-close-blocked", await detail(f, control: p18))
        await p18.stopBeforeClose()
        await f.store.refreshDesktops()
        await f.store.refreshRuns()
        try write("ui-b-P18-close-ready", await detail(f, control: p18))
        #expect(f.m.contractViolations.isEmpty)
    }

    @Test func u2bStates() async throws {
        // Without Desktop.control: derived controller, said so.
        let f = await fixture(sample: true)
        try write("ui-b-U2b-detail-no-control", await detail(f))
        try write("ui-b-U2b-overview-no-control", frame(f.store) {
            DesktopsOverviewView(store: f.store, navigation: ShellNavigation(section: .desktops))
        })

        // With Desktop.control: one stopped, one creating, stops wired.
        let g = await fixture()
        g.m.forceControlState("desk_003", "creating")
        _ = try await g.m.call("desktop.stop", .obj([("desktopId", .string("desk_002"))]))
        await g.store.refreshDesktops()
        await g.store.refreshRuns()
        try write("ui-b-U2b-overview-control", frame(g.store) {
            DesktopsOverviewView(store: g.store, navigation: ShellNavigation(section: .desktops))
        })
        try write("ui-b-U2b-side-by-side", frame(g.store) {
            SideBySideView(store: g.store, navigation: ShellNavigation(section: .desktops), openPreview: nil)
        })
        #expect(g.m.contractViolations.isEmpty)
    }
}
