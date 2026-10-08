import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// One Run's events for the editor, read on connections of their own (never
/// the control connection), on a dedicated thread.
///
/// - `events.subscribe {runId, after}` pushes frames; the stream ends when
///   the Runtime closes it after the Run ended.
/// - A close before that (or a dropped connection) is followed by one
///   `run.events` read: if the Run ended and nothing is left, the stream
///   ends; otherwise it subscribes again from the last sequence delivered.
/// - When the client carries no subscriptions it polls `run.events`.
/// Events at or below the last delivered sequence are dropped, so the
/// editor never sees one twice.
final class ACPBridgeEventReader: @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<ACPRuntimeEvent, Error>.Continuation

    let runId: String
    private let makeClient: ACPBridgeClientFactory
    private let config: ACPBridgeConfiguration
    private let continuation: Continuation
    private let lock = NSLock()
    private var stopped = false
    private var last: Int

    init(runId: String, after: Int?, makeClient: @escaping ACPBridgeClientFactory, config: ACPBridgeConfiguration,
         continuation: Continuation) {
        self.runId = runId
        self.last = after ?? 0
        self.makeClient = makeClient
        self.config = config
        self.continuation = continuation
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Stop reading; the thread closes its connection at its next wake.
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    /// Stop and end the editor's stream now.
    func finish() {
        stop()
        continuation.finish()
    }

    func start() {
        let t = Thread { [self] in self.loop() }
        t.name = "acp.bridge.events.\(runId)"
        t.start()
    }

    private enum Step { case resubscribe, done }

    private func loop() {
        var failures = 0
        while !isStopped {
            let before = last
            do {
                switch try subscribeOnce() {
                case .done: continuation.finish(); return
                case .resubscribe: break
                }
            } catch let e as RuntimeError where !Self.transient(e) {
                continuation.finish(throwing: ACPBridgeErrors.map(e))
                return
            } catch {
                // Transient: retry below within the budget.
            }
            if isStopped { return }
            failures = last > before ? 0 : failures + 1
            if failures > config.maxReconnects {
                continuation.finish(throwing: ACPBridgeErrors.map(RuntimeError.connectionLost(
                    "the event stream of run \(runId) kept dropping")))
                return
            }
            Thread.sleep(forTimeInterval: config.pollInterval)
        }
    }

    /// One subscription; then decide whether the Run's stream is complete.
    private func subscribeOnce() throws -> Step {
        let client = makeClient(.events)
        defer { client.close() }
        _ = try client.handshake()
        do {
            _ = try client.subscribe(runId: runId, after: last)
        } catch let e as RuntimeError where e.code == "capability_missing" {
            return try poll(client)
        }
        while !isStopped {
            switch try client.nextEvent() {
            case .idle: continue
            case let .frame(f):
                guard let e = f["event"] else { continue }
                if !deliver(e) { return .done }
            case .closed:
                return try drain()
            }
        }
        return .done
    }

    /// After a close: read what is left on a fresh connection.
    private func drain() throws -> Step {
        if isStopped { return .done }
        let client = makeClient(.events)
        defer { client.close() }
        _ = try client.handshake()
        while true {
            let page = try client.call(RuntimeRequest(.runEvents, params: .obj([
                ("runId", .string(runId)), ("after", .int(last)), ("limit", .int(500))])))
            let events = page["events"]?.arrayValue ?? []
            for e in events where !deliver(e) { return .done }
            if events.isEmpty { return page["ended"]?.boolValue == true ? .done : .resubscribe }
        }
    }

    /// No push support: page through run.events until the Run ended.
    private func poll(_ client: RuntimeClient) throws -> Step {
        while !isStopped {
            let page = try client.call(RuntimeRequest(.runEvents, params: .obj([
                ("runId", .string(runId)), ("after", .int(last)), ("limit", .int(500))])))
            let events = page["events"]?.arrayValue ?? []
            for e in events where !deliver(e) { return .done }
            if events.isEmpty {
                if page["ended"]?.boolValue == true { return .done }
                Thread.sleep(forTimeInterval: config.pollInterval)
            }
        }
        return .done
    }

    /// Yield one RunEvent unless it was delivered already. False: stop.
    private func deliver(_ e: JSONValue) -> Bool {
        guard let seq = e["sequence"]?.intValue, e["runId"]?.stringValue == runId else { return !isStopped }
        guard seq > last else { return !isStopped }
        last = seq
        let event = ACPRuntimeEvent(runId: runId, cursor: seq, type: e["type"]?.stringValue ?? "",
                                    payload: e["data"] ?? .obj([]))
        if case .terminated = continuation.yield(event) {
            stop()
            return false
        }
        return !isStopped
    }

    /// Failures worth another connection: nothing about the Run is wrong.
    static func transient(_ e: RuntimeError) -> Bool {
        switch e.phase {
        case .connect, .transport: return true
        default: return e.code == "connection_lost" || e.code == "runtime_offline"
        }
    }
}
