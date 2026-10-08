import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A4: who is calling. Pairing with the owner's approval, credentials checked
// by the Runtime (never a self-reported clientId), per-client grants with
// default deny, expiry, revocation that also stops new actions in live Runs,
// and an audit of the real caller.

/// A socket connection that has said hello, with or without a credential.
func socketConnection(_ s: RuntimeService, clientId: String? = nil, token: String? = nil) -> (ConnectionState, RuntimeResponse) {
    let c = ConnectionState(socketPeer: getuid(), pid: nil, executable: nil)
    let cred = clientId.map { #","credential":{"clientId":"\#($0)","token":"\#(token ?? "")"}"# } ?? ""
    let hello = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"hs","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}\#(cred)}}"#
    return (c, answer(s, hello, c))
}

/// A paired app with its own Desktop, a bound Calculator window, a session
/// and a snapshot: everything it needs to act.
func pairedScene(_ s: RuntimeService, _ platform: FakePlatform, name: String = "app") throws -> (Scene, String, String) {
    let (c, id, token) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage", "run"], desktops: ["created"],
                                       apps: ["com.apple.calculator"], name: name)
    let d = try created(s, c)
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)) != nil)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let snap = try #require(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#))?["snapshotId"]?.stringValue)
    return (Scene(platform: platform, s: s, c: c, desktop: d, session: sid, snapshot: snap), id, token)
}

func errorDetails(_ r: RuntimeResponse) -> JSONValue? {
    if case let .failure(e) = r.result { return e.details }
    return nil
}

@Test func anAppPairsWithTheOwnersApprovalAndGetsItsCredentialOnce() throws {
    let s = platformService()
    let owner = handshaken(s)
    let (app, hello) = socketConnection(s)
    #expect(data(hello)?["principal"]?["role"]?.stringValue == "unpaired")
    // Unpaired: nothing but pairing.
    #expect(code(call(s, app, "desktop.list")) == "pairing_required")
    #expect(code(call(s, app, "runtime.status")) == "pairing_required")
    let started = try #require(data(call(s, app, "hub.pairing.start", params: #"{"agentName":"BOSS Agent","requested":{"capabilities":["observe","act"],"desktops":["created"],"apps":[]}}"#)))
    let pairingId = try #require(started["pairingId"]?.stringValue)
    #expect(started["shortCode"]?.stringValue?.count == 6)
    #expect(started["state"]?.stringValue == "requested")
    // The app cannot approve itself, nor can anyone but the owner.
    #expect(code(call(s, app, "hub.pairing.approve", params: #"{"pairingId":"\#(pairingId)","grant":{"capabilities":["observe"]}}"#)) == "pairing_required")
    #expect(data(call(s, app, "hub.pairing.status", params: #"{"pairingId":"\#(pairingId)"}"#))?["state"]?.stringValue == "requested")
    // The owner sees it, and can give no more than was asked.
    let listed = try #require(data(call(s, owner, "hub.clients.list")))
    #expect(listed["pairings"]?.arrayValue?.contains { $0["pairingId"]?.stringValue == pairingId } == true)
    #expect(code(call(s, owner, "hub.pairing.approve", params: #"{"pairingId":"\#(pairingId)","grant":{"capabilities":["observe","unit.run"]}}"#)) == "invalid_argument")
    let approved = try #require(data(call(s, owner, "hub.pairing.approve", params: #"{"pairingId":"\#(pairingId)","grant":{"capabilities":["observe"],"desktops":["created"]}}"#)))
    let clientId = try #require(approved["client"]?["clientId"]?.stringValue)
    #expect(clientId.hasPrefix("app:"))
    #expect(approved.encoded().contains("adt1_") == false, "the owner never sees the app's token")
    // Another connection asking about the pairing gets no credential.
    let (other, _) = socketConnection(s)
    #expect(code(call(s, other, "hub.pairing.status", params: #"{"pairingId":"\#(pairingId)"}"#)) == "not_found")
    #expect(data(call(s, owner, "hub.pairing.status", params: #"{"pairingId":"\#(pairingId)"}"#))?["credential"] == nil)
    // The asking connection collects it, once.
    let status = try #require(data(call(s, app, "hub.pairing.status", params: #"{"pairingId":"\#(pairingId)"}"#)))
    let token = try #require(status["credential"]?["token"]?.stringValue)
    #expect(status["credential"]?["clientId"]?.stringValue == clientId)
    #expect(status["grant"]?["capabilities"] == .array([.string("observe")]))
    #expect(data(call(s, app, "hub.pairing.status", params: #"{"pairingId":"\#(pairingId)"}"#))?["credential"] == nil)
    // A new connection proves it and is the paired app, within its grant.
    let (paired, ok) = socketConnection(s, clientId: clientId, token: token)
    #expect(data(ok)?["principal"]?["role"]?.stringValue == "paired")
    #expect(data(ok)?["principal"]?["clientId"]?.stringValue == clientId)
    #expect(data(call(s, paired, "desktop.list")) != nil)
    #expect(data(call(s, paired, "runtime.status")) != nil)
    #expect(code(call(s, paired, "desktop.create")) == "grant_missing")
    #expect(errorDetails(call(s, paired, "desktop.create"))?["capability"]?.stringValue == "desktop.manage")
    // Default deny for everything the owner keeps.
    #expect(code(call(s, paired, "hub.clients.list")) == "permission_denied")
    #expect(errorDetails(call(s, paired, "hub.clients.list"))?["reason"]?.stringValue == "owner_only")
    #expect(code(call(s, paired, "hub.pairing.approve", params: #"{"pairingId":"\#(pairingId)","grant":{}}"#)) == "permission_denied")
    // Only the hash is stored.
    let stored = try #require(s.hub.client(clientId))
    #expect(stored.json.encoded().contains(token) == false)
}

