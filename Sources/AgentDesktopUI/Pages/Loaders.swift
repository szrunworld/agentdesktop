import AgentDesktopProtocol
import Foundation

/// One action as a page lists it: the receipt from an `action.*` Run event
/// and, for an input that was not sent, the error code its request ended
/// with (request.show), which says why.
public struct ActionEntry: Equatable, Sendable {
    public let runId: String
    public let requestId: String
    public let at: String?
    public let receipt: JSONValue?
    public let errorCode: String?
    /// `action.refused`'s FailureReason: refused before anything was sent.
    public let refused: JSONValue?

    public init(runId: String, requestId: String, at: String?, receipt: JSONValue?, errorCode: String?,
                refused: JSONValue? = nil) {
        self.runId = runId
        self.requestId = requestId
        self.at = at
        self.receipt = receipt
        self.errorCode = errorCode
        self.refused = refused
    }

    public var presentation: ActionResultPresentation {
        if receipt == nil, let refused {
            return ActionResultPresentation(level: .notDispatched, title: "未发出", tone: .danger,
                                            reasonCode: refused["code"]?.stringValue ?? errorCode, canRetry: false,
                                            needsReconciliation: false,
                                            businessResult: ActionResultPresentation.businessNotEvaluated)
        }
        return ActionResultPresentation.make(receipt: receipt, errorCode: errorCode)
    }

    /// The three levels (§6.4) the Runs pages show.
    public var levels: ActionLevels { ActionLevels.receipt(receipt, errorCode: errorCode, refused: refused) }
}

/// Reads a Run's events incrementally (run.events from the last `next`) and
/// derives the actions from them. Event types are not frozen yet
/// (docs/plan/10 F1-01), so only the shape this needs is read: an
/// `action.accepted` names a request; a later `action.*` with
/// `data.receipt` carries its receipt.
@MainActor
final class RunEventReader {
    let runId: String
    private(set) var events: [JSONValue] = []
    private(set) var next = 0
    private var reasons: [String: String] = [:]

    init(runId: String) { self.runId = runId }

    /// Pull every new event; true when anything arrived.
    func pull(_ runtime: RuntimePort) async throws -> Bool {
        var grew = false
        while true {
            let page = try await runtime.call("run.events", .obj([("runId", .string(runId)), ("after", .int(next)),
                                                                  ("limit", .int(500))]))
            let batch = page["events"]?.arrayValue ?? []
            events.append(contentsOf: batch)
            next = page["next"]?.intValue ?? next
            grew = grew || !batch.isEmpty
            if batch.count < 500 { return grew }
        }
    }

    /// Requests accepted in this Run, newest first, with their receipts.
    func actions(_ runtime: RuntimePort) async -> [ActionEntry] {
        var accepted: [(String, String?)] = []
        var receipts: [String: JSONValue] = [:]
        var refusals: [String: JSONValue] = [:]
        for e in events {
            let type = e["type"]?.stringValue ?? ""
            guard type.hasPrefix("action.") else { continue }
            if type == "action.accepted", let id = e["data"]?["requestId"]?.stringValue {
                accepted.append((id, e["at"]?.stringValue))
            } else if type == "action.refused", let id = e["data"]?["requestId"]?.stringValue {
                refusals[id] = e["data"]?["reason"] ?? .obj([])
            } else if let r = e["data"]?["receipt"], let id = r["requestId"]?.stringValue {
                receipts[id] = r
            }
        }
        var out: [ActionEntry] = []
        for (id, at) in accepted.reversed() {
            let receipt = receipts[id]
            var reason: String?
            if let receipt, receipt["delivery"]?.stringValue != "dispatched" || receipt["execution"]?.stringValue == "failed" {
                if let known = reasons[id] {
                    reason = known
                } else if let record = try? await runtime.call("request.show", .obj([("requestId", .string(id))])),
                          let code = record["outcome"]?["error"]?["code"]?.stringValue {
                    reasons[id] = code
                    reason = code
                }
            }
            out.append(ActionEntry(runId: runId, requestId: id, at: at, receipt: receipt,
                                   errorCode: reason ?? receipt?["reason"]?["code"]?.stringValue, refused: refusals[id]))
        }
        return out
    }
}

