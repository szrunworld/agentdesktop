import AgentDesktopProtocol
import SwiftUI

/// One action's receipt as a card (P20): the result level per §6.4, the
/// three locating IDs, and the business result that the platform never
/// evaluates. No retry button exists for any level.
public struct ActionReceiptView: View {
    let receipt: JSONValue?
    let requestId: String
    let presentation: ActionResultPresentation
    let export: (() -> Void)?

    public init(receipt: JSONValue?, requestId: String, errorCode: String? = nil, export: (() -> Void)? = nil) {
        self.receipt = receipt
        self.requestId = requestId
        self.presentation = ActionResultPresentation.make(receipt: receipt, errorCode: errorCode)
        self.export = export
    }

    /// From a RequestRecord (request.show).
    public init(record: JSONValue, export: (() -> Void)? = nil) {
        let p = ActionResultPresentation.make(record: record)
        let outcome = record["outcome"]
        self.receipt = outcome?["error"]?["details"]?["receipt"] ?? outcome.flatMap(ActionResultPresentation.receipt(inSuccess:))
        self.requestId = record["requestId"]?.stringValue ?? "—"
        self.presentation = p
        self.export = export
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack(spacing: ADSpace.m) {
                StateBadge(presentation.status)
                if let reason = presentation.reasonText {
                    Text(reason).font(ADFont.note).foregroundStyle(ADColor.ink)
                }
                Spacer()
                if let export {
                    Button("导出回执", action: export).buttonStyle(ADButtonStyle(.secondary))
                }
            }
            LabeledValue(label: "desktopId", value: receipt?["desktopId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "requestId", value: requestId, monospaced: true, labelWidth: 100)
            LabeledValue(label: "画面 ID", value: receipt?["snapshotId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "投递", value: Self.deliveryText(receipt?["delivery"]?.stringValue), labelWidth: 100)
            LabeledValue(label: "执行", value: Self.executionText(receipt?["execution"]?.stringValue), labelWidth: 100)
            LabeledValue(label: "验证", value: "未请求（平台不判断目标是否变化）", labelWidth: 100)
            Text(presentation.businessResult).font(ADFont.noteStrong).foregroundStyle(ADColor.muted)
            if presentation.needsReconciliation {
                Text("输入可能已到达应用。不会自动重发；只能重新观察并核实，原记录保持「结果未知」。")
                    .font(ADFont.note).foregroundStyle(StatusTone.attention.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ADSpace.l)
        .adPanel()
    }

    static func deliveryText(_ v: String?) -> String {
        switch v {
        case "dispatched": return "已投递（dispatched）"
        case "not_dispatched": return "未发出（not_dispatched）"
        case "unknown": return "未知（unknown）"
        default: return "尚无回执"
        }
    }

    static func executionText(_ v: String?) -> String {
        switch v {
        case "completed": return "已完成（completed）"
        case "failed": return "失败（failed）"
        case "unknown": return "未知（unknown）"
        default: return "尚无回执"
        }
    }
}

/// One line of the action record list (P19).
public struct ActionRecordRow: View {
    let time: String
    let desktopName: String
    let caller: String
    let action: String
    let detail: String
    let requestId: String
    let presentation: ActionResultPresentation
    let open: (() -> Void)?

    public init(time: String, desktopName: String, caller: String, action: String, detail: String,
                requestId: String, presentation: ActionResultPresentation, open: (() -> Void)? = nil) {
        self.time = time
        self.desktopName = desktopName
        self.caller = caller
        self.action = action
        self.detail = detail
        self.requestId = requestId
        self.presentation = presentation
        self.open = open
    }

    public static let columns: [(String, CGFloat)] = [("时间", 150), ("Desktop / 调用者", 210), ("动作", 230),
                                                      ("请求", 160), ("结果", 160)]

    public var body: some View {
        HStack(spacing: 0) {
            Text(time).font(ADFont.code).foregroundStyle(ADColor.ink).frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(desktopName).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text(caller).font(ADFont.note).foregroundStyle(ADColor.muted)
            }.frame(width: 210, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(action).font(ADFont.note).foregroundStyle(ADColor.ink)
                Text(detail).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 230, alignment: .leading)
            Text(requestId).font(ADFont.code).foregroundStyle(ADColor.ink).frame(width: 160, alignment: .leading)
            StateBadge(presentation.status).frame(width: 160, alignment: .leading)
            Spacer()
            Button { open?() } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary)).disabled(open == nil)
        }
        .padding(.horizontal, ADSpace.l)
        .frame(minHeight: 70)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}
