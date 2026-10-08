import AgentDesktopProtocol
import Foundation
import SwiftUI

/// W02 — 添加 / 编辑 AI 连接.
///
/// The key typed into the password field lives only in `secretInput` until
/// the submission that uses it, which reads it once and clears it. It is
/// never part of the draft, a message, or anything a test can find later.
@MainActor
public final class ConnectionEditorModel: ObservableObject {
    public enum Mode: Equatable { case create, edit(String) }

    public struct Conflict: Equatable {
        public let baseRevision: Int
        public let serverRevision: Int
        public let changedFields: [String]
    }

    public let mode: Mode
    @Published public var name = ""
    @Published public var baseUrl = ""
    @Published public var timeoutMs = 30000
    @Published public var allowLocalHTTP = false
    /// The password field's text. Cleared by every submission and reset.
    @Published public var secretInput = ""

    @Published public private(set) var baseRevision: Int?
    @Published public private(set) var savedCredentialSummary: String?
    @Published public private(set) var fieldErrors: [String: String] = [:]
    @Published public private(set) var problem: UIProblem?
    @Published public private(set) var conflict: Conflict?
    @Published public private(set) var saving = false
    @Published public private(set) var notice: String?
    @Published public private(set) var savedConnectionId: String?
    @Published public private(set) var models: [String] = []
    @Published public private(set) var modelsFetchedAt: String?

    /// Protocols the v1 service implements; the others are shown as not implemented.
    public static let protocols: [(id: String, label: String, implemented: Bool)] = [
        ("openai_chat", "OpenAI 兼容 Chat Completions", true),
        ("anthropic_messages", "Anthropic Messages（未实现）", false),
        ("openai_responses", "OpenAI Responses（未实现）", false),
        ("gemini_generate_content", "Gemini（未实现）", false),
    ]

    let client: ContractClient
    let clock: PollClock
    private var saved: (name: String, baseUrl: String, timeoutMs: Int)?
    private var createKey = SubmissionKey()
    private var updateKey = SubmissionKey()
    private var rotateKey = SubmissionKey()
    private var refreshKey = SubmissionKey()

    public init(client: ContractClient, mode: Mode, clock: PollClock = SystemPollClock()) {
        self.client = client
        self.mode = mode
        self.clock = clock
    }

    public var isDirty: Bool {
        guard let saved else { return !name.isEmpty || !baseUrl.isEmpty }
        return saved != (name.trimmingCharacters(in: .whitespaces), baseUrl, timeoutMs)
    }

    public var baseUrlUnsaved: Bool { saved.map { $0.baseUrl != baseUrl } ?? true }

    /// Loads the connection to edit: its revision and a masked credential summary.
    public func load() async {
        guard case let .edit(id) = mode else { return }
        do {
            let c = try await client.send("ai.connections.get", .obj([("connectionId", .string(id))]))
            apply(c)
            problem = nil
        } catch {
            problem = UIProblem(error)
        }
    }

    private func apply(_ c: JSONValue) {
        name = c["name"]?.stringValue ?? ""
        baseUrl = c["baseUrl"]?.stringValue ?? ""
        timeoutMs = c["timeoutMs"]?.intValue ?? 30000
        baseRevision = c["revision"]?.intValue
        savedCredentialSummary = "已保存凭据 " + Format.masked(c["credentialRef"]?.stringValue)
        savedConnectionId = c["connectionId"]?.stringValue
        saved = (name, baseUrl, timeoutMs)
    }

    /// Client-side rules (the service checks again). Messages never quote the URL.
    public func validate(requireKey: Bool) -> Bool {
        var errors: [String: String] = [:]
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.count > 80 { errors["name"] = "名称不能为空，最长 80 个字符" }
        if let e = Self.endpointError(baseUrl, allowLocalHTTP: allowLocalHTTP) { errors["baseUrl"] = e }
        if !(100...120_000).contains(timeoutMs) { errors["timeoutMs"] = "超时需在 100–120000 毫秒之间" }
        if requireKey && secretInput.isEmpty { errors["apiKey"] = "需要填写 API 密钥" }
        fieldErrors = errors
        return errors.isEmpty
    }

    static func endpointError(_ s: String, allowLocalHTTP: Bool) -> String? {
        ProviderEndpointRule.error(s, allowLocalHTTP: allowLocalHTTP)
    }