/// A Run's detail: run.show plus its events and actions, re-read on every
/// update round of the Store (`tick`), whether that round was a poll or a
/// pushed event.
@MainActor
public final class RunDetailLoader: ObservableObject {
    public let runId: String
    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var run: JSONValue?
    @Published public private(set) var events: [JSONValue] = []
    @Published public private(set) var actions: [ActionEntry] = []
    @Published public private(set) var syncedAt: Date?
    /// A stop request is in flight.
    @Published public private(set) var stopping = false
    /// What `run.cancel` answered, in words (accepted, phase, quiescence).
    @Published public private(set) var stopAnswer: String?
    @Published public private(set) var stopProblem: RuntimeProblem?

    private let runtime: RuntimePort
    private let reader: RunEventReader
    private var ticket = 0

    public init(runtime: RuntimePort, runId: String) {
        self.runtime = runtime
        self.runId = runId
        self.reader = RunEventReader(runId: runId)
    }

    public func load() async {
        ticket += 1
        let mine = ticket
        do {
            let r = try await runtime.call("run.show", .obj([("runId", .string(runId))]))
            _ = try await reader.pull(runtime)
            let acts = await reader.actions(runtime)
            guard mine == ticket else { return }
            run = r
            events = reader.events
            actions = acts
            syncedAt = Date()
            state = .loaded
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }

    /// `run.cancel`: shows the Runtime's answer (accepted; the Run's phase
    /// and quiescence after it), then re-reads the Run. The Run is stopped
    /// only when the Runtime later says ended / confirmed.
    public func stop() async {
        stopping = true
        stopProblem = nil
        defer { stopping = false }
        do {
            let r = try await runtime.call("run.cancel", .obj([("runId", .string(runId))]))
            let x = r["execution"]
            let accepted = r["cancelRequest"]?["accepted"]?.boolValue == true
            if r["alreadyTerminal"]?.boolValue == true {
                stopAnswer = "运行已经结束，无需停止"
            } else {
                stopAnswer = (accepted ? "已受理" : "未受理") + " · phase \(x?["phase"]?.stringValue ?? "—") · quiescence \(x?["quiescence"]?.stringValue ?? "—")"
            }
        } catch {
            stopProblem = RuntimeProblem(error)
        }
        await load()
    }
}

/// Recent actions on one Desktop, from the events of its latest Runs.
@MainActor
public final class DesktopActivityLoader: ObservableObject {
    public let desktopId: String
    @Published public private(set) var actions: [ActionEntry] = []
    @Published public private(set) var problem: RuntimeProblem?

    private let runtime: RuntimePort
    private var readers: [String: RunEventReader] = [:]
    private var ticket = 0
    /// How many of the Desktop's latest Runs are read.
    public let runLimit: Int

    public init(runtime: RuntimePort, desktopId: String, runLimit: Int = 5) {
        self.runtime = runtime
        self.desktopId = desktopId
        self.runLimit = runLimit
    }

    public func load(runs: [JSONValue]) async {
        ticket += 1
        let mine = ticket
        let ids = runs.filter { $0["desktopId"]?.stringValue == desktopId }
            .sorted { ($0["createdAt"]?.stringValue ?? "") > ($1["createdAt"]?.stringValue ?? "") }
            .prefix(runLimit).compactMap { $0["runId"]?.stringValue }
        var all: [ActionEntry] = []
        do {
            for id in ids {
                let reader = readers[id] ?? RunEventReader(runId: id)
                readers[id] = reader
                _ = try await reader.pull(runtime)
                all += await reader.actions(runtime)
            }
            guard mine == ticket else { return }
            actions = all.sorted { ($0.at ?? "") > ($1.at ?? "") }
            problem = nil
        } catch {
            guard mine == ticket else { return }
            problem = RuntimeProblem(error)
        }
    }
}

// MARK: Runs (U5)

/// Runs › 全部运行 (Hub W04): `run.list` with the page's filters, newest
/// first, more pages with the Runtime's cursor. Re-read on every update
/// round of the Store (`tick`), whether that round was a push or a poll.
@MainActor
public final class RunListLoader: ObservableObject {
    public struct Filter: Equatable, Sendable {
        /// true: only Runs not ended (`active`); false: only ended Runs,
        /// asked as `phase: ended` (the Runtime reads `active: false` as
        /// "no filter").
        public var active: Bool?
        public var origin: String?
        public var desktopId: String?
        public var clientId: String?
        /// Client-side only: `run.list` has no outcome filter.
        public var unknownOnly = false

