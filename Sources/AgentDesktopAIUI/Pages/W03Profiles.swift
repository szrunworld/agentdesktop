import AgentDesktopContracts
import Foundation
import SwiftUI

public struct ModelProfileRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let modelId: String
    public let revision: Int
    public let connectionId: String
    public let connectionRevision: Int
    public let enabled: Bool
    public let imageEvidence: String
    public let guiEvidence: String

    init(_ v: JSONValue) {
        id = v["modelProfileId"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        modelId = v["modelId"]?.stringValue ?? ""
        revision = v["revision"]?.intValue ?? 0
        connectionId = v["connectionId"]?.stringValue ?? ""
        connectionRevision = v["connectionRevision"]?.intValue ?? 0
        enabled = v["state"]?.stringValue == "enabled"
        imageEvidence = v["capabilities"]?["imageInput"]?["status"]?.stringValue ?? "unknown"
        guiEvidence = v["capabilities"]?["guiContract"]?["status"]?.stringValue ?? "unknown"
    }
}

public struct GuiProfileRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let revision: Int
    public let enabled: Bool
    public let adapterId: String
    public let coordinateProtocol: String
    public let modelProfileId: String
    public let modelProfileRevision: Int
    public var testOnly: Bool { adapterId == "fixture_json_v1" }

    init(_ v: JSONValue) {
        id = v["guiProfileId"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        revision = v["revision"]?.intValue ?? 0
        enabled = v["state"]?.stringValue == "enabled"
        adapterId = v["adapterId"]?.stringValue ?? ""
        coordinateProtocol = v["coordinateProtocol"]?.stringValue ?? ""
        modelProfileId = v["modelProfileId"]?.stringValue ?? ""
        modelProfileRevision = v["modelProfileRevision"]?.intValue ?? 0
    }
}

/// Server ceilings (spec §09.1). A profile may only tighten them.
public struct LimitsDraft: Equatable, Sendable {
    public static let ceiling = LimitsDraft()
    public var maxSteps = 20
    public var maxWallTimeMs = 120_000
    public var maxModelAttemptsPerStep = 2
    public var maxTotalModelAttempts = 30
    public var maxOutputTokens = 1024
    public var maxWaitMs = 5000
    public var maxScreenshots = 5
    public var maxImageEncodedBytes = 8_388_608
    public var requireReportedUsage = false

    var json: JSONValue {
        .obj([("maxSteps", .int(maxSteps)), ("maxWallTimeMs", .int(maxWallTimeMs)),
              ("maxModelAttemptsPerStep", .int(maxModelAttemptsPerStep)), ("maxTotalModelAttempts", .int(maxTotalModelAttempts)),
              ("maxOutputTokens", .int(maxOutputTokens)), ("maxWaitMs", .int(maxWaitMs)), ("maxScreenshots", .int(maxScreenshots)),
              ("maxImageEncodedBytes", .int(maxImageEncodedBytes)), ("requireReportedUsage", .bool(requireReportedUsage))])
    }

    func errors() -> [String: String] {
        var e: [String: String] = [:]
        let c = Self.ceiling
        func check(_ k: String, _ v: Int, _ lo: Int, _ hi: Int) { if v < lo || v > hi { e[k] = "\(k) 需在 \(lo)–\(hi) 之间（服务端上限 \(hi)，只能调低）" } }
        check("maxSteps", maxSteps, 1, c.maxSteps)
        check("maxWallTimeMs", maxWallTimeMs, 1000, c.maxWallTimeMs)
        check("maxModelAttemptsPerStep", maxModelAttemptsPerStep, 1, c.maxModelAttemptsPerStep)
        check("maxTotalModelAttempts", maxTotalModelAttempts, 1, c.maxTotalModelAttempts)
        check("maxOutputTokens", maxOutputTokens, 1, c.maxOutputTokens)
        check("maxWaitMs", maxWaitMs, 0, c.maxWaitMs)
        check("maxScreenshots", maxScreenshots, 1, c.maxScreenshots)
        check("maxImageEncodedBytes", maxImageEncodedBytes, 1, c.maxImageEncodedBytes)
        return e
    }
}

