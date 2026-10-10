import Foundation

// Run-level types of contract v1 (spec §04, §06.4, §09): the immutable
// binding, the receipts and the verification result. Each knows its wire
// form; tests check every form against domain.schema.json.

public enum GuiTime {
    /// ISO 8601 with milliseconds, UTC.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// The only V1 completion condition (spec §06.4): a static text element of
/// the bound window whose whole text equals `text`. Caller-supplied, fixed
/// in the binding; a model can neither write nor relax it.
public struct GuiVerification: Equatable, Sendable {
    public let text: String

    public init(text: String) { self.text = text }

    public init(json: JSONValue) throws {
        guard json["kind"]?.stringValue == "element_text_equals", json["role"]?.stringValue == "static_text",
              let text = json["text"]?.stringValue, !text.isEmpty else {
            throw ContractError(.validationError, "verification must be element_text_equals on static_text")
        }
        self.text = text
    }

    public var json: JSONValue {
        .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")), ("text", .string(text))])
    }
}

/// Per-run limits (domain GuiLimits). The values may only tighten the
/// server ceilings of spec §09.1.
public struct GuiLimits: Equatable, Sendable {
    public var maxSteps = 20
    public var maxWallTimeMs = 120_000
    public var maxModelAttemptsPerStep = 2
    public var maxTotalModelAttempts = 30
    public var maxOutputTokens = 1024
    public var maxWaitMs = 5000
    public var maxScreenshots = 5
    public var maxImageEncodedBytes = 8_388_608
    public var requireReportedUsage = false

    public static let ceiling = GuiLimits()

    public init() {}

    public init(json: JSONValue) throws {
        func int(_ k: String, _ ceiling: Int, min: Int = 1) throws -> Int {
            guard let v = json[k]?.intValue, v >= min, v <= ceiling else {
                throw ContractError(.validationError, "limits.\(k) must be \(min) to \(ceiling)")
            }
            return v
        }
        let c = GuiLimits.ceiling
        maxSteps = try int("maxSteps", c.maxSteps)
        maxWallTimeMs = try int("maxWallTimeMs", c.maxWallTimeMs, min: 1000)
        maxModelAttemptsPerStep = try int("maxModelAttemptsPerStep", c.maxModelAttemptsPerStep)
        maxTotalModelAttempts = try int("maxTotalModelAttempts", c.maxTotalModelAttempts)
        maxOutputTokens = try int("maxOutputTokens", c.maxOutputTokens)
        maxWaitMs = try int("maxWaitMs", c.maxWaitMs, min: 0)
        maxScreenshots = try int("maxScreenshots", c.maxScreenshots)
        maxImageEncodedBytes = try int("maxImageEncodedBytes", c.maxImageEncodedBytes)
        requireReportedUsage = json["requireReportedUsage"]?.boolValue ?? false
    }

    public var json: JSONValue {
        .obj([("maxSteps", .int(maxSteps)), ("maxWallTimeMs", .int(maxWallTimeMs)),
              ("maxModelAttemptsPerStep", .int(maxModelAttemptsPerStep)),
              ("maxTotalModelAttempts", .int(maxTotalModelAttempts)), ("maxOutputTokens", .int(maxOutputTokens)),
              ("maxWaitMs", .int(maxWaitMs)), ("maxScreenshots", .int(maxScreenshots)),
              ("maxImageEncodedBytes", .int(maxImageEncodedBytes)), ("requireReportedUsage", .bool(requireReportedUsage))])
    }
}

/// One fully resolved candidate (domain ResolvedGuiCandidate): the exact
/// GUI profile, model profile and connection revisions with the credential
/// identity, deep-copied at binding time.
public struct GuiCandidate: Equatable, Sendable {
    public let candidateIndex: Int
    public let guiProfile: JSONValue
    public let modelProfile: JSONValue
    public let connection: JSONValue
    public let credentialIdentityRef: String
    public let authorizationScopeRef: String
    public let dataScopeRef: String

    public let guiProfileId: String
    public let guiProfileRevision: Int
    public let adapterId: String
    public let coordinateProtocol: String
    public let limits: GuiLimits
    public let resolvedModel: AiResolvedModel

