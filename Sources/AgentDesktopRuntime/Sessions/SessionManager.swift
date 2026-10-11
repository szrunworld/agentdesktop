import AgentDesktopProtocol
import Foundation

/// A calling context on one Desktop. A Session names who acts and where;
/// it is not a credential and holds no input right by itself.
public struct RuntimeSession: Equatable, Sendable {
    public var sessionId: String
    public var desktopId: String
    /// The principal (clientId) the session belongs to.
    public var caller: String
    public var state: String
    public var createdAt: String
    public var closedAt: String?

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [("sessionId", .string(sessionId)), ("desktopId", .string(desktopId)),
                                        ("state", .string(state)), ("createdAt", .string(createdAt))]
        if let closedAt { m.append(("closedAt", .string(closedAt))) }
        return .obj(m)
    }
}

public final class SessionManager: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: RuntimeSession] = [:]

    public init() {}

    func open(desktopId: String, caller: String, at: String) -> RuntimeSession {
        let s = RuntimeSession(sessionId: DesktopRegistry.newId(prefix: "s"), desktopId: desktopId, caller: caller,
                               state: "open", createdAt: at)
        lock.withLock { sessions[s.sessionId] = s }
        return s
    }

    /// Close every open session of `caller` (its access was revoked).
    @discardableResult
    func closeAll(caller: String, at: String) -> [String] {
        lock.withLock {
            var closed: [String] = []
            for (id, var s) in sessions where s.caller == caller && s.state == "open" {
                s.state = "closed"
                s.closedAt = at
                sessions[id] = s
                closed.append(id)
            }
            return closed
        }
    }

    /// Close every open session on a Desktop, or only `caller`'s there
    /// (the owner took the Desktop out of its grant).
    @discardableResult
    func closeAll(desktopId: String, caller: String? = nil, at: String) -> [String] {
        lock.withLock {
            var closed: [String] = []
            for (id, var s) in sessions where s.desktopId == desktopId && s.state == "open" && (caller == nil || s.caller == caller) {
                s.state = "closed"
                s.closedAt = at
                sessions[id] = s
                closed.append(id)
            }
            return closed
        }
    }

    /// Implicit sessions opened for an act and not yet handed to another
    /// request: the act that opened one may close it again if it fails.
    private var unshared: Set<String> = []

    /// `caller`'s oldest open session on a Desktop, else a new one, in one
    /// step (act's implicit session); whether it was opened now.
    func firstOpenOrOpen(desktopId: String, caller: String, at: String) -> (RuntimeSession, Bool) {
        lock.withLock {
            if let s = sessions.values.filter({ $0.desktopId == desktopId && $0.caller == caller && $0.state == "open" })
                .min(by: { ($0.createdAt, $0.sessionId) < ($1.createdAt, $1.sessionId) }) {
                // Reused: from now on another request may be acting in it.
                unshared.remove(s.sessionId)
                return (s, false)
            }
            let s = RuntimeSession(sessionId: DesktopRegistry.newId(prefix: "s"), desktopId: desktopId, caller: caller,
                                   state: "open", createdAt: at)
            sessions[s.sessionId] = s
            unshared.insert(s.sessionId)
            return (s, true)
        }
    }

    /// Close an implicit session its failed act opened, unless another
    /// request has reused it meanwhile; whether it was closed. One step, so
    /// a concurrent act either reused it before (it stays open) or finds it
    /// closed and opens its own.
    @discardableResult
    func closeIfUnshared(_ id: String, at: String) -> Bool {
        lock.withLock {
            guard unshared.remove(id) != nil, var s = sessions[id], s.state == "open" else { return false }
            s.state = "closed"
            s.closedAt = at
            sessions[id] = s
            return true
        }
    }

    /// The act that opened it succeeded: an ordinary session from now on.
    func keep(_ id: String) { lock.withLock { _ = unshared.remove(id) } }

    /// Whether a session of this id exists at all, whoever's.
    func exists(_ id: String) -> Bool { lock.withLock { sessions[id] != nil } }

    /// The session if `caller` may use it.
    public func find(_ id: String, caller: String) -> RuntimeSession? {
        lock.withLock { sessions[id].flatMap { $0.caller == caller ? $0 : nil } }
    }

    func close(_ id: String, at: String) -> RuntimeSession? {
        lock.withLock {
            guard var s = sessions[id] else { return nil }
            if s.state == "open" {
                s.state = "closed"
                s.closedAt = at
                sessions[id] = s
            }
            return s
        }
    }

    public func openCount(desktopId: String) -> Int {
        lock.withLock { sessions.values.filter { $0.desktopId == desktopId && $0.state == "open" }.count }
    }

    public var openCount: Int { lock.withLock { sessions.values.filter { $0.state == "open" }.count } }
    func openCount(caller: String) -> Int { lock.withLock { sessions.values.filter { $0.state == "open" && $0.caller == caller }.count } }
}
