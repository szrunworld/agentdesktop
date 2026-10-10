import AgentDesktopProtocol
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentDesktopUI

/// Off-screen renders at 1440 × 1000. With AGENTDESKTOP_UI_SNAPSHOTS=<dir>
/// the PNGs are written there (docs/acceptance/ui-u1a/ for the PR);
/// otherwise to a temporary directory. Nothing is shown on screen.
@MainActor
@Suite("Off-screen renders", .serialized)
struct RenderTests {
    static let outDir: URL = {
        if let d = ProcessInfo.processInfo.environment["AGENTDESKTOP_UI_SNAPSHOTS"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("agentdesktop-ui-\(getpid())", isDirectory: true)
    }()

    func write<V: View>(_ name: String, _ view: V) throws {
        let png = try #require(SnapshotRenderer.png(view), "render \(name)")
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1000, "\(name) is \(rep.pixelsWide)×\(rep.pixelsHigh)")
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try png.write(to: Self.outDir.appendingPathComponent(name + ".png"))
    }

    func frame<V: View>(_ section: MainSection, store: ShellStore, @ViewBuilder _ page: () -> V) -> some View {
        MainFrame(selection: .constant(section), runtime: StatusText("本机服务就绪", .running), stopAll: {},
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]!.stringValue!, name: d["name"]!.stringValue!,
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: [.desktops: store.desktops.count],
                  statusLeft: "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中",
                  statusRight: "运行状态：事件订阅", isSample: true, page: page)
    }

    func records(_ m: MockRuntime, _ store: ShellStore) async throws -> [ActionRecordItem] {
        var out: [ActionRecordItem] = []
        for run in store.runs {
            let events = try await m.call("run.events", .obj([("runId", run["runId"]!)]))["events"]!.arrayValue!
            for e in events where e["type"]?.stringValue == "action.accepted" {
                let record = try await m.call("request.show", .obj([("requestId", e["data"]!["requestId"]!)]))
                let name = store.desktops.first { $0["desktopId"] == run["desktopId"] }?["name"]?.stringValue ?? "—"
                out.append(ActionRecordItem(record: record, desktopName: name, caller: run["clientId"]?.stringValue ?? "—"))
            }
        }
        return out.sorted { ($0.record["acceptedAt"]?.stringValue ?? "") > ($1.record["acceptedAt"]?.stringValue ?? "") }
    }

    @Test func specimensAgainstDesign() async throws {
        let m = MockRuntime.sample()
        let accepted = m.addAcceptedRequest()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        var items = try await records(m, store)
        let pending = try await m.call("request.show", .obj([("requestId", .string(accepted))]))
        items.insert(ActionRecordItem(record: pending, desktopName: "Web 表单验证", caller: "local:501"), at: 0)

        try write("P01-desktops-overview", frame(.desktops, store: store) {
            OverviewSpecimen(desktops: store.desktops, activeRuns: store.activeRuns)
        })
        let first = store.desktops[0]
        try write("P06-desktop-detail", frame(.desktops, store: store) {
            DesktopDetailSpecimen(desktop: first, activeRuns: store.activeRuns,
                                  recent: items.filter { $0.desktopName == first["name"]?.stringValue })
        })
        try write("P19-action-records", frame(.runs, store: store) { ActionRecordsSpecimen(items: items) })
        try write("P21-settings-general", frame(.settings, store: store) { GeneralSettingsSpecimen() })
    }

    @Test func inboxAtDifferentWindowSizes() throws {
        for size in [CGSize(width: 1920, height: 1000),
                     CGSize(width: 1440, height: 1000),
                     CGSize(width: 800, height: 600)] {
            let page = MainFrame(selection: .constant(.inbox),
                                 runtime: StatusText("本机服务就绪", .running), stopAll: {},
                                 statusLeft: "0 个 Desktop · 0 个运行进行中", statusRight: "",
                                 isSample: false) { InboxNotEnabledView() }
            let png = try #require(SnapshotRenderer.png(page, size: size))
            let rep = try #require(NSBitmapImageRep(data: png))
            #expect(rep.pixelsWide == Int(size.width))
            #expect(rep.pixelsHigh == Int(size.height))
            try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
            try png.write(to: Self.outDir.appendingPathComponent("inbox-\(Int(size.width))x\(Int(size.height)).png"))
        }
    }

    @Test func shellStatesAndInbox() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock())
        try write("state-loading", MainWindowView(store: store))
        await store.start()
        store.stop()
        try write("shell-desktops-loaded", MainWindowView(store: store))
        try write("shell-inbox-not-enabled", MainWindowView(store: store, initial: .inbox))

        let empty = ShellStore(runtime: MockRuntime(), clock: StillClock())
        await empty.start()
        empty.stop()
        try write("state-empty", MainWindowView(store: empty))

        m.failNext("desktop.list", code: "internal_error")
        await store.refreshDesktops()
        try write("state-error", MainWindowView(store: store))

        let off = MockRuntime()
        off.offline = true
        let offStore = ShellStore(runtime: off, clock: StillClock())
        await offStore.start()
        try write("state-disconnected", MainWindowView(store: offStore))
    }

    // U1b-1: the wired Runs and Desktop detail pages with actions in every
    // delivery state (the real test copy had no bound window to act on).
    @Test func mockPagesWithActions() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock(), allowSubscription: false)
        await store.start()
        store.stop()
        let run = store.runs.first { $0["desktopId"]?.stringValue == "desk_001" && $0["phase"]?.stringValue == "running" }!
        let runNav = ShellNavigation(section: .runs, runId: run["runId"]!.stringValue!)
        let loader = RunDetailLoader(runtime: m, runId: runNav.runId!)
        await loader.load()
        try write("mock-run-detail-with-receipts", frame(.runs, store: store) {
            RunInspectorView(store: store, navigation: runNav, loader: loader)
        })
        let deskNav = ShellNavigation(section: .desktops, desktopId: "desk_002")
        let activity = DesktopActivityLoader(runtime: m, desktopId: "desk_002")
        await activity.load(runs: store.runs)
        try write("mock-desktop-detail-with-actions", frame(.desktops, store: store) {
            DesktopInspectorView(store: store, navigation: deskNav, activity: activity)
        })
    }

    @Test func componentSheet() throws {
        let r1 = receipt("dispatched", "completed"), r2 = receipt("not_dispatched", "failed"), r3 = receipt("unknown", "unknown")
        var name = "本机模型", url = "http://10.0.0.2/v1", key = "", model = "", timeout = 30000
        let sheet = ScrollView {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                HStack {
                    ForEach(StatusTone.allCases, id: \.self) { StateBadge($0.rawValue, tone: $0) }
                    SampleMark()
                }
                HStack(alignment: .top, spacing: ADSpace.l) {
                    ActionReceiptView(receipt: r1, requestId: "req_001")
                    ActionReceiptView(receipt: r2, requestId: "req_002", errorCode: "target_moved")
                    ActionReceiptView(receipt: r3, requestId: "req_003")
                    ActionReceiptView(receipt: nil, requestId: "req_004")
                }
                HStack(alignment: .top, spacing: ADSpace.l) {
                    ConfirmationDialog(title: "关闭 Desktop「计算器」？", message: "关闭前先停止输入，再按顺序释放资源。",
                                       consequences: ["结束本 Desktop 上的运行", "释放预览与专属资源"],
                                       preserved: ["其他 Desktop 继续运行", "宿主共享应用不被结束", "运行与动作记录保留"],
                                       confirmTitle: "停止并关闭", destructive: true, cancel: {}, confirm: {})
                    ProviderForm(name: Binding(get: { name }, set: { name = $0 }), baseUrl: Binding(get: { url }, set: { url = $0 }),
                                 secret: Binding(get: { key }, set: { key = $0 }), modelId: Binding(get: { model }, set: { model = $0 }),
                                 timeoutMs: Binding(get: { timeout }, set: { timeout = $0 }),
                                 fieldErrors: ["baseUrl": ProviderEndpointRule.error(url, allowLocalHTTP: true)!, "modelId": "需要填写模型 ID"],
                                 submit: nil)
                    .frame(width: 420)
                }
                CodeBox(title: "MCP 配置（示例，限定 desktopId）",
                        code: #"{"mcpServers":{"agentdesktop":{"command":"agentdesktop","args":["mcp","--desktop-id","desk_001"]}}}"#,
                        json: true)
            }
            .padding(ADLayout.contentPadding)
        }
        .background(ADColor.canvas)
        try write("components-sheet", sheet)
    }
}
