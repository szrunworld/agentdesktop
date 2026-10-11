import AgentDesktopProtocol
import Foundation

/// Turns what the Runtime advertises into the tasks an editor may start.
/// Nothing here names a business task: a task exists only when the Runtime
/// lists its entry method in `runtime.capabilities`.
///
/// Today runtime/1 has no task entry (unit.run is `frozen`, A6), so the
/// catalog is empty. Once the Runtime lists `unit.run`:
///   - with `ai.profiles.list` also listed, each enabled GUI profile becomes
///     one task `unit.run/<guiProfileId>`, pinned to the revision shown;
///   - otherwise one task `unit.run` that uses the Runtime's default profile.
/// The input schema is the contract's `unit_run_params` minus the fields
/// the bridge fills itself (desktopId, guiProfileId, expectedProfileRevision).
public struct ACPTaskCatalog: Sendable {
    public static let unitRunMethod = "unit.run"
    public static let profilesMethod = "ai.profiles.list"

    /// Whether this connection may list GUI profiles at all: only when its
    /// handshake says it is the owner. A paired client (every socket client
    /// after A4) does not ask.
    public static func listsProfiles(principal: JSONValue?) -> Bool {
        principal?["role"]?.stringValue == "owner"
    }

    /// A definite refusal of `ai.profiles.list` to this caller: `ai.*` is
    /// the owner's, so a paired client gets `permission_denied` (reason
    /// `owner_only`, or `unverified_identity` under A4 R1). The catalog then
    /// falls back to the default-profile task. Nothing else counts.
    public static func profilesRefusedToCaller(_ e: RuntimeError) -> Bool {
        guard e.code == "permission_denied" else { return false }
        // Reasons the Runtime gives for an owner-only method (accessError,
        // A4 R1); a permission_denied for anything else still fails.
        return ["owner_only", "unverified_identity"].contains(e.details?["reason"]?.stringValue ?? "")
    }

    /// Params a caller may never pass: identity and run axes come from the
    /// Runtime's authenticated context (ADR v2.2, A6 F40-06 row 1).
    public static let forbiddenInputKeys: Set<String> = [
        "origin", "lifetime", "ownership", "clientId", "agentId", "trusted", "principal",
    ]
    /// Filled by the bridge from the session and the catalog entry.
    public static let bridgeFilledKeys: Set<String> = ["desktopId", "guiProfileId", "expectedProfileRevision"]

    public struct Entry: Equatable, Sendable {
        public var task: ACPExposedTask
        /// The Runtime method that starts it.
        public var method: String
        public var guiProfileId: String?
        public var profileRevision: Int?
    }

    public enum Refusal: Error, Equatable {
        case refused(code: String, message: String)
    }

    /// `unit_run_params` as frozen in runtime.schema.json, or nil if absent.
    public let unitRunParams: JSONValue?

    public init(unitRunParams: JSONValue? = ACPTaskCatalog.contractUnitRunParams) {
        self.unitRunParams = unitRunParams
    }

    public static let contractUnitRunParams: JSONValue? = {
        guard let schema = try? StrictJSON.parse(RuntimeContract.embedded.schema) else { return nil }
        return schema["$defs"]?["unit_run_params"]
    }()

    /// Method names in a `runtime.capabilities` answer.
    public static func methods(_ capabilities: JSONValue) -> Set<String> {
        Set((capabilities["interface"]?["methods"]?.arrayValue ?? []).compactMap { $0["method"]?.stringValue })
    }

