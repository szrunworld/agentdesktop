import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A4-SEC-03 regression: no socket client is ever the owner; pairings and
// owner-only calls are decided by the user in the host's trusted window,
// bound to exactly what is applied; a client that paired as verified code
// must be that code on every later connection.

/// Blocking test bodies (sleeps, polling, semaphores) run on a plain
/// thread, never on the cooperative pool other tests' services need.
func offPoolConfirm(_ body: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        Thread { do { try body(); k.resume() } catch { k.resume(throwing: error) } }.start()
    }
}

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

/// Mark a test connection as verified code (Developer ID, hardened runtime).
@discardableResult
func asVerified(_ c: ConnectionState) -> ConnectionState {
    c.codeIdentity = signedA
    return c
}

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

@Test func secAPairingIsGrantedOnlyByTheUsersApprovalOfExactlyWhatWasShown() async throws {
    try await offPoolConfirm {
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
}

@Test(arguments: ["denied", "cancelled", "timedOut", "unavailable", "mismatch"])
func secAnythingButAnApprovalGrantsNothing(_ answer: String) async throws {
    try await offPoolConfirm {
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
}

@Test func secWithoutATrustedWindowNothingIsApproved() async throws {
    try await offPoolConfirm {
        let s = platformService()   // no confirmer
        let c = peer(s, "boss")
        _ = hello(s, c)
        let id = try #require(data(call(s, c, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["observe"]}}"#))?["pairingId"]?.stringValue)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(s.hub.pairing(id)?.state == "requested", "waits for the host's own window, never approves itself")
        #expect(s.hub.clients().isEmpty)
        // A paired client's owner call is refused, not run.
        let (app, _) = try pairedConnection(s, capabilities: ["observe"])
        asVerified(app)
        #expect(errorDetails(call(s, app, "hub.clients.list"))?["reason"]?.stringValue == "no_trusted_ui")
    }
}

// MARK: Owner calls a paired client asks for

@Test func secAClientCannotApproveOrWidenItsOwnAccess() async throws {
    try await offPoolConfirm {
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
        // More of its own access: refused before anyone is asked.
        for p in [#"{"clientId":"\#(id)","capabilities":["observe","act","desktop.manage"],"desktops":["created"],"durationSeconds":604800}"#,
                  #"{"clientId":"\#(id)","capabilities":["observe"],"desktops":[],"durationSeconds":604800}"#] {
            let r = call(s, app, "hub.grants.set", params: p)
            #expect(errorDetails(r)?["reason"]?.stringValue == "self_grant", "\(p)")
        }
        #expect(window.requests.count == asked, "the user was not even asked")
        #expect(s.hub.grant(id)?.capabilities == ["observe"])
    }
}

@Test func secAConfirmedOwnerCallRunsOnceAndOnlyThatCall() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    let (app, id) = try pairedConnection(s, capabilities: ["observe"], name: "cli")
    asVerified(app)
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
    #expect(window.requests.last?.details["params"] == expected)
    #expect(window.requests.last?.details["target"]?["clientId"]?.stringValue == other)
    #expect(s.hub.grant(other)?.capabilities == ["observe"])
    // The approval did not stay with the connection.
    #expect(app.elevatedFor == nil)
    #expect(errorDetails(call(s, app, "unit.run"))?["capability"]?.stringValue == "unit.run")
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
                asVerified(app)
                let (app2, _) = try reconnectAs(s, app)
                asVerified(app2)
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

@Test func secACopiedCredentialDoesNotWorkFromAnotherProgram() async throws {
    try await offPoolConfirm {
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
}

@Test func secAScriptClientIsShownAsSameUserOnly() async throws {
    try await offPoolConfirm {
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

/// A4 review M4: a renamed interpreter, python.org's identifier, an Electron
/// app or injectable code is not "verified".
@Test func codeOthersCanRunAsIsNotCalledVerified() throws {
    typealias V = SecurityCodeIdentityVerifier
    #expect(V.runsOthersCode(identifier: "org.python.python", executable: "/tmp/innocent", entitlements: nil))
    #expect(V.runsOthersCode(identifier: "node", executable: "/tmp/renamed", entitlements: nil))
    #expect(V.runsOthersCode(identifier: "com.example.app", executable: "/usr/local/bin/python3.12", entitlements: nil))
    #expect(V.runsOthersCode(identifier: "com.example.app", executable: "/x/A.app/Contents/MacOS/A",
                             entitlements: ["com.apple.security.cs.allow-dyld-environment-variables": true]))
    #expect(V.runsOthersCode(identifier: "com.example.app", executable: nil,
                             entitlements: ["com.apple.security.cs.disable-library-validation": true]))
    #expect(!V.runsOthersCode(identifier: "com.example.boss", executable: "/Applications/Boss.app/Contents/MacOS/Boss",
                              entitlements: ["com.apple.security.app-sandbox": true]))
}

