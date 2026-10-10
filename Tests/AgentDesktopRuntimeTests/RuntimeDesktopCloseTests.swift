import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A5: desktop.closePlan, app.quit and desktop.resize. RT-16 (docs/plan/08):
// closing ends only what the Desktop launched; the host's shared apps live.

/// The scene's Desktop shows Calculator (pid 101, the user's, bound) and
/// Notes (pid 303, launched there).
private func withLaunch(_ backend: FixedBackend = FixedBackend()) throws -> Scene {
    let sc = try scene(FakePlatform(), backend: backend)
    _ = try #require(data(call(sc.s, sc.c, "app.launch", params: #"{"desktopId":"\#(sc.desktop)","bundleId":"com.apple.Notes"}"#)))
    return sc
}

private func pids(_ v: JSONValue?) -> [Int] { v?.arrayValue?.compactMap { $0["process"]?["pid"]?.intValue } ?? [] }
private func reason(_ r: RuntimeResponse) -> String? { errorDetails(r)?["reason"]?.stringValue }

@Test func rt16_theClosePlanListsWhatEndsAndDestroyEndsOnlyThat() throws {
    let sc = try withLaunch()
    let other = try created(sc.s, sc.c)
    let plan = try #require(data(call(sc.s, sc.c, "desktop.closePlan", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(contract.validate(plan, "DesktopClosePlan").isEmpty, "\(plan.encoded())")
    #expect(plan["display"]?.stringValue == "destroyed")
    #expect(pids(plan["quit"]) == [303], "only the launch made here")
    #expect(pids(plan["keep"]) == [101], "the user's Calculator stays")
    #expect(plan["keep"]?.arrayValue?.first?["reason"]?.stringValue == "not_launched_here")
    #expect(plan["canClose"] == .bool(false))
    #expect(plan["blockers"]?.arrayValue?.first?["kind"]?.stringValue == "sessions")
    #expect(sc.platform.quit.isEmpty, "a plan changes nothing")

    _ = call(sc.s, sc.c, "session.close", params: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(data(call(sc.s, sc.c, "desktop.closePlan", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["canClose"] == .bool(true))
    let destroyed = try #require(data(call(sc.s, sc.c, "desktop.destroy", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(destroyed["quitApps"]?.arrayValue?.compactMap { $0["pid"]?.intValue } == [303])
    #expect(sc.platform.quit == [303], "the shared app was not quit")
    #expect(data(call(sc.s, sc.c, "desktop.show", params: #"{"desktopId":"\#(other)"}"#)) != nil, "the other Desktop stays")
}

@Test func aClosePlanNamesTheRunHoldingTheDesktop() throws {
    let sc = try scene()
    let run = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let plan = try #require(data(call(sc.s, sc.c, "desktop.closePlan", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    let blocker = plan["blockers"]?.arrayValue?.first { $0["kind"]?.stringValue == "run" }
    #expect(blocker?["runId"]?.stringValue == run && blocker?["origin"]?.stringValue == "agent_hub")
}

@Test func aPhysicalDesktopsClosePlanKeepsEverything() throws {
    let sc = try scene()
    let d = try #require(data(call(sc.s, sc.c, "desktop.create", params: #"{"physical":{"displayId":1}}"#))?["desktopId"]?.stringValue)
    let plan = try #require(data(call(sc.s, sc.c, "desktop.closePlan", params: #"{"desktopId":"\#(d)"}"#)))
    #expect(contract.validate(plan, "DesktopClosePlan").isEmpty)
    #expect(plan["kind"]?.stringValue == "physical" && plan["display"]?.stringValue == "kept")
    #expect(plan["quit"]?.arrayValue?.isEmpty == true)
}

@Test func appQuitEndsOnlyALaunchMadeHereAndWaitsForTheExit() throws {
    let backend = FixedBackend()
    let sc = try withLaunch(backend)
    // The user's own app, an unknown pid: the same refusal, nothing asked.
    for pid in [101, 999] {
        let r = call(sc.s, sc.c, "app.quit", params: #"{"desktopId":"\#(sc.desktop)","pid":\#(pid)}"#)
        #expect(code(r) == "permission_denied" && reason(r) == "not_launched_here", "\(pid)")
    }
    #expect(sc.platform.quit.isEmpty)

    // Asked, but still running after the wait: not reported as gone.
    sc.s.quitWait = 0.2
    let asked = try #require(data(call(sc.s, sc.c, "app.quit", params: #"{"desktopId":"\#(sc.desktop)","pid":303}"#)))
    #expect(contract.validate(asked, "AppQuitResult").isEmpty, "\(asked.encoded())")
    #expect(asked["quitRequested"] == .bool(true) && asked["exited"] == .bool(false))
    #expect(pids(data(call(sc.s, sc.c, "desktop.closePlan", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["quit"]) == [303])

    // It exits when asked: it leaves the Desktop's launches.
    sc.platform.onQuit = { pid in backend.opened.lock.withLock { _ = backend.opened.restarted.insert(pid) } }
    let gone = try #require(data(call(sc.s, sc.c, "app.quit", params: #"{"desktopId":"\#(sc.desktop)","pid":303}"#)))
    #expect(gone["exited"] == .bool(true))
    // Bound first: Swift 6.1's #expect cannot expand an optional chain followed by .isEmpty.
    let left = pids(data(call(sc.s, sc.c, "desktop.closePlan", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["quit"])
    #expect(left.isEmpty)
    #expect(sc.platform.quit == [303, 303])
}

@Test func aPairedAppQuitsOnlyItsOwnLaunchAndMayNotReadAClosePlan() throws {
    let sc = try withLaunch()
    let (app, _) = try pairedConnection(sc.s, capabilities: ["observe", "act", "run", "desktop.manage"], desktops: [sc.desktop])
    let r = call(sc.s, app, "app.quit", params: #"{"desktopId":"\#(sc.desktop)","pid":303}"#)
    #expect(code(r) == "permission_denied" && reason(r) == "not_launched_here", "the owner launched it")
    #expect(sc.platform.quit.isEmpty)
    let plan = call(sc.s, app, "desktop.closePlan", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    #expect(code(plan) == "permission_denied" && reason(plan) == "owner_only")
}

@Test func resizeChangesAVirtualDesktopAndForgetsItsObservations() throws {
    let sc = try scene()
    let resized = try #require(data(call(sc.s, sc.c, "desktop.resize", params: #"{"desktopId":"\#(sc.desktop)","width":1024,"height":768}"#)))
    #expect(contract.validate(resized, "Desktop").isEmpty, "\(resized.encoded())")
    #expect(resized["screen"]?["frame"]?["width"]?.doubleValue == 1024 && resized["screen"]?["frame"]?["height"]?.doubleValue == 768)
    #expect(data(call(sc.s, sc.c, "desktop.show", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["screen"]?["frame"]?["width"]?.doubleValue == 1024)
    let before = sc.platform.performed.count
    #expect(code(act(sc, clickContinue)) == "stale_observation", "the old snapshot is gone")
    #expect(sc.platform.performed.count == before)

    // Too large for the display: the platform's refusal, the size unchanged.
    #expect(code(call(sc.s, sc.c, "desktop.resize", params: #"{"desktopId":"\#(sc.desktop)","width":5000,"height":3000}"#)) == "execution_failed")
    #expect(data(call(sc.s, sc.c, "desktop.show", params: #"{"desktopId":"\#(sc.desktop)"}"#))?["screen"]?["frame"]?["width"]?.doubleValue == 1024)
    #expect(code(call(sc.s, sc.c, "desktop.resize", params: #"{"desktopId":"\#(sc.desktop)","width":100,"height":100}"#)) == "schema_invalid")

    let physical = try #require(data(call(sc.s, sc.c, "desktop.create", params: #"{"physical":{"displayId":1}}"#))?["desktopId"]?.stringValue)
    #expect(code(call(sc.s, sc.c, "desktop.resize", params: #"{"desktopId":"\#(physical)","width":1024,"height":768}"#)) == "invalid_target")
}

@Test func aPairedAppMayNotResizeOrQuitUnderAnotherClientsRun() throws {
    let sc = try scene()
    _ = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let (app, _) = try pairedConnection(sc.s, capabilities: ["observe", "act", "run", "desktop.manage"], desktops: [sc.desktop])
    let r = call(sc.s, app, "desktop.resize", params: #"{"desktopId":"\#(sc.desktop)","width":1024,"height":768}"#)
    #expect(code(r) == "control_busy")
    #expect(!sc.platform.calls.contains { $0.hasPrefix("resize") })
}
