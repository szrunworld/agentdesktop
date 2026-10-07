import AgentDesktopAI
import AgentDesktopContracts
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
    public var runRepository: GuiRunRepository
    public var prices: AiPriceTable?

    public init(databasePath: String,
                credentials: CredentialStore,
                http: HTTPTransport = URLSessionHTTPTransport(),
                clock: MonotonicClock = SystemMonotonicClock(),
                config: ConfigOptions = ConfigOptions(),
                executionBackend: GuiExecutionBackend? = nil,
                runRepository: GuiRunRepository = InMemoryGuiRunRepository(),
                prices: AiPriceTable? = nil) {
        self.databasePath = databasePath
        self.credentials = credentials
        self.http = http
        self.clock = clock
        self.config = config
        self.executionBackend = executionBackend
        self.runRepository = runRepository
        self.prices = prices
    }
}

/// The composition of contract v1: one configuration store, one model
/// service (shared by capability tests and GUI runs, spec §18.1), one run
/// service, and the 32 command handlers on top of them. Nothing here takes
/// input; GUI runs reach a desktop only through the injected backend.
public final class AgentDesktopService: Sendable {
    public let store: ConfigStore
    public let ai: DefaultAiService
    public let runs: GuiRunService
    let aiHandlers: AiApplicationHandlers
    let capabilityTests: CapabilityTestService

    public static func open(_ o: AgentDesktopServiceOptions) async throws -> AgentDesktopService {
        let digestKey = try ConfigStore.loadOrCreateDigestKey(in: o.credentials)
        let store = try ConfigStore(path: o.databasePath, credentials: o.credentials, digestKey: digestKey, options: o.config)
        let admission = CredentialRevocationAdmission(store: store)
        await admission.register()
        let credentials = StoreCredentialResolver(store: store)
        let ai = DefaultAiService(http: o.http, credentials: credentials, ledger: SQLiteAiCallLedger(store: store),
                                  admission: admission, clock: o.clock, prices: o.prices)
        let codecs = GuiCodecRegistry(fixtureAdapterEnabled: o.config.allowFixtureAdapter)
        let runner = AiOperationRunner()
        let runs = GuiRunService(repository: o.runRepository,
                                 resolver: ConfigBindingResolver(store: store, codecs: codecs),
                                 backend: o.executionBackend, aiService: ai, codecs: codecs, clock: o.clock)
        return AgentDesktopService(
            store: store, ai: ai, runs: runs,
            aiHandlers: AiApplicationHandlers(store: store, http: o.http, runner: runner, credentials: credentials),
            capabilityTests: CapabilityTestService(store: store, ai: ai, http: o.http, runner: runner,
                                                   codecs: codecs, clock: o.clock))
    }

    init(store: ConfigStore, ai: DefaultAiService, runs: GuiRunService,
         aiHandlers: AiApplicationHandlers, capabilityTests: CapabilityTestService) {
        self.store = store
        self.ai = ai
        self.runs = runs
        self.aiHandlers = aiHandlers
        self.capabilityTests = capabilityTests
    }

    /// Every command of the contract for one caller. `trustedOwner` is the
    /// owner UI/CLI, the only caller that may start a run without a session.
    public func handlers(callerScope: String, trustedOwner: Bool) -> [String: RpcHandler] {
        var out = aiHandlers.handlers(callerScope: callerScope, extra: capabilityTests.handlers(callerScope: callerScope))
        out.merge(runs.handlers(callerScope: callerScope, trustedOwner: trustedOwner)) { _, run in run }
        return out
    }

    public func router(callerScope: String, trustedOwner: Bool,
                       legacy: (@Sendable (JSONValue) async -> Data)? = nil,
                       onInternalFault: (@Sendable (String, String) -> Void)? = nil) -> RpcRouter {
        RpcRouter(handlers: handlers(callerScope: callerScope, trustedOwner: trustedOwner),
                  legacy: legacy, onInternalFault: onInternalFault)
    }
}
