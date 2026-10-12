import AgentDesktopProtocol
import SwiftUI

// Lane UI-D (U6): P23 AI 连接 and P24 添加 / 编辑连接 (side drawer).
// Every call is a runtime/1 `ai.*` method through the main window's
// RuntimePort. Logic follows AgentDesktopAIUI W01/W02 (which these pages
// replace in the main window): writes carry the revision the page read,
// a conflict keeps the draft and says so, and the key never stays in any
// state once its one submission has read it.

/// P23: the connections, each with the model and the evidence a test left.
@MainActor
final class SettingsConnectionsModel: ObservableObject {
    @Published private(set) var connections: [AIConnectionItem] = []
    @Published private(set) var modelProfiles: [AIModelProfileItem] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var failure: SettingsFailure?
    @Published private(set) var busyId: String?
    @Published private(set) var notice: String?
    let runtime: RuntimePort

    init(runtime: RuntimePort) { self.runtime = runtime }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let c = try await runtime.call("ai.connections.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            let m = try await runtime.call("ai.modelProfiles.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            connections = (c["items"]?.arrayValue ?? []).map(AIConnectionItem.init)
            modelProfiles = (m["items"]?.arrayValue ?? []).map(AIModelProfileItem.init)
            loaded = true
            failure = nil
        } catch {
            failure = SettingsFailure(error)
        }
    }

    /// The model profile shown for a connection: an enabled one first.
    func model(for c: AIConnectionItem) -> AIModelProfileItem? {
        let on = modelProfiles.filter { $0.connectionId == c.id }
        return on.first(where: \.enabled) ?? on.first
    }

    /// After the user confirmed. Existing runs keep their snapshot.
    func disable(_ c: AIConnectionItem) async {
        await write(c, "ai.connections.disable",
                    .obj([("connectionId", .string(c.id)), ("expectedRevision", .int(c.revision))]),
                    done: "已停用「\(c.name)」。")
    }

    func enable(_ c: AIConnectionItem) async {
        await write(c, "ai.connections.update",
                    .obj([("connectionId", .string(c.id)), ("expectedRevision", .int(c.revision)),
                          ("patch", .obj([("state", .string("enabled"))]))]),
                    done: "已启用「\(c.name)」。")
    }

    /// After the user confirmed. Refused while a model profile uses it.
    func delete(_ c: AIConnectionItem) async {
        await write(c, "ai.connections.delete",
                    .obj([("connectionId", .string(c.id)), ("expectedRevision", .int(c.revision))]),
                    done: "已删除「\(c.name)」。")
    }

    private func write(_ c: AIConnectionItem, _ method: String, _ params: JSONValue, done: String) async {
        busyId = c.id
        notice = nil
        defer { busyId = nil }
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

/// P24: adding or editing one connection.
@MainActor
final class SettingsConnectionEditorModel: ObservableObject {
    enum Mode: Equatable { case create, edit(String) }

    /// Becomes `.edit` once the connection exists, so a second click saves
    /// it instead of creating another one.
    @Published private(set) var mode: Mode
    @Published var name = ""
    @Published var baseUrl = ""
    @Published var timeoutMs = 30000
    /// The password field. Read once by the submission that uses it and
    /// cleared before the request is sent; never copied anywhere else.
    @Published var secretInput = ""
    /// Create only: a model to set up on the new connection (a model profile).
    @Published var modelId = ""
    /// requestIds of creates whose answer has not arrived (idempotency).
    private var pendingCreateId: String?
    private var pendingModelCreateId: String?

    @Published private(set) var revision: Int?
    @Published private(set) var credentialSet = false
    @Published private(set) var fieldErrors: [String: String] = [:]
    @Published private(set) var failure: SettingsFailure?
    @Published private(set) var saving = false
    @Published private(set) var notice: String?
    @Published private(set) var models: [String] = []
    @Published private(set) var modelsRefreshedAt: String?
    @Published private(set) var savedId: String?

    let runtime: RuntimePort
    let clock: PollClock
    private var saved: (name: String, baseUrl: String, timeoutMs: Int)?

    init(runtime: RuntimePort, mode: Mode, clock: PollClock = SystemPollClock()) {
        self.runtime = runtime
        self.mode = mode
        self.clock = clock
        if case let .edit(id) = mode { savedId = id }
    }

    var title: String { mode == .create ? "添加 AI 连接" : "编辑 AI 连接" }

    var baseUrlUnsaved: Bool { saved.map { $0.baseUrl != baseUrl } ?? true }

    func load() async {
        guard case let .edit(id) = mode else { return }
        do {
            apply(try await runtime.call("ai.connections.get", .obj([("connectionId", .string(id))])))
            failure = nil
            await loadModels()
        } catch {
            failure = SettingsFailure(error)
        }
    }

    private func apply(_ c: JSONValue) {
        name = c["name"]?.stringValue ?? ""
        baseUrl = c["baseUrl"]?.stringValue ?? ""
        timeoutMs = c["timeoutMs"]?.intValue ?? 30000
        revision = c["revision"]?.intValue
        credentialSet = c["credentialRef"]?.stringValue != nil
        savedId = c["connectionId"]?.stringValue
        saved = (name, baseUrl, timeoutMs)
    }

    /// Client-side rules; the Runtime checks again. Messages never quote the URL.
    func validate(requireKey: Bool) -> Bool {
        var e: [String: String] = [:]
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.count > 80 { e["name"] = "名称不能为空，最长 80 个字符" }
        if let err = ProviderEndpointRule.error(baseUrl, allowLocalHTTP: true) { e["baseUrl"] = err }
        if !(100...120_000).contains(timeoutMs) { e["timeoutMs"] = "超时需在 100–120000 毫秒之间" }
        if requireKey && secretInput.isEmpty { e["apiKey"] = "需要填写 API 密钥" }
        if modelId.count > 160 { e["modelId"] = "模型 ID 最长 160 个字符" }
        fieldErrors = e
        return e.isEmpty
    }

    /// Create, or save the metadata (which never touches the credential).
    /// Returns true when something was saved.
    @discardableResult
    func save() async -> Bool {
        notice = nil
        switch mode {
        case .create:
            guard validate(requireKey: true) else { secretInput = ""; return false }
            let key = secretInput
            secretInput = ""
            let params = JSONValue.obj([
                ("name", .string(name.trimmingCharacters(in: .whitespaces))), ("protocol", .string("openai_chat")),
                ("baseUrl", .string(baseUrl)), ("timeoutMs", .int(timeoutMs)),
                ("credential", .obj([("apiKey", .string(key))])),
            ])
            // One requestId per attempt at this draft: a repeat after a lost
            // answer gets the ledger's record instead of a second connection.
            let createId = pendingCreateId ?? RuntimeRequest.newId(prefix: "ui")
            pendingCreateId = createId
            let created = await submit {
                let c = try await self.runtime.call("ai.connections.create", params, requestId: createId)
                self.pendingCreateId = nil
                self.apply(c)
                if let id = c["connectionId"]?.stringValue { self.mode = .edit(id) }
                self.notice = "已保存（r\(c["revision"]?.intValue ?? 0)）。密钥只提交了一次，界面没有保留。"
            }
            let model = modelId.trimmingCharacters(in: .whitespaces)
            guard created, !model.isEmpty, let id = savedId, let rev = revision else { return created }
            let modelCreateId = pendingModelCreateId ?? RuntimeRequest.newId(prefix: "ui")
            pendingModelCreateId = modelCreateId
            let modelSaved = await submit {
                _ = try await self.runtime.call("ai.modelProfiles.create", .obj([
                    ("name", .string(model)), ("connectionId", .string(id)), ("connectionRevision", .int(rev)),
                    ("modelId", .string(model)), ("requestOptions", .obj([])), ("maxOutputTokens", .int(1024)),
                ]), requestId: modelCreateId)
                self.pendingModelCreateId = nil
                self.modelId = ""
            }
            if !modelSaved { notice = "连接已保存，但模型配置没有建立；可以在「GUI 配置」里再选择模型。" }
            return true
        case let .edit(id):
            guard validate(requireKey: false), let base = revision, let saved else { return false }
            var patch: [(String, JSONValue)] = []
            let n = name.trimmingCharacters(in: .whitespaces)
            if saved.name != n { patch.append(("name", .string(n))) }
            if saved.baseUrl != baseUrl { patch.append(("baseUrl", .string(baseUrl))) }
            if saved.timeoutMs != timeoutMs { patch.append(("timeoutMs", .int(timeoutMs))) }
            guard !patch.isEmpty else { notice = "没有需要保存的修改"; return false }
            let params = JSONValue.obj([("connectionId", .string(id)), ("expectedRevision", .int(base)), ("patch", .obj(patch))])
            return await submit {
                let c = try await self.runtime.call("ai.connections.update", params)
                self.apply(c)
                self.notice = "已保存（r\(c["revision"]?.intValue ?? 0)），凭据未改变。"
            }
        }
    }

    /// Rotation is its own write: the old key is revoked and runs still
    /// using it fail; nothing switches accounts silently.
    func rotate() async {
        notice = nil
        guard let id = savedId, let base = revision else { return }
        guard !secretInput.isEmpty else { fieldErrors["apiKey"] = "需要填写新的 API 密钥"; return }
        let key = secretInput
        secretInput = ""
        let params = JSONValue.obj([("connectionId", .string(id)), ("expectedRevision", .int(base)),
                                    ("credential", .obj([("apiKey", .string(key))]))])
        await submit {
            self.apply(try await self.runtime.call("ai.credentials.rotate", params))
            self.notice = "密钥已轮换。旧密钥已撤销，仍在使用它的运行会明确失败。"
        }
    }

    func loadModels() async {
        guard let id = savedId else { return }
        if let list = try? await runtime.call("ai.models.list", .obj([("connectionId", .string(id))])) {
            models = (list["items"]?.arrayValue ?? []).compactMap { $0["modelId"]?.stringValue }
            modelsRefreshedAt = list["refreshedAt"]?.stringValue
        }
    }

    /// Asks the saved connection for its models (an operation to poll).
    func refreshModels(maxReads: Int = 150) async {
        guard let id = savedId, let base = revision else { return }
        guard !baseUrlUnsaved else {
            failure = SettingsFailure(problem: RuntimeProblem(code: "invalid_argument", title: "请先保存连接",
                                                              advice: "Base URL 有未保存的修改；获取模型只使用已保存的连接。"))
            return
        }
        await submit {
            let op = try await self.runtime.call("ai.models.refresh", .obj([("connectionId", .string(id)), ("expectedRevision", .int(base))]))
            guard let opId = op["operationId"]?.stringValue else { return }
            var state = op["state"]?.stringValue ?? "queued"
            var reads = 0
            while !["succeeded", "failed", "cancelled"].contains(state), reads < maxReads {
                try await self.clock.pause(milliseconds: 200)
                reads += 1
                state = try await self.runtime.call("ai.operations.get", .obj([("operationId", .string(opId))]))["state"]?.stringValue ?? "failed"
            }
            await self.loadModels()
            self.notice = state == "succeeded"
                ? "已获取 \(self.models.count) 个模型。模型列出不等于通过 GUI 能力测试。"
                : "模型列表没有刷新成功，显示的是上次的结果；仍可手动填写模型 ID。"
        }
    }

    /// Takes the Runtime's current revision; fields the user changed keep
    /// the draft, untouched ones take the Runtime's value.
    func reloadKeepingDraft() async {
        guard let id = savedId, let old = saved else { return }
        let draft = (name: name.trimmingCharacters(in: .whitespaces), baseUrl: baseUrl, timeoutMs: timeoutMs)
        do {
            apply(try await runtime.call("ai.connections.get", .obj([("connectionId", .string(id))])))
            if draft.name != old.name { name = draft.name }
            if draft.baseUrl != old.baseUrl { baseUrl = draft.baseUrl }
            if draft.timeoutMs != old.timeoutMs { timeoutMs = draft.timeoutMs }
            failure = nil
            notice = "已读取服务器版本 r\(revision ?? 0)，你的修改仍保留，尚未保存。"
        } catch {
            failure = SettingsFailure(error)
        }
    }

    /// Leaving the drawer: the key field never survives.
    func reset() { secretInput = "" }

    @discardableResult
    private func submit(_ body: @escaping () async throws -> Void) async -> Bool {
        saving = true
        defer { saving = false }
        do {
            try await body()
            failure = nil
            return true
        } catch {
            failure = SettingsFailure(error)
            return false
        }
    }
}

/// P23 page.
struct SettingsConnectionsPage: View {
    @ObservedObject var model: SettingsConnectionsModel
    let onAdd: () -> Void
    let onEdit: (AIConnectionItem) -> Void
    let onTest: (AIConnectionItem) -> Void
    let confirm: (SettingsConfirmation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            SettingsCard(title: "AI 连接", subtitle: "仅供内置 GUI 诊断使用。通过 CLI / MCP 直接操作 Desktop，不依赖任何 AI 连接。", trailing: {
                Button(action: onAdd) { Label("添加 AI 连接", systemImage: "plus") }.buttonStyle(ADButtonStyle(.primary))
            }) {
                if let f = model.failure {
                    SettingsFailureView(failure: f, retry: { Task { await model.refresh() } }).padding(ADSpace.l)
                }
                if let n = model.notice {
                    Text(n).font(ADFont.note).foregroundStyle(ADColor.muted).padding(.horizontal, ADSpace.l).padding(.top, ADSpace.m)
                }
                if !model.loaded && model.loading {
                    ProgressView("正在读取连接…").padding(ADSpace.xl).frame(maxWidth: .infinity)
                } else if model.loaded && model.connections.isEmpty {
                    EmptyState(title: "还没有 AI 连接", detail: "AI 连接只用于内置 GUI 诊断。直接 API 与确定性回放不需要它，仍然可用。",
                               action: ("添加 AI 连接", onAdd))
                } else {
                    SettingsTableHeader(columns: [("连接", nil), ("模型", 180), ("能力证据", 190), ("状态", 120), ("操作", 250)])
                    ForEach(model.connections) { c in row(c) }
                }
            }
            HStack(alignment: .top, spacing: ADSpace.l) {
                SettingsCard(title: "连接与模型能力分开记录") {
                    Text("连接保存端点和凭据引用；GUI 配置选择模型、适配器与有界运行参数。保存 API 密钥不代表模型能理解和操作画面。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l).fixedSize(horizontal: false, vertical: true)
                }
                SettingsCard(title: "保留你的外部 Agent") {
                    Text("不接管 Codex、Orca 或其他 Agent 的模型账号，不建立统一费用中心。这里的用量仅统计内置 GUI 诊断调用。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { if !model.loaded { await model.refresh() } }
    }

    func row(_ c: AIConnectionItem) -> some View {
        let mp = model.model(for: c)
        let busy = model.busyId == c.id
        return HStack(spacing: ADSpace.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(c.baseUrl).font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(1).truncationMode(.middle)
                Text(c.credentialSet ? "密钥：已设置" : "密钥：未设置").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(mp?.modelId ?? "—").font(ADFont.note).foregroundStyle(ADColor.ink)
                Text(AIConnectionItem.protocolLabel).font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .frame(width: 180, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                StateBadge(AIEvidence.status(mp, connectionRevision: c.revision))
                Text(AIEvidence.note(mp, connectionRevision: c.revision)).font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .frame(width: 190, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                StateBadge(c.enabled ? StatusText("已启用", .running) : StatusText("已停用", .idle))
                Text("配置 r\(c.revision)").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .frame(width: 120, alignment: .leading)
            HStack(spacing: ADSpace.s) {
                Button("编辑") { onEdit(c) }.buttonStyle(ADButtonStyle(.secondary))
                Button("测试") { onTest(c) }.buttonStyle(ADButtonStyle(.secondary)).disabled(!c.enabled)
                if c.enabled {
                    Button { confirm(SettingsConfirmation(action: .disableConnection, id: c.id, name: c.name)) } label: {
                        Image(systemName: "pause.fill")
                    }
                    .buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("停用\(c.name)")
                } else {
                    Button { Task { await model.enable(c) } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("启用\(c.name)")
                }
                Button { confirm(SettingsConfirmation(action: .deleteConnection, id: c.id, name: c.name)) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("删除\(c.name)")
            }
            .disabled(busy)
            .frame(width: 250, alignment: .leading)
        }
        .padding(.horizontal, ADSpace.l).padding(.vertical, ADSpace.m)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// P24: the drawer's fields and actions.
struct SettingsConnectionDrawer: View {
    @ObservedObject var model: SettingsConnectionEditorModel
    let close: () -> Void
    let saved: () -> Void

    var body: some View {
        SettingsDrawer(title: model.title, subtitle: "仅用于内置 GUI 诊断；不影响外部 Agent。", close: { model.reset(); close() }) {
            if let f = model.failure {
                SettingsFailureView(failure: f)
                if f.isConflict {
                    Button("读取服务器版本（保留我的修改）") { Task { await model.reloadKeepingDraft() } }
                        .buttonStyle(ADButtonStyle(.secondary))
                }
            }
            if let n = model.notice { Text(n).font(ADFont.note).foregroundStyle(ADColor.primary) }
            SettingsField("连接名称", hint: "例如：本地 GUI 连接", error: model.fieldErrors["name"]) {
                TextField("连接名称", text: $model.name)
            }
            SettingsField("协议", hint: "当前只开放已实现的兼容协议。") {
                Text("OpenAI Chat 兼容").font(ADFont.body).foregroundStyle(ADColor.ink)
                    .padding(.horizontal, ADSpace.m).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
            }
            SettingsField("Base URL", hint: "HTTPS 或本机 loopback HTTP；不要把密钥放在 URL 中。", error: model.fieldErrors["baseUrl"]) {
                TextField("https://", text: $model.baseUrl)
            }
            if model.mode == .create {
                SettingsField("API 密钥", hint: "只提交一次，界面不保存、不显示。", error: model.fieldErrors["apiKey"]) {
                    SecureField("输入 API 密钥", text: $model.secretInput)
                }
                SettingsField("模型 ID（可选）", hint: "可手动填写；保存连接时一并建立模型配置。获取到模型名称不等于通过 GUI 能力测试。",
                              error: model.fieldErrors["modelId"]) {
                    TextField("例如 gui-model-v1", text: $model.modelId)
                }
            } else {
                SettingsField("API 密钥", hint: "密钥不会显示。轮换会撤销旧密钥，仍在使用它的运行会明确失败。",
                              error: model.fieldErrors["apiKey"]) {
                    VStack(alignment: .leading, spacing: ADSpace.s) {
                        StateBadge(model.credentialSet ? StatusText("已设置", .running) : StatusText("未设置", .attention))
                        SecureField("输入新的 API 密钥以轮换", text: $model.secretInput)
                        Button("轮换密钥") { Task { await model.rotate() } }
                            .buttonStyle(ADButtonStyle(.secondary)).disabled(model.saving || model.secretInput.isEmpty)
                    }
                }
                SettingsField("模型", hint: model.modelsRefreshedAt.map { "上次获取：\($0)" } ?? "尚未获取模型列表。") {
                    VStack(alignment: .leading, spacing: ADSpace.s) {
                        if !model.models.isEmpty {
                            Text(model.models.joined(separator: "、")).font(ADFont.code).foregroundStyle(ADColor.ink)
                        }
                        Button { Task { await model.refreshModels() } } label: { Label("获取模型示例", systemImage: "arrow.clockwise") }
                            .buttonStyle(ADButtonStyle(.secondary)).disabled(model.saving)
                    }
                }
            }
            SettingsField("请求超时（毫秒）", hint: "同时受诊断运行的总时限约束。", error: model.fieldErrors["timeoutMs"]) {
                TextField("30000", value: $model.timeoutMs, format: .number)
            }
            Text("正式应用把凭据写入系统凭据存储；界面只显示是否已设置，不显示密钥本身。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("取消") { model.reset(); close() }.buttonStyle(ADButtonStyle(.secondary))
            Button { Task { if await model.save() { saved() } } } label: {
                Label(model.mode == .create ? "保存连接" : "保存修改", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(ADButtonStyle(.primary)).disabled(model.saving)
        }
        .task { await model.load() }
    }
}
