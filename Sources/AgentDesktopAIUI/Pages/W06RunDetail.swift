import AgentDesktopProtocol
import Foundation
import SwiftUI

public struct EventRow: Identifiable, Equatable, Sendable {
    public var id: Int { sequence }
    public let sequence: Int
    public let type: String
    public let summary: String
    public let state: String?
    public let occurredAt: String
}

/// The latest input of a unit Run, from its action.* events (A6).
public struct ReceiptRow: Equatable, Sendable {
    public let actionId: String
    public let actionType: String
    /// confirmed (executed), failed, not_sent, unknown.
    public let deliveryState: String
    public let snapshotId: String
    public let startedAt: String?
    /// An observation the unit made after this input, if any.
    public let confirmationObservationId: String?
    public let reasonCode: String?

    public var deliveryText: String {
        switch deliveryState {
        case "confirmed": return "执行器已确认输入（不代表任务成功）"
        case "unknown": return "结果未知（不计为已确认）"
        case "failed": return "已送达，执行失败"
        case "not_sent": return "未发送"
        default: return deliveryState
        }
    }
}

/// W06 — 运行详情. Reads only run.show / run.events; stop (run.cancel) is
/// the only write. A6: the Run is the Runtime's (kind unit).
@MainActor
public final class RunDetailModel: ObservableObject {
    public enum StopPhase: Equatable { case none, requesting, requested, stopped }

    public let runId: String
    /// running, cancelling, waiting_user, succeeded, failed, cancelled, unknown.
    @Published public private(set) var state = "running"
    @Published public private(set) var events: [EventRow] = []
    @Published public private(set) var lastSequence = 0
    @Published public private(set) var modelAttempts = 0
    @Published public private(set) var stepCount = 0
    @Published public private(set) var confirmedActions = 0
    @Published public private(set) var unknownActions = 0
    @Published public private(set) var latestReceipt: ReceiptRow?
    @Published public private(set) var waitingReasonCode: String?
    @Published public private(set) var verification: (status: String, observationId: String?, checkedAt: String?) = ("not_run", nil, nil)
    @Published public private(set) var bindingSummary: [(String, String)] = []
    @Published public private(set) var desktopId = ""
    @Published public private(set) var createdAt = ""
    @Published public private(set) var stopPhase: StopPhase = .none
    @Published public private(set) var problem: UIProblem?
    /// closingReason of an ended Run.
    @Published public private(set) var errorCode: String?

    let client: ContractClient
    let clock: PollClock
    let pollMs: Int
    private var seen = Set<Int>()
    private var actionKinds: [String: String] = [:]

    public init(client: ContractClient, runId: String, clock: PollClock = SystemPollClock(), pollMs: Int = 500) {
        self.client = client
        self.runId = runId
        self.clock = clock
        self.pollMs = pollMs
    }

    public var isTerminal: Bool { ["succeeded", "failed", "cancelled", "unknown"].contains(state) }
    /// The Run needs a person: an input whose outcome is unknown, or a wait.
    public var needsAttention: Bool { state == "waiting_user" || state == "unknown" || unknownActions > 0 }

    public var stateText: String {
        switch state {
        case "succeeded": return "成功（新观察已验证完成条件）"
        case "failed": return "失败" + (errorCode.map { "（\($0)）" } ?? "")
        case "cancelled": return "已停止"
        case "unknown": return "结果未知 · 需要核实：有一项输入结果尚未确认"
        case "cancelling": return unknownActions > 0
            ? "停止请求已收到；有一项输入结果尚未确认" : "停止请求已收到，正在等待在途输入结束"
        case "waiting_user": return "需要处理（\(waitingReasonCode ?? "")）"
        default: return "进行中"
        }
    }

    /// One read of the Run and its new events.
    public func refresh() async {
        do {
            let run = try await client.runtime("run.show", .obj([("runId", .string(runId))]), requestId: nil)
            try await readEvents()
            apply(run)
            problem = nil
        } catch {
            problem = UIProblem(error)
        }
    }

