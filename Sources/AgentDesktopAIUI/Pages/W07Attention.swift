import AgentDesktopContracts
import Foundation
import SwiftUI

/// W07 — 需要处理的运行. Shows what is known about an input whose outcome
/// is unknown. It offers no retry, no forced success, no forced release
/// and no resume: v1 has none, and only the Runtime's own reconciliation
/// can end the quarantine.
@MainActor
public final class AttentionModel: ObservableObject {
    public enum Branch: Equatable { case loading, unknownAction, cancelPending, invalidAction, needsUser(String), resolved(String) }

    public let detail: RunDetailModel
    @Published public private(set) var branch: Branch = .loading

    public init(client: ContractClient, runId: String, clock: PollClock = SystemPollClock()) {
        detail = RunDetailModel(client: client, runId: runId, clock: clock)
    }

    /// Only gui.runs.get / gui.runs.events. Never asks for a new observation.
    public func refreshEvidence() async {
        await detail.refresh()
        let unknown = detail.waitingReasonCode == ErrorCode.actionOutcomeUnknown.rawValue
            || detail.latestReceipt?.deliveryState == "unknown"
        switch detail.state {
        case "cancelling" where unknown: branch = .cancelPending
        case "waiting_user" where unknown: branch = .unknownAction
        case "waiting_user": branch = .needsUser(detail.waitingReasonCode ?? "")
        case "failed" where detail.errorCode == ErrorCode.invalidAction.rawValue && detail.confirmedActions == 0:
            branch = .invalidAction
        default: branch = detail.isTerminal ? .resolved(detail.state) : .loading
        }
    }

    public var headline: String {
        switch branch {
        case .unknownAction: return "有一项输入结果尚未确认"
        case .cancelPending: return "停止请求已收到；有一项输入结果尚未确认"
        case .invalidAction: return "模型建议的动作无效，没有动作被执行"
        case let .needsUser(code): return "运行在等待处理（\(code)）"
        case let .resolved(s): return s == "cancelled" ? "已停止，Runtime 已完成核对" : "运行已结束"
        case .loading: return "正在读取"
        }
    }

    public var explanation: String {
        switch branch {
        case .unknownAction, .cancelPending:
            return "不会自动重发上一次的点击、输入、按键或滚动。冲突域保持隔离，直到 Runtime 的安全复核给出结论。这里显示的证据可能是动作前的旧证据，不代表最新画面。"
        case .invalidAction:
            return "动作在执行前被拒绝（not_sent / rejected）。修正配置后可以新建运行。"
        default: return ""
        }
    }

    /// Whether the evidence came after the input or is the pre-action snapshot.
    public var evidenceFreshness: String {
        detail.latestReceipt?.confirmationObservationId != nil ? "动作后证据" : "动作前 / 旧证据"
    }

    /// A new run is possible only after the Runtime ended this one.
    public var canCreateNewRun: Bool {
        if case .resolved = branch { return true }
        return branch == .invalidAction
    }

    /// The only control besides reading: ask to stop. Accepted ≠ stopped.
    public func requestStop() async {
        await detail.stop()
        await refreshEvidence()
    }
}

public struct AttentionView: View {
    @ObservedObject var model: AttentionModel
    var onNewRun: () -> Void

    public init(model: AttentionModel, onNewRun: @escaping () -> Void = {}) {
        self.model = model
        self.onNewRun = onNewRun
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("需要处理的运行").font(.title2).bold().accessibilityAddTraits(.isHeader)
            Text(model.headline).font(.headline).accessibilityAddTraits(.updatesFrequently)
            Text(model.explanation).font(.callout)
            if let r = model.detail.latestReceipt {
                GroupBox("上一项动作") {
                    LabeledValue(label: "动作类型", value: r.actionType)
                    LabeledValue(label: "回执", value: r.deliveryText)
                    LabeledValue(label: "动作前快照", value: r.snapshotId)
                    LabeledValue(label: "提交时间", value: Format.time(r.startedAt))
                    LabeledValue(label: "证据", value: model.evidenceFreshness)
                    LabeledValue(label: "冲突域", value: model.canCreateNewRun ? "已释放" : "保持隔离")
                }
            }
            HStack {
                Button("读取最新证据") { Task { await model.refreshEvidence() } }
                Button("停止") { Task { await model.requestStop() } }.disabled(!model.detail.canStop)
                Button("创建新运行", action: onNewRun).disabled(!model.canCreateNewRun)
            }
            Spacer()
        }
        .padding()
        .task { await model.refreshEvidence() }
    }
}