@Test func aDeniedPairingIssuesNothing() throws {
    let s = platformService()
    let owner = handshaken(s)
    let (app, _) = socketConnection(s)
    let pairingId = try #require(data(call(s, app, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["act"]}}"#))?["pairingId"]?.stringValue)
    #expect(data(call(s, owner, "hub.pairing.deny", params: #"{"pairingId":"\#(pairingId)"}"#))?["state"]?.stringValue == "denied")
    let status = try #require(data(call(s, app, "hub.pairing.status", params: #"{"pairingId":"\#(pairingId)"}"#)))
    #expect(status["state"]?.stringValue == "denied" && status["credential"] == nil)
    #expect(s.hub.clients().isEmpty)
    // A denied pairing cannot be approved afterwards.
    #expect(code(call(s, owner, "hub.pairing.approve", params: #"{"pairingId":"\#(pairingId)","grant":{"capabilities":["act"]}}"#)) == "conflict")
    #expect(code(call(s, app, "desktop.list")) == "pairing_required")
    // Unknown capabilities are refused at the door (by the contract).
    #expect(code(call(s, app, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["root"]}}"#)) == "schema_invalid")
}

@Test func aWrongOrBorrowedCredentialIsRefusedAndAudited() throws {
    let s = platformService()
    let (_, a) = try pairedConnection(s, capabilities: ["observe"], name: "a")
    let (_, b) = try pairedConnection(s, capabilities: ["observe", "act", "desktop.manage"], name: "b")
    // A made-up token, an unknown client, B's id with a guessed token.
    for (id, token) in [(a, "adt1_wrong"), ("app:nobody", "adt1_wrong"), (b, "adt1_" + String(repeating: "A", count: 43))] {
        let (c, r) = socketConnection(s, clientId: id, token: token)
        #expect(code(r) == "permission_denied", "\(id)")
        #expect(errorDetails(r)?["reason"]?.stringValue == "bad_credential")
        #expect(code(call(s, c, "desktop.list")) == "handshake_required" || code(call(s, c, "desktop.list")) == "pairing_required")
    }
    // No token at all breaks the contract before anything is looked up.
    #expect(code(socketConnection(s, clientId: a, token: "").1) == "schema_invalid")
    // An app claiming to be the owner with anything but the owner token.
    let (_, asOwner) = socketConnection(s, clientId: "local:\(getuid())", token: "adt1_guess")
    #expect(code(asOwner) == "permission_denied")
    let denials = s.hub.auditEvents().filter { $0["decision"]?.stringValue == "denied" && $0["method"]?.stringValue == "runtime.handshake" }
    #expect(denials.count == 4)
    #expect(denials.contains { $0["clientId"]?.stringValue == b }, "the claimed id is recorded beside the refusal")
}