// MARK: Review fixes (M1–M3, L1, L4)

@Test func aNameThatCouldFakeLinesOfTheWindowIsRefused() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    for name in ["BOSS\n代码身份（系统核实）：已验证签名：com.apple.x", "a\u{202E}b", "x\u{2028}y", "tab\there", ""] {
        let c = peer(s, "boss")
        _ = hello(s, c)
        let params = JSONValue.obj([("agentName", .string(name)), ("requested", .obj([("capabilities", .array([.string("observe")]))]))])
        let r = answer(s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"p1","method":"hub.pairing.start","params":\#(params.encoded())}"#, c)
        #expect(code(r) == "schema_invalid" || code(r) == "invalid_argument", "\(name.debugDescription)")
    }
    #expect(window.requests.isEmpty, "nothing was shown")
    #expect(RuntimeService.showableName("BOSS Agent 招聘助手", max: 64))
}

@Test func anOwnerCallTooLargeToShowIsRefusedUnseen() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    let (app, _) = try pairedConnection(s, capabilities: ["observe"], name: "cli")
    asVerified(app)
    let (_, other) = try pairedConnection(s, capabilities: ["observe"], name: "other")
    let apps = (0..<60).map { #""com.example.a-rather-long-bundle-identifier.app\#($0)""# }.joined(separator: ",")
    let r = call(s, app, "hub.grants.set", params: #"{"clientId":"\#(other)","capabilities":["observe","act"],"desktops":[],"apps":[\#(apps)]}"#)
    #expect(errorDetails(r)?["reason"]?.stringValue == "confirmation_too_large")
    #expect(window.requests.isEmpty)
    #expect(s.hub.grant(other)?.capabilities == ["observe"])
}

@Test func aFloodOfPairingsNeitherWaitsInLineNorDeniesRealOnes() async throws {
    try await offPoolConfirm {
        let s = platformService()
        let release = DispatchSemaphore(value: 0)
        let window = FakeConfirmer { r in release.wait(); return .denied }
        s.confirmer = window
        // One process, many connections: one waiting request only.
        let first = ConnectionState(socketPeer: getuid(), pid: 1, executable: "/tmp/flooder")
        _ = hello(s, first)
        #expect(data(call(s, first, "hub.pairing.start", params: #"{"agentName":"f","requested":{"capabilities":["observe"]}}"#)) != nil)
        for _ in 0..<5 {
            let c = ConnectionState(socketPeer: getuid(), pid: 1, executable: "/tmp/flooder")
            _ = hello(s, c)
            let r = call(s, c, "hub.pairing.start", params: #"{"agentName":"f","requested":{"capabilities":["observe"]}}"#)
            #expect(errorDetails(r)?["reason"]?.stringValue == "pairing_busy")
        }
        #expect(waitFor { window.requests.count == 1 })
        // Other programs fill the line (one shown, the rest waiting)...
        for n in 0..<(ConfirmationGate.maxWaiting - 1) {
            let c = ConnectionState(socketPeer: getuid(), pid: Int32(10 + n), executable: "/tmp/other\(n)")
            _ = hello(s, c)
            #expect(data(call(s, c, "hub.pairing.start", params: #"{"agentName":"o","requested":{"capabilities":["observe"]}}"#)) != nil)
        }
        Thread.sleep(forTimeInterval: 0.2)
        // ...then a real app asks: the line is full, but that is not the user's
        // no: it stays requested.
        let real = ConnectionState(socketPeer: getuid(), pid: 3, executable: "/Applications/Boss.app/Contents/MacOS/Boss")
        _ = hello(s, real)
        let id = try #require(data(call(s, real, "hub.pairing.start", params: #"{"agentName":"boss","requested":{"capabilities":["observe"]}}"#))?["pairingId"]?.stringValue)
        #expect(waitFor { s.hub.auditEvents().contains { $0["reason"]?.stringValue == "confirmation_busy" } })
        Thread.sleep(forTimeInterval: 0.1)
        #expect(s.hub.pairing(id)?.state == "requested")
        for _ in 0..<ConfirmationGate.maxWaiting { release.signal() }
    }
}

@Test func aPairingEndsWithItsConnectionAndIsDecidedOnce() throws {
    let s = platformService()
    let c = peer(s, "boss")
    _ = hello(s, c)
    let id = try #require(data(call(s, c, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["observe"]}}"#))?["pairingId"]?.stringValue)
    let pairing = try #require(s.hub.pairing(id))
    try s.hub.deny(pairing)
    // A late approval of a denied request makes no client.
    #expect(throws: (any Error).self) { _ = try s.hub.approve(pairing, grant: HubStore.Grant(clientId: "", capabilities: ["observe"], desktops: [], apps: [], expiresAt: Timestamp.string(Date().addingTimeInterval(60)), revision: 0, state: "active")) }
    #expect(s.hub.clients().isEmpty && s.hub.pairing(id)?.state == "denied")
    // The asking connection goes away: its open request expires.
    let d = peer(s, "boss2")
    _ = hello(s, d)
    let id2 = try #require(data(call(s, d, "hub.pairing.start", params: #"{"agentName":"y","requested":{"capabilities":["observe"]}}"#))?["pairingId"]?.stringValue)
    s.connectionClosed(d)
    #expect(s.hub.pairing(id2)?.state == "expired")
}

@Test func aSocketConnectionSaysWhoItIsOnce() throws {
    let s = platformService()
    let (_, idA, tokenA) = try pairedClient(s, capabilities: ["observe"], name: "a")
    let (_, idB, tokenB) = try pairedClient(s, capabilities: ["observe", "act"], name: "b")
    let c = peer(s, nil)
    #expect(data(hello(s, c, ClientCredential(clientId: idA, token: tokenA))) != nil)
    let again = hello(s, c, ClientCredential(clientId: idB, token: tokenB))
    #expect(errorDetails(again)?["reason"]?.stringValue == "already_handshaken")
    #expect(c.clientId == idA)
}

// MARK: Re-review fixes

@Test func grantedAppsAndDesktopsCannotCarryFakeLines() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    for (field, value) in [("apps", "com.example.notes\n期限：批准后 5 分钟"), ("desktops", "created\u{202E}x"), ("apps", "a b")] {
        let c = peer(s, "boss-\(field)")
        _ = hello(s, c)
        let params = JSONValue.obj([("agentName", .string("ok")),
                                    ("requested", .obj([("capabilities", .array([.string("observe")])), (field, .array([.string(value)]))]))])
        let r = answer(s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"p1","method":"hub.pairing.start","params":\#(params.encoded())}"#, c)
        #expect(code(r) == "schema_invalid", "\(field): \(value.debugDescription)")
    }
    #expect(window.requests.isEmpty)
}

@Test func strangersCannotFlushTheAuditOfPairedClients() throws {
    let s = platformService()
    s.hub.auditKeptUnpaired = 50
    s.hub.auditKept = 100_000
    s.hub.auditPruneEvery = 10
    let (app, id) = try pairedConnection(s, capabilities: ["observe"], name: "suspect")
    // What the suspect did.
    #expect(code(call(s, app, "desktop.create")) == "grant_missing")
    #expect(data(call(s, handshaken(s), "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    // A flood of refusals from unpaired connections.
    for _ in 0..<400 {
        let c = peer(s, nil)
        _ = hello(s, c)
        _ = call(s, c, "desktop.list")
    }
    let events = s.hub.auditEvents(limit: 100_000)
    #expect(events.contains { $0["clientId"]?.stringValue == id && $0["decision"]?.stringValue == "denied" }, "the suspect's refusal is still there")
    #expect(events.contains { $0["clientId"]?.stringValue == id && $0["decision"]?.stringValue == "revoked" })
    #expect(events.filter { ($0["clientId"]?.stringValue ?? "").hasPrefix("unpaired:") }.count <= 60, "strangers' refusals are bounded")
}

@Test func scriptsOfOneInterpreterPairSideBySideButARefusedOneWaits() async throws {
    try await offPoolConfirm {
        let s = platformService()
        let bothAsked = DispatchSemaphore(value: 0)
        let window = FakeConfirmer { _ in bothAsked.wait(); bothAsked.signal(); return .denied }
        s.confirmer = window
        // Two python agents (same executable, different processes): both may ask.
        let a = ConnectionState(socketPeer: getuid(), pid: 501, executable: "/usr/bin/python3")
        let b = ConnectionState(socketPeer: getuid(), pid: 502, executable: "/usr/bin/python3")
        for c in [a, b] {
            _ = hello(s, c)
            #expect(data(call(s, c, "hub.pairing.start", params: #"{"agentName":"py","requested":{"capabilities":["observe"]}}"#)) != nil)
        }
        #expect(s.hub.pairings().count == 2, "both are waiting at once")
        bothAsked.signal()
        #expect(waitFor { window.requests.count == 2 })
        #expect(waitFor { s.hub.pairings().isEmpty })
        // Refused by the user: that program waits before asking again, and a
        // new process of it does not start over.
        let r = call(s, a, "hub.pairing.start", params: #"{"agentName":"py","requested":{"capabilities":["observe"]}}"#)
        #expect(errorDetails(r)?["reason"]?.stringValue == "pairing_cooldown")
        let fresh = ConnectionState(socketPeer: getuid(), pid: 999, executable: "/usr/bin/python3")
        _ = hello(s, fresh)
        #expect(errorDetails(call(s, fresh, "hub.pairing.start", params: #"{"agentName":"py","requested":{"capabilities":["observe"]}}"#))?["reason"]?.stringValue == "pairing_cooldown")
        #expect(window.requests.count == 2)
    }
}

@Test func aPairingThatFoundTheLineFullIsAskedOnceThereIsRoom() async throws {
    try await offPoolConfirm {
        let s = platformService()
        RuntimeService.busyRetry = 0.05
        let release = DispatchSemaphore(value: 0)
        let window = FakeConfirmer { r in
            if r.requester["agentName"]?.stringValue == "real" { return .approved(digest: r.digest) }
            release.wait(); return .denied
        }
        s.confirmer = window
        for n in 0..<ConfirmationGate.maxWaiting {
            let c = ConnectionState(socketPeer: getuid(), pid: Int32(700 + n), executable: "/tmp/f\(n)")
            _ = hello(s, c)
            _ = call(s, c, "hub.pairing.start", params: #"{"agentName":"filler","requested":{"capabilities":["observe"]}}"#)
        }
        #expect(waitFor { window.requests.count == 1 })
        let real = ConnectionState(socketPeer: getuid(), pid: 800, executable: "/Applications/Real.app/Contents/MacOS/Real")
        _ = hello(s, real)
        let id = try #require(data(call(s, real, "hub.pairing.start", params: #"{"agentName":"real","requested":{"capabilities":["observe"]}}"#))?["pairingId"]?.stringValue)
        #expect(waitFor { s.hub.auditEvents().contains { $0["reason"]?.stringValue == "confirmation_busy" } })
        for _ in 0..<ConfirmationGate.maxWaiting { release.signal() }
        #expect(waitFor { s.hub.pairing(id)?.state == "approved" }, "asked and approved once the line had room")
    }
}


// MARK: A4 R1: unverified code gets no sensitive management

@Test func unverifiedCodeMayOnlyAskForWhatTakesAccessAway() throws {
    let s = platformService()
    let window = FakeConfirmer()
    s.confirmer = window
    let (script, scriptId) = try pairedConnection(s, capabilities: ["observe", "act"], name: "py")   // same_user
    let (_, other) = try pairedConnection(s, capabilities: ["observe", "act"], desktops: ["created"], name: "other")
    // Sensitive: refused without even asking.
    for (m, p) in [("hub.clients.list", "{}"), ("hub.connections.list", "{}"), ("ai.connections.list", "{}"),
                   ("runtime.enableInput", "{}"),
                   ("hub.grants.set", #"{"clientId":"\#(other)","capabilities":["observe","act","desktop.manage"],"desktops":["created"]}"#)] {
        let r = call(s, script, m, params: p)
        #expect(errorDetails(r)?["reason"]?.stringValue == "unverified_identity", "\(m)")
    }
    // A shared interpreter counts as unverified too.
    let (node, _) = try pairedConnection(s, capabilities: ["observe"], name: "node")
    node.codeIdentity = CodeIdentity(level: .sharedInterpreter, identifier: "node", teamId: "HX7739G8FX", hardenedRuntime: true, requirement: "r")
    #expect(errorDetails(call(s, node, "hub.clients.list"))?["reason"]?.stringValue == "unverified_identity")
    #expect(window.requests.isEmpty, "the user was not asked")
    // Kevin's R1 ruling: not even taking another client's access away.
    for (m, p) in [("hub.grants.set", #"{"clientId":"\#(other)","capabilities":["observe"],"desktops":["created"],"durationSeconds":60}"#),
                   ("hub.grants.revoke", #"{"clientId":"\#(other)"}"#), ("hub.clients.revoke", #"{"clientId":"\#(other)"}"#)] {
        #expect(errorDetails(call(s, script, m, params: p))?["reason"]?.stringValue == "unverified_identity", "\(m) on another client")
    }
    #expect(window.requests.isEmpty && s.hub.client(other)?.state == "active")
    // Giving up its own access: asked, then done.
    #expect(data(call(s, script, "hub.grants.set", params: #"{"clientId":"\#(scriptId)","capabilities":["observe"],"desktops":[],"durationSeconds":60}"#)) != nil)
    #expect(window.requests.last?.details["target"]?["isRequester"] == .bool(true))
    // (narrowing cut its connection: it comes back on a new one)
    let (back, _) = try reconnectAs(s, script)
    #expect(data(call(s, back, "hub.clients.revoke", params: #"{"clientId":"\#(scriptId)"}"#)) != nil)
    #expect(window.requests.map(\.action) == ["hub.grants.set", "hub.clients.revoke"])
    #expect(s.hub.client(scriptId)?.state == "revoked")
}

@Test func revokingAClientOrItsGrantTellsTheServicesNarrowingDoesNot() throws {
    let s = platformService()
    final class Seen: @unchecked Sendable { let lock = NSLock(); var ids: [String] = [] }
    let seen = Seen()
    s.onAccessWithdrawn { id in seen.lock.withLock { seen.ids.append(id) } }
    let owner = handshaken(s)
    let (_, a) = try pairedConnection(s, capabilities: ["observe", "act"], name: "a")
    let (_, b) = try pairedConnection(s, capabilities: ["observe"], name: "b")
    #expect(data(call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(a)","capabilities":["observe"],"desktops":[]}"#)) != nil)
    #expect(seen.lock.withLock { seen.ids }.isEmpty, "a narrower grant keeps its approved work")
    #expect(data(call(s, owner, "hub.grants.revoke", params: #"{"clientId":"\#(a)"}"#)) != nil)
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(b)"}"#)) != nil)
    #expect(seen.lock.withLock { seen.ids } == [a, b])
}

// MARK: Round-four review H1: what was approved applies only to what was shown

@Test(arguments: ["revokeGrant", "narrow"], [false, true])
func anApprovedChangeDoesNotUndoWhatTheOwnerDidWhileTheUserWasAsked(_ ownerAction: String, _ verified: Bool) throws {
    let s = platformService()
    let owner = handshaken(s)
    // A verified client changes another's grant; an unverified one only its own.
    let (app, askerId) = try pairedConnection(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"], name: "asker")
    if verified { asVerified(app) }
    let b = verified ? try pairedConnection(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"], name: "b").1 : askerId
    // The owner acts while the window is up; then the user approves.
    s.confirmer = FakeConfirmer { r in
        if ownerAction == "revokeGrant" {
            _ = call(s, owner, "hub.grants.revoke", params: #"{"clientId":"\#(b)"}"#)
        } else {
            _ = call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(b)","capabilities":["observe"],"desktops":[]}"#)
        }
        return .approved(digest: r.digest)
    }
    let before = try #require(s.hub.grant(b))
    // A "narrowing" of what B had when the window opened.
    let r = call(s, app, "hub.grants.set", params: #"{"clientId":"\#(b)","capabilities":["observe","act"],"desktops":["created"],"durationSeconds":60}"#)
    #expect(data(r) == nil, "\(ownerAction) verified=\(verified)")
    if verified { #expect(errorDetails(r)?["reason"]?.stringValue == "target_changed") }
    let after = try #require(s.hub.grant(b))
    if ownerAction == "revokeGrant" {
        #expect(after.state == "revoked", "the owner's revocation holds")
    } else {
        #expect(after.capabilities == ["observe"] && after.desktops.isEmpty, "the owner's narrowing holds")
    }
    #expect(after.revision == before.revision + 1, "only the owner's change was applied")
}

@Test func anUnverifiedClientsNarrowingNeverExtendsTheExpiry() async throws {
    try await offPoolConfirm {
        let s = platformService()
        s.confirmer = FakeConfirmer { r in Thread.sleep(forTimeInterval: 1.2); return .approved(digest: r.digest) }
        // Its own grant: the only one an unverified client may narrow.
        let (app, b) = try pairedConnection(s, capabilities: ["observe", "act"], name: "asker")
        var g = try #require(s.hub.grant(b))
        g.expiresAt = Timestamp.string(Date().addingTimeInterval(30))
        try s.hub.putGrant(g)
        let old = g.expiresAt
        // Just under what is left: a narrowing when asked, longer by the time it
        // took to answer. Refused on the second look, or clamped: never later.
        _ = call(s, app, "hub.grants.set", params: #"{"clientId":"\#(b)","capabilities":["observe"],"desktops":[],"durationSeconds":29}"#)
        #expect(try #require(s.hub.grant(b)).expiresAt <= old, "the user's time to answer did not become extra grant time")
        // Well within (from a fresh connection: a narrowing cuts the old one):
        // applied, and still not later.
        let (again, _) = try reconnectAs(s, app)
        #expect(data(call(s, again, "hub.grants.set", params: #"{"clientId":"\#(b)","capabilities":["observe"],"desktops":[],"durationSeconds":10}"#)) != nil,
                "a real narrowing of its own grant is applied")
        #expect(try #require(s.hub.grant(b)).expiresAt <= old)
    }
}

@Test func aConfirmedCallNeverBringsBackARevokedGrant() throws {
    let s = platformService()
    let owner = handshaken(s)
    s.confirmer = FakeConfirmer()
    let (app, _) = try pairedConnection(s, capabilities: ["observe"], name: "asker")
    asVerified(app)
    let (_, b) = try pairedConnection(s, capabilities: ["observe"], name: "b")
    #expect(data(call(s, owner, "hub.grants.revoke", params: #"{"clientId":"\#(b)"}"#)) != nil)
    let r = call(s, app, "hub.grants.set", params: #"{"clientId":"\#(b)","capabilities":["observe"],"desktops":[]}"#)
    #expect(errorDetails(r)?["reason"]?.stringValue == "grant_not_active")
    #expect(s.hub.grant(b)?.state == "revoked")
}

/// Round-four review M2: the owner revokes a client while a confirmed AI call
/// of it is still being served; what that call started is cancelled after
/// it, and its answer is not given.
@Test func aServiceCallThatOutlivesTheRevocationIsCleanedUpAfterIt() throws {
    let s = platformService()
    let owner = handshaken(s)
    s.confirmer = FakeConfirmer()
    let (app, id) = try pairedConnection(s, capabilities: ["observe"], name: "verified-app")
    asVerified(app)
    final class Log: @unchecked Sendable { let lock = NSLock(); var withdrawn = 0; var started = 0 }
    let log = Log()
    s.onAccessWithdrawn { _ in log.lock.withLock { log.withdrawn += 1 } }
    s.registerExtensions(["ai.models.refresh": { _ in
        // The revocation lands while the service is working...
        _ = call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)
        // ...and only then does the service start its operation.
        log.lock.withLock { log.started += 1 }
        return .success(.obj([("operationId", .string("op_1")), ("state", .string("queued"))]))
    }])
    let r = call(s, app, "ai.models.refresh", params: #"{"connectionId":"conn_1","expectedRevision":1}"#)
    #expect(code(r) != nil, "\(r.json.encoded())")
    #expect(log.lock.withLock { log.started } == 1)
    #expect(log.lock.withLock { log.withdrawn } == 2, "once by the revocation, once more after the call")
    #expect(data(r) == nil, "the revoked client does not get the answer")
}

@Test func aClientRefusedByTheUserCannotAskAgainAtOnce() throws {
    let s = platformService()
    let window = FakeConfirmer { _ in .denied }
    s.confirmer = window
    let (app, _) = try pairedConnection(s, capabilities: ["observe"], name: "pest")
    asVerified(app)
    let (_, b) = try pairedConnection(s, capabilities: ["observe"], name: "b")
    #expect(errorDetails(call(s, app, "hub.clients.revoke", params: #"{"clientId":"\#(b)"}"#))?["reason"]?.stringValue == "user_denied")
    #expect(errorDetails(call(s, app, "hub.clients.revoke", params: #"{"clientId":"\#(b)"}"#))?["reason"]?.stringValue == "confirmation_cooldown")
    #expect(window.requests.count == 1, "the user was asked once")
}

@Test func strangersAndPairedClientsTogetherCannotFlushAccessDecisions() throws {
    let s = platformService()
    s.hub.auditKeptUnpaired = 30
    s.hub.auditKeptRefusals = 60
    s.hub.auditKept = 80
    s.hub.auditPruneEvery = 10
    let owner = handshaken(s)
    let (_, victim) = try pairedConnection(s, capabilities: ["observe"], name: "victim")
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(victim)"}"#)) != nil)
    let (noisy, _) = try pairedConnection(s, capabilities: ["observe"], name: "noisy")
    for _ in 0..<300 { _ = call(s, noisy, "hub.clients.list") }      // unverified_identity, no prompt
    let events = s.hub.auditEvents(limit: 10_000)
    #expect(events.contains { $0["clientId"]?.stringValue == victim && $0["decision"]?.stringValue == "revoked" })
    #expect(events.filter { $0["decision"]?.stringValue == "denied" }.count <= 70)
}

// MARK: Round-five review

@Test func aPairedAppCannotLaunchByPathBehindAGrantedBundleId() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let (sc, _, _) = try pairedScene(s, platform)   // grant: com.apple.calculator
    // Both named: refused before the platform (by the path check first, and
    // the contract's oneOf would refuse it too).
    let both = call(s, sc.c, "app.launch", params: #"{"desktopId":"\#(sc.desktop)","bundleId":"com.apple.calculator","path":"/System/Applications/Notes.app"}"#)
    #expect(code(both) == "grant_missing" || code(both) == "schema_invalid")
    // A path alone: no app identity the grant could name.
    let path = call(s, sc.c, "app.launch", params: #"{"desktopId":"\#(sc.desktop)","path":"/System/Applications/Notes.app"}"#)
    #expect(code(path) == "grant_missing" && errorDetails(path)?["reason"]?.stringValue == "launch_requires_grant")
    #expect(platform.calls.filter { $0.hasPrefix("launch") }.isEmpty)
    #expect(data(call(s, sc.c, "app.launch", params: #"{"desktopId":"\#(sc.desktop)","bundleId":"com.apple.calculator"}"#)) != nil)
}

@Test func aNarrowingDuringAServiceCallDoesNotCancelTheClientsWork() throws {
    let s = platformService()
    let owner = handshaken(s)
    s.confirmer = FakeConfirmer()
    let (app, id) = try pairedConnection(s, capabilities: ["observe", "act"], name: "verified-app")
    asVerified(app)
    final class Log: @unchecked Sendable { let lock = NSLock(); var withdrawn = 0 }
    let log = Log()
    s.onAccessWithdrawn { _ in log.lock.withLock { log.withdrawn += 1 } }
    s.registerExtensions(["ai.models.refresh": { _ in
        _ = call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(id)","capabilities":["observe"],"desktops":[]}"#)
        return .success(.obj([("operationId", .string("op_1")), ("state", .string("queued"))]))
    }])
    _ = call(s, app, "ai.models.refresh", params: #"{"connectionId":"conn_1","expectedRevision":1}"#)
    #expect(log.lock.withLock { log.withdrawn } == 0, "a narrower grant keeps the client's approved work")
}


@Test func anUnverifiedClientRefusedByTheUserWaitsBeforeAskingAgain() throws {
    let s = platformService()
    let window = FakeConfirmer { _ in .denied }
    s.confirmer = window
    let (app, id) = try pairedConnection(s, capabilities: ["observe", "act"], name: "script")   // same_user
    let narrow = #"{"clientId":"\#(id)","capabilities":["observe"],"desktops":[],"durationSeconds":60}"#
    #expect(errorDetails(call(s, app, "hub.grants.set", params: narrow))?["reason"]?.stringValue == "user_denied")
    #expect(errorDetails(call(s, app, "hub.grants.set", params: narrow))?["reason"]?.stringValue == "confirmation_cooldown")
    #expect(window.requests.count == 1)
}

@Test func aClientNarrowingItsOwnGrantNeverEndsLaterWhateverItsIdentity() async throws {
    try await offPoolConfirm {
        for verified in [false, true] {
            let s = platformService()
            s.confirmer = FakeConfirmer { r in Thread.sleep(forTimeInterval: 0.3); return .approved(digest: r.digest) }
            let (app, id) = try pairedConnection(s, capabilities: ["observe", "act"], name: "self")
            if verified { asVerified(app) }
            var g = try #require(s.hub.grant(id))
            g.expiresAt = Timestamp.string(Date().addingTimeInterval(20))
            try s.hub.putGrant(g)
            let old = g.expiresAt
            _ = call(s, app, "hub.grants.set", params: #"{"clientId":"\#(id)","capabilities":["observe"],"desktops":[],"durationSeconds":19}"#)
            #expect(try #require(s.hub.grant(id)).expiresAt <= old, "verified=\(verified)")
        }
    }
}
