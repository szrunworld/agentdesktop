import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

// The owner's display entry (owner-display-attach.md): the window lists
// what the Runtime proved, asks it to attach, and shows only its answer.
@MainActor
@Suite("Owner display attach", .serialized)
struct DisplayAttachTests {
    func loaded(_ m: MockRuntime) async -> ShellStore {
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        return store
    }

    @Test func theFlowOffersOnlyProvedPhysicalDisplaysAndAttachesThroughTheRuntime() async throws {
        let m = MockRuntime.sample()
        let store = await loaded(m)
        let flow = AttachDisplayFlow(runtime: m)
        #expect(!flow.canSubmit)
        await flow.load()
        #expect(flow.displays.count == 2 && flow.clients.count == 1)
        #expect(flow.displays.filter(AttachDisplayFlow.attachable).map { $0["displayId"]?.intValue } == [1])
        // Preselected: the one attachable display and the one client.
        #expect(flow.displayId == 1 && flow.clientId == "app:mock-001")
        #expect(AttachDisplayFlow.originText(flow.displays[1]).text.contains("虚拟"))
        #expect(flow.canSubmit)
        // A virtual display cannot be chosen into a submission.
        flow.displayId = 9
        #expect(!flow.canSubmit)
        flow.displayId = 1
        flow.name = "我的主显示器"
        await flow.submit()
        #expect(flow.isDone, "\(flow.step)")
        let id = try #require(flow.desktopId)
        #expect(flow.result?["created"]?.boolValue == true && flow.result?["grant"]?["revision"]?.intValue == 2)
        #expect(m.callLog.contains("hub.displays.attach") && m.contractViolations.isEmpty, "\(m.contractViolations)")
        await store.refreshDesktops()
        let d = try #require(store.desktops.first { $0["desktopId"]?.stringValue == id })
        #expect(d["kind"]?.stringValue == "physical" && d["name"]?.stringValue == "我的主显示器")
        // The display is now attached: listed as such, and a second attach reuses the Desktop.
        let again = AttachDisplayFlow(runtime: m)
        await again.load()
        #expect(again.displayId == nil, "nothing attachable is preselected")
        #expect(again.displays[0]["desktopId"]?.stringValue == id && AttachDisplayFlow.originText(again.displays[0]).text == "已挂接")
    }

    @Test func aRefusalShowsTheProblemAndKeepsTheForm() async {
        let m = MockRuntime.sample()
        _ = await loaded(m)
        let flow = AttachDisplayFlow(runtime: m)
        await flow.load()
        m.failNext("hub.displays.attach", code: "permission_denied")
        await flow.submit()
        guard case let .failed(p) = flow.step else { Issue.record("not failed: \(flow.step)"); return }
        #expect(p.code == "permission_denied")
        #expect(SnapshotRenderer.png(AttachDisplaySheet(flow: flow, cancel: {}, finished: { _ in })) != nil)
        flow.reset()
        #expect(flow.canSubmit && flow.result == nil)
        #expect(!m.callLog.contains("desktop.create"), "the window never creates a Desktop by itself")
    }

    @Test func thePhysicalDesktopPanelListsAndTakesBackAccess() async throws {
        let m = MockRuntime.sample()
        let store = await loaded(m)
        let flow = AttachDisplayFlow(runtime: m)
        await flow.load()
        await flow.submit()
        let id = try #require(flow.desktopId)
        let b = m.addClient(name: "second", apps: ["com.example.probe"])
        let second = AttachDisplayFlow(runtime: m)
        await second.load()
        second.displayId = 1
        #expect(!second.canSubmit, "already attached: not offered again")
        let access = PhysicalDesktopAccess(runtime: m, desktopId: id)
        await access.load()
        #expect(access.grants.map { $0["clientId"]?.stringValue } == ["app:mock-001"])
        _ = b
        await access.detach(clientId: "app:mock-001")
        #expect(access.grants.isEmpty && !access.detachedAll)
        await store.refreshDesktops()
        #expect(store.desktops.contains { $0["desktopId"]?.stringValue == id }, "the Desktop stays until detached from everyone")
        await access.detach(clientId: nil)
        #expect(access.detachedAll)
        await store.refreshDesktops()
        #expect(!store.desktops.contains { $0["desktopId"]?.stringValue == id })
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func theSheetAndThePhysicalDetailRender() async throws {
        let m = MockRuntime.sample()
        let store = await loaded(m)
        let flow = AttachDisplayFlow(runtime: m)
        await flow.load()
        let form = SnapshotRenderer.png(AttachDisplaySheet(flow: flow, cancel: {}, finished: { _ in }), size: CGSize(width: 640, height: 720))
        #expect((form?.count ?? 0) > 10_000)
        await flow.submit()
        let done = SnapshotRenderer.png(AttachDisplaySheet(flow: flow, cancel: {}, finished: { _ in }), size: CGSize(width: 640, height: 480))
        #expect((done?.count ?? 0) > 5_000)
        await store.refreshDesktops()
        let id = try #require(flow.desktopId)
        let nav = ShellNavigation(section: .desktops, desktopId: id)
        let png = SnapshotRenderer.png(MainWindowView(store: store, navigation: nav))
        #expect((png?.count ?? 0) > 10_000)
        #expect(m.observations == 0 && !m.callLog.contains("observe"), "no observation for the detail or the sheet")
    }
}
