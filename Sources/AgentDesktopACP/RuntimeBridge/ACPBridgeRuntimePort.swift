import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

/// `ACPRuntimePort` over runtime/1 (`RuntimeClient`) only.
///
/// One instance serves one editor connection. It keeps one control
/// connection to the Runtime: Runs it submits are Delegated
/// (external_client / connection_scoped) and owned by that connection, so
/// `connectionLost()` closes it and the Runtime stops them (ADR v2.2). Event
/// streams use connections of their own, which control no Run.
///
/// All `RuntimeClient` calls are blocking; they run on one serial queue
/// (control) or one thread per stream (events), never on the cooperative
/// pool, and async callers wait at most `callTimeout`.
///
/// Idempotency: the Runtime's request ledger (caller uid + requestId) is the
/// only execution de-dup. The requestId of a submission is derived from the
/// caller and its `submissionKey`; `ACPSubmissionLog` remembers the
/// submission → requestId/runId link so that a retry reads `request.show` /
/// `run.show` and never sends `unit.run` a second time. Unknown stays
/// `.unconfirmed`.
public final class ACPBridgeRuntimePort: ACPRuntimePort, @unchecked Sendable {
    private let makeClient: ACPBridgeClientFactory
    private let log: ACPSubmissionLog
    private let catalog: ACPTaskCatalog
    private let config: ACPBridgeConfiguration
    private let control = ACPBridgeExecutor(label: "acp.bridge.control")

    // Touched only on the control queue.
    private var controlClient: RuntimeClient?
    private var runConnectionId: (instanceId: String, connectionId: String)?
    private var instanceId: String?

    // Guarded by `lock`.
    private let lock = NSLock()
    private var lost = false
    private var readers: [ObjectIdentifier: ACPBridgeEventReader] = [:]

    public init(makeClient: @escaping ACPBridgeClientFactory, log: ACPSubmissionLog,
                catalog: ACPTaskCatalog = ACPTaskCatalog(), config: ACPBridgeConfiguration = ACPBridgeConfiguration()) {
        self.makeClient = makeClient
        self.log = log
        self.catalog = catalog
        self.config = config
    }

    private var isLost: Bool {
        lock.lock(); defer { lock.unlock() }
        return lost
    }

    // MARK: Identity and tasks

    /// From the Runtime's handshake and status, never from editor input.
    /// Until A4/PR2b puts `principal {clientId, role, connectionId}` into the
    /// handshake, the Runtime authenticates every local connection as
    /// `local:<uid>` (owner) by getpeereid on an owner-only socket, and does
    /// not tell the connectionId; the bridge reports the one the Runtime
    /// stamped on a Run of this connection, else `unissued:<instanceId>`.
    public func caller() async throws -> ACPCaller {
        try await onControl { c in
            let id = try c.handshake()
            let status = try c.call(RuntimeRequest(.status))
            guard status["instanceId"]?.stringValue == id.instanceId else {
                throw RuntimeError("instance_mismatch", "runtime.status names another instance than the handshake", phase: .handshake)
            }
            self.instanceId = id.instanceId
            let principal = "local:\(self.config.uid)"
            let conn = self.runConnectionId.flatMap { $0.instanceId == id.instanceId ? $0.connectionId : nil }
                ?? "unissued:\(id.instanceId)"
            // Not authenticated by a Runtime-issued principal yet (R4).
            return ACPCaller(principalId: principal, clientId: principal, connectionId: conn, verified: false)
        }
    }

    public func tasks() async throws -> [ACPExposedTask] {
        try await onControl { c in try self.catalogEntries(c).map(\.task) }
    }

