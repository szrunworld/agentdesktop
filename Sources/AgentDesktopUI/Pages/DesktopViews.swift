import AgentDesktopProtocol
import SwiftUI

/// Buttons for actions the Runtime does not offer yet (desktop.stop,
/// takeover, closePlan, all A5): present, off, and saying why.
public enum WaitingFor {
    public static let a5 = "等待 A5"
}

/// The observed picture with its facts: size in pixels, scale, snapshotId
/// (shown as 画面 ID, D20) and capture time. Zoom changes only the display.
public struct DesktopFrameView: View {
    @ObservedObject var loader: DesktopFrameLoader
    @Binding var zoom: PreviewZoom
    /// Fixed picture height inside scrolling pages; nil fills the space
    /// (the preview window).
    let height: CGFloat?
    let showControls: Bool

    public init(loader: DesktopFrameLoader, zoom: Binding<PreviewZoom>, height: CGFloat? = 360, showControls: Bool = true) {
        self.loader = loader
        _zoom = zoom
        self.height = height
        self.showControls = showControls
    }

    public var body: some View {
        VStack(spacing: 0) {
            picture
                .frame(maxWidth: .infinity, minHeight: height ?? 240, maxHeight: height ?? .infinity)
                .background(ADColor.canvas)
                .clipped()
            if showControls { footer }
        }
        .adPanel()
        .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
    }

