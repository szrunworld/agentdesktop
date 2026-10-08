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
        #expect(await flow.activeNow()?.count == 2)
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
        #expect((SnapshotRenderer.png(QuitDialogView(flow: flow) { _ in }, size: CGSize(width: 600, height: 320))?.count ?? 0) > 5_000)
        await store.stopAllInput()
        #expect(MenuBarPanelView.status(store) == StatusText("输入已停止", .attention))
    }

    // A Runtime that cannot be reached: the count says so (never zero) and
    // fills in once the Runtime is back.
    @Test func countWhileDisconnectedThenRecovered() async throws {
        let m = MockRuntime.sample()
        m.offline = true
        let flow = QuitFlow(runtime: m, clock: FastClock(), pollMs: 1)
        let counting = Task { await flow.countActive() }
        await waitFor("unavailable") { if case .unavailable = flow.activeCount { return true }; return false }
        #expect(QuitDialogView.activeLine(flow.activeCount).contains("暂时读不到"))
        m.offline = false
        await counting.value
        #expect(flow.activeCount == .known(2))
    }

    // Stopping while the Runtime cannot be reached fails visibly and never
    // reports quiet; it can be retried once the Runtime is back.
    @Test func stopWhileDisconnectedNeverReportsQuiet() async throws {
        let m = MockRuntime.sample()
        m.offline = true
        let flow = QuitFlow(runtime: m, clock: FastClock(), pollMs: 1)
        flow.stopAndWait()
        await waitFor("failed") { if case .failed = flow.phase { return true }; return false }
        m.offline = false
        flow.stopAndWait()
        await waitFor("stopping") { flow.stoppedIds.count == 2 }
        #expect(flow.phase == .stopping)
        for id in flow.stoppedIds { m.confirmQuiescence(id) }
        await waitFor("quiet") { flow.phase == .quiet }
    }

    // An ended Run whose quiescence is unknown or not confirmed is not
    // quiet: quitting never treats an unknown state as finished.
    @Test func unknownQuiescenceIsNotQuiet() {
        for q in ["unknown", "not_confirmed", "pending"] {
            #expect(!QuitFlow.isQuiet(.obj([("phase", .string("ended")), ("quiescence", .string(q))])), "\(q)")
        }
        #expect(!QuitFlow.isQuiet(.obj([("phase", .string("stopping")), ("quiescence", .string("confirmed"))])))
        #expect(QuitFlow.isQuiet(.obj([("phase", .string("ended")), ("quiescence", .string("confirmed"))])))
    }

    // Review of #101: an answer without a list of Runs is not "no Runs".
    @Test func anAnswerWithoutRunsIsUnavailableNotZero() async {
        final class NoRuns: RuntimePort, @unchecked Sendable {
            let isSample = false
            func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue { .obj([]) }
            func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
        }
        let flow = QuitFlow(runtime: NoRuns(), clock: FastClock(), pollMs: 1)
        let counting = Task { await flow.countActive() }
        await waitFor("unavailable") { if case .unavailable = flow.activeCount { return true }; return false }
        #expect(!QuitDialogView.activeLine(flow.activeCount).contains("没有进行中的运行"))
        #expect(await flow.activeNow() == nil)
        flow.close()
        await counting.value
    }
}
