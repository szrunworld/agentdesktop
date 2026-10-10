@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Owner display attach (docs/security/owner-display-attach.md, Kevin's
// ruling of 2026-10-10): only the owner opens one of the user's displays to
// a paired client, the user confirms it with Touch ID, the client gets the
// physical Desktop in its grant and still no window of it.

private func displayService(_ platform: FakePlatform = FakePlatform(), confirmer: TrustedConfirmer? = FakeConfirmer()) -> RuntimeService {
    let s = platformService(platform)
    s.confirmer = confirmer
    return s
}

private func attach(_ s: RuntimeService, _ c: ConnectionState, display: Int = 1, client: String, name: String? = nil) -> RuntimeResponse {
    let n = name.map { #","name":"\#($0)""# } ?? ""
    return call(s, c, "hub.displays.attach", params: #"{"displayId":\#(display),"clientId":"\#(client)"\#(n)}"#)
}

@Test func theOwnerListsDisplaysWithTheirProvedOrigin() throws {
    let s = displayService()
    let owner = handshaken(s)
    let list = try #require(data(call(s, owner, "hub.displays.list")))
    #expect(contract.validate(list, "HubDisplayList").isEmpty, "\(list.encoded())")
    let displays = list["displays"]?.arrayValue ?? []
    #expect(displays.count == 2)
    let builtin = try #require(displays.first { $0["displayId"]?.intValue == 1 })
    #expect(builtin["origin"]?.stringValue == "physical" && builtin["attachable"]?.boolValue == true && builtin["builtin"]?.boolValue == true)
    let virtual = try #require(displays.first { $0["displayId"]?.intValue == 9 })
    #expect(virtual["origin"]?.stringValue == "virtual" && virtual["attachable"]?.boolValue == false)
    #expect(virtual["originDetail"]?.stringValue?.contains("virtual display") == true)
    // Not a paired client's to see, whatever its grant; not an unpaired one's.
    let (c, _) = try pairedConnection(s, capabilities: ["observe", "act", "desktop.manage", "run", "unit.run"], desktops: ["created"])
    let r = call(s, c, "hub.displays.list")
    #expect(code(r) == "permission_denied" && errorDetails(r)?["reason"]?.stringValue == "owner_only", "\(r.json.encoded())")
    let unpaired = ConnectionState(socketPeer: getuid(), pid: nil, executable: nil)
    _ = s.respond(to: Data(handshakeLine.utf8), on: unpaired)
    #expect(code(call(s, unpaired, "hub.displays.list")) == "pairing_required")
}

@Test func attachingAsksTheUserAndOpensTheDisplayToTheClientWithoutAnyWindow() throws {
    let platform = FakePlatform()
    let window = FakeConfirmer()
    let s = displayService(platform, confirmer: window)
    let owner = handshaken(s)
    let (c, id, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"],
                                      apps: ["com.apple.calculator"], name: "wx-agent")
    let before = try #require(s.hub.grant(id))
    let r = try #require(data(attach(s, owner, client: id, name: "主显示器")), "attach")
    #expect(contract.validate(r, "HubDisplayAttachment").isEmpty, "\(r.encoded())")
    let d = try #require(r["desktop"]?["desktopId"]?.stringValue)
    #expect(r["created"]?.boolValue == true)
    #expect(r["desktop"]?["kind"]?.stringValue == "physical" && r["desktop"]?["name"]?.stringValue == "主显示器")
    #expect(platform.calls == ["attach 1"], "nothing is created: \(platform.calls)")
    // The user was asked, as the owner, about this client and this display.
    let asked = try #require(window.requests.last)
    #expect(asked.kind == .displayAttach && asked.action == "hub.displays.attach")
    #expect(asked.details["client"]?["clientId"]?.stringValue == id && asked.details["display"]?["displayId"]?.intValue == 1)
    #expect(asked.details["desktop"]?["desktopId"] == .null, "a new Desktop: none shown yet")
    #expect(asked.requester["clientId"]?.stringValue == owner.clientId)
    // The grant names the Desktop at the next revision; nothing was taken away, so the connection stays.
    let after = try #require(s.hub.grant(id))
    #expect(after.desktops.contains(d) && after.revision == before.revision + 1 && r["grant"]?["revision"]?.intValue == after.revision)
    #expect(c.cutReason == nil)
    #expect(s.hub.auditEvents().contains { $0["method"]?.stringValue == "hub.displays.attach" && $0["decision"]?.stringValue == "granted" })
    // The client reaches the Desktop, and no window of it until the user grants one.
    #expect(data(call(s, c, "desktop.show", params: #"{"desktopId":"\#(d)"}"#))?["kind"]?.stringValue == "physical")
    #expect(data(call(s, c, "window.list"))?["windows"]?.arrayValue?.isEmpty == true)
    platform.onScreen[11] = "physical-1"
    let bind = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)
    #expect(code(bind) == "grant_missing" && errorDetails(bind)?["reason"]?.stringValue == "bind_requires_grant", "\(bind.json.encoded())")
    try grantWindow(s, clientId: id, desktopId: d, permissions: ["observe"])
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#))?["binding"]?["windowId"]?.intValue == 11)
    // The list now shows the display as attached, to that Desktop.
    let shown = try #require(data(call(s, owner, "hub.displays.list"))?["displays"]?.arrayValue?.first { $0["displayId"]?.intValue == 1 })
    #expect(shown["attachable"]?.boolValue == false && shown["desktopId"]?.stringValue == d)
}

@Test func aDisplayAlreadyAttachedIsSharedNotAttachedTwice() throws {
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (_, a, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "a")
    let (_, b, _) = try pairedClient(s, capabilities: ["observe"], desktops: [], name: "b")
    let first = try #require(data(attach(s, owner, client: a)))
    let second = try #require(data(attach(s, owner, client: b, name: "ignored")))
    #expect(second["created"]?.boolValue == false)
    #expect(second["desktop"]?["desktopId"] == first["desktop"]?["desktopId"])
    #expect(platform.calls.filter { $0.hasPrefix("attach") }.count == 1)
    #expect(s.hub.grant(b)?.desktops == [first["desktop"]!["desktopId"]!.stringValue!])
    // Named by the display when no name is given.
    #expect(first["desktop"]?["name"]?.stringValue == "Built-in Retina Display")
}

@Test func aRefusalOrNoTrustedWindowAttachesNothing() throws {
    for (confirmer, reason) in [(FakeConfirmer { _ in .denied }, "user_denied"), (FakeConfirmer { _ in .timedOut }, "confirmation_timeout"),
                                (nil, "no_trusted_ui")] as [(FakeConfirmer?, String)] {
        let platform = FakePlatform()
        let s = displayService(platform, confirmer: confirmer)
        let owner = handshaken(s)
        let (_, id, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"])
        let revision = s.hub.grant(id)?.revision
        let r = attach(s, owner, client: id)
        #expect(code(r) == "permission_denied" && errorDetails(r)?["reason"]?.stringValue == reason, "\(r.json.encoded())")
        #expect(failure(r)?.notSent == true)
        #expect(platform.calls.isEmpty && s.desktops.count == 0)
        #expect(s.hub.grant(id)?.revision == revision && s.hub.grant(id)?.desktops == ["created"])
    }
}

@Test func onlyAProvedPhysicalDisplayOfAnActiveClientIsAttached() throws {
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (_, id, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"])
    // A virtual display, however it is named, and one that does not exist.
    let virtual = attach(s, owner, display: 9, client: id)
    #expect(code(virtual) == "permission_denied" && errorDetails(virtual)?["reason"]?.stringValue == "display_not_physical")
    #expect(code(attach(s, owner, display: 42, client: id)) == "not_found")
    // A client that is not active, or whose grant expired, gets no Desktop.
    #expect(code(attach(s, owner, client: "app:nobody")) == "not_found")
    _ = try s.hub.revoke(id)
    #expect(code(attach(s, owner, client: id)) == "not_found")
    let (_, late, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "late")
    var g = try #require(s.hub.grant(late))
    g.expiresAt = Timestamp.string(Date().addingTimeInterval(-1))
    _ = try s.hub.setGrant(g)
    let expired = attach(s, owner, client: late)
    #expect(code(expired) == "conflict" && errorDetails(expired)?["reason"]?.stringValue == "grant_expired")
    #expect(platform.calls.isEmpty, "\(platform.calls)")
}

@Test func aPairedAppWithDesktopManageCannotDestroyThePhysicalDesktopItWasOpened() throws {
    // Codex on a6a9088: desktop.manage covers desktop.destroy; a shared
    // physical Desktop is the owner's to take back, not one app's to drop.
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (a, aId, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"],
                                       apps: ["com.apple.calculator"], name: "a")
    let (_, bId, _) = try pairedClient(s, capabilities: ["observe"], desktops: [], name: "b")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    _ = try #require(data(attach(s, owner, client: bId)))
    let r = call(s, a, "desktop.destroy", params: #"{"desktopId":"\#(d)"}"#)
    #expect(code(r) == "permission_denied" && errorDetails(r)?["reason"]?.stringValue == "owner_only", "\(r.json.encoded())")
    #expect(failure(r)?.notSent == true)
    #expect(s.desktops.find(d) != nil && s.hub.grant(bId)?.desktops == [d])
    // Its own virtual Desktop it still destroys.
    let v = try created(s, a)
    #expect(data(call(s, a, "desktop.destroy", params: #"{"desktopId":"\#(v)"}"#))?["destroyed"]?.boolValue == true)
    // The owner's desktop.destroy of a physical Desktop goes through detach's cleanup: no grant keeps the id.
    _ = try #require(data(call(s, owner, "desktop.destroy", params: #"{"desktopId":"\#(d)"}"#)))
    #expect(s.hub.grant(aId)?.desktops == ["created"] && s.hub.grant(bId)?.desktops == [])
}

@Test func aPairedAppIsRefusedBeforeAnythingOfThePhysicalDesktopsStateIsTold() throws {
    // Codex on b0e2df9: the owner_only refusal comes before the holder and
    // session checks, so an app learns nothing of others' sessions or Runs.
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (a, aId, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"], name: "a")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    _ = try #require(data(call(s, owner, "session.open", params: #"{"desktopId":"\#(d)"}"#)))
    let r = call(s, a, "desktop.destroy", params: #"{"desktopId":"\#(d)"}"#)
    #expect(code(r) == "permission_denied" && errorDetails(r)?["reason"]?.stringValue == "owner_only", "\(r.json.encoded())")
    #expect(errorDetails(r)?["openSessions"] == nil && errorDetails(r)?["holderRunId"] == nil)
    let message = failure(r)?.message ?? ""
    #expect(message.contains("session") == false)
}

@Test func aGrantStoreThatCannotRecordTheLossKeepsThePhysicalDesktop() throws {
    // Codex on b0e2df9: destroyed is never reported while a grant still names the Desktop.
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (_, aId, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "a")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    s.hub.failsGrantWrites = true
    let r = call(s, owner, "desktop.destroy", params: #"{"desktopId":"\#(d)"}"#)
    #expect(code(r) == "audit_unavailable", "\(r.json.encoded())")
    #expect(s.desktops.find(d) != nil && s.hub.grant(aId)?.desktops.contains(d) == true)
    let r2 = call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)"}"#)
    #expect(code(r2) == "audit_unavailable")
    #expect(s.desktops.find(d) != nil)
    s.hub.failsGrantWrites = false
    #expect(data(call(s, owner, "desktop.destroy", params: #"{"desktopId":"\#(d)"}"#))?["destroyed"]?.boolValue == true)
    #expect(s.hub.grant(aId)?.desktops == ["created"])
}

@Test func detachingFromSeveralClientsIsAllOrNothing() throws {
    // Codex on fdb5477: a grant write that fails for the second client
    // leaves the first one's grant, window grants and connection as they were.
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (a, aId, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"],
                                       apps: ["com.apple.calculator"], name: "a")
    let (b, bId, _) = try pairedClient(s, capabilities: ["observe"], desktops: [], name: "b")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    _ = try #require(data(attach(s, owner, client: bId)))
    let wg = try grantWindow(s, clientId: aId, desktopId: d)
    s.hub.grantWritesBeforeFailure = 1
    let r = call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)"}"#)
    #expect(code(r) == "audit_unavailable", "\(r.json.encoded())")
    #expect(s.hub.grant(aId)?.desktops.contains(d) == true && s.hub.grant(bId)?.desktops == [d])
    #expect(s.hub.windowGrant(wg.windowGrantId)?.state == "active")
    #expect(a.cutReason == nil && b.cutReason == nil && s.desktops.find(d) != nil)
    // The same for the owner's destroy.
    s.hub.grantWritesBeforeFailure = 1
    #expect(code(call(s, owner, "desktop.destroy", params: #"{"desktopId":"\#(d)"}"#)) == "audit_unavailable")
    #expect(s.hub.grant(aId)?.desktops.contains(d) == true && s.hub.windowGrant(wg.windowGrantId)?.state == "active")
    s.hub.grantWritesBeforeFailure = nil
    #expect(data(call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)"}"#))?["grants"]?.arrayValue?.count == 2)
}

@Test func anAttachedDisplayKeepsItsDesktopsNameWhateverIsAsked() throws {
    // Codex on fdb5477: the confirmation shows the name that applies.
    let window = FakeConfirmer()
    let s = displayService(FakePlatform(), confirmer: window)
    let owner = handshaken(s)
    let (_, aId, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "a")
    let (_, bId, _) = try pairedClient(s, capabilities: ["observe"], desktops: [], name: "b")
    _ = try #require(data(attach(s, owner, client: aId, name: "第一次的名字")))
    let r = try #require(data(attach(s, owner, client: bId, name: "另一个名字")))
    #expect(r["desktop"]?["name"]?.stringValue == "第一次的名字" && r["created"]?.boolValue == false)
    #expect(window.requests.last?.details["desktop"]?["name"]?.stringValue == "第一次的名字")
    #expect(window.requests.last?.details["desktop"]?["desktopId"]?.stringValue == r["desktop"]?["desktopId"]?.stringValue)
}

@Test func aDesktopReplacedWhileTheUserDecidedIsNotTheOneGranted() throws {
    // Codex on bb8a1f8: detached and attached again during the prompt, the
    // Desktop is another record than the one shown.
    let platform = FakePlatform()
    let s = displayService(platform, confirmer: nil)
    let owner = handshaken(s)
    let (_, aId, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "a")
    let (_, bId, _) = try pairedClient(s, capabilities: ["observe"], desktops: [], name: "b")
    s.confirmer = FakeConfirmer()
    let first = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    s.confirmer = FakeConfirmer { r in
        _ = call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(first)"}"#)
        _ = call(s, owner, "hub.displays.attach", params: #"{"displayId":1,"clientId":"\#(aId)"}"#)   // no confirmer: refused, nothing attached
        return .approved(digest: r.digest)
    }
    let r = attach(s, owner, client: bId)
    #expect(code(r) == "conflict" && errorDetails(r)?["reason"]?.stringValue == "target_changed", "\(r.json.encoded())")
    #expect(s.hub.grant(bId)?.desktops == [])
    // The same when a Desktop appears on the display where none was shown
    // (another owner path attached it while the prompt was up).
    s.confirmer = FakeConfirmer { r in
        let screen = try! platform.attachDisplay(1)
        s.desktops.add(desktopId: "d_meanwhile", name: "meanwhile", screen: screen, createdAt: Timestamp.string(Date()), kind: .physical,
                       createdBy: owner.clientId)
        return .approved(digest: r.digest)
    }
    let r2 = attach(s, owner, client: bId)
    #expect(code(r2) == "conflict" && errorDetails(r2)?["reason"]?.stringValue == "target_changed", "\(r2.json.encoded())")
    #expect(s.hub.grant(bId)?.desktops == [] && s.desktops.count == 1)
}

@Test func aStoreThatCannotWriteTheGrantIsNotReportedAsAChangedTarget() throws {
    // Codex on bb8a1f8: an outage is audit_unavailable, not a reason to ask again.
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (_, aId, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "a")
    s.hub.failsGrantWrites = true
    let r = attach(s, owner, client: aId)
    #expect(code(r) == "audit_unavailable", "\(r.json.encoded())")
    #expect(s.desktops.count == 0, "a Desktop made for the attach is dropped again")
}

@Test func detachingFromEveryoneFailsWholeWhenTheDesktopIsBusy() throws {
    // Codex on bb8a1f8: a Desktop held past the lock wait is told
    // deadline_exceeded with nothing taken from any grant.
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (a, aId, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"], name: "a")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    let record = try #require(s.desktops.find(d))
    s.desktopLockWait = 0.2
    record.lock.lock()
    defer { record.lock.unlock() }
    let r = call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)"}"#)
    #expect(code(r) == "deadline_exceeded", "\(r.json.encoded())")
    #expect(s.hub.grant(aId)?.desktops.contains(d) == true && a.cutReason == nil && s.desktops.find(d) != nil)
}

@Test func aGrantThatExpiredWhileTheUserDecidedGetsNoDesktop() throws {
    let platform = FakePlatform()
    let s = displayService(platform, confirmer: nil)
    let owner = handshaken(s)
    let (_, id, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"])
    s.confirmer = FakeConfirmer { r in
        // Expired during the prompt, revision unchanged (Codex on a6a9088).
        var g = s.hub.grant(id)!
        g.expiresAt = Timestamp.string(Date().addingTimeInterval(-1))
        try! s.hub.putGrant(g)
        return .approved(digest: r.digest)
    }
    let r = attach(s, owner, client: id)
    #expect(code(r) == "conflict" && errorDetails(r)?["reason"]?.stringValue == "grant_expired", "\(r.json.encoded())")
    #expect(platform.calls.isEmpty && s.desktops.count == 0)
}

@Test func aClientThatChangedWhileTheUserDecidedGetsNothing() throws {
    let platform = FakePlatform()
    let s = displayService(platform, confirmer: nil)
    let owner = handshaken(s)
    let (_, id, _) = try pairedClient(s, capabilities: ["observe", "act"], desktops: ["created"])
    // The owner narrows the grant in the window while the prompt is up.
    s.confirmer = FakeConfirmer { r in
        var g = s.hub.grant(id)!
        g.capabilities = ["observe"]
        _ = try? s.hub.setGrant(g)
        return .approved(digest: r.digest)
    }
    let r = attach(s, owner, client: id)
    #expect(code(r) == "conflict" && errorDetails(r)?["reason"]?.stringValue == "target_changed", "\(r.json.encoded())")
    #expect(platform.calls.isEmpty && s.desktops.count == 0)
    #expect(s.hub.grant(id)?.desktops == ["created"])
}

@Test func detachingFromOneClientEndsItsWindowGrantsThereAndCutsIt() throws {
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (a, aId, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"],
                                       apps: ["com.apple.calculator"], name: "a")
    let (b, bId, _) = try pairedClient(s, capabilities: ["observe", "act"], desktops: [], name: "b")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    _ = try #require(data(attach(s, owner, client: bId)))
    let wg = try grantWindow(s, clientId: aId, desktopId: d, permissions: ["observe", "act"])
    let elsewhere = try created(s, a)
    let other = try grantWindow(s, clientId: aId, desktopId: elsewhere)
    _ = try #require(data(call(s, a, "session.open", params: #"{"desktopId":"\#(d)"}"#)))
    _ = try #require(data(call(s, b, "session.open", params: #"{"desktopId":"\#(d)"}"#)))
    let r = try #require(data(call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)","clientId":"\#(aId)"}"#)))
    #expect(contract.validate(r, "HubDisplayDetachment").isEmpty, "\(r.encoded())")
    #expect(r["destroyed"]?.boolValue == false)
    #expect(r["grants"]?.arrayValue?.count == 1 && r["grants"]?.arrayValue?.first?["desktops"]?.arrayValue == [.string("created")])
    // Its window grant on that Desktop ended in the same change; the other one stands.
    #expect(s.hub.windowGrant(wg.windowGrantId)?.state == "ended" && s.hub.windowGrant(wg.windowGrantId)?.endedReason == "desktop_removed")
    #expect(s.hub.windowGrant(other.windowGrantId)?.state == "active")
    // Narrowed: its connection is cut, its session there closed; b keeps everything.
    #expect(a.cutReason == "grant_narrowed" && b.cutReason == nil)
    #expect(s.sessions.openCount(desktopId: d) == 1)
    #expect(s.desktops.find(d) != nil)
    #expect(s.hub.grant(bId)?.desktops == [d])
    #expect(data(call(s, b, "desktop.show", params: #"{"desktopId":"\#(d)"}"#))?["kind"]?.stringValue == "physical")
    // Apps that never held it are not touched: naming one is not found.
    #expect(code(call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)","clientId":"app:nobody"}"#)) == "not_found")
}

@Test func detachingFromEveryoneDropsTheRecordAndTouchesNoDisplay() throws {
    let platform = FakePlatform()
    let s = displayService(platform)
    let owner = handshaken(s)
    let (_, aId, _) = try pairedClient(s, capabilities: ["observe", "act"], desktops: ["created"], apps: ["com.apple.calculator"], name: "a")
    let (_, bId, _) = try pairedClient(s, capabilities: ["observe"], desktops: [], name: "b")
    let d = try #require(data(attach(s, owner, client: aId))?["desktop"]?["desktopId"]?.stringValue)
    _ = try #require(data(attach(s, owner, client: bId)))
    let wg = try grantWindow(s, clientId: aId, desktopId: d)
    _ = try #require(data(call(s, owner, "session.open", params: #"{"desktopId":"\#(d)"}"#)))
    let r = try #require(data(call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(d)"}"#)))
    #expect(r["destroyed"]?.boolValue == true && r["grants"]?.arrayValue?.count == 2)
    #expect(s.desktops.find(d) == nil)
    #expect(code(call(s, owner, "desktop.show", params: #"{"desktopId":"\#(d)"}"#)) == "not_found")
    #expect(!platform.calls.contains { $0.hasPrefix("destroy") || $0.hasPrefix("quit") }, "the display and its windows are the user's: \(platform.calls)")
    #expect(s.hub.grant(aId)?.desktops == ["created"] && s.hub.grant(bId)?.desktops == [])
    #expect(s.hub.windowGrant(wg.windowGrantId)?.state == "ended")
    #expect(s.sessions.openCount(desktopId: d) == 0)
    // The display can be attached again, as a new Desktop.
    let again = try #require(data(attach(s, owner, client: aId)))
    #expect(again["created"]?.boolValue == true && again["desktop"]?["desktopId"]?.stringValue != d)
    // A virtual Desktop is not detached this way.
    let v = try created(s, owner)
    #expect(code(call(s, owner, "hub.displays.detach", params: #"{"desktopId":"\#(v)"}"#)) == "invalid_argument")
}

@Test func pairedClientsNeverAttachOrDetachAndAreNotAskedFor() throws {
    let window = FakeConfirmer()
    let s = displayService(FakePlatform(), confirmer: window)
    let (c, id, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage", "run", "unit.run"], desktops: ["created"])
    for (method, params) in [("hub.displays.attach", #"{"displayId":1,"clientId":"\#(id)"}"#),
                             ("hub.displays.detach", #"{"desktopId":"d_x"}"#), ("desktop.create", #"{"physical":{}}"#)] {
        let r = call(s, c, method, params: params)
        #expect(code(r) == "permission_denied" && errorDetails(r)?["reason"]?.stringValue == "owner_only", "\(method): \(r.json.encoded())")
        #expect(failure(r)?.notSent == true)
    }
    #expect(window.requests.isEmpty, "a paired client cannot even ask the user for a display")
    #expect(s.desktops.count == 0)
}

@Test func aDisplayChangedWhileTheUserDecidedIsNotGranted() throws {
    for reuse in [false, true] {
        let platform = FakePlatform()
        let s = displayService(platform, confirmer: FakeConfirmer())
        let owner = handshaken(s)
        let (_, id, _) = try pairedClient(s, capabilities: ["observe"], desktops: ["created"])
        if reuse { _ = attach(s, owner, client: id) }
        let before = s.hub.grant(id)!
        let count = s.desktops.count
        s.confirmer = FakeConfirmer { request in
            var report = platform.displays()
            report[0].frame.width += 100
            platform.displayReport = report
            return .approved(digest: request.digest)
        }
        let response = attach(s, owner, client: id)
        #expect(code(response) == "conflict" && errorDetails(response)?["reason"]?.stringValue == "display_changed")
        #expect(s.hub.grant(id)?.revision == before.revision && s.desktops.count == count)
    }
}
