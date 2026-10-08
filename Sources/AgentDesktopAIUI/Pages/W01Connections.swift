import AgentDesktopProtocol
import Foundation
import SwiftUI

/// One row of W01. Holds no secret: the credential is a reference shown masked.
public struct ConnectionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseUrl: String
    public let protocolName: String
    public let credentialSummary: String
    public let enabled: Bool
    public let revision: Int
    public let updatedAt: String

    init(_ v: JSONValue) {
        id = v["connectionId"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? ""
        baseUrl = v["baseUrl"]?.stringValue ?? ""
        protocolName = v["protocol"]?.stringValue ?? ""
        credentialSummary = "已保存凭据 " + Format.masked(v["credentialRef"]?.stringValue)
        enabled = v["state"]?.stringValue == "enabled"
        revision = v["revision"]?.intValue ?? 0
        updatedAt = v["updatedAt"]?.stringValue ?? ""
    }
}

/// W01 — AI 连接.
@MainActor
public final class ConnectionsModel: ObservableObject {
    @Published public private(set) var rows: [ConnectionRow] = []
    @Published public private(set) var phase: LoadPhase = .idle
    @Published public private(set) var lastLoadedAt: Date?
    @Published public private(set) var problem: UIProblem?
    @Published public var search = ""
    @Published public private(set) var busyRowId: String?

    let client: ContractClient
    private var disableKeys: [String: SubmissionKey] = [:]
    private var deleteKeys: [String: SubmissionKey] = [:]

    public init(client: ContractClient) { self.client = client }

    public enum EmptyKind: Equatable { case none, noConnections, noMatch }

    public var visibleRows: [ConnectionRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? rows : rows.filter { $0.name.lowercased().contains(q) }
    }

    /// Two different empty states: nothing configured vs. nothing matches.
    public var emptyKind: EmptyKind {
        if phase == .loading && rows.isEmpty { return .none }
        if rows.isEmpty && lastLoadedAt != nil { return .noConnections }
        if !rows.isEmpty && visibleRows.isEmpty { return .noMatch }
        return .none
    }

    /// Reads the list. A failure keeps the last good list and its time.
    public func refresh() async {
        phase = .loading
        do {
            let r = try await client.send("ai.connections.list", .obj([("limit", .int(100)), ("includeDisabled", .bool(true))]))
            rows = (r["items"]?.arrayValue ?? []).map(ConnectionRow.init)
            lastLoadedAt = Date()
            problem = nil
            phase = .loaded
        } catch {
            problem = UIProblem(error)
            phase = .failed
        }
    }

    /// Disable blocks new bindings; existing runs keep their snapshot.
    public func disable(_ row: ConnectionRow) async {
        busyRowId = row.id
        defer { busyRowId = nil }
        let params = JSONValue.obj([("connectionId", .string(row.id)), ("expectedRevision", .int(row.revision))])
        var key = disableKeys[row.id] ?? SubmissionKey()
        let k = key.key(for: params, prefix: "w01-disable")
        disableKeys[row.id] = key
        do {
            let updated = try await client.send("ai.connections.disable", params, idempotencyKey: k)
            disableKeys[row.id] = nil
            if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i] = ConnectionRow(updated) }
            problem = nil
        } catch {
            problem = UIProblem(error)
        }
    }

    /// Soft delete; refused while referenced, never cascading.
    public func delete(_ row: ConnectionRow) async {
        busyRowId = row.id
        defer { busyRowId = nil }
        let params = JSONValue.obj([("connectionId", .string(row.id)), ("expectedRevision", .int(row.revision))])
        var key = deleteKeys[row.id] ?? SubmissionKey()
        let k = key.key(for: params, prefix: "w01-delete")
        deleteKeys[row.id] = key
        do {
            _ = try await client.send("ai.connections.delete", params, idempotencyKey: k)
            deleteKeys[row.id] = nil
            rows.removeAll { $0.id == row.id }
            problem = nil
        } catch {
            problem = UIProblem(error)
        }
    }
}

public struct ConnectionsView: View {
    @ObservedObject var model: ConnectionsModel
    var onAdd: () -> Void
    var onEdit: (String) -> Void
    var onTest: (String) -> Void

    public init(model: ConnectionsModel, onAdd: @escaping () -> Void = {}, onEdit: @escaping (String) -> Void = { _ in },
                onTest: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onAdd = onAdd
        self.onEdit = onEdit
        self.onTest = onTest
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 连接").font(.title2).bold().accessibilityAddTraits(.isHeader)
                Spacer()
                TextField("按名称搜索", text: $model.search).frame(maxWidth: 220)
                Button("刷新") { Task { await model.refresh() } }.disabled(model.phase == .loading)
                Button("添加连接", action: onAdd).keyboardShortcut("n")
            }
            if let p = model.problem { ProblemBanner(problem: p, retry: { Task { await model.refresh() } }) }
            if let t = model.lastLoadedAt {
                Text("数据时间 \(t.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
            switch model.emptyKind {
            case .noConnections:
                EmptyState(title: "AI 未配置",
                           detail: "添加一个连接后才能配置 GUI 模型。直接 API 与确定性回放不受影响，仍然可用。",
                           action: ("添加连接", onAdd))
            case .noMatch:
                EmptyState(title: "没有匹配的连接", detail: "换一个名称再搜索。", action: nil)
            case .none:
                if model.phase == .loading && model.rows.isEmpty {
                    ProgressView("正在读取…").accessibilityLabel("正在读取连接列表")
                } else {
                    Table(model.visibleRows) {
                        TableColumn("名称与端点") { r in
                            VStack(alignment: .leading) { Text(r.name).bold(); Text(r.baseUrl).font(.caption).foregroundStyle(.secondary) }
                        }
                        TableColumn("协议与凭据") { r in
                            VStack(alignment: .leading) { Text(r.protocolName); Text(r.credentialSummary).font(.caption) }
                        }
                        TableColumn("状态") { r in
                            Text("\(r.enabled ? "已启用" : "已停用") · r\(r.revision)")
                        }
                        TableColumn("操作") { r in
                            HStack {
                                Button("编辑") { onEdit(r.id) }
                                Button("测试") { onTest(r.id) }.disabled(!r.enabled)
                                Button("停用") { Task { await model.disable(r) } }.disabled(!r.enabled || model.busyRowId == r.id)
                                Button("删除", role: .destructive) { Task { await model.delete(r) } }.disabled(model.busyRowId == r.id)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .task { if model.phase == .idle { await model.refresh() } }
    }
}
