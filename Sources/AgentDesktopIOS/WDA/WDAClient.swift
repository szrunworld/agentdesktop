import Foundation

/// HTTP client for one WebDriverAgent runner (one iPhone).
///
/// - Every request has an explicit upper bound: the configured request
///   timeout, shortened by the caller's deadline. A deadline that has
///   already passed fails with `timeout` / `notSent` and sends nothing.
/// - One WDA session is created lazily and reused. When WDA reports the
///   session invalid, the client drops it. Reads (status, screenshot,
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

    /// Returns the cached session, or creates (or adopts) one.
    @discardableResult
    public func ensureSession(deadline: ContinuousClock.Instant? = nil) async throws -> String {
        if let sessionId { return sessionId }
        if let pendingSession { return try await pendingSession.value }
        let task = Task { try await self.openSession(deadline: deadline) }
        pendingSession = task
        do {
            let id = try await task.value
            pendingSession = nil
            return id
        } catch {
            pendingSession = nil
            throw error
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

    private func openSession(deadline: ContinuousClock.Instant?) async throws -> String {
        if configuration.adoptRunnerSession,
           let held = try await status(deadline: deadline).runnerSessionId, !held.isEmpty {
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
        let reply = try await send("POST", "/session", body: body,
                                   timeout: configuration.sessionCreateTimeout, deadline: deadline)
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

    /// A session-scoped request. A read that meets an invalid session runs
    /// once more on a new session; an action never does.
    func sessionSend(_ method: String, _ suffix: String, query: [URLQueryItem] = [], body: Any? = nil,
                     deadline: ContinuousClock.Instant?, isAction: Bool) async throws -> Reply {
        let id = try await ensureSession(deadline: deadline)
        do {
            return try await send(method, "/session/\(id)\(suffix)", query: query, body: body,
                                  deadline: deadline, isAction: isAction)
        } catch let error as WDAError where error.kind == .sessionInvalid {
            dropSession(id)
            guard !isAction else { throw error }
            let fresh = try await ensureSession(deadline: deadline)
            return try await send(method, "/session/\(fresh)\(suffix)", query: query, body: body,
                                  deadline: deadline, isAction: false)
        }
    }

    func evidence(_ operation: String, _ reply: Reply) -> WDAActionEvidence {
        WDAActionEvidence(requestId: UUID(), operation: operation, endpoint: reply.endpoint,
                          sessionId: reply.answer.sessionId ?? sessionId, delivery: .accepted,
                          effect: .notVerifiedByClient, httpStatus: reply.answer.httpStatus,
                          sentAt: reply.sentAt, answeredAt: reply.answeredAt)
    }
}
