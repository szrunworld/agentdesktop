import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

@MainActor
@Suite("Menu bar and quit (U8)", .serialized)
struct QuitFlowTests {
    // UC51: quitting waits until every Run is ended and confirmed quiet; an
    // accepted stop is not enough.
    @Test func uc51_quitWaitsForQuiescence() async throws {
        let m = MockRuntime.sample()
        let flow = QuitFlow(runtime: m, clock: FastClock(), pollMs: 1)
        #expect(await flow.activeNow().count == 2)
        flow.stopAndWait()
        await waitFor("stop accepted") { flow.stoppedIds.count == 2 }
        await waitFor("several checks") { flow.checks >= 3 }
        #expect(flow.phase == .stopping, "accepted but not quiet")
        #expect(flow.remaining.count == 2)
        #expect(flow.remaining.allSatisfy { $0["phase"]?.stringValue == "stopping" && $0["quiescence"]?.stringValue == "pending" })
        m.confirmQuiescence(flow.stoppedIds[0])
        await waitFor("one left") { flow.remaining.count == 1 }
        #expect(flow.phase == .stopping)
        m.confirmQuiescence(flow.stoppedIds[1])
        await waitFor("quiet") { flow.phase == .quiet }
        #expect(m.callLog.filter { $0 == "runtime.stopAll" }.count == 1)
        #expect(QuitFlow.isQuiet(try await m.call("run.show", .obj([("runId", .string(flow.stoppedIds[0]))]))))
    }

    @Test func nothingRunningIsQuietAtOnce() async {
        let m = MockRuntime()
        let flow = QuitFlow(runtime: m, clock: FastClock(), pollMs: 1)
        flow.stopAndWait()
        await waitFor("quiet") { flow.phase == .quiet }
        #expect(m.callLog.contains("runtime.stopAll"))
    }

    // Calling the quit off stops waiting; input stays stopped, nothing is
    // forced or resumed.
    @Test func cancelWhileStopping() async throws {
        let m = MockRuntime.sample()
        let flow = QuitFlow(runtime: m, clock: FastClock(), pollMs: 1)
        flow.stopAndWait()
        await waitFor("stopping") { flow.checks >= 1 }
        flow.cancel()
        #expect(flow.phase == .cancelled)
        let status = try await m.call("runtime.status")
        #expect(status["inputAdmission"]?.stringValue == "stopped")
        #expect(!m.callLog.contains("runtime.enableInput"))
    }

    @Test func stopFailureCanBeRetried() async {
        let m = MockRuntime.sample()
        m.failNext("runtime.stopAll", code: "internal_error")
        let flow = QuitFlow(runtime: m, clock: FastClock(), pollMs: 1)
        flow.stopAndWait()
        await waitFor("failed") { if case .failed = flow.phase { return true }; return false }
        flow.stopAndWait()
        await waitFor("stopping again") { flow.stoppedIds.count == 2 }
        for id in flow.stoppedIds { m.confirmQuiescence(id) }
        await waitFor("quiet") { flow.phase == .quiet }
    }

    @Test func panelStatusAndRenders() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        #expect(MenuBarPanelView.status(store) == StatusText("正在连接", .idle))
        await store.start()
        store.stop()
        #expect(MenuBarPanelView.status(store) == StatusText("运行中", .running))
        #expect(MenuBarPanelView.summary(store) == "3 个 Desktop · 2 个运行进行中")
        var opened: [String] = []
        let panel = MenuBarPanelView(store: store, actions: MenuBarActions(openMain: {}, openPreview: { opened.append($0) },
                                                                            openSettings: {}, quit: {}))
        #expect((SnapshotRenderer.png(panel, size: CGSize(width: 340, height: 560))?.count ?? 0) > 5_000)
        let flow = QuitFlow(runtime: m, clock: FastClock())
        #expect((SnapshotRenderer.png(QuitDialogView(flow: flow, activeCount: 2) { _ in }, size: CGSize(width: 600, height: 320))?.count ?? 0) > 5_000)
        await store.stopAllInput()
        #expect(MenuBarPanelView.status(store) == StatusText("输入已停止", .attention))
    }
}
