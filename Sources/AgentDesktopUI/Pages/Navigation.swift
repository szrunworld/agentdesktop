import Foundation

/// Second-level entries of Settings (docs/plan/06 §6.1).
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general = "通用"
    case permissions = "权限"
    case aiConnections = "AI 连接"
    case guiProfiles = "GUI 配置"
    case capabilityTest = "能力测试"
    case verification = "核实"
    case usage = "诊断与用量"

    public var id: String { rawValue }

    /// Delivery that fills an entry the host does not supply yet.
    public var delivery: String {
        switch self {
        case .verification: return "U9"
        default: return "U6"
        }
    }
}

/// Where the main window is: one first-level entry and, inside it, an
/// optional selected object. Only navigation; no Runtime state lives here.
@MainActor
public final class ShellNavigation: ObservableObject {
    @Published public var section: MainSection
    /// Desktops: nil shows the overview, an ID shows that Desktop's detail.
    @Published public var desktopId: String?
    /// Runs: nil shows the list, an ID shows that Run's detail.
    @Published public var runId: String?
    @Published public var settingsPage: SettingsPage
    /// Desktops: the side-by-side view (P07) instead of the overview.
    @Published public var sideBySide = false
    /// GUI Explorer: nil shows the history, an ID shows that Run's detail.
    @Published public var explorerRunId: String?
    /// GUI Explorer: open P27 with this Desktop preselected.
    @Published public var explorerDesktopId: String?

    public init(section: MainSection = .desktops, desktopId: String? = nil, runId: String? = nil,
                settingsPage: SettingsPage = .general) {
        self.section = section
        self.desktopId = desktopId
        self.runId = runId
        self.settingsPage = settingsPage
    }

    /// Choosing a first-level entry shows its top view.
    public func open(_ section: MainSection) {
        self.section = section
        switch section {
        case .desktops: desktopId = nil; sideBySide = false
        case .runs: runId = nil
        case .explorer: explorerRunId = nil; explorerDesktopId = nil
        default: break
        }
    }

    /// GUI Explorer: one Run's detail (from Runs, a Desktop, or a notice).
    public func showExplorerRun(_ id: String) {
        section = .explorer
        explorerDesktopId = nil
        explorerRunId = id
    }

    /// GUI Explorer: P27 for this Desktop (from its detail page).
    public func startExplorer(desktopId: String) {
        section = .explorer
        explorerRunId = nil
        explorerDesktopId = desktopId
    }

    public func showDesktop(_ id: String) {
        section = .desktops
        sideBySide = false
        desktopId = id
    }

    public func showRun(_ id: String) {
        section = .runs
        runId = id
    }

    public func back() {
        switch section {
        case .desktops: desktopId = nil
        case .runs: runId = nil
        case .explorer: explorerRunId = nil; explorerDesktopId = nil
        default: break
        }
    }
}
