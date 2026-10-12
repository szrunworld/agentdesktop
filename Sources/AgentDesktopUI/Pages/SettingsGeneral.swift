import AgentDesktopProtocol
import SwiftUI

// Lane UI-D (U6): P21 通用. Local preferences only; nothing here reaches
// the Runtime or changes a Desktop that exists.

/// A Desktop size offered for new Desktops.
public struct SettingsDesktopSize: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var label: String { "\(width) × \(height)" }

    public static let choices = [SettingsDesktopSize(width: 1280, height: 800),
                                 SettingsDesktopSize(width: 1440, height: 900),
                                 SettingsDesktopSize(width: 1920, height: 1080)]
    public static let standard = choices[0]
}

/// The user's local preferences (P21), kept in UserDefaults. The page edits
/// a draft; only "保存偏好" writes it. Readers (the host's cursor overlay,
/// the Desktop creation form) read `saved`.
@MainActor
public final class SettingsPreferences: ObservableObject {
    public struct Values: Equatable, Sendable {
        public var showAgentCursor = true
        public var defaultDesktopSize = SettingsDesktopSize.standard
        public init() {}
    }

    public static let showAgentCursorKey = "agentdesktop.settings.showAgentCursor"
    public static let defaultDesktopSizeKey = "agentdesktop.settings.defaultDesktopSize"

    @Published public private(set) var saved: Values
    @Published public var draft: Values
    @Published public private(set) var savedNotice: String?
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var v = Values()
        if defaults.object(forKey: Self.showAgentCursorKey) != nil {
            v.showAgentCursor = defaults.bool(forKey: Self.showAgentCursorKey)
        }
        if let s = defaults.string(forKey: Self.defaultDesktopSizeKey),
           let size = SettingsDesktopSize.choices.first(where: { "\($0.width)x\($0.height)" == s }) {
            v.defaultDesktopSize = size
        }
        saved = v
        draft = v
    }

    public var isDirty: Bool { draft != saved }

    /// Writes the draft. A new default size applies to Desktops created
    /// afterwards only; existing Desktops are not rebuilt.
    public func save() {
        defaults.set(draft.showAgentCursor, forKey: Self.showAgentCursorKey)
        defaults.set("\(draft.defaultDesktopSize.width)x\(draft.defaultDesktopSize.height)", forKey: Self.defaultDesktopSizeKey)
        saved = draft
        savedNotice = "已保存为本机偏好。默认尺寸对之后新建的 Desktop 生效，已有的 Desktop 不会改变；光标开关尚未接入预览，接入后生效。"
    }

    public func revert() {
        draft = saved
        savedNotice = nil
    }
}

struct SettingsGeneralPage: View {
    @ObservedObject var preferences: SettingsPreferences

    var body: some View {
        SettingsPanel(title: "通用") {
            SettingsToggleRow(title: "关闭主窗口后继续运行",
                              detail: "关闭主窗口只隐藏窗口，保留菜单栏入口，不停止正在工作的 Desktop。退出请用菜单栏的「退出」。",
                              isOn: .constant(true))
                .disabled(true)
                .accessibilityHint("固定开启")
            SettingsToggleRow(title: "在预览中显示 Agent 光标", detail: "只影响画面显示，不改变输入路由。目前只保存偏好，尚未接入预览。",
                              isOn: $preferences.draft.showAgentCursor)
            SettingsToggleRow(title: "登录时启动 AgentDesktop",
                              detail: "尚未提供：将在后续版本支持。开启后也只启动本机服务，不自动启动 Agent 或业务任务。",
                              isOn: .constant(false))
                .disabled(true)
            HStack(alignment: .top, spacing: ADSpace.l) {
                SettingsChoiceRow(title: "新 Desktop 默认尺寸（尚未接入新建表单）", options: SettingsDesktopSize.choices.map(\.label),
                                  selection: Binding(
                                    get: { preferences.draft.defaultDesktopSize.label },
                                    set: { label in
                                        if let s = SettingsDesktopSize.choices.first(where: { $0.label == label }) {
                                            preferences.draft.defaultDesktopSize = s
                                        }
                                    }))
                SettingsChoiceRow(title: "界面语言", options: ["简体中文"], selection: .constant("简体中文"))
            }
            .padding(.top, ADSpace.xl)
            HStack(spacing: ADSpace.s) {
                Button("保存偏好") { preferences.save() }
                    .buttonStyle(ADButtonStyle(.primary)).disabled(!preferences.isDirty)
                if preferences.isDirty {
                    Button("放弃修改") { preferences.revert() }.buttonStyle(ADButtonStyle(.secondary))
                    Text("有未保存的修改").font(ADFont.note).foregroundStyle(StatusTone.attention.foreground)
                } else if let n = preferences.savedNotice {
                    Text(n).font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            }
            .padding(.top, ADSpace.l)
        }
        .frame(maxWidth: 790, alignment: .leading)
    }
}
