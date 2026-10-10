import SwiftUI

/// The Settings entry as the main window shows it.
struct SettingsSection: View {
    let context: SectionContext
    let content: (SettingsPage) -> AnyView?

    var body: some View { SettingsPageView(navigation: context.navigation, content: content) }
}

/// Settings: second-level list on the left, the selected entry's content
/// on the right (P21 layout). Owned by lane UI-D (U6;
/// docs/plan/11-parallel-lanes.md); only that lane edits this file.
public struct SettingsPageView: View {
    @ObservedObject var navigation: ShellNavigation
    let content: (SettingsPage) -> AnyView?

    public init(navigation: ShellNavigation, content: @escaping (SettingsPage) -> AnyView?) {
        self.navigation = navigation
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                PageHeader(eyebrow: "Agent Desktop", title: "设置").padding(.bottom, ADSpace.l)
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
                Spacer()
            }
            .padding(ADLayout.contentPadding)
            .frame(width: 240)
            Rectangle().fill(ADColor.line).frame(width: 1)
            Group {
                if let view = content(navigation.settingsPage) {
                    view
                } else if navigation.settingsPage == .verification {
                    notEnabled
                } else {
                    VStack(alignment: .leading) { PendingSection(delivery: navigation.settingsPage.delivery) }
                        .padding(ADLayout.contentPadding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(ADColor.canvas)
    }

    var notEnabled: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            StateBadge("尚未启用", tone: .idle)
            Text("尚未启用：结果未知动作的核实将在后续版本提供").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text("核实只追加记录，原结果保持「结果未知」，不会重发动作。").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.xl).frame(maxWidth: .infinity, alignment: .leading).adPanel()
        .padding(ADLayout.contentPadding)
    }
}
