import AgentDesktopContracts
import Foundation

/// Resolves credential identities through the configuration store: only an
/// active identity yields its key (spec §04.1, §10.2, SEC-002).
public struct StoreCredentialResolver: CredentialResolver {
    public let store: ConfigStore

    public init(store: ConfigStore) {
        self.store = store
    }

    public func resolveKey(credentialIdentity: ResourceID) async throws -> String {
        try await store.resolveSecret(credentialId: credentialIdentity)
    }
}

/// Admission that voids calls made with a credential identity that has since
/// been revoked (rotation or connection delete). The store's outbox reports
/// each revocation; a call in flight when it lands finishes as discarded and
/// its result never leaves the model service (SEC-004).
///
/// `next` adds the Runtime's own checks (run generation, candidate
/// authorization); both must pass.
public final class CredentialRevocationAdmission: AiCallAdmission, @unchecked Sendable {
    private let store: ConfigStore
    private let next: AiCallAdmission
    private let lock = NSLock()
    private var revoked: Set<ResourceID> = []

    /// Call `register()` once after creating it, so revocations reach it.
    public init(store: ConfigStore, next: AiCallAdmission = AdmitAll()) {
        self.store = store
        self.next = next
    }

    public func register() async {
        await store.onCredentialRevoked { [weak self] id in self?.markRevoked(id) }
    }

    func markRevoked(_ id: ResourceID) {
        _ = lock.withLock { revoked.insert(id) }
    }

    func knownRevoked(_ id: ResourceID) -> Bool {
        lock.withLock { revoked.contains(id) }
    }

    private func isRevoked(_ id: ResourceID) async -> Bool {
        if knownRevoked(id) { return true }
        // Also read the durable state, so a revocation committed before this
        // object existed (or before a restart) is honoured.
        return (try? await store.credentialState(id)) != "active"
    }

    public func admit(_ context: AiCallContext, target: AiResolvedModel) async throws {
        if await isRevoked(target.connection.credentialIdentityRef) {
            throw ContractError(.credentialRevoked, "the credential was revoked")
        }
        try await next.admit(context, target: target)
    }

    public func isStillCurrent(_ context: AiCallContext, target: AiResolvedModel) async -> Bool {
        if await isRevoked(target.connection.credentialIdentityRef) { return false }
        return await next.isStillCurrent(context, target: target)
    }
}
