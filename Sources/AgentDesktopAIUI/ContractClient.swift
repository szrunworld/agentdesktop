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
    public init(router: ServiceRouter, guiCapabilities: @escaping @Sendable () -> JSONValue) {
        self.router = router
        self.capabilities = guiCapabilities
    }

    public func guiCapabilities() async throws -> JSONValue { capabilities() }

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
