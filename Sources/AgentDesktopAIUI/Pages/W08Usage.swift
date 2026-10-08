import AgentDesktopProtocol
import Foundation
import SwiftUI

/// W08 — 用量与诊断. Model attempts and real inputs are counted apart;
/// unreported usage stays unknown; money is an estimate, never a bill.
@MainActor
public final class UsageModel: ObservableObject {
    @Published public var from: Date
    @Published public var to: Date
    @Published public var connectionId: String?
    @Published public private(set) var connections: [ConnectionRow] = []
    @Published public private(set) var summary: JSONValue?
    @Published public private(set) var problem: UIProblem?
    @Published public private(set) var phase: LoadPhase = .idle

    let client: ContractClient

    public init(client: ContractClient, from: Date = Date(timeIntervalSinceNow: -7 * 86400), to: Date = Date()) {
        self.client = client
        self.from = from
        self.to = to
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = Format.shanghai
        return f.string(from: d)
    }

    public func refresh() async {
        phase = .loading
        var p: [(String, JSONValue)] = [("from", .string(Self.iso(from))), ("to", .string(Self.iso(to)))]
        if let c = connectionId { p.append(("connectionId", .string(c))) }
        do {
            if connections.isEmpty {
                connections = (try await client.send("ai.connections.list", .obj([("limit", .int(100))]))["items"]?.arrayValue ?? []).map(ConnectionRow.init)
            }
            summary = try await client.send("ai.usage.summary", .obj(p))
            problem = nil
            phase = .loaded
        } catch {
            problem = UIProblem(error)
            phase = .failed
        }
    }

    public var attempts: Int { summary?["inferenceAttempts"]?.intValue ?? 0 }
    public var confirmedActions: Int { summary?["confirmedActions"]?.intValue ?? 0 }
    public var unknownOutcomes: Int { summary?["unknownActionOutcomes"]?.intValue ?? 0 }
    public var missingUsage: Int { summary?["attemptsMissingUsage"]?.intValue ?? 0 }

    public var coverageText: String { "\(attempts - missingUsage)/\(attempts) 次尝试报告了用量" }

    public var tokenText: (input: String, output: String, total: String) {
        let t = summary?["reportedTokens"]
        guard let t, !t.isNull else { return ("未知 / 未报告", "未知 / 未报告", "未知 / 未报告") }
        return (Format.tokens(t["inputTokens"]), Format.tokens(t["outputTokens"]), Format.tokens(t["totalTokens"]))
    }

    public var costText: String {
        let c = summary?["knownCostSubtotal"]
        let coverage = summary?["costCoverage"]?.stringValue ?? "unknown"
        guard let c, !c.isNull, let amount = c["amountDecimal"]?.stringValue else { return "总额未知" }
        let base = "\(amount) \(c["currency"]?.stringValue ?? "")（估算）"
        return coverage == "complete" ? base : base + " · 不完整，总额未知"
    }

    public var billNote: String { "估算参考，不是上游账单，也不是硬性花费上限。" }
}

public struct UsageView: View {
    @ObservedObject var model: UsageModel

    public init(model: UsageModel) { self.model = model }

    public var body: some View {
        Form {
            Text("用量与诊断").font(.title2).bold().accessibilityAddTraits(.isHeader)
            DatePicker("开始（Asia/Shanghai）", selection: $model.from)
            DatePicker("结束", selection: $model.to)
            Picker("连接", selection: $model.connectionId) {
                Text("全部").tag(String?.none)
                ForEach(model.connections) { c in Text(c.name).tag(Optional(c.id)) }
            }
            Button("查询") { Task { await model.refresh() } }
            if let p = model.problem { ProblemBanner(problem: p) }
            Section("模型尝试") {
                LabeledValue(label: "尝试次数", value: "\(model.attempts)")
                LabeledValue(label: "用量覆盖", value: model.coverageText)
                LabeledValue(label: "输入 token", value: model.tokenText.input)
                LabeledValue(label: "输出 token", value: model.tokenText.output)
                LabeledValue(label: "合计 token", value: model.tokenText.total)
                LabeledValue(label: "已知费用", value: model.costText)
                Text(model.billNote).font(.caption)
            }
            Section("实际动作") {
                LabeledValue(label: "已确认动作", value: "\(model.confirmedActions)")
                LabeledValue(label: "结果未知的动作", value: "\(model.unknownOutcomes)（不计为已确认）")
            }
        }
        .padding()
        .task { await model.refresh() }
    }
}
