import AgentDesktopAI
import AgentDesktopContracts
import Foundation

/// Resolves a new run's candidates from the configuration store (spec
/// §04.1, §18.2). It reads exact revisions, so the binding is a deep copy
/// that later edits, default changes or disables cannot alter; and it
/// refuses anything disabled, deleted, stale, revoked or incompatible
/// before any model call happens.
public struct ConfigBindingResolver: GuiBindingResolver {
    public let store: ConfigStore
    public let codecs: GuiCodecRegistry
    /// No policy store exists yet; every binding records this revision.
    public let policyRevision: Int
    public let dataScopeRef: String

    public init(store: ConfigStore, codecs: GuiCodecRegistry = GuiCodecRegistry(), policyRevision: Int = 1,
                dataScopeRef: String = "local-device") {
        self.store = store
        self.codecs = codecs
        self.policyRevision = policyRevision
        self.dataScopeRef = dataScopeRef
    }

    public func resolve(guiProfileId: String?, expectedProfileRevision: Int?, callerScope: String) async throws
        -> (primary: GuiCandidate, fallback: [GuiCandidate], policyRevision: Int) {
        let profile: JSONValue
        if let guiProfileId {
            profile = try await store.get(.guiProfile, guiProfileId)
            let current = profile["revision"]?.intValue ?? 0
            guard current == expectedProfileRevision else {
                throw ContractError(.configConflict, "the GUI profile changed; reload and retry",
                                    details: .obj([("currentRevision", .int(current))]))
            }
        } else {
            let pointer = try await store.defaultProfile()
            guard let resolved = pointer["resolvedProfile"], case .object = resolved else {
                throw ContractError(.notFound, "no default GUI profile is set")
            }
            profile = resolved
        }
        let scope = Self.scopeRef(callerScope)
        let primary = try await candidate(profile, index: 0, scope: scope)

        var fallback: [GuiCandidate] = []
        if let ref = profile["allowedFallbackProfileRefs"]?.arrayValue?.first {
            guard let fid = ref["guiProfileId"]?.stringValue, let frev = ref["revision"]?.intValue else {
                throw ContractError(.validationError, "fallback reference is incomplete")
            }
            guard fid != primary.guiProfileId else {
                throw ContractError(.validationError, "a GUI profile cannot fall back to itself")
            }
            guard let body = try await store.revisionBody(.guiProfile, fid, frev) else {
                throw ContractError(.notFound, "the fallback GUI profile revision does not exist")
            }
            let current = try await store.get(.guiProfile, fid)
            guard current["state"]?.stringValue == "enabled" else {
                throw ContractError(.resourceDisabled, "the fallback GUI profile is disabled")
            }
            let f = try await candidate(body, index: 1, scope: scope)
            guard f.adapterId == primary.adapterId, f.coordinateProtocol == primary.coordinateProtocol else {
                throw ContractError(.capabilityMismatch, "the fallback uses another adapter or coordinate protocol")
            }
            fallback = [f]
        }
        return (primary, fallback, policyRevision)
    }

    private func candidate(_ profile: JSONValue, index: Int, scope: String) async throws -> GuiCandidate {
        guard profile["state"]?.stringValue == "enabled" else {
            throw ContractError(.resourceDisabled, "the GUI profile is disabled")
        }
        guard let adapter = profile["adapterId"]?.stringValue,
              let mpId = profile["modelProfileId"]?.stringValue, let mpRev = profile["modelProfileRevision"]?.intValue else {
            throw ContractError(.validationError, "the GUI profile is incomplete")
        }
        _ = try codecs.codec(adapterId: adapter, coordinateProtocol: profile["coordinateProtocol"]?.stringValue)

        guard let model = try await store.revisionBody(.modelProfile, mpId, mpRev) else {
            throw ContractError(.notFound, "the model profile revision does not exist")
        }
        guard try await store.get(.modelProfile, mpId)["state"]?.stringValue == "enabled" else {
            throw ContractError(.resourceDisabled, "the model profile is disabled")
        }
        guard let cId = model["connectionId"]?.stringValue, let cRev = model["connectionRevision"]?.intValue,
              let connection = try await store.revisionBody(.connection, cId, cRev) else {
            throw ContractError(.notFound, "the connection revision does not exist")
        }
        guard try await store.get(.connection, cId)["state"]?.stringValue == "enabled" else {
            throw ContractError(.resourceDisabled, "the connection is disabled")
        }
        guard connection["protocol"]?.stringValue == AiProtocol.openaiChat.rawValue else {
            throw ContractError(.unsupportedProtocol, "only openai_chat is implemented")
        }
        guard let credentialId = try await store.credentialId(connectionId: cId, revision: cRev) else {
            throw ContractError(.credentialRequired, "the connection has no credential")
        }
        switch try await store.credentialState(credentialId) {
        case "active": break
        case "revoked": throw ContractError(.credentialRevoked, "the connection's credential was revoked")
        default: throw ContractError(.credentialRequired, "the connection's credential is not active")
        }
        return try GuiCandidate(candidateIndex: index, guiProfile: profile, modelProfile: model, connection: connection,
                                credentialIdentityRef: credentialId, authorizationScopeRef: scope, dataScopeRef: dataScopeRef)
    }

    /// A caller scope as a resource reference (pattern ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$).
    static func scopeRef(_ scope: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        var s = String(scope.map { allowed.contains($0) ? $0 : "-" }.prefix(120))
        if s.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { s = "c" + s }
        return s
    }
}