    /// Create or save metadata. Metadata saves never touch the credential.
    public func save() async {
        notice = nil
        switch mode {
        case .create:
            guard validate(requireKey: true) else { secretInput = ""; return }
            let key = secretInput
            secretInput = ""
            let params = JSONValue.obj([
                ("name", .string(name.trimmingCharacters(in: .whitespaces))), ("protocol", .string("openai_chat")),
                ("baseUrl", .string(baseUrl)), ("timeoutMs", .int(timeoutMs)),
                ("credential", .obj([("apiKey", .string(key))])),
            ])
            let k = createKey.key(for: params, prefix: "w02-create")
            await submit {
                let c = try await self.client.send("ai.connections.create", params, idempotencyKey: k)
                self.apply(c)
                self.createKey.reset()
                self.notice = "已保存（r\(c["revision"]?.intValue ?? 0)）"
            }
        case let .edit(id):
            guard validate(requireKey: false), let base = baseRevision else { return }
            var patch: [(String, JSONValue)] = []
            if let saved {
                if saved.name != name.trimmingCharacters(in: .whitespaces) { patch.append(("name", .string(name.trimmingCharacters(in: .whitespaces)))) }
                if saved.baseUrl != baseUrl { patch.append(("baseUrl", .string(baseUrl))) }
                if saved.timeoutMs != timeoutMs { patch.append(("timeoutMs", .int(timeoutMs))) }
            }
            guard !patch.isEmpty else { notice = "没有需要保存的修改"; return }
            let params = JSONValue.obj([("connectionId", .string(id)), ("expectedRevision", .int(base)), ("patch", .obj(patch))])
            let k = updateKey.key(for: params, prefix: "w02-update")
            await submit {
                let c = try await self.client.send("ai.connections.update", params, idempotencyKey: k)
                self.apply(c)
                self.updateKey.reset()
                self.notice = "已保存（r\(c["revision"]?.intValue ?? 0)），凭据未改变"
            }
        }
    }

    /// Rotation is its own operation: the old identity is revoked and
    /// runs still using it fail; nothing switches accounts silently.
    public func rotateCredential() async {
        notice = nil
        guard let id = savedConnectionId, let base = baseRevision else { return }
        guard !secretInput.isEmpty else { fieldErrors["apiKey"] = "需要填写新的 API 密钥"; return }
        let key = secretInput
        secretInput = ""
        let params = JSONValue.obj([("connectionId", .string(id)), ("expectedRevision", .int(base)),
                                    ("credential", .obj([("apiKey", .string(key))]))])
        let k = rotateKey.key(for: params, prefix: "w02-rotate")
        await submit {
            let c = try await self.client.send("ai.credentials.rotate", params, idempotencyKey: k)
            self.apply(c)
            self.rotateKey.reset()
            self.notice = "凭据已更新。旧凭据已撤销，仍在使用它的运行会明确失败。"
        }
    }

    /// Fetch models with the saved connection only.
    public func refreshModels() async {
        guard let id = savedConnectionId, let base = baseRevision else { return }
        guard !baseUrlUnsaved else {
            problem = UIProblem(code: .validationError, title: "请先保存连接", advice: "Base URL 有未保存的修改；获取模型只使用已保存的连接。")
            return
        }
        let params = JSONValue.obj([("connectionId", .string(id)), ("expectedRevision", .int(base))])
        let k = refreshKey.key(for: params, prefix: "w02-models")
        await submit {
            let op = try await self.client.send("ai.models.refresh", params, idempotencyKey: k)
            guard let opId = op["operationId"]?.stringValue else { return }
            var state = "queued"
            while !["succeeded", "failed", "cancelled"].contains(state) {
                try await self.clock.pause(milliseconds: 200)
                state = try await self.client.send("ai.operations.get", .obj([("operationId", .string(opId))]))["state"]?.stringValue ?? "failed"
            }
            self.refreshKey.reset()
            let list = try await self.client.send("ai.models.list", .obj([("connectionId", .string(id))]))
            self.models = (list["items"]?.arrayValue ?? []).compactMap { $0["modelId"]?.stringValue }
            self.modelsFetchedAt = list["refreshedAt"]?.stringValue
            if state != "succeeded" { self.notice = "模型列表刷新未成功，显示的是上次的缓存；仍可手动填写模型 ID" }
        }
    }

    private func submit(_ body: @escaping () async throws -> Void) async {
        saving = true
        defer { saving = false }
        do {
            try await body()
            problem = nil
            conflict = nil
        } catch let e as ContractError where e.code == .configConflict {
            problem = UIProblem(e)
            await describeConflict(serverRevision: e.details?["currentRevision"]?.intValue)
        } catch {
            problem = UIProblem(error)
        }
    }

    /// Keep the draft; show base vs. server revision and what changed there.
    private func describeConflict(serverRevision: Int?) async {
        guard let id = savedConnectionId ?? { if case let .edit(i) = mode { return i }; return nil }(),
              let base = baseRevision else { return }
        var changed: [String] = []
        var server = serverRevision ?? base
        if let c = try? await client.send("ai.connections.get", .obj([("connectionId", .string(id))])), let saved {
            server = c["revision"]?.intValue ?? server
            if c["name"]?.stringValue != saved.name { changed.append("名称") }
            if c["baseUrl"]?.stringValue != saved.baseUrl { changed.append("Base URL") }
            if c["timeoutMs"]?.intValue != saved.timeoutMs { changed.append("超时") }
            if "已保存凭据 " + Format.masked(c["credentialRef"]?.stringValue) != savedCredentialSummary { changed.append("凭据已更新") }
            if c["state"]?.stringValue == "disabled" { changed.append("状态") }
        }
        conflict = Conflict(baseRevision: base, serverRevision: server, changedFields: changed)
    }

