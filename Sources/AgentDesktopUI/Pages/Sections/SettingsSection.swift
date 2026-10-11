import AgentDesktopProtocol
import SwiftUI

/// The Settings entry as the main window shows it.
struct SettingsSection: View {
    let context: SectionContext
    let content: (SettingsPage) -> AnyView?

    var body: some View {
        SettingsPageView(store: context.store, navigation: context.navigation, content: content)
    }
}

/// The models behind the Settings pages, kept while the window lives so a
/// running capability test or a draft survives switching entries.
@MainActor
final class SettingsModels: ObservableObject {
    let runtime: RuntimePort
    let preferences: SettingsPreferences
    let permissions: SettingsPermissionsModel
    let connections: SettingsConnectionsModel
    let profiles: SettingsProfilesModel
    let test: SettingsCapabilityTestModel
    let usage: SettingsUsageModel
    /// The last `runtime.capabilities` this page read itself. The Store
    /// reads them once per connection; the AI service registers its
    /// methods later, so Settings reads them again when an entry opens.
    @Published private(set) var capabilities: JSONValue?

    init(store: ShellStore, preferences: SettingsPreferences? = nil, clock: PollClock = SystemPollClock()) {
        runtime = store.runtime
        self.preferences = preferences ?? SettingsPreferences()
        permissions = SettingsPermissionsModel(runtime: store.runtime, capabilities: store.capabilities)
        connections = SettingsConnectionsModel(runtime: store.runtime)
        profiles = SettingsProfilesModel(runtime: store.runtime, gui: store.capabilities?["gui"])
        test = SettingsCapabilityTestModel(runtime: store.runtime, clock: clock)
        usage = SettingsUsageModel(runtime: store.runtime)
        capabilities = store.capabilities
    }

    func apply(_ caps: JSONValue) {
        capabilities = caps
        permissions.apply(caps)
        profiles.gui = caps["gui"]
    }

    /// Reads `runtime.capabilities` again; a failure keeps the last answer.
    func refreshCapabilities() async {
        if let caps = try? await runtime.call("runtime.capabilities") { apply(caps) }
    }

    func offers(_ method: String) -> Bool {
        capabilities?["interface"]?["methods"]?.arrayValue?.contains { $0["method"]?.stringValue == method } ?? false
    }
}

