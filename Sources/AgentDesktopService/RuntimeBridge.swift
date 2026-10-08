import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// The AI service's operations on the Runtime's single endpoint (A2,
/// runtime-api-v1-freeze §1, §6). A runtime/1 call is handed to the same
/// router the main window uses, as the ai/1 request it stands for; the
/// answer comes back in runtime/1 terms with lowercase error codes. The
/// ai/1 envelope never crosses a socket any more.
public enum RuntimeBridge {
    /// How long a call waits for the service when the request has no
    /// deadline. Long work (model refresh, capability tests) answers at once
    /// with an operation to poll.
    static let defaultWait: TimeInterval = 60

    public static func handlers(_ service: AgentDesktopService, methods: [String],
                                contract: ContractBundle = .shared) -> [String: ExtensionMethod] {
        var out: [String: ExtensionMethod] = [:]
        for name in methods {
            guard let op = contract.operation(name) else { continue }
            let needsKey = op.requiresIdempotencyKey
            out[name] = { call in answer(call, service: service, idempotent: needsKey) }
        }
        return out
    }

    /// The service's own capabilities answer (GUI execution backend: actions,
    /// predicates, concurrency), for the `gui` section of runtime.capabilities.
    public static func guiCapabilities(_ service: AgentDesktopService) -> JSONValue? {
        let call = ExtensionCall(method: "runtime.capabilities", requestId: UUID().uuidString.lowercased(),
                                 deadline: Date().addingTimeInterval(5), params: .obj([]),
                                 clientId: "local:\(getuid())", owner: true)
        if case let .success(v) = answer(call, service: service, idempotent: false) { return v }
        return nil
    }

    static func answer(_ call: ExtensionCall, service: AgentDesktopService, idempotent: Bool) -> Result<JSONValue, RuntimeError> {
        // The service scopes configuration by caller; the local owner keeps
        // the scope the ai.sock connections had.
        let scope = call.clientId.hasPrefix("local:") ? "uid:" + call.clientId.dropFirst("local:".count) : call.clientId
        let router = service.router(callerScope: scope, trustedOwner: call.owner)
        var context: [(String, JSONValue)] = []
        if idempotent { context.append(("idempotencyKey", .string(call.requestId))) }
        if let deadline = call.deadline { context.append(("deadlineAt", .string(Timestamp.string(deadline)))) }
        var envelope: [(String, JSONValue)] = [("schemaVersion", .string(ContractBundle.schemaVersion)),
                                               ("requestId", .string(UUID().uuidString.lowercased())),
                                               ("command", .string(call.method)), ("params", call.params)]
        if !context.isEmpty { envelope.append(("context", .obj(context))) }
        let body = Data(JSONValue.obj(envelope).encoded().utf8)

        final class Box: @unchecked Sendable { var reply: Data? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.reply = await router.respond(toBody: body)
            done.signal()
        }
        let until = call.deadline ?? Date().addingTimeInterval(defaultWait)
        guard done.wait(timeout: .now() + max(0, until.timeIntervalSinceNow)) == .success, let reply = box.reply else {
            // Sent to the service; whether a write took effect is unknown.
            return .failure(idempotent
                ? RuntimeError("request_acceptance_unknown", "the AI service did not answer in time; look the request up again with the same requestId",
                               phase: .handler, details: .obj([("requestId", .string(call.requestId))]))
                : RuntimeError("deadline_exceeded", "the AI service did not answer in time", phase: .handler))
        }
        guard let value = try? StrictJSON.parse(reply.last == 0x0A ? reply.dropLast() : reply) else {
            return .failure(RuntimeError("internal_error", "the AI service answered with something that is not JSON", phase: .handler))
        }
        if value["ok"]?.boolValue == true { return .success(value["result"] ?? .obj([])) }
        return .failure(runtimeError(value["error"] ?? .obj([])))
    }

    /// ai/1 error → runtime/1 error (runtime-api-v1-freeze §6).
    static func runtimeError(_ e: JSONValue) -> RuntimeError {
        let code = e["code"]?.stringValue ?? "INTERNAL_ERROR"
        let message = e["message"]?.stringValue ?? "the AI service failed"
        let retryable = e["retryable"]?.boolValue ?? false
        var details = e["details"]?.objectMembers ?? []
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
        details.append(("aiCode", .string(code)))
        return RuntimeError(mapped, message, phase: .handler, retryable: retryable, details: .obj(details))
    }
}
