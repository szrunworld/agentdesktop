import AgentDesktopProtocol
import Foundation
import SwiftUI

/// W05 — 启动 GUI 诊断运行.
@MainActor
public final class RunStartModel: ObservableObject {
    public nonisolated static let neutralGoal = "在指定中立表单的姓名中输入 Ada，然后点击应用"
    public nonisolated static let neutralExpected = "已保存：Ada / MAC-001-A / 提交次数 1"

    @Published public var desktopId = ""
    @Published public var guiProfileId: String?
    @Published public var goal = RunStartModel.neutralGoal
    @Published public var expectedText = RunStartModel.neutralExpected
    @Published public var allowedActions: Set<String> = ["click", "type"]
    @Published public private(set) var profiles: [GuiProfileRow] = []
    @Published public private(set) var supportedActions: [String] = []
    @Published public private(set) var predicates: [String] = []
    @Published public private(set) var isolationEvidence = "NOT_RUN"
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var problem: UIProblem?
    @Published public private(set) var summary: String?
    @Published public private(set) var starting = false
    /// Set once the service accepted the run; the page moves to W06.
    @Published public private(set) var startedRunId: String?

    let client: ContractClient
    private var startKey = SubmissionKey()

    public init(client: ContractClient, guiProfileId: String? = nil) {
        self.client = client
        self.guiProfileId = guiProfileId
    }

    /// Read-only: capabilities and enabled, non-fixture profiles.
    public func load() async {
        do {
            let caps = try await client.guiCapabilities()
            supportedActions = caps["actions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            predicates = caps["verificationPredicates"]?.arrayValue?.compactMap(\.stringValue) ?? []
            isolationEvidence = caps["features"]?["nativeIsolationEvidence"]?.stringValue ?? "NOT_RUN"
            allowedActions = allowedActions.intersection(supportedActions)
            let p = try await client.send("ai.profiles.list", .obj([("limit", .int(100))]))
            profiles = (p["items"]?.arrayValue ?? []).map(GuiProfileRow.init).filter { $0.enabled && !$0.testOnly }
            if guiProfileId == nil || !profiles.contains(where: { $0.id == guiProfileId }) {
                let d = try await client.send("ai.profiles.default.get")
                guiProfileId = d["default"]?["guiProfileId"]?.stringValue ?? profiles.first?.id
            }
            problem = nil
        } catch { problem = UIProblem(error) }
    }

    func params() -> JSONValue? {
        var errors: [String: String] = [:]
        let d = desktopId.trimmingCharacters(in: .whitespaces)
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { errors["desktop"] = "请选择 Desktop" }
        if g.isEmpty || g.count > 4096 { errors["goal"] = "任务描述不能为空，最长 4096 个字符" }
        if t.isEmpty || t.count > 1024 { errors["verification"] = "完成条件不能为空，最长 1024 个字符" }
        if allowedActions.isEmpty { errors["actions"] = "至少允许一种动作" }
        if !predicates.contains("element_text_equals") { errors["verification"] = "当前执行后端不支持静态文字完成条件" }
        let profile = profiles.first(where: { $0.id == guiProfileId })
        if profile == nil { errors["profile"] = "请选择已启用的 GUI 配置（测试夹具配置不可用于真实运行）" }
        fieldErrors = errors
        guard errors.isEmpty, let profile else { return nil }
        let order = ["click", "type", "key", "scroll"]
        return .obj([
            ("desktopId", .string(d)), ("guiProfileId", .string(profile.id)), ("expectedProfileRevision", .int(profile.revision)),
            ("goal", .string(g)),
            ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")), ("text", .string(t))])),
            ("allowedActions", .array(order.filter(allowedActions.contains).map(JSONValue.string))),
        ])
    }

    /// Checks locally and reads only; no model call, no run, no input.
    public func validateOnly() async {
        summary = nil
        guard params() != nil, let id = guiProfileId else { return }
        do {
            let p = try await client.send("ai.profiles.get", .obj([("guiProfileId", .string(id))]))
            summary = "将绑定 GUI 配置 r\(p["revision"]?.intValue ?? 0)、模型配置 r\(p["modelProfileRevision"]?.intValue ?? 0)、适配器 \(p["adapterId"]?.stringValue ?? "")；预算 \(p["limits"]?["maxSteps"]?.intValue ?? 0) 步、\((p["limits"]?["maxWallTimeMs"]?.intValue ?? 0) / 1000) 秒；用量可能未知。"
            problem = nil
        } catch { problem = UIProblem(error) }
    }

    /// One logical start: double clicks or a retry reuse the same key.
    public func start() async {
        guard !starting, let params = params() else { return }
        starting = true
        defer { starting = false }
        do {
            let r = try await client.send("gui.runs.start", params, idempotencyKey: startKey.key(for: params, prefix: "w05-run"))
            startedRunId = r["runId"]?.stringValue
            problem = nil
        } catch let e as ContractError where e.code == .idempotencyConflict {
            problem = UIProblem(e)
        } catch {
            problem = UIProblem(error)
        }
    }

    /// After a finished run, a new start is a new submission.
    public func prepareNew() {
        startKey.reset()
        startedRunId = nil
    }
}

public struct RunStartView: View {
    @ObservedObject var model: RunStartModel
    var onStarted: (String) -> Void

    public init(model: RunStartModel, onStarted: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onStarted = onStarted
    }

    public var body: some View {
        Form {
            Text("启动 GUI 诊断运行").font(.title2).bold().accessibilityAddTraits(.isHeader)
            if let p = model.problem { ProblemBanner(problem: p) }
            if model.isolationEvidence != "VERIFIED" {
                Text("当前执行后端的原生隔离证据：\(model.isolationEvidence)。").font(.caption)
            }
            TextField("Desktop", text: $model.desktopId)
            Picker("GUI 配置", selection: $model.guiProfileId) {
                ForEach(model.profiles) { p in Text("\(p.name) r\(p.revision)").tag(Optional(p.id)) }
            }
            TextField("任务描述", text: $model.goal, axis: .vertical)
            TextField("完成条件（静态文字，逐字匹配）", text: $model.expectedText)
            Section("允许的动作") {
                ForEach(model.supportedActions, id: \.self) { a in
                    Toggle(a, isOn: Binding(get: { model.allowedActions.contains(a) },
                                            set: { if $0 { model.allowedActions.insert(a) } else { model.allowedActions.remove(a) } }))
                }
            }
            ForEach(model.fieldErrors.sorted(by: { $0.key < $1.key }), id: \.key) { e in Text(e.value).foregroundStyle(.red).font(.caption) }
            if let s = model.summary { Text(s).font(.callout) }
            HStack {
                Button("仅验证") { Task { await model.validateOnly() } }
                Button("开始诊断") { Task { await model.start() } }.disabled(model.starting).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .task { await model.load() }
        .onChange(of: model.startedRunId) { _, id in if let id { onStarted(id) } }
    }
}