    func readEvents() async throws {
        while true {
            let r = try await client.runtime("run.events", .obj([("runId", .string(runId)), ("after", .int(lastSequence)),
                                                                ("limit", .int(200))]), requestId: nil)
            let page = r["events"]?.arrayValue ?? []
            for e in page {
                guard let seq = e["sequence"]?.intValue, seen.insert(seq).inserted else { continue }
                note(e, sequence: seq)
            }
            events.sort { $0.sequence < $1.sequence }
            lastSequence = max(lastSequence, r["next"]?.intValue ?? lastSequence)
            if page.count < 200 { return }
        }
    }

    private func note(_ e: JSONValue, sequence: Int) {
        let type = e["type"]?.stringValue ?? ""
        let d = e["data"] ?? .obj([])
        let at = e["at"]?.stringValue ?? ""
        events.append(EventRow(sequence: sequence, type: type, summary: Self.summary(type, d), state: nil, occurredAt: at))
        switch type {
        case "unit.inference.attempt": modelAttempts += d["attempts"]?.intValue ?? 1
        case "unit.progress": stepCount += 1
        case "unit.needs_input": waitingReasonCode = d["reason"]?.stringValue
        case "action.accepted":
            if let id = d["requestId"]?.stringValue { actionKinds[id] = d["kind"]?.stringValue }
        case "action.completed", "action.failed", "action.unknown":
            let r = d["receipt"] ?? .obj([])
            let id = r["requestId"]?.stringValue ?? ""
            let delivery: String
            switch type {
            case "action.completed": delivery = "confirmed"; confirmedActions += 1
            case "action.unknown": delivery = "unknown"
            default: delivery = r["delivery"]?.stringValue == "not_dispatched" ? "not_sent" : "failed"
            }
            latestReceipt = ReceiptRow(actionId: id, actionType: actionKinds[id] ?? "", deliveryState: delivery,
                                       snapshotId: r["snapshotId"]?.stringValue ?? "", startedAt: at,
                                       confirmationObservationId: nil, reasonCode: r["reason"]?["code"]?.stringValue)
        case "unit.observation":
            if let l = latestReceipt, l.confirmationObservationId == nil {
                latestReceipt = ReceiptRow(actionId: l.actionId, actionType: l.actionType, deliveryState: l.deliveryState,
                                           snapshotId: l.snapshotId, startedAt: l.startedAt,
                                           confirmationObservationId: d["observationId"]?.stringValue, reasonCode: l.reasonCode)
            }
        default: break
        }
    }

    /// Ids, enums and codes only, as the events carry them.
    static func summary(_ type: String, _ d: JSONValue) -> String {
        switch type {
        case "unit.progress": return "第 \(d["stepIndex"]?.intValue ?? 0) 步，剩 \(d["stepsLeft"]?.intValue ?? 0) 步"
        case "unit.inference.attempt": return "模型调用 \(d["state"]?.stringValue ?? "")"
        case "unit.step.proposed": return "建议 \(d["actionKind"]?.stringValue ?? d["kind"]?.stringValue ?? "")"
        case "unit.step.rejected": return "建议被拒：\(d["reason"]?.stringValue ?? "")"
        case "unit.action": return "输入 \(d["deliveryState"]?.stringValue ?? "")"
        case "unit.verification": return "验证 \(d["status"]?.stringValue ?? "")"
        case "unit.needs_input": return "需要处理：\(d["reason"]?.stringValue ?? "")"
        case "run.ended": return "结束：\(d["outcome"]?.stringValue ?? "")，\(d["reason"]?.stringValue ?? "")"
        case "stop.accepted", "run.finishing": return d["reason"]?.stringValue ?? ""
        default: return ""
        }
    }

