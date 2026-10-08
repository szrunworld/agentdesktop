import AgentDesktopProtocol
import CryptoKit
import Foundation

/// One thing the user is asked to allow (A4 S1): a pairing, or one call of
/// a method only the owner may make, asked for by a socket client. The
/// decision is bound to `digest`, computed from exactly what will be applied;
/// an approval for anything else is refused.
public struct ConfirmationRequest: Sendable {
    public enum Kind: String, Sendable { case pairing, adminCall }
    public let confirmationId: String
    public let kind: Kind
    /// Who asks: clientId, agentName, publisher, codeIdentity, callerFacts.
    public let requester: JSONValue
    /// `hub.pairing.start` for a pairing, else the method to call.
    public let action: String
    /// The grant a pairing would get, or the call's params: shown, and applied
    /// exactly as shown.
    public let details: JSONValue
    /// The pairing's short code, for the user to compare with the app's.
    public let shortCode: String?
    public let digest: String
    public let deadline: Date

    /// The window recomputes this from what it displayed; an approval counts
    /// only when it matches the Runtime's.
    public static func digest(kind: Kind, requester: String, action: String, details: JSONValue) -> String {
        let canonical = JSONValue.obj([("kind", .string(kind.rawValue)), ("requester", .string(requester)),
                                       ("action", .string(action)), ("details", details)]).encoded()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ConfirmationDecision: Sendable, Equatable {
    /// The user approved the request with this digest.
    case approved(digest: String)
    case denied
    case cancelled
    case timedOut
    /// No trusted way to ask (no window, no user authentication): refuse.
    case unavailable(String)
}

/// The host's trusted user interface. `confirm` blocks until the user
/// answers or the deadline passes; it is never called on the main thread.
public protocol TrustedConfirmer: Sendable {
    func confirm(_ request: ConfirmationRequest) -> ConfirmationDecision
}

/// One confirmation on screen at a time, a short queue, and at most one
/// waiting per client: a client cannot flood the user with prompts.
final class ConfirmationGate: @unchecked Sendable {
    static let maxWaiting = 3
    private let lock = NSLock()
    private let turn = NSLock()
    private var waiting = 0
    private var clients: Set<String> = []

    func admit(_ clientId: String) -> Bool {
        lock.withLock {
            guard waiting < Self.maxWaiting, !clients.contains(clientId) else { return false }
            waiting += 1
            clients.insert(clientId)
            return true
        }
    }

    func run<T>(_ clientId: String, _ body: () -> T) -> T {
        turn.lock()
        defer {
            turn.unlock()
            lock.withLock { waiting -= 1; clients.remove(clientId) }
        }
        return body()
    }
}

extension RuntimeService {
    /// How long the user has to answer.
    static let confirmationTimeout: TimeInterval = 120
    /// The most an owner call's params may hold to be shown in full.
    static let maxConfirmableParams = 1200

    /// Methods only the owner may call that a paired client may still ask
    /// for, one call at a time, each confirmed by the user in the Agent
    /// Desktop window. Pairing approval is not among them: a pairing asks
    /// the user itself, when it starts. gui.runs.* stays the window's own.
    static let confirmableMethods: Set<String> = {
        var m: Set<String> = ["runtime.stopAll", "runtime.enableInput",
                              "hub.clients.list", "hub.clients.show", "hub.clients.revoke",
                              "hub.grants.list", "hub.grants.set", "hub.grants.revoke", "hub.connections.list"]
        for x in RuntimeContract.shared.methods where x.method.hasPrefix("ai.") { m.insert(x.method) }
        return m
    }()

    func requesterJSON(_ c: ConnectionState, agentName: String? = nil, publisher: String? = nil) -> JSONValue {
        var out: [(String, JSONValue)] = [("clientId", .string(c.clientId)), ("connectionId", .string(c.connectionId))]
        let client = c.role == .paired ? hub.client(c.clientId) : nil
        if let name = agentName ?? client?.agentName { out.append(("agentName", .string(name))) }
        if let p = publisher ?? client?.publisher { out.append(("publisher", .string(p))) }
        out.append(("codeIdentity", c.codeIdentity.json))
        out.append(("callerFacts", c.callerFacts))
        return .obj(out)
    }

    /// Who waits for the user: a paired client by its id; anyone else by the
    /// program the kernel says it runs.
    func gateKey(_ c: ConnectionState) -> String {
        if c.role == .paired { return c.clientId }
        return "peer:" + (c.codeIdentity.identifier ?? c.callerFacts["executable"]?.stringValue ?? c.connectionId)
    }

    /// Ask the user; success only for an approval of exactly this request.
    func confirm(_ kind: ConfirmationRequest.Kind, by c: ConnectionState, action: String, details: JSONValue,
                 agentName: String? = nil, publisher: String? = nil, shortCode: String? = nil,
                 runId: String? = nil) -> Result<Void, RuntimeError> {
        func refuse(_ reason: String, _ message: String) -> Result<Void, RuntimeError> {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: action, decision: "denied", reason: reason, runId: runId)
            return .failure(RuntimeError("permission_denied", message, phase: .handler, notSent: true,
                                         details: .obj([("reason", .string(reason))])))
        }
        guard let confirmer else {
            return refuse("no_trusted_ui", "no trusted window can ask the user to allow \(action); refused")
        }
        // One waiting prompt per program, not per connection: a new
        // connection is not a new requester (review M3).
        let key = gateKey(c)
        guard confirmationGate.admit(key) else {
            return refuse("confirmation_busy", "another request is waiting for the user; ask again later")
        }
        var asked: ConfirmationRequest?
        let decision = confirmationGate.run(key) { () -> ConfirmationDecision in
            // The user's time starts when the window can show (review M3).
            let r = ConfirmationRequest(
                confirmationId: DesktopRegistry.newId(prefix: "conf"), kind: kind,
                requester: requesterJSON(c, agentName: agentName, publisher: publisher), action: action, details: details,
                shortCode: shortCode,
                digest: ConfirmationRequest.digest(kind: kind, requester: c.clientId, action: action, details: details),
                deadline: now().addingTimeInterval(Self.confirmationTimeout))
            asked = r
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: action, decision: "asked", reason: r.confirmationId,
                      runId: runId)
            return confirmer.confirm(r)
        }
        let request = asked!
        switch decision {
        case let .approved(digest) where digest == request.digest && now() <= request.deadline:
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: action, decision: "confirmed",
                      reason: request.confirmationId, runId: runId)
            return .success(())
        case .approved:
            return refuse("confirmation_mismatch", "the approval does not match this request; refused")
        case .denied:
            return refuse("user_denied", "the user denied \(action)")
        case .cancelled:
            return refuse("user_cancelled", "the user cancelled the confirmation of \(action)")
        case .timedOut:
            return refuse("confirmation_timeout", "the user did not answer within \(Int(Self.confirmationTimeout)) s")
        case let .unavailable(why):
            return refuse("no_trusted_ui", "no trusted confirmation is possible (\(why)); refused")
        }
    }

    /// A paired client asks for one owner-only call: refused outright when
    /// it would change the caller's own access, else the user confirms it.
    /// On approval the connection acts as the owner for this request only.
    func confirmAdminCall(_ request: RuntimeRequest, _ c: ConnectionState) -> RuntimeError? {
        let method = request.method
        let target = request.params["clientId"]?.stringValue
        if target == c.clientId, ["hub.grants.set", "hub.grants.revoke"].contains(method) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "self_grant")
            return RuntimeError("permission_denied", "an app cannot change its own grant; the user does that in the Agent Desktop window",
                                phase: .request, notSent: true, details: .obj([("reason", .string("self_grant"))]))
        }
        if let spec = contract.method(method) {
            let v = contract.validate(request.params, spec.params)
            if !v.isEmpty { return .schemaInvalid("params break \(spec.params)", violations: v) }
        }
        // The user must be able to read all of what they approve (review M1).
        guard request.params.encoded().count <= Self.maxConfirmableParams else {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "confirmation_too_large")
            return RuntimeError("permission_denied", "this request is too large to show for confirmation; use the Agent Desktop window",
                                phase: .request, notSent: true, details: .obj([("reason", .string("confirmation_too_large"))]))
        }
        // Who the call is aimed at, as the Runtime knows it (review L3).
        var details: [(String, JSONValue)] = [("params", request.params)]
        if let target, let client = hub.client(target) {
            details.append(("target", .obj([("clientId", .string(target)), ("agentName", .string(client.agentName)),
                                             ("codeIdentity", client.codeIdentity), ("grant", hub.grant(target)?.json ?? .null),
                                             ("sameProgramAsRequester", .bool(CodeIdentity(json: client.codeIdentity).identifier != nil
                                                 && CodeIdentity(json: client.codeIdentity).identifier == c.codeIdentity.identifier))])))
        }
        if case let .failure(e) = confirm(.adminCall, by: c, action: method, details: .obj(details), runId: request.context.runId) {
            return e
        }
        // Access may have gone while the user was deciding.
        if let reason = c.cutReason { return Self.cutError(c, reason) }
        if let e = accessError(c, method: "runtime.status") { return e }
        c.elevate(request.requestId)
        return nil
    }
}