    public init(candidateIndex: Int, guiProfile: JSONValue, modelProfile: JSONValue, connection: JSONValue,
                credentialIdentityRef: String, authorizationScopeRef: String, dataScopeRef: String) throws {
        func bad(_ m: String) -> ContractError { ContractError(.validationError, "candidate: \(m)") }
        guard let gpId = guiProfile["guiProfileId"]?.stringValue, let gpRev = guiProfile["revision"]?.intValue,
              let adapter = guiProfile["adapterId"]?.stringValue,
              let coords = guiProfile["coordinateProtocol"]?.stringValue,
              let limitsJSON = guiProfile["limits"] else { throw bad("incomplete GUI profile") }
        guard let mpId = modelProfile["modelProfileId"]?.stringValue, let mpRev = modelProfile["revision"]?.intValue,
              let modelId = modelProfile["modelId"]?.stringValue,
              let maxOut = modelProfile["maxOutputTokens"]?.intValue,
              let mpConn = modelProfile["connectionId"]?.stringValue,
              let mpConnRev = modelProfile["connectionRevision"]?.intValue else { throw bad("incomplete model profile") }
        guard let cId = connection["connectionId"]?.stringValue, let cRev = connection["revision"]?.intValue,
              let name = connection["name"]?.stringValue, let proto = connection["protocol"]?.stringValue,
              let base = connection["baseUrl"]?.stringValue, let url = URL(string: base),
              let timeout = connection["timeoutMs"]?.intValue else { throw bad("incomplete connection") }
        guard guiProfile["modelProfileId"]?.stringValue == mpId, guiProfile["modelProfileRevision"]?.intValue == mpRev,
              mpConn == cId, mpConnRev == cRev else { throw bad("revision chain does not line up") }
        guard let apiProtocol = AiProtocol(rawValue: proto) else { throw ContractError(.unsupportedProtocol, "unknown protocol") }
        self.candidateIndex = candidateIndex
        self.guiProfile = guiProfile
        self.modelProfile = modelProfile
        self.connection = connection
        self.credentialIdentityRef = credentialIdentityRef
        self.authorizationScopeRef = authorizationScopeRef
        self.dataScopeRef = dataScopeRef
        self.guiProfileId = gpId
        self.guiProfileRevision = gpRev
        self.adapterId = adapter
        self.coordinateProtocol = coords
        self.limits = try GuiLimits(json: limitsJSON)
        let state: ResourceState = connection["state"]?.stringValue == "disabled" ? .disabled : .enabled
        self.resolvedModel = AiResolvedModel(
            connection: AiConnectionSnapshot(connectionId: cId, revision: Revision(cRev), name: name, apiProtocol: apiProtocol,
                                             baseUrl: url, credentialIdentityRef: credentialIdentityRef,
                                             timeoutMs: timeout, state: state),
            model: AiModelSnapshot(modelProfileId: mpId, revision: Revision(mpRev), connectionId: cId,
                                   connectionRevision: Revision(cRev), modelId: modelId,
                                   requestOptions: try ModelRequestOptions.parse(modelProfile["requestOptions"] ?? .obj([])),
                                   maxOutputTokens: maxOut),
            authorizationScopeRef: authorizationScopeRef, dataScopeRef: dataScopeRef)
    }

    public var json: JSONValue {
        .obj([("candidateIndex", .int(candidateIndex)), ("guiProfile", guiProfile), ("modelProfile", modelProfile),
              ("connection", connection), ("credentialIdentityRef", .string(credentialIdentityRef)),
              ("authorizationScopeRef", .string(authorizationScopeRef)), ("dataScopeRef", .string(dataScopeRef))])
    }
}

/// The immutable binding of one run (spec §04, D07). Fixed at start; a later
/// change of the default profile, a profile edit or a disable never alters it.
public struct GuiRunBinding: Equatable, Sendable {
    public let runId: String
    public let sessionId: String
    public let desktopId: String
    public let goal: String
    public let bindingEpoch: UInt64
    /// The generation the run started with; cancellation moves the run's
    /// current generation, never this value.
    public let runGeneration: UInt64
    public let policyRevision: Int
    public let boundAt: Date
    public let primary: GuiCandidate
    public let fallbackCandidates: [GuiCandidate]
    public let verification: GuiVerification
    /// unit.run: the other predicates of `verification.all` (A6); every one
    /// must hold on the same fresh observation.
    public let moreVerifications: [GuiVerification]
    public let allowedActions: [GuiActionKind]
    /// unit.run `limits`, already folded into the profile's (they only narrow).
    public let narrowedLimits: GuiLimits?

