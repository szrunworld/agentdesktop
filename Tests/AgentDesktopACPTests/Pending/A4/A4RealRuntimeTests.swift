import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// A4 behaviours B1–B6 against a REAL Runtime test copy.
//
// Layer: Real · not run. Every test is disabled until A4 (PR3, f1) lands
// the contract proposed in docs/acp/10-a4-identity.md §五. They speak raw
// runtime/1 lines so they compile today; the proposed fields (handshake
// `auth`, `principal`, `hub.pairing.*` params, `credential_*` codes) are
// PROPOSALS and will be aligned to whatever f1 freezes.
//
// Run only against a Runtime this test process launched and owns
// (ACPTestRuntimeChild, ACP_TEST_RUNTIME_BINARY), never the product endpoint.

private let waitingForA4 = "waiting for A4: Runtime identity (handshake principal, pairing, credentials, revocation) — PR3, f1"

/// One raw runtime/1 connection to the scratch Runtime.
final class A4TestLiveConnection {
    let transport: RuntimeTransport
    private(set) var principal: JSONValue?
    /// Nothing but the handshake is sent until the stated endpoint passed.
    private var verified = false

    /// Kernel-pinned: the peer must be the Runtime child this test process
    /// launched (ACPTestRuntimeChild, ACP_TEST_RUNTIME_BINARY), checked
    /// before any byte is sent.
    init() throws {
        let child = try ACPTestRuntimeChild.shared()
        transport = try ACPTestPinnedTransport(path: child.runtimeEndpoint, timeout: 5, child: child)
    }

    deinit { transport.close() }

    func send(_ method: String, _ params: JSONValue = .obj([]), requestId: String = RuntimeRequest.newId())
        throws -> Result<JSONValue, RuntimeError> {
        guard verified || method == "runtime.handshake" else {
            throw RuntimeError("invalid_argument", "no request before a verified handshake", phase: .local)
        }
        let request = RuntimeRequest(requestId: requestId, method: method, params: params)
        let line = try transport.exchange(request.json.encodedData())
        let v = try StrictJSON.parse(line)
        if v["ok"]?.boolValue == true, let data = v["data"] { return .success(data) }
        return .failure(v["error"].flatMap(RuntimeError.init(json:)) ?? RuntimeError("internal_error", "no error", phase: .transport))
    }

    /// PROPOSED: `auth` in runtime_handshake_params (§五 P1).
    func handshake(auth: JSONValue?) throws -> Result<JSONValue, RuntimeError> {
        var params: [(String, JSONValue)] = [
            ("apiVersions", .array(RuntimeAPI.supportedVersions.map(JSONValue.string))),
            ("client", .obj([("name", .string("a4-real-test")), ("version", .string("0"))])),
        ]
        if let auth { params.append(("auth", auth)) }
        let r: Result<JSONValue, RuntimeError>
        do { r = try send("runtime.handshake", .obj(params)) } catch { transport.close(); throw error }
        switch r {
        case let .success(id):
            // Post-connect check before any other request (TOCTOU, Kevin on #141).
            do { try ACPTestEndpointGuard.verify(statedEndpoint: id["endpoint"]?.stringValue) } catch {
                transport.close(); throw error
            }
            principal = id["principal"]
            verified = true
        case .failure:
            // A refused handshake ends the connection (b9 on #141).
            transport.close()
        }
        return r
    }

    static func owner() throws -> A4TestLiveConnection {
        let c = try A4TestLiveConnection()
        _ = try c.handshake(auth: nil).get()
        return c
    }

    static func app(credential: String?) throws -> (A4TestLiveConnection, Result<JSONValue, RuntimeError>) {
        let c = try A4TestLiveConnection()
        var auth: [(String, JSONValue)] = [("scheme", .string("client_credential"))]
        if let credential { auth.append(("credential", .string(credential))) }
        return (c, try c.handshake(auth: .obj(auth)))
    }

