import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// What a page shows: one of the four states, or its content.
public enum PageState: Equatable, Sendable {
    case loading
    case empty
    case loaded
    /// The call failed; the last good data (if any) stays on screen with its
    /// sync time, and never sample data in its place.
    case failed(RuntimeProblem)
    /// The Runtime cannot be reached; changes are disabled.
    case disconnected(RuntimeProblem)
}

/// How one kind of data is kept current. Exactly one source per kind
/// (02 U1「轮询或事件唯一」): Runs follow the event subscription when the
/// Runtime offers it, otherwise polling; Desktops poll, because runtime/1
/// has no Desktop events yet (docs/plan/10 F1-02).
public enum UpdateMode: String, Equatable, Sendable {
    case none
    case subscription
    case polling
}

public enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case connected(instanceId: String, productVersion: String)
    case disconnected(RuntimeProblem)
}

/// The main window's view of the Runtime: snapshots from runtime/1 calls
/// plus run events. It decides nothing about execution; it only keeps what
/// the Runtime said, and drops answers that arrive too late.
///
/// Late answers: every reply is tagged with the Store's generation (bumped
/// when the Runtime source is replaced) and a per-kind ticket (bumped on
/// every new request of that kind). A reply whose generation or ticket is
/// no longer current is discarded. The generation idea comes from PR #1's
/// AppModel (A02 review fix "client generations"); the ticket adds
/// last-request-wins within one source.
@MainActor
public final class ShellStore: ObservableObject {
    @Published public private(set) var connection: ConnectionStatus = .connecting
    @Published public private(set) var status: JSONValue?
    @Published public private(set) var capabilities: JSONValue?
    @Published public private(set) var desktops: [JSONValue] = []
    @Published public private(set) var desktopsState: PageState = .loading
    @Published public private(set) var desktopsSyncedAt: Date?
    @Published public private(set) var runs: [JSONValue] = []
    @Published public private(set) var runsState: PageState = .loading
    @Published public private(set) var runsSyncedAt: Date?
    @Published public private(set) var desktopUpdates: UpdateMode = .none
    @Published public private(set) var runUpdates: UpdateMode = .none
    /// Last global event cursor seen; resubscription continues after it.
    @Published public private(set) var eventCursor: Int?
    /// Bumped after every update round (poll tick or applied event). Detail
    /// pages re-read their own object when it changes, so they never know
    /// whether the round came from polling or a push.
    @Published public private(set) var tick = 0
    /// Answer of the last global stop or input re-enable, for the window.
    @Published public private(set) var lastStop: JSONValue?
    @Published public private(set) var stopProblem: RuntimeProblem?

    public private(set) var runtime: RuntimePort
    public private(set) var generation = 0
    public var isSample: Bool { runtime.isSample }

    private var desktopTicket = 0
    private var runTicket = 0
    private var tasks: [Task<Void, Never>] = []
    private let clock: PollClock
    private let pollMs: Int
    private let now: () -> Date
    /// When false, Runs are polled even if the Runtime offers
    /// `events.subscribe` (U1b-1: the in-process port has no push yet).
    public let allowSubscription: Bool

    public init(runtime: RuntimePort, clock: PollClock = SystemPollClock(), pollMs: Int = 2000,
                allowSubscription: Bool = true, now: @escaping () -> Date = Date.init) {
        self.runtime = runtime
        self.clock = clock
        self.pollMs = pollMs
        self.allowSubscription = allowSubscription
        self.now = now
    }

    public var isRunning: Bool { !tasks.isEmpty }
    /// Update loops running now (tests: one poll loop, plus one
    /// subscription loop when Runs are pushed).
    var loopCount: Int { tasks.count }

    /// Runs whose phase is not `ended`.
    public var activeRuns: [JSONValue] { runs.filter { $0["phase"]?.stringValue != "ended" } }

    public var inputAdmission: String? { status?["inputAdmission"]?.stringValue }

    // MARK: Lifecycle