    public init(runId: String, sessionId: String, desktopId: String, goal: String, bindingEpoch: UInt64,
                runGeneration: UInt64 = 1, policyRevision: Int, boundAt: Date, primary: GuiCandidate,
                fallbackCandidates: [GuiCandidate], verification: GuiVerification, allowedActions: [GuiActionKind],
                moreVerifications: [GuiVerification] = [], narrowedLimits: GuiLimits? = nil) {
        precondition(fallbackCandidates.count <= 1)
        self.runId = runId; self.sessionId = sessionId; self.desktopId = desktopId; self.goal = goal
        self.bindingEpoch = bindingEpoch; self.runGeneration = runGeneration; self.policyRevision = policyRevision
        self.boundAt = boundAt; self.primary = primary; self.fallbackCandidates = fallbackCandidates
        self.verification = verification; self.allowedActions = allowedActions
        self.moreVerifications = moreVerifications; self.narrowedLimits = narrowedLimits
    }

    /// Every predicate the run must see hold.
    public var verifications: [GuiVerification] { [verification] + moreVerifications }

    /// Limits of the run: the primary profile's, narrowed by unit.run.
    public var limits: GuiLimits { narrowedLimits ?? primary.limits }
    public var candidates: [GuiCandidate] { [primary] + fallbackCandidates }

    public var json: JSONValue {
        .obj([("runId", .string(runId)), ("sessionId", .string(sessionId)), ("desktopId", .string(desktopId)),
              ("goal", .string(goal)), ("bindingEpoch", .int(Int(bindingEpoch))),
              ("runGeneration", .int(Int(runGeneration))), ("policyRevision", .int(policyRevision)),
              ("boundAt", .string(GuiTime.iso(boundAt))), ("primary", primary.json),
              ("fallbackCandidates", .array(fallbackCandidates.map(\.json))), ("verification", verification.json),
              ("allowedActions", .array(allowedActions.map { .string($0.rawValue) }))])
    }
}

/// The receipt of one model call made for a GUI step (domain InferenceReceipt).
public struct GuiInferenceReceipt: Equatable, Sendable {
    public let record: AiCallRecord
    public let snapshotId: String
    public let runId: String
    public let stepIndex: Int
    public let candidate: GuiCandidate
    public let proposalId: String?

    public init(record: AiCallRecord, snapshotId: String, runId: String, stepIndex: Int,
                candidate: GuiCandidate, proposalId: String?) {
        self.record = record; self.snapshotId = snapshotId; self.runId = runId
        self.stepIndex = stepIndex; self.candidate = candidate; self.proposalId = proposalId
    }

    public var inferenceAttemptId: String { record.context.inferenceAttemptId }

    public var json: JSONValue {
        let r = record
        let status: String = r.state.rawValue
        // Code, message and retryable only: upstream details stay in the ledger.
        let error: JSONValue = r.error.map { e in
            ContractError(e.code, e.message.isEmpty ? e.code.rawValue : String(e.message.prefix(512)), retryable: e.retryable).json
        } ?? .null
        let c = candidate.resolvedModel
        var m: [(String, JSONValue)] = []
        m.append(("inferenceAttemptId", .string(r.context.inferenceAttemptId)))
        m.append(("requestId", .string(r.context.requestId.uuidString.lowercased())))
        m.append(("upstreamRequestId", r.upstreamRequestId.map { JSONValue.string(String($0.prefix(256))) } ?? .null))
        m.append(("snapshotId", .string(snapshotId)))
        m.append(("runId", .string(runId)))
        m.append(("stepIndex", .int(stepIndex)))
        m.append(("candidateIndex", .int(candidate.candidateIndex)))
        m.append(("connectionId", .string(c.connection.connectionId)))
        m.append(("connectionRevision", .int(Int(c.connection.revision))))
        m.append(("modelProfileId", .string(c.model.modelProfileId)))
        m.append(("modelProfileRevision", .int(Int(c.model.revision))))
        m.append(("guiProfileId", .string(candidate.guiProfileId)))
        m.append(("guiProfileRevision", .int(candidate.guiProfileRevision)))
        m.append(("requestedModelId", .string(r.requestedModelId)))
        m.append(("actualModelId", r.actualModelId.map { JSONValue.string(String($0.prefix(160))) } ?? .null))
        m.append(("credentialIdentityRef", .string(candidate.credentialIdentityRef)))
        m.append(("startedAt", .string(GuiTime.iso(r.startedAt))))
        m.append(("endedAt", .string(GuiTime.iso(r.endedAt))))
        m.append(("latencyMs", .int(min(max(r.latencyMs, 0), 120_000))))
        m.append(("status", .string(status)))
        m.append(("usage", r.usage?.json ?? .null))
        m.append(("cost", r.cost?.json ?? .null))
        m.append(("proposalId", proposalId.map(JSONValue.string) ?? .null))
        m.append(("error", error))
        return .obj(m)
    }
}

public enum DeliveryState: String, Sendable {
    case notSent = "not_sent", submitted, confirmed, unknown, rejected
}

/// What the Runtime's executor reports for one action (domain ActionReceipt).
/// `submitted` is not `confirmed`, and neither is business success.
public struct GuiActionReceipt: Equatable, Sendable {
    public let actionId: String
    public let proposalId: String
    public let runId: String
    public let stamp: ObservationStamp
    public let actionType: GuiActionKind
    public let deliveryState: DeliveryState
    public let executionTarget: TargetIdentity?
    public let inputPath: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let evidenceRefs: [String]
    public let createdAt: Date
    public let updatedAt: Date
    public let confirmationObservationId: String?
    public let reasonCode: String?

