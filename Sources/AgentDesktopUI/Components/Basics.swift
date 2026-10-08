import SwiftUI

/// A state shown as a dot, words and a tone together; never colour alone.
public struct StateBadge: View {
    public let status: StatusText

    public init(_ status: StatusText) { self.status = status }
    public init(_ text: String, tone: StatusTone) { self.status = StatusText(text, tone) }

    /// What assistive technology reads: the words, never the colour.
    public var accessibilityText: String { status.text }

    public var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.tone.foreground).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(status.text).font(ADFont.noteStrong).foregroundStyle(status.tone.foreground).lineLimit(1)
        }
        .padding(.horizontal, ADSpace.s)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(status.tone.background))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(status.tone.foreground.opacity(0.18)))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

/// Button looks of Design v2.0: min height 36, radius 7.
public struct ADButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, danger, quiet }
    public let kind: Kind

    public init(_ kind: Kind = .secondary) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        StyledButtonBody(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }

    private struct StyledButtonBody<Label: View>: View {
        let kind: Kind
        let label: Label
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label
                .font(ADFont.bodyStrong)
                .foregroundStyle(foreground)
                .padding(.horizontal, ADSpace.l)
                .frame(minHeight: ADLayout.buttonMinHeight)
                .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(background))
                .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(border, lineWidth: 1))
                .opacity(enabled ? (pressed ? 0.8 : 1) : 0.45)
                .contentShape(Rectangle())
        }

        var foreground: Color {
            switch kind {
            case .primary: return .white
            case .danger: return StatusTone.danger.foreground
            case .secondary, .quiet: return ADColor.ink
            }
        }

        var background: Color {
            switch kind {
            case .primary: return ADColor.primary
            case .danger: return StatusTone.danger.background
            case .secondary: return ADColor.panel
            case .quiet: return .clear
            }
        }

        var border: Color {
            switch kind {
            case .primary: return ADColor.primary
            case .danger: return StatusTone.danger.foreground.opacity(0.45)
            case .secondary: return ADColor.line
            case .quiet: return .clear
            }
        }
    }
}

/// White panel with a 12 pt radius and a 1 pt line.
public struct PanelBackground: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(ADColor.panel))
            .overlay(RoundedRectangle(cornerRadius: ADRadius.panel).stroke(ADColor.line, lineWidth: 1))
    }
}

extension View {
    public func adPanel() -> some View { modifier(PanelBackground()) }
}

/// Eyebrow, page title (27) and one line of explanation.
public struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String?
    let trailing: Trailing

    public init(eyebrow: String, title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: ADSpace.s) {
                Text(eyebrow.uppercased()).font(ADFont.eyebrow).kerning(1.6).foregroundStyle(ADColor.muted)
                Text(title).font(ADFont.pageTitle).foregroundStyle(ADColor.ink)
                if let subtitle { Text(subtitle).font(ADFont.note).foregroundStyle(ADColor.muted) }
            }
            Spacer(minLength: ADSpace.l)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    public init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// An empty list or page with at most one next step. Also used by
/// AgentDesktopAIUI (moved here from its Components.swift).
public struct EmptyState: View {
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    public init(title: String, detail: String, action: (String, () -> Void)?) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    public var body: some View {
        VStack(spacing: ADSpace.s) {
            Text(title).font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text(detail).font(ADFont.note).foregroundStyle(ADColor.muted).multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1).buttonStyle(ADButtonStyle(.primary)).padding(.top, ADSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// A label and a selectable value on one line. Also used by AgentDesktopAIUI.
public struct LabeledValue: View {
    let label: String
    let value: String
    let monospaced: Bool
    let labelWidth: CGFloat

    public init(label: String, value: String, monospaced: Bool = false, labelWidth: CGFloat = 150) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.labelWidth = labelWidth
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: labelWidth, alignment: .leading)
            Text(value).font(monospaced ? ADFont.code : ADFont.note).foregroundStyle(ADColor.ink).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// A failure: title, advice and the stable code; an optional retry.
public struct ProblemView: View {
    let title: String
    let advice: String
    let code: String
    let extra: [String]
    let retry: (() -> Void)?

    public init(title: String, advice: String, code: String, extra: [String] = [], retry: (() -> Void)? = nil) {
        self.title = title
        self.advice = advice
        self.code = code
        self.extra = extra
        self.retry = retry
    }

    public init(_ problem: RuntimeProblem, retry: (() -> Void)? = nil) {
        self.init(title: problem.title, advice: problem.advice, code: problem.code, retry: retry)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: ADSpace.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusTone.attention.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(advice).font(ADFont.note).foregroundStyle(ADColor.ink)
                ForEach(extra, id: \.self) { Text($0).font(ADFont.note).foregroundStyle(ADColor.muted) }
                Text(code).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }
            Spacer()
            if let retry { Button("重试", action: retry).buttonStyle(ADButtonStyle(.secondary)) }
        }
        .padding(ADSpace.m)
        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(StatusTone.attention.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("错误：\(title)。\(advice)")
    }
}

/// Permanent mark while data comes from a sample source (09 brief).
public struct SampleMark: View {
    public init() {}
    public var body: some View {
        StateBadge("样例数据 · 非真实 Runtime", tone: .attention)
    }
}
