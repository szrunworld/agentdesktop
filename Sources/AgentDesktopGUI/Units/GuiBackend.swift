import AgentDesktopAI
import AgentDesktopProtocol
import Foundation

/// What the Runtime's execution backend can do, reported as is by
/// runtime.capabilities. Nothing is claimed that has no evidence.
public struct GuiBackendFeatures: Sendable {
    public var actions: [GuiActionKind]
    /// The leaf predicates the backend can verify: `elementPredicates` when
    /// it reads the bound window's elements (role, label, value), else none.
    public var verificationPredicates: [String]

    /// What a backend that reads the bound window's element tree verifies.
    public static let elementPredicates = ["element_text_equals", "element_exists", "value_equals_parameter"]
    public var directApiWithoutAi: Bool
    public var deterministicReplayWithoutAi: Bool
    public var independentDesktopConcurrency: Bool
    /// "NOT_RUN", "VERIFIED" or "FAILED" (G0 evidence for this backend).
    public var nativeIsolationEvidence: String

    public init(actions: [GuiActionKind], verificationPredicates: [String], directApiWithoutAi: Bool = false,
                deterministicReplayWithoutAi: Bool = false, independentDesktopConcurrency: Bool = false,
                nativeIsolationEvidence: String = "NOT_RUN") {
        self.actions = actions; self.verificationPredicates = verificationPredicates
        self.directApiWithoutAi = directApiWithoutAi; self.deterministicReplayWithoutAi = deterministicReplayWithoutAi
        self.independentDesktopConcurrency = independentDesktopConcurrency
        self.nativeIsolationEvidence = nativeIsolationEvidence
    }
}

/// The Runtime's execution boundary as the GUI executor sees it. Without
/// one, real GUI input stays off: unit.run answers unsupported_backend.
public struct GuiExecutionBackend: Sendable {
    public let ports: GuiExplorerPorts
    public let features: GuiBackendFeatures

    public init(ports: GuiExplorerPorts, features: GuiBackendFeatures) {
        self.ports = ports
        self.features = features
    }
}

/// Where the explorer writes what a run did. Since A6 this is the
/// Runtime's unit Run (UnitRunRecorder).
/// Nothing written may carry screenshot bytes, typed text or secrets.
public protocol GuiRunRecording: Actor {
    /// Set once a record could not be written: no further model call or input.
    var writeFailed: Bool { get }
    /// Mirror the lifecycle's new events.
    func sync() async
    func stepStarted(stepIndex: Int) async
    func observation(_ o: Observation) async
    func inferenceStarted(stepIndex: Int) async
    func inference(_ r: GuiInferenceReceipt, discarded: Bool) async
    /// A step's model calls failed with no receipt (they still happened).
    func inferenceFailed(stepIndex: Int, error: Error) async
    func proposed(_ p: GuiProposal) async
    func rejected(stepIndex: Int, reason: String) async
    func recovered(stepIndex: Int) async
    func action(_ r: GuiActionReceipt, stepIndex: Int) async
    func verified(_ v: GoalVerification) async
}

/// The `gui` section of runtime.capabilities: what the GUI execution
/// backend supports, reported as is.
public enum GuiCapabilities {
    public static func capabilities(features f: GuiBackendFeatures?, codecs: GuiCodecRegistry) -> JSONValue {
        return .obj([
            ("implementedAiProtocols", .array([.string(AiProtocol.openaiChat.rawValue)])),
            ("verificationPredicates", .array((f?.verificationPredicates ?? []).map(JSONValue.string))),
            ("guiAdapters", .array(codecs.availableAdapters.map { .string($0.rawValue) })),
            // What the codecs can propose; with no backend nothing is executed
            // (verificationPredicates is empty and unit.run is off).
            ("actions", .array((f?.actions ?? GuiActionKind.allCases).map { .string($0.rawValue) })),
            ("limits", GuiLimits.ceiling.json),
            ("features", .obj([
                ("directApiWithoutAi", .bool(f?.directApiWithoutAi ?? false)),
                ("deterministicReplayWithoutAi", .bool(f?.deterministicReplayWithoutAi ?? false)),
                ("fixtureAdapterEnabled", .bool(codecs.fixtureAdapterEnabled)),
                ("independentDesktopConcurrency", .bool(f?.independentDesktopConcurrency ?? false)),
                ("nativeIsolationEvidence", .string(f?.nativeIsolationEvidence ?? "NOT_RUN")),
            ])),
        ])
    }

    /// Objects with sorted keys, so equal values encode equally.
    public static func canonical(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .object(m): return .object(m.sorted { $0.key < $1.key }.map { (key: $0.key, value: canonical($0.value)) })
        case let .array(a): return .array(a.map(canonical))
        default: return v
        }
    }
}
