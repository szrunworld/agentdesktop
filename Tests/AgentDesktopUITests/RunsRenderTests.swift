import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

/// Off-screen renders of the U5 pages at 1440 × 1000, beside
/// docs/design/v2/P19.webp, P20.webp and Hub W04–W05. With
/// AGENTDESKTOP_UI_SNAPSHOTS=<dir> the PNGs go there
/// (docs/acceptance/ui-a/ for the PR). Nothing is shown on screen.
@MainActor
@Suite("U5 renders", .serialized)
struct RunsRenderTests {
    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000)
        try FileManager.default.createDirectory(at: RenderTests.outDir, withIntermediateDirectories: true)
        try png.write(to: RenderTests.outDir.appendingPathComponent(name + ".png"))
    }

    func frame<V: View>(_ store: ShellStore, @ViewBuilder _ page: () -> V) -> some View {
        MainFrame(selection: .constant(.runs), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]!.stringValue!, name: d["name"]!.stringValue!,
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: [.desktops: store.desktops.count, .runs: store.activeRuns.count],
                  statusLeft: "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中",
                  statusRight: "同步于 —", isSample: true, page: page)
    }

    /// The sample plus a unit Run of each verification value, a stopping
    /// Run, a Run that ended unknown and a refused input.
    func scenario() async -> (MockRuntime, ShellStore) {
        let m = MockRuntime.sample()
        m.addUnitRun(desktopId: "desk_003", verification: "matched")
        m.addUnitRun(desktopId: "desk_003", phase: "ended", outcome: "failed", verification: "contradicted")
        m.addUnitRun(desktopId: "desk_003", verification: "inconclusive")
        let unknown = m.addRun(desktopId: "desk_002", phase: "ended", outcome: "unknown", receipts: 1, unknownActions: 1)
        m.addAction(runId: unknown, delivery: "unknown", execution: "unknown")
        m.addRefusedAction(runId: "run_002", code: "input_disabled")
        m.addAcceptedRequest(method: "desktop.create")
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        return (m, store)
    }

    @Test func runsPages() async throws {
        let (m, store) = await scenario()
        let nav = ShellNavigation(section: .runs)

        let list = RunListLoader(runtime: m)
        await list.reload()
        try write("W04-runs-list", frame(store) { RunsListView(store: store, navigation: nav, loader: list) })

        let act = RunDetailLoader(runtime: m, runId: "run_002")
        await act.load()
        try write("W05-run-detail-act", frame(store) { RunInspectorView(store: store, navigation: nav, loader: act) })

        _ = try await m.call("run.cancel", .obj([("runId", .string("run_003"))]))
        let stopping = RunDetailLoader(runtime: m, runId: "run_003")
        await stopping.load()
        try write("W05-run-detail-stopping-unknown", frame(store) { RunInspectorView(store: store, navigation: nav, loader: stopping) })

        let unit = RunDetailLoader(runtime: m, runId: "run_006")
        await unit.load()
        #expect(unit.run?["unit"]?["verification"]?["status"]?.stringValue == "inconclusive")
        try write("W05-run-detail-unit-inconclusive", frame(store) { RunInspectorView(store: store, navigation: nav, loader: unit) })

        let records = ActionRecordsLoader(runtime: m)
        await records.reload()
        try write("P19-action-records", frame(store) { ActionRecordsView(store: store, navigation: nav, loader: records) })
        try write("P20-receipt-executed", frame(store) {
            ActionRecordsView(store: store, navigation: nav, loader: records, receipt: "req_002")
        })
        try write("P20-receipt-not-dispatched", frame(store) {
            ActionRecordsView(store: store, navigation: nav, loader: records, receipt: "req_003")
        })
        try write("P20-receipt-unknown", frame(store) {
            ActionRecordsView(store: store, navigation: nav, loader: records, receipt: "req_007")
        })
        await records.exportRecords()
        try write("P19-action-records-exported", frame(store) { ActionRecordsView(store: store, navigation: nav, loader: records) })
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }
}
