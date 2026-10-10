import AgentDesktopProtocol
import Foundation
import SwiftUI

/// One level of the four-level test as the page shows it.
public struct LevelRow: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case pending, passed, failed, skipped }
    public let id: String
    public let label: String
    public let doesNotMean: String
    public var status: Status
    public var reasonCode: String?
    public var httpStatus: Int?
    public var latencyMs: Int?

    public var statusText: String {
        switch status {
        case .pending: return "未完成"
        case .passed: return "通过"
        case .failed: return "失败"
        case .skipped: return "未执行（前一层未通过）"
        }
    }

    static func initial() -> [LevelRow] {
        [LevelRow(id: "network", label: "T1 网络与端点", doesNotMean: "不代表认证或模型可用", status: .pending),
         LevelRow(id: "auth_model", label: "T2 认证与目标模型", doesNotMean: "不代表支持图像", status: .pending),
         LevelRow(id: "image_input", label: "T3 图像输入", doesNotMean: "不代表具备 GUI 结构化协议", status: .pending),
         LevelRow(id: "gui_contract", label: "T4 GUI 输出协议", doesNotMean: "不代表实际任务完成率或输入隔离", status: .pending)]
    }
}

/// W04 — 连接与能力测试. Runs only the synthetic material; never takes
/// a desktop screenshot or gives input.
@MainActor
public final class CapabilityTestModel: ObservableObject {
    public enum Phase: Equatable { case idle, starting, running, cancelling, unknown, finished(String) }

    @Published public var guiProfileId: String?
    @Published public private(set) var guiProfileRevision: Int?
    @Published public private(set) var profiles: [GuiProfileRow] = []
    @Published public private(set) var levels = LevelRow.initial()
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var isPolling = false
    @Published public private(set) var operationId: String?
    @Published public private(set) var problem: UIProblem?
    @Published public private(set) var performedDesktopInput: Bool?
    @Published public private(set) var evidence: [String: String] = [:]

    public nonisolated static let costNotice = "测试使用固定的合成素材，不截取桌面、不执行输入；会向模型发送最多 3 次请求，可能产生费用。"

    let client: ContractClient
    let clock: PollClock
    let pollMs: Int
    private var startKey = SubmissionKey()

    public init(client: ContractClient, guiProfileId: String? = nil, clock: PollClock = SystemPollClock(), pollMs: Int = 500) {
        self.client = client
        self.guiProfileId = guiProfileId
        self.clock = clock
        self.pollMs = pollMs
    }

    public func loadProfiles() async {
        do {
            let r = try await client.send("ai.profiles.list", .obj([("limit", .int(100))]))
            profiles = (r["items"]?.arrayValue ?? []).map(GuiProfileRow.init)
            if guiProfileId == nil { guiProfileId = profiles.first?.id }
        } catch { problem = UIProblem(error) }
    }

    public var canStart: Bool {
        guard guiProfileId != nil else { return false }
        switch phase {
        case .idle, .finished: return true
        default: return false
        }
    }

    /// Starts once; a retry after a lost answer reuses the same key.
    public func start() async {
        guard canStart, let id = guiProfileId else { return }
        phase = .starting
        problem = nil
        levels = LevelRow.initial()
        performedDesktopInput = nil
        do {
            let p = try await client.send("ai.profiles.get", .obj([("guiProfileId", .string(id))]))
            let rev = p["revision"]?.intValue ?? 1
            guiProfileRevision = rev
            let params = JSONValue.obj([("guiProfileId", .string(id)), ("expectedRevision", .int(rev)),
                                        ("fixtureId", .string("synthetic_gui_v1"))])
            let r = try await client.send("ai.tests.start", params, idempotencyKey: startKey.key(for: params, prefix: "w04-test"))
            operationId = r["operationId"]?.stringValue
            phase = .running
            await poll()
            startKey.reset()
        } catch {
            problem = UIProblem(error)
            phase = .idle
        }
    }

    /// Reads the operation until it ends. Levels never finished stay unfinished.
    public func poll() async {
        guard let op = operationId, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        var failures = 0
        while true {
            do {
                let o = try await client.send("ai.operations.get", .obj([("operationId", .string(op))]))
                failures = 0
                problem = nil
                apply(o)
                if let s = o["state"]?.stringValue, ["succeeded", "failed", "cancelled"].contains(s) {
                    phase = .finished(s)
                    return
                }
                if o["state"]?.stringValue == "cancelling" { phase = .cancelling }
                else if phase == .unknown { phase = .running }
                try await clock.pause(milliseconds: pollMs)
            } catch is CancellationError {
                if case .finished = phase {} else { phase = .unknown }
                return
            } catch {
                problem = UIProblem(error)
                failures += 1
                guard failures < 3 else { phase = .unknown; return }
                do { try await clock.pause(milliseconds: pollMs * failures) }
                catch { if case .finished = phase {} else { phase = .unknown }; return }
            }
        }
    }

