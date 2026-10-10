import AgentDesktopProtocol
import CryptoKit
import Foundation
import Testing
@testable import AgentDesktopRuntime

// The GUI layer's ports served by the Runtime: same observation, same
// executor, same ledger as every other caller.

func guiScene() throws -> (FakePlatform, RuntimeService, RuntimeGuiPorts, String) {
    let platform = FakePlatform()
    platform.realImages = true
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try created(s, c)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    return (platform, s, RuntimeGuiPorts(service: s), d)
}

func proposal(_ body: GuiProposalBody, run: String, stamp: ObservationStamp, shot: String) -> GuiProposal {
    GuiProposal(proposalId: "prop-\(UUID().uuidString.prefix(8))", runId: run, stepIndex: 1, inferenceAttemptId: "att-1",
                stamp: stamp, screenshotId: shot,
                provenance: AdapterProvenance(adapterId: .uitarsV1, adapterVersion: "1", promptVersion: "1", parserVersion: "1",
                                              coordinateProtocol: .normalized1000),
                body: body)
}

@Test func observeHandsTheModelTheBoundWindowWithExactTransforms() async throws {
    let (_, s, ports, d) = try guiScene()
    let r1 = try await guiRun(s, ports, d)
    let bundle = try await ports.observe(runId: r1, expectedGeneration: 7)
    let o = bundle.observation
    #expect(o.stamp.desktopId == d && o.stamp.runGeneration == 7 && o.stamp.bindingEpoch == 1)
    #expect(o.target.windowId == "11" && o.target.processId == 101 && o.target.backendId == "2ndscreen-engine")
    let shot = try #require(o.screenshots.first)
    // The Runtime's image already is the window (2100,100) 400x300 at 2x (G0).
    #expect(shot.transform.crop == GuiRect(x: 0, y: 0, width: 800, height: 600))
    #expect(shot.transform.modelInputSize == Size(width: 800, height: 600))
    let corner = shot.sourceToDesktop.apply(Point(x: 0, y: 0))
    #expect(corner == Point(x: 2100, y: 100))
    let image = try #require(bundle.currentImage)
    #expect(pngSize(image.bytes).map { $0 == (800, 600) } == true)
    #expect(shot.sha256 == SHA256.hash(data: image.bytes).map { String(format: "%02x", $0) }.joined())
    #expect(FileManager.default.fileExists(atPath: s.artifacts.path(for: shot.artifactRef, ext: "png")))
    #expect(bundle.elements?.first == ObservedElement(role: "button", text: "继续"))
    #expect(bundle.elements?.last == ObservedElement(role: "text_field", text: "Ada \"Q\""))
}

@Test func executeRunsThroughTheRuntimeExecutorOncePerActionId() async throws {
    let (platform, s, ports, d) = try guiScene()
    let r1 = try await guiRun(s, ports, d)
    let bundle = try await ports.observe(runId: r1, expectedGeneration: 1)
    let shot = bundle.observation.screenshots[0].screenshotId
    // Source pixel (100,100) → (2150,150) in points, inside the window.
    let p = proposal(.action(.click(sourcePixel: Point(x: 100, y: 100))), run: r1, stamp: bundle.observation.stamp, shot: shot)
    let r = try await ports.execute(p, actionId: "act-1")
    #expect(r.deliveryState == .confirmed)
    #expect(r.executionTarget?.windowId == "11")
    #expect(r.confirmationObservationId != nil)
    #expect(r.inputPath == "event.click")
    #expect(platform.performed.last?.point?.x == 2150 && platform.performed.last?.point?.y == 150)
    // The same actionId again: replayed by the ledger, no second click.
    let again = try await ports.execute(p, actionId: "act-1")
    #expect(again.deliveryState == .confirmed)
    #expect(platform.performed.count == 1)
    #expect(try s.ledger.record(caller: "local:\(getuid())", requestId: "gui-act-1")?.method == "act")

    // Keys: Meta+A → cmd-a.
    let k = proposal(.action(.key(keys: ["Meta", "A"])), run: r1, stamp: bundle.observation.stamp, shot: shot)
    _ = try await ports.execute(k, actionId: "act-2")
    #expect(platform.performed.last?.key == "a" && platform.performed.last?.modifiers == ["cmd"])
}

@Test func staleAndUnknownOutcomesAreReportedNotRetried() async throws {
    let (platform, s, ports, d) = try guiScene()
    let r1 = try await guiRun(s, ports, d)
    let bundle = try await ports.observe(runId: r1, expectedGeneration: 1)
    let stamp = bundle.observation.stamp
    let shot = bundle.observation.screenshots[0].screenshotId

    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    let unknown = try await ports.execute(proposal(.action(.type(text: "秘密")), run: r1, stamp: stamp, shot: shot), actionId: "act-u")
    #expect(unknown.deliveryState == .unknown)
    #expect(unknown.executionTarget?.processId == 101)
    #expect(unknown.reasonCode == "ACTION_OUTCOME_UNKNOWN")

    // Outside the window: refused before any input.
    let outside = try await ports.execute(proposal(.action(.click(sourcePixel: Point(x: 900, y: 5))), run: r1, stamp: stamp, shot: shot), actionId: "act-o")
    #expect(outside.deliveryState == .rejected && outside.reasonCode == "COORDINATE_OUT_OF_BOUNDS")

    // Rebinding makes the proposal's snapshot stale.
    let c = handshaken(s)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let stale = try await ports.execute(proposal(.action(.click(sourcePixel: Point(x: 300, y: 300))), run: r1, stamp: stamp, shot: shot), actionId: "act-s")
    #expect(stale.deliveryState == .rejected && stale.reasonCode == "STALE_OBSERVATION")
    #expect(platform.performed.isEmpty)

    // Another session's stamp is refused outright.
    let foreign = ObservationStamp(sessionId: "s_other", desktopId: d, snapshotId: stamp.snapshotId, bindingEpoch: 1, runGeneration: 1)
    let forbidden = try await ports.execute(proposal(.action(.click(sourcePixel: Point(x: 300, y: 300))), run: r1, stamp: foreign, shot: shot), actionId: "act-f")
    #expect(forbidden.deliveryState == .rejected && forbidden.reasonCode == "FORBIDDEN")
}
