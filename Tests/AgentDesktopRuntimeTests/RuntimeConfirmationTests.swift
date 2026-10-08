import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A4-SEC-03 regression: no socket client is ever the owner; pairings and
// owner-only calls are decided by the user in the host's trusted window,
// bound to exactly what is applied; a client that paired as verified code
// must be that code on every later connection.

/// A scripted trusted window: answers with `decide`, records what it saw.
final class FakeConfirmer: TrustedConfirmer, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ConfirmationRequest] = []
    var decide: @Sendable (ConfirmationRequest) -> ConfirmationDecision

    init(_ decide: @escaping @Sendable (ConfirmationRequest) -> ConfirmationDecision = { .approved(digest: $0.digest) }) {
        self.decide = decide
    }

    var requests: [ConfirmationRequest] { lock.withLock { seen } }

    func confirm(_ request: ConfirmationRequest) -> ConfirmationDecision {
        lock.withLock { seen.append(request) }
        return decide(request)
    }
}

/// Code identities by fake audit token: a token is "the program it names".
struct FakeVerifier: CodeIdentityVerifier {
    var identities: [String: CodeIdentity]
    func identify(auditToken: Data, executable: String?) -> CodeIdentity {
        identities[String(decoding: auditToken, as: UTF8.self)] ?? .unknown
    }
    func satisfies(auditToken: Data, requirement: String) -> Bool {
        identify(auditToken: auditToken, executable: nil).requirement == requirement
    }
}

let signedA = CodeIdentity(level: .verified, identifier: "com.example.boss", teamId: "TEAMAAAAAA", hardenedRuntime: true,
                           requirement: "identifier \"com.example.boss\" and anchor apple generic and certificate leaf[subject.OU] = TEAMAAAAAA")
let signedB = CodeIdentity(level: .verified, identifier: "com.example.other", teamId: "TEAMBBBBBB", hardenedRuntime: true,
                           requirement: "identifier \"com.example.other\" and anchor apple generic and certificate leaf[subject.OU] = TEAMBBBBBB")
let script = CodeIdentity(level: .sameUser, identifier: "python3")

/// A socket connection whose kernel-reported program is `program`.
func peer(_ s: RuntimeService, _ program: String?) -> ConnectionState {
    let c = ConnectionState(socketPeer: getuid(), pid: 4242, executable: "/opt/\(program ?? "x")")
    if let program {
        c.peerAuditToken = Data(program.utf8)
        c.codeIdentity = s.codeVerifier.identify(auditToken: Data(program.utf8), executable: nil)
    }
    return c
}

