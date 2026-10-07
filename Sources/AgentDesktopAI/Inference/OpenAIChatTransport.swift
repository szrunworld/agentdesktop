// Request shape and response reading follow 2ndscreen da5677c
// Sources/TarsAgent/Model.swift (multimodal chat completions) and
// packages/task-runtime/src/agent-providers.ts (key held by the host,
// redirects refused, upstream body never passed on), rewritten async and
// without the hard-coded thinking/top_p fields.
import Foundation
import AgentDesktopContracts

/// What one chat completions call returned, before any GUI parsing.
public struct ChatCompletion: Equatable, Sendable {
    public let text: String
    public let actualModelId: String?
    public let finishReason: String?
    public let usage: UsageTokens?
    public let upstreamRequestId: String?
    public let httpStatus: Int
}

/// Endpoint rules of spec §10.1.
public enum EndpointRules {
    /// The chat completions URL for a configured base, or a VALIDATION_ERROR.
    /// Accepts https, or http only to 127.0.0.1, [::1] or localhost (which
    /// must resolve to loopback only). Refuses userinfo, query, fragment and
    /// a base that already ends in /chat/completions.
    public static func chatCompletionsURL(base: URL,
                                          resolve: (String) -> [String] = EndpointRules.resolveAddresses) throws -> URL {
        guard let comps = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), let host = comps.host, !host.isEmpty else {
            throw ContractError(.validationError, "baseUrl must be an absolute http(s) URL")
        }
        if comps.user != nil || comps.password != nil {
            throw ContractError(.validationError, "baseUrl must not carry credentials")
        }
        if comps.query != nil || comps.fragment != nil {
            throw ContractError(.validationError, "baseUrl must not have a query or fragment")
        }
        switch scheme {
        case "https": break
        case "http":
            let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard ["127.0.0.1", "::1", "localhost"].contains(h) else {
                throw ContractError(.validationError, "plain http is allowed only to a loopback address")
            }
            if h == "localhost" {
                let addrs = resolve("localhost")
                guard !addrs.isEmpty, addrs.allSatisfy(isLoopback) else {
                    throw ContractError(.validationError, "localhost does not resolve to loopback only")
                }
            }
        default:
            throw ContractError(.validationError, "baseUrl must use https")
        }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/chat/completions") {
            throw ContractError(.validationError, "baseUrl must not include /chat/completions; it is added automatically")
        }
        var out = comps
        out.path = path + "/chat/completions"
        guard let url = out.url else { throw ContractError(.validationError, "baseUrl is not a valid URL") }
        return url
    }

    public static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address.hasPrefix("127.") || address == "::ffff:127.0.0.1"
    }

    public static func resolveAddresses(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            cur = ai.pointee.ai_next
        }
        return out
    }
}

/// openai_chat, non-streaming (spec §06.1, §10.1).
public struct OpenAIChatTransport: Sendable {
    public static let maxResponseBytes = 2 * 1024 * 1024

    public let http: HTTPTransport

    public init(http: HTTPTransport) {
        self.http = http
    }

    /// Build the exact request. Throws VALIDATION_ERROR/UNSUPPORTED_PROTOCOL
    /// before anything reaches the network.
    public func makeRequest(_ request: AiInferenceRequest, model: AiResolvedModel, apiKey: String,
                            timeout: TimeInterval) throws -> URLRequest {
        guard model.connection.apiProtocol == .openaiChat else {
            throw ContractError(.unsupportedProtocol, "only openai_chat is implemented")
        }
        let url = try EndpointRules.chatCompletionsURL(base: model.connection.baseUrl)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = max(0.1, timeout)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpShouldHandleCookies = false
        req.httpBody = Self.body(request, model: model).encodedData()
        return req
    }

    /// The JSON body: model, messages, max_tokens, stream:false, and only
    /// temperature/seed from the profile. Nothing vendor-specific.
    static func body(_ request: AiInferenceRequest, model: AiResolvedModel) -> JSONValue {
        let maxTokens = min(request.maxOutputTokens, model.model.maxOutputTokens, AiInferenceRequest.hardMaxOutputTokens)
        var members: [(String, JSONValue)] = [
            ("model", .string(model.model.modelId)),
            ("messages", .array(request.messages.map(message))),
            ("max_tokens", .int(maxTokens)),
            ("stream", .bool(false)),
        ]
        let opts = model.model.requestOptions
        if let t = opts.temperature { members.append(("temperature", .double(t))) }
        if let s = opts.seed { members.append(("seed", .int(s))) }
        return .obj(members)
    }

    static func message(_ m: AiMessage) -> JSONValue {
        let content: JSONValue
        if m.content.count == 1, case let .text(t) = m.content[0] {
            content = .string(t)
        } else {
            content = .array(m.content.map { part in
                switch part {
                case let .text(t):
                    return .obj([("type", .string("text")), ("text", .string(t))])
                case let .image(img):
                    let url = "data:\(img.mimeType);base64,\(img.bytes.base64EncodedString())"
                    return .obj([("type", .string("image_url")), ("image_url", .obj([("url", .string(url))]))])
                }
            })
        }
        return .obj([("role", .string(m.role.rawValue)), ("content", content)])
    }