    /// PROPOSED pairing flow (04 §4.2): the app starts, the owner approves,
    /// the app reads its credential once from hub.pairing.status.
    static func pairApp(name: String, capabilities: [String] = ["observe", "act", "unit.run"]) throws -> String {
        let (app, hello) = try A4TestLiveConnection.app(credential: nil)
        _ = try hello.get() // a failed handshake stops pairing here
        let start = try app.send("hub.pairing.start", .obj([
            ("agentName", .string(name)), ("publisher", .string("a4-test")),
            ("requested", .obj([("capabilities", .array(capabilities.map(JSONValue.string))),
                                ("duration", .string("PT1H"))])),
        ])).get()
        let pairingId = start["pairingId"]?.stringValue ?? ""
        _ = try owner().send("hub.pairing.approve", .obj([("pairingId", .string(pairingId)),
                                                          ("capabilities", .array(capabilities.map(JSONValue.string)))])).get()
        let status = try app.send("hub.pairing.status", .obj([("pairingId", .string(pairingId))])).get()
        return status["credential"]?.stringValue ?? ""
    }
}

private func code(_ r: Result<JSONValue, RuntimeError>) -> String? {
    if case let .failure(e) = r { return e.code }
    return nil
}

@Suite("A4 [Real·not run] Runtime identity acceptance", .tags(.a4Real), .serialized)
struct A4RealRuntimeTests {
    // B1
    @Test("[Real·not run] B1 unpaired app: handshake works, everything else is pairing_required",
          .disabled(Comment(rawValue: waitingForA4)))
    func unpairedClientCannotAuthorize() throws {
        let (app, hs) = try A4TestLiveConnection.app(credential: nil)
        #expect((try? hs.get()) != nil)
        #expect(app.principal == nil || app.principal == .null)
        for method in ["run.list", "desktop.list", "unit.run", "hub.grants.set", "hub.pairing.approve"] {
            #expect(code(try app.send(method)) == "pairing_required", "\(method)")
        }
        #expect((try? app.send("runtime.capabilities").get()) != nil)
    }