func hello(_ s: RuntimeService, _ c: ConnectionState, _ credential: ClientCredential? = nil, extra: String = "") -> RuntimeResponse {
    let cred = credential.map { #","credential":{"clientId":"\#($0.clientId)","token":"\#($0.token)"}"# } ?? ""
    return answer(s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"hs","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}\#(cred)\#(extra)}}"#, c)
}

private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

/// Pair from `c` through runtime/1; the credential once the window answered.
func pairThroughWindow(_ s: RuntimeService, _ c: ConnectionState, capabilities: [String] = ["observe"],
                       desktops: [String] = [], durationSeconds: Int? = nil) throws -> (pairingId: String, credential: ClientCredential?) {
    _ = hello(s, c)
    let caps = capabilities.map { #""\#($0)""# }.joined(separator: ",")
    let desks = desktops.map { #""\#($0)""# }.joined(separator: ",")
    let dur = durationSeconds.map { #","durationSeconds":\#($0)"# } ?? ""
    let started = try #require(data(call(s, c, "hub.pairing.start", params: #"{"agentName":"BOSS Agent","requested":{"capabilities":[\#(caps)],"desktops":[\#(desks)]\#(dur)}}"#)))
    let id = try #require(started["pairingId"]?.stringValue)
    var credential: ClientCredential?
    _ = waitFor {
        guard let st = data(call(s, c, "hub.pairing.status", params: #"{"pairingId":"\#(id)"}"#)) else { return true }
        if let cred = st["credential"] {
            credential = ClientCredential(clientId: cred["clientId"]!.stringValue!, token: cred["token"]!.stringValue!)
            return true
        }
        return st["state"]?.stringValue != "requested"
    }
    return (id, credential)
}

// MARK: S1: no owner on a socket

@Test func secNoFileOrCredentialMakesASocketClientTheOwnerEvenAfterARestart() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // What an earlier build left behind: an owner token in a user-readable file.
    let legacy = "adt1_legacy-owner-token"
    FileManager.default.createFile(atPath: dir + "/owner.credential", contents: Data(legacy.utf8), attributes: [.posixPermissions: 0o600])
    let identity = RuntimeIdentity(instanceId: "rt_s1", pid: getpid(), startedAt: Timestamp.string(Date()), endpoint: dir + "/r.sock",
                                   buildSource: "unknown")
    for round in 0..<2 {
        let s = try RuntimeService.persistent(identity: identity, backend: FixedBackend(), platform: FakePlatform(), records: dir)
        #expect(!FileManager.default.fileExists(atPath: dir + "/owner.credential"), "round \(round): no owner file")
        #expect(s.testSocketOwnerToken == nil)
        for token in [legacy, "adt1_guess", ""] where !token.isEmpty {
            let c = peer(s, nil)
            let r = hello(s, c, ClientCredential(clientId: "local:\(getuid())", token: token))
            #expect(code(r) == "permission_denied")
            #expect(errorDetails(r)?["reason"]?.stringValue == "owner_not_on_socket")
            #expect(c.role != .owner)
        }
        // Without a credential: unpaired, and the owner's methods say so.
        let anon = peer(s, nil)
        #expect(data(hello(s, anon))?["principal"]?["role"]?.stringValue == "unpaired")
        for m in ["hub.clients.list", "hub.pairing.approve", "runtime.stopAll", "desktop.list"] {
            #expect(code(call(s, anon, m, params: m == "hub.pairing.approve" ? #"{"pairingId":"pair_x","grant":{}}"# : m == "runtime.stopAll" ? #"{"scope":"all_platform_runs"}"# : "{}")) == "pairing_required", "\(m)")
        }
    }
}

// MARK: The trusted window

@Test func secAPairingIsGrantedOnlyByTheUsersApprovalOfExactlyWhatWasShown() throws {
    let s = platformService()
    s.codeVerifier = FakeVerifier(identities: ["boss": signedA])
    let window = FakeConfirmer()
    s.confirmer = window
    let c = peer(s, "boss")
    let (pairingId, credential) = try pairThroughWindow(s, c, capabilities: ["observe", "act"], desktops: ["created"], durationSeconds: 900)
    let cred = try #require(credential)
    let seen = try #require(window.requests.first)
    #expect(seen.kind == .pairing)
    #expect(seen.details == .obj([("capabilities", .array([.string("observe"), .string("act")])), ("desktops", .array([.string("created")])),
                                  ("apps", .array([])), ("durationSeconds", .int(900))]))
    #expect(seen.shortCode?.count == 6)
    #expect(seen.requester["codeIdentity"]?["level"]?.stringValue == "verified")
    #expect(seen.requester["codeIdentity"]?["teamId"]?.stringValue == "TEAMAAAAAA", "read from the peer, not sent by it")
    #expect(s.hub.pairing(pairingId)?.state == "approved")
    // Granted exactly that, no more, for that long from the approval.
    let g = try #require(s.hub.grant(cred.clientId))
    #expect(g.capabilities == ["observe", "act"] && g.desktops == ["created"] && g.apps.isEmpty)
    #expect(g.expiresAt <= Timestamp.string(Date().addingTimeInterval(905)))
    #expect(s.hub.client(cred.clientId)?.codeIdentity["requirement"]?.stringValue == signedA.requirement)
}

@Test(arguments: ["denied", "cancelled", "timedOut", "unavailable", "mismatch"])
func secAnythingButAnApprovalGrantsNothing(_ answer: String) throws {
    let s = platformService()
    s.confirmer = FakeConfirmer { r in
        switch answer {
        case "denied": return .denied
        case "cancelled": return .cancelled
        case "timedOut": return .timedOut
        case "unavailable": return .unavailable("no window")
        default: return .approved(digest: String(r.digest.reversed()))   // approved, but something else
        }
    }
    let c = peer(s, "boss")
    let (pairingId, credential) = try pairThroughWindow(s, c)
    #expect(credential == nil)
    #expect(s.hub.pairing(pairingId)?.state == "denied")
    #expect(s.hub.clients().isEmpty)
    let reason = ["denied": "user_denied", "cancelled": "user_cancelled", "timedOut": "confirmation_timeout",
                  "unavailable": "no_trusted_ui", "mismatch": "confirmation_mismatch"][answer]!
    #expect(s.hub.auditEvents().contains { $0["reason"]?.stringValue == reason }, "\(answer)")
}

@Test func secWithoutATrustedWindowNothingIsApproved() throws {
    let s = platformService()   // no confirmer
    let c = peer(s, "boss")
    _ = hello(s, c)
    let id = try #require(data(call(s, c, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["observe"]}}"#))?["pairingId"]?.stringValue)
    Thread.sleep(forTimeInterval: 0.2)
    #expect(s.hub.pairing(id)?.state == "requested", "waits for the host's own window, never approves itself")
    #expect(s.hub.clients().isEmpty)
    // A paired client's owner call is refused, not run.
    let (app, _) = try pairedConnection(s, capabilities: ["observe"])
    #expect(errorDetails(call(s, app, "hub.clients.list"))?["reason"]?.stringValue == "no_trusted_ui")
}

// MARK: Owner calls a paired client asks for

@Test func secAClientCannotApproveOrWidenItsOwnAccess() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    let (app, id) = try pairedConnection(s, capabilities: ["observe"])
    // Its own pairing requests, from another connection.
    let other = peer(s, "boss")
    _ = hello(s, other)
    let pairingId = try #require(data(call(s, other, "hub.pairing.start", params: #"{"agentName":"me too","requested":{"capabilities":["act"]}}"#))?["pairingId"]?.stringValue)
    #expect(waitFor { s.hub.pairing(pairingId)?.state != "requested" })
    let asked = window.requests.count
    // Approving pairings is the window's alone, never an IPC call.
    #expect(errorDetails(call(s, app, "hub.pairing.approve", params: #"{"pairingId":"\#(pairingId)","grant":{"capabilities":["act"]}}"#))?["reason"]?.stringValue == "owner_only")
    // Its own grant: refused before anyone is asked.
    for (m, p) in [("hub.grants.set", #"{"clientId":"\#(id)","capabilities":["observe","act","desktop.manage"],"desktops":["created"],"durationSeconds":604800}"#),
                   ("hub.grants.revoke", #"{"clientId":"\#(id)"}"#)] {
        let r = call(s, app, m, params: p)
        #expect(errorDetails(r)?["reason"]?.stringValue == "self_grant", "\(m)")
    }
    #expect(window.requests.count == asked, "the user was not even asked")
    #expect(s.hub.grant(id)?.capabilities == ["observe"])
}

@Test func secAConfirmedOwnerCallRunsOnceAndOnlyThatCall() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    let (app, id) = try pairedConnection(s, capabilities: ["observe"], name: "cli")
    let (_, other) = try pairedConnection(s, capabilities: ["observe", "act"], name: "wechat")
    let listed = try #require(data(call(s, app, "hub.clients.list")))
    #expect(listed["clients"]?.arrayValue?.count == 2)
    let first = try #require(window.requests.last)
    #expect(first.kind == .adminCall && first.action == "hub.clients.list")
    #expect(first.requester["clientId"]?.stringValue == id)
    // Narrowing another app: asked again, with exactly these params.
    let narrowed = #"{"clientId":"\#(other)","capabilities":["observe"],"desktops":[]}"#
    #expect(data(call(s, app, "hub.grants.set", params: narrowed)) != nil)
    #expect(window.requests.count == 2)
    let expected = try StrictJSON.parse(Data(narrowed.utf8))
    #expect(window.requests.last?.details == expected)
    #expect(s.hub.grant(other)?.capabilities == ["observe"])
    // The approval did not stay with the connection.
    #expect(app.elevatedFor == nil)
    #expect(errorDetails(call(s, app, "gui.runs.get", params: #"{"runId":"run_x"}"#))?["reason"]?.stringValue == "owner_only")
    #expect(code(call(s, app, "run.list")) == "grant_missing")
    // The user says no: nothing happens.
    window.decide = { _ in .denied }
    #expect(errorDetails(call(s, app, "hub.clients.revoke", params: #"{"clientId":"\#(other)"}"#))?["reason"]?.stringValue == "user_denied")
    #expect(s.hub.client(other)?.state == "active")
}

@Test func secOneClientCannotQueueUpPrompts() async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        Thread {
            do {
                let s = platformService()
                let release = DispatchSemaphore(value: 0)
                let window = FakeConfirmer { r in release.wait(); return .approved(digest: r.digest) }
                s.confirmer = window
                let (app, _) = try pairedConnection(s, capabilities: ["observe"])
                let (app2, _) = try reconnectAs(s, app)
                let done = DispatchSemaphore(value: 0)
                Thread { _ = s.respond(to: Data(requestLine("hub.clients.list", id: "first").utf8), on: app); done.signal() }.start()
                #expect(waitFor { window.requests.count == 1 })
                // The same client, another connection: refused while one waits.
                let second = s.respond(to: Data(requestLine("hub.connections.list", id: "second").utf8), on: app2)
                #expect(errorDetails(second)?["reason"]?.stringValue == "confirmation_busy")
                #expect(window.requests.count == 1)
                release.signal()
                done.wait()
                k.resume()
            } catch { k.resume(throwing: error) }
        }.start()
    }
}

/// Another connection of the same paired client (for tests: shares its id).
func reconnectAs(_ s: RuntimeService, _ c: ConnectionState) throws -> (ConnectionState, String) {
    let n = ConnectionState(socketPeer: getuid(), pid: nil, executable: nil)
    n.clientId = c.clientId
    n.role = c.role
    _ = answer(s, handshakeLine, n)
    n.clientId = c.clientId
    n.role = c.role
    return (n, c.clientId)
}

// MARK: S2: the code a client paired as

@Test func secACopiedCredentialDoesNotWorkFromAnotherProgram() throws {
    let s = platformService()
    s.codeVerifier = FakeVerifier(identities: ["boss": signedA, "other": signedB, "python": script])
    s.confirmer = FakeConfirmer()
    let (_, credential) = try pairThroughWindow(s, peer(s, "boss"))
    let cred = try #require(credential)
    // The program it paired as: accepted.
    let again = peer(s, "boss")
    #expect(data(hello(s, again, cred))?["principal"]?["codeIdentityLevel"]?.stringValue == "verified")
    // The same token from another signed program, a script, or a peer the
    // kernel could not describe: refused.
    for program in ["other", "python", nil] as [String?] {
        let thief = peer(s, program)
        let r = hello(s, thief, cred)
        #expect(code(r) == "permission_denied", "\(program ?? "no token")")
        #expect(errorDetails(r)?["reason"]?.stringValue == "code_identity_mismatch")
        #expect(thief.role == .unpaired)
    }
    // Saying who you are in the request changes nothing: refused by the contract.
    let liar = peer(s, "python")
    #expect(code(hello(s, liar, cred, extra: #","codeIdentity":{"teamId":"TEAMAAAAAA"}"#)) == "schema_invalid")
    #expect(code(hello(s, peer(s, "python"), cred, extra: #","teamId":"TEAMAAAAAA""#)) == "schema_invalid")
}

@Test func secAScriptClientIsShownAsSameUserOnly() throws {
    let s = platformService()
    s.codeVerifier = FakeVerifier(identities: ["python": script])
    let window = FakeConfirmer()
    s.confirmer = window
    let (_, credential) = try pairThroughWindow(s, peer(s, "python"))
    let cred = try #require(credential)
    #expect(window.requests.first?.requester["codeIdentity"]?["level"]?.stringValue == "same_user")
    #expect(s.hub.client(cred.clientId)?.codeIdentity["requirement"] == nil)
    // Nothing binds it: the identity the window showed is what it gets.
    #expect(data(hello(s, peer(s, "python"), cred))?["principal"]?["codeIdentityLevel"]?.stringValue == "same_user")
}

// MARK: Revocation and work already accepted

@Test func secAnActionInFlightAtTheRevocationIsNotTreatedAsNeverSent() async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        Thread {
            do {
                let platform = FakePlatform()
                let s = platformService(platform)
                let owner = handshaken(s)
                let (sc, id, _) = try pairedScene(s, platform)
                let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
                let gate = DispatchSemaphore(value: 0)
                platform.gate = gate
                let done = DispatchSemaphore(value: 0)
                let line = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"inflight-1","method":"act","context":{"sessionId":"\#(sc.session)","runId":"\#(runId)"},"params":{"snapshotId":"\#(sc.snapshot)","action":\#(clickContinue)}}"#
                Thread { _ = s.respond(to: Data(line.utf8), on: sc.c); done.signal() }.start()
                #expect(platform.entered.wait(timeout: .now() + 3) == .success, "the click is being sent")
                #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
                platform.gate = nil
                gate.signal()
                #expect(done.wait(timeout: .now() + 3) == .success)
                // It happened, and the record says so; the Run settled after it.
                #expect(platform.performed.count == 1)
                #expect(try s.ledger.record(caller: id, requestId: "inflight-1")?.state == .completed)
                #expect(waitFor { data(call(s, owner, "run.show", params: #"{"runId":"\#(runId)"}"#))?["quiescence"]?.stringValue == "confirmed" })
                let run = try #require(data(call(s, owner, "run.show", params: #"{"runId":"\#(runId)"}"#)))
                #expect(run["receipts"]?.arrayValue?.count == 1)
                #expect(run["closingReason"]?.stringValue == "client_revoked")
                k.resume()
            } catch { k.resume(throwing: error) }
        }.start()
    }
}
