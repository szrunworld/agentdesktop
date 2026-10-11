import AgentDesktopProtocol
@testable import AgentDesktopRuntime
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
    /// An executable in no app bundle: known not to be iPhone Mirroring (#139).
    func executablePath(_ pid: Int32) -> String? { "/test/bin/process" }
}

/// A platform that has no screens: every screen call is refused. Enough
/// for the Runtime to serve its platform methods (events.subscribe, runs).
struct NoScreenPlatform: DesktopPlatform {
    struct Refused: Error {}
    func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle { throw Refused() }
    func destroyScreen(name: String) throws { throw Refused() }
    func resizeScreen(name: String, width: Int, height: Int) throws -> ScreenHandle { throw Refused() }
    func attachDisplay(_ displayId: UInt32?) throws -> ScreenHandle { throw Refused() }
    func displays() -> [PlatformDisplay] { [] }
    func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws
        -> (pid: Int32, windows: [PlatformWindow]) { throw Refused() }
    func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow] { throw Refused() }
    func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow? { nil }
    func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int) { throw Refused() }
    func stack(on screen: ScreenHandle) -> [PlatformWindow] { [] }
    func windowScreenshot(_ screen: ScreenHandle, pid: Int32, windowId: UInt32, to path: String) throws -> (width: Int, height: Int) { throw Refused() }
    func overlays(on screen: ScreenHandle, boundPid: Int32) -> [PlatformWindow] { [] }
    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws -> ElementRead { throw Refused() }
    func quit(pid: Int32) -> Bool { false }
    func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String { throw Refused() }
}

struct FastClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 2_000_000) }
}

struct StillClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