    /// Adopt the server's revision as the new base. Fields the user changed
    /// keep the draft; fields the user did not touch take the server's value,
    /// so saving never silently reverts someone else's change.
    public func reloadKeepingDraft() async {
        guard let id = savedConnectionId, let old = saved else { return }
        let draft = (name: name.trimmingCharacters(in: .whitespaces), baseUrl: baseUrl, timeoutMs: timeoutMs)
        do {
            let c = try await client.send("ai.connections.get", .obj([("connectionId", .string(id))]))
            apply(c)
            if draft.name != old.name { name = draft.name }
            if draft.baseUrl != old.baseUrl { baseUrl = draft.baseUrl }
            if draft.timeoutMs != old.timeoutMs { timeoutMs = draft.timeoutMs }
            conflict = nil
            problem = nil
            updateKey.reset()
        } catch { problem = UIProblem(error) }
    }

    public func discardDraft() async {
        conflict = nil
        updateKey.reset()
        await load()
    }

    /// Leaving the page: the key field never survives.
    public func reset() { secretInput = "" }
}

public struct ConnectionEditorView: View {
    @ObservedObject var model: ConnectionEditorModel
    var onTest: (String) -> Void

    public init(model: ConnectionEditorModel, onTest: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onTest = onTest
    }

    public var body: some View {
        Form {
            Section {
                Text(model.mode == .create ? "添加 AI 连接" : "编辑 AI 连接").font(.title2).bold().accessibilityAddTraits(.isHeader)
                if let p = model.problem { ProblemBanner(problem: p) }
                if let c = model.conflict {
                    VStack(alignment: .leading) {
                        Text("r\(c.baseRevision) → r\(c.serverRevision)；服务器上变化的字段：\(c.changedFields.isEmpty ? "—" : c.changedFields.joined(separator: "、"))")
                        HStack {
                            Button("保留草稿并读取") { Task { await model.reloadKeepingDraft() } }
                            Button("放弃草稿") { Task { await model.discardDraft() } }
                        }
                    }
                }
                if let n = model.notice { Text(n).foregroundStyle(.green) }
            }
            Section("连接") {
                TextField("名称", text: $model.name)
                if let e = model.fieldErrors["name"] { Text(e).foregroundStyle(.red).font(.caption) }
                Picker("协议", selection: .constant("openai_chat")) {
                    ForEach(ConnectionEditorModel.protocols, id: \.id) { p in Text(p.label).tag(p.id).disabled(!p.implemented) }
                }
                TextField("Base URL", text: $model.baseUrl)
                if let e = model.fieldErrors["baseUrl"] { Text(e).foregroundStyle(.red).font(.caption) }
                Toggle("允许本地模型（http://127.0.0.1、localhost、[::1]）", isOn: $model.allowLocalHTTP)
                Stepper("请求超时 \(model.timeoutMs) ms", value: $model.timeoutMs, in: 100...120_000, step: 1000)
                if let e = model.fieldErrors["timeoutMs"] { Text(e).foregroundStyle(.red).font(.caption) }
            }
            Section(model.mode == .create ? "API 密钥" : "凭据") {
                if let s = model.savedCredentialSummary { LabeledValue(label: "当前", value: s) }
                SecureField(model.mode == .create ? "API 密钥" : "新的 API 密钥（留空表示不修改）", text: $model.secretInput)
                if let e = model.fieldErrors["apiKey"] { Text(e).foregroundStyle(.red).font(.caption) }
                if model.mode != .create {
                    Text("轮换会撤销旧凭据身份；仍在使用它的运行会明确失败，不会静默切换账户。").font(.caption)
                    Button("轮换凭据") { Task { await model.rotateCredential() } }.disabled(model.saving || model.secretInput.isEmpty)
                }
            }
            Section("模型") {
                Button("获取模型") { Task { await model.refreshModels() } }
                    .disabled(model.savedConnectionId == nil || model.saving)
                if !model.models.isEmpty { Text(model.models.joined(separator: "、")).font(.callout) }
                Text("模型列表不代表图像或 GUI 能力可用，能力以四层测试为准。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存") { Task { await model.save() } }.keyboardShortcut(.defaultAction).disabled(model.saving)
                if let id = model.savedConnectionId { Button("测试") { onTest(id) } }
            }
        }
        .padding()
        .task { await model.load() }
        .onDisappear { model.reset() }
    }
}
