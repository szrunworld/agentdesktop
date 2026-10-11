import AgentDesktopProtocol
import SwiftUI

// Lane UI-D (U6 设置): pieces the Settings pages share. Kept in this lane's
// own file until another lane needs them (docs/plan/11-parallel-lanes.md).

/// A failed Settings call as the page shows it: the runtime/1 problem, and
/// on a revision conflict the revision the Runtime holds now. The page
/// keeps the user's draft and never retries a write by itself.
struct SettingsFailure: Equatable {
    let problem: RuntimeProblem
    let currentRevision: Int?
    /// The AI service's own code (`details.serviceCode`), when it answered.
    let serviceCode: String?

    init(_ error: Error) {
        let e = error as? RuntimeError
        let base = RuntimeProblem(error)
        serviceCode = e?.details?["serviceCode"]?.stringValue
        currentRevision = e?.details?["currentRevision"]?.intValue
        if let advice = Self.advice(code: base.code, serviceCode: serviceCode, reason: e?.details?["reason"]?.stringValue) {
            problem = RuntimeProblem(code: base.code, title: advice.0, advice: advice.1, notSent: base.notSent)
        } else {
            problem = base
        }
    }

    init(problem: RuntimeProblem) {
        self.problem = problem
        currentRevision = nil
        serviceCode = nil
    }

    var isConflict: Bool { problem.code == "conflict" && currentRevision != nil }

    /// Words for the AI service's refusals that runtime/1 folds into one code.
    static func advice(code: String, serviceCode: String?, reason: String?) -> (String, String)? {
        switch (code, serviceCode ?? reason ?? "") {
        case ("conflict", "CONFIG_CONFLICT"):
            return ("配置已被修改", "这项配置在别处（另一个窗口或命令行）被改过。你的输入仍保留，请重新读取后再决定是否保存。")
        case ("conflict", "RESOURCE_IN_USE"), ("conflict", "in_use"):
            return ("仍在被使用", "还有配置引用它，不能删除。请先改掉或删除引用它的配置；不会级联删除。")
        case ("conflict", "RESOURCE_DISABLED"), ("conflict", "disabled"):
            return ("已停用", "已停用的连接或配置不能用于新的配置或测试。")
        case ("model_unavailable", "CREDENTIAL_REVOKED"), ("model_unavailable", "credential_revoked"):
            return ("凭据已撤销", "这条连接的凭据已被轮换或撤销，请在 AI 连接里填写新的密钥。")
        case ("model_unavailable", "CREDENTIAL_REQUIRED"), ("model_unavailable", "credential_required"):
            return ("缺少凭据", "这条连接还没有可用的密钥。")
        case ("model_unavailable", "AUTH_FAILED"), ("model_unavailable", "auth_failed"):
            return ("认证失败", "上游拒绝了这把密钥。请检查后轮换密钥；界面不会自动重试。")
        case ("idempotency_conflict", _):
            return ("同一请求编号对应了不同内容", "这次提交和之前的内容不同，没有执行。请确认后重新提交。")
        default:
            return nil
        }
    }

    var extra: [String] {
        currentRevision.map { ["服务器当前版本 r\($0)；页面上读到的是旧版本。"] } ?? []
    }
}

struct SettingsFailureView: View {
    let failure: SettingsFailure
    var retry: (() -> Void)?

    var body: some View {
        ProblemView(title: failure.problem.title, advice: failure.problem.advice, code: failure.problem.code,
                    extra: failure.extra, retry: retry)
    }
}

/// One AI connection. Holds no secret: only whether one is set.
struct AIConnectionItem: Identifiable, Equatable {
    let id: String
    let name: String
    let baseUrl: String
    let enabled: Bool
    let revision: Int
    let timeoutMs: Int
    let credentialSet: Bool

    init(_ v: JSONValue) {
        id = v["connectionId"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        baseUrl = v["baseUrl"]?.stringValue ?? ""
        enabled = v["state"]?.stringValue == "enabled"
        revision = v["revision"]?.intValue ?? 0
        timeoutMs = v["timeoutMs"]?.intValue ?? 30000
        credentialSet = v["credentialRef"]?.stringValue != nil
    }

    static let protocolLabel = "OpenAI Chat 兼容协议"
}

/// One model profile: which model on which connection, and what a test
/// proved about it (evidence per level).
struct AIModelProfileItem: Identifiable, Equatable {
    let id: String
    let name: String
    let modelId: String
    let connectionId: String
    let connectionRevision: Int
    let revision: Int
    let enabled: Bool
    /// network / authModel / imageInput / guiContract → status.
    let evidence: [String: String]
    /// Connection revision the evidence was taken at.
    let evidenceConnectionRevision: Int?

