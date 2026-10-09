import AgentDesktopProtocol
import Foundation

/// The AI service's operations on the Runtime's single endpoint (A2,
/// runtime-api-v1-freeze §1, §6). A runtime/1 call goes straight to the
/// router the main window uses; the answer comes back in runtime/1 terms
/// with lowercase error codes.
public enum RuntimeBridge {
    /// How long a call waits for the service when the request has no
    /// deadline. Long work (model refresh, capability tests) answers at once
    /// with an operation to poll.
    static let defaultWait: TimeInterval = 60

    public static func handlers(_ service: AgentDesktopService, methods: [String],
                                contract: ContractBundle = .shared) -> [String: ExtensionMethod] {
        handlers(service, methods: methods, contract: contract, diagnostics: nil)
    }

    /// With a test-only timeline of each call (#166); internal, so only a
    /// `@testable` test can pass one.
    static func handlers(_ service: AgentDesktopService, methods: [String], contract: ContractBundle = .shared,
                         diagnostics: BridgeDiagnostics?) -> [String: ExtensionMethod] {
        var out: [String: ExtensionMethod] = [:]
        for name in methods {
            guard let op = contract.operation(name) else { continue }
            let needsKey = op.requiresIdempotencyKey
            out[name] = { call in answer(call, service: service, idempotent: needsKey, diagnostics: diagnostics) }
        }
        return out
    }

    /// What the GUI execution backend supports, for the `gui` section of
    /// runtime.capabilities.
    public static func guiCapabilities(_ service: AgentDesktopService) -> JSONValue? {
        service.runs.capabilities()
    }

    static func answer(_ call: ExtensionCall, service: AgentDesktopService, idempotent: Bool,
                       diagnostics: BridgeDiagnostics? = nil) -> Result<JSONValue, RuntimeError> {
        // Test-only timeline (#166); with none, every `diagnostics?` below is
        // skipped and nothing else changes.
        let traced = diagnostics?.begin(method: call.method)
        // The service scopes configuration by caller; the local owner keeps
        // the scope it has always had.
        let scope = call.clientId.hasPrefix("local:") ? "uid:" + call.clientId.dropFirst("local:".count) : call.clientId
        let router = service.router(callerScope: scope, trustedOwner: call.owner)
        final class Box: @unchecked Sendable { var outcome: Result<JSONValue, ContractError>? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let deadline = call.deadline.map(Timestamp.string)
        Task.detached {
            traced?.note(.taskStarted, taskPriority: Task.currentPriority.rawValue)
            box.outcome = await router.answer(method: call.method, params: call.params, deadline: deadline,
                                              idempotencyKey: idempotent ? call.requestId : nil)
            traced?.note(.resultReady)
            done.signal()
        }
        traced?.note(.taskCreated)
        let until = call.deadline ?? Date().addingTimeInterval(defaultWait)
        traced?.note(.waitStarted)
        let waited = done.wait(timeout: .now() + max(0, until.timeIntervalSinceNow))
        traced?.note(waited == .success ? .answered : .timedOut)
        guard waited == .success, let outcome = box.outcome else {
            // Handed to the service; whether a write took effect is unknown.
            return .failure(idempotent
                ? RuntimeError("request_acceptance_unknown", "the AI service did not answer in time; look the request up again with the same requestId",
                               phase: .handler, details: .obj([("requestId", .string(call.requestId))]))
                : RuntimeError("deadline_exceeded", "the AI service did not answer in time", phase: .handler))
        }
        return outcome.mapError(runtimeError)
    }

    /// The service's error → runtime/1 error (runtime-api-v1-freeze §6).
    /// The service's own classification stays in `details.serviceCode`.
    static func runtimeError(_ e: ContractError) -> RuntimeError {
        let code = e.code.rawValue
        let message = e.message
        let retryable = e.retryable
        var details = e.details?.objectMembers ?? []
        func reason(_ r: String) { if !details.contains(where: { $0.0 == "reason" }) { details.append(("reason", .string(r))) } }
        let mapped: String
        switch code {
        case "VALIDATION_ERROR": mapped = "invalid_argument"
        case "UNSUPPORTED_SCHEMA", "UNSUPPORTED_PROTOCOL": mapped = "version_mismatch"
        case "UNSUPPORTED_COMMAND": mapped = "not_found"; reason("unknown_method")
        case "IPC_FRAME_TOO_LARGE": mapped = "frame_too_large"
        case "UNAUTHORIZED", "FORBIDDEN": mapped = "permission_denied"
        case "NOT_FOUND": mapped = "not_found"
        case "CONFIG_CONFLICT": mapped = "conflict"
        case "IDEMPOTENCY_CONFLICT": mapped = "idempotency_conflict"
        case "RESOURCE_IN_USE": mapped = "conflict"; reason("in_use")
        case "RESOURCE_DISABLED": mapped = "conflict"; reason("disabled")
        case "CAPABILITY_MISMATCH": mapped = "capability_mismatch"
        case "CREDENTIAL_REQUIRED", "CREDENTIAL_REVOKED", "AUTH_FAILED", "RATE_LIMITED", "UPSTREAM_UNAVAILABLE",
             "UPSTREAM_PROTOCOL_ERROR", "MODEL_NOT_FOUND":
            mapped = "model_unavailable"; reason(code.lowercased())
        case "DEADLINE_EXCEEDED": mapped = "deadline_exceeded"
        case "CANCELLED": mapped = "conflict"; reason("cancelled")
        case "OPERATION_NOT_CANCELLABLE": mapped = "conflict"; reason("not_cancellable")
        case "DESKTOP_BUSY": mapped = "control_busy"
        case "STALE_OBSERVATION", "STALE_GENERATION": mapped = "stale_observation"
        case "INVALID_ACTION", "COORDINATE_OUT_OF_BOUNDS": mapped = "invalid_target"
        case "ACTION_OUTCOME_UNKNOWN": mapped = "action_delivery_unknown"
        case "VERIFICATION_FAILED": mapped = "execution_failed"; reason("verification_failed")
        case "LIMIT_EXCEEDED": mapped = "limit_exceeded"
        case "EVENTS_CURSOR_EXPIRED": mapped = "events_cursor_expired"
        case "AUDIT_UNAVAILABLE": mapped = "audit_unavailable"
        case "USAGE_UNAVAILABLE": mapped = "internal_error"; reason("usage_unavailable")
        default: mapped = "internal_error"
        }
        details.append(("serviceCode", .string(code)))
        return RuntimeError(mapped, message, phase: .handler, retryable: retryable, details: .obj(details))
    }
}
