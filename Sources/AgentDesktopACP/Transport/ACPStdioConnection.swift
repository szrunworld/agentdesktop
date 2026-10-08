import AgentDesktopContracts
import Foundation

public struct ACPStdioConnectionOptions: Sendable {
    /// Largest frame accepted from the editor. A longer line ends the
    /// connection: a peer that sends one is not speaking ACP.
    public var maxFrameBytes = 16 * 1024 * 1024
    /// Unparseable frames tolerated (each answered with a JSON-RPC error)
    /// before the connection is ended.
    public var maxMalformedFrames = 16
    /// Versions offered in negotiation; defaults to the ones a real client spoke.
    public var supportedVersions = ACPWireNegotiation.supported
    public init() {}
}

/// `ACPConnection` over newline-delimited JSON-RPC 2.0 (ACP stdio transport).
///
/// It answers protocol-level faults itself (parse errors, invalid requests,
/// unknown or unadvertised methods, bad params, incompatible versions) and
/// delivers only well-formed requests to the server, in arrival order.
/// Pipelining is allowed: anything that arrives after an accepted
/// `initialize` but before its answer is held and processed, in order,
/// right after that answer is written (docs/acp/02-protocol-version.md §4).
/// Input end, a write failure, an oversized frame or too many malformed
/// frames end it with `.closed(reason:)`; pending agent→editor requests then
/// resolve to `.unavailable`.
public final class ACPStdioConnection: ACPConnection, @unchecked Sendable {
    public let events: AsyncStream<ACPConnectionEvent>
    private let eventsContinuation: AsyncStream<ACPConnectionEvent>.Continuation
    private let transport: ACPFrameTransport
    private let options: ACPStdioConnectionOptions
    private let writer: ACPStdioFrameWriter

    private let lock = NSLock()
    private var started = false
    private var closedReason: String?
    private var negotiation: ACPWireNegotiation.Outcome?
    private var adapter: ACPWireAdapter?
    private var clientCaps = ACPClientCapabilities()
    /// Set when our `initialize` answer went out: the connection is ready.
    private var advertised: ACPAgentCapabilities?
    /// An `initialize` was delivered and its answer is not fully out yet:
    /// incoming messages wait in `held`, in arrival order.
    private var initPending = false
    private var held: [ACPJsonRpcMessage] = []
    /// Capabilities of an accepted `initialize` answer not yet written.
    private var pendingAdvertised: ACPAgentCapabilities?
    /// Editor requests delivered to the server and not yet answered.
    private var unanswered: [ACPRequestId: (method: String, params: JSONValue?)] = [:]
    private var outgoing: [Int: OutgoingSlot] = [:]
    private var nextOutgoingId = 0
    private var malformed = 0

    private enum OutgoingResult { case result(JSONValue), error(ACPJsonRpcError), closed }
    private enum OutgoingSlot {
        case waiting(CheckedContinuation<OutgoingResult, Never>?)
        case done(OutgoingResult)
    }

    public init(transport: ACPFrameTransport, options: ACPStdioConnectionOptions = .init()) {
        self.transport = transport
        self.options = options
        writer = ACPStdioFrameWriter(transport: transport)
        (events, eventsContinuation) = AsyncStream<ACPConnectionEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    /// A started connection over this process's stdin and stdout.
    public static func standardIO(options: ACPStdioConnectionOptions = .init()) -> ACPStdioConnection {
        let c = ACPStdioConnection(transport: ACPStdioFileTransport(), options: options)
        c.start()
        return c
    }

    /// Begin reading. Idempotent.
    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        (transport as? ACPStdioFileTransport)?.start()
        Task { await readLoop() }
    }

