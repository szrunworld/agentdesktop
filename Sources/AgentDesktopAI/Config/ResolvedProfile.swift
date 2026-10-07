import AgentDesktopContracts
import Foundation

/// A GUI profile revision with the exact model profile and connection
/// revisions it pins, ready to call (spec §04, §04.1). Built from immutable
/// revision snapshots; the current default is never consulted.
public struct ResolvedGuiProfile: Sendable {
    public let model: AiResolvedModel
    /// The bodies of the three pinned revisions, as the contract renders them.
    public let guiProfile: JSONValue
    public let modelProfile: JSONValue
    public let connection: JSONValue

    public var guiProfileId: String { guiProfile["guiProfileId"]?.stringValue ?? "" }
    public var guiProfileRevision: Int { guiProfile["revision"]?.intValue ?? 0 }
    public var adapterId: String { guiProfile["adapterId"]?.stringValue ?? "" }
    public var coordinateProtocol: String? { guiProfile["coordinateProtocol"]?.stringValue }
    public var limits: JSONValue { guiProfile["limits"] ?? .obj([]) }
}

extension ConfigStore {
    /// Resolve a GUI profile at `revision` (which must be its current
    /// revision) to the candidate a run or a capability test calls.
    ///
    /// - Throws: NOT_FOUND, CONFIG_CONFLICT (stale revision), RESOURCE_DISABLED
    ///   (any of the three is disabled: no new binding), UNSUPPORTED_PROTOCOL,
    ///   VALIDATION_ERROR (stored options outside the contract).
    public func resolveGuiProfile(_ guiProfileId: String, revision: Int, callerScope: String) throws -> ResolvedGuiProfile {
        guard let gui = try load(.guiProfile, guiProfileId) else {
            throw ContractError(.notFound, "GUI profile not found")
        }
        guard gui.currentRevision == revision else {
            throw ContractError(.configConflict, "the GUI profile changed; reload and retry",
                                details: .obj([("currentRevision", .int(gui.currentRevision))]))
        }
        guard gui.state == "enabled" else { throw ContractError(.resourceDisabled, "the GUI profile is disabled") }
        guard let mpId = gui.refId, let mpRev = gui.refRevision,
              let model = try load(.modelProfile, mpId),
              let modelBody = try revisionBody(.modelProfile, mpId, mpRev) else {
            throw ContractError(.notFound, "the GUI profile's model profile is gone")
        }
        guard model.state == "enabled" else { throw ContractError(.resourceDisabled, "the model profile is disabled") }
        guard let connId = modelBody["connectionId"]?.stringValue, let connRev = modelBody["connectionRevision"]?.intValue,
              let conn = try load(.connection, connId),
              let connBody = try revisionBody(.connection, connId, connRev),
              let credential = try credentialId(connectionId: connId, revision: connRev) else {
            throw ContractError(.notFound, "the model profile's connection is gone")
        }
        guard conn.state == "enabled" else { throw ContractError(.resourceDisabled, "the connection is disabled") }
        guard let proto = connBody["protocol"]?.stringValue.flatMap(AiProtocol.init(rawValue:)), proto.isImplemented else {
            throw ContractError(.unsupportedProtocol, "only openai_chat is implemented in this version")
        }
        guard let base = connBody["baseUrl"]?.stringValue.flatMap(URL.init(string:)) else {
            throw ContractError(.validationError, "the connection's baseUrl is invalid")
        }
        let options = try ModelRequestOptions.parse(modelBody["requestOptions"] ?? .obj([]))
        let resolved = AiResolvedModel(
            connection: AiConnectionSnapshot(
                connectionId: connId, revision: Revision(connRev), name: connBody["name"]?.stringValue ?? "",
                apiProtocol: proto, baseUrl: base, credentialIdentityRef: credential,
                timeoutMs: connBody["timeoutMs"]?.intValue ?? 30_000,
                state: .enabled),
            model: AiModelSnapshot(
                modelProfileId: mpId, revision: Revision(mpRev), connectionId: connId,
                connectionRevision: Revision(connRev), modelId: modelBody["modelId"]?.stringValue ?? "",
                requestOptions: options, maxOutputTokens: modelBody["maxOutputTokens"]?.intValue ?? 1024),
            authorizationScopeRef: "caller:\(callerScope)", dataScopeRef: "local")
        let guiBody = try revisionBody(.guiProfile, guiProfileId, revision) ?? gui.body
        return ResolvedGuiProfile(model: resolved, guiProfile: guiBody, modelProfile: modelBody, connection: connBody)
    }
}
