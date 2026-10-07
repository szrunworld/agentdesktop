import AgentDesktopContracts
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

public struct ReceiptRow: Equatable, Sendable {
    public let actionId: String
    public let actionType: String
    public let deliveryState: String
    public let snapshotId: String
    public let startedAt: String?
    public let confirmationObservationId: String?
    public let reasonCode: String?

    init?(_ v: JSONValue?) {
        guard let v, !v.isNull, let id = v["actionId"]?.stringValue else { return nil }
        actionId = id
        actionType = v["actionType"]?.stringValue ?? ""
        deliveryState = v["deliveryState"]?.stringValue ?? ""
        snapshotId = v["snapshotId"]?.stringValue ?? ""
        startedAt = v["startedAt"]?.stringValue
        confirmationObservationId = v["confirmationObservationId"]?.stringValue
        reasonCode = v["reasonCode"]?.stringValue
    }

    public var deliveryText: String {
        switch deliveryState {
        case "confirmed": return "执行器已确认输入（不代表任务成功）"
        case "unknown": return "结果未知（不计为已确认）"
        case "submitted": return "已提交，未确认"
        case "rejected": return "已拒绝，未执行"
        case "not_sent": return "未发送"
        default: return deliveryState
        }
    }
}

/// W06 — 运行详情. Reads only gui.runs.get/events; stop is the only write.
@MainActor
public final class RunDetailModel: ObservableObject {
    public enum StopPhase: Equatable { case none, requesting, requested, stopped }

    public let runId: String
    @Published public private(set) var state = "queued"
    @Published public private(set) var events: [EventRow] = []
    @Published public private(set) var lastSequence = 0
    @Published public private(set) var modelAttempts = 0
    @Published public private(set) var stepCount = 0
    @Published public private(set) var confirmedActions = 0
    @Published public private(set) var latestReceipt: ReceiptRow?
    @Published public private(set) var waitingReasonCode: String?
    @Published public private(set) var verification: (status: String, observationId: String?, checkedAt: String?) = ("not_run", nil, nil)
    @Published public private(set) var bindingSummary: [(String, String)] = []
    @Published public private(set) var desktopId = ""
    @Published public private(set) var createdAt = ""
    @Published public private(set) var stopPhase: StopPhase = .none
    @Published public private(set) var problem: UIProblem?
    @Published public private(set) var errorCode: String?

    let client: ContractClient
    let clock: PollClock
    let pollMs: Int
    private var seen = Set<Int>()

    public init(client: ContractClient, runId: String, clock: PollClock = SystemPollClock(), pollMs: Int = 500) {
        self.client = client
        self.runId = runId
        self.clock = clock
        self.pollMs = pollMs
    }

    public nonisolated static let stages = ["queued", "observing", "inferencing", "validating", "executing", "verifying"]
    public var isTerminal: Bool { ["succeeded", "failed", "cancelled"].contains(state) }
    /// The run needs a person: an input whose outcome is unknown, or a wait.
    public var needsAttention: Bool { state == "waiting_user" || waitingReasonCode == ErrorCode.actionOutcomeUnknown.rawValue }

    public var stateText: String {
        switch state {
        case "succeeded": return "成功（新观察已验证完成条件）"
        case "failed": return "失败"
        case "cancelled": return "已停止"
        case "cancelling": return waitingReasonCode == ErrorCode.actionOutcomeUnknown.rawValue
            ? "停止请求已收到；有一项输入结果尚未确认" : "停止请求已收到，正在等待在途输入核对"
        case "waiting_user": return waitingReasonCode == ErrorCode.actionOutcomeUnknown.rawValue ? "需要处理：有一项输入结果尚未确认" : "需要处理"
        default: return "进行中：\(state)"
        }
    }

    /// One read of the run and its new events.
    public func refresh() async {
        do {
            let run = try await client.send("gui.runs.get", .obj([("runId", .string(runId))]))
            apply(run)
            try await readEvents()
            problem = nil
        } catch {
            problem = UIProblem(error)
        }
    }