@Test func anAppCannotReachAnotherAppsWorkByChangingParams() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let (a, idA, _) = try pairedScene(s, platform, name: "boss")
    let (cB, idB) = try pairedConnection(s, capabilities: ["observe", "act", "desktop.manage", "run"], desktops: ["created"],
                                         apps: ["com.apple.calculator"], name: "wechat")
    let r = try #require(data(act(a, clickContinue, id: "boss-click")))
    let runId = try #require(r["runId"]?.stringValue)
    let b = Scene(platform: platform, s: s, c: cB, desktop: a.desktop, session: a.session, snapshot: a.snapshot)
    // B names A's Desktop, session, snapshot, Run and requestId.
    #expect(code(call(s, cB, "desktop.show", params: #"{"desktopId":"\#(a.desktop)"}"#)) == "not_found")
    #expect(code(call(s, cB, "session.open", params: #"{"desktopId":"\#(a.desktop)"}"#)) == "not_found")
    #expect(code(call(s, cB, "observe", context: #"{"sessionId":"\#(a.session)"}"#)) == "not_found")
    #expect(code(act(b, clickContinue)) == "not_found")
    #expect(code(act(b, clickContinue, runId: runId)) == "not_found")
    #expect(code(call(s, cB, "desktop.destroy", params: #"{"desktopId":"\#(a.desktop)"}"#)) == "not_found")
    #expect(code(call(s, cB, "window.bind", params: #"{"desktopId":"\#(a.desktop)","pid":101}"#)) == "not_found")
    #expect(code(call(s, cB, "run.show", params: #"{"runId":"\#(runId)"}"#)) == "not_found")
    #expect(code(call(s, cB, "run.cancel", params: #"{"runId":"\#(runId)"}"#)) == "not_found")
    #expect(code(call(s, cB, "request.show", params: #"{"requestId":"boss-click"}"#)) == "not_found")
    // The same requestId from B is B's own request, not a replay of A's.
    #expect(errorDetails(act(b, clickContinue, id: "boss-click"))?["originalMethod"] == nil)
    // Self-reported identity in the request is no identity at all.
    #expect(code(call(s, cB, "desktop.list", params: #"{"clientId":"\#(idA)"}"#)) == "schema_invalid")
    #expect(code(call(s, cB, "desktop.list", context: #"{"clientId":"\#(idA)"}"#)) == "schema_invalid")
    // Listings show each app its own.
    #expect(data(call(s, cB, "desktop.list"))?["desktops"]?.arrayValue?.isEmpty == true)
    #expect(data(call(s, a.c, "desktop.list"))?["desktops"]?.arrayValue?.count == 1)
    #expect(data(call(s, cB, "run.list"))?["runs"]?.arrayValue?.isEmpty == true)
    #expect(platform.performed.count == 1, "only A's own click was sent")
    // The audit names the real caller of each refusal.
    let refused = s.hub.auditEvents().filter { $0["decision"]?.stringValue == "denied" }
    #expect(refused.allSatisfy { $0["clientId"]?.stringValue == idB })
    #expect(refused.contains { $0["method"]?.stringValue == "act" && $0["runId"]?.stringValue == runId
        && $0["reason"]?.stringValue == "foreign_session" })
}