    func apply(_ o: JSONValue) {
        for l in o["result"]?["levels"]?.arrayValue ?? [] {
            guard let id = l["level"]?.stringValue, let i = levels.firstIndex(where: { $0.id == id }) else { continue }
            levels[i].status = LevelRow.Status(rawValue: l["status"]?.stringValue ?? "") ?? .pending
            levels[i].reasonCode = l["reasonCode"]?.stringValue
            levels[i].httpStatus = l["httpStatus"]?.intValue
            levels[i].latencyMs = l["latencyMs"]?.intValue
        }
        if let caps = o["result"]?["capabilities"]?.objectMembers {
            evidence = Dictionary(uniqueKeysWithValues: caps.map { ($0.key, $0.value["status"]?.stringValue ?? "unknown") })
        }
        performedDesktopInput = o["result"]?["performedDesktopInput"]?.boolValue
        if let e = o["error"], !e.isNull {
            problem = UIProblem(ContractError(ErrorCode(rawValue: e["code"]?.stringValue ?? "") ?? .internalError,
                                              e["message"]?.stringValue ?? ""))
        }
    }

    /// Accepting a cancel shows "cancelling" first; the end state comes from get.
    public func cancel() async {
        guard let op = operationId else { return }
        do {
            let r = try await client.send("ai.operations.cancel", .obj([("operationId", .string(op))]),
                                          idempotencyKey: "w04-cancel-\(op)")
            if r["terminal"]?.boolValue == true {
                phase = .finished(r["state"]?.stringValue ?? "cancelled")
            } else {
                phase = .cancelling
            }
        } catch { problem = UIProblem(error) }
    }

    public var allPassed: Bool { levels.allSatisfy { $0.status == .passed } }
}

public struct CapabilityTestView: View {
    @ObservedObject var model: CapabilityTestModel

    public init(model: CapabilityTestModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接与能力测试").font(.title2).bold().accessibilityAddTraits(.isHeader)
            Text(CapabilityTestModel.costNotice).font(.callout)
            HStack {
                Picker("GUI 配置", selection: $model.guiProfileId) {
                    ForEach(model.profiles) { p in Text("\(p.name) r\(p.revision)").tag(Optional(p.id)) }
                }.frame(maxWidth: 360)
                Button("开始测试") { Task { await model.start() } }.disabled(!model.canStart)
                Button("取消") { Task { await model.cancel() } }.disabled(model.phase != .running)
            }
            if let p = model.problem { ProblemBanner(problem: p) }
            switch model.phase {
            case .cancelling: Text("取消中…未完成的层不会被标为通过。").accessibilityAddTraits(.updatesFrequently)
            case let .finished(s): Text("测试结束：\(s == "succeeded" ? "完成" : s == "cancelled" ? "已取消" : "失败")")
            case .running, .starting: ProgressView("测试进行中")
            case .unknown:
                Text("测试状态未知，尚未确认结束。")
                Button("重新查询状态") { Task { await model.poll() } }.disabled(model.isPolling)
            case .idle: EmptyView()
            }
            ForEach(model.levels) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(l.label).bold()
                        Spacer()
                        Text(l.statusText).accessibilityLabel("\(l.label)：\(l.statusText)")
                    }
                    Text(l.doesNotMean).font(.caption).foregroundStyle(.secondary)
                    if let r = l.reasonCode { Text("原因 \(r)").font(.caption) }
                    if let h = l.httpStatus { Text("HTTP \(h)\(l.latencyMs.map { " · \($0) ms" } ?? "")").font(.caption2) }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
            if let input = model.performedDesktopInput { LabeledValue(label: "实际桌面输入", value: input ? "有（异常）" : "0") }
            if let r = model.guiProfileRevision { LabeledValue(label: "测试绑定", value: "GUI 配置 r\(r) · 素材 synthetic_gui_v1") }
            Spacer()
        }
        .padding()
        .task { await model.loadProfiles() }
    }
}