/// W03 — GUI 配置: GUI profiles, the model-profile sub-panel and the
/// default pointer, which has its own revision.
@MainActor
public final class ProfilesModel: ObservableObject {
    @Published public private(set) var profiles: [GuiProfileRow] = []
    @Published public private(set) var modelProfiles: [ModelProfileRow] = []
    @Published public private(set) var connections: [ConnectionRow] = []
    @Published public private(set) var defaultPointer: (revision: Int, guiProfileId: String?) = (0, nil)
    @Published public private(set) var phase: LoadPhase = .idle
    @Published public private(set) var problem: UIProblem?
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var notice: String?

    // GUI profile draft
    @Published public var editingProfileId: String?
    @Published public var name = "默认 GUI 配置"
    @Published public var modelProfileId: String?
    @Published public var adapterId = "uitars_v1"
    @Published public var coordinateProtocol = "normalized_1000"
    @Published public var limits = LimitsDraft()
    @Published public var fallbackProfileId: String?

    // Model profile sub-panel draft
    @Published public var mpName = ""
    @Published public var mpConnectionId: String?
    @Published public var mpModelId = ""
    @Published public var mpTemperature: Double?
    @Published public var mpSeed: Int?
    @Published public var mpMaxOutputTokens = 1024

    /// fixture_json_v1 appears only where the service allows it, marked test only.
    public let allowFixtureAdapter: Bool
    let client: ContractClient
    private var profileKey = SubmissionKey()
    private var modelKey = SubmissionKey()
    private var defaultKey = SubmissionKey()

    public init(client: ContractClient, allowFixtureAdapter: Bool = false) {
        self.client = client
        self.allowFixtureAdapter = allowFixtureAdapter
    }

    public var adapters: [(id: String, label: String)] {
        var a = [("uitars_v1", "UI-TARS v1")]
        if allowFixtureAdapter { a.append(("fixture_json_v1", "测试夹具（仅测试，不能启动真实运行）")) }
        return a
    }