    /// The tasks for this Runtime. `profiles` are `ai.profiles.list` items,
    /// nil when that method is not available.
    public func entries(methods: Set<String>, profiles: [JSONValue]?) -> [Entry] {
        guard methods.contains(Self.unitRunMethod), let schema = editorSchema() else { return [] }
        if let profiles, methods.contains(Self.profilesMethod) {
            return profiles.compactMap { p -> Entry? in
                guard p["state"]?.stringValue == "enabled", let id = p["guiProfileId"]?.stringValue,
                      let rev = p["revision"]?.intValue else { return nil }
                let name = p["name"]?.stringValue ?? id
                return Entry(task: task(taskType: "\(Self.unitRunMethod)/\(id)", displayName: name,
                                        description: "GUI unit run with profile \(name) (revision \(rev))", schema: schema),
                             method: Self.unitRunMethod, guiProfileId: id, profileRevision: rev)
            }
        }
        return [Entry(task: task(taskType: Self.unitRunMethod, displayName: "GUI unit run",
                                 description: "GUI unit run with the Runtime's default GUI profile", schema: schema),
                      method: Self.unitRunMethod, guiProfileId: nil, profileRevision: nil)]
    }

    /// The Runtime params for one submission, checked against the frozen
    /// schema before anything is sent.
    public func params(for entry: Entry, submission: ACPSubmission,
                       contract: RuntimeContract = .shared) -> Result<JSONValue, Refusal> {
        guard let members = submission.input.objectMembers else {
            return .failure(.refused(code: "invalid_argument", message: "task input must be a JSON object"))
        }
        if let bad = members.first(where: { Self.forbiddenInputKeys.contains($0.key) }) {
            return .failure(.refused(code: "ownership_escalation_denied",
                                     message: "\(bad.key) comes from the Runtime's authenticated context, never from input"))
        }
        if let bad = members.first(where: { $0.key == "guiProfileId" || $0.key == "expectedProfileRevision" }) {
            return .failure(.refused(code: "invalid_argument", message: "\(bad.key) is chosen by the task, not by input"))
        }
        let inputDesktop = submission.input["desktopId"]?.stringValue
        if let a = submission.desktopId, let b = inputDesktop, a != b {
            return .failure(.refused(code: "invalid_argument", message: "input desktopId differs from the session's Desktop"))
        }
        guard let desktopId = submission.desktopId ?? inputDesktop else {
            return .failure(.refused(code: "invalid_argument", message: "no Desktop chosen for this session"))
        }
        var params: [(String, JSONValue)] = [("desktopId", .string(desktopId))]
        params += members.filter { $0.key != "desktopId" }.map { ($0.key, $0.value) }
        if let id = entry.guiProfileId, let rev = entry.profileRevision {
            params.append(("guiProfileId", .string(id)))
            params.append(("expectedProfileRevision", .int(rev)))
        }
        let value = JSONValue.obj(params)
        let violations = contract.validate(value, "unit_run_params")
        guard violations.isEmpty else {
            return .failure(.refused(code: "schema_invalid", message: "task input breaks unit_run_params: "
                                     + violations.prefix(3).joined(separator: "; ")))
        }
        return .success(value)
    }

    private func task(taskType: String, displayName: String, description: String, schema: JSONValue) -> ACPExposedTask {
        ACPExposedTask(taskType: taskType, displayName: displayName, description: description, inputSchema: schema,
                       // goal.description is free text the contract accepts.
                       allowFreeText: true,
                       // GUI input on the user's apps: the editor asks first in Ask mode.
                       requiresApproval: true,
                       // Observations of app windows may hold personal data.
                       dataClassification: "desktop_content")
    }

    /// `unit_run_params` without the bridge-filled fields.
    func editorSchema() -> JSONValue? {
        guard let s = unitRunParams, let members = s.objectMembers else { return nil }
        var out: [(String, JSONValue)] = []
        for (k, v) in members {
            switch k {
            case "properties":
                out.append((k, .object((v.objectMembers ?? []).filter { !Self.bridgeFilledKeys.contains($0.key) })))
            case "required":
                out.append((k, .array((v.arrayValue ?? []).filter { !Self.bridgeFilledKeys.contains($0.stringValue ?? "") })))
            case "dependentRequired":
                continue
            default:
                out.append((k, v))
            }
        }
        return .object(out.map { (key: $0.0, value: $0.1) })
    }
}
