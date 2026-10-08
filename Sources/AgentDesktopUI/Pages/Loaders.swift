import AgentDesktopContracts
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

    public var presentation: ActionResultPresentation {
        ActionResultPresentation.make(receipt: receipt, errorCode: errorCode)
    }
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
        for e in events {
            let type = e["type"]?.stringValue ?? ""
            guard type.hasPrefix("action.") else { continue }
            if type == "action.accepted", let id = e["data"]?["requestId"]?.stringValue {
                accepted.append((id, e["at"]?.stringValue))
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
            out.append(ActionEntry(runId: runId, requestId: id, at: at, receipt: receipt, errorCode: reason))
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
