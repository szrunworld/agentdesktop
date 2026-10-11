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

    /// True while an event stream is open and being read.
    @Published public private(set) var pushLive = false
    /// Why Runs are polled although the Runtime lists `events.subscribe`
    /// (the code its subscription failed with); nil otherwise.
    @Published public private(set) var pushFallback: RuntimeProblem?

    public private(set) var runtime: RuntimePort
    public private(set) var generation = 0
    public var isSample: Bool { runtime.isSample }

    private var desktopTicket = 0
    private var runTicket = 0
    private var runUpdateVersion = 0
    private var pushedRunVersions: [String: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    /// Identifies the current push loop, so an old loop that ends late
    /// never clears a newer one.
    private var pushId = 0
    private let clock: PollClock
    private let pollMs: Int
    private let now: () -> Date
    /// When false, Runs are polled even if the Runtime offers
    /// `events.subscribe`.
    public let allowSubscription: Bool

    public init(runtime: RuntimePort, clock: PollClock = SystemPollClock(), pollMs: Int = 2000,
                allowSubscription: Bool = true, now: @escaping () -> Date = Date.init) {
        self.runtime = runtime
        self.clock = clock
        self.pollMs = pollMs
        self.allowSubscription = allowSubscription
        self.now = now
    }

    public var isRunning: Bool { pollTask != nil || pushTask != nil }
    /// Update loops running now (tests: one poll loop, plus one
    /// subscription loop when Runs are pushed).
    var loopCount: Int { (pollTask == nil ? 0 : 1) + (pushTask == nil ? 0 : 1) }

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
        guard gen == generation, pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollLoop(gen) }
        startPush(gen)
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
        // Every (re)connection tries the push again, even after a fallback.
        if allowSubscription && offers("events.subscribe") {
            runUpdates = .subscription
            pushFallback = nil
        } else {
            runUpdates = .polling
        }
        tick += 1
    }

    private func markDisconnected(_ p: RuntimeProblem) {
        connection = .disconnected(p)
        desktopsState = .disconnected(p)
        runsState = .disconnected(p)
    }

    /// Stop updating (window closed). Ends the event stream; never a Run.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        pushTask?.cancel()
        pushTask = nil
        pushLive = false
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
        pushFallback = nil
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
        let version = runUpdateVersion
        if runs.isEmpty, runsSyncedAt == nil { runsState = .loading }
        do {
            let r = try await runtime.call("run.list", .obj([("limit", .int(200))]))
            guard gen == generation, ticket == runTicket else { return }
            runs = Self.merge(snapshot: r["runs"]?.arrayValue ?? [], over: runs,
                              preserving: Set(pushedRunVersions.filter { $0.value > version }.map(\.key)))
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

    /// One frame from `events.subscribe`: re-read the Run it names from
    /// `run.show` (the authoritative state), never infer the state from the
    /// event type. Tests and the push loop use it; a failed read is dropped.
    public func apply(frame: JSONValue) async {
        try? await applyPushed(frame, generation)
    }

    /// The push loop's step. The cursor moves only once the Run was read,
    /// so after any failed read the same frame comes again (resume after
    /// the last applied cursor). Only a Run that is gone or not visible
    /// (`not_found`, `permission_denied`) is skipped; any other failure
    /// (lost connection, `internal_error`, …) is thrown, leaving the cursor.
    private func applyPushed(_ frame: JSONValue, _ gen: Int) async throws {
        if let runId = frame["event"]?["runId"]?.stringValue {
            do {
                let run = try await runtime.call("run.show", .obj([("runId", .string(runId))]))
                guard gen == generation else { return }
                upsert(run)
            } catch {
                guard Self.skippable.contains(RuntimeProblem(error).code) else { throw error }
            }
        }
        guard gen == generation else { return }
        if let c = frame["cursor"]?.intValue { eventCursor = max(eventCursor ?? 0, c) }
        tick += 1
    }

    /// Failures of `run.show` that mean the Run will never be readable here.
    static let skippable: Set<String> = ["not_found", "permission_denied"]

    /// Keep the newer revision of a Run.
    func upsert(_ run: JSONValue) {
        guard let id = run["runId"]?.stringValue else { return }
        runUpdateVersion += 1
        pushedRunVersions[id] = runUpdateVersion
        if let i = runs.firstIndex(where: { $0["runId"]?.stringValue == id }) {
            if (runs[i]["revision"]?.intValue ?? 0) <= (run["revision"]?.intValue ?? 0) { runs[i] = run }
        } else {
            runs.insert(run, at: 0)
        }
        runsSyncedAt = now()
        runsState = .loaded
    }

    /// A `run.list` snapshot over what is shown: the snapshot decides which
    /// Runs are listed and in what order, but a Run already shown at a
    /// newer revision (an event applied while the snapshot was in flight)
    /// is kept, so a slow snapshot never moves a Run back.
    static func merge(snapshot: [JSONValue], over current: [JSONValue], preserving ids: Set<String> = []) -> [JSONValue] {
        var known: [String: JSONValue] = [:]
        for r in current { if let id = r["runId"]?.stringValue { known[id] = r } }
        let listed = Set(snapshot.compactMap { $0["runId"]?.stringValue })
        let pushed = current.filter { r in
            guard let id = r["runId"]?.stringValue else { return false }
            return ids.contains(id) && !listed.contains(id)
        }
        return pushed + snapshot.map { fresh in
            guard let id = fresh["runId"]?.stringValue, let shown = known[id],
                  (shown["revision"]?.intValue ?? 0) > (fresh["revision"]?.intValue ?? 0) else { return fresh }
            return shown
        }
    }

    // MARK: Update loops

    /// Status and Desktops every interval (no Desktop events yet, F1-02),
    /// Runs too while they are not pushed; reconnects while disconnected.
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
                // Reconnect: the same loop, one attempt per interval; the
                // push resumes after the last applied cursor.
                await connect(gen)
                startPush(gen)
            }
        }
    }

    /// Start the push loop when Runs are to be pushed and none is running.
    private func startPush(_ gen: Int) {
        guard gen == generation, runUpdates == .subscription, pushTask == nil else { return }
        guard case .connected = connection else { return }
        pushId += 1
        let id = pushId
        pushTask = Task { [weak self] in
            await self?.pushLoop(gen)
            guard let self, self.pushId == id else { return }
            self.pushTask = nil
            self.pushLive = false
        }
    }

    /// Runs from `events.subscribe` (U1b-2). Resumes after the last applied
    /// cursor; past the stored events (`events_cursor_expired`) it starts
    /// from now and re-reads `run.list`; a stream the Runtime ends or loses
    /// is opened again; a Runtime that cannot push turns Runs back to
    /// polling. Pages see the same `runs` and `tick` either way.
    private func pushLoop(_ gen: Int) async {
        while !Task.isCancelled, gen == generation, runUpdates == .subscription {
            guard case .connected = connection else { return }
            let resumed = eventCursor != nil
            let stream: AsyncThrowingStream<JSONValue, Error>
            do {
                stream = try await runtime.subscribe(after: eventCursor)
            } catch {
                guard await recover(from: error, gen, opening: true) else { return }
                continue
            }
            guard !Task.isCancelled, gen == generation, runUpdates == .subscription else { return }
            pushLive = true
            // Following from now: a snapshot taken after the subscription
            // covers whatever happened before it, so nothing falls between.
            if !resumed { await refreshRuns() }
            tick += 1
            var delivered = false
            do {
                for try await frame in stream {
                    guard !Task.isCancelled, gen == generation else { return }
                    try await applyPushed(frame, gen)
                    delivered = true
                }
                pushLive = false
                guard !Task.isCancelled, gen == generation else { return }
                // The Runtime closed the stream: open it again from the
                // cursor; at once if it had carried events, else after a pause.
                if !delivered { do { try await clock.pause(milliseconds: pollMs) } catch { return } }
            } catch {
                pushLive = false
                guard await recover(from: error, gen, opening: false) else { return }
            }
        }
    }

    /// After the stream failed: true to subscribe again.
    /// - `events_cursor_expired`: from now, then a snapshot (no pause).
    /// - Runtime unreachable when subscribing: Disconnected; the poll loop
    ///   reconnects and starts the push again from the cursor.
    /// - Stream lost or a pushed Run not readable while connected: pause,
    ///   then subscribe again from the cursor, so the frame comes again
    ///   (the poll loop finds out if the Runtime itself is gone).
    /// - Subscribing refused for any other reason (no push in this
    ///   Runtime, refused): poll Runs.
    private func recover(from error: Error, _ gen: Int, opening: Bool) async -> Bool {
        guard !Task.isCancelled, gen == generation else { return false }
        let p = RuntimeProblem(error)
        if p.code == "events_cursor_expired" {
            eventCursor = nil
            return true
        }
        if p.isDisconnection && opening {
            markDisconnected(p)
            return false
        }
        if !opening {
            do { try await clock.pause(milliseconds: pollMs) } catch { return false }
            return !Task.isCancelled && gen == generation
        }
        pushFallback = p
        runUpdates = .polling
        await refreshRuns()
        tick += 1
        return false
    }

    static func failure(_ error: Error) -> PageState {
        let p = RuntimeProblem(error)
        return p.isDisconnection ? .disconnected(p) : .failed(p)
    }
}