    init(_ v: JSONValue) {
        id = v["modelProfileId"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        modelId = v["modelId"]?.stringValue ?? ""
        connectionId = v["connectionId"]?.stringValue ?? ""
        connectionRevision = v["connectionRevision"]?.intValue ?? 0
        revision = v["revision"]?.intValue ?? 0
        enabled = v["state"]?.stringValue == "enabled"
        var e: [String: String] = [:]
        for k in ["network", "authModel", "imageInput", "guiContract"] {
            e[k] = v["capabilities"]?[k]?["status"]?.stringValue ?? "unknown"
        }
        evidence = e
        evidenceConnectionRevision = v["capabilities"]?["guiContract"]?["scope"]?["connectionRevision"]?.intValue
    }
}

/// One GUI profile.
struct AIGuiProfileItem: Identifiable, Equatable {
    let id: String
    let name: String
    let revision: Int
    let enabled: Bool
    let modelProfileId: String
    let modelProfileRevision: Int
    let adapterId: String
    let coordinateProtocol: String
    let limits: JSONValue?

    init(_ v: JSONValue) {
        id = v["guiProfileId"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        revision = v["revision"]?.intValue ?? 0
        enabled = v["state"]?.stringValue == "enabled"
        modelProfileId = v["modelProfileId"]?.stringValue ?? ""
        modelProfileRevision = v["modelProfileRevision"]?.intValue ?? 0
        adapterId = v["adapterId"]?.stringValue ?? ""
        coordinateProtocol = v["coordinateProtocol"]?.stringValue ?? ""
        limits = v["limits"]
    }

    static func adapterLabel(_ id: String) -> String {
        switch id {
        case "uitars_v1": return "UI-TARS v1"
        case "fixture_json_v1": return "测试夹具（仅测试）"
        default: return id
        }
    }

    static func coordinateLabel(_ id: String) -> String {
        switch id {
        case "normalized_1000": return "0–1000 归一化"
        case "image_pixels": return "截图像素"
        default: return id
        }
    }
}

enum AIEvidence {
    /// What a model's test proved, in words. Evidence taken at an older
    /// connection revision is shown as stale, never as current.
    static func status(_ mp: AIModelProfileItem?, connectionRevision: Int?) -> StatusText {
        guard let mp else { return StatusText("没有模型配置", .idle) }
        let e = mp.evidence
        if e.values.contains("failed") { return StatusText("测试未通过", .danger) }
        if e["guiContract"] == "verified" && e["imageInput"] == "verified" {
            if let cr = connectionRevision, let er = mp.evidenceConnectionRevision, cr != er {
                return StatusText("证据已过期", .attention)
            }
            return StatusText("图像 / GUI 已验证", .running)
        }
        if e.values.contains("verified") { return StatusText("部分验证", .attention) }
        return StatusText("尚未测试", .idle)
    }

    static func note(_ mp: AIModelProfileItem?, connectionRevision: Int?) -> String {
        guard let mp else { return "在 GUI 配置里选择模型" }
        let s = status(mp, connectionRevision: connectionRevision).text
        switch s {
        case "图像 / GUI 已验证": return "合成测试 · 只代表合成素材"
        case "证据已过期": return "连接已修改，需要重新测试"
        case "测试未通过": return "见能力测试的分层结果"
        default: return "模型列出 ≠ GUI 可用"
        }
    }
}

/// A Settings content panel: title, an optional line under it, an optional
/// action on the right, then the content.
struct SettingsCard<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let trailing: Trailing
    let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                    if let subtitle { Text(subtitle).font(ADFont.note).foregroundStyle(ADColor.muted) }
                }
                Spacer()
                trailing
            }
            .padding(.horizontal, ADSpace.l).frame(minHeight: 54)
            Rectangle().fill(ADColor.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .adPanel()
    }
}

