import Foundation
import AgentDesktopContracts

/// `ai.usage.summary` (spec §09.3, §18.1): model attempts of both purposes,
/// counted once each by inferenceAttemptId, with known values, unknown
/// counts and estimated cost kept apart. Never a final bill.
public enum UsageSummaryBuilder {
    /// - Parameters:
    ///   - records: finished ledger rows the caller is allowed to see.
    ///   - from/to: half-open range on the attempt's start time.
    ///   - connectionId: optional filter.
    ///   - confirmedActions / unknownActionOutcomes: from the action
    ///     receipts, counted separately; model attempts never stand in for them.
    public static func summarize(_ records: [AiCallRecord], from: Date, to: Date, connectionId: ResourceID? = nil,
                                 confirmedActions: Int = 0, unknownActionOutcomes: Int = 0) -> JSONValue {
        var seen = Set<ResourceID>()
        let rows = records.filter { r in
            guard r.startedAt >= from, r.startedAt < to else { return false }
            if let c = connectionId, r.target.connection.connectionId != c { return false }
            return seen.insert(r.context.inferenceAttemptId).inserted
        }

        func sum(_ pick: (UsageTokens) -> Int?) -> Int? {
            let known = rows.compactMap { $0.usage.flatMap(pick) }
            return known.isEmpty ? nil : known.reduce(0, +)
        }
        let anyUsage = rows.contains { $0.usage != nil }
        let reported: JSONValue = anyUsage
            ? UsageTokens(inputTokens: sum(\.inputTokens), outputTokens: sum(\.outputTokens),
                          cacheReadTokens: sum(\.cacheReadTokens), cacheWriteTokens: sum(\.cacheWriteTokens),
                          totalTokens: sum(\.totalTokens)).json
            : .null
        let missing = rows.filter { !($0.usage?.isComplete ?? false) }.count

        // Cost: add up only what is known, in one currency; say how much is covered.
        let costs = rows.compactMap(\.cost)
        var subtotal: JSONValue = .null
        var coverage = "unknown"
        if let currency = costs.first?.currency, costs.allSatisfy({ $0.currency == currency }) {
            let total = costs.compactMap { Decimal(string: $0.amount) }.reduce(Decimal(0), +)
            let source = costs.allSatisfy { $0.source == .reported } ? "reported" : "estimated"
            let revisions = Set(costs.compactMap(\.pricingRevision))
            subtotal = .obj([("amount", .string(DecimalText.format(total))), ("currency", .string(currency)),
                             ("source", .string(source)),
                             ("pricingRevision", revisions.count == 1 ? .string(revisions.first!) : .null)])
            coverage = costs.count == rows.count ? "complete" : "partial"
        } else if !costs.isEmpty {
            coverage = "partial"   // mixed currencies: no single subtotal
        }
        if rows.isEmpty { coverage = "complete" }

        return .obj([
            ("from", .string(isoString(from))),
            ("to", .string(isoString(to))),
            ("inferenceAttempts", .int(rows.count)),
            ("confirmedActions", .int(confirmedActions)),
            ("unknownActionOutcomes", .int(unknownActionOutcomes)),
            ("attemptsMissingUsage", .int(missing)),
            ("reportedTokens", reported),
            ("knownCostSubtotal", subtotal),
            ("costCoverage", .string(coverage)),
            ("isFinalBill", .bool(false)),
        ])
    }

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
