import AgentDesktopProtocol
import SwiftUI

/// Component sheets laid out like Design v2.0 P01, P06, P19 and P21, for
/// visual review of U1a's tokens and components. They are not the U2, U5 or
/// U6 pages: they take contract objects as given and wire no actions.
public enum Specimen: String, CaseIterable, Sendable {
    case p01, p06, p19, p21

    public var designImage: String { rawValue.uppercased() + ".webp" }
}

/// One record row's data, from request.show plus its Run and Desktop.
public struct ActionRecordItem: Sendable {
    public let record: JSONValue
    public let desktopName: String
    public let caller: String

    public init(record: JSONValue, desktopName: String, caller: String) {
        self.record = record
        self.desktopName = desktopName
        self.caller = caller
    }
}

public struct OverviewSpecimen: View {
    let desktops: [JSONValue]
    let activeRuns: [JSONValue]

    public init(desktops: [JSONValue], activeRuns: [JSONValue]) {
        self.desktops = desktops
        self.activeRuns = activeRuns
    }

    public var body: some View {
        PageContainer(state: desktops.isEmpty ? .empty : .loaded, emptyTitle: "还没有 Desktop", header: {
            PageHeader(eyebrow: "Agent Desktop", title: "Desktops", subtitle: "每个 Agent 一个独立桌面，你继续使用自己的电脑。") {
                HStack(spacing: ADSpace.s) {
                    Button {} label: { Label("并排预览", systemImage: "square.grid.2x2") }.buttonStyle(ADButtonStyle(.secondary))
                    Button {} label: { Label("创建 Desktop", systemImage: "plus") }.buttonStyle(ADButtonStyle(.primary))
                }.disabled(true)
            }
        }) {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                HStack {
                    let running = desktops.filter { d in activeRuns.contains { $0["desktopId"] == d["desktopId"] } }.count
                    StateBadge("全部 \(desktops.count)", tone: .idle)
                    StateBadge("操作中 \(running)", tone: .running)
                    StateBadge("空闲 \(desktops.count - running)", tone: .idle)
                    Spacer()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ADSpace.l), count: 3), spacing: ADSpace.l) {
                    ForEach(desktops.indices, id: \.self) { i in
                        DesktopCard(desktop: desktops[i],
                                    control: DesktopControlPresentation.make(desktop: desktops[i], activeRuns: activeRuns))
                    }
                }
            }
        }
    }
}

public struct DesktopDetailSpecimen: View {
    let desktop: JSONValue
    let activeRuns: [JSONValue]
    let recent: [ActionRecordItem]

    public init(desktop: JSONValue, activeRuns: [JSONValue], recent: [ActionRecordItem]) {
        self.desktop = desktop
        self.activeRuns = activeRuns
        self.recent = recent
    }