@Test func anOutOfGrantAppOrDesktopIsRefused() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let ownersDesktop = try created(s, owner)
    // Grant without the Calculator: binding it is refused.
    let (c, _) = try pairedConnection(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"], apps: [])
    let d = try created(s, c)
    #expect(code(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)) == "grant_missing")
    #expect(code(call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.Notes"}"#)) == "grant_missing")
    // The user's own display is the owner's to attach.
    #expect(code(call(s, c, "desktop.create", params: #"{"physical":{}}"#)) == "permission_denied")
    #expect(s.hub.auditEvents().contains { $0["reason"]?.stringValue == "physical_display" })
    // The owner's Desktop is out of a "created" grant.
    #expect(code(call(s, c, "session.open", params: #"{"desktopId":"\#(ownersDesktop)"}"#)) == "not_found")
    #expect(platform.calls.filter { $0.hasPrefix("move") || $0.hasPrefix("launch") }.isEmpty)
}

@Test func anExpiredGrantStopsWorkUntilTheOwnerRenewsIt() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, token) = try pairedScene(s, platform)
    var g = try #require(s.hub.grant(id))
    g.expiresAt = Timestamp.string(Date().addingTimeInterval(-1))
    try s.hub.putGrant(g)
    #expect(code(act(sc, clickContinue)) == "grant_expired")
    #expect(code(call(s, sc.c, "desktop.list")) == "grant_expired")
    #expect(platform.performed.isEmpty)
    // Renewal: a grant past seven days is refused, a shorter one works.
    #expect(code(call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(id)","capabilities":["observe","act"],"desktops":["created"],"durationSeconds":9999999}"#)) == "schema_invalid")
    let renewed = try #require(data(call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(id)","capabilities":["observe","act"],"desktops":["created"],"apps":["com.apple.calculator"],"durationSeconds":600}"#)))
    #expect(renewed["revision"]?.intValue == 2)
    // The renewal dropped capabilities: the old connection was cut; the app
    // reconnects under the new grant.
    #expect(code(act(sc, clickContinue)) == "grant_missing")
    let (again, _) = socketConnection(s, clientId: id, token: token)
    let back = Scene(platform: platform, s: s, c: again, desktop: sc.desktop, session: sc.session, snapshot: sc.snapshot)
    #expect(data(act(back, clickContinue)) != nil)
}

@Test func revokingAnAppStopsItsRunsAndRefusesNewActionsInThem() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, _) = try pairedScene(s, platform)
    let start = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let runId = try #require(start["run"]?["runId"]?.stringValue)
    #expect(data(act(sc, clickContinue, runId: runId)) != nil)
    let epoch = s.hub.policyEpoch
    let revoked = try #require(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)))
    #expect(revoked["state"]?.stringValue == "revoked")
    #expect(s.hub.policyEpoch > epoch)
    // The open connection: no new action, in the Run or outside it.
    #expect(code(act(sc, clickContinue, runId: runId)) == "client_revoked")
    #expect(code(act(sc, clickContinue)) == "client_revoked")
    #expect(code(call(s, sc.c, "desktop.list")) == "client_revoked")
    #expect(platform.performed.count == 1)
    let run = try #require(data(call(s, owner, "run.show", params: #"{"runId":"\#(runId)"}"#)))
    #expect(run["phase"]?.stringValue == "ended" && run["closingReason"]?.stringValue == "client_revoked")
    // Its sessions are closed: the owner can tear its Desktop down.
    #expect(data(call(s, owner, "desktop.destroy", params: #"{"desktopId":"\#(sc.desktop)"}"#)) != nil)
    // The old credential no longer opens a connection.
    let (_, again) = socketConnection(s, clientId: id, token: "adt1_irrelevant")
    #expect(code(again) == "permission_denied")
    // Re-pairing makes a new client; the old one stays revoked.
    let (_, newId) = try pairedConnection(s, capabilities: ["observe"], name: "app")
    #expect(newId != id && s.hub.client(id)?.state == "revoked")
}

