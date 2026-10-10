import AgentDesktopProtocol
import Foundation

/// One read-only stream per connection. It has no Run, lease or actionable
/// snapshot. Monotonic scheduling skips missed frames rather than catching up.
final class ObservationSubscription: @unchecked Sendable {
    let id: String
    let context: RequestContext
    let params: JSONValue
    let fps: Int
    private let lock = NSLock()
    private var next: ContinuousClock.Instant
    private var sequence = 0
    init(context: RequestContext, params: JSONValue, now: ContinuousClock.Instant) {
        self.id = DesktopRegistry.newId(prefix: "view")
        self.context = context
        self.params = params
        self.fps = params["fps"]?.intValue ?? 1
        self.next = now
    }
    func claim(at now: ContinuousClock.Instant) -> Int? {
        lock.withLock {
            guard now >= next else { return nil }
            next = now.advanced(by: .milliseconds(1000 / fps))
            sequence += 1
            return sequence
        }
    }
}

extension RuntimeService {
    func subscribeObservation(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard !c.isSubscribed else { return .failure(RuntimeError("conflict", "connection already subscribed", phase: .handler)) }
        guard request.context.runId == nil,
              !c.ownedRuns.union(c.attachedRuns).contains(where: { runs.find($0).map { $0.phase != .ended } ?? false })
        else { return .failure(RuntimeError("conflict", "use a separate read-only connection for frames", phase: .handler,
                                           details: .obj([("reason", .string("control_connection"))]))) }
        if case let .failure(error) = target(of: request, c) { return .failure(error) }
        let sub = ObservationSubscription(context: request.context, params: request.params, now: observationStreamNow())
        c.frameSubscription = sub
        return .success(.obj([("subscriptionId", .string(sub.id)), ("subscribed", .bool(true)),
                              ("fps", .int(sub.fps)), ("maxWidth", .int(request.params["maxWidth"]?.intValue ?? 1280)),
                              ("version", .int(1))]))
    }

    func pendingObservationFrames(_ c: ConnectionState) -> [JSONValue] {
        guard let sub = c.frameSubscription, let sequence = sub.claim(at: observationStreamNow()) else { return [] }
        var params = JSONValue.obj([("maxWidth", .int(sub.params["maxWidth"]?.intValue ?? 1280)), ("elements", .bool(false))])
        if let region = sub.params["region"] { params = params.setting("region", region) }
        let request = RuntimeRequest(requestId: RuntimeRequest.newId(), method: "observe.region", context: sub.context,
                                     deadline: Timestamp.string(now().addingTimeInterval(0.5)), params: params)
        // A grant withdrawal still applies on every frame, even without a new
        // wire request passing through respond's admission checks.
        let answer: Result<JSONValue, RuntimeError>
        if let error = authorization(request, c) { answer = .failure(error) }
        else { answer = observe(request, c, readOnlyFrame: true) }
        guard c.frameSubscription === sub else {
            if case let .success(observation) = answer, let id = observation["image"]?["artifactId"]?.stringValue { artifacts.remove(id) }
            return []
        }
        var fields: [(String, JSONValue)] = [("apiVersion", .string(RuntimeAPI.version)),
            ("subscriptionId", .string(sub.id)), ("sequence", .int(sequence)), ("type", .string("observation.frame"))]
        switch answer {
        case let .success(observation):
            fields += [("status", .string("ready")), ("frame", .obj([
                ("image", observation["image"] ?? .null), ("screen", observation["screen"] ?? .null),
                ("target", observation["target"] ?? .null), ("capturedAt", observation["capturedAt"] ?? .null)]))]
        case let .failure(error):
            fields += [("status", .string("paused")), ("error", error.json)]
        }
        return [.obj(fields)]
    }
}
