import AgentDesktopProtocol
// PollClock, EmptyState, LabeledValue and the endpoint rule live in the
// shell library; pages and tests keep using them through this module.
@_exported import AgentDesktopUI
import Foundation

/// The only way the AI/GUI pages talk to the service (spec §2.1): one
/// contract v1 request per call, answered by the same application service
/// the CLI uses. The page never decides who the caller is.
public protocol ContractClient: Sendable {
    /// Send one command. Returns the validated `result`, or throws the
    /// service's `ContractError`.
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue
    /// What the GUI execution backend supports (runtime.capabilities `gui`).
    func guiCapabilities() async throws -> JSONValue
    /// A6: start a GUI unit Run from the main window: a Durable Run
    /// (platform / platform_durable / gui_explorer), started in-process.
    /// Returns the Run.
    func startUnitRun(_ params: JSONValue) async throws -> JSONValue
    /// A6: a Runtime Run method (run.show, run.events, run.cancel). A write
    /// carries `requestId` (the same id repeats it).
    func runtime(_ method: String, _ params: JSONValue, requestId: String?) async throws -> JSONValue
}

extension ContractClient {
    public func send(_ command: String, _ params: JSONValue = .obj([])) async throws -> JSONValue {
        try await send(command, params, idempotencyKey: nil)
    }
}

/// Calls the service's router in the same process (the app hosting the
/// service). No envelope: the router checks params and result against the
/// contract; a write's idempotency key is what the page passes.
public struct InProcessContractClient: ContractClient {
    public let router: ServiceRouter
    let capabilities: @Sendable () -> JSONValue
    let runs: RuntimeRunsPort?
    public init(router: ServiceRouter, guiCapabilities: @escaping @Sendable () -> JSONValue, runs: RuntimeRunsPort? = nil) {
        self.router = router
        self.capabilities = guiCapabilities
        self.runs = runs
    }

    public func guiCapabilities() async throws -> JSONValue { capabilities() }

    public func startUnitRun(_ params: JSONValue) async throws -> JSONValue {
        guard let runs else { throw ContractError(.capabilityMismatch, "this window has no Runtime to run GUI units") }
        return try await runs.start(params).mapError(ContractError.init(runtime:)).get()
    }

    public func runtime(_ method: String, _ params: JSONValue, requestId: String?) async throws -> JSONValue {
        guard let runs else { throw ContractError(.capabilityMismatch, "this window has no Runtime to run GUI units") }
        return try await runs.call(method, params, requestId).mapError(ContractError.init(runtime:)).get()
    }

    public func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        try await router.answer(method: command, params: params, idempotencyKey: idempotencyKey).get()
    }
}

/// One logical submission keeps its idempotency key across retries; a
/// changed request gets a new one (spec §2.2).
struct SubmissionKey {
    private var key: String?
    private var semantic: String?

    mutating func key(for semantic: JSONValue, prefix: String) -> String {
        let s = semantic.encoded()
        if let key, self.semantic == s { return key }
        let fresh = "\(prefix)-\(UUID().uuidString.lowercased())"
        key = fresh
        self.semantic = s
        return fresh
    }

    mutating func reset() { key = nil; semantic = nil }
}

/// The main window's way to the Runtime's Runs (A6), supplied by the host.
/// Both answer off the cooperative pool.
public struct RuntimeRunsPort: Sendable {
    public let start: @Sendable (JSONValue) async -> Result<JSONValue, RuntimeError>
    public let call: @Sendable (_ method: String, _ params: JSONValue, _ requestId: String?) async -> Result<JSONValue, RuntimeError>

    public init(start: @escaping @Sendable (JSONValue) async -> Result<JSONValue, RuntimeError>,
                call: @escaping @Sendable (String, JSONValue, String?) async -> Result<JSONValue, RuntimeError>) {
        self.start = start
        self.call = call
    }
}

extension ContractError {
    /// A runtime/1 error in the terms the pages explain (UIProblem).
    public init(runtime e: RuntimeError) {
        let reason = e.details?["reason"]?.stringValue
        let code: ErrorCode
        switch e.code {
        case "not_found": code = .notFound
        case "control_busy": code = .desktopBusy
        case "conflict" where reason == "profile_revision_changed": code = .configConflict
        case "conflict" where reason == "disabled": code = .resourceDisabled
        case "model_unavailable" where reason == "credential_revoked": code = .credentialRevoked
        case "model_unavailable" where reason == "credential_required": code = .credentialRequired
        case "model_unavailable": code = .upstreamUnavailable
        case "unsupported_backend", "capability_mismatch", "capability_missing", "input_disabled", "invalid_target":
            code = .capabilityMismatch
        case "schema_invalid", "invalid_argument", "ownership_escalation_denied": code = .validationError
        case "permission_denied", "grant_missing", "pairing_required": code = .forbidden
        case "events_cursor_expired": code = .eventsCursorExpired
        case "audit_unavailable": code = .auditUnavailable
        case "deadline_exceeded": code = .deadlineExceeded
        case "limit_exceeded": code = .limitExceeded
        case "stale_observation": code = .staleObservation
        default: code = .internalError
        }
        var details = e.details?.objectMembers ?? []
        details.append(("runtimeCode", .string(e.code)))
        self.init(code, e.message, retryable: e.retryable, details: .obj(details))
    }
}
