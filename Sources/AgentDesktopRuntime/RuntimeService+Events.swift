import AgentDesktopProtocol
import Foundation

/// events.subscribe (runtime-api-v1-freeze §4): after the reply the server
/// pushes EventFrame lines on the same connection. A subscription is a
/// view, never a control connection: closing it stops nothing.
final class EventSubscription: @unchecked Sendable {
    /// One Run's events by its sequence, or every visible Run's events by
    /// the global cursor.
    let runId: String?
    /// Nil for the owner, who sees every Run.
    let clientId: String?
    var cursor: Int

    init(runId: String?, clientId: String?, cursor: Int) {
        self.runId = runId
        self.clientId = clientId
        self.cursor = cursor
    }
}

extension RuntimeService {
    func subscribe(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard c.subscription == nil else {
            return .failure(RuntimeError("conflict", "this connection is already subscribed; send events.unsubscribe first",
                                         phase: .handler, details: .obj([("reason", .string("subscribed"))])))
        }
        // The connection of a live Delegated Run is its control connection;
        // a stream that ends by closing it would stop that Run.
        guard !c.ownedRuns.contains(where: { runs.find($0).map { $0.phase != .ended } ?? false }) else {
            return .failure(RuntimeError("conflict", "this connection controls a live Run; subscribe on another connection",
                                         phase: .handler, details: .obj([("reason", .string("control_connection"))])))
        }
        let after = p["after"]?.intValue
        let sub: EventSubscription
        if let runId = p["runId"]?.stringValue {
            switch ownRun(p, c) {
            case let .failure(e): return .failure(e)
            case .success: break
            }
            // A Run's own stream starts at its beginning unless told otherwise.
            sub = EventSubscription(runId: runId, clientId: nil, cursor: after ?? 0)
        } else {
            let range = runs.eventCursorRange()
            if let after, after < range.floor || after > range.latest {
                return .failure(RuntimeError("events_cursor_expired",
                                             "cursor \(after) is outside the stored events (\(range.floor)–\(range.latest)); read current state with run.list",
                                             phase: .handler, details: .obj([("latest", .int(range.latest))])))
            }
            // Without a cursor the stream starts now.
            sub = EventSubscription(runId: nil, clientId: isOwner(c) ? nil : c.clientId, cursor: after ?? range.latest)
        }
        c.subscription = sub
        var reply: [(String, JSONValue)] = [("subscribed", .bool(true)), ("next", .int(sub.cursor))]
        if let runId = sub.runId { reply.insert(("runId", .string(runId)), at: 1) }
        return .success(.obj(reply))
    }

    func unsubscribe(_ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let next = c.subscription?.cursor
        c.subscription = nil
        var reply: [(String, JSONValue)] = [("subscribed", .bool(false))]
        if let next { reply.append(("next", .int(next))) }
        return .success(.obj(reply))
    }

    /// Frames due on a subscribed connection, oldest first; advances its
    /// cursor. Empty when nothing new happened.
    public func pendingEventFrames(_ c: ConnectionState, limit: Int = 100) -> [JSONValue] {
        guard let sub = c.subscription else { return [] }
        let items: [(cursor: Int, event: JSONValue)]
        if let runId = sub.runId {
            items = runs.events(runId, after: sub.cursor, limit: limit).map { ($0["sequence"]?.intValue ?? 0, $0) }
        } else {
            items = runs.eventsSince(sub.cursor, clientId: sub.clientId, limit: limit)
        }
        if let last = items.last { sub.cursor = last.cursor }
        return items.map { .obj([("apiVersion", .string(RuntimeAPI.version)), ("event", $0.event), ("cursor", .int($0.cursor))]) }
    }

    /// Whether a subscribed connection may still expect frames: a Run's own
    /// stream ends once the Run has ended and everything was sent.
    public func subscriptionDrained(_ c: ConnectionState) -> Bool {
        guard let sub = c.subscription, let runId = sub.runId, let r = runs.find(runId), r.phase == .ended else { return false }
        return runs.events(runId, after: sub.cursor, limit: 1).isEmpty
    }
}
