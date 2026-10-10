import AgentDesktopAI
import AgentDesktopProtocol
import AgentDesktopGUI
import Foundation

/// What the service is built from. Everything with a side effect is
/// injected, so tests and the product host differ only here.
public struct AgentDesktopServiceOptions: Sendable {
    public var databasePath: String
    public var credentials: CredentialStore
    public var http: HTTPTransport
    public var clock: MonotonicClock
    public var config: ConfigOptions
    /// The Runtime's observation/execution ports. Nil keeps real GUI input
    /// closed: there is no unit.run executor, and the Runtime answers
    /// unsupported_backend (spec §15, G0). Its audit port is not used: a
    /// unit Run's records are the Runtime's (A6).
    public var executionBackend: GuiExecutionBackend?
    /// The inputs of these unit Runs in [from, to), for ai.usage.summary:
    /// the host reads them from the Runtime's RunStore.
    public var actionOutcomes: @Sendable ([String], Date, Date) throws -> (confirmed: Int, unknown: Int)
    public var prices: AiPriceTable?

    public init(databasePath: String,
                credentials: CredentialStore,
                http: HTTPTransport = URLSessionHTTPTransport(),
                clock: MonotonicClock = SystemMonotonicClock(),
                config: ConfigOptions = ConfigOptions(),
                executionBackend: GuiExecutionBackend? = nil,
                actionOutcomes: @escaping @Sendable ([String], Date, Date) throws -> (confirmed: Int, unknown: Int) = { _, _, _ in (0, 0) },
                prices: AiPriceTable? = nil) {
        self.databasePath = databasePath
        self.credentials = credentials
        self.http = http
        self.clock = clock
        self.config = config
        self.executionBackend = executionBackend
        self.actionOutcomes = actionOutcomes
        self.prices = prices
    }
}

/// The composition of the AI service: one configuration store, one model
/// service (shared by capability tests and GUI unit Runs, spec §18.1), the
/// unit.run executor, and the handlers of its runtime/1 methods. Nothing
/// here takes input; unit Runs reach a desktop only through the Runtime.
public final class AgentDesktopService: Sendable {
    public let store: ConfigStore
    public let ai: DefaultAiService
    /// A6: the executor of unit.run, when a GUI execution backend is on.
    /// The host registers it with the Runtime, which owns its Runs.
    public let units: UnitRunService?
    let features: GuiBackendFeatures?
    let codecs: GuiCodecRegistry
    let aiHandlers: AiApplicationHandlers
    let capabilityTests: CapabilityTestService

    public static func open(_ o: AgentDesktopServiceOptions) async throws -> AgentDesktopService {
        let digestKey = try ConfigStore.loadOrCreateDigestKey(in: o.credentials)
        let store = try ConfigStore(path: o.databasePath, credentials: o.credentials, digestKey: digestKey, options: o.config)
        // Before anything can start: model calls the last process reserved
        // and never finished become interrupted (usage unknown), and their
        // budget scope waits for a settlement; nothing is sent again (codex
        // on 7eee9bb: this was RunRecovery's first step).
        _ = try await store.recoverLedger()
        let admission = CredentialRevocationAdmission(store: store)
        await admission.register()
        let credentials = StoreCredentialResolver(store: store)
        let ai = DefaultAiService(http: o.http, credentials: credentials, ledger: SQLiteAiCallLedger(store: store),
                                  admission: admission, clock: o.clock, prices: o.prices)
        let codecs = GuiCodecRegistry(fixtureAdapterEnabled: o.config.allowFixtureAdapter)
        let runner = AiOperationRunner()
        // unit.run keeps no run table here: the Runtime's RunStore, request
        // ledger and the AI call ledger are the records (A6 principle 3).
        let units = o.executionBackend.map { be in
            UnitRunService(resolver: ConfigBindingResolver(store: store, codecs: codecs), evidence: store,
                           ports: GuiExplorerPorts(observation: be.ports.observation, execution: be.ports.execution,
                                                   audit: UnitRunAudit()),
                           features: be.features, aiService: ai, codecs: codecs, clock: o.clock)
        }
        // What a live unit Run pinned cannot be deleted under it (§04.1).
        if let units { await store.setActiveRunCheck { kind, id in units.pins(kind, id) } }
        return AgentDesktopService(
            store: store, ai: ai, units: units, features: o.executionBackend?.features, codecs: codecs,
            aiHandlers: AiApplicationHandlers(store: store, http: o.http, runner: runner, credentials: credentials,
                                              actionOutcomes: o.actionOutcomes),
            capabilityTests: CapabilityTestService(store: store, ai: ai, http: o.http, runner: runner,
                                                   codecs: codecs, clock: o.clock))
    }

    init(store: ConfigStore, ai: DefaultAiService, units: UnitRunService?, features: GuiBackendFeatures?,
         codecs: GuiCodecRegistry, aiHandlers: AiApplicationHandlers, capabilityTests: CapabilityTestService) {
        self.store = store
        self.ai = ai
        self.units = units
        self.features = features
        self.codecs = codecs
        self.aiHandlers = aiHandlers
        self.capabilityTests = capabilityTests
    }

    /// The `gui` section of runtime.capabilities.
    public func guiCapabilities() -> JSONValue {
        GuiCapabilities.capabilities(features: features, codecs: codecs)
    }

    /// A4 R4: a paired client lost its access; what it started here stops.
    /// `clientId` as the Runtime names it (the service's caller scope).
    public func accessWithdrawn(clientId: String) async {
        await aiHandlers.cancelOperations(callerScope: clientId)
    }

    /// Every command of the service for one caller.
    public func handlers(callerScope: String) -> [String: ServiceHandler] {
        aiHandlers.handlers(callerScope: callerScope, extra: capabilityTests.handlers(callerScope: callerScope))
    }

    public func router(callerScope: String, onInternalFault: (@Sendable (String, String) -> Void)? = nil) -> ServiceRouter {
        ServiceRouter(handlers: handlers(callerScope: callerScope), onInternalFault: onInternalFault)
    }
}

/// A unit Run's audit port: the Runtime records the Run, each act in its
/// request ledger before dispatch, and the AI service each model call; the
/// explorer only needs an actionId per input.
struct UnitRunAudit: GuiAuditPort {
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
    func recordInference(_ receipt: GuiInferenceReceipt) {}
    func reserveAction(_ proposal: GuiProposal) -> String { "act_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    func recordAction(_ receipt: GuiActionReceipt) {}
}
