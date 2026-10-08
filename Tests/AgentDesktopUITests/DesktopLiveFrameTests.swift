import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

/// The live Desktop picture (P06, P07, P08) comes from a capture of the
/// Desktop's display through DesktopFrameHub, never from `observe`. These
/// tests use the fake source only; no real capture is started.
@MainActor
@Suite("Desktop live frames", .serialized)
struct DesktopLiveFrameTests {
    func display(_ store: ShellStore, _ id: String) -> UInt32? {
        DesktopFrameHub.displayId(of: store.desktops.first { $0["desktopId"]?.stringValue == id })
    }

    func loadedStore(_ m: MockRuntime) async -> ShellStore {
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        return store
    }

    // The live preview makes no observe and no artifact.read call, over
    // many store rounds and renders of every page that shows a picture.
    @Test func livePreviewNeverObserves() async throws {
        let m = MockRuntime.sample()
        let store = await loadedStore(m)
        let fake = FakeDesktopFrames()
        let detail = DesktopFrameLease(), side = DesktopFrameLease(), card = DesktopFrameLease()
        let preview = DesktopFrameLease()
        let d1 = try #require(display(store, "desk_001"))
        detail.attach(fake.hub, displayId: d1)
        side.attach(fake.hub, displayId: d1)
        card.attach(fake.hub, displayId: d1)
        preview.attach(fake.hub, displayId: d1, scope: PreviewWindowRegistry.scope("desk_001"))
        let source = try #require(fake.running(d1))
        let nav = ShellNavigation(section: .desktops)
        for round in 0..<40 {
            await store.refreshDesktops()
            source.push(width: 800, height: 500)
            if round % 10 == 0 {
                for setup in [{ nav.sideBySide = false; nav.desktopId = nil }, { nav.sideBySide = true },
                              { nav.showDesktop("desk_001") }] {
                    setup()
                    let view = MainWindowView(store: store, navigation: nav).environment(\.desktopFrames, fake.hub)
                    #expect(SnapshotRenderer.png(view) != nil)
                }
                let pv = DesktopPreviewView(store: store, desktopId: "desk_001", hide: {}, openDetail: {})
                    .environment(\.desktopFrames, fake.hub)
                #expect(SnapshotRenderer.png(pv, size: CGSize(width: 900, height: 640)) != nil)
            }
        }
        #expect(source.isRunning && detail.frame != nil)
        #expect(m.observations == 0)
        #expect(!m.callLog.contains("observe") && !m.callLog.contains("artifact.read"))
        for l in [detail, side, card, preview] { l.detach() }
    }

    // One stream per display, shared; it stops with its last consumer.
    @Test func streamLifecycle() async throws {
        let m = MockRuntime.sample()
        let store = await loadedStore(m)
        let fake = FakeDesktopFrames()
        let hub = fake.hub
        let registry = PreviewWindowRegistry(frames: hub)
        registry.present = { _ in }
        let d1 = try #require(display(store, "desk_001")), d2 = try #require(display(store, "desk_002"))

        // Detail page open: one stream.
        let detail = DesktopFrameLease()
        detail.attach(hub, displayId: d1)
        #expect(hub.streamCount == 1)
        // Side by side and a preview window of the same Desktop: still one.
        let side = DesktopFrameLease()
        side.attach(hub, displayId: d1)
        registry.show("desk_001")
        let preview = DesktopFrameLease()
        preview.attach(hub, displayId: d1, scope: PreviewWindowRegistry.scope("desk_001"))
        #expect(hub.streamCount == 1 && hub.consumerCount == 3 && fake.made.count == 1)
        // Attaching again for the same display does not add a consumer.
        detail.attach(hub, displayId: d1)
        #expect(hub.consumerCount == 3)

        // Closing every consumer: no stream.
        registry.hide("desk_001")
        #expect(hub.consumerCount == 2 && hub.streamCount == 1)
        side.detach()
        detail.detach()
        #expect(hub.streamCount == 0 && hub.consumerCount == 0 && fake.running.isEmpty)
        #expect(hub.feed(d1) == nil, "the last frame goes with the last consumer")
        preview.detach()   // already released with its window: no-op
        #expect(hub.consumerCount == 0)

        // Two Desktops: two streams.
        let a = DesktopFrameLease(), b = DesktopFrameLease()
        a.attach(hub, displayId: d1)
        b.attach(hub, displayId: d2)
        #expect(hub.streamCount == 2 && hub.streamingDisplays == [d1, d2])

        // The main window hidden or closed: its streams pause, the last
        // frame stays; shown again: they resume.
        try #require(fake.running(d1)).push(width: 640, height: 400)
        hub.setScopeVisible(DesktopFrameHub.mainScope, false)
        #expect(hub.streamCount == 0 && a.status == .paused && a.frame != nil)
        hub.setScopeVisible(DesktopFrameHub.mainScope, true)
        #expect(hub.streamCount == 2)

        // A preview window occluded pauses only its own consumers.
        registry.show("desk_002")
        let p2 = DesktopFrameLease()
        p2.attach(hub, displayId: d2, scope: PreviewWindowRegistry.scope("desk_002"))
        b.detach()
        registry.setVisible("desk_002", false)
        #expect(hub.streamingDisplays == [d1])
        registry.setVisible("desk_002", true)
        #expect(hub.streamingDisplays == [d1, d2])

        // A Desktop destroyed: its stream stops and its preview closes.
        _ = try await m.call("desktop.destroy", .obj([("desktopId", .string("desk_002"))]))
        await store.refreshDesktops()
        registry.sync(desktops: store.desktops)
        #expect(registry.open.isEmpty)
        #expect(hub.streamingDisplays == [d1])
        #expect(m.callLog.filter { $0 == "desktop.destroy" }.count == 1, "the preview closing destroyed nothing else")

        // A lease dropped without detaching lets go by itself.
        var dropped: DesktopFrameLease? = DesktopFrameLease()
        dropped?.attach(hub, displayId: d2)
        #expect(hub.streamCount == 2)
        dropped = nil
        await waitFor("dropped lease released") { hub.streamCount == 1 }

        // App quit: everything stops.
        hub.stopAll()
        #expect(hub.streamCount == 0 && hub.consumerCount == 0 && hub.retainedFrameCount == 0 && fake.running.isEmpty)
        #expect(m.observations == 0)
    }

