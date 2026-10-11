import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

/// Off-screen renders of the Agents page (U4) at 1440 × 1000, for comparison
/// with docs/design/v2/P09–P11 and Hub W01–W03. With
/// AGENTDESKTOP_UI_SNAPSHOTS=<dir> the PNGs go there (docs/acceptance/ui-c/);
/// otherwise to a temporary directory. Nothing is shown on screen. These are
/// component renders with the mock Runtime, not page acceptance.
@MainActor
@Suite("Agents renders (U4)", .serialized)
struct AgentsRenderTests {
    static let now = Date(timeIntervalSince1970: 1_791_446_400 + 60)

    static let outDir: URL = {
        if let d = ProcessInfo.processInfo.environment["AGENTDESKTOP_UI_SNAPSHOTS"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("agentdesktop-ui-c-\(getpid())", isDirectory: true)
    }()

    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000, "\(name) is \(rep.pixelsWide)×\(rep.pixelsHigh)")
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: Self.outDir.appendingPathComponent(name + ".png"))
    }

    func setup(_ m: MockRuntime) async -> (ShellStore, AgentsModel) {
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let model = AgentsModel(store: store, now: { Self.now })
        await model.load()
        return (store, model)
    }

    func page(_ store: ShellStore, _ model: AgentsModel, confirming: AgentsConfirmation? = nil,
              state: PageState = .loaded) -> some View {
        let nav = ShellNavigation(section: .agents)
        let context = SectionContext(store: store, navigation: nav, connectionState: state, retry: {})
        return MainFrame(selection: .constant(.agents), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                         counts: [.desktops: store.desktops.count, .runs: store.activeRuns.count],
                         statusLeft: "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中",
                         statusRight: "同步于 —", isSample: true) {
            AgentsPageView(context: context, model: model, confirming: confirming, autoload: false)
        }
    }

    /// The list with the mock's pairing requests, checked against the
    /// contract first (the base mock lists none; see the PR's coordination note).
    func withPairings(_ m: MockRuntime, _ model: AgentsModel) async throws {
        let list = try await m.call("hub.clients.list").setting("pairings", .array(m.agentsPairings))
        #expect(RuntimeContract.shared.validate(list, "HubClientList").isEmpty)
        model.apply(list: list, connections: nil, windowGrants: nil, grants: nil, problems: [:])
    }

    @Test func overviewW01() async throws {
        let m = MockRuntime.agentsSample()
        m.addPairing(agentName: "Draft Agent", capabilities: ["observe", "act"], desktops: ["desk_001"])
        let (store, model) = await setup(m)
        try await withPairings(m, model)
        try write("W01-agents-overview", page(store, model))
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func detailW03() async throws {
        let m = MockRuntime.agentsSample()
        let (store, model) = await setup(m)
        model.clientId = "app:mock-001"
        await model.loadDetail("app:mock-001")
        try write("W03-agent-detail", page(store, model))
        // The narrowing confirmation (二次确认) over the detail.
        let g = try #require(model.grant(of: "app:mock-001"))
        let intent = GrantNarrowing.Intent(keepCapabilities: ["observe"], keepDesktops: ["created"], keepApps: ["com.tencent.xinWeChat"],
                                           period: 3600 - 600, revision: g["revision"]?.intValue ?? -1)
        #expect(GrantNarrowing.params(clientId: "app:mock-001", grant: g, intent: intent, now: Self.now) != nil)
        try write("W03-narrow-confirm", page(store, model, confirming: .narrowGrant("app:mock-001", intent)))
        try write("W03-revoke-client-confirm", page(store, model, confirming: .revokeClient("app:mock-001")))
        // After the removal: 已受理, the facts, and the HB-UI-04 banner.
        await model.revokeClient("app:mock-001")
        try write("W03-after-revoke", page(store, model))
        #expect(m.contractViolations.isEmpty, "\(m.contractViolations)")
    }

    @Test func connectP09toP11() async throws {
        let m = MockRuntime.agentsSample()
        m.addPairing(agentName: "Draft Agent", capabilities: ["observe", "act"], desktops: ["desk_001"])
        let (store, model) = await setup(m)
        try await withPairings(m, model)
        model.tab = .connect
        model.channel = .cli
        try write("P09-connect-cli", page(store, model))
        model.channel = .mcp
        try write("P10-connect-mcp", page(store, model))
        model.channel = .acp
        await model.checkConnection(desktopId: "desk_001")
        try write("P11-connect-acp", page(store, model))
        // UC24: the read-only check's visible result (below the fold above).
        let check = try #require(model.check)
        try write("P09-P11-check-result", VStack(alignment: .leading) { AgentsCheckResult(check: check).frame(width: 900) }
            .padding(ADLayout.contentPadding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ADColor.canvas))
    }

    @Test func statesEmptyAndDisconnected() async throws {
        let empty = MockRuntime()
        let (estore, emodel) = await setup(empty)
        try write("agents-empty", page(estore, emodel, state: .loaded))
        let m = MockRuntime.agentsSample()
        let (store, model) = await setup(m)
        m.offline = true
        await store.refreshStatus()
        await model.load()
        let p = RuntimeProblem(code: "runtime_offline", title: RuntimeProblem.text("runtime_offline").0,
                               advice: RuntimeProblem.text("runtime_offline").1)
        try write("agents-disconnected", page(store, model, state: .disconnected(p)))
    }
}
