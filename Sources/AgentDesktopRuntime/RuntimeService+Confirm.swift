import AgentDesktopProtocol
import CryptoKit
import Foundation

/// One thing the user is asked to allow (A4 S1): a pairing, or one call of
/// a method only the owner may make, asked for by a socket client. The
/// decision is bound to `digest`, computed from exactly what will be applied;
/// an approval for anything else is refused.
public struct ConfirmationRequest: Sendable {
    public enum Kind: String, Sendable { case pairing, adminCall, windowGrant }
    public let confirmationId: String
    public let kind: Kind
    /// Who asks: clientId, agentName, publisher, codeIdentity, callerFacts.
    public let requester: JSONValue
    /// `hub.pairing.start` for a pairing, `hub.windows.request` for a window
    /// grant, else the method to call.
    public let action: String
    /// The grant a pairing would get, the window, Desktop and permissions a
    /// window grant would cover, or the call's params: shown, and applied
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
    /// After the user says no, the same program waits this long to ask again.
    static let cooldown: TimeInterval = 60
    private var refusedUntil: [String: Date] = [:]
    func coolDown(_ key: String, until: Date) { lock.withLock { refusedUntil[key] = until } }
    func coolingDown(_ key: String, now: Date) -> Bool { lock.withLock { (refusedUntil[key] ?? .distantPast) > now } }
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

final class AccessObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [@Sendable (String) -> Void] = []
    func add(_ o: @escaping @Sendable (String) -> Void) { lock.withLock { list.append(o) } }
    var all: [@Sendable (String) -> Void] { lock.withLock { list } }
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
        var m: Set<String> = ["runtime.enableInput",
                              "hub.clients.list", "hub.clients.show", "hub.clients.revoke",
                              "hub.grants.list", "hub.grants.set", "hub.grants.revoke", "hub.connections.list",
                              "hub.windows.revoke"]
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
        return Self.programKey(callerFacts: c.callerFacts, codeIdentity: c.codeIdentity.json, fallback: c.connectionId)
    }

    /// Owner calls that only take access away (revoke, or a grants.set that
    /// neither adds nor extends anything). An unverified client may ask the
    /// user for these about its own access only.
    func isReductive(_ request: RuntimeRequest) -> Bool {
        switch request.method {
        case "hub.clients.revoke", "hub.grants.revoke", "hub.windows.revoke":
            return true
        case "hub.grants.set":
            let p = request.params
            guard let id = p["clientId"]?.stringValue, let old = hub.grant(id), old.state == "active" else { return false }
            func list(_ v: JSONValue?) -> Set<String> { Set((v?.arrayValue ?? []).compactMap(\.stringValue)) }
            let seconds = Double(p["durationSeconds"]?.intValue ?? Int(Self.defaultGrantDuration))
            return list(p["capabilities"]).isSubset(of: old.capabilities) && list(p["desktops"]).isSubset(of: old.desktops)
                && list(p["apps"]).isSubset(of: old.apps) && Timestamp.string(now().addingTimeInterval(seconds)) <= old.expiresAt
        default:
            return false
        }
    }

    /// Whether a target client paired as the program now asking (review L3):
    /// same requirement, same signing identifier, or same executable file.
    static func sameProgram(_ client: HubStore.Client, _ c: ConnectionState) -> Bool {
        let theirs = CodeIdentity(json: client.codeIdentity)
        if let r = theirs.requirement, r == c.codeIdentity.requirement { return true }
        if let i = theirs.identifier, i == c.codeIdentity.identifier { return true }
        if let e = client.callerFacts["executable"]?.stringValue, e == c.callerFacts["executable"]?.stringValue { return true }
        return false
    }

    /// Who waits after the user said no: verified code by its signing
    /// identifier, anything else by its executable, so starting a new process
    /// does not start over (a refusal holds every script of that interpreter
    /// back for the minute).
    func cooldownKey(_ c: ConnectionState) -> String {
        if c.codeIdentity.level == .verified, let id = c.codeIdentity.identifier { return "code:" + id }
        // No executable known: all such callers share one key (round-four review L5).
        return "exe:" + (c.callerFacts["executable"]?.stringValue ?? "unknown")
    }

    /// One program, for limits: verified code by its signing identifier;
    /// anything else (scripts share an interpreter) by its process, so two
    /// python agents do not block each other (re-review).
    static func programKey(callerFacts: JSONValue, codeIdentity: JSONValue, fallback: String) -> String {
        if codeIdentity["level"]?.stringValue == "verified", let id = codeIdentity["identifier"]?.stringValue { return "code:" + id }
        if let pid = callerFacts["pid"]?.intValue { return "pid:\(pid)" }
        return "conn:" + fallback
    }

    /// Ask the user; success only for an approval of exactly this request.
    func confirm(_ kind: ConfirmationRequest.Kind, by c: ConnectionState, action: String, details: JSONValue,
                 agentName: String? = nil, publisher: String? = nil, shortCode: String? = nil,
                 runId: String? = nil, confirmed: ((String) -> Void)? = nil) -> Result<Void, RuntimeError> {
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
            confirmed?(request.confirmationId)
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
        // A window grant's client is the one whose access it changes; one
        // that does not exist is not worth asking the user about.
        let windowGrant = method == "hub.windows.revoke" ? request.params["windowGrantId"]?.stringValue.flatMap { hub.windowGrant($0) } : nil
        if method == "hub.windows.revoke", windowGrant == nil {
            return .notFound("no window grant \(request.params["windowGrantId"]?.stringValue ?? "")")
        }
        // An app gives up only its own window grants, verified or not (Codex
        // on 09b8f7d); another app's is the user's to take back, in the window.
        if let windowGrant, windowGrant.clientId != c.clientId {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "not_own_window_grant")
            return RuntimeError("permission_denied", "an app can only give up its own window grants",
                                phase: .request, notSent: true, details: .obj([("reason", .string("not_own_window_grant"))]))
        }
        let target = request.params["clientId"]?.stringValue ?? windowGrant?.clientId
        let isSelf = target == c.clientId
        let changesAccess = ["hub.grants.set", "hub.grants.revoke", "hub.clients.revoke", "hub.windows.revoke"].contains(method)
        // Its own access: only ever less of it (Kevin, R1 ruling of 2026-10-09).
        if isSelf, changesAccess, !isReductive(request) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "self_grant")
            return RuntimeError("permission_denied", "an app cannot change its own grant; the user does that in the Agent Desktop window",
                                phase: .request, notSent: true, details: .obj([("reason", .string("self_grant"))]))
        }
        if let spec = contract.method(method) {
            let v = contract.validate(request.params, spec.params)
            if !v.isEmpty { return .schemaInvalid("params break \(spec.params)", violations: v) }
        }
        // A4 R1: code whose identity cannot be bound (same_user, an
        // interpreter) gets no sensitive management, even with the user's
        // confirmation; it may only ask for what takes access away.
        // Kevin's R1 ruling: it may only give up its OWN access (revoke itself,
        // narrow its own grant), never touch another client's.
        if c.codeIdentity.level != .verified, !(isSelf && changesAccess && isReductive(request)) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "unverified_identity")
            return RuntimeError("permission_denied",
                                "\(method) needs a client whose code identity is verified (Developer ID, hardened runtime); an unverified client may only give up its own access",
                                phase: .request, notSent: true, details: .obj([("reason", .string("unverified_identity"))]))
        }
        // Refused by the user a moment ago: not asked again yet (round-four review L5).
        if confirmationGate.coolingDown("admin:" + c.clientId, now: now()) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "confirmation_cooldown")
            return RuntimeError("permission_denied", "the user just refused this client's request; ask again in a minute",
                                phase: .request, notSent: true, details: .obj([("reason", .string("confirmation_cooldown"))]))
        }
        // The user must be able to read all of what they approve (review M1).
        guard request.params.encoded().count <= Self.maxConfirmableParams else {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: "confirmation_too_large")
            return RuntimeError("permission_denied", "this request is too large to show for confirmation; use the Agent Desktop window",
                                phase: .request, notSent: true, details: .obj([("reason", .string("confirmation_too_large"))]))
        }
        // Who the call is aimed at, as the Runtime knows it (review L3).
        var details: [(String, JSONValue)] = [("params", request.params)]
        if let windowGrant { details.append(("windowGrant", windowGrant.json)) }
        // One read of the target's grant: what is shown is the revision used (round-five Low-5).
        let shownGrant = target.flatMap { hub.grant($0) }
        if let target, let client = hub.client(target) {
            details.append(("target", .obj([("clientId", .string(target)), ("agentName", .string(client.agentName)),
                                             ("codeIdentity", client.codeIdentity), ("grant", shownGrant?.json ?? .null),
                                             ("isRequester", .bool(target == c.clientId)),
                                             ("sameProgramAsRequester", .bool(target != c.clientId && Self.sameProgram(client, c)))])))
        }
        // What the user is shown is this revision of the target's grant; the
        // change applies to that revision only (round-four review H1).
        let seenRevision = shownGrant?.revision
        if case let .failure(e) = confirm(.adminCall, by: c, action: method, details: .obj(details), runId: request.context.runId) {
            if ["user_denied", "user_cancelled", "confirmation_timeout"].contains(e.details?["reason"]?.stringValue ?? "") {
                confirmationGate.coolDown("admin:" + c.clientId, until: now().addingTimeInterval(ConfirmationGate.cooldown))
            }
            return e
        }
        // Access may have gone while the user was deciding.
        if let reason = c.cutReason { return Self.cutError(c, reason) }
        if let e = accessError(c, method: "runtime.status") { return e }
        // The target changed meanwhile (the owner revoked or narrowed it):
        // what was approved no longer means the same; nothing is applied.
        // Checked again, each with its own reason (focused review L3).
        let recheck: (String, String)? = {
            if let target, hub.grant(target)?.revision != seenRevision { return ("target_changed", "\(target) changed while the user was asked; ask again") }
            if isSelf, changesAccess, !isReductive(request) { return ("self_grant", "by now this would not only take access away; ask again") }
            if c.codeIdentity.level != .verified, !(isSelf && changesAccess && isReductive(request)) {
                return ("unverified_identity", "an unverified client may only give up its own access")
            }
            return nil
        }()
        if let (reason, message) = recheck {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: reason)
            return RuntimeError(reason == "target_changed" ? "conflict" : "permission_denied", message, phase: .handler, notSent: true,
                                details: .obj([("reason", .string(reason))]))
        }
        c.elevate(request.requestId, targetRevision: seenRevision)
        return nil
    }
}
