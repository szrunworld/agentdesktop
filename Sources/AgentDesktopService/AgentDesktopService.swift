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
    /// closed: `gui.runs.start` answers CAPABILITY_MISMATCH (spec §15, G0).
    public var executionBackend: GuiExecutionBackend?
    /// Runs, events and receipts. Nil keeps them in the configuration
    /// database, which is what restart recovery reads (spec §07.4).
    public var runRepository: GuiRunRepository?
    /// Replace the backend's audit port with the durable one in the
    /// configuration database, so a pending input survives a crash as
    /// unknown (spec §09.3). Only tests that count audit calls turn it off.
    public var durableAudit: Bool
    public var prices: AiPriceTable?

    public init(databasePath: String,
                credentials: CredentialStore,
                http: HTTPTransport = URLSessionHTTPTransport(),
                clock: MonotonicClock = SystemMonotonicClock(),
                config: ConfigOptions = ConfigOptions(),
                executionBackend: GuiExecutionBackend? = nil,
                runRepository: GuiRunRepository? = nil,
                durableAudit: Bool = true,
                prices: AiPriceTable? = nil) {
        self.databasePath = databasePath
        self.credentials = credentials
        self.http = http
        self.clock = clock
        self.config = config
        self.executionBackend = executionBackend
        self.runRepository = runRepository
        self.durableAudit = durableAudit
        self.prices = prices
    }
}

/// The composition of contract v1: one configuration store, one model
/// service (shared by capability tests and GUI runs, spec §18.1), one run
/// service, and the handlers of its runtime/1 methods on top of them. Nothing here takes
/// input; GUI runs reach a desktop only through the injected backend.
public final class AgentDesktopService: Sendable {
    public let store: ConfigStore
    public let ai: DefaultAiService
    public let runs: GuiRunService
    /// A6: the executor of unit.run, when a GUI execution backend is on.
    /// The host registers it with the Runtime, which owns its Runs.
    public let units: UnitRunService?
    /// What restart recovery found when the service opened.
    public let recovery: RunRecoveryReport
    let aiHandlers: AiApplicationHandlers
    let capabilityTests: CapabilityTestService

    public static func open(_ o: AgentDesktopServiceOptions) async throws -> AgentDesktopService {
        let digestKey = try ConfigStore.loadOrCreateDigestKey(in: o.credentials)
        let store = try ConfigStore(path: o.databasePath, credentials: o.credentials, digestKey: digestKey, options: o.config)
        // Before anything can start: unresolved inputs of the last process
        // become unknown and quarantined; nothing is resent.
        let recovery = try await RunRecovery(store: store).recover()
        let admission = CredentialRevocationAdmission(store: store)
        await admission.register()
        let credentials = StoreCredentialResolver(store: store)
        let ai = DefaultAiService(http: o.http, credentials: credentials, ledger: SQLiteAiCallLedger(store: store),
                                  admission: admission, clock: o.clock, prices: o.prices)
        let codecs = GuiCodecRegistry(fixtureAdapterEnabled: o.config.allowFixtureAdapter)
        let runner = AiOperationRunner()
        var backend = o.executionBackend
        // unit.run keeps no run table here: the Runtime's RunStore, request
        // ledger and the AI call ledger are the records (A6 principle 3).
        let units = o.executionBackend.map { be in
            UnitRunService(resolver: ConfigBindingResolver(store: store, codecs: codecs),
                           ports: GuiExplorerPorts(observation: be.ports.observation, execution: be.ports.execution,
                                                   audit: UnitRunAudit()),
                           features: be.features, aiService: ai, codecs: codecs, clock: o.clock)
        }
        if let be = backend, o.durableAudit {
            backend = GuiExecutionBackend(
                ports: GuiExplorerPorts(observation: be.ports.observation, execution: be.ports.execution,
                                        audit: SQLiteGuiAuditPort(store: store)),
                sessions: be.sessions, features: be.features)
        }
        let runs = GuiRunService(repository: o.runRepository ?? SQLiteGuiRunRepository(store: store),
                                 resolver: ConfigBindingResolver(store: store, codecs: codecs),
                                 backend: backend, aiService: ai, codecs: codecs, clock: o.clock)
        return AgentDesktopService(
            store: store, ai: ai, runs: runs, units: units, recovery: recovery,
            aiHandlers: AiApplicationHandlers(store: store, http: o.http, runner: runner, credentials: credentials),
            capabilityTests: CapabilityTestService(store: store, ai: ai, http: o.http, runner: runner,
                                                   codecs: codecs, clock: o.clock))
    }

    init(store: ConfigStore, ai: DefaultAiService, runs: GuiRunService, units: UnitRunService?, recovery: RunRecoveryReport,
         aiHandlers: AiApplicationHandlers, capabilityTests: CapabilityTestService) {
        self.store = store
        self.ai = ai
        self.runs = runs
        self.units = units
        self.recovery = recovery
        self.aiHandlers = aiHandlers
        self.capabilityTests = capabilityTests
    }

    /// A4 R4: a paired client lost its access; what it started here stops.
    /// `clientId` as the Runtime names it (the service's caller scope).
    public func accessWithdrawn(clientId: String) async {
        await aiHandlers.cancelOperations(callerScope: clientId)
    }

    /// Every command of the contract for one caller. `trustedOwner` is the
    /// owner UI/CLI, the only caller that may start a run without a session.
    public func handlers(callerScope: String, trustedOwner: Bool) -> [String: ServiceHandler] {
        var out = aiHandlers.handlers(callerScope: callerScope, extra: capabilityTests.handlers(callerScope: callerScope))
        out.merge(runs.handlers(callerScope: callerScope, trustedOwner: trustedOwner)) { _, run in run }
        return out
    }

    public func router(callerScope: String, trustedOwner: Bool,
                       onInternalFault: (@Sendable (String, String) -> Void)? = nil) -> ServiceRouter {
        ServiceRouter(handlers: handlers(callerScope: callerScope, trustedOwner: trustedOwner),
                      onInternalFault: onInternalFault)
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