    /// End the connection from our side.
    public func close(reason: String = "closed by agent") {
        finish(reason: reason)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: ACPPeer

    public var version: ACPVersion {
        lock.lock(); defer { lock.unlock() }
        return negotiation?.version ?? options.supportedVersions.first ?? .v1
    }

    public var clientCapabilities: ACPClientCapabilities {
        lock.lock(); defer { lock.unlock() }
        return clientCaps
    }

    /// The version negotiated in `initialize`, nil before.
    public var negotiatedVersion: ACPVersion? {
        lock.lock(); defer { lock.unlock() }
        return negotiation?.version
    }

    /// Image bytes the editor attached, by `ACPContentBlock.image` handle.
    public func image(handle: String) -> (mimeType: String, base64: String)? {
        lock.lock(); let a = adapter; lock.unlock()
        return (a as? ACPWireV1)?.image(handle: handle)
    }

    public func reply(to id: ACPRequestId, _ reply: ACPReply) async {
        // Unknown, already answered, or gone: answering twice is never right.
        guard let (message, wasInitialize) = locked({ () -> (ACPJsonRpcMessage, Bool)? in
            let isInit = unanswered[id]?.method == ACPWireV1.Method.initialize
            return encodeAnswer(to: id, reply).map { ($0, isInit) }
        }) else { return }
        await write(message)
        if wasInitialize { await releaseHeld() }
    }

    /// After the `initialize` answer is written: become ready (if it was
    /// accepted) and process held messages in arrival order. Messages that
    /// arrive meanwhile stay held until every earlier refusal is written,
    /// so nothing overtakes anything.
    private func releaseHeld() async {
        while true {
            let (refusals, done) = locked { () -> ([ACPJsonRpcMessage], Bool) in
                if let caps = pendingAdvertised { advertised = caps; pendingAdvertised = nil }
                let items = held
                held = []
                var refusals: [ACPJsonRpcMessage] = []
                for m in items {
                    switch m {
                    case let .request(rawId, method, params):
                        let id = ACPRequestId(rawId)
                        switch decide(id: id, method: method, params: params) {
                        case let .refuse(e): refusals.append(.errorResponse(id: rawId, error: e))
                        case let .deliver(event): eventsContinuation.yield(event)
                        case .held: break
                        }
                    case let .notification(method, params):
                        if let incoming = notificationNow(method: method, params: params) {
                            eventsContinuation.yield(.notification(incoming))
                        }
                    default:
                        break
                    }
                }
                if refusals.isEmpty { initPending = false }
                return (refusals, refusals.isEmpty)
            }
            for r in refusals { await write(r) }
            if done || isClosed { return }
        }
    }

    /// Called with the lock held.
    private func encodeAnswer(to id: ACPRequestId, _ reply: ACPReply) -> ACPJsonRpcMessage? {
        guard closedReason == nil, let pending = unanswered.removeValue(forKey: id) else { return nil }
        let message: ACPJsonRpcMessage
        if pending.method == ACPWireV1.Method.initialize {
            message = answerInitialize(id: id, reply)
        } else if let adapter {
            switch adapter.encodeReply(reply, method: pending.method) {
            case let .success(result):
                message = .response(id: id.raw, result: result)
                adapter.didReply(reply, method: pending.method, requestParams: pending.params)
            case let .failure(e):
                message = .errorResponse(id: id.raw, error: e)
            }
        } else {
            message = .errorResponse(id: id.raw, error: .init(code: ACPJsonRpcErrorCode.internalError,
                                                              message: "internal error: no wire adapter"))
        }
        return message
    }

    /// Called with the lock held.
    private func answerInitialize(id: ACPRequestId, _ reply: ACPReply) -> ACPJsonRpcMessage {
        guard let adapter, let negotiation else {
            return .errorResponse(id: id.raw, error: .init(code: ACPJsonRpcErrorCode.internalError,
                                                           message: "internal error: no negotiated version"))
        }
        if case let .initialized(v, _, caps) = reply {
            guard v == negotiation.version else {
                return .errorResponse(id: id.raw, error: .init(
                    code: ACPJsonRpcErrorCode.internalError,
                    message: "internal error: server answered a version other than the negotiated one"))
            }
            if case let .success(result) = adapter.encodeReply(reply, method: ACPWireV1.Method.initialize) {
                // Ready once the answer is written (releaseHeld).
                pendingAdvertised = caps
                return .response(id: id.raw, result: result)
            }
        }
        // Refused by the server (or an unfit reply): back to not initialized.
        self.negotiation = nil
        self.adapter = nil
        clientCaps = ACPClientCapabilities()
        if case let .error(e) = reply {
            return .errorResponse(id: id.raw, error: .init(code: e.code, message: e.message,
                                                           data: .obj([("reason", .string(e.reason))])))
        }
        return .errorResponse(id: id.raw, error: .init(code: ACPJsonRpcErrorCode.internalError,
                                                       message: "internal error: reply does not fit initialize"))
    }

    public func send(sessionId: String, _ update: ACPSessionUpdate) async {
        let encoded = locked { () -> (method: String, params: JSONValue)? in
            guard closedReason == nil, advertised != nil else { return nil }
            return adapter?.encodeUpdate(sessionId: sessionId, update)
        }
        guard let encoded else { return }
        await write(.notification(method: encoded.method, params: encoded.params))
    }

    public func requestPermission(_ request: ACPPermissionRequest) async -> ACPPermissionOutcome {
        let a = locked { advertised != nil ? adapter : nil }
        guard let a, !request.options.isEmpty else { return .unavailable }
        let (method, params) = a.encodePermissionRequest(request)
        switch await call(method: method, params: params) {
        case let .result(r): return a.decodePermissionResult(r, request: request)
        case .error, .closed: return .unavailable
        }
    }

    public func ask(_ question: ACPQuestion) async -> ACPAnswer {
        let a = locked { advertised != nil && clientCaps.elicitation ? adapter : nil }
        guard let a else { return .unavailable }
        let (method, params) = a.encodeQuestion(question)
        switch await call(method: method, params: params) {
        case let .result(r): return a.decodeAnswer(r, question: question)
        case .error, .closed: return .unavailable
        }
    }

    // MARK: agent → editor requests

    private func call(method: String, params: JSONValue) async -> OutgoingResult {
        let reserved = locked { () -> Int? in
            guard closedReason == nil else { return nil }
            let id = nextOutgoingId
            nextOutgoingId += 1
            outgoing[id] = .waiting(nil)
            return id
        }
        guard let id = reserved else { return .closed }

        await write(.request(id: .int(id), method: method, params: params))

        return await withCheckedContinuation { (cont: CheckedContinuation<OutgoingResult, Never>) in
            let ready = locked { () -> OutgoingResult? in
                switch outgoing[id] {
                case let .done(r)?:
                    outgoing[id] = nil
                    return r
                case .waiting?:
                    outgoing[id] = .waiting(cont)
                    return nil
                case nil:
                    return .closed
                }
            }
            if let ready { cont.resume(returning: ready) }
        }
    }

    /// Called with the lock held.
    private func resolveOutgoing(_ id: Int, _ r: OutgoingResult) -> CheckedContinuation<OutgoingResult, Never>? {
        switch outgoing[id] {
        case let .waiting(cont?)?:
            outgoing[id] = nil
            return cont
        case .waiting(nil)?:
            outgoing[id] = .done(r)
            return nil
        default:
            return nil  // Unknown or already answered id: ignored.
        }
    }

    // MARK: reading

    private func readLoop() async {
        var splitter = ACPFrameSplitter(maxFrameBytes: options.maxFrameBytes)
        for await chunk in transport.chunks {
            for unit in splitter.feed(chunk) {
                switch unit {
                case let .oversized(seen):
                    await write(.errorResponse(id: .null, error: .init(
                        code: ACPJsonRpcErrorCode.invalidRequest,
                        message: "frame exceeds \(options.maxFrameBytes) bytes (saw \(seen))")))
                    finish(reason: "frame_too_large")
                    return
                case let .frame(data):
                    await handle(frame: data)
                }
                if isClosed { return }
            }
        }
        finish(reason: splitter.pendingByteCount > 0 ? "input_closed_mid_frame" : "input_closed")
    }

    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedReason != nil }

