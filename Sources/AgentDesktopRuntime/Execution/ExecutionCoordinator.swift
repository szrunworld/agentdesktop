import AgentDesktopContracts
import AgentDesktopProtocol
import CryptoKit
import Foundation

/// Who may send input where, and the stop path (CLI plan §04, §06).
///
/// Each Desktop has at most one control lease, held by one running Run. A
/// short `act` takes a one-action Run and releases it at once; `session
/// exec` holds its Run's lease until the shell finishes, is cancelled, or
/// its owner connection goes away. Cancelling first revokes the right to
/// start new input; the Run becomes quiescent, and the lease free, only
/// once no action of it is in flight.
public final class ExecutionCoordinator: @unchecked Sendable {
    struct Live {
        var record: RunRecord
        var inFlight = 0
        /// SHA-256 of the attach token, for exec Runs.
        var tokenDigest: String?
        /// The connection whose loss stops the Run.
        var owner: ObjectIdentifier
        /// How the Run ends once quiescent.
        var endAs: RunRecord.State = .completed
    }

    let runs: RunStore
    private let lock = NSLock()
    private var leases: [String: String] = [:]
    private var live: [String: Live] = [:]
    private let now: @Sendable () -> Date

    init(runs: RunStore, now: @escaping @Sendable () -> Date) {
        self.runs = runs
        self.now = now
    }

    var activeCount: Int { lock.withLock { live.count } }

    /// Start a Run on the session's Desktop and take its lease.
    func start(kind: String, session: RuntimeSession, owner: ConnectionState) -> Result<(RunRecord, token: String?), RuntimeError> {
        let at = Timestamp.string(now())
        let runId = DesktopRegistry.newId(prefix: "run")
        var token: String?
        let result: Result<RunRecord, RuntimeError> = lock.withLock {
            if let holder = leases[session.desktopId], live[holder] != nil {
                return .failure(RuntimeError(
                    "control_busy", "desktop \(session.desktopId) is controlled by run \(holder)", phase: .handler,
                    retryable: true, details: .obj([("desktopId", .string(session.desktopId)), ("holderRunId", .string(holder))])))
            }
            let record = RunRecord(runId: runId, caller: owner.peerUID, kind: kind, sessionId: session.sessionId,
                                   desktopId: session.desktopId, state: .running, quiescent: false, createdAt: at,
                                   endedAt: nil, endReason: nil, receipts: [])
            var l = Live(record: record, owner: ObjectIdentifier(owner))
            if kind == "exec" {
                let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                token = t
                l.tokenDigest = Self.digest(t)
            }
            live[runId] = l
            leases[session.desktopId] = runId
            return .success(record)
        }
        switch result {
        case let .failure(e): return .failure(e)
        case let .success(r):
            runs.create(r)
            owner.ownedRuns.insert(r.runId)
            return .success((r, token))
        }
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Let another connection of the same user act within an exec Run.
    func attach(runId: String, token: String, connection: ConnectionState) -> Result<RunRecord, RuntimeError> {
        let r: RunRecord? = lock.withLock {
            guard let l = live[runId], l.record.caller == connection.peerUID,
                  let d = l.tokenDigest, d == Self.digest(token) else { return nil }
            return l.record
        }
        guard let r else { return .failure(RuntimeError("permission_denied", "cannot attach to run \(runId)", phase: .handler)) }
        connection.attachedRuns.insert(runId)
        return .success(r)
    }

    /// The Run this connection may act in, if it is still running.
    func authorized(runId: String, connection: ConnectionState) -> Result<RunRecord, RuntimeError> {
        guard connection.ownedRuns.contains(runId) || connection.attachedRuns.contains(runId) else {
            return .failure(RuntimeError("permission_denied", "this connection does not own or attach to run \(runId)", phase: .handler))
        }
        return lock.withLock {
            guard let l = live[runId] else {
                return .failure(RuntimeError("run_not_active", "run \(runId) has ended", phase: .handler))
            }
            guard l.record.state == .running else {
                return .failure(RuntimeError("run_not_active", "run \(runId) is \(l.record.state.rawValue); it takes no new input",
                                             phase: .handler))
            }
            return .success(l.record)
        }
    }

    /// Right before dispatch: the Run still running and holding its
    /// Desktop. Counts the action as in flight.
    func beginAction(runId: String) -> RuntimeError? {
        lock.withLock {
            guard var l = live[runId], l.record.state == .running, leases[l.record.desktopId] == runId else {
                return RuntimeError("run_not_active", "run \(runId) was cancelled before this action was dispatched",
                                    phase: .handler, notSent: true)
            }
            l.inFlight += 1
            live[runId] = l
            return nil
        }
    }

    func endAction(runId: String, receiptId: String?) {
        let quiesce: Bool = lock.withLock {
            guard var l = live[runId] else { return false }
            l.inFlight -= 1
            if let receiptId { l.record.receipts.append(receiptId) }
            live[runId] = l
            return l.record.state == .cancelling && l.inFlight == 0
        }
        if let r = snapshot(runId) { runs.update(r) }
        if quiesce { settle(runId) }
    }

    private func snapshot(_ runId: String) -> RunRecord? { lock.withLock { live[runId]?.record } }

    public enum StopOutcome {
        case accepted(RunRecord)
        case alreadyTerminal(RunRecord)
        case notFound
    }

    /// Stop new input of the Run now; end it once quiescent. `endAs` is
    /// how it ends: cancelled (cancel, owner lost) or completed (finish).
    @discardableResult
    func stop(runId: String, reason: String, endAs: RunRecord.State) -> StopOutcome {
        let outcome: (StopOutcome, quiesceNow: Bool) = lock.withLock {
            guard var l = live[runId] else {
                return (runs.find(runId).map { .alreadyTerminal($0) } ?? .notFound, false)
            }
            if l.record.state == .running {
                l.record.state = .cancelling
                l.record.endReason = reason
                l.endAs = endAs
                live[runId] = l
            }
            return (.accepted(l.record), l.inFlight == 0)
        }
        if case let .accepted(r) = outcome.0 {
            runs.update(r)
            runs.appendEvent(runId, endAs == .completed ? "run.finishing" : "cancel.accepted",
                             .obj([("reason", .string(reason)), ("inFlight", .bool(!outcome.quiesceNow))]))
            if outcome.quiesceNow { settle(runId) }
        }
        return outcome.0
    }

    /// No input of the Run can follow: free the Desktop and end the Run.
    private func settle(_ runId: String) {
        let ended: RunRecord? = lock.withLock {
            guard var l = live.removeValue(forKey: runId) else { return nil }
            l.record.state = l.endAs
            l.record.quiescent = true
            l.record.endedAt = Timestamp.string(now())
            if leases[l.record.desktopId] == runId { leases.removeValue(forKey: l.record.desktopId) }
            return l.record
        }
        guard let ended else { return }
        runs.update(ended)
        runs.appendEvent(runId, "run.quiescent", .obj([]))
        runs.appendEvent(runId, "run.ended", .obj([("state", .string(ended.state.rawValue)),
                                                   ("reason", .string(ended.endReason ?? ""))]))
    }

    /// The owner connection is gone: its Runs take no further input.
    func ownerLost(_ connection: ConnectionState) {
        let owned: [String] = lock.withLock {
            live.filter { $0.value.owner == ObjectIdentifier(connection) }.map(\.key)
        }
        for id in owned { stop(runId: id, reason: "owner_lost", endAs: .cancelled) }
    }

    /// Whether a live Run holds the Desktop (destroy refuses then).
    func holder(of desktopId: String) -> String? { lock.withLock { leases[desktopId] } }
}