    @ViewBuilder var picture: some View {
        if let image = loader.image {
            ZStack(alignment: .top) {
                if let f = zoom.factor(imageScale: loader.scale), let px = loader.pixelSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: CGFloat(px.width) * f, height: CGFloat(px.height) * f)
                    }
                } else {
                    // Fit, but never larger than the picture's own size in points.
                    let pts = loader.pixelSize.map { CGSize(width: CGFloat($0.width) / CGFloat(loader.scale ?? 1),
                                                            height: CGFloat($0.height) / CGFloat(loader.scale ?? 1)) }
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: pts?.width ?? .infinity, maxHeight: pts?.height ?? .infinity)
                        .padding(ADSpace.s).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                problemOverlay
            }
        } else {
            switch loader.state {
            case .loading:
                VStack(spacing: ADSpace.s) {
                    ProgressView()
                    Text("正在观察这个 Desktop…").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            default:
                problemOverlay
            }
        }
    }

    @ViewBuilder var problemOverlay: some View {
        switch loader.state {
        case .failed(let p), .disconnected(let p):
            ProblemView(title: "画面没有更新：\(p.title)", advice: p.advice, code: p.code,
                        extra: loader.image == nil ? [] : ["下方是上一次观察的画面"],
                        retry: { Task { await loader.load() } })
                .padding(ADSpace.m)
        default:
            EmptyView()
        }
    }

    var footer: some View {
        HStack(spacing: ADSpace.m) {
            Image(systemName: "display").foregroundStyle(ADColor.muted)
            Text(sizeText).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            Spacer()
            Text("画面 ID").font(ADFont.note).foregroundStyle(ADColor.muted)
            Text(loader.snapshotId ?? "—").font(ADFont.code).foregroundStyle(ADColor.ink).textSelection(.enabled)
            Text(TimeText.clock(loader.capturedAt)).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            Spacer()
            Picker("缩放", selection: $zoom) { ForEach(PreviewZoom.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().pickerStyle(.menu).frame(width: 110)
            Button { Task { await loader.load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("重新观察")
        }
        .padding(.horizontal, ADSpace.l).frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }

    var sizeText: String {
        guard let px = loader.pixelSize else { return "—" }
        let s = loader.scale.map { $0 == $0.rounded() ? "\(Int($0))x" : String(format: "%.2fx", $0) } ?? "—"
        return "\(px.width) × \(px.height) px · scale \(s)"
    }
}

/// P04 / P05: the create sheet, then the real steps of creation.
public struct CreateDesktopSheet: View {
    @ObservedObject var flow: CreateDesktopFlow
    let cancel: () -> Void
    let finished: (String) -> Void

    public init(flow: CreateDesktopFlow, cancel: @escaping () -> Void, finished: @escaping (String) -> Void) {
        self.flow = flow
        self.cancel = cancel
        self.finished = finished
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            Text(flow.started ? "正在创建 Desktop" : "创建 Desktop").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            if flow.started { progress } else { form }
        }
        .padding(ADSpace.xl)
        .frame(width: 560)
        .background(ADColor.panel)
        .task { await flow.loadChoices() }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text("名称").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                TextField("例如：表单验证", text: $flow.name).textFieldStyle(.roundedBorder)
                    .onChange(of: flow.name) { _, _ in if flow.nameError != nil { flow.validate() } }
                if let e = flow.nameError {
                    Text(e).font(ADFont.note).foregroundStyle(StatusTone.danger.foreground).accessibilityLabel("名称：\(e)")
                }
            }
            Picker("方式", selection: $flow.mode) { ForEach(CreateDesktopFlow.Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch flow.mode {
            case .empty:
                Text("只创建一个空的独立桌面，之后由 Agent 启动或绑定应用。").font(ADFont.note).foregroundStyle(ADColor.muted)
            case .launch:
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("应用的 Bundle ID 或 .app 路径").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                    TextField("com.example.app 或 /Applications/Example.app", text: $flow.bundleId).textFieldStyle(.roundedBorder)
                    if !flow.apps.isEmpty {
                        Menu("从正在运行的应用中选择") {
                            ForEach(flow.apps.indices, id: \.self) { i in
                                let a = flow.apps[i]
                                Button("\(a["name"]?.stringValue ?? "—")（\(a["bundleId"]?.stringValue ?? "")）") {
                                    flow.bundleId = a["bundleId"]?.stringValue ?? ""
                                }
                            }
                        }
                        .frame(width: 260)
                    }
                    Text("以新实例启动，窗口放在这个 Desktop 上；不会移动已经打开的窗口。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            case .bind:
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("选择窗口").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                    if flow.windows.isEmpty {
                        Text("没有可绑定的窗口。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(flow.windows.indices, id: \.self) { i in windowRow(flow.windows[i]) }
                        }
                    }
                    .frame(maxHeight: 180).adPanel()
                    Text("绑定会把这个窗口移到新 Desktop 上，之后的输入只发给它。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            }
            if let e = flow.choiceError {
                Text(e).font(ADFont.note).foregroundStyle(StatusTone.danger.foreground)
            }
            if let p = flow.choicesProblem { ProblemView(p) }
            DisclosureGroup("高级：尺寸", isExpanded: $flow.showSize) {
                HStack {
                    Picker("尺寸", selection: Binding(get: { "\(flow.width)x\(flow.height)" }, set: { v in
                        let parts = v.split(separator: "x").compactMap { Int($0) }
                        if parts.count == 2 { flow.width = parts[0]; flow.height = parts[1] }
                    })) {
                        ForEach(CreateDesktopFlow.sizes, id: \.0) { s in Text(s.0).tag("\(s.1)x\(s.2)") }
                    }
                    .labelsHidden().frame(width: 180)
                    Text("不选则与主显示器的全屏区域相同").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                .padding(.top, ADSpace.s)
            }
            .font(ADFont.note)
            HStack {
                Spacer()
                Button("取消", action: cancel).buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("创建") { Task { await flow.submit() } }.buttonStyle(ADButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    func windowRow(_ w: JSONValue) -> some View {
        let on = flow.window?["windowId"] == w["windowId"]
        return Button { flow.window = w } label: {
            HStack {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? ADColor.primary : ADColor.muted)
                Text(w["appName"]?.stringValue ?? "—").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text(w["title"]?.stringValue ?? "（标题不可读）").font(ADFont.note).foregroundStyle(ADColor.muted).lineLimit(1)
                Spacer()
                Text("pid \(w["process"]?["pid"]?.intValue ?? 0) · 窗口 \(w["windowId"]?.intValue ?? 0)")
                    .font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }
            .padding(.horizontal, ADSpace.m).frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("窗口 \(w["appName"]?.stringValue ?? "") \(w["title"]?.stringValue ?? "")")
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            step("创建 Desktop", flow.createStep, detail: flow.desktopId)
            if flow.mode != .empty {
                step(flow.mode == .launch ? "启动应用并绑定它的窗口：\(flow.bundleId)" : "绑定窗口", flow.attachStep, detail: nil)
            }
            Text("创建中没有控制者，暂不接受输入；只显示 Runtime 返回的每一步结果，没有进度百分比。")
                .font(ADFont.note).foregroundStyle(ADColor.muted)
            HStack {
                Spacer()
                if flow.hasFailed {
                    Button("关闭", action: { if let id = flow.desktopId { finished(id) } else { cancel() } })
                        .buttonStyle(ADButtonStyle(.secondary))
                    Button("重试失败的步骤") { Task { await flow.retry() } }.buttonStyle(ADButtonStyle(.primary))
                } else if flow.isDone, let id = flow.desktopId {
                    Button("打开 Desktop") { finished(id) }.buttonStyle(ADButtonStyle(.primary))
                }
            }
        }
    }

    func step(_ title: String, _ state: CreateDesktopFlow.StepState, detail: String?) -> some View {
        HStack(alignment: .top, spacing: ADSpace.m) {
            switch state {
            case .pending: StateBadge("等待", tone: .idle)
            case .running: ProgressView().controlSize(.small)
            case .done: StateBadge("完成", tone: .running)
            case .skipped: StateBadge("不需要", tone: .idle)
            case .failed: StateBadge("失败", tone: .danger)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                if let detail { Text(detail).font(ADFont.code).foregroundStyle(ADColor.muted) }
                if case .failed(let p) = state {
                    ProblemView(title: p.title, advice: p.advice, code: p.code)
                }
            }
        }
    }
}

/// P07: Desktops side by side, each with its own observed picture.
public struct SideBySideView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    let openPreview: ((String) -> Void)?

    public init(store: ShellStore, navigation: ShellNavigation, openPreview: ((String) -> Void)?) {
        self.store = store
        self.navigation = navigation
        self.openPreview = openPreview
    }

    public var body: some View {
        PageContainer(state: store.desktopsState, emptyTitle: "还没有 Desktop", syncedAt: store.desktopsSyncedAt,
                      retry: { Task { await store.start() } }, header: {
            PageHeader(eyebrow: "Desktops / Side by side", title: "并排预览",
                       subtitle: "每个 Desktop 独立输入；这里只看画面，停止要等 Runtime 的单 Desktop 停止（A5）。") {
                Button { navigation.sideBySide = false } label: { Label("总览", systemImage: "chevron.left") }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
        }) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: ADSpace.l), GridItem(.flexible(), spacing: ADSpace.l)],
                      spacing: ADSpace.l) {
                ForEach(store.desktops.indices, id: \.self) { i in
                    SideBySidePanel(store: store, navigation: navigation, desktop: store.desktops[i], openPreview: openPreview)
                        .id(store.desktops[i]["desktopId"]?.stringValue ?? "\(i)")
                }
            }
        }
    }
}

struct SideBySidePanel: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    let desktop: JSONValue
    let openPreview: ((String) -> Void)?
    @StateObject private var loader: DesktopFrameLoader
    @State private var zoom: PreviewZoom = .fit

    init(store: ShellStore, navigation: ShellNavigation, desktop: JSONValue, openPreview: ((String) -> Void)?) {
        self.store = store
        self.navigation = navigation
        self.desktop = desktop
        self.openPreview = openPreview
        _loader = StateObject(wrappedValue: DesktopFrameLoader(runtime: store.runtime, desktopId: desktop["desktopId"]?.stringValue ?? ""))
    }

    var body: some View {
        let id = desktop["desktopId"]?.stringValue ?? ""
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack {
                Text(desktop["name"]?.stringValue ?? "—").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(id).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                Spacer()
                StateBadge(DesktopControlPresentation.make(desktop: desktop, activeRuns: store.activeRuns).status)
            }
            DesktopFrameView(loader: loader, zoom: $zoom, height: 300)
            HStack(spacing: ADSpace.s) {
                Button { navigation.showDesktop(id) } label: { Label("详情", systemImage: "info.circle") }
                    .buttonStyle(ADButtonStyle(.secondary))
                Button { openPreview?(id) } label: { Label("独立预览", systemImage: "rectangle.on.rectangle") }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(openPreview == nil)
                Spacer()
                Button {} label: { Label("停止", systemImage: "stop.fill") }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(true).help(WaitingFor.a5)
                Text(WaitingFor.a5).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }
        }
        .task(id: store.tick) { await loader.refreshIfStale(interval: 5) }
    }
}

/// P08: one Desktop's picture in its own window. Closing it closes only the
/// window; the Desktop, its input and its Runs go on (UC14).
public struct DesktopPreviewView: View {
    @ObservedObject var store: ShellStore
    @StateObject private var loader: DesktopFrameLoader
    @State private var zoom: PreviewZoom = .fit
    let desktopId: String
    let hide: () -> Void
    let openDetail: () -> Void

    public init(store: ShellStore, desktopId: String, hide: @escaping () -> Void, openDetail: @escaping () -> Void) {
        self.store = store
        self.desktopId = desktopId
        self.hide = hide
        self.openDetail = openDetail
        _loader = StateObject(wrappedValue: DesktopFrameLoader(runtime: store.runtime, desktopId: desktopId))
    }

    init(store: ShellStore, loader: DesktopFrameLoader, hide: @escaping () -> Void, openDetail: @escaping () -> Void) {
        self.store = store
        self.desktopId = loader.desktopId
        self.hide = hide
        self.openDetail = openDetail
        _loader = StateObject(wrappedValue: loader)
    }

    var desktop: JSONValue? { store.desktops.first { $0["desktopId"]?.stringValue == desktopId } }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ADSpace.m) {
                Text(desktop?["name"]?.stringValue ?? desktopId).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(desktopId).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                if let d = desktop { StateBadge(DesktopControlPresentation.make(desktop: d, activeRuns: store.activeRuns).status) }
                Spacer()
                Button("打开详情", action: openDetail).buttonStyle(ADButtonStyle(.secondary))
                Button("隐藏预览", action: hide).buttonStyle(ADButtonStyle(.secondary))
                    .help("只关闭这个窗口；Desktop 和它的运行不受影响")
                Button {} label: { Label("停止", systemImage: "stop.fill") }.buttonStyle(ADButtonStyle(.secondary))
                    .disabled(true).help(WaitingFor.a5)
            }
            .padding(.horizontal, ADSpace.l).frame(height: 54)
            .background(ADColor.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
            if desktop == nil, store.desktopsState == .loaded || store.desktopsState == .empty {
                EmptyState(title: "这个 Desktop 已不存在", detail: "\(desktopId) 已关闭；可以关闭这个预览窗口。", action: nil)
                    .frame(maxHeight: .infinity)
            } else {
                DesktopFrameView(loader: loader, zoom: $zoom, height: nil).padding(ADSpace.m)
            }
        }
        .background(ADColor.canvas)
        .environment(\.colorScheme, .light)
        .task(id: store.tick) { await loader.refreshIfStale(interval: 3) }
    }
}