extension SettingsCard where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// A note with a light-bulb, for what a number or a button does not mean.
struct SettingsNote: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: ADSpace.m) {
            Image(systemName: "lightbulb").foregroundStyle(ADColor.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ADFont.noteStrong).foregroundStyle(ADColor.primary)
                Text(detail).font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ADSpace.l)
        .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(ADColor.canvas))
        .overlay(RoundedRectangle(cornerRadius: ADRadius.panel).stroke(ADColor.line))
    }
}

/// A labelled form field with its hint or error under it.
struct SettingsField<Control: View>: View {
    let label: String
    let hint: String?
    let error: String?
    let control: Control

    init(_ label: String, hint: String? = nil, error: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.error = error
        self.control = control()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(label).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
            control.textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(ADFont.note).foregroundStyle(StatusTone.danger.foreground)
                    .accessibilityLabel("\(label)：\(error)")
            } else if let hint {
                Text(hint).font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A confirmation the user must answer before a delete or a disable.
struct SettingsConfirmation: Identifiable, Equatable {
    enum Action: Equatable { case disableConnection, deleteConnection, disableProfile, deleteProfile }
    let action: Action
    let id: String
    let name: String

    var title: String {
        switch action {
        case .disableConnection: return "停用「\(name)」？"
        case .deleteConnection: return "删除「\(name)」？"
        case .disableProfile: return "停用「\(name)」？"
        case .deleteProfile: return "删除「\(name)」？"
        }
    }

    var message: String {
        switch action {
        case .disableConnection: return "停用后，新的 GUI 配置和能力测试不能再使用这条连接。"
        case .deleteConnection: return "删除后这条连接不再出现；仍有模型配置引用它时 Runtime 会拒绝删除。"
        case .disableProfile: return "停用后，新的 GUI 诊断不能再使用这个配置；如果它是默认配置，默认会被清空。"
        case .deleteProfile: return "删除后这个配置不再出现；如果它是默认配置，默认会被清空。"
        }
    }

    var consequences: [String] {
        switch action {
        case .disableConnection: return ["新的配置与测试不能选择它"]
        case .deleteConnection: return ["连接与其凭据引用被删除，无法恢复"]
        case .disableProfile: return ["新的诊断不能选择它"]
        case .deleteProfile: return ["配置被删除，无法恢复"]
        }
    }

    var preserved: [String] {
        ["已开始的运行保留它开始时的配置快照", "不影响外部 Agent，也不改动任何 Desktop"]
    }

    var confirmTitle: String {
        switch action {
        case .disableConnection, .disableProfile: return "停用"
        case .deleteConnection, .deleteProfile: return "删除"
        }
    }
}

/// Dims what is behind and centres a dialog over it.
struct SettingsModal<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            content
        }
    }
}

/// A side drawer from the right edge (P24), over a dimmed page.
struct SettingsDrawer<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    let close: () -> Void
    let content: Content
    let footer: Footer

    init(title: String, subtitle: String, close: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.close = close
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: ADSpace.xs) {
                        Text(title).font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                        Text(subtitle).font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("关闭")
                        .keyboardShortcut(.cancelAction)
                }
                .padding(ADSpace.xl)
                Rectangle().fill(ADColor.line).frame(height: 1)
                ScrollView { VStack(alignment: .leading, spacing: ADSpace.l) { content }.padding(ADSpace.xl) }
                Rectangle().fill(ADColor.line).frame(height: 1)
                HStack(spacing: ADSpace.s) { Spacer(); footer }.padding(ADSpace.l)
            }
            .frame(width: 520)
            .frame(maxHeight: .infinity)
            .background(ADColor.panel)
            .shadow(color: .black.opacity(0.12), radius: 18, x: -4)
        }
    }
}

/// A table header cell and row layout shared by the lists.
struct SettingsTableHeader: View {
    let columns: [(String, CGFloat?)]

    var body: some View {
        HStack(spacing: ADSpace.m) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted)
                    .frame(width: c.1, alignment: .leading)
                    .frame(maxWidth: c.1 == nil ? .infinity : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, ADSpace.l).frame(height: 42)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// Settings dates: ISO 8601 with the local offset, as the contract wants.
enum SettingsTime {
    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}
