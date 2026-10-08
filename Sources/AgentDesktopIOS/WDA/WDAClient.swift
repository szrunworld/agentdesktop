import Foundation

/// HTTP client for one WebDriverAgent runner (one iPhone).
///
/// - Every request has an explicit upper bound: the configured request
///   timeout, shortened by the caller's deadline. A deadline that has
///   already passed fails with `timeout` / `notSent` and sends nothing.
/// - One WDA session is created lazily and reused. `POST /session` can
///   launch or foreground the app in `sessionCapabilities`, so it is treated
///   like a command: lost answers are `unknown`, and the read-only `probe()`
///   never sends it. When WDA reports the session invalid, the client drops it. Reads (status, screenshot,
///   source, geometry) are retried once on a new session; input commands
///   are never retried or replayed — the caller gets `sessionInvalid` and
///   the next call runs on a new session.
/// - Input results carry `WDAActionEvidence` with `delivery == .accepted`
///   and `effect == .notVerifiedByClient`. Confirming the effect needs a new
///   observation and is the Runtime's call.
///
/// Per-device serialisation (one task at a time on a phone) belongs to the
/// Runtime's device session; this actor only keeps its own state
/// consistent.
public actor WDAClient {
    public nonisolated let configuration: WDAConfiguration
    private let urlSession: URLSession
    private var sessionId: String?
    private var pendingSession: Task<String, Error>?
    /// Number of sessions this client has created or adopted.
    public private(set) var sessionGeneration = 0

    public init(configuration: WDAConfiguration = WDAConfiguration(),
                urlSessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        let sessionConfiguration = urlSessionConfiguration
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    /// The session the next session-scoped call will use, if any.
    public var currentSessionId: String? { sessionId }

    // MARK: - Session lifecycle

    /// How a session-scoped request gets its session.
    enum SessionUse: Sendable, Equatable {
        /// Use the cached session or open one (`POST /session`, or adopt
        /// the runner's when configured). A read that meets an invalid
        /// session runs once more on a new session.
        case createIfNeeded
        /// Use the cached session, or adopt the runner's when
        /// `adoptRunnerSession` is on. Never sends `POST /session`; with no
        /// session the request fails with `noSession` / `notSent`.
        case existingOnly
        /// Only this session. An invalid session is reported, never replaced.
        case pinned(String)
    }

    /// Returns the cached session, or creates (or adopts) one.
    ///
    /// `POST /session` can launch or foreground the app named in
    /// `sessionCapabilities`, so it counts as a command that changes the
    /// phone: a transport failure after sending is `delivery == .unknown`.
    ///
    /// One creation runs at a time. It is bounded by `sessionCreateTimeout`
    /// only, not by whichever caller started it; every caller (the first one
    /// included) waits for it within its own deadline. A caller that gives up
    /// gets `timeout` / `unknown`; the creation may still finish and is then
    /// cached for the next call.
    @discardableResult
    public func ensureSession(deadline: ContinuousClock.Instant? = nil) async throws -> String {
        try await session(.createIfNeeded, deadline: deadline)
    }

    /// Resolves the session for `use` without sending anything that could
    /// change the phone unless `use == .createIfNeeded`.
    func session(_ use: SessionUse, deadline: ContinuousClock.Instant?) async throws -> String {
        if case let .pinned(id) = use { return id }
        if let sessionId { return sessionId }
        if let deadline, deadline <= ContinuousClock.now {
            throw WDAError(kind: .timeout, delivery: .notSent, endpoint: "POST /session",
                           message: "deadline passed before a session was available")
        }
        if let pendingSession {
            // Someone else is already creating it; waiting creates nothing.
            return try await wait(for: pendingSession, deadline: deadline)
        }
        switch use {
        case .createIfNeeded:
            let task = Task { () throws -> String in
                defer { self.pendingSession = nil }
                return try await self.openSession()
            }
            pendingSession = task
            return try await wait(for: task, deadline: deadline)
        case .existingOnly:
            if configuration.adoptRunnerSession,
               let held = try await status(deadline: deadline).runnerSessionId, !held.isEmpty {
                if let sessionId { return sessionId }
                sessionId = held
                sessionGeneration += 1
                return held
            }
            if let sessionId { return sessionId }
            throw WDAError(kind: .noSession, delivery: .notSent, endpoint: "POST /session",
                           message: "no WDA session and this call may not create one "
                               + "(POST /session can launch or foreground an app)")
        case .pinned:
            preconditionFailure("handled above")
        }
    }

    /// Waits for a shared session creation within this caller's deadline.
    private func wait(for task: Task<String, Error>, deadline: ContinuousClock.Instant?) async throws -> String {
        guard let deadline else { return try await task.value }
        let gate = OneShot<String>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                gate.arm(continuation)
                Task {
                    do { gate.resume(with: .success(try await task.value)) } catch { gate.resume(with: .failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    gate.resume(with: .failure(WDAError(
                        kind: .timeout, delivery: .unknown, endpoint: "POST /session",
                        message: "no session within this call's deadline; the creation may still complete")))
                }
                gate.onResume { timer.cancel() }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
    }

    /// Drops the current session (best-effort `DELETE`) and opens a new one.
    @discardableResult
    public func rebuildSession(deadline: ContinuousClock.Instant? = nil) async throws -> String {
        if let old = sessionId {
            sessionId = nil
            _ = try? await send("DELETE", "/session/\(old)", timeout: .seconds(5), deadline: deadline)
        }
        return try await ensureSession(deadline: deadline)
    }

    /// Ends the current session, if any.
    public func endSession(deadline: ContinuousClock.Instant? = nil) async {
        guard let old = sessionId else { return }
        sessionId = nil
        _ = try? await send("DELETE", "/session/\(old)", timeout: .seconds(5), deadline: deadline)
    }

    /// Bounded by the configuration's timeouts only; callers bound their
    /// own waits (see `ensureSession`).
    private func openSession() async throws -> String {
        if configuration.adoptRunnerSession,
           let held = try await status(deadline: nil).runnerSessionId, !held.isEmpty {
            sessionId = held
            sessionGeneration += 1
            return held
        }
        let body: [String: Any] = [
            "capabilities": [
                "alwaysMatch": configuration.sessionCapabilities.mapValues(\.foundationValue),
                "firstMatch": [[String: Any]()],
            ] as [String: Any],
        ]
        let endpoint = "POST /session"
        // May launch or foreground an app: once sent, a lost answer is
        // `unknown`, not `rejected`.
        let reply = try await send("POST", "/session", body: body,
                                   timeout: configuration.sessionCreateTimeout, deadline: nil, isAction: true)
        let id = reply.answer.sessionId ?? (reply.answer.value as? [String: Any])?["sessionId"] as? String
        guard let id, !id.isEmpty else {
            throw WDAError(kind: .invalidResponse, delivery: .unknown, endpoint: endpoint,
                           httpStatus: reply.answer.httpStatus, message: "session answer has no sessionId")
        }
        sessionId = id
        sessionGeneration += 1
        return id
    }

    private func dropSession(_ id: String) {
        if sessionId == id { sessionId = nil }
    }

    // MARK: - Transport

    struct Reply {
        let answer: WDAAnswer
        let endpoint: String
        let sentAt: Date
        let answeredAt: Date
        /// The session the request was addressed to, for session-scoped ones.
        var sessionId: String? = nil
    }

    /// Sends one request and maps every failure to `WDAError`.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil,
              timeout: Duration? = nil, deadline: ContinuousClock.Instant?,
              isAction: Bool = false) async throws -> Reply {
        let endpoint = "\(method) \(path)"
        var limit = timeout ?? configuration.requestTimeout
        if let deadline {
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero {
                throw WDAError(kind: .timeout, delivery: .notSent, endpoint: endpoint,
                               message: "deadline passed before the request was sent")
            }
            limit = min(limit, remaining)
        }

        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw WDAError(kind: .invalidArgument, delivery: .notSent, endpoint: endpoint, message: "bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = limit.timeInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            } catch {
                throw WDAError(kind: .invalidArgument, delivery: .notSent, endpoint: endpoint,
                               message: "body is not JSON: \(error)")
            }
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }

        let sentAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await raced(request, limit: limit)
        } catch is RequestTimedOut {
            throw WDAError(kind: .timeout, delivery: isAction ? .unknown : .rejected, endpoint: endpoint,
                           message: "no answer within \(limit.wdaMilliseconds) ms")
        } catch let error as URLError {
            if error.code == .timedOut {
                throw WDAError(kind: .timeout, delivery: isAction ? .unknown : .rejected, endpoint: endpoint,
                               message: "no answer within \(limit.wdaMilliseconds) ms")
            }
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            let notSent = WDAErrorMapping.refusedBeforeSending.contains(error.code)
            throw WDAError(kind: .runnerUnreachable,
                           delivery: notSent ? .notSent : (isAction ? .unknown : .rejected),
                           endpoint: endpoint, message: "runner unreachable: \(error.code.rawValue) \(error.localizedDescription)")
        }
        let answeredAt = Date()
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let answer = WDAAnswer.decode(httpStatus: httpStatus, data: data) else {
            if httpStatus == 404 {
                throw WDAError(kind: .unsupportedEndpoint, delivery: .rejected, endpoint: endpoint,
                               httpStatus: httpStatus, message: "route not served")
            }
            throw WDAError(kind: .invalidResponse, delivery: isAction ? .unknown : .rejected,
                           endpoint: endpoint, httpStatus: httpStatus, message: "answer is not WDA JSON")
        }
        if answer.isError {
            let (kind, delivery) = WDAErrorMapping.classify(code: answer.errorCode, httpStatus: httpStatus,
                                                            isAction: isAction)
            throw WDAError(kind: kind, delivery: delivery, endpoint: endpoint, httpStatus: httpStatus,
                           wdaErrorCode: answer.errorCode, message: answer.errorMessage ?? "WDA error")
        }
        return Reply(answer: answer, endpoint: endpoint, sentAt: sentAt, answeredAt: answeredAt)
    }

    private struct RequestTimedOut: Error {}

    /// URLRequest.timeoutInterval is an idle timeout; this bounds the whole
    /// exchange.
    private func raced(_ request: URLRequest, limit: Duration) async throws -> (Data, URLResponse) {
        let session = urlSession
        return try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RequestTimedOut() }
            guard let result = first else { throw RequestTimedOut() }
            return result
        }
    }

    /// A session-scoped request. With `.createIfNeeded`, a read that meets
    /// an invalid session runs once more on a new session; an action never
    /// does. Other uses never replace the session.
    func sessionSend(_ method: String, _ suffix: String, query: [URLQueryItem] = [], body: Any? = nil,
                     deadline: ContinuousClock.Instant?, isAction: Bool,
                     use: SessionUse = .createIfNeeded) async throws -> Reply {
        let id = try await session(use, deadline: deadline)
        do {
            var reply = try await send(method, "/session/\(id)\(suffix)", query: query, body: body,
                                       deadline: deadline, isAction: isAction)
            reply.sessionId = id
            return reply
        } catch let error as WDAError where error.kind == .sessionInvalid {
            dropSession(id)
            guard !isAction, use == .createIfNeeded else { throw error }
            let fresh = try await session(.createIfNeeded, deadline: deadline)
            var reply = try await send(method, "/session/\(fresh)\(suffix)", query: query, body: body,
                                       deadline: deadline, isAction: false)
            reply.sessionId = fresh
            return reply
        }
    }

    func evidence(_ operation: String, _ reply: Reply) -> WDAActionEvidence {
        WDAActionEvidence(requestId: UUID(), operation: operation, endpoint: reply.endpoint,
                          sessionId: reply.sessionId ?? reply.answer.sessionId ?? sessionId, delivery: .accepted,
                          effect: .notVerifiedByClient, httpStatus: reply.answer.httpStatus,
                          sentAt: reply.sentAt, answeredAt: reply.answeredAt)
    }
}

/// Resumes a continuation exactly once, whichever side gets there first.
private final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var early: Result<Value, Error>?
    private var done = false
    private var cleanup: (@Sendable () -> Void)?

    func arm(_ continuation: CheckedContinuation<Value, Error>) {
        let pending: Result<Value, Error>? = lock.withLock {
            if let early { self.early = nil; return early }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    func onResume(_ action: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if done { return true }
            cleanup = action
            return false
        }
        if runNow { action() }
    }

    func resume(with result: Result<Value, Error>) {
        let (target, action): (CheckedContinuation<Value, Error>?, (@Sendable () -> Void)?) = lock.withLock {
            if done { return (nil, nil) }
            done = true
            let target = continuation
            continuation = nil
            if target == nil { early = result }
            let action = cleanup
            cleanup = nil
            return (target, action)
        }
        target?.resume(with: result)
        action?()
    }
}