    public init(actionId: String, proposalId: String, runId: String, stamp: ObservationStamp, actionType: GuiActionKind,
                deliveryState: DeliveryState, executionTarget: TargetIdentity?, inputPath: String?, startedAt: Date?,
                endedAt: Date?, evidenceRefs: [String], createdAt: Date, updatedAt: Date,
                confirmationObservationId: String?, reasonCode: String?) {
        self.actionId = actionId; self.proposalId = proposalId; self.runId = runId; self.stamp = stamp
        self.actionType = actionType; self.deliveryState = deliveryState; self.executionTarget = executionTarget
        self.inputPath = inputPath; self.startedAt = startedAt; self.endedAt = endedAt; self.evidenceRefs = evidenceRefs
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.confirmationObservationId = confirmationObservationId; self.reasonCode = reasonCode
    }

    public var json: JSONValue {
        func date(_ d: Date?) -> JSONValue { d.map { .string(GuiTime.iso($0)) } ?? .null }
        return .obj([
            ("actionId", .string(actionId)), ("proposalId", .string(proposalId)), ("runId", .string(runId)),
            ("desktopId", .string(stamp.desktopId)), ("snapshotId", .string(stamp.snapshotId)),
            ("bindingEpoch", .int(Int(stamp.bindingEpoch))), ("runGeneration", .int(Int(stamp.runGeneration))),
            ("actionType", .string(actionType.rawValue)), ("deliveryState", .string(deliveryState.rawValue)),
            ("executionTarget", executionTarget?.json ?? .null), ("inputPath", inputPath.map(JSONValue.string) ?? .null),
            ("startedAt", date(startedAt)), ("endedAt", date(endedAt)),
            ("evidenceRefs", .array(evidenceRefs.map(JSONValue.string))),
            ("createdAt", .string(GuiTime.iso(createdAt))), ("updatedAt", .string(GuiTime.iso(updatedAt))),
            ("confirmationObservationId", confirmationObservationId.map(JSONValue.string) ?? .null),
            ("reasonCode", reasonCode.map(JSONValue.string) ?? .null),
        ])
    }
}

/// A verifier's verdict on one observation (domain GoalVerification).
public struct GoalVerification: Equatable, Sendable {
    public enum Status: String, Sendable { case notRun = "not_run", passed, failed }
    public let status: Status
    public let observationId: String?
    public let verifierId: String?
    public let checkedAt: Date?

    public init(status: Status, observationId: String?, verifierId: String?, checkedAt: Date?) {
        self.status = status; self.observationId = observationId; self.verifierId = verifierId; self.checkedAt = checkedAt
    }

    public static let notRun = GoalVerification(status: .notRun, observationId: nil, verifierId: nil, checkedAt: nil)

    public var json: JSONValue {
        .obj([("status", .string(status.rawValue)), ("observationId", observationId.map(JSONValue.string) ?? .null),
              ("verifierId", verifierId.map(JSONValue.string) ?? .null),
              ("checkedAt", checkedAt.map { .string(GuiTime.iso($0)) } ?? .null)])
    }
}
