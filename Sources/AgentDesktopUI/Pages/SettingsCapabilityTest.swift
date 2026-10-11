import AgentDesktopProtocol
import SwiftUI

// Lane UI-D (U6): P26 连接与能力测试. Four levels checked apart with the
// fixed synthetic material: no desktop screenshot, no input. Logic follows
// AgentDesktopAIUI W04: one operation, polled until it ends; a cancel is
// accepted, not done, until the operation says so; answers for an older
// test never touch the page.

struct SettingsTestLevel: Identifiable, Equatable {
    enum Status: String { case pending, passed, failed, skipped }
    let id: String
    let title: String
    let detail: String
    var status: Status = .pending
    var reasonCode: String?

    var badge: StatusText {
        switch status {
        case .pending: return StatusText("未完成", .idle)
        case .passed: return StatusText("通过", .running)
        case .failed: return StatusText("失败", .danger)
        case .skipped: return StatusText("未执行", .idle)
        }
    }

    static func initial() -> [SettingsTestLevel] {
        [SettingsTestLevel(id: "network", title: "网络与端点", detail: "检查端点与连接，不推断视觉能力。"),
         SettingsTestLevel(id: "auth_model", title: "认证与目标模型", detail: "向指定模型发起合成调用，确认访问可用。"),
         SettingsTestLevel(id: "image_input", title: "图像输入能力", detail: "发送固定合成图片，不读取用户桌面。"),
         SettingsTestLevel(id: "gui_contract", title: "GUI 输出协议", detail: "解析标准 Proposal，检查动作字段与坐标，不发送输入。")]
    }
}

@MainActor
final class SettingsCapabilityTestModel: ObservableObject {
    /// `lost`: reading the operation failed; it may still be running.
    enum Phase: Equatable { case idle, starting, running, cancelling, lost, finished(String) }

    @Published var guiProfileId: String?
    @Published private(set) var profiles: [AIGuiProfileItem] = []
    @Published private(set) var modelProfiles: [AIModelProfileItem] = []
    @Published private(set) var connections: [AIConnectionItem] = []
    @Published private(set) var levels = SettingsTestLevel.initial()
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var operationId: String?
    @Published private(set) var testedRevision: Int?
    @Published private(set) var performedDesktopInput: Bool?
    @Published private(set) var failure: SettingsFailure?
    @Published private(set) var loaded = false
    /// Why no profile is selected after a connection's 测试 (no GUI profile uses it).
    @Published private(set) var selectionNote: String?
    /// Set by a connection's 测试: the next load selects a profile on it.
    var pendingConnectionId: String?
    /// The phase the lost poll was in, for resuming.
    private var lostFrom: Phase = .running

    static let costNotice = "测试使用固定的合成素材，不截取桌面、不执行输入；会向模型发送最多 3 次请求，可能产生费用。"

    let runtime: RuntimePort
    let clock: PollClock
    let pollMs: Int
    /// Raised by every start; work for an older test writes nothing.
    private var generation = 0

    init(runtime: RuntimePort, clock: PollClock = SystemPollClock(), pollMs: Int = 500) {
        self.runtime = runtime
        self.clock = clock
        self.pollMs = pollMs
    }

    var profile: AIGuiProfileItem? { profiles.first { $0.id == guiProfileId } }
    var modelProfile: AIModelProfileItem? { profile.flatMap { p in modelProfiles.first { $0.id == p.modelProfileId } } }
    var connection: AIConnectionItem? { modelProfile.flatMap { m in connections.first { $0.id == m.connectionId } } }

    var canStart: Bool {
        guard profile?.enabled == true else { return false }
        switch phase {
        case .idle, .finished, .lost: return true
        default: return false
        }
    }

    var isActive: Bool { [.starting, .running, .cancelling].contains(phase) }

