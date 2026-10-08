import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

@MainActor
@Suite("Desktops U2a", .serialized)
struct DesktopsU2aTests {
    // UC03: an empty name is refused in place; nothing is sent.
    @Test func uc03_nameIsRequired() async {
        let m = MockRuntime()
        let flow = CreateDesktopFlow(runtime: m)
        flow.name = "   "
        await flow.submit()
        #expect(flow.nameError == "请填写名称")
        #expect(!flow.started)
        #expect(!m.callLog.contains("desktop.create"))
        flow.name = "表单验证"
        #expect(flow.validate())
        flow.mode = .launch
        #expect(!flow.validate() && flow.choiceError == "请选择或填写要启动的应用")
        flow.mode = .bind
        #expect(!flow.validate() && flow.choiceError == "请选择一个窗口")
    }

    // UC04–UC06, UC52: creating shows the real step, the new Desktop gets
    // its own desktopId, waits for a controller and shows no sample app.
    @Test func uc04to06_uc52_createEmpty() async throws {
        let m = MockRuntime.sample()
        m.delays = ["desktop.create": 200_000_000]
        let flow = CreateDesktopFlow(runtime: m)
        flow.name = "新 Desktop"
        let task = Task { await flow.submit() }
        await waitFor("creating") { flow.createStep == .running }
        #expect(flow.started && flow.isWorking)
        await task.value
        #expect(flow.createStep == .done && flow.attachStep == .skipped && flow.isDone)
        let id = try #require(flow.desktopId)
        let list = try await m.call("desktop.list")["desktops"]!.arrayValue!
        #expect(list.filter { $0["desktopId"]?.stringValue == id }.count == 1)
        #expect(!["desk_001", "desk_002", "desk_003"].contains(id))
        let d = list.first { $0["desktopId"]?.stringValue == id }!
        #expect(d["binding"]!.isNull, "an empty Desktop has no app")
        #expect(DesktopControlPresentation.make(desktop: d, activeRuns: []).status == StatusText("等待接入", .idle))
        #expect(!m.callLog.contains("app.launch") && !m.callLog.contains("window.bind"))
        #expect(m.callLog.filter { $0 == "desktop.create" }.count == 1)
    }

    @Test func createWithSizeLaunchAndBind() async throws {
        let m = MockRuntime()
        let launch = CreateDesktopFlow(runtime: m)
        launch.name = "A"
        launch.mode = .launch
        launch.bundleId = "com.example.probe"
        launch.showSize = true
        launch.width = 1440
        launch.height = 900
        await launch.submit()
        #expect(launch.isDone)
        #expect(launch.desktop?["binding"]?["appName"]?.stringValue == "Probe")
        #expect(DesktopControlPresentation.sizeText(launch.desktop!) == "1440 × 900")

        let byPath = CreateDesktopFlow(runtime: m)
        byPath.bundleId = "/tmp/x/Probe.app"
        #expect(byPath.launchTarget.0 == "path")
        byPath.bundleId = "com.example.probe"
        #expect(byPath.launchTarget.0 == "bundleId")

        m.addFreeWindow(pid: 4242, windowId: 9001)
        let bind = CreateDesktopFlow(runtime: m)
        await bind.loadChoices()
        #expect(bind.windows.contains { $0["windowId"]?.intValue == 9001 })
        bind.name = "B"
        bind.mode = .bind
        bind.window = bind.windows.first { $0["windowId"]?.intValue == 9001 }
        await bind.submit()
        #expect(bind.isDone)
        #expect(bind.desktop?["binding"]?["windowId"]?.intValue == 9001)
    }

    // P05: a failed step keeps its error; retry repeats only that step.
    @Test func failedStepRetriesAlone() async throws {
        let m = MockRuntime()
        m.failNext("app.launch", code: "execution_failed")
        let flow = CreateDesktopFlow(runtime: m)
        flow.name = "A"
        flow.mode = .launch
        flow.bundleId = "com.example.probe"
        await flow.submit()
        guard case .failed(let p) = flow.attachStep else { Issue.record("not failed"); return }
        #expect(p.code == "execution_failed")
        #expect(flow.createStep == .done && flow.hasFailed)
        await flow.retry()
        #expect(flow.isDone)
        #expect(m.callLog.filter { $0 == "desktop.create" }.count == 1, "the Desktop is not created twice")
        #expect(m.callLog.filter { $0 == "app.launch" }.count == 2)
        #expect(flow.desktop?["binding"]?["appName"]?.stringValue == "Probe")

        // A failed bind after a good launch retries the bind only.
        let b = MockRuntime()
        b.failNext("window.bind", code: "stale_observation")
        let f3 = CreateDesktopFlow(runtime: b)
        f3.name = "C"
        f3.mode = .launch
        f3.bundleId = "com.example.probe"
        await f3.submit()
        guard case .failed = f3.attachStep else { Issue.record("bind not failed"); return }
        await f3.retry()
        #expect(f3.isDone)
        #expect(b.callLog.filter { $0 == "app.launch" }.count == 1, "the app is not launched twice")

        let c = MockRuntime()
        c.failNext("desktop.create", code: "limit_exceeded")
        let f2 = CreateDesktopFlow(runtime: c)
        f2.name = "B"
        await f2.submit()
        guard case .failed = f2.createStep else { Issue.record("create not failed"); return }
        #expect(f2.desktopId == nil)
        await f2.retry()
        #expect(f2.isDone)
    }