        public init(active: Bool? = nil, origin: String? = nil, desktopId: String? = nil, clientId: String? = nil,
                    unknownOnly: Bool = false) {
            self.active = active
            self.origin = origin
            self.desktopId = desktopId
            self.clientId = clientId
            self.unknownOnly = unknownOnly
        }

        var params: [(String, JSONValue)] {
            var p: [(String, JSONValue)] = []
            switch active {
            case true?: p.append(("active", .bool(true)))
            case false?: p.append(("phase", .string("ended")))
            case nil: break
            }
            if let origin { p.append(("origin", .string(origin))) }
            if let desktopId { p.append(("desktopId", .string(desktopId))) }
            if let clientId { p.append(("clientId", .string(clientId))) }
            return p
        }
    }

    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var runs: [JSONValue] = []
    @Published public private(set) var next: String?
    @Published public private(set) var syncedAt: Date?
    @Published public private(set) var loadingMore = false
    public private(set) var filter = Filter()

    private let runtime: RuntimePort
    private let pageSize: Int
    private var ticket = 0

    public init(runtime: RuntimePort, pageSize: Int = 50) {
        self.runtime = runtime
        self.pageSize = pageSize
    }

    /// Runs as shown: the unknown-only filter is applied here.
    public var shown: [JSONValue] {
        filter.unknownOnly ? runs.filter { $0["outcome"]?.stringValue == "unknown" || ($0["unknownActions"]?.intValue ?? 0) > 0 } : runs
    }

    /// New filter: start over from the first page; answers for the old
    /// filter are dropped.
    public func apply(_ f: Filter) async {
        if f != filter {
            filter = f
            runs = []
            next = nil
            syncedAt = nil
            state = .loading
        }
        await reload()
    }

    /// Re-read from the top, as many Runs as are shown (at most 200, the
    /// contract's page limit); pages beyond stay as they were.
    public func reload() async {
        ticket += 1
        let mine = ticket
        let limit = min(200, max(pageSize, runs.count))
        do {
            let r = try await runtime.call("run.list", .obj(filter.params + [("limit", .int(limit))]))
            guard mine == ticket else { return }
            let first = r["runs"]?.arrayValue ?? []
            let rest = runs.count > limit ? Self.tail(after: first, of: runs, key: "runId") : []
            runs = first + rest
            if rest.isEmpty { next = r["next"]?.stringValue }
            syncedAt = Date()
            state = runs.isEmpty ? .empty : .loaded
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }

    /// The pages loaded beyond a re-read first page, by identity: what came
    /// after the last item the new first page shares with the old list
    /// (items pushed across the page boundary by newer ones stay; items
    /// that left the first page's range are dropped), without repeats.
    static func tail(after first: [JSONValue], of old: [JSONValue], key: String) -> [JSONValue] {
        let ids = Set(first.compactMap { $0[key]?.stringValue })
        let shared = old.lastIndex { ids.contains($0[key]?.stringValue ?? "") }
        let from = shared.map { $0 + 1 } ?? 0
        return old[from...].filter { !ids.contains($0[key]?.stringValue ?? "") }
    }

    /// The next page after `next`.
    public func loadMore() async {
        guard let cursor = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let mine = ticket
        do {
            let r = try await runtime.call("run.list", .obj(filter.params + [("cursor", .string(cursor)), ("limit", .int(pageSize))]))
            guard mine == ticket else { return }
            let known = Set(runs.compactMap { $0["runId"]?.stringValue })
            runs += (r["runs"]?.arrayValue ?? []).filter { !known.contains($0["runId"]?.stringValue ?? "") }
            next = r["next"]?.stringValue
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }
}

/// Runs › 动作记录 (P19): the request ledger from `request.list` with its
/// filters and cursor; `request.export` writes the same records into an
/// artifact, read back with `artifact.read`.
@MainActor
public final class ActionRecordsLoader: ObservableObject {
    public struct Filter: Equatable, Sendable {
        public var desktopId: String?
        public var state: String?
        public var method: String?
        public var clientId: String?

        public init(desktopId: String? = nil, state: String? = nil, method: String? = nil, clientId: String? = nil) {
            self.desktopId = desktopId
            self.state = state
            self.method = method
            self.clientId = clientId
        }

        var params: [(String, JSONValue)] {
            var p: [(String, JSONValue)] = []
            if let method { p.append(("method", .string(method))) }
            if let state { p.append(("state", .string(state))) }
            if let desktopId { p.append(("desktopId", .string(desktopId))) }
            if let clientId { p.append(("clientId", .string(clientId))) }
            return p
        }
    }

    /// What `request.export` gave, with the document read back.
    public struct Export: Equatable, Sendable {
        public let artifactId: String
        public let count: Int
        public let truncated: Bool
        public let data: Data
    }

    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var records: [JSONValue] = []
    @Published public private(set) var next: String?
    @Published public private(set) var syncedAt: Date?
    @Published public private(set) var export: Export?
    @Published public private(set) var exporting = false
    @Published public private(set) var exportProblem: RuntimeProblem?
    public private(set) var filter = Filter()

    private let runtime: RuntimePort
    private let pageSize: Int
    private var ticket = 0

    public init(runtime: RuntimePort, pageSize: Int = 50) {
        self.runtime = runtime
        self.pageSize = pageSize
    }

    /// Records whose requestId, method or Desktop matches `text`, among
    /// those loaded (request.list has no text search).
    public func search(_ text: String) -> [JSONValue] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return records }
        return records.filter { r in
            ["requestId", "method", "desktopId", "clientId"].contains { (r[$0]?.stringValue ?? "").lowercased().contains(q) }
        }
    }

