import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

private final class RecoveryStage {
    let platform = FakePlatform()
    let backend = FixedBackend()
    let service: RuntimeService
    let owner: ConnectionState
    let confirmer = FakeConfirmer()
    let desktop: String
    let client: ConnectionState
    init() throws {
        platform.onScreen[11] = "physical-1"
        service = platformService(platform, backend: backend)
        service.physicalDesktopsEnabled = true
        service.confirmer = confirmer
        owner = handshaken(service)
        desktop = try #require(data(call(service, owner, "desktop.create", params: #"{"name":"main","physical":{}}"#))?["desktopId"]?.stringValue)
        (client, _, _) = try pairedClient(service, capabilities: ["observe", "act", "desktop.manage", "run"], desktops: [desktop], apps: ["com.apple.calculator"])
        #expect(data(request("hub.windows.request")) != nil)
        #expect(data(call(service, client, "window.bind", params: #"{"desktopId":"\#(desktop)","pid":101,"windowId":11}"#)) != nil)
    }
    func request(_ method: String = "desktop.recoverBinding") -> RuntimeResponse {
        call(service, client, method, params: #"{"desktopId":"\#(desktop)","bundleId":"com.apple.calculator","permissions":["observe","act"]}"#)
    }
    func replace(_ ids: [UInt32] = [15]) {
        backend.opened.closed.insert(11)
        backend.opened.windows = ids.map { WindowSummary(windowId: $0, process: backend.processIdentity(101), appName: "Calculator", bundleId: "com.apple.calculator", title: "replacement", frame: Rect(x: 10, y: 20, width: 230, height: 400), onScreen: true) }
        platform.windows[101] = ids.map { PlatformWindow(windowId: $0, pid: 101, appName: "Calculator", title: "replacement", frame: Rect(x: 10, y: 20, width: 230, height: 400)) }
        for id in ids { platform.onScreen[id] = "physical-1" }
    }
}

@Test func bindingRecoveryConfirmsNewGrantAndAdvancesGeneration() throws {
    let st = try RecoveryStage()
    let old = try #require(st.service.desktops.find(st.desktop)?.binding)
    st.replace()
    let response = st.request()
    let result = try #require(data(response), "\(response.json.encoded())")
    #expect(contract.validate(result, "RecoveredBinding").isEmpty)
    #expect(result["binding"]?["windowId"]?.intValue == 15)
    #expect(result["binding"]?["generation"]?.intValue == old.generation + 1)
    #expect(result["binding"]?["windowGrantId"]?.stringValue != old.windowGrantId)
    #expect(st.confirmer.requests.last?.details["bindingRecovery"]?["fromWindowId"]?.intValue == 11)
    let status = call(st.service, st.client, "desktop.bindingStatus", params: #"{"desktopId":"\#(st.desktop)"}"#)
    #expect(data(status)?["state"]?.stringValue == "valid")
}

@Test func bindingRecoveryRefusesAmbiguousOrStillOpenWindow() throws {
    let st = try RecoveryStage()
    let count = st.confirmer.requests.count
    #expect(data(st.request()) == nil)
    st.replace([15, 16])
    #expect(errorDetails(st.request())?["reason"]?.stringValue == "recovery_ambiguous")
    #expect(st.confirmer.requests.count == count)
    #expect(st.service.desktops.find(st.desktop)?.binding?.windowId == 11)
}

@Test func bindingRecoveryRefusesProcessRestartAndPendingTargetChange() throws {
    let st = try RecoveryStage()
    st.replace()
    st.backend.opened.restarted.insert(101)
    #expect(data(st.request()) == nil)
    st.backend.opened.restarted.remove(101)
    st.confirmer.decide = { request in
        st.backend.opened.closed.remove(11)
        return .approved(digest: request.digest)
    }
    #expect(errorDetails(st.request())?["reason"]?.stringValue == "recovery_target_changed")
    #expect(st.service.desktops.find(st.desktop)?.binding?.windowId == 11)
}

@Test func bindingStatusDoesNotDiscloseClosedWindowToFormerGrantee() throws {
    let st = try RecoveryStage()
    st.replace()
    let params = #"{"desktopId":"\#(st.desktop)"}"#
    let status = try #require(data(call(st.service, st.client, "desktop.bindingStatus", params: params)))
    #expect(status["state"]?.stringValue == "needs_authorization")
    #expect(status["binding"] == nil)
    #expect(data(call(st.service, st.owner, "desktop.bindingStatus", params: params))?["state"]?.stringValue == "invalid")
}

@Test func bindingRecoveryDenialPreservesBindingAndGrantCount() throws {
    let st = try RecoveryStage()
    st.replace()
    let count = st.service.hub.windowGrants(clientId: st.client.clientId, includeEnded: true).count
    st.confirmer.decide = { _ in .denied }
    #expect(errorDetails(st.request())?["reason"]?.stringValue == "user_denied")
    #expect(st.service.desktops.find(st.desktop)?.binding?.windowId == 11)
    #expect(st.service.hub.windowGrants(clientId: st.client.clientId, includeEnded: true).count == count)
}

@Test func bindingRecoveryRequiresQuiescenceBeforeAsking() throws {
    let st = try RecoveryStage()
    let sid = try #require(data(call(st.service, st.client, "session.open", params: #"{"desktopId":"\#(st.desktop)"}"#))?["sessionId"]?.stringValue)
    #expect(data(call(st.service, st.client, "run.start", context: #"{"sessionId":"\#(sid)"}"#)) != nil)
    st.replace()
    let count = st.confirmer.requests.count
    #expect(errorDetails(st.request())?["reason"]?.stringValue == "control_busy")
    #expect(st.confirmer.requests.count == count)
}

/// #261: a second eligible window that appears while the user decides makes
/// the recovery ambiguous again; nothing is granted or rebound.
@Test func bindingRecoveryRechecksTheReplacementIsUniqueAfterApproval() throws {
    let st = try RecoveryStage()
    st.replace([15])
    let backend = st.backend, platform = st.platform
    st.confirmer.decide = { request in
        // Window 16 of the same process opens while the dialog is up.
        let process = backend.processIdentity(101)
        backend.opened.windows += [WindowSummary(windowId: 16, process: process, appName: "Calculator", bundleId: "com.apple.calculator",
                                                 title: "second", frame: Rect(x: 300, y: 20, width: 230, height: 400), onScreen: true)]
        platform.windows[101, default: []] += [PlatformWindow(windowId: 16, pid: 101, appName: "Calculator", title: "second",
                                                              frame: Rect(x: 300, y: 20, width: 230, height: 400))]
        platform.onScreen[16] = "physical-1"
        return .approved(digest: request.digest)
    }
    let grantsBefore = st.service.hub.windowGrants(clientId: nil).count
    let r = st.request()
    #expect(errorDetails(r)?["reason"]?.stringValue == "recovery_ambiguous", "\(r.json.encoded())")
    #expect(st.service.desktops.find(st.desktop)?.binding?.windowId == 11)
    #expect(st.service.hub.windowGrants(clientId: nil).count == grantsBefore)
}

/// #261: recovery ends the closed window's grant at once (sticky reason,
/// audit, transients), not at the next check.
@Test func bindingRecoveryEndsTheClosedWindowsGrant() throws {
    let st = try RecoveryStage()
    let oldGrantId = try #require(st.service.desktops.find(st.desktop)?.binding?.windowGrantId)
    // A transient screenshot kept only under the old grant (69 on 61d2dec).
    let artifacts = st.service.artifacts
    let artifactId = "art_recovery261"
    let file = artifacts.path(for: artifactId, ext: "png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: file))
    try artifacts.register(artifactId, mediaType: "image/png", clientId: st.client.clientId, runId: nil,
                           createdAt: Timestamp.string(Date()), transientUntil: Date().addingTimeInterval(600),
                           windowGrantId: oldGrantId)
    #expect(FileManager.default.fileExists(atPath: file))
    st.replace()
    #expect(data(st.request()) != nil)
    let old = try #require(st.service.hub.windowGrant(oldGrantId))
    #expect(old.state == "ended" && old.endedReason == "window_closed", "\(old.state) \(old.endedReason ?? "-")")
    // Its transient went with it, and the ending was audited.
    #expect(!FileManager.default.fileExists(atPath: file))
    #expect(artifacts.info(artifactId) == nil)
    #expect(st.service.hub.auditEvents().contains {
        $0["method"]?.stringValue == "hub.windows" && $0["decision"]?.stringValue == "ended"
            && $0["reason"]?.stringValue == "\(oldGrantId) window_closed"
    })
}

/// Codex on 80867e8: naming the replacement window does not hide a second
/// eligible one, neither before asking nor after the user approved.
@Test func bindingRecoveryNamingAWindowDoesNotHideASecondOne() throws {
    let st = try RecoveryStage()
    func named(_ id: Int) -> RuntimeResponse {
        call(st.service, st.client, "desktop.recoverBinding",
             params: #"{"desktopId":"\#(st.desktop)","bundleId":"com.apple.calculator","permissions":["observe","act"],"windowId":\#(id)}"#)
    }
    // Two eligible replacements, one named: refused before asking.
    st.replace([15, 16])
    let asked = st.confirmer.requests.count
    #expect(errorDetails(named(15))?["reason"]?.stringValue == "recovery_ambiguous")
    #expect(st.confirmer.requests.count == asked)
    // One replacement when asked, a second appears while the user decides.
    st.replace([15])
    let backend = st.backend, platform = st.platform
    st.confirmer.decide = { request in
        backend.opened.windows += [WindowSummary(windowId: 16, process: backend.processIdentity(101), appName: "Calculator",
                                                 bundleId: "com.apple.calculator", title: "second",
                                                 frame: Rect(x: 300, y: 20, width: 230, height: 400), onScreen: true)]
        platform.windows[101, default: []] += [PlatformWindow(windowId: 16, pid: 101, appName: "Calculator", title: "second",
                                                              frame: Rect(x: 300, y: 20, width: 230, height: 400))]
        platform.onScreen[16] = "physical-1"
        return .approved(digest: request.digest)
    }
    #expect(errorDetails(named(15))?["reason"]?.stringValue == "recovery_ambiguous")
    #expect(st.service.desktops.find(st.desktop)?.binding?.windowId == 11)
}