    public func refresh() async {
        phase = .loading
        do {
            async let p = client.send("ai.profiles.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            async let m = client.send("ai.modelProfiles.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            async let c = client.send("ai.connections.list", .obj([("limit", .int(100))]))
            async let d = client.send("ai.profiles.default.get")
            let (pv, mv, cv, dv) = try await (p, m, c, d)
            profiles = (pv["items"]?.arrayValue ?? []).map(GuiProfileRow.init)
            modelProfiles = (mv["items"]?.arrayValue ?? []).map(ModelProfileRow.init)
            connections = (cv["items"]?.arrayValue ?? []).map(ConnectionRow.init)
            defaultPointer = (dv["default"]?["revision"]?.intValue ?? 0, dv["default"]?["guiProfileId"]?.stringValue)
            if modelProfileId == nil { modelProfileId = modelProfiles.first(where: \.enabled)?.id }
            if mpConnectionId == nil { mpConnectionId = connections.first(where: \.enabled)?.id }
            problem = nil
            phase = .loaded
        } catch {
            problem = UIProblem(error)
            phase = .failed
        }
    }

    public func defaultLabel(for row: GuiProfileRow) -> String? {
        row.id == defaultPointer.guiProfileId ? "默认（指针 d\(defaultPointer.revision)）" : nil
    }

    public func edit(_ row: GuiProfileRow) {
        editingProfileId = row.id
        name = row.name
        modelProfileId = row.modelProfileId
        adapterId = row.adapterId
        coordinateProtocol = row.coordinateProtocol
        profileKey.reset()
    }

    public func newProfile() {
        editingProfileId = nil
        name = "默认 GUI 配置"
        adapterId = "uitars_v1"
        coordinateProtocol = "normalized_1000"
        limits = LimitsDraft()
        fallbackProfileId = nil
        profileKey.reset()
    }

    /// Saves a new GUI profile revision; existing runs keep their snapshot.
    public func saveProfile() async {
        notice = nil
        var errors = limits.errors()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.count > 80 { errors["name"] = "名称不能为空，最长 80 个字符" }
        guard let mpId = modelProfileId, let mp = modelProfiles.first(where: { $0.id == mpId }) else {
            errors["modelProfile"] = "请选择一个模型配置"
            fieldErrors = errors
            return
        }
        if !mp.enabled { errors["modelProfile"] = "模型配置已停用，不能用于新的配置" }
        if adapterId == "fixture_json_v1" && !allowFixtureAdapter { errors["adapter"] = "测试夹具适配器不能用于生产配置" }
        if let f = fallbackProfileId, f == editingProfileId { errors["fallback"] = "备用配置不能引用自身" }
        fieldErrors = errors
        guard errors.isEmpty else { return }
        let codec: (String, String) = adapterId == "uitars_v1" ? ("uitars-prompt-1", "uitars-parser-1") : ("fixture-prompt-1", "fixture-parser-1")
        var fallback: [JSONValue] = []
        if let f = fallbackProfileId, let row = profiles.first(where: { $0.id == f }) {
            fallback = [.obj([("guiProfileId", .string(row.id)), ("revision", .int(row.revision))])]
        }
        let body: [(String, JSONValue)] = [
            ("name", .string(trimmed)), ("modelProfileId", .string(mp.id)), ("modelProfileRevision", .int(mp.revision)),
            ("adapterId", .string(adapterId)), ("adapterVersion", .string("1.0.0")),
            ("promptVersion", .string(codec.0)), ("parserVersion", .string(codec.1)),
            ("coordinateProtocol", .string(coordinateProtocol)), ("limits", limits.json),
            ("allowedFallbackProfileRefs", .array(fallback)),
        ]
        do {
            let saved: JSONValue
            if let id = editingProfileId, let row = profiles.first(where: { $0.id == id }) {
                let params = JSONValue.obj([("guiProfileId", .string(id)), ("expectedRevision", .int(row.revision)), ("patch", .obj(body))])
                saved = try await client.send("ai.profiles.update", params, idempotencyKey: profileKey.key(for: params, prefix: "w03-profile"))
            } else {
                let params = JSONValue.obj(body)
                saved = try await client.send("ai.profiles.create", params, idempotencyKey: profileKey.key(for: params, prefix: "w03-profile"))
            }
            profileKey.reset()
            editingProfileId = saved["guiProfileId"]?.stringValue
            notice = "已保存 GUI 配置 r\(saved["revision"]?.intValue ?? 0)。只对新任务生效，已开始的运行不变。"
            problem = nil
            await refresh()
        } catch {
            problem = UIProblem(error)
        }
    }

    /// Model-profile sub-panel: pins the connection revision it was made with.
    public func saveModelProfile() async {
        notice = nil
        guard let cid = mpConnectionId, let conn = connections.first(where: { $0.id == cid }) else {
            fieldErrors = ["mpConnection": "请选择连接"]
            return
        }
        var errors: [String: String] = [:]
        if mpName.trimmingCharacters(in: .whitespaces).isEmpty { errors["mpName"] = "名称不能为空" }
        if mpModelId.trimmingCharacters(in: .whitespaces).isEmpty { errors["mpModelId"] = "模型 ID 不能为空" }
        if !(1...1024).contains(mpMaxOutputTokens) { errors["mpMaxOutputTokens"] = "输出上限需在 1–1024 之间" }
        fieldErrors = errors
        guard errors.isEmpty else { return }
        var options: [(String, JSONValue)] = []
        if let t = mpTemperature { options.append(("temperature", .double(t))) }
        if let s = mpSeed { options.append(("seed", .int(s))) }
        let params = JSONValue.obj([
            ("name", .string(mpName.trimmingCharacters(in: .whitespaces))), ("connectionId", .string(conn.id)),
            ("connectionRevision", .int(conn.revision)), ("modelId", .string(mpModelId.trimmingCharacters(in: .whitespaces))),
            ("requestOptions", .obj(options)), ("maxOutputTokens", .int(mpMaxOutputTokens)),
        ])
        do {
            let mp = try await client.send("ai.modelProfiles.create", params, idempotencyKey: modelKey.key(for: params, prefix: "w03-model"))
            modelKey.reset()
            await refresh()
            modelProfileId = mp["modelProfileId"]?.stringValue
            notice = "已保存模型配置 r\(mp["revision"]?.intValue ?? 0)，请在 GUI 配置中明确选择它。"
        } catch {
            problem = UIProblem(error)
        }
    }

    /// Only moves the default pointer, with its own expected revision.
    public func setDefault(_ row: GuiProfileRow) async {
        let params = JSONValue.obj([("guiProfileId", .string(row.id)), ("expectedDefaultRevision", .int(defaultPointer.revision)),
                                    ("expectedProfileRevision", .int(row.revision))])
        do {
            let r = try await client.send("ai.profiles.setDefault", params, idempotencyKey: defaultKey.key(for: params, prefix: "w03-default"))
            defaultKey.reset()
            defaultPointer = (r["default"]?["revision"]?.intValue ?? 0, r["default"]?["guiProfileId"]?.stringValue)
            notice = "默认指针已更新为 d\(defaultPointer.revision)。只对之后新建的运行生效。"
            problem = nil
        } catch {
            problem = UIProblem(error)
        }
    }

    public func disable(_ row: GuiProfileRow) async {
        let params = JSONValue.obj([("guiProfileId", .string(row.id)), ("expectedRevision", .int(row.revision))])
        do {
            _ = try await client.send("ai.profiles.disable", params, idempotencyKey: "w03-disable-\(row.id)-r\(row.revision)")
            await refresh()
        } catch { problem = UIProblem(error) }
    }

    public func delete(_ row: GuiProfileRow) async {
        let params = JSONValue.obj([("guiProfileId", .string(row.id)), ("expectedRevision", .int(row.revision))])
        do {
            _ = try await client.send("ai.profiles.delete", params, idempotencyKey: "w03-delete-\(row.id)-r\(row.revision)")
            await refresh()
        } catch { problem = UIProblem(error) }
    }
}

public struct ProfilesView: View {
    @ObservedObject var model: ProfilesModel
    var onTest: (String) -> Void
    var onRun: (String) -> Void

