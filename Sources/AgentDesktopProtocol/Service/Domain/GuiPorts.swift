import Foundation

// Ports between the GUI layer and the Runtime (spec §03.1, §06.3–06.5).
// GUI code reaches the desktop only through these; the Runtime (the
// composition root) implements them. Only the explorer gets the execution
// port; GuiAiProvider never sees any of them.

/// An accessible element of the observed window, normalized across
/// platforms. Internal to the Runtime and the verifier: not a wire field.
public struct ObservedElement: Equatable, Sendable {
    /// Normalized role; V1 verification reads "static_text" only.
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// One observation plus what only the Runtime may hand out: the image bytes
/// of its own screenshots and the accessible elements read in the same pass.
public struct ObservationBundle: Sendable {
    public let observation: Observation
    /// Bytes of the observation's screenshots, by screenshotId. Never put
    /// into RPC JSON or ordinary logs.
    public let authorizedImages: [AiImageContent]
    /// Accessible elements of the bound window from this same observation.
    /// nil when the backend cannot read them, which makes the V1 predicate
    /// unavailable (CAPABILITY_MISMATCH), never vacuously true.
    public let elements: [ObservedElement]?

    public init(observation: Observation, authorizedImages: [AiImageContent], elements: [ObservedElement]?) {
        self.observation = observation
        self.authorizedImages = authorizedImages
        self.elements = elements
    }

    /// The image of the observation's first screenshot: what the model sees.
    public var currentImage: AiImageContent? {
        guard let first = observation.screenshots.first else { return nil }
        return authorizedImages.first { $0.screenshotId == first.screenshotId }
    }
}

public protocol GuiObservationPort: Sendable {
    /// A new observation of the run's bound target, stamped with the run's
    /// current generation. Throws STALE_GENERATION when `expectedGeneration`
    /// is no longer current.
    func observe(runId: String, expectedGeneration: UInt64) async throws -> ObservationBundle
}

public protocol GuiExecutionPort: Sendable {
    /// Execute one validated proposal. The Runtime rechecks control,
    /// desktop, conflict domain, generation, process and window identity,
    /// geometry, snapshot freshness, action and deadline before any input
    /// (spec §06.5). A proposal is not an execution capability. An unknown
    /// outcome is reported, never retried.
    func execute(_ proposal: GuiProposal, actionId: String) async throws -> GuiActionReceipt
}

/// Durable pre-call and pre-input records (spec §09.3). A failure to write
/// stops progress with AUDIT_UNAVAILABLE: no model call, no input.
public protocol GuiAuditPort: Sendable {
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) async throws
    func recordInference(_ receipt: GuiInferenceReceipt) async throws
    /// Returns the actionId the executor must use.
    func reserveAction(_ proposal: GuiProposal) async throws -> String
    /// The same, recording the target the input is aimed at, so an input
    /// whose verdict never arrives (a crash) can still be reported as
    /// unknown against its target after a restart (spec §07.4).
    func reserveAction(_ proposal: GuiProposal, target: TargetIdentity) async throws -> String
    func recordAction(_ receipt: GuiActionReceipt) async throws
}

extension GuiAuditPort {
    public func reserveAction(_ proposal: GuiProposal, target: TargetIdentity) async throws -> String {
        try await reserveAction(proposal)
    }
}

/// Resolves the candidates a new run binds to (spec §04.1, §18.2): the GUI
/// profile (explicit with its revision, or the current default), its model
/// profile and connection revisions, the credential identity, and at most
/// one fallback with the same adapter and coordinate protocol. Disabled,
/// deleted, stale or revoked references fail here, before any model call.
public protocol GuiBindingResolver: Sendable {
    func resolve(guiProfileId: String?, expectedProfileRevision: Int?, callerScope: String) async throws
        -> (primary: GuiCandidate, fallback: [GuiCandidate], policyRevision: Int)
}

/// Whether a candidate passed the GUI contract test (F40-06 row 12): its
/// model profile and connection revisions hold verified guiContract
/// evidence for `provenance`, the adapter, prompt, parser and coordinate
/// protocol the run will really use (the codec's, which the capability
/// test also records; not what a profile declares).
public protocol GuiContractEvidence: Sendable {
    func guiContractPassed(_ candidate: GuiCandidate, provenance: AdapterProvenance) async throws -> Bool
}
