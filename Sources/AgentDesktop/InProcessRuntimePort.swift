import AgentDesktopProtocol
import AgentDesktopRuntime
import AgentDesktopUI
import Foundation

/// The main window's way into the Runtime in this process (docs/plan/10
/// §1.6): each call is one runtime/1 request line answered by the same
/// `RuntimeService.respond` the socket server uses, on a connection of its
/// own, so the same checks, ledger and principal (`local:<uid>`, owner)
/// apply as for any local client.
///
/// Requests never run on the main thread: the engine platform hops to the
/// main actor, so a main-thread caller would wait on itself. They run in
/// order on one serial queue, as on one socket connection.
///
/// Closing the main window does not close this connection (ADR-02): it
/// belongs to the host process, and the window only stops reading.
final class InProcessRuntimePort: RuntimePort, @unchecked Sendable {
    let isSample = false
    private let service: RuntimeService
    private let connection: ConnectionState
    private let queue = DispatchQueue(label: "agentdesktop.main-window.runtime", qos: .userInitiated)

    init(service: RuntimeService) {
        self.service = service
        self.connection = ConnectionState(peerUID: getuid())
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    /// True while the current thread is this port's queue (tests use it).
    static let queueKey = DispatchSpecificKey<Bool>()

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        try await call(method, params, context: context, requestId: nil)
    }

    /// With the caller's requestId it is the Runtime's idempotency key: the
    /// ledger answers a repeat of the same request from its record.
    func call(_ method: String, _ params: JSONValue, context: RequestContext, requestId: String?) async throws -> JSONValue {
        let request = RuntimeRequest(requestId: requestId ?? RuntimeRequest.newId(prefix: "ui"), method: method, context: context,
                                     params: params)
        let line = request.json.encodedData()
        let service = self.service
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let response = service.respond(to: line, on: connection)
                continuation.resume(with: response.result)
            }
        }
    }

    /// `events.subscribe` on a connection of its own (a subscribed
    /// connection takes no other requests, docs/plan/10 §1.6), handshaken
    /// like any local client. Its frames are taken on the same queue as
    /// the socket server takes them (`pendingEventFrames`), until access is
    /// withdrawn or the Store stops reading; then it unsubscribes. Closing
    /// it never affects a Run (ADR-02).
    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        let sub = ConnectionState(peerUID: getuid())
        _ = try await send("runtime.handshake", .obj([
            ("apiVersions", .array([.string(RuntimeAPI.version)])),
            ("client", .obj([("name", .string("AgentDesktop main window events")), ("version", .string(RuntimeAPI.productVersion))])),
        ]), on: sub)
        var params: [(String, JSONValue)] = []
        if let after { params.append(("after", .int(after))) }
        _ = try await send("events.subscribe", .obj(params), on: sub)
        let service = self.service
        let queue = self.queue
        return PulledEventStream.make(pull: {
            await withCheckedContinuation { (c: CheckedContinuation<[JSONValue]?, Never>) in
                queue.async {
                    if service.subscriptionRevoked(sub) || service.subscriptionDrained(sub) { c.resume(returning: nil); return }
                    c.resume(returning: service.pendingEventFrames(sub))
                }
            }
        }, close: {
            let line = RuntimeRequest(requestId: RuntimeRequest.newId(prefix: "ui"), method: "events.unsubscribe",
                                      context: RequestContext(), params: .obj([])).json.encodedData()
            queue.async { _ = service.respond(to: line, on: sub) }
        })
    }

    private func send(_ method: String, _ params: JSONValue, on connection: ConnectionState) async throws -> JSONValue {
        let line = RuntimeRequest(requestId: RuntimeRequest.newId(prefix: "ui"), method: method, context: RequestContext(),
                                  params: params).json.encodedData()
        let service = self.service
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: service.respond(to: line, on: connection).result) }
        }
    }
}

/// The Runtime did not start: every call says so, and the window shows the
/// Disconnected state instead of any data.
final class UnavailableRuntimePort: RuntimePort, @unchecked Sendable {
    let isSample = false
    let reason: String

    init(reason: String) { self.reason = reason }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        throw RuntimeError.runtimeOffline(reason, endpoint: "in-process")
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        throw RuntimeError.runtimeOffline(reason, endpoint: "in-process")
    }
}