@Test func theRevokedCredentialItselfIsToldItWasRevoked() throws {
    let s = platformService()
    let owner = handshaken(s)
    let pairing = try s.hub.startPairing(connectionId: "conn_x", agentName: "x", publisher: nil, requested: .obj([]), callerFacts: .obj([]))
    let (client, _) = try s.hub.approve(pairing, grant: HubStore.Grant(clientId: "", capabilities: ["observe"], desktops: [], apps: [],
                                                                        expiresAt: Timestamp.string(Date().addingTimeInterval(60)),
                                                                        revision: 0, state: "active"))
    let token = try #require(s.hub.collect(pairing.pairingId))
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(client.clientId)"}"#)) != nil)
    let (_, r) = socketConnection(s, clientId: client.clientId, token: token)
    #expect(code(r) == "client_revoked")
}

@Test func narrowingAGrantStopsRunsOutsideIt() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, _) = try pairedScene(s, platform)
    let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    #expect(data(call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(id)","capabilities":["observe","act"],"desktops":[]}"#)) != nil)
    // The connection was cut on narrowing.
    #expect(code(act(sc, clickContinue, runId: runId)) == "grant_missing")
    #expect(code(act(sc, clickContinue)) == "grant_missing")
    #expect(platform.performed.isEmpty)
    let run = try #require(data(call(s, owner, "run.show", params: #"{"runId":"\#(runId)"}"#)))
    #expect(run["closingReason"]?.stringValue == "grant_narrowed")
    // Revoking only the grant keeps the client but refuses its work.
    #expect(data(call(s, owner, "hub.grants.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    #expect(code(call(s, sc.c, "desktop.list")) == "grant_missing")
}

@Test func aDroppedAppEndsItsDelegatedRunAndAnUnknownActionStaysUnknown() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, token) = try pairedScene(s, platform)
    let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    #expect(code(act(sc, clickContinue, id: "lost-click", runId: runId)) == "action_delivery_unknown")
    s.connectionClosed(sc.c)
    let run = try #require(data(call(s, owner, "run.show", params: #"{"runId":"\#(runId)"}"#)))
    #expect(run["phase"]?.stringValue == "ended" && run["quiescence"]?.stringValue == "confirmed")
    #expect(run["closingReason"]?.stringValue == "owner_lost")
    #expect(run["outcome"]?.stringValue == "unknown", "never called cancelled or success")
    // The app comes back on a new connection with the same credential: the
    // unknown request is still unknown and is never sent again.
    let (back, hello) = socketConnection(s, clientId: id, token: token)
    #expect(data(hello)?["principal"]?["clientId"]?.stringValue == id)
    let again = Scene(platform: platform, s: s, c: back, desktop: sc.desktop, session: sc.session, snapshot: sc.snapshot)
    #expect(code(act(again, clickContinue, id: "lost-click", runId: runId)) == "action_delivery_unknown")
    #expect(platform.performed.isEmpty)
}

@Test func aRevokedAppsEventStreamStopsAndCloses() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, token) = try pairedScene(s, platform)
    let dir = try socketDirectory()
    let path = dir + "/runtime.sock"
    let server = RuntimeServer(path: path, service: s)
    try server.start()
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let watcher = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"),
                                      timeout: 5, credential: ClientCredential(clientId: id, token: token))
    defer { watcher.close() }
    #expect(try watcher.subscribe(runId: nil, after: nil)["subscribed"]?.boolValue == true)
    let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    var before: [JSONValue] = []
    for _ in 0..<5 where before.isEmpty {
        if case let .frame(f) = try watcher.nextEvent() { before.append(f) }
    }
    #expect(before.first?["event"]?["runId"]?.stringValue == runId)
    // Revocation stops the Run (more events) but the stream sends none of them.
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    var after: [JSONValue] = []
    var closed = false
    for _ in 0..<10 where !closed {
        switch try watcher.nextEvent() {
        case let .frame(f): after.append(f)
        case .idle: break
        case .closed: closed = true
        }
    }
    #expect(closed, "the stream closes once access is gone")
    #expect(after.allSatisfy { $0["event"]?["type"]?.stringValue == "run.started" }, "no event after the revocation: \(after)")
    #expect(s.hub.auditEvents().contains { $0["decision"]?.stringValue == "cut" && $0["reason"]?.stringValue == "client_revoked" })
}