    func apply(_ run: JSONValue) {
        let phase = run["phase"]?.stringValue ?? "running"
        let outcome = run["outcome"]?.stringValue
        switch phase {
        case "ended": state = outcome == "success" ? "succeeded" : (outcome ?? "failed")
        case "stopping": state = "cancelling"
        case "waiting_input": state = "waiting_user"
        default: state = "running"
        }
        unknownActions = run["unknownActions"]?.intValue ?? unknownActions
        errorCode = phase == "ended" && outcome != "success" ? run["closingReason"]?.stringValue : nil
        let v = run["unit"]?["verification"]
        verification = (v?["status"]?.stringValue ?? "not_run", v?["observationId"]?.stringValue, v?["checkedAt"]?.stringValue)
        createdAt = run["createdAt"]?.stringValue ?? ""
        desktopId = run["desktopId"]?.stringValue ?? ""
        let unit = run["unit"]
        bindingSummary = [
            ("Desktop", desktopId),
            ("GUI 配置", "\(unit?["guiProfileId"]?.stringValue ?? "—") r\(unit?["guiProfileRevision"]?.intValue ?? 0)"),
            ("模式", unit?["mode"]?.stringValue ?? ""),
            ("任务摘要", String((unit?["goalHash"]?.stringValue ?? "").prefix(19))),
            ("来源", "\(run["origin"]?.stringValue ?? "") · \(run["lifetime"]?.stringValue ?? "")"),
        ]
        if state == "cancelled" { stopPhase = .stopped }
    }

    /// Polls until the Run ends or needs a person.
    public func follow(maxPolls: Int = .max) async {
        var n = 0
        while n < maxPolls {
            await refresh()
            if isTerminal || needsAttention { return }
            n += 1
            do { try await clock.pause(milliseconds: pollMs) } catch { return }
        }
    }

    /// Accepted is not stopped: "stopped" only once the Run ended cancelled.
    public func stop() async {
        guard stopPhase == .none || stopPhase == .requested else { return }
        stopPhase = .requesting
        do {
            let r = try await client.runtime("run.cancel", .obj([("runId", .string(runId))]), requestId: "w06-stop-\(runId)")
            let ex = r["execution"]
            if ex?["phase"]?.stringValue == "ended" {
                let outcome = ex?["outcome"]?.stringValue
                state = outcome == "success" ? "succeeded" : (outcome ?? state)
                stopPhase = state == "cancelled" ? .stopped : .none
                if stopPhase == .none { problem = UIProblem(ContractError(.operationNotCancellable, "")) }
            } else {
                state = "cancelling"
                stopPhase = .requested
            }
        } catch {
            stopPhase = .none
            problem = UIProblem(error)
        }
    }

    public var canStop: Bool { !isTerminal && stopPhase == .none }
}

public struct RunDetailView: View {
    @ObservedObject var model: RunDetailModel
    var onAttention: (String) -> Void

    public init(model: RunDetailModel, onAttention: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onAttention = onAttention
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("运行详情").font(.title2).bold().accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("刷新") { Task { await model.refresh() } }
                    Button("停止") { Task { await model.stop() } }.disabled(!model.canStop)
                }
                if let p = model.problem { ProblemBanner(problem: p) }
                Text(model.stateText).font(.headline).accessibilityAddTraits(.updatesFrequently)
                if model.needsAttention { Button("查看需要处理的运行") { onAttention(model.runId) } }
                LabeledValue(label: "运行", value: model.runId)
                LabeledValue(label: "创建时间", value: Format.time(model.createdAt))
                LabeledValue(label: "模型尝试", value: "\(model.modelAttempts)")
                LabeledValue(label: "已确认动作", value: "\(model.confirmedActions)")
                LabeledValue(label: "决策步数", value: "\(model.stepCount)")
                LabeledValue(label: "完成验证", value: model.verification.status == "matched"
                             ? "通过（观察 \(model.verification.observationId ?? "—")，\(Format.time(model.verification.checkedAt))）"
                             : model.verification.status == "contradicted" ? "未满足" : "未执行")
                if let r = model.latestReceipt {
                    GroupBox("最近的动作回执") {
                        LabeledValue(label: "动作", value: "\(r.actionType) · \(r.actionId)")
                        LabeledValue(label: "状态", value: r.deliveryText)
                        LabeledValue(label: "动作前快照", value: r.snapshotId)
                    }
                }
                GroupBox("固定的配置版本") {
                    ForEach(Array(model.bindingSummary.enumerated()), id: \.offset) { _, kv in LabeledValue(label: kv.0, value: kv.1) }
                }
                GroupBox("事件") {
                    ForEach(model.events) { e in
                        Text("#\(e.sequence) \(Format.time(e.occurredAt)) \(e.type) \(e.summary)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .task { await model.follow() }
    }
}