    private func handle(frame: Data) async {
        switch ACPJsonRpcCodec.decode(frame) {
        case let .failure(f):
            let tooMany = locked { () -> Bool in
                malformed += 1
                return malformed > options.maxMalformedFrames
            }
            if let id = f.replyId { await write(.errorResponse(id: id, error: f.error)) }
            if tooMany { finish(reason: "too_many_malformed_frames") }
        case let .success(message):
            await handle(message)
        }
    }

    private func handle(_ message: ACPJsonRpcMessage) async {
        switch message {
        case let .request(rawId, method, params):
            await handleRequest(id: ACPRequestId(rawId), method: method, params: params)
        case let .notification(method, params):
            locked {
                if initPending { held.append(message); return }
                if let incoming = notificationNow(method: method, params: params) {
                    eventsContinuation.yield(.notification(incoming))
                }
            }
        case let .response(rawId, result):
            resolve(rawId, .result(result))
        case let .errorResponse(rawId, error):
            resolve(rawId, .error(error))
        }
    }

    /// Called with the lock held.
    private func notificationNow(method: String, params: JSONValue?) -> ACPIncoming? {
        advertised != nil ? adapter?.decodeNotification(method: method, params: params) : nil
    }

    private func resolve(_ rawId: JSONValue, _ r: OutgoingResult) {
        guard let id = rawId.intValue else { return }
        let cont = locked { resolveOutgoing(id, r) }
        cont?.resume(returning: r)
    }