    /// Reads the profiles again (every time the entry opens, so profiles
    /// made elsewhere are there). A selection survives unless a
    /// connection's 测试 asked for a profile on that connection.
    func load() async {
        do {
            let p = try await runtime.call("ai.profiles.list", .obj([("limit", .int(100))]))
            let m = try await runtime.call("ai.modelProfiles.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            let c = try await runtime.call("ai.connections.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            profiles = (p["items"]?.arrayValue ?? []).map(AIGuiProfileItem.init)
            modelProfiles = (m["items"]?.arrayValue ?? []).map(AIModelProfileItem.init)
            connections = (c["items"]?.arrayValue ?? []).map(AIConnectionItem.init)
            selectionNote = nil
            if let conn = pendingConnectionId, !isActive {
                pendingConnectionId = nil
                let onConn = profiles.filter { p in modelProfiles.contains { $0.id == p.modelProfileId && $0.connectionId == conn } }
                if let id = onConn.first(where: \.enabled)?.id ?? onConn.first?.id {
                    guiProfileId = id
                } else {
                    guiProfileId = nil
                    selectionNote = "这条连接还没有 GUI 配置。请先在「GUI 配置」里为它选择模型，再测试。"
                }
            } else if guiProfileId == nil || profile == nil {
                let d = try? await runtime.call("ai.profiles.default.get")
                guiProfileId = d?["default"]?["guiProfileId"]?.stringValue ?? profiles.first?.id
            }
            loaded = true
            failure = nil
        } catch {
            failure = SettingsFailure(error)
        }
    }

    /// Starts one test of the selected profile at its current revision.
    func start() async {
        guard canStart, let id = guiProfileId else { return }
        generation += 1
        let g = generation
        operationId = nil
        levels = SettingsTestLevel.initial()
        performedDesktopInput = nil
        failure = nil
        phase = .starting
        do {
            let p = try await runtime.call("ai.profiles.get", .obj([("guiProfileId", .string(id))]))
            guard g == generation else { return }
            let rev = p["revision"]?.intValue ?? 1
            testedRevision = rev
            let r = try await runtime.call("ai.tests.start", .obj([("guiProfileId", .string(id)), ("expectedRevision", .int(rev)),
                                                                   ("fixtureId", .string("synthetic_gui_v1"))]))
            guard g == generation else { return }
            guard let op = r["operationId"]?.stringValue else { phase = .idle; return }
            operationId = op
            phase = .running
            await poll(g)
        } catch {
            guard g == generation else { return }
            failure = SettingsFailure(error)
            phase = .idle
        }
    }

    /// Reads the operation until it ends (or a newer test takes over).
    private func poll(_ g: Int) async {
        while g == generation, isActive, let op = operationId {
            do {
                try await clock.pause(milliseconds: pollMs)
                guard g == generation, isActive else { return }
                let o = try await runtime.call("ai.operations.get", .obj([("operationId", .string(op))]))
                guard g == generation, isActive else { return }
                apply(o)
            } catch is CancellationError {
                return
            } catch {
                guard g == generation else { return }
                // A failed read leaves the test's state unknown, not ended:
                // the page says so and offers to read it again.
                failure = SettingsFailure(error)
                lostFrom = phase
                phase = .lost
                return
            }
        }
    }

    private func apply(_ o: JSONValue) {
        let state = o["state"]?.stringValue ?? "running"
        if let result = o["result"], !result.isNull {
            for l in result["levels"]?.arrayValue ?? [] {
                guard let i = levels.firstIndex(where: { $0.id == l["level"]?.stringValue }) else { continue }
                levels[i].status = SettingsTestLevel.Status(rawValue: l["status"]?.stringValue ?? "") ?? .pending
                levels[i].reasonCode = l["reasonCode"]?.stringValue
            }
            performedDesktopInput = result["performedDesktopInput"]?.boolValue
        }
        if let e = o["error"], !e.isNull, let code = e["code"]?.stringValue {
            failure = SettingsFailure(problem: RuntimeProblem(code: code.lowercased(), title: "测试没有完成",
                                                              advice: e["message"]?.stringValue ?? "测试在完成前失败。"))
        }
        switch state {
        case "succeeded", "failed", "cancelled": phase = .finished(state)
        case "cancelling": phase = .cancelling
        default: if phase != .cancelling { phase = .running }
        }
    }

    /// Reads the operation again after a lost read, and keeps polling.
    func resume() async {
        guard phase == .lost, operationId != nil else { return }
        failure = nil
        phase = lostFrom
        await poll(generation)
    }

    /// Asks to cancel; the test ends only when the operation says it did.
    func cancel() async {
        guard let op = operationId, isActive || phase == .lost else { return }
        let g = generation
        let wasLost = phase == .lost
        phase = .cancelling
        do {
            let r = try await runtime.call("ai.operations.cancel", .obj([("operationId", .string(op))]))
            guard g == generation else { return }
            if r["terminal"]?.boolValue == true {
                phase = .finished(r["state"]?.stringValue ?? "cancelled")
            } else if wasLost {
                // No loop is running after a lost read; follow the cancel.
                await poll(g)
            }
        } catch {
            guard g == generation else { return }
            failure = SettingsFailure(error)
        }
    }

    var summaryBadge: StatusText? {
        switch phase {
        case .idle: return nil
        case .starting: return StatusText("正在开始", .attention)
        case .running: return StatusText("测试中", .attention)
        case .cancelling: return StatusText("正在取消", .attention)
        case .lost: return StatusText("状态未知", .attention)
        case .finished(let s):
            if performedDesktopInput == true { return StatusText("异常：报告发生了桌面输入", .danger) }
            switch s {
            case "succeeded":
                return levels.allSatisfy { $0.status == .passed } ? StatusText("全部通过", .running) : StatusText("部分未通过", .danger)
            case "cancelled": return StatusText("已取消", .idle)
            default: return StatusText("测试失败", .danger)
            }
        }
    }
}

struct SettingsCapabilityTestPage: View {
    @ObservedObject var model: SettingsCapabilityTestModel
    let onDiagnose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            HStack(alignment: .center, spacing: ADSpace.m) {
                Text("将“连得上”“看得懂”“输出能解析”分别验证。").font(ADFont.note).foregroundStyle(ADColor.muted)
                Spacer()
                Picker("GUI 配置", selection: $model.guiProfileId) {
                    ForEach(model.profiles) { p in Text("\(p.name) · r\(p.revision)").tag(String?.some(p.id)) }
                }
                .labelsHidden().frame(width: 220).disabled(model.isActive)
                if model.phase == .lost {
                    Button("重新查询状态") { Task { await model.resume() } }.buttonStyle(ADButtonStyle(.secondary))
                }
                if model.isActive || model.phase == .lost {
                    Button("取消测试") { Task { await model.cancel() } }.buttonStyle(ADButtonStyle(.secondary))
                        .disabled(model.phase == .cancelling || model.operationId == nil)
                }
                Button { Task { await model.start() } } label: { Label("开始测试", systemImage: "play.fill") }
                    .buttonStyle(ADButtonStyle(.primary)).disabled(!model.canStart)
            }
            if let f = model.failure { SettingsFailureView(failure: f) }
            if model.phase == .lost {
                Text("读取测试状态失败。测试可能仍在运行并向模型发送请求；可以重新查询或取消。现在开始新的测试会另起一次。")
                    .font(ADFont.note).foregroundStyle(StatusTone.attention.foreground)
            }
            if let n = model.selectionNote { Text(n).font(ADFont.note).foregroundStyle(StatusTone.attention.foreground) }
            if model.loaded && model.profiles.isEmpty {
                EmptyState(title: "还没有 GUI 配置", detail: "先在「GUI 配置」里选择连接与模型，再回来测试。", action: nil).adPanel()
            }
            HStack(alignment: .top, spacing: ADSpace.l) {
                SettingsCard(title: "四层测试", trailing: {
                    if let b = model.summaryBadge { StateBadge(b) }
                }) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.levels.enumerated()), id: \.element.id) { i, l in level(i + 1, l) }
                    }
                    .padding(.horizontal, ADSpace.l).padding(.vertical, ADSpace.s)
                }
                VStack(alignment: .leading, spacing: ADSpace.l) {
                    SettingsCard(title: "本次测试") {
                        VStack(alignment: .leading, spacing: ADSpace.s) {
                            LabeledValue(label: "连接", value: model.connection?.name ?? "—", labelWidth: 90)
                            LabeledValue(label: "模型", value: model.modelProfile?.modelId ?? "—", labelWidth: 90)
                            LabeledValue(label: "GUI 配置", value: (model.testedRevision ?? model.profile?.revision).map { "r\($0)" } ?? "—", labelWidth: 90)
                            LabeledValue(label: "真实输入", value: Self.inputText(model.performedDesktopInput), labelWidth: 90)
                            LabeledValue(label: "数据", value: "合成图与固定文本", labelWidth: 90)
                            if let op = model.operationId { LabeledValue(label: "操作编号", value: op, monospaced: true, labelWidth: 90) }
                        }
                        .padding(ADSpace.l)
                    }
                    SettingsCard(title: "能力证据的范围") {
                        Text("模型能返回文本，不代表支持图片；通过协议解析，不代表任意业务任务都成功。各层结果独立记录。\(SettingsCapabilityTestModel.costNotice)")
                            .font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l).fixedSize(horizontal: false, vertical: true)
                    }
                    Button(action: onDiagnose) { Label("使用此配置进行诊断", systemImage: "chevron.right").frame(maxWidth: .infinity) }
                        .buttonStyle(ADButtonStyle(.primary))
                        .disabled(model.summaryBadge?.text != "全部通过")
                }
                .frame(width: 300)
            }
        }
        .task { await model.load() }
    }

    /// Reported desktop input: none, unknown until the result, or the
    /// safety violation it would be.
    static func inputText(_ performed: Bool?) -> String {
        switch performed {
        case false?: return "0 次"
        case true?: return "异常：结果报告发生了桌面输入"
        case nil: return "尚无结果（测试不应发送输入）"
        }
    }

    func level(_ n: Int, _ l: SettingsTestLevel) -> some View {
        HStack(alignment: .top, spacing: ADSpace.m) {
            Text("\(n)").font(ADFont.note).foregroundStyle(ADColor.muted)
                .frame(width: 26, height: 26).background(Circle().stroke(ADColor.line))
            VStack(alignment: .leading, spacing: 3) {
                Text(l.title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(l.detail).font(ADFont.note).foregroundStyle(ADColor.muted)
                if let r = l.reasonCode { Text(r).font(ADFont.identifier).foregroundStyle(StatusTone.danger.foreground) }
            }
            Spacer()
            StateBadge(l.badge)
        }
        .padding(.vertical, ADSpace.l)
        .overlay(alignment: .bottom) { if n < 4 { Rectangle().fill(ADColor.line).frame(height: 1) } }
        .accessibilityElement(children: .combine)
    }
}