    // Only the latest frame is kept: earlier ones are freed.
    @Test func onlyTheLatestFrameIsRetained() throws {
        let fake = FakeDesktopFrames()
        let lease = DesktopFrameLease()
        lease.attach(fake.hub, displayId: 501)
        let source = try #require(fake.running(501))
        weak var first: DesktopFrame?
        do {
            let f = DesktopFrame(image: FakeDesktopFrameSource.image(width: 1600, height: 1000), scale: 1)
            first = f
            source.push(f)
        }
        #expect(first != nil && lease.frame === first)
        var weakFrames: [() -> DesktopFrame?] = []
        for i in 0..<120 {
            let f = DesktopFrame(image: FakeDesktopFrameSource.image(width: 1600, height: 1000), scale: 1)
            if i < 119 { weak var w = f; weakFrames.append { w } }
            source.push(f)
        }
        #expect(first == nil, "the first frame was freed")
        #expect(weakFrames.allSatisfy { $0() == nil }, "no earlier frame is kept")
        #expect(fake.hub.retainedFrameCount == 1 && fake.hub.feed(501)?.framesReceived == 121)
        lease.detach()
        #expect(fake.hub.retainedFrameCount == 0)
    }

    // No permission or a failed capture: honest text, no picture, no
    // automatic restart; a retry starts the capture again.
    @Test func permissionAndFailureStates() throws {
        let fake = FakeDesktopFrames()
        fake.failOnStart[501] = .permissionDenied
        let denied = DesktopFrameLease()
        denied.attach(fake.hub, displayId: 501)
        #expect(denied.status == .permissionDenied && denied.frame == nil)
        #expect(DesktopFrameView.problemText(denied.status)?.title == "需要屏幕录制权限")
        #expect(DesktopFrameView.statusText(denied.status) == "需要屏幕录制权限")
        #expect(CardPicture.note(denied.status) == "需要屏幕录制权限")
        #expect(fake.hub.streamCount == 0)
        // Another view of the same display does not hammer the capture.
        let other = DesktopFrameLease()
        other.attach(fake.hub, displayId: 501)
        #expect(fake.made.count == 1 && other.status == .permissionDenied)
        #expect(SnapshotRenderer.png(DesktopFrameView(lease: denied, zoom: .constant(.fit)), size: CGSize(width: 600, height: 400)) != nil)
        // Granted later: the retry starts the capture.
        fake.failOnStart[501] = nil
        denied.retry()
        #expect(fake.made.count == 2 && fake.hub.streamCount == 1 && denied.status == .starting)

        // A capture that fails while running keeps its last frame and says so.
        let source = try #require(fake.running(501))
        source.push(width: 320, height: 200)
        source.failNow(.unavailable("屏幕捕获失败：测试"))
        #expect(denied.status == .unavailable("屏幕捕获失败：测试") && denied.frame != nil)
        #expect(DesktopFrameView.problemText(denied.status)?.title == "画面暂不可用")
        #expect(fake.hub.streamCount == 0)

        // No hub in this window (renders) or no display: unavailable.
        let none = DesktopFrameLease()
        none.attach(nil, displayId: 501)
        #expect(DesktopFrameView.problemText(none.status)?.title == "画面暂不可用" && none.frame == nil)
        none.attach(fake.hub, displayId: nil)
        #expect(DesktopFrameView.problemText(none.status)?.title == "画面暂不可用")
        #expect(DesktopFrameHub.displayId(of: .obj([("screen", .obj([("displayId", .int(0))]))])) == nil)
        denied.detach()
        other.detach()
    }
}
