import Foundation

/// One HTTP exchange, fully read and bounded.
public struct HTTPResult: Sendable {
    public let status: Int
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    /// A 3xx answer; redirects are never followed (the key must not travel).
    case redirect(status: Int)
    /// The body grew past the limit; reading stopped there.
    case responseTooLarge
    case timedOut
    /// Could not connect or the connection broke; carries URLError's code.
    case network(code: Int)
    case cancelled
}

/// The network edge of the model service. Injected so tests capture the
/// exact request without touching a real network.
public protocol HTTPTransport: Sendable {
    /// Send `request` and read the whole body, stopping once it exceeds
    /// `maxResponseBytes`. Must honour task cancellation and never follow
    /// a redirect.
    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult
}

/// URLSession with an ephemeral configuration (no cookies, cache or stored
/// credentials) and a delegate that refuses every redirect.
public final class URLSessionHTTPTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    public func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.network(code: URLError.badServerResponse.rawValue) }
        if (300..<400).contains(http.statusCode) {
            bytes.task.cancel()
            throw HTTPTransportError.redirect(status: http.statusCode)
        }
        if http.expectedContentLength > Int64(maxResponseBytes) {
            bytes.task.cancel()
            throw HTTPTransportError.responseTooLarge
        }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxResponseBytes {
                    bytes.task.cancel()
                    throw HTTPTransportError.responseTooLarge
                }
            }
        } catch let e as HTTPTransportError {
            throw e
        } catch {
            throw Self.map(error)
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        return HTTPResult(status: http.statusCode, headers: headers, body: body)
    }

    static func map(_ error: Error) -> HTTPTransportError {
        if error is CancellationError { return .cancelled }
        guard let u = error as? URLError else { return .network(code: URLError.unknown.rawValue) }
        switch u.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .httpTooManyRedirects, .redirectToNonExistentLocation: return .redirect(status: 0)
        default: return .network(code: u.code.rawValue)
        }
    }
}