/// Waits on the Store's update rounds; the timer only ends a hung test.
@MainActor
func hostUntil(_ what: String, _ store: ShellStore, _ check: @escaping @MainActor () -> Bool) async {
    if check() { return }
    let ok = await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor in
            for await _ in store.$tick.values { if check() { return true } }
            return false
        }
        group.addTask { try? await Task.sleep(nanoseconds: 60_000_000_000); return false }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    if !ok { Issue.record("timed out waiting for \(what); updates \(store.runUpdates), fallback \(String(describing: store.pushFallback))") }
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
        #expect(side.mainWindowForTest(environment: ["AGENTDESKTOP_MAIN_WINDOW": "1", "AGENTDESKTOP_MAIN_WINDOW_DISPLAY": "first-desktop"])
                == HostRole.TestWindowRequest(displayID: nil, onFirstDesktop: true))
        #expect(HostRole.product.mainWindowForTest(environment: ["AGENTDESKTOP_MAIN_WINDOW": "1",
                                                                 "AGENTDESKTOP_MAIN_WINDOW_DISPLAY": "first-desktop"]) == nil)
    }

    // The in-process port answers runtime/1 through the Runtime itself, as
    // the owner, on a connection of its own.
    @Test func inProcessPortSpeaksRuntime1() async throws {
        let service = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_ui", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                               endpoint: "/tmp/none.sock", buildSource: "unknown"),
                                     backend: EmptyBackend()); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
        let port = InProcessRuntimePort(service: service)
        #expect(!port.isSample)
        do {
            _ = try await port.call("runtime.status")
            Issue.record("expected handshake_required")
        } catch let e as RuntimeError {
            #expect(e.code == "handshake_required")
        }
        let store = ShellStore(runtime: port, clock: StillClock())
        await store.start()
        #expect(store.connection == .connected(instanceId: "rt_ui", productVersion: RuntimeAPI.productVersion))
        #expect(store.desktopsState == .empty)
        // This Runtime has no platform, so it lists no events.subscribe:
        // Runs are polled (the push case is the next test).
        #expect(store.runUpdates == .polling)
        store.stop()
    }

    // U1b-2: a Run started in the Runtime reaches the window through the
    // in-process subscription, then its stop, without polling run.list;
    // the stream's own connection never controls the Run.
    @Test func inProcessPortPushesRunEvents() async throws {
        let service = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_push", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                               endpoint: "/tmp/none.sock", buildSource: "unknown"),
                                     backend: EmptyBackend(), platform: NoScreenPlatform()); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
        let port = InProcessRuntimePort(service: service)
        let store = ShellStore(runtime: port, clock: StillClock())
        await store.start()
        await hostUntil("push live", store) { store.pushLive }
        #expect(store.pushFallback == nil, "\(String(describing: store.pushFallback))")
        let session = service.sessions.open(desktopId: "desk_push", caller: "local:\(getuid())", at: Timestamp.string(Date()))
        let run = try service.execution.startDurable(kind: "unit", session: session, origin: .guiExplorer).get()
        await hostUntil("pushed run", store) { store.runs.contains { $0["runId"]?.stringValue == run.runId } }
        _ = service.execution.stop(runId: run.runId, reason: "stopped", endAs: .cancelled)
        await hostUntil("stop pushed", store) {
            store.runs.first { $0["runId"]?.stringValue == run.runId }?["phase"]?.stringValue != "running"
        }
        #expect(store.runUpdates == .subscription)
        #expect(store.eventCursor != nil)
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
        let controller = MainWindowController(store: store, frames: FakeDesktopFrames().hub)
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
        let fake = FakeDesktopFrames()
        let controller = MainWindowController(store: store, frames: fake.hub)
        // Never ordered on screen: the registry records it, the window is
        // built without showing.
        controller.previews.present = nil
        controller.previews.show("desk_001")
        let w = controller.previewWindows.window(for: "desk_001")
        #expect(w.isReleasedWhenClosed == false)
        // What the preview view does when it appears: hold the Desktop's
        // display in the window's scope.
        let lease = DesktopFrameLease()
        lease.attach(controller.frames, displayId: DesktopFrameHub.displayId(of: store.desktops.first { $0["desktopId"]?.stringValue == "desk_001" }),
                     scope: PreviewWindowRegistry.scope("desk_001"))
        #expect(controller.frames.streamCount == 1)
        let calls = m.callLog.count
        w.close()
        #expect(controller.previewWindows.windows["desk_001"] == nil)
        #expect(controller.previews.open.isEmpty)
        #expect(controller.frames.streamCount == 0 && controller.frames.consumerCount == 0, "closing the window stops its stream")
        #expect(fake.running.isEmpty)
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
        let fake = FakeDesktopFrames()
        let controller = MainWindowController(store: store, frames: fake.hub)
        controller.previews.present = nil
        controller.previews.show("desk_001")
        let lease = DesktopFrameLease()
        lease.attach(controller.frames, displayId: DesktopFrameHub.displayId(of: store.desktops.first { $0["desktopId"]?.stringValue == "desk_001" }),
                     scope: DesktopFrameHub.mainScope)
        controller.frames.setScopeVisible(DesktopFrameHub.mainScope, true)
        #expect(controller.frames.streamCount == 1)
        m.offline = true
        await store.refreshDesktops()
        #expect(store.desktopsState != .loaded)
        m.offline = false
        _ = try await m.call("desktop.destroy", .obj([("desktopId", .string("desk_001"))]))
        await store.refreshDesktops()
        #expect(store.desktopsState == .loaded)
        #expect(controller.previews.open.isEmpty, "the preview of the destroyed Desktop closed")
        #expect(controller.frames.streamCount == 0, "nothing captures the destroyed Desktop's display")
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
    // before run.list answers, the count reads "reading", then "cannot
    // tell" once the read times out (never zero), and fills in when the
    // Runtime answers; the user can call the quit off throughout.
    @Test func quitDialogDoesNotWaitForTheRuntime() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        m.delays = ["run.list": 300_000_000]
        let q = QuitController(store: store)
        q.clock = FastClock()
        var replies: [Bool] = []
        q.reply = { replies.append($0) }
        let listsBefore = m.callLog.filter { $0 == "run.list" }.count
        let started = Date()
        await q.begin(show: false)
        #expect(Date().timeIntervalSince(started) < 0.25, "begin did not wait for run.list")
        let flow = try #require(q.flow)
        #expect(flow.activeCount == .reading)
        #expect(QuitDialogView.activeLine(.reading).hasPrefix("正在读取"))
        for _ in 0..<200 where flow.activeCount == .reading { try await Task.sleep(nanoseconds: 2_000_000) }
        guard case .unavailable(let why) = flow.activeCount else { Issue.record("\(flow.activeCount)"); return }
        #expect(QuitDialogView.activeLine(flow.activeCount).contains("暂时读不到"))
        #expect(!QuitDialogView.activeLine(flow.activeCount).contains("没有进行中的运行"), "\(why)")
        await q.counting?.value
        #expect(flow.activeCount == .known(2), "the late answer fills the count in")
        #expect(m.callLog.filter { $0 == "run.list" }.count - listsBefore == 1, "a read in flight is not sent again")
        q.choose(.cancel)
        #expect(replies == [false])
    }

    // UC51 on the machine (2026-10-08): a second quit request while the
    // dialog waited made AppKit force termination, so the test copy exited
    // with its Runs still running. While the dialog is open a request only
    // brings it forward; once answered, the next one asks again.
    @Test func aSecondQuitRequestWhileAskingDoesNotTerminate() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let q = QuitController(store: store)
        q.clock = FastClock()
        var terminations = 0, replies: [Bool] = []
        q.terminate = { terminations += 1 }
        q.reply = { replies.append($0) }
        q.requestQuit()
        #expect(terminations == 1, "with no dialog open a request starts the quit")
        await q.begin(show: false)
        q.requestQuit()
        q.requestQuit()
        #expect(terminations == 1, "no terminate while the dialog waits for an answer")
        #expect(replies.isEmpty)
        q.choose(.cancel)
        #expect(replies == [false])
        q.requestQuit()
        #expect(terminations == 2)
    }

    // Review of #101: a stop called off while a Runtime answer is in flight
    // never turns quiet afterwards, and a late quiet never approves a later
    // quit (which would then skip the dialog and stop-and-wait).
    @Test func aLateQuietAfterCancelApprovesNothing() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let q = QuitController(store: store)
        q.clock = FastClock()
        var replies: [Bool] = []
        q.reply = { replies.append($0) }
        await q.begin(show: false)
        let flow = try #require(q.flow)
        m.delays = ["run.list": 200_000_000]
        q.choose(.stopAndQuit)
        for _ in 0..<200 where flow.stoppedIds.count < 2 { try await Task.sleep(nanoseconds: 2_000_000) }
        for id in flow.stoppedIds { m.confirmQuiescence(id) }
        q.choose(.cancel)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(flow.phase == .cancelled, "the late answer did not turn the cancelled stop quiet")
        #expect(!q.approved)
        #expect(replies == [false])
    }

    // Review of #101: once the dialog is answered nothing keeps reading the
    // count, even while the Runtime cannot be reached.
    @Test func answeringTheDialogStopsReadingTheCount() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        m.offline = true
        let q = QuitController(store: store)
        q.clock = FastClock()
        q.reply = { _ in }
        q.hideMainWindow = {}
        await q.begin(show: false)
        let flow = try #require(q.flow)
        for _ in 0..<200 where flow.activeCount == .reading { try await Task.sleep(nanoseconds: 2_000_000) }
        q.choose(.hideWindow)
        await q.counting?.value
        #expect(flow.closed)
        let calls = m.callLog.count
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(m.callLog.count == calls, "no reads after the answer")
    }
}