    public func apply(_ f: Filter) async {
        if f != filter {
            filter = f
            records = []
            next = nil
            syncedAt = nil
            state = .loading
        }
        await reload()
    }

    /// The first page again, as many as are shown (at most 100).
    public func reload() async {
        ticket += 1
        let mine = ticket
        let limit = min(100, max(pageSize, records.count))
        do {
            let r = try await runtime.call("request.list", .obj(filter.params + [("limit", .int(limit))]))
            guard mine == ticket else { return }
            let first = r["requests"]?.arrayValue ?? []
            let rest = records.count > limit ? RunListLoader.tail(after: first, of: records, key: "requestId") : []
            records = first + rest
            if rest.isEmpty { next = r["next"]?.stringValue }
            syncedAt = Date()
            state = records.isEmpty ? .empty : .loaded
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }

    public func loadMore() async {
        guard let cursor = next else { return }
        let mine = ticket
        do {
            let r = try await runtime.call("request.list", .obj(filter.params + [("cursor", .string(cursor)), ("limit", .int(pageSize))]))
            guard mine == ticket else { return }
            let known = Set(records.compactMap { $0["requestId"]?.stringValue })
            records += (r["requests"]?.arrayValue ?? []).filter { !known.contains($0["requestId"]?.stringValue ?? "") }
            next = r["next"]?.stringValue
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }

    /// `request.export` with the current filter, then the whole artifact by
    /// `artifact.read` chunks. The page offers to save the bytes.
    public func exportRecords() async {
        exporting = true
        exportProblem = nil
        defer { exporting = false }
        do {
            let r = try await runtime.call("request.export", .obj(filter.params))
            guard let id = r["artifact"]?["artifactId"]?.stringValue else {
                throw RuntimeError("internal_error", "request.export gave no artifact", phase: .handler)
            }
            let data = try await Self.readArtifact(runtime, id)
            export = Export(artifactId: id, count: r["count"]?.intValue ?? 0, truncated: r["truncated"]?.boolValue ?? false,
                            data: data)
        } catch {
            exportProblem = RuntimeProblem(error)
        }
    }

    static func readArtifact(_ runtime: RuntimePort, _ id: String) async throws -> Data {
        var data = Data()
        while true {
            let chunk = try await runtime.call("artifact.read", .obj([("artifactId", .string(id)), ("offset", .int(data.count))]))
            guard let b64 = chunk["dataBase64"]?.stringValue, let bytes = Data(base64Encoded: b64) else {
                throw RuntimeError("internal_error", "artifact.read gave no data", phase: .handler)
            }
            data.append(bytes)
            if chunk["eof"]?.boolValue ?? true || bytes.isEmpty { return data }
        }
    }
}
