import AgentDesktopProtocol
import Foundation

/// Methods other services register with the Runtime. They are served on
/// the same endpoint and envelope; their params are validated by the
/// service (its schema is the contract's), they skip the Runtime's request
/// ledger because the service keys its own idempotency on the requestId.
final class ExtensionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String: ExtensionMethod] = [:]
    /// Extra sections of runtime.capabilities ("gui": what the GUI
    /// execution backend supports), answered by their service.
    private var sections: [String: @Sendable () -> JSONValue?] = [:]

    func registerSection(_ name: String, _ body: @escaping @Sendable () -> JSONValue?) {
        lock.withLock { sections[name] = body }
    }

    func capabilitySections() -> [(String, JSONValue)] {
        let all = lock.withLock { sections }
        return all.keys.sorted().compactMap { k in all[k]!().map { (k, $0) } }
    }

    func register(_ handlers: [String: ExtensionMethod]) {
        lock.withLock { methods.merge(handlers) { _, new in new } }
    }

    func handler(_ name: String) -> ExtensionMethod? { lock.withLock { methods[name] } }
    var names: Set<String> { lock.withLock { Set(methods.keys) } }
}

extension RuntimeService {
    /// Serve these methods on the Runtime's endpoint. Only names methods.json
    /// lists with `servedBy` are taken; the others are ignored.
    public func registerExtensions(_ handlers: [String: ExtensionMethod]) {
        extensions.register(handlers.filter { contract.method($0.key)?.servedBy != nil })
    }

    /// Add a section to runtime.capabilities (one capabilities answer for
    /// the whole endpoint, runtime-api-v1-freeze §6).
    public func registerCapabilitySection(_ name: String, _ body: @escaping @Sendable () -> JSONValue?) {
        extensions.registerSection(name, body)
    }

    func ledgeredExtension(_ request: RuntimeRequest, _ handler: ExtensionMethod, on c: ConnectionState) -> RuntimeResponse {
        let begin: RequestLedger.Begin
        do {
            begin = try ledger.begin(caller: c.clientId, request)
        } catch {
            return .failure(request.requestId, RuntimeError("audit_unavailable", "the request ledger is unavailable", phase: .request,
                                                            notSent: true))
        }
        switch begin {
        case let .existing(record):
            switch RequestLedger.replay(record) {
            case let .success(d): return .success(request.requestId, d)
            case let .failure(e): return .failure(request.requestId, e)
            }
        case let .conflict(record):
            return .failure(request.requestId, RuntimeError(
                "idempotency_conflict", "requestId \(request.requestId) was used for another request (\(record.method)); use a new requestId",
                phase: .request, notSent: true, details: .obj([("method", .string(record.method))])))
        case .fresh:
            let response = answerExtension(request, handler, on: c)
            switch response.result {
            case let .failure(e) where !["request_acceptance_unknown", "action_delivery_unknown"].contains(e.code):
                // The service refused or failed it before any effect, and
                // forgot the key itself: so does the ledger, for a retry.
                try? ledger.forget(caller: c.clientId, requestId: request.requestId)
            default:
                try? ledger.finish(caller: c.clientId, requestId: request.requestId, response.result)
            }
            return response
        }
    }

    func answerExtension(_ request: RuntimeRequest, _ handler: ExtensionMethod, on c: ConnectionState) -> RuntimeResponse {
        let call = ExtensionCall(method: request.method, requestId: request.requestId,
                                 deadline: request.deadline.flatMap(Timestamp.date), params: request.params,
                                 clientId: c.clientId, owner: isOwner(c))
        switch handler(call) {
        case let .success(data): return .success(request.requestId, data)
        case let .failure(e): return .failure(request.requestId, e)
        }
    }
}
