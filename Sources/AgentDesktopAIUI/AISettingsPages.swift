import AgentDesktopProtocol
import AgentDesktopUI
import SwiftUI

/// The AI/GUI pages inside the main window's Settings (D32, integration
/// design T27): no sidebar or window of their own. Each Settings entry
/// shows one page; follow-on pages (editing a connection, starting a GUI
/// diagnostic run, its detail and attention) open within the same entry,
/// with a way back. The pages keep their contract v1 client until U6 moves
/// them to runtime/1.
@MainActor
public final class AISettingsModel: ObservableObject {
    /// A follow-on page shown in place of an entry's top page.
    public enum Drill: Equatable {
        case editor, start, detail, attention
    }

    let client: ContractClient
    let allowFixtureAdapter: Bool
    let connections: ConnectionsModel
    let profiles: ProfilesModel
    let usage: UsageModel
    @Published var drill: [SettingsPage: Drill] = [:]
    var editor: ConnectionEditorModel?
    var test: CapabilityTestModel
    var start: RunStartModel?
    var detail: RunDetailModel?
    var attention: AttentionModel?

    public init(client: ContractClient, allowFixtureAdapter: Bool = false) {
        self.client = client
        self.allowFixtureAdapter = allowFixtureAdapter
        connections = ConnectionsModel(client: client)
        profiles = ProfilesModel(client: client, allowFixtureAdapter: allowFixtureAdapter)
        usage = UsageModel(client: client)
        test = CapabilityTestModel(client: client)
    }

    /// The Settings entries these pages fill.
    public static let entries: Set<SettingsPage> = [.aiConnections, .guiProfiles, .capabilityTest, .usage]

    /// The page for one Settings entry, or nil when it is not an AI entry.
    public func view(for page: SettingsPage, navigation: ShellNavigation) -> AnyView? {
        guard Self.entries.contains(page) else { return nil }
        return AnyView(AISettingsEntryView(model: self, page: page, navigation: navigation))
    }

    public func drill(of page: SettingsPage) -> Drill? { drill[page] }
}

struct AISettingsEntryView: View {
    @ObservedObject var model: AISettingsModel
    let page: SettingsPage
    @ObservedObject var navigation: ShellNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            if model.drill[page] != nil {
                Button { model.drill[page] = nil } label: { Label("返回\(page.rawValue)", systemImage: "chevron.left") }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
            content
        }
        .padding(ADLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    var content: some View {
        let c = model.client
        switch (page, model.drill[page]) {
        case (.aiConnections, .editor?):
            ConnectionEditorView(model: model.editor ?? ConnectionEditorModel(client: c, mode: .create),
                                 onTest: { _ in openTest() })
        case (.aiConnections, _):
            ConnectionsView(model: model.connections,
                            onAdd: { model.editor = ConnectionEditorModel(client: c, mode: .create); model.drill[.aiConnections] = .editor },
                            onEdit: { id in model.editor = ConnectionEditorModel(client: c, mode: .edit(id)); model.drill[.aiConnections] = .editor },
                            onTest: { _ in openTest() })
        case (.guiProfiles, .start?):
            RunStartView(model: model.start ?? RunStartModel(client: c),
                         onStarted: { id in model.detail = RunDetailModel(client: c, runId: id); model.drill[.guiProfiles] = .detail })
        case (.guiProfiles, .detail?):
            if let d = model.detail {
                RunDetailView(model: d, onAttention: { id in
                    model.attention = AttentionModel(client: c, runId: id); model.drill[.guiProfiles] = .attention
                })
            }
        case (.guiProfiles, .attention?):
            if let a = model.attention {
                AttentionView(model: a, onNewRun: { model.start = RunStartModel(client: c); model.drill[.guiProfiles] = .start })
            }
        case (.guiProfiles, _):
            ProfilesView(model: model.profiles,
                         onTest: { id in model.test = CapabilityTestModel(client: c, guiProfileId: id); navigation.settingsPage = .capabilityTest },
                         onRun: { id in model.start = RunStartModel(client: c, guiProfileId: id); model.drill[.guiProfiles] = .start })
        case (.capabilityTest, _):
            CapabilityTestView(model: model.test).id(ObjectIdentifier(model.test))
        case (.usage, _):
            UsageView(model: model.usage)
        default:
            EmptyView()
        }
    }

    func openTest() {
        model.test = CapabilityTestModel(client: model.client)
        navigation.settingsPage = .capabilityTest
    }
}
