import AgentDesktopProtocol
import SwiftUI

// Lane UI-D (U6): P30 用量（诊断导出 is U9). Only the built-in GUI
// diagnostics' model calls are counted. Model attempts and real inputs are
// counted apart; a number not reported stays unknown, never zero; money is
// an estimate, never a bill (AgentDesktopAIUI W08's rules).

@MainActor
final class SettingsUsageModel: ObservableObject {
    @Published private(set) var summary: JSONValue?
    @Published private(set) var failure: SettingsFailure?
    @Published private(set) var loaded = false
    let runtime: RuntimePort
    let days: Int
    let now: () -> Date

    init(runtime: RuntimePort, days: Int = 7, now: @escaping () -> Date = Date.init) {
        self.runtime = runtime
        self.days = days
        self.now = now
    }

    func refresh() async {
        let to = now()
        let from = to.addingTimeInterval(-Double(days) * 86400)
        do {
            summary = try await runtime.call("ai.usage.summary", .obj([("from", .string(SettingsTime.iso(from))),
                                                                       ("to", .string(SettingsTime.iso(to)))]))
            loaded = true
            failure = nil
        } catch {
            failure = SettingsFailure(error)
        }
    }

    var attempts: Int { summary?["inferenceAttempts"]?.intValue ?? 0 }
    var confirmed: Int { summary?["confirmedActions"]?.intValue ?? 0 }
    var unknownOutcomes: Int { summary?["unknownActionOutcomes"]?.intValue ?? 0 }
    var missing: Int { summary?["attemptsMissingUsage"]?.intValue ?? 0 }

    /// Total tokens, or nil when no attempt reported any.
    var totalTokens: Int? {
        guard let t = summary?["reportedTokens"], !t.isNull else { return nil }
        return t["totalTokens"]?.intValue
    }

    var tokenText: String { totalTokens.map { $0.formatted(.number) } ?? "未知" }

    var tokenNote: String {
        if attempts == 0 { return "还没有模型调用" }
        if missing > 0 { return "\(attempts - missing)/\(attempts) 次报告了用量；未报告的不按 0 计" }
        return "全部 \(attempts) 次都报告了用量"
    }

    var costText: String {
        guard let c = summary?["knownCostSubtotal"], !c.isNull, let amount = c["amount"]?.stringValue else {
            return "费用未知，不按 ¥0 显示"
        }
        let coverage = summary?["costCoverage"]?.stringValue ?? "unknown"
        let base = "已知费用 \(amount) \(c["currency"]?.stringValue ?? "")（估算，不是账单）"
        return coverage == "complete" ? base : base + "；不完整，总额未知"
    }
}

struct SettingsUsagePage: View {
    @ObservedObject var model: SettingsUsageModel
    let onRuns: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            HStack {
                Text("这里只记录内置 GUI 调用（最近 \(model.days) 天）。外部 Agent 的费用和推理留在调用方。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
                Spacer()
                Button { Task { await model.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .buttonStyle(ADButtonStyle(.secondary))
                Button {} label: { Label("导出诊断", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(true)
                    .help("尚未启用：诊断导出随 U9 提供")
            }
            if let f = model.failure { SettingsFailureView(failure: f, retry: { Task { await model.refresh() } }) }
            HStack(spacing: ADSpace.l) {
                metric("模型尝试", value: model.loaded ? "\(model.attempts)" : "—", unit: "次", note: "与桌面输入次数分别计量")
                metric("真实动作回执", value: model.loaded ? "\(model.confirmed)" : "—", unit: "次",
                       note: model.unknownOutcomes > 0 ? "另有 \(model.unknownOutcomes) 次结果未知" : "已确认送达的输入")
                metric("已知 token / 费用", value: model.loaded ? model.tokenText : "—", unit: nil, note: model.costText)
            }
            SettingsCard(title: "内置 GUI 运行", trailing: {
                Button("在 Runs 中查看", action: onRuns).buttonStyle(ADButtonStyle(.secondary))
            }) {
                VStack(alignment: .leading, spacing: ADSpace.s) {
                    StateBadge("按运行汇总尚未提供", tone: .idle)
                    Text("按运行汇总用量需要 ai.usage.summary 支持按 runId 查询（F40-04）。在那之前这里只显示时间范围内的合计；每个运行的动作记录在 Runs 中查看。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(ADSpace.l)
            }
            SettingsNote(title: "未知用量保持未知", detail: "有些模型响应不提供 token；不补零，不用累计输入动作推算模型费用。\(model.tokenNote)。")
        }
        .task { if !model.loaded { await model.refresh() } }
    }

    func metric(_ title: String, value: String, unit: String?, note: String) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            Text(title).font(ADFont.note).foregroundStyle(ADColor.muted)
            HStack(alignment: .firstTextBaseline, spacing: ADSpace.xs) {
                Text(value).font(.system(size: 30, weight: .bold)).foregroundStyle(ADColor.primary)
                if let unit { Text(unit).font(ADFont.noteStrong).foregroundStyle(ADColor.primary) }
            }
            Text(note).font(ADFont.note).foregroundStyle(ADColor.muted).lineLimit(2)
        }
        .padding(ADSpace.l)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .adPanel()
        .accessibilityElement(children: .combine)
    }
}
