import AgentDesktopProtocol
import SwiftUI

/// Where a Desktop's picture goes. U1a draws a placeholder only: no
/// ScreenCaptureKit stream (U2), no observation image. It says so on the
/// picture, so a placeholder is never mistaken for the target app.
public struct DesktopViewport: View {
    let sizeText: String
    let appName: String?
    let note: String

    public init(sizeText: String, appName: String?, note: String = "画面占位 · 未接实时预览") {
        self.sizeText = sizeText
        self.appName = appName
        self.note = note
    }

    public init(desktop: JSONValue) {
        self.init(sizeText: DesktopControlPresentation.sizeText(desktop),
                  appName: desktop["binding"]?["appName"]?.stringValue)
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(ADColor.canvas)
            VStack(spacing: ADSpace.s) {
                Image(systemName: appName == nil ? "rectangle.dashed" : "macwindow")
                    .font(.system(size: 30)).foregroundStyle(ADColor.muted.opacity(0.7))
                Text(appName.map { "绑定窗口：\($0)" } ?? "空 Desktop · 没有绑定窗口")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            VStack {
                Spacer()
                HStack {
                    Text("\(sizeText) · 独立输入").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ADColor.panel))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ADColor.line))
                    Spacer()
                    Text(note).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                }
                .padding(ADSpace.s)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("画面占位，\(appName ?? "没有绑定窗口")，\(sizeText)")
    }
}

/// A Desktop in the overview (P01): name and desktopId, picture, control
/// state, controller, action count and two actions.
public struct DesktopCard: View {
    let desktop: JSONValue
    let control: DesktopControlPresentation
    let openPreview: (() -> Void)?
    let stop: (() -> Void)?
    let openDetail: (() -> Void)?
    let picture: AnyView?
    let stopUnavailable: String?

    public init(desktop: JSONValue, control: DesktopControlPresentation,
                openPreview: (() -> Void)? = nil, stop: (() -> Void)? = nil, openDetail: (() -> Void)? = nil,
                picture: AnyView? = nil, stopUnavailable: String? = nil) {
        self.desktop = desktop
        self.control = control
        self.openPreview = openPreview
        self.stop = stop
        self.openDetail = openDetail
        self.picture = picture
        self.stopUnavailable = stopUnavailable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ADSpace.m) {
                Image(systemName: "macwindow").foregroundStyle(ADColor.primary)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 8).fill(ADColor.selected))
                VStack(alignment: .leading, spacing: 2) {
                    Text(desktop["name"]?.stringValue ?? "—").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                    Text(desktop["desktopId"]?.stringValue ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                }
                Spacer()
                if let openDetail {
                    Button(action: openDetail) { Label("详情", systemImage: "chevron.right") }
                        .buttonStyle(ADButtonStyle(.quiet))
                        .accessibilityLabel("打开 \(desktop["name"]?.stringValue ?? "Desktop") 的详情")
                }
            }
            .padding(ADSpace.l)
            Group {
                if let picture { picture } else { DesktopViewport(desktop: desktop) }
            }
            .frame(height: 210).clipped()
                .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
            VStack(alignment: .leading, spacing: ADSpace.m) {
                HStack {
                    StateBadge(control.status)
                    Spacer()
                    Text(control.source).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                }
                HStack {
                    Text(control.controller).font(ADFont.note).foregroundStyle(ADColor.ink)
                    Spacer()
                    Text(control.actionCount.map { "\($0) 次动作" } ?? "—").font(ADFont.note).foregroundStyle(ADColor.ink)
                }
                HStack(spacing: ADSpace.s) {
                    Button { openPreview?() } label: { Label("打开预览", systemImage: "eye").frame(maxWidth: .infinity) }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(openPreview == nil)
                    Button { stop?() } label: { Label("停止", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(stop == nil)
                        .help(stopUnavailable ?? "")
                }
            }
            .padding(ADSpace.l)
        }
        .adPanel()
        .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(desktop["name"]?.stringValue ?? "Desktop")，\(control.status.text)")
    }
}