    // B2
    @Test("[Real·not run] B2 clientId in params is refused or ignored; the principal is the Runtime's",
          .disabled(Comment(rawValue: waitingForA4)))
    func clientIdCannotBeForged() throws {
        let credA = try A4TestLiveConnection.pairApp(name: "a4-A")
        let credB = try A4TestLiveConnection.pairApp(name: "a4-B")
        let (b, _) = try A4TestLiveConnection.app(credential: credB)
        let bId = b.principal?["clientId"]?.stringValue
        let (a, _) = try A4TestLiveConnection.app(credential: credA)
        let aId = try #require(a.principal?["clientId"]?.stringValue)
        #expect(aId != bId)
        // Filtering by another clientId shows nothing of theirs.
        let list = try a.send("run.list", .obj([("clientId", .string(bId ?? ""))])).get()
        for run in list["runs"]?.arrayValue ?? [] { #expect(run["clientId"]?.stringValue == aId) }
        // Identity in unit.run params is a schema error, not an override.
        let forged = try a.send("unit.run", .obj([("desktopId", .string("desk_none")), ("clientId", .string(bId ?? "")),
                                                   ("mode", .string("explore")), ("goal", .obj([("description", .string("x"))])),
                                                   ("verification", .obj([])), ("allowedActions", .array([]))]))
        #expect(code(forged) == "schema_invalid")
        // A handshake cannot claim a principal either.
        let (c, hs) = try A4TestLiveConnection.app(credential: credA)
        _ = c
        #expect(code(hs) == nil)
    }

    // B3
    @Test("[Real·not run] B3 invalid, expired and revoked credentials are refused at handshake",
          .disabled(Comment(rawValue: waitingForA4)))
    func badCredentialsAreRefused() throws {
        let (_, invalid) = try A4TestLiveConnection.app(credential: "adt_cred_not_a_real_one")
        #expect(code(invalid) == "credential_invalid")

        // Expiry: the scratch Runtime is started with a 2 s credential TTL
        // (proposed test knob, §四 Q7).
        let short = try A4TestLiveConnection.pairApp(name: "a4-expiring")
        Thread.sleep(forTimeInterval: 3)
        let (_, expired) = try A4TestLiveConnection.app(credential: short)
        #expect(code(expired) == "credential_expired")

        let doomed = try A4TestLiveConnection.pairApp(name: "a4-revoked")
        let (probe, _) = try A4TestLiveConnection.app(credential: doomed)
        let clientId = probe.principal?["clientId"]?.stringValue ?? ""
        _ = try A4TestLiveConnection.owner().send("hub.clients.revoke", .obj([("clientId", .string(clientId))])).get()
        let (_, revoked) = try A4TestLiveConnection.app(credential: doomed)
        #expect(code(revoked) == "client_revoked")
    }

    // B4
    @Test("[Real·not run] B4 a paired client cannot read, cancel or follow another client's Run",
          .disabled(Comment(rawValue: waitingForA4 + "; also A6 unit.run for a real Run")))
    func noCrossClientRunAccess() throws {
        let (a, _) = try A4TestLiveConnection.app(credential: try A4TestLiveConnection.pairApp(name: "a4-owner-of-run"))
        let (b, _) = try A4TestLiveConnection.app(credential: try A4TestLiveConnection.pairApp(name: "a4-intruder"))
        let runs = try a.send("run.list").get()["runs"]?.arrayValue ?? []
        let runId = try #require(runs.first?["runId"]?.stringValue, "start a Run on A first (runbook §五)")
        #expect(code(try b.send("run.show", .obj([("runId", .string(runId))]))) == "not_found")
        #expect(code(try b.send("run.cancel", .obj([("runId", .string(runId))]))) == "not_found")
        #expect(code(try b.send("run.events", .obj([("runId", .string(runId))]))) == "not_found")
        #expect(code(try b.send("events.subscribe", .obj([("runId", .string(runId))]))) == "not_found")
        let bList = try b.send("run.list").get()["runs"]?.arrayValue ?? []
        #expect(!bList.contains { $0["runId"]?.stringValue == runId })
        #expect(try a.send("run.show", .obj([("runId", .string(runId))])).get()["phase"]?.stringValue != "ended")
    }

    // B5
    @Test("[Real·not run] B5 revocation cuts an open connection: no new actions, its Runs stop",
          .disabled(Comment(rawValue: waitingForA4)))
    func revocationCutsInFlightConnection() throws {
        let cred = try A4TestLiveConnection.pairApp(name: "a4-live-revoke")
        let (app, _) = try A4TestLiveConnection.app(credential: cred)
        let clientId = try #require(app.principal?["clientId"]?.stringValue)
        #expect((try? app.send("run.list").get()) != nil)
        _ = try A4TestLiveConnection.owner().send("hub.clients.revoke", .obj([("clientId", .string(clientId))])).get()
        // The SAME connection, still open, can no longer start or act.
        for method in ["unit.run", "run.start", "act", "observe", "desktop.create"] {
            let r = try? app.send(method)
            #expect(r.flatMap(code) == "client_revoked" || r == nil, "\(method)")
        }
        // Its Delegated Runs are stopping or ended (closingReason proposed: grant_revoked).
        for run in try A4TestLiveConnection.owner().send("run.list", .obj([("clientId", .string(clientId))])).get()["runs"]?.arrayValue ?? [] {
            #expect(["stopping", "ended"].contains(run["phase"]?.stringValue ?? ""))
        }
    }

    // B6
    @Test("[Real·not run] B6 auth errors carry no credential, principal detail or foreign data",
          .disabled(Comment(rawValue: waitingForA4)))
    func authErrorsLeakNothing() throws {
        let probe = "adt_cred_probe_7f3a9c2e5b1d4f6a8c0e2b4d6f8a"
        let (_, invalid) = try A4TestLiveConnection.app(credential: probe)
        guard case let .failure(e) = invalid else { Issue.record("an invalid credential was accepted"); return }
        let text = e.json.encoded()
        #expect(!text.contains(probe))
        #expect(!text.contains("adt_cred_"))
        // Details only name a reason class, never the credential or another client.
        let keys = Set(e.details?.objectMembers?.map(\.key) ?? [])
        #expect(keys.isSubset(of: ["reason"]))
    }
}