/// Settings (U6): the page header, the second-level list on the left and
/// the selected entry on the right (P21 layout). Owned by lane UI-D
/// (docs/plan/11-parallel-lanes.md); only that lane edits this file.
///
/// - 通用 (P21): local preferences.
/// - 权限 (P02/P22): states from `runtime.capabilities`; nothing is requested.
/// - AI 连接, GUI 配置, 能力测试, 诊断与用量 (P23–P26, P30): `ai.*` over
///   runtime/1, offered only when `runtime.capabilities` lists them.
/// - 核实 (U9): not yet.
///
/// `content` lets a host put its own page in an entry; nil keeps the page
/// here.
public struct SettingsPageView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var models: SettingsModels
    let content: (SettingsPage) -> AnyView?
    let openSystemSettings: (SettingsPermission) -> Void

    @State private var editor: SettingsConnectionEditorModel?
    @State private var confirmation: SettingsConfirmation?

    public init(store: ShellStore, navigation: ShellNavigation,
                preferences: SettingsPreferences? = nil,
                openSystemSettings: @escaping (SettingsPermission) -> Void = SettingsPermission.openInSystemSettings,
                content: @escaping (SettingsPage) -> AnyView? = { _ in nil }) {
        self.init(store: store, navigation: navigation,
                  models: SettingsModels(store: store, preferences: preferences),
                  openSystemSettings: openSystemSettings, content: content)
    }

    init(store: ShellStore, navigation: ShellNavigation, models: @autoclosure @escaping () -> SettingsModels,
         openSystemSettings: @escaping (SettingsPermission) -> Void, content: @escaping (SettingsPage) -> AnyView?) {
        self.store = store
        self.navigation = navigation
        _models = StateObject(wrappedValue: models())
        self.openSystemSettings = openSystemSettings
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xl) {
            PageHeader(eyebrow: "Agent Desktop", title: "设置", subtitle: "管理本机偏好、必要权限与内置 GUI 诊断的 AI 配置。") {
                if store.isSample { SampleMark() }
            }
            HStack(alignment: .top, spacing: ADSpace.xxl) {
                subnav
                ScrollView {
                    entry.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(ADLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ADColor.canvas)
        .overlay { overlays }
        .onChange(of: store.capabilities) { _, caps in
            if let caps { models.apply(caps) }
        }
        .task(id: navigation.settingsPage) {
            if connected { await models.refreshCapabilities() }
        }
    }

    var subnav: some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            ForEach(SettingsPage.allCases) { p in
                let on = navigation.settingsPage == p
                Button { navigation.settingsPage = p } label: {
                    Text(p.rawValue).font(on ? ADFont.bodyStrong : ADFont.body)
                        .foregroundStyle(on ? ADColor.primary : ADColor.ink)
                        .padding(.horizontal, ADSpace.m).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(on ? ADColor.selected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(width: 180)
    }

    var connected: Bool {
        if case .connected = store.connection { return true }
        return false
    }

    /// The AI entries need the AI service, which the Runtime advertises.
    var aiOffered: Bool { models.offers("ai.connections.list") || store.offers("ai.connections.list") }

    @ViewBuilder
    var entry: some View {
        let page = navigation.settingsPage
        if let view = content(page) {
            view
        } else {
            switch page {
            case .general:
                SettingsGeneralPage(preferences: models.preferences)
            case .permissions:
                SettingsPermissionsPage(model: models.permissions, connected: connected, open: openSystemSettings)
            case .verification:
                notEnabled
            case .aiConnections, .guiProfiles, .capabilityTest, .usage:
                if !aiOffered {
                    aiUnavailable
                } else {
                    aiEntry(page)
                }
            }
        }
    }

    @ViewBuilder
    func aiEntry(_ page: SettingsPage) -> some View {
        switch page {
        case .aiConnections:
            SettingsConnectionsPage(
                model: models.connections,
                onAdd: { editor = SettingsConnectionEditorModel(runtime: store.runtime, mode: .create) },
                onEdit: { c in editor = SettingsConnectionEditorModel(runtime: store.runtime, mode: .edit(c.id)) },
                onTest: { c in
                    // Resolved from a fresh read when the test entry opens,
                    // never from a list that may not be loaded yet.
                    models.test.pendingConnectionId = c.id
                    navigation.settingsPage = .capabilityTest
                },
                confirm: { confirmation = $0 })
        case .guiProfiles:
            SettingsProfilesPage(
                model: models.profiles,
                onTest: { p in
                    models.test.pendingConnectionId = nil
                    models.test.guiProfileId = p.id
                    navigation.settingsPage = .capabilityTest
                },
                onDiagnose: { navigation.open(.explorer) },
                onConnections: { navigation.settingsPage = .aiConnections },
                confirm: { confirmation = $0 })
        case .capabilityTest:
            SettingsCapabilityTestPage(model: models.test, onDiagnose: { navigation.open(.explorer) })
        default:
            SettingsUsagePage(model: models.usage, onRuns: { navigation.open(.runs) })
        }
    }

    var aiUnavailable: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            StateBadge(models.capabilities == nil ? StatusText("正在读取 Runtime 能力", .idle) : StatusText("AI 服务未运行", .attention))
            Text(models.capabilities == nil ? "等待 Runtime 报告能力。" : "这个 Runtime 没有提供 AI 连接与 GUI 配置")
                .font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text("这些页面只在 runtime.capabilities 列出 ai.* 方法时可用。直接 API、CLI / MCP 与确定性回放不需要 AI 连接，不受影响。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(ADSpace.xl).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    var notEnabled: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            StateBadge("尚未启用", tone: .idle)
            Text("尚未启用：结果未知动作的核实将在后续版本提供").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text("核实只追加记录，原结果保持「结果未知」，不会重发动作。").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.xl).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    @ViewBuilder
    var overlays: some View {
        if let editor {
            SettingsConnectionDrawer(model: editor, close: { self.editor = nil }, saved: {
                self.editor = nil
                Task { await models.connections.refresh(); await models.profiles.refresh() }
            })
        } else if let c = confirmation {
            SettingsModal {
                ConfirmationDialog(title: c.title, message: c.message, consequences: c.consequences, preserved: c.preserved,
                                   confirmTitle: c.confirmTitle, destructive: true,
                                   cancel: { confirmation = nil },
                                   confirm: { confirmation = nil; Task { await perform(c) } })
            }
        }
    }

    /// Runs a confirmed delete or disable.
    func perform(_ c: SettingsConfirmation) async {
        switch c.action {
        case .disableConnection:
            if let item = models.connections.connections.first(where: { $0.id == c.id }) { await models.connections.disable(item) }
        case .deleteConnection:
            if let item = models.connections.connections.first(where: { $0.id == c.id }) { await models.connections.delete(item) }
        case .disableProfile:
            if let item = models.profiles.profiles.first(where: { $0.id == c.id }) { await models.profiles.disable(item) }
        case .deleteProfile:
            if let item = models.profiles.profiles.first(where: { $0.id == c.id }) { await models.profiles.delete(item) }
        }
    }
}
