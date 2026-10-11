import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// #203 (Kevin 2026-10-10, P1): a paired client's ai.* call whose access is
// withdrawn while the service works. A read's answer is withheld and nothing
// it did reaches outside; a write the service already did is never reported
// as not performed (runtime-api-v1-freeze §1.1), its answer still withheld.

private func notSent(_ r: RuntimeResponse) -> Bool? {
    if case let .failure(e) = r.result { return e.notSent }
    return nil
}

/// A verified paired app whose grant expires inside the service's handler,
/// which then answers `outcome`; the call's response, and the scene.
private func expiringDuring(_ method: String, params: String = #"{"connectionId":"conn_1","expectedRevision":1}"#,
                            id: String = RuntimeRequest.newId(),
                            outcome: Result<JSONValue, RuntimeError>) throws -> (RuntimeResponse, RuntimeService, String) {
    let s = platformService()
    s.confirmer = FakeConfirmer()
    let (app, clientId) = try pairedConnection(s, capabilities: ["observe"], name: "verified-app")
    asVerified(app)
    s.registerExtensions([method: { _ in
        var g = s.hub.grant(clientId)!
        g.expiresAt = Timestamp.string(Date().addingTimeInterval(-1))
        try? s.hub.putGrant(g)
        return outcome
    }])
    return (call(s, app, method, id: id, params: params), s, clientId)
}

@Test func aWriteDoneBeforeTheGrantExpiredIsNeverNotPerformed() throws {
    let id = "w203-expired-0001"
    let (r, s, clientId) = try expiringDuring("ai.models.refresh", id: id,
                                              outcome: .success(.obj([("operationId", .string("op_1")), ("state", .string("queued"))])))
    #expect(code(r) == "grant_expired", "\(r.json.encoded())")
    #expect(data(r) == nil, "the answer is withheld")
    #expect(notSent(r) == false, "a write the service did is not 'not performed'")
    #expect(errorDetails(r)?["writeOutcome"]?.stringValue == "completed")
    #expect(errorDetails(r)?["reason"]?.stringValue == "grant_expired", "the refusal's own reason is kept")
    // The client keeps its id: the same requestId reads the outcome.
    #expect(errorDetails(r)?["recovery"]?.stringValue == "look_up_same_request_id")
    // The ledger holds the write as done: the same requestId is never a new write.
    #expect(try s.ledger.record(caller: clientId, requestId: id)?.state == .completed)
}

@Test func aReadAnsweredAfterTheGrantExpiredIsWithheldAsBefore() throws {
    let (r, _, _) = try expiringDuring("ai.connections.list", params: "{}", outcome: .success(.obj([("items", .array([]))])))
    #expect(code(r) == "grant_expired")
    #expect(data(r) == nil)
    #expect(notSent(r) == true, "a read sent nothing out")
    #expect(errorDetails(r)?["writeOutcome"] == nil)
}

// A revocation cuts the connection; the refusal it gives a completed write is
// the same: withheld, not 'not performed'.
@Test func aWriteDoneBeforeTheClientWasRevokedIsNeverNotPerformed() throws {
    let s = platformService()
    let owner = handshaken(s)
    s.confirmer = FakeConfirmer()
    let (app, clientId) = try pairedConnection(s, capabilities: ["observe"], name: "verified-app")
    asVerified(app)
    s.registerExtensions(["ai.models.refresh": { _ in
        _ = call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(clientId)"}"#)
        return .success(.obj([("operationId", .string("op_1")), ("state", .string("queued"))]))
    }])
    let r = call(s, app, "ai.models.refresh", id: "w203-revoked-0001", params: #"{"connectionId":"conn_1","expectedRevision":1}"#)
    #expect(code(r) == "client_revoked", "\(r.json.encoded())")
    #expect(data(r) == nil)
    #expect(notSent(r) == false)
    #expect(errorDetails(r)?["writeOutcome"]?.stringValue == "completed")
    // Codex on 38edddd: pairing again gives a new client id the ledger does
    // not know, so no advice to replay the requestId.
    #expect(errorDetails(r)?["recovery"]?.stringValue == "check_outcome_do_not_resubmit")
    if case let .failure(e) = r.result { #expect(!e.message.contains("same requestId"), "\(e.message)") }
    #expect(s.hub.client(clientId)?.state == "revoked")
}

// What the service itself answered is passed on as it was: a refusal before
// any effect, and an outcome it could not confirm (never turned into either
// 'not performed' or 'done').
@Test func aWritesOwnFailureOrUnknownOutcomeIsPassedOnUnchanged() throws {
    let refused = RuntimeError("not_found", "no connection conn_1", phase: .handler, notSent: true)
    let (r1, _, _) = try expiringDuring("ai.models.refresh", outcome: .failure(refused))
    #expect(code(r1) == "not_found" && notSent(r1) == true && errorDetails(r1)?["writeOutcome"] == nil)

    let unknown = RuntimeError("request_acceptance_unknown", "the AI service did not answer in time", phase: .handler,
                               details: .obj([("requestId", .string("x"))]))
    let (r2, _, _) = try expiringDuring("ai.models.refresh", outcome: .failure(unknown))
    #expect(code(r2) == "request_acceptance_unknown" && notSent(r2) != true && errorDetails(r2)?["writeOutcome"] == nil)
}

@Test func unknownAiCreateIsResolvedUnderTheSameKey() throws {
    let s = platformService()
    let owner = handshaken(s)
    final class Outcomes: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var keys: [String] = []
        func answer(_ call: ExtensionCall) -> Result<JSONValue, RuntimeError> {
            lock.withLock {
                calls += 1
                keys.append(call.requestId)
                if calls == 1 { return .failure(RuntimeError("request_acceptance_unknown", "answer lost", phase: .handler)) }
                return .success(.obj([("connectionId", .string("conn_recovered"))]))
            }
        }
    }
    let outcomes = Outcomes()
    s.registerExtensions(["ai.connections.create": { outcomes.answer($0) }])
    let id = "recover-create-0001"
    #expect(code(call(s, owner, "ai.connections.create", id: id, params: "{}")) == "request_acceptance_unknown")
    #expect(code(call(s, owner, "ai.connections.create", id: id, params: #"{"name":"changed"}"#)) == "idempotency_conflict")
    let recovered = call(s, owner, "ai.connections.create", id: id, params: "{}")
    #expect(data(recovered)?["connectionId"]?.stringValue == "conn_recovered")
    _ = call(s, owner, "ai.connections.create", id: id, params: "{}")
    #expect(outcomes.calls == 2)
    #expect(outcomes.keys == [id, id])
    #expect(try s.ledger.record(caller: owner.clientId, requestId: id)?.state == .completed)
}