/// The controller strip above a Desktop picture: who holds input and in
/// which state. Stopping stays "停止中" until the Runtime reports quiet.
public struct ControllerBanner: View {
    let control: DesktopControlPresentation
    let detail: String?

    public init(control: DesktopControlPresentation, detail: String? = nil) {
        self.control = control
        self.detail = detail
    }

    public var body: some View {
        HStack(spacing: ADSpace.m) {
            StateBadge(control.status)
            Text(control.controller).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
            if let detail { Text(detail).font(ADFont.note).foregroundStyle(ADColor.muted) }
            Spacer()
            Text(control.source).font(ADFont.identifier).foregroundStyle(ADColor.muted)
        }
        .padding(.horizontal, ADSpace.l)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(control.status.tone.background.opacity(0.6)))
        .accessibilityElement(children: .combine)
    }
}

/// Right column of a Desktop's detail (P06): connection, output, details.
public struct ConnectionPanel: View {
    public enum Tab: String, CaseIterable, Identifiable {
        case connection = "连接", output = "输出", details = "详情"
        public var id: String { rawValue }
    }

    let desktop: JSONValue
    let control: DesktopControlPresentation
    @State private var tab: Tab
    let takeover: (() -> Void)?
    let showConnection: (() -> Void)?

    public init(desktop: JSONValue, control: DesktopControlPresentation, initialTab: Tab = .connection,
                showConnection: (() -> Void)? = nil, takeover: (() -> Void)? = nil) {
        self.desktop = desktop
        self.control = control
        _tab = State(initialValue: initialTab)
        self.showConnection = showConnection
        self.takeover = takeover
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            HStack(spacing: ADSpace.xs) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        Text(t.rawValue).font(tab == t ? ADFont.bodyStrong : ADFont.body)
                            .foregroundStyle(tab == t ? ADColor.ink : ADColor.muted)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(tab == t ? ADColor.selected : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            switch tab {
            case .connection: connection
            case .output: output
            case .details: details
            }
        }
        .padding(ADSpace.l)
        .adPanel()
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack(spacing: ADSpace.m) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(ADColor.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.controller).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                    Text(control.source).font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                Spacer()
            }
            .padding(ADSpace.l)
            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
            .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(ADColor.line))
            LabeledValue(label: "Desktop ID", value: desktop["desktopId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            HStack {
                Text("控制状态").font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 100, alignment: .leading)
                StateBadge(control.status)
                Spacer()
            }
            LabeledValue(label: "输入范围", value: "仅此 Desktop", labelWidth: 100)
            Button { showConnection?() } label: { Label("连接信息", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                .buttonStyle(ADButtonStyle(.secondary)).disabled(showConnection == nil)
            Button { takeover?() } label: { Label("我要接管", systemImage: "hand.raised").frame(maxWidth: .infinity) }
                .buttonStyle(ADButtonStyle(.secondary)).disabled(takeover == nil)
                .help(takeover == nil ? "接管需要 Runtime 的 desktop.takeover（A5）" : "")
            Text("多个 Desktop 可并行；同一 Desktop 一次只由一个调用者发送输入。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var output: some View {
        Text("输出来自运行的回执与事件；在 Runs 中查看完整记录。").font(ADFont.note).foregroundStyle(ADColor.muted)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            LabeledValue(label: "displayId", value: desktop["screen"]?["displayId"]?.intValue.map(String.init) ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "windowId", value: desktop["binding"]?["windowId"]?.intValue.map(String.init) ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "绑定代次", value: desktop["binding"]?["generation"]?.intValue.map(String.init) ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "pid", value: desktop["binding"]?["process"]?["pid"]?.intValue.map(String.init) ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "会话数", value: desktop["openSessions"]?.intValue.map(String.init) ?? "—", labelWidth: 100)
        }
    }
}