    func readEvents() async throws {
        var hasMore = true
        while hasMore {
            let r: JSONValue
            do {
                r = try await client.send("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(lastSequence))]))
            } catch let e as ContractError where e.code == .eventsCursorExpired {
                // Do not infer what happened in the gap: start again from the current snapshot.
                events.removeAll()
                seen.removeAll()
                lastSequence = 0
                continue
            }
            for e in r["events"]?.arrayValue ?? [] {
                guard let seq = e["sequence"]?.intValue, seen.insert(seq).inserted else { continue }
                events.append(EventRow(sequence: seq, type: e["type"]?.stringValue ?? "", summary: e["summary"]?.stringValue ?? "",
                                       state: e["state"]?.stringValue, occurredAt: e["occurredAt"]?.stringValue ?? ""))
                if e["actionReceipt"]?["deliveryState"]?.stringValue == "confirmed" { confirmedActions += 1 }
            }
            events.sort { $0.sequence < $1.sequence }
            lastSequence = max(lastSequence, r["nextAfterSequence"]?.intValue ?? lastSequence)
            hasMore = r["hasMore"]?.boolValue == true
        }
    }

    func apply(_ run: JSONValue) {
        state = run["state"]?.stringValue ?? state
        modelAttempts = run["modelAttemptCount"]?.intValue ?? modelAttempts
        stepCount = run["stepCount"]?.intValue ?? stepCount
        waitingReasonCode = run["waitingReasonCode"]?.stringValue
        latestReceipt = ReceiptRow(run["latestActionReceipt"]) ?? latestReceipt
        let gv = run["goalVerification"]
        verification = (gv?["status"]?.stringValue ?? "not_run", gv?["observationId"]?.stringValue, gv?["checkedAt"]?.stringValue)
        errorCode = run["error"]?["code"]?.stringValue
        createdAt = run["createdAt"]?.stringValue ?? ""
        let b = run["binding"]
        desktopId = b?["desktopId"]?.stringValue ?? ""
        let p = b?["primary"]
        bindingSummary = [
            ("Desktop", desktopId),
            ("GUI 配置", "\(p?["guiProfile"]?["name"]?.stringValue ?? "") r\(p?["guiProfile"]?["revision"]?.intValue ?? 0)"),
            ("模型配置", "\(p?["modelProfile"]?["modelId"]?.stringValue ?? "") r\(p?["modelProfile"]?["revision"]?.intValue ?? 0)"),
            ("连接", "\(p?["connection"]?["name"]?.stringValue ?? "") r\(p?["connection"]?["revision"]?.intValue ?? 0)"),
            ("适配器 / 提示 / 解析器", "\(p?["guiProfile"]?["adapterId"]?.stringValue ?? "") / \(p?["guiProfile"]?["promptVersion"]?.stringValue ?? "") / \(p?["guiProfile"]?["parserVersion"]?.stringValue ?? "")"),
            ("凭据身份", Format.masked(p?["credentialIdentityRef"]?.stringValue)),
            ("策略版本", "\(b?["policyRevision"]?.intValue ?? 0)"),
            ("完成条件", b?["verification"]?["text"]?.stringValue ?? ""),
        ]
        if state == "cancelled" { stopPhase = .stopped }
    }

    /// Polls until the run ends or needs a person.
    public func follow(maxPolls: Int = .max) async {
        var n = 0
        while n < maxPolls {
            await refresh()
            if isTerminal || needsAttention { return }
            n += 1
            do { try await clock.pause(milliseconds: pollMs) } catch { return }
        }
    }

    /// Accepted is not stopped: "stopped" only once get says cancelled.
    public func stop() async {
        guard stopPhase == .none || stopPhase == .requested else { return }
        stopPhase = .requesting
        do {
            let r = try await client.send("gui.runs.cancel", .obj([("runId", .string(runId))]), idempotencyKey: "w06-stop-\(runId)")
            state = r["state"]?.stringValue ?? state
            stopPhase = state == "cancelled" ? .stopped : (r["accepted"]?.boolValue == true ? .requested : .none)
            if stopPhase == .none { problem = UIProblem(ContractError(.operationNotCancellable, "")) }
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
                HStack(spacing: 4) {
                    ForEach(RunDetailModel.stages, id: \.self) { s in
                        Text(s).font(.caption2).padding(3)
                            .background(s == model.state ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08))
                    }
                }
                LabeledValue(label: "运行", value: model.runId)
                LabeledValue(label: "创建时间", value: Format.time(model.createdAt))
                LabeledValue(label: "模型尝试", value: "\(model.modelAttempts)")
                LabeledValue(label: "已确认动作", value: "\(model.confirmedActions)")
                LabeledValue(label: "决策步数", value: "\(model.stepCount)")
                LabeledValue(label: "完成验证", value: model.verification.status == "passed"
                             ? "通过（观察 \(model.verification.observationId ?? "—")，\(Format.time(model.verification.checkedAt))）"
                             : model.verification.status == "failed" ? "未满足" : "未执行")
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