    public init(model: ProfilesModel, onTest: @escaping (String) -> Void = { _ in }, onRun: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onTest = onTest
        self.onRun = onRun
    }

    public var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("GUI 配置").font(.title2).bold().accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("新建") { model.newProfile() }
                }
                Text("默认指针 d\(model.defaultPointer.revision)").font(.caption).foregroundStyle(.secondary)
                List(model.profiles, selection: Binding(get: { model.editingProfileId }, set: { id in
                    if let r = model.profiles.first(where: { $0.id == id }) { model.edit(r) }
                })) { r in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(r.name).bold()
                            if let d = model.defaultLabel(for: r) { Text(d).font(.caption).padding(2).background(Color.green.opacity(0.15)) }
                        }
                        Text("GUI 配置 r\(r.revision) · \(r.enabled ? "已启用" : "已停用")\(r.testOnly ? " · 仅测试" : "")").font(.caption)
                    }
                    .tag(r.id)
                    .contextMenu {
                        Button("设为默认") { Task { await model.setDefault(r) } }.disabled(!r.enabled || r.testOnly)
                        Button("测试") { onTest(r.id) }
                        Button("启动诊断运行") { onRun(r.id) }.disabled(!r.enabled || r.testOnly)
                        Button("停用") { Task { await model.disable(r) } }
                        Button("删除", role: .destructive) { Task { await model.delete(r) } }
                    }
                }
            }
            .frame(minWidth: 260)
            Form {
                if let p = model.problem { ProblemBanner(problem: p) }
                if let n = model.notice { Text(n).foregroundStyle(.green) }
                Section("GUI 配置") {
                    TextField("名称", text: $model.name)
                    Picker("模型配置", selection: $model.modelProfileId) {
                        ForEach(model.modelProfiles) { m in
                            Text("\(m.name) · \(m.modelId) · r\(m.revision) · 图像 \(m.imageEvidence) / GUI \(m.guiEvidence)")
                                .tag(Optional(m.id)).disabled(!m.enabled)
                        }
                    }
                    Picker("GUI 适配器", selection: $model.adapterId) {
                        ForEach(model.adapters, id: \.id) { a in Text(a.label).tag(a.id) }
                    }
                    Picker("坐标协议", selection: $model.coordinateProtocol) {
                        Text("normalized_1000").tag("normalized_1000")
                        Text("image_pixels").tag("image_pixels")
                    }
                    Picker("备用 GUI 配置", selection: $model.fallbackProfileId) {
                        Text("无").tag(String?.none)
                        ForEach(model.profiles.filter { $0.id != model.editingProfileId && $0.enabled }) { r in Text("\(r.name) r\(r.revision)").tag(Optional(r.id)) }
                    }
                }
                Section("预算（只能调低，不能超过服务端上限）") {
                    Stepper("决策步数 \(model.limits.maxSteps) / 20", value: $model.limits.maxSteps, in: 1...20)
                    Stepper("总时长 \(model.limits.maxWallTimeMs / 1000) 秒 / 120", value: $model.limits.maxWallTimeMs, in: 1000...120_000, step: 1000)
                    Stepper("每步模型尝试 \(model.limits.maxModelAttemptsPerStep) / 2", value: $model.limits.maxModelAttemptsPerStep, in: 1...2)
                    Stepper("全程模型尝试 \(model.limits.maxTotalModelAttempts) / 30", value: $model.limits.maxTotalModelAttempts, in: 1...30)
                    Stepper("单次输出 token \(model.limits.maxOutputTokens) / 1024", value: $model.limits.maxOutputTokens, in: 1...1024, step: 64)
                    Stepper("单次等待 \(model.limits.maxWaitMs) ms / 5000", value: $model.limits.maxWaitMs, in: 0...5000, step: 500)
                    LabeledValue(label: "截图数量 / 总编码体积", value: "5 / 8 MiB（只读上限）")
                    Toggle("缺少用量报告时停止下一次尝试（不是账单硬上限）", isOn: $model.limits.requireReportedUsage)
                }
                ForEach(model.fieldErrors.sorted(by: { $0.key < $1.key }), id: \.key) { e in Text(e.value).foregroundStyle(.red).font(.caption) }
                Button("保存 GUI 配置") { Task { await model.saveProfile() } }.keyboardShortcut(.defaultAction)
                DisclosureGroup("编辑模型配置") {
                    TextField("名称", text: $model.mpName)
                    Picker("连接", selection: $model.mpConnectionId) {
                        ForEach(model.connections) { c in Text("\(c.name) r\(c.revision)").tag(Optional(c.id)) }
                    }
                    TextField("模型 ID", text: $model.mpModelId)
                    Stepper("输出 token 上限 \(model.mpMaxOutputTokens)", value: $model.mpMaxOutputTokens, in: 1...1024, step: 64)
                    Button("保存模型配置") { Task { await model.saveModelProfile() } }
                }
            }
            .padding()
        }
        .task { if model.phase == .idle { await model.refresh() } }
    }
}