    /// Send and read one call. Errors are contract errors with no upstream
    /// body in them; `details.httpStatus` and, for 429, `retryAfterMs`.
    public func complete(_ request: AiInferenceRequest, model: AiResolvedModel, apiKey: String,
                         timeout: TimeInterval) async throws -> ChatCompletion {
        let urlRequest = try makeRequest(request, model: model, apiKey: apiKey, timeout: timeout)
        let result: HTTPResult
        do {
            result = try await http.send(urlRequest, maxResponseBytes: Self.maxResponseBytes)
        } catch let e as HTTPTransportError {
            throw Self.map(e)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ContractError(.upstreamUnavailable, "the model endpoint could not be reached")
        }
        return try Self.read(result)
    }

    static func map(_ e: HTTPTransportError) -> Error {
        switch e {
        case let .redirect(status):
            return ContractError(.upstreamProtocolError, "the model endpoint answered with a redirect, which is not followed",
                                 retryable: false, details: .obj([("httpStatus", .int(status))]))
        case .responseTooLarge:
            return ContractError(.upstreamProtocolError, "the model response exceeds \(maxResponseBytes) bytes", retryable: false)
        case .timedOut:
            return ContractError(.upstreamUnavailable, "the model endpoint timed out")
        case .network:
            return ContractError(.upstreamUnavailable, "the model endpoint could not be reached")
        case .cancelled:
            return CancellationError()
        }
    }

    /// Classify and parse a complete response.
    static func read(_ r: HTTPResult) throws -> ChatCompletion {
        let statusDetails: JSONValue = .obj([("httpStatus", .int(r.status))])
        switch r.status {
        case 200...299: break
        case 300...399:
            throw ContractError(.upstreamProtocolError, "the model endpoint answered with a redirect, which is not followed",
                                retryable: false, details: statusDetails)
        case 401, 403:
            throw ContractError(.authFailed, "the model endpoint refused the credential", retryable: false, details: statusDetails)
        case 404:
            if isModelNotFound(r.body) {
                throw ContractError(.modelNotFound, "the endpoint does not know this model", retryable: false, details: statusDetails)
            }
            throw ContractError(.upstreamProtocolError, "the model endpoint answered 404", retryable: false, details: statusDetails)
        case 408:
            throw ContractError(.upstreamUnavailable, "the model endpoint timed out", details: statusDetails)
        case 429:
            var d: [(String, JSONValue)] = [("httpStatus", .int(429))]
            if let ms = retryAfterMs(r.headers["retry-after"]) { d.append(("retryAfterMs", .int(ms))) }
            throw ContractError(.rateLimited, "the model endpoint is rate limiting", retryable: true, details: .obj(d))
        case 500...599:
            throw ContractError(.upstreamUnavailable, "the model endpoint failed", retryable: true, details: statusDetails)
        default:
            throw ContractError(.upstreamProtocolError, "the model endpoint answered \(r.status)", retryable: false, details: statusDetails)
        }

        let contentType = r.headers["content-type"]?.lowercased() ?? ""
        let head = String(decoding: r.body.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if contentType.contains("text/event-stream") || head.hasPrefix("data:") || head.hasPrefix("event:") {
            throw protocolError("the model endpoint streamed its answer; V1 needs one complete JSON response")
        }
        let json: JSONValue
        do { json = try StrictJSON.parse(r.body) } catch {
            throw protocolError("the model response is not one complete JSON object")
        }
        guard let choices = json["choices"]?.arrayValue, let first = choices.first,
              let message = first["message"], let text = message["content"]?.stringValue else {
            throw protocolError("the model response has no message text")
        }
        let actual = json["model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let finish = first["finish_reason"]?.stringValue
        let requestId = r.headers["x-request-id"] ?? json["id"]?.stringValue
        return ChatCompletion(text: text, actualModelId: actual, finishReason: finish,
                              usage: usage(json["usage"]), upstreamRequestId: requestId, httpStatus: r.status)
    }

    static func protocolError(_ message: String) -> ContractError {
        ContractError(.upstreamProtocolError, message, retryable: false)
    }

    /// Usage as reported. A count that is missing or not a non-negative
    /// integer stays nil; nil usage means nothing was reported.
    static func usage(_ u: JSONValue?) -> UsageTokens? {
        guard let u, case .object = u else { return nil }
        func count(_ v: JSONValue?) -> Int? {
            guard let n = v?.intValue, n >= 0, n <= Int(Int32.max) else { return nil }
            return n
        }
        let tokens = UsageTokens(inputTokens: count(u["prompt_tokens"]),
                                 outputTokens: count(u["completion_tokens"]),
                                 cacheReadTokens: count(u["prompt_tokens_details"]?["cached_tokens"]),
                                 cacheWriteTokens: nil,
                                 totalTokens: count(u["total_tokens"]))
        if tokens.inputTokens == nil, tokens.outputTokens == nil, tokens.totalTokens == nil { return nil }
        return tokens
    }

    static func isModelNotFound(_ body: Data) -> Bool {
        guard let json = try? StrictJSON.parse(body), let err = json["error"] else { return false }
        let code = (err["code"]?.stringValue ?? err["type"]?.stringValue ?? "").lowercased()
        if code.contains("model_not_found") || code == "modelnotfound" || code.contains("invalidendpointormodel") { return true }
        let msg = (err["message"]?.stringValue ?? "").lowercased()
        return msg.contains("model") && (msg.contains("not found") || msg.contains("does not exist"))
    }

    /// Retry-After as delay-seconds or an HTTP date, in milliseconds.
    static func retryAfterMs(_ value: String?, now: Date = Date()) -> Int? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let s = Double(v), s >= 0, s.isFinite { return Int((s * 1000).rounded()) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let d = f.date(from: v) else { return nil }
        return max(0, Int((d.timeIntervalSince(now) * 1000).rounded()))
    }
}
