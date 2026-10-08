import AgentDesktopProtocol
import Foundation

/// The configuration commands of contract v1 as `ServiceHandler`s backed by
/// one `ConfigStore`. Params arrive already validated against
/// `<command>_params`; results are checked by `ServiceRouter`.
public struct ConfigApplicationService: Sendable {
    public let store: ConfigStore

    public init(store: ConfigStore) {
        self.store = store
    }

    public static let commands: [String] = [
        "ai.connections.list", "ai.connections.get", "ai.connections.create", "ai.connections.update",
        "ai.connections.disable", "ai.connections.delete", "ai.credentials.rotate",
        "ai.modelProfiles.list", "ai.modelProfiles.get", "ai.modelProfiles.create", "ai.modelProfiles.update",
        "ai.modelProfiles.disable", "ai.modelProfiles.delete",
        "ai.profiles.list", "ai.profiles.get", "ai.profiles.create", "ai.profiles.update",
        "ai.profiles.disable", "ai.profiles.delete",
        "ai.profiles.default.get", "ai.profiles.setDefault",
    ]

    /// Handlers for one caller. Idempotency records are scoped to
    /// `callerScope`, so another caller's key never returns this caller's
    /// result (RPC-007).
    public func handlers(callerScope: String) -> [String: ServiceHandler] {
        var out: [String: ServiceHandler] = [:]
        for command in Self.commands {
            out[command] = { req in try await self.handle(req, callerScope: callerScope) }
        }
        return out
    }

    public func handle(_ req: ServiceRequest, callerScope: String) async throws -> JSONValue {
        let p = req.params
        func str(_ k: String) -> String { p[k]?.stringValue ?? "" }
        func int(_ k: String) -> Int { p[k]?.intValue ?? 0 }
        let s = store
        let scope = callerScope
        let key = req.idempotencyKey
        let command = req.method

        func mutate(_ body: @escaping @Sendable (isolated ConfigStore) throws -> JSONValue) async throws -> JSONValue {
            try await s.runIdempotent(scope: scope, command: command, key: key, semantic: p, body)
        }

        switch req.method {
        case "ai.connections.list":
            return try await s.list(.connection, limit: p["limit"]?.intValue, cursor: p["cursor"]?.stringValue,
                                    includeDisabled: p["includeDisabled"]?.boolValue ?? false)
        case "ai.connections.get":
            return try await s.get(.connection, str("connectionId"))
        case "ai.connections.create":
            let name = str("name"), proto = str("protocol"), url = str("baseUrl"), timeout = int("timeoutMs")
            let apiKey = p["credential"]?["apiKey"]?.stringValue ?? ""
            return try await mutate { try $0.createConnection(name: name, protocol: proto, baseUrl: url, timeoutMs: timeout, apiKey: apiKey) }
        case "ai.connections.update":
            let id = str("connectionId"), rev = int("expectedRevision"), patch = p["patch"] ?? .obj([])
            return try await mutate { try $0.updateConnection(id, expectedRevision: rev, patch: patch) }
        case "ai.connections.disable":
            let id = str("connectionId"), rev = int("expectedRevision")
            return try await mutate { try $0.disable(.connection, id, expectedRevision: rev) }
        case "ai.connections.delete":
            let id = str("connectionId"), rev = int("expectedRevision")
            return try await mutate { try $0.delete(.connection, id, expectedRevision: rev) }
        case "ai.credentials.rotate":
            let id = str("connectionId"), rev = int("expectedRevision")
            let apiKey = p["credential"]?["apiKey"]?.stringValue ?? ""
            return try await mutate { try $0.rotateCredential(id, expectedRevision: rev, apiKey: apiKey) }

        case "ai.modelProfiles.list":
            return try await s.list(.modelProfile, limit: p["limit"]?.intValue, cursor: p["cursor"]?.stringValue,
                                    includeDisabled: p["includeDisabled"]?.boolValue ?? false,
                                    connectionId: p["connectionId"]?.stringValue)
        case "ai.modelProfiles.get":
            return try await s.get(.modelProfile, str("modelProfileId"))
        case "ai.modelProfiles.create":
            return try await mutate { try $0.createModelProfile(p) }
        case "ai.modelProfiles.update":
            let id = str("modelProfileId"), rev = int("expectedRevision"), patch = p["patch"] ?? .obj([])
            return try await mutate { try $0.updateModelProfile(id, expectedRevision: rev, patch: patch) }
        case "ai.modelProfiles.disable":
            let id = str("modelProfileId"), rev = int("expectedRevision")
            return try await mutate { try $0.disable(.modelProfile, id, expectedRevision: rev) }
        case "ai.modelProfiles.delete":
            let id = str("modelProfileId"), rev = int("expectedRevision")
            return try await mutate { try $0.delete(.modelProfile, id, expectedRevision: rev) }

        case "ai.profiles.list":
            return try await s.list(.guiProfile, limit: p["limit"]?.intValue, cursor: p["cursor"]?.stringValue,
                                    includeDisabled: p["includeDisabled"]?.boolValue ?? false)
        case "ai.profiles.get":
            return try await s.get(.guiProfile, str("guiProfileId"))
        case "ai.profiles.create":
            return try await mutate { try $0.createGuiProfile(p) }
        case "ai.profiles.update":
            let id = str("guiProfileId"), rev = int("expectedRevision"), patch = p["patch"] ?? .obj([])
            return try await mutate { try $0.updateGuiProfile(id, expectedRevision: rev, patch: patch) }
        case "ai.profiles.disable":
            let id = str("guiProfileId"), rev = int("expectedRevision")
            return try await mutate { try $0.disable(.guiProfile, id, expectedRevision: rev) }
        case "ai.profiles.delete":
            let id = str("guiProfileId"), rev = int("expectedRevision")
            return try await mutate { try $0.delete(.guiProfile, id, expectedRevision: rev) }
        case "ai.profiles.default.get":
            return try await s.defaultProfile()
        case "ai.profiles.setDefault":
            let id = p["guiProfileId"]?.stringValue
            let dRev = int("expectedDefaultRevision")
            let pRev = p["expectedProfileRevision"]?.intValue
            return try await mutate { try $0.setDefault(guiProfileId: id, expectedDefaultRevision: dRev, expectedProfileRevision: pRev) }
        default:
            throw ContractError(.unsupportedCommand, "not a configuration command")
        }
    }
}

extension ConfigStore {
    /// `idempotent` with the mutation running inside the actor, so the
    /// check, the side effect and the record never interleave with another
    /// request for the same key.
    public func runIdempotent(scope: String, command: String, key: String?, semantic: JSONValue,
                              _ body: @Sendable (isolated ConfigStore) throws -> JSONValue) throws -> JSONValue {
        try idempotent(scope: scope, command: command, key: key, semantic: semantic) { try body(self) }
    }
}
