// Ledger semantics follow 2ndscreen da5677c packages/task-runtime/src/
// agent-ledgers.ts: every started call is a row, unknown counts are never
// added up as zero. Durable SQLite storage comes with the config store (T03).
import Foundation
import AgentDesktopContracts

/// An `AiCallLedgerPort` held in memory, for tests and until the SQLite
/// store implements the same port. Faults can be injected.
public actor InMemoryAiCallLedger: AiCallLedgerPort {
    public enum RowState: Equatable, Sendable { case reserved, finished }

    public struct Row: Sendable {
        public let reservationId: ResourceID
        public let context: AiCallContext
        public let target: AiResolvedModel
        public var state: RowState
        public var record: AiCallRecord?
    }

    private var rows: [ResourceID: Row] = [:]
    private var order: [ResourceID] = []
    /// Make the next `reserve` calls fail (pre-call audit unavailable).
    public var failReserve = false
    /// Make the next `finish` calls fail (post-call audit unavailable).
    public var failFinish = false
    /// After a finish could not be written, no new reservation is accepted
    /// until recovery: progress stops instead of running untraceably.
    public private(set) var needsRecovery = false

    public init() {}

    public func setFailReserve(_ v: Bool) { failReserve = v }
    public func setFailFinish(_ v: Bool) { failFinish = v }
    public func clearRecovery() { needsRecovery = false }

    public func reserve(context: AiCallContext, target: AiResolvedModel) async throws -> ResourceID {
        if failReserve || needsRecovery {
            throw ContractError(.auditUnavailable, "the call ledger cannot record a new attempt")
        }
        let id = context.inferenceAttemptId
        if rows[id] != nil {
            throw ContractError(.validationError, "inference attempt id was already reserved")
        }
        rows[id] = Row(reservationId: id, context: context, target: target, state: .reserved, record: nil)
        order.append(id)
        return id
    }

    public func finish(_ record: AiCallRecord) async throws {
        if failFinish {
            needsRecovery = true
            throw ContractError(.auditUnavailable, "the call ledger cannot record the attempt's end")
        }
        guard var row = rows[record.reservationId] else {
            throw ContractError(.validationError, "finish without a reservation")
        }
        // A repeated finish for the same attempt is ignored, never counted twice.
        guard row.state == .reserved else { return }
        row.state = .finished
        row.record = record
        rows[record.reservationId] = row
    }

    /// Every reservation in order, finished or not.
    public func allRows() -> [Row] { order.compactMap { rows[$0] } }

    /// Finished records in order.
    public func records() -> [AiCallRecord] { order.compactMap { rows[$0]?.record } }
}