    /// Handshake, read capabilities and first snapshots, then keep each kind
    /// current with its one update source. Calling it again while running
    /// restarts the loops; there is never a second poll loop. If the Runtime
    /// cannot be reached the same loop keeps trying, and the window comes
    /// back by itself once it answers.
    public func start() async {
        stop()
        let gen = generation
        await connect(gen)
        guard gen == generation, tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in await self?.pollLoop(gen) })
        if runUpdates == .subscription {
            tasks.append(Task { [weak self] in await self?.subscriptionLoop(gen) })
        }
    }

    /// One connection attempt: handshake, capabilities, status, snapshots.
    private func connect(_ gen: Int) async {
        if case .connected = connection {} else { connection = .connecting }
        do {
            let identity = try await runtime.call("runtime.handshake", .obj([
                ("apiVersions", .array([.string(RuntimeAPI.version)])),
                ("client", .obj([("name", .string("AgentDesktop main window")), ("version", .string(RuntimeAPI.productVersion))])),
            ]))
            let caps = try await runtime.call("runtime.capabilities")
            let st = try await runtime.call("runtime.status")
            guard gen == generation else { return }
            connection = .connected(instanceId: identity["instanceId"]?.stringValue ?? "—",
                                    productVersion: identity["productVersion"]?.stringValue ?? "—")
            capabilities = caps
            status = st
        } catch {
            guard gen == generation else { return }
            markDisconnected(RuntimeProblem(error))
            return
        }
        await refreshDesktops()
        await refreshRuns()
        guard gen == generation else { return }
        desktopUpdates = .polling
        runUpdates = allowSubscription && offers("events.subscribe") ? .subscription : .polling
        tick += 1
    }

    private func markDisconnected(_ p: RuntimeProblem) {
        connection = .disconnected(p)
        desktopsState = .disconnected(p)
        runsState = .disconnected(p)
    }

    /// Stop updating (window closed). Ends the event stream; never a Run.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        desktopUpdates = .none
        runUpdates = .none
    }

    /// Replace the Runtime source (for instance Mock → in-process). Every
    /// answer still in flight from the old source is discarded.
    public func switchRuntime(_ next: RuntimePort) async {
        stop()
        generation += 1
        runtime = next
        status = nil
        capabilities = nil
        desktops = []
        runs = []
        desktopsSyncedAt = nil
        runsSyncedAt = nil
        eventCursor = nil
        desktopsState = .loading
        runsState = .loading
        await start()
    }

    public func offers(_ method: String) -> Bool {
        capabilities?["interface"]?["methods"]?.arrayValue?.contains { $0["method"]?.stringValue == method } ?? false
    }

    // MARK: Snapshots

    public func refreshDesktops() async {
        let gen = generation
        desktopTicket += 1
        let ticket = desktopTicket
        if desktops.isEmpty, desktopsSyncedAt == nil { desktopsState = .loading }
        do {
            let r = try await runtime.call("desktop.list")
            guard gen == generation, ticket == desktopTicket else { return }
            desktops = r["desktops"]?.arrayValue ?? []
            desktopsSyncedAt = now()
            desktopsState = desktops.isEmpty ? .empty : .loaded
        } catch {
            guard gen == generation, ticket == desktopTicket else { return }
            desktopsState = Self.failure(error)
        }
    }

    public func refreshRuns() async {
        let gen = generation
        runTicket += 1
        let ticket = runTicket
        if runs.isEmpty, runsSyncedAt == nil { runsState = .loading }
        do {
            let r = try await runtime.call("run.list", .obj([("limit", .int(200))]))
            guard gen == generation, ticket == runTicket else { return }
            runs = r["runs"]?.arrayValue ?? []
            runsSyncedAt = now()
            runsState = runs.isEmpty ? .empty : .loaded
        } catch {
            guard gen == generation, ticket == runTicket else { return }
            runsState = Self.failure(error)
        }
    }

    public func refreshStatus() async {
        let gen = generation
        do {
            let st = try await runtime.call("runtime.status")
            guard gen == generation else { return }
            status = st
        } catch {
            guard gen == generation else { return }
            let p = RuntimeProblem(error)
            if p.isDisconnection { markDisconnected(p) }
        }
    }

    /// `runtime.stopAll`: every platform Run stops taking input. The window
    /// shows what the Runtime answered (stopping, pending); it does not
    /// mark anything stopped itself.
    public func stopAllInput() async {
        let gen = generation
        do {
            let r = try await runtime.call("runtime.stopAll", .obj([("scope", .string("all_platform_runs"))]))
            guard gen == generation else { return }
            lastStop = r
            stopProblem = nil
        } catch {
            guard gen == generation else { return }
            stopProblem = RuntimeProblem(error)
        }
        await refreshStatus()
        await refreshRuns()
        tick += 1
    }

    /// `runtime.enableInput`: new input is accepted again; stopped Runs stay
    /// stopped.
    public func enableInput() async {
        let gen = generation
        do {
            _ = try await runtime.call("runtime.enableInput")
            guard gen == generation else { return }
            stopProblem = nil
        } catch {
            guard gen == generation else { return }
            stopProblem = RuntimeProblem(error)
        }
        await refreshStatus()
        tick += 1
    }

    /// One frame from `events.subscribe`: move the cursor and re-read the
    /// Run it names from `run.show` (the authoritative state), never infer
    /// the state from the event type.
    public func apply(frame: JSONValue) async {
        let gen = generation
        if let c = frame["cursor"]?.intValue { eventCursor = max(eventCursor ?? 0, c) }
        guard let runId = frame["event"]?["runId"]?.stringValue else { return }
        guard let run = try? await runtime.call("run.show", .obj([("runId", .string(runId))])), gen == generation else { return }
        upsert(run)
        tick += 1
    }

    /// Keep the newer revision of a Run.
    func upsert(_ run: JSONValue) {
        guard let id = run["runId"]?.stringValue else { return }
        if let i = runs.firstIndex(where: { $0["runId"]?.stringValue == id }) {
            if (runs[i]["revision"]?.intValue ?? 0) <= (run["revision"]?.intValue ?? 0) { runs[i] = run }
        } else {
            runs.insert(run, at: 0)
        }
        runsSyncedAt = now()
        runsState = .loaded
    }

    // MARK: Update loops

    private func pollLoop(_ gen: Int) async {
        while !Task.isCancelled, gen == generation {
            do { try await clock.pause(milliseconds: pollMs) } catch { return }
            guard !Task.isCancelled, gen == generation else { return }
            if case .connected = connection {
                await refreshStatus()
                guard case .connected = connection else { continue }
                await refreshDesktops()
                if runUpdates == .polling { await refreshRuns() }
                tick += 1
            } else {
                // Reconnect: the same loop, one attempt per interval.
                let hadSubscription = runUpdates == .subscription
                await connect(gen)
                if case .connected = connection, runUpdates == .subscription, !hadSubscription {
                    tasks.append(Task { [weak self] in await self?.subscriptionLoop(gen) })
                }
            }
        }
    }

    private func subscriptionLoop(_ gen: Int) async {
        while !Task.isCancelled, gen == generation {
            do {
                let stream = try await runtime.subscribe(after: eventCursor)
                for try await frame in stream {
                    guard !Task.isCancelled, gen == generation else { return }
                    await apply(frame: frame)
                }
                return
            } catch let e as RuntimeError where e.code == "events_cursor_expired" {
                // Past the stored events: take the current state, then
                // follow from now.
                guard gen == generation else { return }
                eventCursor = nil
                await refreshRuns()
            } catch {
                guard !Task.isCancelled, gen == generation else { return }
                runsState = Self.failure(error)
                do { try await clock.pause(milliseconds: pollMs) } catch { return }
            }
        }
    }

    static func failure(_ error: Error) -> PageState {
        let p = RuntimeProblem(error)
        return p.isDisconnection ? .disconnected(p) : .failed(p)
    }
}
