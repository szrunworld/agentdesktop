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

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let request = RuntimeRequest(requestId: RuntimeRequest.newId(prefix: "ui"), method: method, params: params)
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

    /// Event push arrives with U1b-2 (after PR2b); until then the Store
    /// polls, and this answers as a Runtime without the method would.
    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        throw RuntimeError.capabilityMissing("the main window reads the Runtime by polling until U1b-2")
    }
}

/// The Runtime did not start: every call says so, and the window shows the
/// Disconnected state instead of any data.
final class UnavailableRuntimePort: RuntimePort, @unchecked Sendable {
    let isSample = false
    let reason: String

    init(reason: String) { self.reason = reason }

    func call(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        throw RuntimeError.runtimeOffline(reason, endpoint: "in-process")
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        throw RuntimeError.runtimeOffline(reason, endpoint: "in-process")
    }
}