    // UC49: zooming only changes the display: the capture is not
    // restarted and the Runtime is not called.
    @Test func uc49_zoomNeverRestartsTheCapture() async throws {
        let m = MockRuntime.sample()
        let fake = FakeDesktopFrames()
        let lease = DesktopFrameLease()
        lease.attach(fake.hub, displayId: 501)
        try #require(fake.running(501)).push(width: 1600, height: 1000, scale: 2)
        #expect(lease.status == .live && lease.frame?.pixelWidth == 1600)
        #expect(PreviewZoom.actual.factor(imageScale: 2) == 0.5)
        #expect(PreviewZoom.fit.factor(imageScale: 2) == nil)
        #expect(DesktopFrameView.sizeText(lease.frame) == "1600 × 1000 px · scale 2x")
        let calls = m.callLog.count
        for z in PreviewZoom.allCases {
            let png = SnapshotRenderer.png(DesktopFrameView(lease: lease, zoom: .constant(z)), size: CGSize(width: 600, height: 400))
            #expect(png != nil)
        }
        #expect(fake.hub.startedCount == 1 && fake.made.count == 1, "one capture for all zoom levels")
        #expect(m.callLog.count == calls && m.observations == 0)
        lease.detach()
    }

    // UC14: hiding or closing a preview never touches the Desktop.
    @Test func uc14_closingAPreviewKeepsTheDesktop() async throws {
        let m = MockRuntime.sample()
        let registry = PreviewWindowRegistry()
        var shown: [String] = [], dismissed: [String] = []
        registry.present = { shown.append($0) }
        registry.dismiss = { dismissed.append($0) }
        registry.show("desk_001")
        registry.show("desk_001")
        #expect(registry.open == ["desk_001"] && shown == ["desk_001", "desk_001"])
        let before = try await m.call("desktop.list")
        let calls = m.callLog.count
        registry.hide("desk_001")
        #expect(registry.open.isEmpty && dismissed == ["desk_001"])
        registry.show("desk_002")
        registry.closed("desk_002")
        #expect(registry.open.isEmpty)
        #expect(m.callLog.count == calls, "no Runtime call at all")
        #expect(try await m.call("desktop.list") == before)
    }

    // UC16: a Desktop closed elsewhere leaves the overview, its detail says
    // it is gone, and its preview closes.
    @Test func uc16_closedDesktopDisappears() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let registry = PreviewWindowRegistry()
        registry.show("desk_003")
        _ = try await m.call("desktop.destroy", .obj([("desktopId", .string("desk_003"))]))
        await store.refreshDesktops()
        #expect(!store.desktops.contains { $0["desktopId"]?.stringValue == "desk_003" })
        #expect(DesktopsOverviewView.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "计算器").isEmpty)
        #expect(DesktopInspectorView.state(list: store.desktopsState, found: false) == .empty)
        registry.prune(existing: Set(store.desktops.compactMap { $0["desktopId"]?.stringValue }))
        #expect(registry.open.isEmpty)
    }

    // UC19–UC21: search with and without results, clearing, grid and list.
    @Test func uc19to21_searchFilterLayout() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        typealias O = DesktopsOverviewView
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "不存在的名字").isEmpty)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "文本").count == 1)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .idle, query: "文本").isEmpty)
        #expect(O.visible(store.desktops, activeRuns: store.activeRuns, filter: .all, query: "").count == 3, "clearing restores the list")
        #expect(O.Layout.allCases.map(\.rawValue) == ["网格", "列表"])
        let nav = ShellNavigation(section: .desktops)
        for _ in O.Layout.allCases {
            let png = SnapshotRenderer.png(MainWindowView(store: store, navigation: nav))
            #expect((png?.count ?? 0) > 10_000)
        }
        nav.sideBySide = true
        #expect((SnapshotRenderer.png(MainWindowView(store: store, navigation: nav))?.count ?? 0) > 10_000)
        nav.showDesktop("desk_001")
        #expect(!nav.sideBySide && nav.desktopId == "desk_001")
    }
}
