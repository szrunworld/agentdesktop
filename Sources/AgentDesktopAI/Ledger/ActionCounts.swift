import AgentDesktopProtocol
import Foundation

extension ConfigStore {
    /// Inputs a caller's runs handed to the desktop in [from, to), for
    /// `ai.usage.summary`: confirmed deliveries, and outcomes still unknown
    /// (unknown, or submitted without confirmation, and not yet reconciled).
    /// With `connectionId`, only runs that called a model on that connection.
    public func actionOutcomeCounts(callerScope: String, from: Date, to: Date,
                                    connectionId: String?) throws -> (confirmed: Int, unknown: Int) {
        var sql = """
            SELECT a.state, a.reconciled, a.reserved_at FROM action_receipts a
            JOIN gui_runs r ON r.run_id = a.run_id
            WHERE r.caller_scope = ?
            """
        var args: [SQLValue] = [.text(callerScope)]
        if let connectionId {
            sql += " AND a.run_id IN (SELECT run_id FROM inference_attempts WHERE run_id IS NOT NULL AND connection_id = ?)"
            args.append(.text(connectionId))
        }
        var confirmed = 0, unknown = 0
        for r in try db.rows(sql, args) {
            guard let at = r[2].text.flatMap(Self.parseTimestamp), at >= from, at < to else { continue }
            switch r[0].text {
            case "confirmed": confirmed += 1
            case "unknown", "submitted": if r[1].int == 0 { unknown += 1 }
            default: break
            }
        }
        return (confirmed, unknown)
    }
}