    public var body: some View {
        let control = DesktopControlPresentation.make(desktop: desktop, activeRuns: activeRuns)
        return PageContainer(state: .loaded, header: {
            PageHeader(eyebrow: "Desktop / Preview", title: desktop["name"]?.stringValue ?? "—",
                       subtitle: "\(desktop["desktopId"]?.stringValue ?? "—") · \(desktop["binding"]?["appName"]?.stringValue ?? "没有绑定窗口")") {
                HStack(spacing: ADSpace.s) {
                    Button {} label: { Label("独立预览", systemImage: "rectangle.on.rectangle") }.buttonStyle(ADButtonStyle(.secondary))
                    Button {} label: { Label("停止输入", systemImage: "stop.fill") }.buttonStyle(ADButtonStyle(.danger))
                }.disabled(true)
            }
        }) {
            HStack(alignment: .top, spacing: ADSpace.xl) {
                VStack(alignment: .leading, spacing: ADSpace.l) {
                    ControllerBanner(control: control)
                    DesktopViewport(desktop: desktop).frame(height: 470).adPanel()
                        .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("最近动作").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink).padding(ADSpace.l)
                        ForEach(recent.indices, id: \.self) { i in row(recent[i]) }
                    }
                    .adPanel()
                }
                .frame(maxWidth: .infinity)
                ConnectionPanel(desktop: desktop, control: control).frame(width: 294)
            }
        }
    }

    func row(_ item: ActionRecordItem) -> some View {
        let p = ActionResultPresentation.make(record: item.record)
        return HStack {
            Text(TimeText.clock(item.record["acceptedAt"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
            Text(item.record["requestId"]?.stringValue ?? "—").font(ADFont.code).foregroundStyle(ADColor.muted)
            Spacer()
            StateBadge(p.status)
        }
        .padding(.horizontal, ADSpace.l).frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

public struct ActionRecordsSpecimen: View {
    let items: [ActionRecordItem]

    public init(items: [ActionRecordItem]) { self.items = items }

    public var body: some View {
        PageContainer(state: items.isEmpty ? .empty : .loaded, emptyTitle: "还没有动作记录", header: {
            PageHeader(eyebrow: "Activity / Receipts", title: "动作记录",
                       subtitle: "查看桌面执行事实与回执。这里不判断业务结果，也不代替测试断言。") {
                Button {} label: { Label("导出记录", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(true)
            }
        }) {
            VStack(alignment: .leading, spacing: ADSpace.m) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(ActionRecordRow.columns, id: \.0) { c in
                            Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, ADSpace.l).frame(height: 44)
                    .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
                    ForEach(items.indices, id: \.self) { i in
                        let r = items[i].record
                        let receipt = r["outcome"]?["error"]?["details"]?["receipt"] ?? r["outcome"]
                        ActionRecordRow(time: TimeText.clock(r["acceptedAt"]?.stringValue), desktopName: items[i].desktopName,
                                        caller: items[i].caller, action: r["method"]?.stringValue ?? "—",
                                        detail: receipt?["route"]?.stringValue.map { "route \($0)" } ?? "—",
                                        requestId: r["requestId"]?.stringValue ?? "—",
                                        presentation: ActionResultPresentation.make(record: r))
                    }
                }
                .adPanel()
                Text("「已执行，未验证」只表示输入已投递并完成，不表示目标窗口已变化；业务结果一律未评估。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            }
        }
    }
}

public struct GeneralSettingsSpecimen: View {
    @State private var keepRunning = true
    @State private var cursor = true
    @State private var login = false
    @State private var size = "1280 × 800"
    @State private var language = "简体中文"

    public init() {}

    public var body: some View {
        PageContainer(state: .loaded, header: {
            PageHeader(eyebrow: "Agent Desktop", title: "设置", subtitle: "管理本机偏好与必要权限。")
        }) {
            HStack(alignment: .top, spacing: ADSpace.xxl) {
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    ForEach(MainSection.settings.subviews, id: \.self) { s in
                        Text(s).font(s == "通用" ? ADFont.bodyStrong : ADFont.body)
                            .foregroundStyle(s == "通用" ? ADColor.primary : ADColor.ink)
                            .padding(.horizontal, ADSpace.m).frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(s == "通用" ? ADColor.selected : .clear))
                    }
                }
                .frame(width: 180)
                SettingsPanel(title: "通用") {
                    SettingsToggleRow(title: "关闭主窗口后继续运行", detail: "保留菜单栏入口，不停止正在工作的 Desktop。", isOn: $keepRunning)
                    SettingsToggleRow(title: "在预览中显示 Agent 光标", detail: "只影响画面显示，不改变输入路由。", isOn: $cursor)
                    SettingsToggleRow(title: "登录时启动 AgentDesktop", detail: "仅启动本机服务，不自动启动 Agent 或业务任务。", isOn: $login)
                    HStack(spacing: ADSpace.l) {
                        SettingsChoiceRow(title: "新 Desktop 默认尺寸", options: ["1280 × 800", "1440 × 900", "1920 × 1080"], selection: $size)
                        SettingsChoiceRow(title: "界面语言", options: ["简体中文"], selection: $language)
                    }
                    .padding(.top, ADSpace.xl)
                    Button("保存偏好") {}.buttonStyle(ADButtonStyle(.primary)).disabled(true).padding(.top, ADSpace.l)
                }
                .frame(maxWidth: 790)
            }
        }
    }
}
