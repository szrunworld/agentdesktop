import AgentDesktopProtocol
import SwiftUI

// Lane UI-D (U6): P25 GUI 配置. A GUI profile pins a model profile (a model
// on a connection, at the revisions it was made with), the adapter and the
// bounded limits. Saving makes a new revision; runs already started keep
// their snapshot. The default pointer has its own revision.

@MainActor
final class SettingsProfilesModel: ObservableObject {
    @Published private(set) var profiles: [AIGuiProfileItem] = []
    @Published private(set) var modelProfiles: [AIModelProfileItem] = []
    @Published private(set) var connections: [AIConnectionItem] = []
    @Published private(set) var defaultRevision = 0
    @Published private(set) var defaultId: String?
    @Published private(set) var loaded = false
    @Published private(set) var failure: SettingsFailure?
    @Published private(set) var fieldErrors: [String: String] = [:]
    @Published private(set) var notice: String?
    @Published private(set) var saving = false

    /// nil: a new profile.
    @Published private(set) var selectedId: String?
    @Published var name = "默认 GUI 配置"
    /// requestIds of creates whose answer has not arrived (idempotency).
    private var pendingCreateId: String?
    private var pendingModelCreateIds: [String: String] = [:]
    @Published var connectionId: String?
    @Published var modelId = ""
    @Published var adapterId = "uitars_v1"
    @Published var coordinateProtocol = "normalized_1000"

    let runtime: RuntimePort
    /// runtime.capabilities `gui` (absent while the AI service is not running).
    var gui: JSONValue?

    init(runtime: RuntimePort, gui: JSONValue?) {
        self.runtime = runtime
        self.gui = gui
    }

    /// fixture_json_v1 is offered only where the backend allows it.
    var adapters: [String] {
        var a = ["uitars_v1"]
        if gui?["features"]?["fixtureAdapterEnabled"]?.boolValue == true { a.append("fixture_json_v1") }
        return a
    }

    var selected: AIGuiProfileItem? { profiles.first { $0.id == selectedId } }

    func modelProfile(of p: AIGuiProfileItem) -> AIModelProfileItem? { modelProfiles.first { $0.id == p.modelProfileId } }

