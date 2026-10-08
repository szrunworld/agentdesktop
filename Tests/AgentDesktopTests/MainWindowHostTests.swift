import AgentDesktopProtocol
import AgentDesktopRuntime
import AgentDesktopUI
import AppKit
import Foundation
import Testing
@testable import AgentDesktop

struct EmptyBackend: RuntimeBackend {
    var platform: Platform { Platform(os: "macos", osVersion: "15.1.0", arch: "arm64") }
    func permissions() -> BackendPermissions { BackendPermissions(screenRecording: .granted, accessibility: .granted) }
    func features() -> [String] { [] }
    func applications(includeBackground: Bool) -> [AppSummary] { [] }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] { [] }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: nil) }
}

struct FastClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 2_000_000) }
}

struct StillClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

@MainActor
@Suite("Main window in the host", .serialized)
struct MainWindowHostTests {
    @Test func rolesAndActivation() {
        #expect(HostRole.product.activationPolicy == .regular)
        let side = HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/adt-x/s.sock"))
        #expect(side.activationPolicy == .accessory)
        #expect(side.mainWindowForTest(environment: [:]) == nil, "a test copy shows no window unless asked")
        #expect(side.mainWindowForTest(environment: ["AGENTDESKTOP_MAIN_WINDOW": "1", "AGENTDESKTOP_MAIN_WINDOW_DISPLAY": "951"])
                == HostRole.TestWindowRequest(displayID: 951))
        #expect(HostRole.product.mainWindowForTest(environment: ["AGENTDESKTOP_MAIN_WINDOW": "1"]) == nil)
    }

    // The in-process port answers runtime/1 through the Runtime itself, as
    // the owner, on a connection of its own.
    @Test func inProcessPortSpeaksRuntime1() async throws {
        let service = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_ui", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                               endpoint: "/tmp/none.sock", buildSource: "unknown"),
                                     backend: EmptyBackend())
        let port = InProcessRuntimePort(service: service)
        #expect(!port.isSample)
        do {
            _ = try await port.call("runtime.status")
            Issue.record("expected handshake_required")
        } catch let e as RuntimeError {
            #expect(e.code == "handshake_required")
        }
        let store = ShellStore(runtime: port, clock: StillClock(), allowSubscription: false)
        await store.start()
        #expect(store.connection == .connected(instanceId: "rt_ui", productVersion: RuntimeAPI.productVersion))
        #expect(store.desktopsState == .empty)
        #expect(store.runUpdates == .polling, "U1b-1 polls even though the Runtime offers events.subscribe")
        store.stop()
    }

    @Test func unavailableRuntimeShowsDisconnected() async {
        let store = ShellStore(runtime: UnavailableRuntimePort(reason: "test"), clock: StillClock(), allowSubscription: false)
        await store.start()
        guard case .disconnected(let p) = store.connection else { Issue.record("connected"); return }
        #expect(p.code == "runtime_offline")
        #expect(MenuBarPanelView.status(store) == StatusText("Runtime 未连接", .danger))
        store.stop()
    }

    // Closing the main window hides it; the Store keeps its connection and
    // loop, and no Run changes (ADR-02).
    @Test func closingTheWindowAffectsNoRun() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        let controller = MainWindowController(store: store)
        let window = controller.ensureWindow()      // never ordered on screen
        #expect(window.isReleasedWhenClosed == false)
        let before = try await m.call("run.list", .obj([]))
        let calls = m.callLog.count
        controller.close()
        #expect(controller.closeCount == 1)
        #expect(store.isRunning, "the Store outlives the window")
        let after = try await m.call("run.list", .obj([]))
        #expect(before == after)
        #expect(!m.callLog.dropFirst(calls).contains { $0.hasPrefix("run.cancel") || $0 == "runtime.stopAll" })
        #expect(controller.ensureWindow() === window, "reopening shows the same window")
        store.stop()
    }

    @Test func menuStatusLines() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        #expect(MenuBarPanelView.summary(store) == "3 个 Desktop · 2 个运行进行中")
        #expect(MenuBarPanelView.status(store) == StatusText("运行中", .running))
        await store.stopAllInput()
        #expect(MenuBarPanelView.status(store) == StatusText("输入已停止", .attention))
        #expect(MenuBarPanelView.summary(store) == "3 个 Desktop · 2 个运行进行中（2 个停止中）")
    }

    // UC14 in the host: closing a preview window removes only the window.
    @Test func closingAPreviewWindowKeepsTheDesktop() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let controller = MainWindowController(store: store)
        // Never ordered on screen: the registry records it, the window is
        // built without showing.
        controller.previews.present = nil
        controller.previews.show("desk_001")
        let w = controller.previewWindows.window(for: "desk_001")
        #expect(w.isReleasedWhenClosed == false)
        let calls = m.callLog.count
        w.close()
        #expect(controller.previewWindows.windows["desk_001"] == nil)
        #expect(controller.previews.open.isEmpty)
        #expect(!m.callLog.dropFirst(calls).contains("desktop.destroy"))
        #expect(store.desktops.count == 3)
    }

    // A Desktop destroyed while the Runtime was unreachable: its preview
    // closes on the first successful refresh after reconnecting, although
    // the Store publishes the list before its state turns loaded.
    @Test func previewOfADesktopDestroyedWhileDisconnectedCloses() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let controller = MainWindowController(store: store)
        controller.previews.present = nil
        controller.previews.show("desk_001")
        m.offline = true
        await store.refreshDesktops()
        #expect(store.desktopsState != .loaded)
        m.offline = false
        _ = try await m.call("desktop.destroy", .obj([("desktopId", .string("desk_001"))]))
        await store.refreshDesktops()
        #expect(store.desktopsState == .loaded)
        #expect(controller.previews.open.isEmpty, "the preview of the destroyed Desktop closed")
    }

    // P32 choices. UC50: hiding or keeping in the background quits nothing
    // and stops nothing; UC51: stop-and-quit answers yes only once quiet.
    @Test func quitChoices() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let q = QuitController(store: store)
        q.clock = FastClock()
        var replies: [Bool] = [], hidden = 0, background = 0
        q.reply = { replies.append($0) }
        q.hideMainWindow = { hidden += 1 }
        q.keepInBackground = { background += 1 }

        await q.begin(show: false)
        q.choose(.hideWindow)
        #expect(replies == [false] && hidden == 1)
        await q.begin(show: false)
        q.choose(.keepInBackground)
        #expect(replies == [false, false] && background == 1)
        await q.begin(show: false)
        q.choose(.cancel)
        #expect(replies == [false, false, false])
        #expect(!m.callLog.contains("runtime.stopAll"), "none of these stops anything")
        #expect(store.activeRuns.count == 2)

        await q.begin(show: false)
        q.choose(.stopAndQuit)
        let flow = try #require(q.flow)
        for _ in 0..<200 where flow.stoppedIds.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(replies.count == 3, "no answer while Runs are only stopping")
        #expect(!q.approved)
        for id in flow.stoppedIds { m.confirmQuiescence(id) }
        for _ in 0..<200 where replies.count < 4 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(replies.last == true && q.approved)
    }

    // A stalled Runtime does not hold the quit dialog back: begin returns
    // before run.list answers, the count stays unknown (never zero) until
    // then, and the user can still call the quit off.
    @Test func quitDialogDoesNotWaitForTheRuntime() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        m.delays = ["run.list": 2_000_000_000]
        let q = QuitController(store: store)
        q.clock = FastClock()
        var replies: [Bool] = []
        q.reply = { replies.append($0) }
        let started = Date()
        await q.begin(show: false)
        #expect(Date().timeIntervalSince(started) < 1, "begin did not wait for run.list")
        let flow = try #require(q.flow)
        #expect(flow.activeCount == nil)
        #expect(QuitDialogView.activeLine(nil).hasPrefix("正在读取"))
        q.choose(.cancel)
        #expect(replies == [false])
        m.delays = [:]
        await q.counting?.value
        #expect(flow.activeCount == 2)
    }
}
