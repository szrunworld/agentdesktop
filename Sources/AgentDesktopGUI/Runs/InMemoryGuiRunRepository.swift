import AgentDesktopContracts
import Foundation

/// GuiRunRepository in memory, for tests and until the SQLite store backs
/// it. Same semantics: caller-scoped reads, atomic idempotent create,
/// strictly increasing event sequences, pruning that makes old cursors
/// expire.
public actor InMemoryGuiRunRepository: GuiRunRepository {
    private struct Key: Hashable { let scope: String; let key: String }
    private var runs: [String: StoredGuiRun] = [:]
    private var keys: [Key: (digest: String, runId: String)] = [:]
    private var events: [String: [JSONValue]] = [:]
    private var lastSequence: [String: Int] = [:]
    private var pruned: [String: Int] = [:]
    public let maxEventsPerRun: Int

    public init(maxEventsPerRun: Int = 100_000) {
        self.maxEventsPerRun = maxEventsPerRun
    }

    public func create(_ run: StoredGuiRun, idempotencyKey: String, digest: String) throws -> GuiRunCreateOutcome {
        let k = Key(scope: run.callerScope, key: idempotencyKey)
        if let existing = keys[k] {
            guard existing.digest == digest else {
                throw ContractError(.idempotencyConflict, "this idempotency key was used for a different run")
            }
            guard let stored = runs[existing.runId] else { throw ContractError(.internalError, "internal error") }
            return .existing(stored)
        }
        keys[k] = (digest, run.runId)
        runs[run.runId] = run
        events[run.runId] = []
        lastSequence[run.runId] = 0
        return .created(run)
    }

    public func load(runId: String, callerScope: String) -> StoredGuiRun? {
        guard let r = runs[runId], r.callerScope == callerScope else { return nil }
        return r
    }

    public func saveSnapshot(runId: String, snapshot: JSONValue) throws {
        guard runs[runId] != nil else { throw ContractError(.notFound, "run not found") }
        runs[runId]?.snapshot = snapshot
    }

    public func appendEvent(runId: String, _ build: @Sendable (Int) -> JSONValue) throws -> Int {
        guard runs[runId] != nil else { throw ContractError(.notFound, "run not found") }
        let seq = (lastSequence[runId] ?? 0) + 1
        guard seq <= maxEventsPerRun else { throw ContractError(.limitExceeded, "the run's event log is full") }
        lastSequence[runId] = seq
        events[runId, default: []].append(build(seq))
        return seq
    }

    public func events(runId: String, afterSequence: Int, limit: Int) throws -> StoredEvents {
        guard let list = events[runId] else { throw ContractError(.notFound, "run not found") }
        let after = list.filter { ($0["sequence"]?.intValue ?? 0) > afterSequence }
        return StoredEvents(events: Array(after.prefix(limit)), oldestRetained: pruned[runId],
                            lastSequence: lastSequence[runId] ?? 0)
    }

    /// Drop events with sequence < `keepFrom` (retention). Cursors before
    /// the gap then expire.
    public func prune(runId: String, keepFrom: Int) {
        events[runId]?.removeAll { ($0["sequence"]?.intValue ?? 0) < keepFrom }
        pruned[runId] = keepFrom
    }
}
