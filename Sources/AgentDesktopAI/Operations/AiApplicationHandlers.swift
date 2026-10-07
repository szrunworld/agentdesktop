import AgentDesktopContracts
import Foundation

/// Every AI command of contract v1 that the AI module serves, as
/// `RpcHandler`s for one caller: the configuration commands plus
/// `ai.models.list/refresh`, `ai.operations.get/cancel` and
/// `ai.usage.summary`. `ai.tests.start` comes from the GUI module's
/// capability tests and is passed in through `extra`.
public struct AiApplicationHandlers: Sendable {
    public let store: ConfigStore
    public let config: ConfigApplicationService
    public let runner: AiOperationRunner
    public let catalog: ModelCatalogFetcher
    public let credentials: CredentialResolver

    public init(store: ConfigStore, http: HTTPTransport, runner: AiOperationRunner = AiOperationRunner(),
                credentials: CredentialResolver? = nil) {
        self.store = store
        self.config = ConfigApplicationService(store: store)
        self.runner = runner
        self.catalog = ModelCatalogFetcher(http: http)
        self.credentials = credentials ?? StoreCredentialResolver(store: store)
    }

    public static let commands: [String] = ConfigApplicationService.commands + [
        "ai.models.list", "ai.models.refresh", "ai.operations.get", "ai.operations.cancel", "ai.usage.summary",
    ]

    public func handlers(callerScope: String, extra: [String: RpcHandler] = [:]) -> [String: RpcHandler] {
        var out = config.handlers(callerScope: callerScope)
        for command in ["ai.models.list", "ai.models.refresh", "ai.operations.get", "ai.operations.cancel", "ai.usage.summary"] {
            out[command] = { req in try await self.handle(req, callerScope: callerScope) }
        }
        out.merge(extra) { _, new in new }
        return out
    }

    public func handle(_ req: RpcRequest, callerScope: String) async throws -> JSONValue {
        let p = req.params
        let s = store
        switch req.command {
        case "ai.models.list":
            return try await s.listModels(connectionId: p["connectionId"]?.stringValue ?? "",
                                          limit: p["limit"]?.intValue, cursor: p["cursor"]?.stringValue)
        case "ai.models.refresh":
            let id = p["connectionId"]?.stringValue ?? ""
            let rev = p["expectedRevision"]?.intValue ?? 0
            let result = try await s.runIdempotent(scope: callerScope, command: req.command, key: req.idempotencyKey,
                                                   semantic: p) { store in
                _ = try store.connectionForRefresh(id, expectedRevision: rev)
                let op = try store.createOperation(kind: .modelRefresh, callerScope: callerScope,
                                                   resourceId: id, resourceRevision: rev)
                return .obj([("operationId", .string(op)), ("state", .string("queued"))])
            }
            if let op = result["operationId"]?.stringValue {
                await runner.start(op) { await self.refresh(operationId: op, connectionId: id, revision: rev) }
            }
            return result
        case "ai.operations.get":
            return try await s.operation(p["operationId"]?.stringValue ?? "", callerScope: callerScope)
        case "ai.operations.cancel":
            let id = p["operationId"]?.stringValue ?? ""
            let result = try await s.runIdempotent(scope: callerScope, command: req.command, key: req.idempotencyKey,
                                                   semantic: p) { store in
                let (accepted, state) = try store.requestOperationCancel(id, callerScope: callerScope)
                return .obj([("operationId", .string(id)), ("accepted", .bool(accepted)),
                             ("state", .string(state.rawValue)), ("terminal", .bool(state.isTerminal))])
            }
            if result["state"]?.stringValue == AiOperationState.cancelling.rawValue {
                await runner.cancel(id)
                if !(await runner.isActive(id)) {
                    // No work in flight (never started, or already gone): end it here.
                    try await s.setOperation(id, state: .cancelled)
                }
            }
            return result
        case "ai.usage.summary":
            guard let from = p["from"]?.stringValue.flatMap(ConfigStore.parseTimestamp),
                  let to = p["to"]?.stringValue.flatMap(ConfigStore.parseTimestamp) else {
                throw ContractError(.validationError, "from and to must be date-times")
            }
            guard from < to else { throw ContractError(.validationError, "from must be before to") }
            let rows = try await s.usageRows(callerScope: callerScope)
            return UsageSummaryBuilder.summarize(rows: rows, from: from, to: to, connectionId: p["connectionId"]?.stringValue)
        default:
            throw ContractError(.unsupportedCommand, "not an AI command")
        }
    }

    /// The work of one `ai.models.refresh`.
    func refresh(operationId: String, connectionId: String, revision: Int) async {
        let s = store
        do {
            try Task.checkCancellation()
            guard try await s.setOperation(operationId, state: .running) else {
                if try await s.operationState(operationId) == .cancelling { try await s.setOperation(operationId, state: .cancelled) }
                return
            }
            let (body, credential) = try await s.connectionForRefresh(connectionId, expectedRevision: revision)
            let key = try await credentials.resolveKey(credentialIdentity: credential)
            guard let base = body["baseUrl"]?.stringValue.flatMap(URL.init(string:)) else {
                throw ContractError(.validationError, "the connection's baseUrl is invalid")
            }
            let at = await s.timestampNow
            let entries = try await catalog.fetch(base: base, apiKey: key, timeoutMs: body["timeoutMs"]?.intValue ?? 30_000, at: at)
            try Task.checkCancellation()
            try await s.saveCatalog(connectionId: connectionId, revision: revision, entries: entries, at: at)
            try await s.setOperation(operationId, state: .succeeded, result: .obj([
                ("connectionId", .string(connectionId)), ("connectionRevision", .int(revision)),
                ("modelCount", .int(entries.count)), ("refreshedAt", .string(at)),
            ]))
        } catch is CancellationError {
            _ = try? await s.setOperation(operationId, state: .cancelled)
        } catch {
            _ = try? await s.markCatalogStale(connectionId: connectionId)
            let e = (error as? ContractError) ?? ContractError(.internalError, "the model list could not be refreshed")
            if Task.isCancelled {
                _ = try? await s.setOperation(operationId, state: .cancelled)
            } else {
                _ = try? await s.setOperation(operationId, state: .failed, error: e)
            }
        }
    }
}
