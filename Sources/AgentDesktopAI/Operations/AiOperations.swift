import AgentDesktopContracts
import Foundation

public enum AiOperationKind: String, Sendable {
    case capabilityTest = "capability_test"
    case modelRefresh = "model_refresh"
}

public enum AiOperationState: String, Sendable {
    case queued, running, cancelling, succeeded, failed, cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

/// Asynchronous operations (`ai.tests.start`, `ai.models.refresh`) in the
/// configuration database (spec §05.3, §05.4). An operation belongs to the
/// caller that started it; others get NOT_FOUND. A terminal state never
/// changes again.
extension ConfigStore {
    public func createOperation(kind: AiOperationKind, callerScope: String, resourceId: String,
                                resourceRevision: Int) throws -> String {
        let id = Self.randomId("op")
        let t = Self.timestamp(clock.now())
        try db.run("INSERT INTO ai_operations VALUES(?,?,?,?,?,'queued',NULL,NULL,?,?)",
                   [.text(id), .text(kind.rawValue), .text(callerScope), .text(resourceId),
                    .int(Int64(resourceRevision)), .text(t), .text(t)])
        return id
    }

    /// The contract's AiOperation, or NOT_FOUND for another caller's id.
    public func operation(_ id: String, callerScope: String) throws -> JSONValue {
        guard let r = try db.row("""
            SELECT operation_id, kind, state, resource_id, resource_revision, created_at, updated_at, result, error
            FROM ai_operations WHERE operation_id=? AND caller_scope=?
            """, [.text(id), .text(callerScope)]) else {
            throw ContractError(.notFound, "operation not found")
        }
        return .obj([
            ("operationId", .string(r[0].text!)), ("kind", .string(r[1].text!)), ("state", .string(r[2].text!)),
            ("resourceId", .string(r[3].text!)), ("resourceRevision", .int(Int(r[4].int!))),
            ("createdAt", .string(r[5].text!)), ("updatedAt", .string(r[6].text!)),
            ("result", try r[7].text.map { try StrictJSON.parse($0) } ?? .null),
            ("error", try r[8].text.map { try StrictJSON.parse($0) } ?? .null),
        ])
    }

    public func operationState(_ id: String) throws -> AiOperationState? {
        try db.row("SELECT state FROM ai_operations WHERE operation_id=?", [.text(id)])?[0].text
            .flatMap(AiOperationState.init(rawValue:))
    }

    /// Move an operation on. Refused once terminal, and a cancelling
    /// operation only ends cancelled (or, if its work already finished,
    /// with that work's real outcome).
    @discardableResult
    public func setOperation(_ id: String, state next: AiOperationState, result: JSONValue? = nil,
                             error: ContractError? = nil) throws -> Bool {
        guard let current = try operationState(id) else { throw ContractError(.notFound, "operation not found") }
        if current.isTerminal { return false }
        if current == .cancelling, next == .running { return false }
        let n = try db.run("UPDATE ai_operations SET state=?, result=?, error=?, updated_at=? WHERE operation_id=? AND state=?", [
            .text(next.rawValue), result.map { .text($0.encoded()) } ?? .null,
            error.map { .text(Self.rpcError($0).encoded()) } ?? .null,
            .text(Self.timestamp(clock.now())), .text(id), .text(current.rawValue),
        ])
        return n == 1
    }

    /// `ai.operations.cancel`: accepting is not being cancelled. Repeats
    /// are harmless; a succeeded or failed operation is left as it is.
    public func requestOperationCancel(_ id: String, callerScope: String) throws -> (accepted: Bool, state: AiOperationState) {
        _ = try operation(id, callerScope: callerScope)
        let current = try operationState(id)!
        switch current {
        case .queued, .running:
            try setOperation(id, state: .cancelling)
            return (true, .cancelling)
        case .cancelling, .cancelled:
            return (true, current)
        case .succeeded, .failed:
            return (false, current)
        }
    }

    /// Partial result kept while an operation runs, so a failure or a crash
    /// still reports the layers already done.
    public func saveOperationProgress(_ id: String, _ partial: JSONValue) throws {
        try db.run("INSERT OR REPLACE INTO capability_tests VALUES(?,?,?)",
                   [.text(id), .text(partial.encoded()), .text(Self.timestamp(clock.now()))])
    }

    public func operationProgress(_ id: String) throws -> JSONValue? {
        try db.row("SELECT body FROM capability_tests WHERE operation_id=?", [.text(id)])?[0].text
            .map { try StrictJSON.parse($0) }
    }

    /// After a restart: unfinished operations end. Their work is gone; a
    /// capability test keeps the layers it had finished.
    public func recoverOperations() throws {
        let interrupted = ContractError(.internalError, "the operation was interrupted by a restart; start it again")
        for r in try db.rows("SELECT operation_id, kind, state FROM ai_operations WHERE state IN ('queued','running','cancelling')") {
            let id = r[0].text!
            if r[2].text == "cancelling" {
                try setOperation(id, state: .cancelled)
            } else if r[1].text == AiOperationKind.capabilityTest.rawValue {
                try setOperation(id, state: .failed, result: try operationProgress(id), error: interrupted)
            } else {
                try setOperation(id, state: .failed, error: interrupted)
            }
        }
    }

    /// A ContractError as the contract's RpcError: only the detail members
    /// the schema allows.
    static func rpcError(_ e: ContractError) -> JSONValue {
        let message = e.message.isEmpty ? e.code.rawValue : String(e.message.prefix(512))
        var m: [(String, JSONValue)] = [
            ("code", .string(e.code.rawValue)),
            ("message", .string(message)),
            ("retryable", .bool(e.retryable)),
        ]
        let allowed: Set<String> = ["retryAfterMs", "currentRevision", "resourceId", "operationId", "runId", "reasonCode"]
        if let details = e.details?.objectMembers {
            let kept = details.filter { allowed.contains($0.key) }
            if !kept.isEmpty { m.append(("details", .object(kept))) }
        }
        return .obj(m)
    }
}

/// Owns the background task of each running operation, at most one per id,
/// so a duplicate start (same idempotency key) never runs the work twice
/// and a cancel reaches the work in flight.
public actor AiOperationRunner {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var started: Set<String> = []

    public init() {}

    /// Start `work` for `operationId` unless it was started before.
    /// Returns false for a repeat.
    @discardableResult
    public func start(_ operationId: String, _ work: @escaping @Sendable () async -> Void) -> Bool {
        guard started.insert(operationId).inserted else { return false }
        tasks[operationId] = Task {
            await work()
            self.finished(operationId)
        }
        return true
    }

    public func cancel(_ operationId: String) {
        tasks[operationId]?.cancel()
    }

    /// Wait for the operation's work to end (tests and shutdown).
    public func wait(_ operationId: String) async {
        await tasks[operationId]?.value
    }

    public var running: Int { tasks.count }

    /// Whether the operation's work is still in flight.
    public func isActive(_ operationId: String) -> Bool { tasks[operationId] != nil }

    private func finished(_ operationId: String) {
        tasks[operationId] = nil
    }
}