    private func catalogEntries(_ c: RuntimeClient) throws -> [ACPTaskCatalog.Entry] {
        _ = try c.handshake()
        let caps = try c.call(RuntimeRequest(.capabilities))
        let methods = ACPTaskCatalog.methods(caps)
        var profiles: [JSONValue]?
        // ai.* is the owner's. A4 leaves no owner on the socket, so a paired
        // bridge never asks: a verified one would open a confirmation in the
        // owner's window on every listing (Codex on d10d83b), which the
        // bridge must not trigger by itself (Kevin's ruling on #246). Only an
        // owner connection lists profiles; the bridge offers the
        // default-profile task.
        if methods.contains(ACPTaskCatalog.unitRunMethod), methods.contains(ACPTaskCatalog.profilesMethod),
           ACPTaskCatalog.listsProfiles(principal: c.principal) {
            do {
                let r = try c.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: ACPTaskCatalog.profilesMethod,
                                                  params: .obj([])))
                profiles = r["items"]?.arrayValue ?? []
            } catch let e as RuntimeError where ACPTaskCatalog.profilesRefusedToCaller(e) {
                // ai.* is the owner's (A4 R1): a paired bridge is refused it
                // for sure. It then offers the one unit.run task on the
                // Runtime's default profile, as if the method were absent;
                // any other failure still fails the listing (#246).
                profiles = nil
            }
        }
        return catalog.entries(methods: methods, profiles: profiles)
    }

    // MARK: Submission

    public func submit(_ submission: ACPSubmission) async throws -> ACPSubmissionReceipt {
        if isLost { return .refused(code: "connection_lost", message: ACPBridgeErrors.connectionLost.message) }
        do {
            return try await control.run(timeout: config.callTimeout) { try self.submitBlocking(submission) }
        } catch is ACPBridgeTimeout {
            // The job goes on and records what the Runtime answers; a retry reads it.
            return .unconfirmed
        } catch let e as ACPError {
            throw e
        } catch {
            throw ACPBridgeErrors.map(error)
        }
    }

    private func submitBlocking(_ s: ACPSubmission) throws -> ACPSubmissionReceipt {
        if isLost { return .refused(code: "connection_lost", message: ACPBridgeErrors.connectionLost.message) }
        if let entry = log.entry(s.submissionKey) { return recover(entry) }

        let c = client()
        let entries: [ACPTaskCatalog.Entry]
        do {
            entries = try catalogEntries(c)
        } catch let e as RuntimeError {
            return .refused(code: e.code, message: e.message)
        }
        guard let entry = entries.first(where: { $0.task.taskType == s.taskType }) else {
            if entries.isEmpty {
                return .refused(code: "capability_missing",
                                message: "this Runtime offers no task entry (\(ACPTaskCatalog.unitRunMethod) is not available)")
            }
            return .refused(code: "not_found", message: "no task \(s.taskType) is offered to this caller")
        }
        let params: JSONValue
        switch catalog.params(for: entry, submission: s) {
        case let .success(p): params = p
        case let .failure(.refused(code, message)): return .refused(code: code, message: message)
        }

        let requestId = ACPSubmissionLog.requestId(principalId: "local:\(config.uid)", submissionKey: s.submissionKey)
        // Write-ahead: from here on a retry only queries.
        try log.record(.init(submissionKey: s.submissionKey, requestId: requestId, method: entry.method,
                             state: .sending, updatedAt: log.stampNow()))
        let run: JSONValue
        do {
            run = try c.call(RuntimeRequest(requestId: requestId, method: entry.method, params: params))
        } catch let e as RuntimeError {
            if e.notSent == true {
                // Not performed (#170): certainly no input and no write went
                // out, so there is no outcome to protect. The editor may submit
                // again; that is judged again like any request.
                try? log.remove(s.submissionKey)
                return .refused(code: e.code, message: e.message)
            }
            if Self.answerUnknown(e) { return .unconfirmed }
            // Done, only the answer withheld: the caller lost its access while
            // the Runtime worked (#203, b9 on 38edddd). Never a refusal: the
            // entry stays `.sending`, so a later look reads the outcome with
            // the same requestId and nothing is sent again.
            if e.details?["writeOutcome"]?.stringValue == "completed" { return .unconfirmed }
            try? log.record(.init(submissionKey: s.submissionKey, requestId: requestId, method: entry.method, state: .refused,
                                  refusalCode: e.code, refusalMessage: e.message, updatedAt: log.stampNow()))
            return .refused(code: e.code, message: e.message)
        }
        guard let snapshot = Self.snapshot(run) else { return .unconfirmed }
        noteConnection(run)
        try? log.record(.init(submissionKey: s.submissionKey, requestId: requestId, method: entry.method, state: .accepted,
                              runId: snapshot.runId, updatedAt: log.stampNow()))
        return .accepted(snapshot)
    }

    /// A submission seen before: read back, never send again.
    private func recover(_ entry: ACPSubmissionLog.Entry) -> ACPSubmissionReceipt {
        switch entry.state {
        case .refused:
            return .refused(code: entry.refusalCode ?? "execution_failed", message: entry.refusalMessage ?? "")
        case .accepted:
            guard let runId = entry.runId else { return .unconfirmed }
            if let run = try? client().call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))]))),
               let snap = Self.snapshot(run) {
                return .duplicate(snap)
            }
            return .unconfirmed
        case .sending:
            guard let record = try? client().call(RuntimeRequest(.requestShow, params: .obj([("requestId", .string(entry.requestId))])))
            else {
                // not_found included: the ledger cannot vouch either way.
                return .unconfirmed
            }
            switch record["state"]?.stringValue {
            case "completed":
                guard let run = record["outcome"]?["data"], let snap = Self.snapshot(run) else { return .unconfirmed }
                try? log.record(.init(submissionKey: entry.submissionKey, requestId: entry.requestId, method: entry.method,
                                      state: .accepted, runId: snap.runId, updatedAt: log.stampNow()))
                // The Run's current state, not the one at acceptance.
                if let now = try? client().call(RuntimeRequest(.runShow, params: .obj([("runId", .string(snap.runId))]))),
                   let current = Self.snapshot(now) {
                    return .duplicate(current)
                }
                return .duplicate(snap)
            case "failed":
                let e = record["outcome"]?["error"].flatMap(RuntimeError.init(json:))
                let code = e?.code ?? "execution_failed", message = e?.message ?? "the original request failed"
                try? log.record(.init(submissionKey: entry.submissionKey, requestId: entry.requestId, method: entry.method,
                                      state: .refused, refusalCode: code, refusalMessage: message, updatedAt: log.stampNow()))
                return .refused(code: code, message: message)
            default:
                // accepted (still running) or unknown (Runtime restarted).
                return .unconfirmed
            }
        }
    }

    /// Sent, and the answer may have been lost.
    static func answerUnknown(_ e: RuntimeError) -> Bool {
        if ["connection_lost", "request_acceptance_unknown", "action_delivery_unknown", "cancel_acceptance_unknown"].contains(e.code) {
            return true
        }
        return e.phase == .transport
    }

    // MARK: Runs

    public func snapshot(runId: String) async throws -> ACPRunSnapshot {
        try await onControl { c in
            let run = try c.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))
            guard let s = Self.snapshot(run) else {
                throw RuntimeError("instance_mismatch", "run.show answered without a Run", phase: .transport)
            }
            return s
        }
    }

    /// run.cancel under the caller's requestId, so a repeat is the same
    /// cancel (ledgered). The answer is the acceptance; quiescence follows
    /// and is read with `snapshot` or seen in events.
    public func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot {
        try await onControl { c in
            let receipt: JSONValue
            do {
                receipt = try c.call(RuntimeRequest(.runCancel, requestId: requestId, params: .obj([("runId", .string(runId))])))
            } catch let e as RuntimeError where Self.answerUnknown(e) {
                throw RuntimeError("cancel_acceptance_unknown",
                                   "\(e.message); repeat the cancel with the same requestId to learn whether it was accepted",
                                   phase: .transport, details: .obj([("requestId", .string(requestId))]))
            }
            let ex = receipt["execution"]
            let lifetime = (try? c.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))]))))?["lifetime"]?.stringValue
            return ACPRunSnapshot(runId: runId, phase: ex?["phase"]?.stringValue ?? "stopping",
                                  outcome: ex?["outcome"]?.stringValue, quiescence: ex?["quiescence"]?.stringValue ?? "pending",
                                  lifetime: lifetime ?? "unknown")
        }
    }

    public func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        AsyncThrowingStream { cont in
            let reader = ACPBridgeEventReader(runId: runId, after: cursor, makeClient: makeClient, config: config,
                                              continuation: cont)
            lock.lock()
            if lost {
                lock.unlock()
                cont.finish(throwing: ACPBridgeErrors.connectionLost)
                return
            }
            readers[ObjectIdentifier(reader)] = reader
            lock.unlock()
            cont.onTermination = { [weak self] _ in
                reader.stop()
                guard let self else { return }
                self.lock.lock()
                self.readers[ObjectIdentifier(reader)] = nil
                self.lock.unlock()
            }
            reader.start()
        }
    }

    // MARK: Approvals and questions

    // runtime/1 has no approval or question methods yet (README §二.5; Inbox
    // is reserved for PR4). These throw `capability_missing`; the server
    // treats that as a refusal, never as an approval.

    public func pending(runId: String) async throws -> [ACPPendingDecision] {
        throw ACPBridgeErrors.capabilityMissing("runtime/1 has no approval or question listing yet (inbox.list, PR4)")
    }

    public func decide(approvalId: String, allow: Bool) async throws {
        throw ACPBridgeErrors.capabilityMissing("runtime/1 cannot take an approval decision yet (inbox.resolve, PR4); treated as denied")
    }

    public func answer(questionId: String, text: String) async throws {
        throw ACPBridgeErrors.capabilityMissing("runtime/1 cannot take an answer yet (inbox.resolve, PR4)")
    }

    // MARK: Connection loss

    /// The editor is gone. Close the control connection so the Runtime
    /// applies ADR v2.2 to the Delegated Runs it owns (no new input,
    /// stopping, ended with owner_lost). The bridge stops nothing itself, does
    /// not reconnect and refuses further work.
    public func connectionLost() async {
        guard let open = markLost() else { return }
        open.forEach { $0.finish() }
        _ = try? await control.run(timeout: config.callTimeout) {
            self.controlClient?.close()
            self.controlClient = nil
        }
    }

    // MARK: Helpers

    /// Set the lost flag once; the open streams to end, or nil if already lost.
    private func markLost() -> [ACPBridgeEventReader]? {
        lock.lock(); defer { lock.unlock() }
        if lost { return nil }
        lost = true
        let open = Array(readers.values)
        readers = [:]
        return open
    }

    /// The control client; only on the control queue.
    private func client() -> RuntimeClient {
        if let c = controlClient { return c }
        let c = makeClient(.control)
        controlClient = c
        return c
    }

    private func onControl<T>(_ body: @escaping (RuntimeClient) throws -> T) async throws -> T {
        if isLost { throw ACPBridgeErrors.connectionLost }
        do {
            return try await control.run(timeout: config.callTimeout) {
                if self.isLost { throw ACPBridgeErrors.connectionLost }
                return try body(self.client())
            }
        } catch {
            throw ACPBridgeErrors.map(error)
        }
    }

    private func noteConnection(_ run: JSONValue) {
        if let conn = run["connectionId"]?.stringValue, let inst = instanceId {
            runConnectionId = (inst, conn)
        }
    }

    /// The Run field that carries its last event sequence once the Runtime
    /// exposes it (07-runtime-requests.md R10); absent today, so nil.
    static let lastCursorField = "lastEventSequence"

    /// The ADR v2.2 axes of a runtime/1 `Run`.
    static func snapshot(_ run: JSONValue) -> ACPRunSnapshot? {
        guard let id = run["runId"]?.stringValue, let phase = run["phase"]?.stringValue,
              let quiescence = run["quiescence"]?.stringValue, let lifetime = run["lifetime"]?.stringValue
        else { return nil }
        return ACPRunSnapshot(runId: id, phase: phase, outcome: run["outcome"]?.stringValue,
                              quiescence: quiescence, lifetime: lifetime,
                              lastCursor: run[lastCursorField]?.intValue)
    }
}
