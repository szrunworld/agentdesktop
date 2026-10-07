import AgentDesktopContracts
import SwiftUI

/// The eight AI/GUI pages behind one sidebar, ready to be placed in the
/// main window. Navigation between pages follows spec §1: test from a
/// connection or profile, start a run from a profile, open details after
/// start, and the attention page from details.
public struct AIGUIRootView: View {
    public enum Page: String, CaseIterable, Identifiable {
        case connections = "AI 连接"
        case editor = "添加 / 编辑 AI 连接"
        case profiles = "GUI 配置"
        case test = "连接与能力测试"
        case start = "启动 GUI 诊断运行"
        case detail = "运行详情"
        case attention = "需要处理的运行"
        case usage = "用量与诊断"
        public var id: String { rawValue }
    }

    let client: ContractClient
    let allowFixtureAdapter: Bool
    @State private var page: Page? = .connections
    @StateObject private var connections: ConnectionsModel
    @StateObject private var profiles: ProfilesModel
    @StateObject private var usage: UsageModel
    @State private var editor: ConnectionEditorModel?
    @State private var test: CapabilityTestModel?
    @State private var start: RunStartModel?
    @State private var detail: RunDetailModel?
    @State private var attention: AttentionModel?

    public init(client: ContractClient, allowFixtureAdapter: Bool = false) {
        self.client = client
        self.allowFixtureAdapter = allowFixtureAdapter
        _connections = StateObject(wrappedValue: ConnectionsModel(client: client))
        _profiles = StateObject(wrappedValue: ProfilesModel(client: client, allowFixtureAdapter: allowFixtureAdapter))
        _usage = StateObject(wrappedValue: UsageModel(client: client))
    }

    public var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { p in Text(p.rawValue).tag(p) }
                .navigationTitle("AI 与 GUI")
        } detail: {
            switch page ?? .connections {
            case .connections:
                ConnectionsView(model: connections,
                                onAdd: { editor = ConnectionEditorModel(client: client, mode: .create); page = .editor },
                                onEdit: { id in editor = ConnectionEditorModel(client: client, mode: .edit(id)); page = .editor },
                                onTest: { _ in test = CapabilityTestModel(client: client); page = .test })
            case .editor:
                ConnectionEditorView(model: editor ?? ConnectionEditorModel(client: client, mode: .create),
                                     onTest: { _ in test = CapabilityTestModel(client: client); page = .test })
            case .profiles:
                ProfilesView(model: profiles,
                             onTest: { id in test = CapabilityTestModel(client: client, guiProfileId: id); page = .test },
                             onRun: { id in start = RunStartModel(client: client, guiProfileId: id); page = .start })
            case .test:
                CapabilityTestView(model: test ?? CapabilityTestModel(client: client))
            case .start:
                RunStartView(model: start ?? RunStartModel(client: client),
                             onStarted: { id in detail = RunDetailModel(client: client, runId: id); page = .detail })
            case .detail:
                if let detail {
                    RunDetailView(model: detail, onAttention: { id in attention = AttentionModel(client: client, runId: id); page = .attention })
                } else {
                    EmptyState(title: "没有选中的运行", detail: "从“启动 GUI 诊断运行”开始一次运行。", action: nil)
                }
            case .attention:
                if let attention {
                    AttentionView(model: attention, onNewRun: { start = RunStartModel(client: client); page = .start })
                } else {
                    EmptyState(title: "没有需要处理的运行", detail: "运行进入等待处理时会出现在这里。", action: nil)
                }
            case .usage:
                UsageView(model: usage)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