    private enum RequestDecision {
        case refuse(ACPJsonRpcError)
        case deliver(ACPConnectionEvent)
        case held
    }

    private func handleRequest(id: ACPRequestId, method: String, params: JSONValue?) async {
        let decision = locked { () -> RequestDecision in
            if initPending {
                held.append(.request(id: id.raw, method: method, params: params))
                return .held
            }
            // Yield under the lock so a concurrent release cannot reorder events.
            let d = decide(id: id, method: method, params: params)
            if case let .deliver(event) = d { eventsContinuation.yield(event); return .held }
            return d
        }
        if case let .refuse(e) = decision { await write(.errorResponse(id: id.raw, error: e)) }
    }

    /// Called with the lock held.
    private func decide(id: ACPRequestId, method: String, params: JSONValue?) -> RequestDecision {
        func refuse(_ code: Int, _ msg: String) -> RequestDecision { .refuse(.init(code: code, message: msg)) }
        if unanswered[id] != nil {
            return refuse(ACPJsonRpcErrorCode.invalidRequest, "request id already in use")
        }
        if method == ACPWireV1.Method.initialize {
            if negotiation != nil {
                return refuse(ACPJsonRpcErrorCode.invalidRequest, "connection already initialized")
            }
            switch ACPWireNegotiation.negotiate(params: params, supported: options.supportedVersions) {
            case let .failure(e):
                return .refuse(e)
            case let .success(outcome):
                guard let a = ACPWire.adapter(for: outcome.version), let p = params else {
                    return refuse(ACPJsonRpcErrorCode.internalError, "no wire adapter for the negotiated version")
                }
                negotiation = outcome
                adapter = a
                let (info, caps) = a.decodeInitialize(params: p)
                clientCaps = caps
                unanswered[id] = (method, params)
                initPending = true
                return .deliver(.request(id, .initialize(client: info, capabilities: caps,
                                                          requested: String(outcome.requested))))
            }
        }
        guard let adapter, let advertised else {
            return refuse(ACPJsonRpcErrorCode.invalidRequest, "connection not initialized: send initialize first")
        }
        switch adapter.decodeRequest(method: method, params: params, advertised: advertised) {
        case let .failure(e):
            return .refuse(e)
        case let .success(incoming):
            unanswered[id] = (method, params)
            return .deliver(.request(id, incoming))
        }
    }

    // MARK: writing and closing

    private func write(_ message: ACPJsonRpcMessage) async {
        if isClosed { return }
        if !(await writer.send(ACPJsonRpcCodec.frame(message))) {
            finish(reason: "output_closed")
        }
    }

    private func finish(reason: String) {
        lock.lock()
        guard closedReason == nil else { lock.unlock(); return }
        closedReason = reason
        var conts: [CheckedContinuation<OutgoingResult, Never>] = []
        for (id, slot) in outgoing {
            if case let .waiting(c?) = slot { conts.append(c) } else { outgoing[id] = nil }
        }
        // Anything still waiting registers later and sees no slot: `.closed`.
        outgoing.removeAll()
        unanswered.removeAll()
        held.removeAll()
        lock.unlock()
        for c in conts { c.resume(returning: .closed) }
        eventsContinuation.yield(.closed(reason: reason))
        eventsContinuation.finish()
        transport.close()
    }
}

/// Serializes frames onto the transport so concurrent senders never
/// interleave bytes of two messages.
actor ACPStdioFrameWriter {
    private let transport: ACPFrameTransport
    private var broken = false
    init(transport: ACPFrameTransport) { self.transport = transport }

    func send(_ data: Data) async -> Bool {
        guard !broken else { return false }
        do {
            try await transport.write(data)
            return true
        } catch {
            broken = true
            return false
        }
    }
}
