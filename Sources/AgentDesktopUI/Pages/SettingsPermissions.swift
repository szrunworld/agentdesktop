import AgentDesktopProtocol
import AppKit
import SwiftUI

// Lane UI-D (U6): P22 系统权限 and P02 首次使用. The states come from
// `runtime.capabilities` (backend.permissions; F1-10), never from a check
// of this window's own. Nothing here asks the system for a permission: the
// only action is opening System Settings, on the user's click.

/// The two system permissions the Runtime needs.
public enum SettingsPermission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording, accessibility

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .accessibility: return "辅助功能"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "读取所选 Desktop 的画面。"
        case .accessibility: return "向已绑定的应用发送定向输入。"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: return "display"
        case .accessibility: return "computermouse"
        }
    }

    /// The System Settings pane for this permission.
    public var systemSettingsURL: URL {
        switch self {
        case .screenRecording: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    /// Opens System Settings at the pane; requests nothing.
    public static func openInSystemSettings(_ p: SettingsPermission) {
        NSWorkspace.shared.open(p.systemSettingsURL)
    }
}

/// Permission states as the Runtime reports them.
@MainActor
final class SettingsPermissionsModel: ObservableObject {
    /// granted / denied / unknown per permission; nil until capabilities are read.
    @Published private(set) var states: [SettingsPermission: String]?
    @Published private(set) var checking = false
    @Published private(set) var failure: SettingsFailure?
    @Published private(set) var checkedAt: Date?
    let runtime: RuntimePort

    init(runtime: RuntimePort, capabilities: JSONValue?) {
        self.runtime = runtime
        if let capabilities { apply(capabilities) }
    }

    func apply(_ caps: JSONValue) {
        guard let p = caps["backend"]?["permissions"] else { return }
        var s: [SettingsPermission: String] = [:]
        for k in SettingsPermission.allCases { s[k] = p[k.rawValue]?.stringValue ?? "unknown" }
        states = s
        checkedAt = Date()
    }

    func state(_ p: SettingsPermission) -> String { states?[p] ?? "unknown" }

    var allGranted: Bool { SettingsPermission.allCases.allSatisfy { state($0) == "granted" } }

    /// Reads `runtime.capabilities` again; the Runtime checks the system.
    func recheck() async {
        checking = true
        defer { checking = false }
        do {
            apply(try await runtime.call("runtime.capabilities"))
            failure = nil
        } catch {
            failure = SettingsFailure(error)
        }
    }

    static func badge(_ state: String) -> StatusText {
        switch state {
        case "granted": return StatusText("已授权", .running)
        case "denied": return StatusText("未授权", .danger)
        default: return StatusText("状态未知", .attention)
        }
    }
}

/// One permission: icon, what it is for, its state and, when not granted,
/// the way to System Settings.
struct SettingsPermissionRow: View {
    let permission: SettingsPermission
    let state: String
    let open: (SettingsPermission) -> Void

    var body: some View {
        HStack(spacing: ADSpace.l) {
            Image(systemName: permission.symbol).font(.system(size: 20)).foregroundStyle(ADColor.ink)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(permission.detail).font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            Spacer()
            if state == "granted" {
                StateBadge(SettingsPermissionsModel.badge(state))
            } else {
                StateBadge(SettingsPermissionsModel.badge(state))
                Button { open(permission) } label: { Label("前往授权", systemImage: "chevron.right") }
                    .buttonStyle(ADButtonStyle(.secondary))
                    .accessibilityHint("打开系统设置的\(permission.title)页面，不会自动授权")
            }
        }
        .padding(ADSpace.l)
        .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(ADColor.panel))
        .overlay(RoundedRectangle(cornerRadius: ADRadius.panel)
            .stroke(state == "granted" ? ADColor.line : StatusTone.attention.foreground.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

/// P22: the permissions entry of Settings.
struct SettingsPermissionsPage: View {
    @ObservedObject var model: SettingsPermissionsModel
    let connected: Bool
    let open: (SettingsPermission) -> Void

    var body: some View {
        SettingsPanel(title: "系统权限") {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                Text("仅申请显示、截图与控制目标应用所需的系统权限。模型配置不在此步骤。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).padding(.top, ADSpace.l)
                if !connected || model.states == nil {
                    ProblemView(title: "权限状态未知", advice: "Runtime 未连接或还没有报告权限状态。界面不会假定已经授权。",
                                code: "runtime.capabilities")
                }
                ForEach(SettingsPermission.allCases) { p in
                    SettingsPermissionRow(permission: p, state: model.state(p), open: open)
                }
                if let f = model.failure { SettingsFailureView(failure: f) }
                HStack(spacing: ADSpace.m) {
                    Button { Task { await model.recheck() } } label: { Label("重新检查权限", systemImage: "arrow.clockwise") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(model.checking)
                    if model.checking { ProgressView().controlSize(.small) }
                }
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("权限状态以 Runtime 报告的 runtime.capabilities 为准。Agent Desktop 不会自动申请权限；「前往授权」只打开系统设置，是否授权由你决定。")
                    Text("权限被撤销时停止受影响的输入并提示恢复；不会改用宿主前台执行。")
                }
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 790, alignment: .leading)
    }
}

/// P02: first use. Both permissions must be granted before the first
/// Desktop can be created (UC32); "先查看" leaves without creating anything.
/// The host decides when to show it (first launch); the page only reads.
public struct SettingsFirstUseView: View {
    @StateObject private var model: SettingsPermissionsModel
    let open: (SettingsPermission) -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    public init(store: ShellStore, open: @escaping (SettingsPermission) -> Void = SettingsPermission.openInSystemSettings,
                onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SettingsPermissionsModel(runtime: store.runtime, capabilities: store.capabilities))
        self.open = open
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    init(model: SettingsPermissionsModel, open: @escaping (SettingsPermission) -> Void,
         onContinue: @escaping () -> Void, onSkip: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        self.open = open
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                Image(systemName: "display").font(.system(size: 30)).foregroundStyle(ADColor.ink).accessibilityHidden(true)
                Text("WELCOME TO AGENTDESKTOP").font(ADFont.eyebrow).kerning(1.6).foregroundStyle(ADColor.muted)
                Text("Agent 自己操作，\n你照常工作。").font(.system(size: 30, weight: .bold)).foregroundStyle(ADColor.primary)
                Text("创建独立 Desktop，运行真实应用，\n通过 CLI 或 MCP 接入你的 Agent。").font(ADFont.body).foregroundStyle(ADColor.muted)
                VStack(alignment: .leading, spacing: ADSpace.m) {
                    ForEach(["每个 Desktop 独立接收输入", "同时运行，不抢宿主鼠标", "不需要先配置 AI 模型"], id: \.self) { s in
                        Label(s, systemImage: "checkmark").font(ADFont.body).foregroundStyle(ADColor.ink)
                    }
                }
                .padding(.top, ADSpace.l)
                Spacer()
            }
            .padding(ADSpace.xxl)
            .frame(width: 414, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(ADColor.selected)
            VStack(alignment: .leading, spacing: ADSpace.l) {
                Text("01 / 本机准备").font(ADFont.noteStrong).foregroundStyle(ADColor.muted)
                Text("允许 AgentDesktop 工作").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                Text("先完成两项系统权限，再创建第一个 Desktop。").font(ADFont.note).foregroundStyle(ADColor.muted)
                ForEach(SettingsPermission.allCases) { p in
                    SettingsPermissionRow(permission: p, state: model.state(p), open: open)
                }
                if let f = model.failure { SettingsFailureView(failure: f) }
                Button { onContinue() } label: {
                    Label("完成并创建 Desktop", systemImage: "chevron.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(ADButtonStyle(.primary)).disabled(!model.allGranted)
                .accessibilityHint(model.allGranted ? "" : "两项权限都授权后才能继续")
                HStack {
                    Button("重新检查") { Task { await model.recheck() } }.buttonStyle(ADButtonStyle(.quiet))
                        .disabled(model.checking)
                    Spacer()
                    Button("先查看", action: onSkip).buttonStyle(ADButtonStyle(.quiet))
                }
                Text("状态来自 Runtime 的 runtime.capabilities。这里不会自动申请权限，「前往授权」只打开系统设置。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(ADSpace.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ADColor.panel)
        }
        .frame(width: 944, height: 510)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ADColor.line))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ADColor.canvas)
    }
}