    func refresh() async {
        do {
            let p = try await runtime.call("ai.profiles.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            let m = try await runtime.call("ai.modelProfiles.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            let c = try await runtime.call("ai.connections.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            let d = try await runtime.call("ai.profiles.default.get")
            profiles = (p["items"]?.arrayValue ?? []).map(AIGuiProfileItem.init)
            modelProfiles = (m["items"]?.arrayValue ?? []).map(AIModelProfileItem.init)
            connections = (c["items"]?.arrayValue ?? []).map(AIConnectionItem.init)
            defaultRevision = d["default"]?["revision"]?.intValue ?? 0
            defaultId = d["default"]?["guiProfileId"]?.stringValue
            if !loaded {
                if let first = profiles.first(where: { $0.id == defaultId }) ?? profiles.first { select(first) } else { newProfile() }
            } else if let id = selectedId, let still = profiles.first(where: { $0.id == id }) {
                select(still)
            }
            loaded = true
            failure = nil
        } catch {
            failure = SettingsFailure(error)
        }
    }

    func select(_ p: AIGuiProfileItem) {
        selectedId = p.id
        name = p.name
        adapterId = p.adapterId
        coordinateProtocol = p.coordinateProtocol
        let mp = modelProfile(of: p)
        connectionId = mp?.connectionId
        modelId = mp?.modelId ?? ""
        fieldErrors = [:]
    }

    func newProfile() {
        selectedId = nil
        name = profiles.isEmpty ? "默认 GUI 配置" : "新 GUI 配置"
        adapterId = "uitars_v1"
        coordinateProtocol = "normalized_1000"
        connectionId = connections.first(where: \.enabled)?.id
        modelId = ""
        fieldErrors = [:]
    }

    /// Saves the draft: finds or makes the model profile, then creates the
    /// GUI profile or writes a new revision of the selected one.
    func save() async {
        notice = nil
        var e: [String: String] = [:]
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.count > 80 { e["name"] = "名称不能为空，最长 80 个字符" }
        let model = modelId.trimmingCharacters(in: .whitespaces)
        if model.isEmpty || model.count > 160 { e["modelId"] = "请填写模型 ID（最长 160 个字符）" }
        let conn = connections.first { $0.id == connectionId }
        if conn == nil { e["connection"] = "请选择一个 AI 连接" } else if conn?.enabled == false { e["connection"] = "连接已停用，不能用于新的配置" }
        if !adapters.contains(adapterId) { e["adapter"] = "这个适配器在当前后端不可用" }
        fieldErrors = e
        guard e.isEmpty, let conn else { return }
        saving = true
        defer { saving = false }
        do {
            let mp = try await modelProfileFor(connection: conn, modelId: model)
            let codec = adapterId == "uitars_v1" ? ("uitars-prompt-1", "uitars-parser-1") : ("fixture-prompt-1", "fixture-parser-1")
            let saved: JSONValue
            if let p = selected {
                var patch: [(String, JSONValue)] = []
                if p.name != n { patch.append(("name", .string(n))) }
                if p.modelProfileId != mp.id || p.modelProfileRevision != mp.revision {
                    patch.append(("modelProfileId", .string(mp.id)))
                    patch.append(("modelProfileRevision", .int(mp.revision)))
                }
                if p.adapterId != adapterId {
                    patch += [("adapterId", .string(adapterId)), ("promptVersion", .string(codec.0)), ("parserVersion", .string(codec.1))]
                }
                if p.coordinateProtocol != coordinateProtocol { patch.append(("coordinateProtocol", .string(coordinateProtocol))) }
                guard !patch.isEmpty else { notice = "没有需要保存的修改"; return }
                saved = try await runtime.call("ai.profiles.update", .obj([
                    ("guiProfileId", .string(p.id)), ("expectedRevision", .int(p.revision)), ("patch", .obj(patch)),
                ]))
            } else {
                let createId = pendingCreateId ?? RuntimeRequest.newId(prefix: "ui")
                pendingCreateId = createId
                saved = try await runtime.call("ai.profiles.create", .obj([
                    ("name", .string(n)), ("modelProfileId", .string(mp.id)), ("modelProfileRevision", .int(mp.revision)),
                    ("adapterId", .string(adapterId)), ("adapterVersion", .string("1.0.0")),
                    ("promptVersion", .string(codec.0)), ("parserVersion", .string(codec.1)),
                    ("coordinateProtocol", .string(coordinateProtocol)), ("limits", limits),
                    ("allowedFallbackProfileRefs", .array([])),
                ]), requestId: createId)
                pendingCreateId = nil
            }
            selectedId = saved["guiProfileId"]?.stringValue
            failure = nil
            notice = "已保存 GUI 配置 r\(saved["revision"]?.intValue ?? 0)。只对新的诊断生效，已开始的运行不变。"
            await refresh()
        } catch {
            failure = SettingsFailure(error)
        }
    }

    /// The limits a new profile starts with: the backend's ceilings.
    var limits: JSONValue {
        if let l = gui?["limits"], l.objectMembers != nil { return l }
        return .obj([
            ("maxSteps", .int(20)), ("maxWallTimeMs", .int(120_000)), ("maxModelAttemptsPerStep", .int(2)),
            ("maxTotalModelAttempts", .int(30)), ("maxOutputTokens", .int(1024)), ("maxWaitMs", .int(5000)),
            ("maxScreenshots", .int(5)), ("maxImageEncodedBytes", .int(8_388_608)), ("requireReportedUsage", .bool(false)),
        ])
    }

    /// An enabled model profile for this model on this connection at its
    /// current revision; made when there is none.
    private func modelProfileFor(connection c: AIConnectionItem, modelId: String) async throws -> AIModelProfileItem {
        if let mp = modelProfiles.first(where: { $0.enabled && $0.connectionId == c.id && $0.modelId == modelId && $0.connectionRevision == c.revision }) {
            return mp
        }
        let key = "\(c.id)@\(c.revision)/\(modelId)"
        let createId = pendingModelCreateIds[key] ?? RuntimeRequest.newId(prefix: "ui")
        pendingModelCreateIds[key] = createId
        let created = try await runtime.call("ai.modelProfiles.create", .obj([
            ("name", .string(modelId)), ("connectionId", .string(c.id)), ("connectionRevision", .int(c.revision)),
            ("modelId", .string(modelId)), ("requestOptions", .obj([])), ("maxOutputTokens", .int(1024)),
        ]), requestId: createId)
        pendingModelCreateIds[key] = nil
        let item = AIModelProfileItem(created)
        modelProfiles.append(item)
        return item
    }

    func setDefault(_ p: AIGuiProfileItem) async {
        await write(.obj([("guiProfileId", .string(p.id)), ("expectedDefaultRevision", .int(defaultRevision)),
                          ("expectedProfileRevision", .int(p.revision))]), "ai.profiles.setDefault",
                    done: "「\(p.name)」已设为默认。只影响之后的新运行。")
    }

    func disable(_ p: AIGuiProfileItem) async {
        await write(.obj([("guiProfileId", .string(p.id)), ("expectedRevision", .int(p.revision))]), "ai.profiles.disable",
                    done: "已停用「\(p.name)」。")
    }

    func delete(_ p: AIGuiProfileItem) async {
        await write(.obj([("guiProfileId", .string(p.id)), ("expectedRevision", .int(p.revision))]), "ai.profiles.delete",
                    done: "已删除「\(p.name)」。")
        if selectedId == p.id { selectedId = nil; newProfile() }
    }

    private func write(_ params: JSONValue, _ method: String, done: String) async {
        notice = nil
        saving = true
        defer { saving = false }
        do {
            _ = try await runtime.call(method, params)
            failure = nil
            notice = done
            await refresh()
        } catch {
            failure = SettingsFailure(error)
        }
    }
}

struct SettingsProfilesPage: View {
    @ObservedObject var model: SettingsProfilesModel
    let onTest: (AIGuiProfileItem) -> Void
    let onDiagnose: () -> Void
    let onConnections: () -> Void
    let confirm: (SettingsConfirmation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            if let f = model.failure { SettingsFailureView(failure: f, retry: { Task { await model.refresh() } }) }
            if let n = model.notice { Text(n).font(ADFont.note).foregroundStyle(ADColor.primary) }
            HStack(alignment: .top, spacing: ADSpace.l) {
                list.frame(width: 234)
                VStack(alignment: .leading, spacing: ADSpace.l) {
                    editor
                    limits
                    SettingsNote(title: "只建议，不直接输入",
                                 detail: "GuiAiProvider 返回动作建议，Runtime 验证目标和控制权后执行。配置测试也不会操作真实桌面。")
                    HStack(spacing: ADSpace.s) {
                        Button(action: onDiagnose) { Label("开始一次 GUI 诊断", systemImage: "play.fill") }
                            .buttonStyle(ADButtonStyle(.primary)).disabled(model.selected == nil)
                        Button("查看模型连接", action: onConnections).buttonStyle(ADButtonStyle(.secondary))
                    }
                }
            }
        }
        .task { if !model.loaded { await model.refresh() } }
    }

    var list: some View {
        SettingsCard(title: "配置", trailing: {
            Text("\(model.profiles.count)").font(ADFont.noteStrong).foregroundStyle(ADColor.muted)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).stroke(ADColor.line))
        }) {
            VStack(alignment: .leading, spacing: ADSpace.m) {
                ForEach(model.profiles) { p in card(p) }
                Button { model.newProfile() } label: { Label("新建配置", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(ADButtonStyle(.quiet))
            }
            .padding(ADSpace.l)
        }
    }

    func card(_ p: AIGuiProfileItem) -> some View {
        let on = model.selectedId == p.id
        let mp = model.modelProfile(of: p)
        return VStack(alignment: .leading, spacing: ADSpace.s) {
            HStack {
                Text(p.name).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                if model.defaultId == p.id { StateBadge("默认", tone: .running) }
                if !p.enabled { StateBadge("已停用", tone: .idle) }
            }
            Group {
                Text(mp?.modelId ?? "—")
                Text(AIGuiProfileItem.adapterLabel(p.adapterId))
                Text("配置版本 r\(p.revision)")
            }
            .font(ADFont.note).foregroundStyle(ADColor.muted)
            Button { onTest(p) } label: { Label("测试配置", systemImage: "checkmark").frame(maxWidth: .infinity) }
                .buttonStyle(ADButtonStyle(.secondary)).disabled(!p.enabled)
            HStack(spacing: ADSpace.xs) {
                if model.defaultId != p.id && p.enabled {
                    Button("设为默认") { Task { await model.setDefault(p) } }.buttonStyle(ADButtonStyle(.quiet))
                }
                Spacer()
                if p.enabled {
                    Button("停用") { confirm(SettingsConfirmation(action: .disableProfile, id: p.id, name: p.name)) }
                        .buttonStyle(ADButtonStyle(.quiet))
                }
                Button("删除") { confirm(SettingsConfirmation(action: .deleteProfile, id: p.id, name: p.name)) }
                    .buttonStyle(ADButtonStyle(.quiet))
            }
            .font(ADFont.note)
        }
        .padding(ADSpace.m)
        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(on ? ADColor.selected.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.select(p) }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var editor: some View {
        SettingsCard(title: model.selected == nil ? "新建：模型与输出协议" : "模型与输出协议") {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                HStack(alignment: .top, spacing: ADSpace.l) {
                    SettingsField("配置名称", error: model.fieldErrors["name"]) { TextField("配置名称", text: $model.name) }
                    SettingsField("AI 连接", error: model.fieldErrors["connection"]) {
                        Picker("AI 连接", selection: $model.connectionId) {
                            Text("请选择").tag(String?.none)
                            ForEach(model.connections) { c in
                                Text(c.enabled ? c.name : "\(c.name)（已停用）").tag(String?.some(c.id))
                            }
                        }
                        .labelsHidden()
                    }
                }
                HStack(alignment: .top, spacing: ADSpace.l) {
                    SettingsField("模型 ID", hint: "可手动填写；能力需要单独测试。", error: model.fieldErrors["modelId"]) {
                        TextField("模型 ID", text: $model.modelId)
                    }
                    SettingsField("GUI 适配器", error: model.fieldErrors["adapter"]) {
                        Picker("GUI 适配器", selection: $model.adapterId) {
                            ForEach(model.adapters, id: \.self) { Text(AIGuiProfileItem.adapterLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                HStack(alignment: .top, spacing: ADSpace.l) {
                    SettingsField("模型输出坐标", hint: "适配器会转换成 Desktop 来源截图像素。") {
                        Picker("模型输出坐标", selection: $model.coordinateProtocol) {
                            ForEach(["normalized_1000", "image_pixels"], id: \.self) { Text(AIGuiProfileItem.coordinateLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                    }
                    SettingsField("当前版本", hint: "正在运行的诊断不会静默切换版本。") {
                        Text(model.selected.map { "r\($0.revision)" } ?? "尚未保存").font(ADFont.body).foregroundStyle(ADColor.ink)
                            .padding(.horizontal, ADSpace.m).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
                    }
                }
                HStack {
                    Spacer()
                    Button { Task { await model.save() } } label: { Label("保存配置", systemImage: "square.and.arrow.down") }
                        .buttonStyle(ADButtonStyle(.primary)).disabled(model.saving)
                }
            }
            .padding(ADSpace.l)
        }
    }

    var limits: some View {
        DisclosureGroup {
            let l = model.selected?.limits ?? model.limits
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                LabeledValue(label: "最多步数", value: "\(l["maxSteps"]?.intValue ?? 0)")
                LabeledValue(label: "总时限", value: "\(l["maxWallTimeMs"]?.intValue ?? 0) 毫秒")
                LabeledValue(label: "每步模型调用", value: "最多 \(l["maxModelAttemptsPerStep"]?.intValue ?? 0) 次")
                LabeledValue(label: "模型调用总数", value: "最多 \(l["maxTotalModelAttempts"]?.intValue ?? 0) 次")
                LabeledValue(label: "截图", value: "最多 \(l["maxScreenshots"]?.intValue ?? 0) 张")
                Text("这些上限由后端给出，配置只能调低；在这里只读显示。").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .padding(.top, ADSpace.s)
        } label: {
            Text("有界运行限制与调用选项").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.l)
        .adPanel()
    }
}
