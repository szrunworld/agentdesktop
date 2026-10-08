import AgentDesktopProtocol
import AppKit
import SwiftUI

/// A titled settings section (P21) holding rows.
public struct SettingsPanel<Content: View>: View {
    let title: String
    let content: Content

    public init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                .padding(.horizontal, ADSpace.l).frame(height: 54)
            Rectangle().fill(ADColor.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, ADSpace.l).padding(.bottom, ADSpace.l)
        }
        .adPanel()
    }
}

/// A switch with its title and the consequence written under it.
public struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    public init(title: String, detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    public var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(detail).font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(ADColor.primary)
        }
        .padding(.vertical, ADSpace.l)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// A labelled choice from a fixed list.
public struct SettingsChoiceRow: View {
    let title: String
    let options: [String]
    @Binding var selection: String

    public init(title: String, options: [String], selection: Binding<String>) {
        self.title = title
        self.options = options
        _selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            Text(title).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
            Picker(title, selection: $selection) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
        }
    }
}

/// A confirmation that states what will and will not happen. The cancel
/// button is always there; the confirming one says its effect.
public struct ConfirmationDialog: View {
    let title: String
    let message: String
    let consequences: [String]
    let preserved: [String]
    let confirmTitle: String
    let destructive: Bool
    let cancel: () -> Void
    let confirm: (() -> Void)?

    public init(title: String, message: String, consequences: [String] = [], preserved: [String] = [],
                confirmTitle: String, destructive: Bool = false, cancel: @escaping () -> Void, confirm: (() -> Void)?) {
        self.title = title
        self.message = message
        self.consequences = consequences
        self.preserved = preserved
        self.confirmTitle = confirmTitle
        self.destructive = destructive
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            Text(title).font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text(message).font(ADFont.body).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
            if !consequences.isEmpty { list("将会", consequences, tone: destructive ? .danger : .attention) }
            if !preserved.isEmpty { list("不会改变", preserved, tone: .idle) }
            HStack {
                Spacer()
                Button("取消", action: cancel).buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm?() }.buttonStyle(ADButtonStyle(destructive ? .danger : .primary))
                    .disabled(confirm == nil)
            }
        }
        .padding(ADSpace.xl)
        .frame(width: 460)
        .adPanel()
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }

    private func list(_ heading: String, _ items: [String], tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(heading).font(ADFont.noteStrong).foregroundStyle(tone.foreground)
            ForEach(items, id: \.self) { Text("· \($0)").font(ADFont.note).foregroundStyle(ADColor.ink) }
        }
    }
}

/// Endpoint rule for AI connections: HTTPS, or HTTP on loopback only.
/// Moved from AgentDesktopAIUI's W02 editor so both use one rule.
public enum ProviderEndpointRule {
    public static func error(_ s: String, allowLocalHTTP: Bool) -> String? {
        guard let u = URLComponents(string: s), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else {
            return "请输入完整的 URL"
        }
        if u.user != nil || u.password != nil { return "URL 不能包含用户名或密码" }
        if u.query != nil || u.fragment != nil { return "URL 不能包含查询参数或片段（# 之后）" }
        if u.path.hasSuffix("/chat/completions") || u.path.hasSuffix("/chat/completions/") {
            return "请填写基础地址，不要包含 /chat/completions"
        }
        switch scheme {
        case "https": return nil
        case "http":
            guard ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return "非本机地址必须使用 HTTPS" }
            return allowLocalHTTP ? nil : "本机 HTTP 需要先开启“允许本地模型”"
        default: return "只支持 HTTPS（或本机 HTTP）"
        }
    }
}

/// The fields of an AI connection (P24). Presentation only: it holds no
/// data of its own and sends nothing; the caller owns the values and the
/// key, and clears the key after its one submission (AIUI W02's rule).
public struct ProviderForm: View {
    @Binding var name: String
    @Binding var baseUrl: String
    @Binding var secret: String
    @Binding var modelId: String
    @Binding var timeoutMs: Int
    let fieldErrors: [String: String]
    let submitTitle: String
    let submit: (() -> Void)?

    public init(name: Binding<String>, baseUrl: Binding<String>, secret: Binding<String>, modelId: Binding<String>,
                timeoutMs: Binding<Int>, fieldErrors: [String: String] = [:], submitTitle: String = "校验并保存",
                submit: (() -> Void)?) {
        _name = name
        _baseUrl = baseUrl
        _secret = secret
        _modelId = modelId
        _timeoutMs = timeoutMs
        self.fieldErrors = fieldErrors
        self.submitTitle = submitTitle
        self.submit = submit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            field("名称", key: "name") { TextField("例如：本机模型", text: $name) }
            field("协议", key: "protocol") { Text("openai_chat").font(ADFont.code).foregroundStyle(ADColor.ink) }
            field("端点", key: "baseUrl") { TextField("https://", text: $baseUrl) }
            field("API 密钥", key: "apiKey") { SecureField("只用于这次提交，不会显示或保存到界面", text: $secret) }
            field("模型 ID", key: "modelId") { TextField("模型 ID", text: $modelId) }
            field("超时（毫秒）", key: "timeoutMs") { TextField("30000", value: $timeoutMs, format: .number) }
            Text("只接受 HTTPS 或本机 loopback HTTP。模型已列出不等于支持图像或 GUI 输出。")
                .font(ADFont.note).foregroundStyle(ADColor.muted)
            HStack {
                Spacer()
                Button(submitTitle) { submit?() }.buttonStyle(ADButtonStyle(.primary)).disabled(submit == nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(ADSpace.xl)
        .adPanel()
    }

    private func field<F: View>(_ label: String, key: String, @ViewBuilder _ control: () -> F) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(label).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
            control()
            if let e = fieldErrors[key] {
                Text(e).font(ADFont.note).foregroundStyle(StatusTone.danger.foreground)
                    .accessibilityLabel("\(label)：\(e)")
            }
        }
    }
}

/// A command or configuration to copy, in a monospaced box. When `json` is
/// true the text is checked with the strict parser and the result shown.
public struct CodeBox: View {
    let title: String
    let code: String
    let json: Bool
    @State private var copied = false

    public init(title: String, code: String, json: Bool = false) {
        self.title = title
        self.code = code
        self.json = json
    }

    /// Whether `code` is one valid JSON value (StrictJSON: no duplicate keys).
    public static func isValidJSON(_ code: String) -> Bool { (try? StrictJSON.parse(code)) != nil }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            HStack {
                Text(title).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                if json {
                    StateBadge(Self.isValidJSON(code) ? StatusText("有效 JSON", .running) : StatusText("JSON 无效", .danger))
                }
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .buttonStyle(ADButtonStyle(.secondary))
            }
            Text(code).font(ADFont.code).foregroundStyle(ADColor.ink).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(ADSpace.m)
                .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
                .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(ADColor.line))
        }
    }
}
