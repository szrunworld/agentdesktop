import Foundation
@testable import AgentDesktopIOS

/// An in-process stand-in for a WebDriverAgent runner, reached through a
/// `URLProtocol` stub. Each instance owns a unique `.test` host, so tests
/// can run in parallel and nothing leaves the process.
final class FakeWDA: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data?
        /// The URLRequest's own timeout: which limit the client applied.
        var timeout: TimeInterval = 0
        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    enum Reply {
        case json(Int, Any)
        case raw(Int, Data)
        case fail(URLError.Code)
        /// Never answers; the client has to give up.
        case hang
        /// Answers after a pause.
        indirect case delayed(TimeInterval, Reply)
        /// Answers only when the test releases the gate.
        indirect case held(WDAReplyGate, Reply)
    }

    let host = "wda-\(UUID().uuidString.lowercased()).test"
    var baseURL: URL { URL(string: "http://\(host):8100")! }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var validSessions: Set<String> = []
    private var sessionCounter = 0
    private var overrides: [String: Reply] = [:]
    private var hook: ((Request) -> Void)?
    var screenshotSize = (width: 1170, height: 2532)

    init() { StubURLProtocol.register(self) }
    deinit { StubURLProtocol.unregister(host) }

    var requests: [Request] { lock.withLock { _requests } }
    func requests(_ method: String, suffix: String) -> [Request] {
        requests.filter { $0.method == method && $0.path.hasSuffix(suffix) }
    }

    /// Makes the runner hold a session it did not create through this fake.
    func addSession(_ id: String) { _ = lock.withLock { validSessions.insert(id) } }

    /// Makes the runner forget a session, as after a runner restart.
    func killSession(_ id: String) { _ = lock.withLock { validSessions.remove(id) } }

    /// Runs `action` for every request before it is routed.
    func onRequest(_ action: ((Request) -> Void)?) { lock.withLock { hook = action } }

    /// Overrides the answer for `"METHOD suffix"` (path suffix match).
    func override(_ method: String, _ suffix: String, _ reply: Reply?) {
        lock.withLock { overrides["\(method) \(suffix)"] = reply }
    }

    func client(timeout: Duration = .seconds(5), udid: String? = nil,
                adopt: Bool = false, capabilities: [String: WDAJSONValue] = [:]) -> WDAClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return WDAClient(configuration: WDAConfiguration(baseURL: baseURL, requestTimeout: timeout,
                                                         sessionCreateTimeout: timeout, deviceUDID: udid,
                                                         sessionCapabilities: capabilities,
                                                         adoptRunnerSession: adopt),
                         urlSessionConfiguration: configuration)
    }

    // MARK: - Routing

    func handle(_ request: Request) -> Reply {
        let action = lock.withLock { () -> ((Request) -> Void)? in
            _requests.append(request)
            return hook
        }
        action?(request)
        let forced = lock.withLock { () -> Reply? in
            overrides.first { key, _ in
                let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
                return parts[0] == request.method && request.path.hasSuffix(parts[1])
            }?.value
        }
        if let forced { return forced }
        let parts = request.path.split(separator: "/").map(String.init)
        let route = request.method + " " + parts.joined(separator: "/")
        switch route {
        case "GET status":
            return .json(200, ["value": [
                "ready": true, "message": "WebDriverAgent is ready to accept commands", "state": "success",
                "build": ["version": "9.0.0", "productBundleIdentifier": "com.facebook.WebDriverAgentRunner"],
                "os": ["name": "iOS", "version": "18.6", "sdkVersion": "18.5"],
                "device": "iphone", "ios": ["ip": "192.168.1.20"],
            ] as [String: Any], "sessionId": NSNull()])
        case "POST session":
            let id = lock.withLock { () -> String in
                sessionCounter += 1
                let id = "S\(sessionCounter)"
                validSessions.insert(id)
                return id
            }
            return .json(200, ["value": ["sessionId": id, "capabilities": [:] as [String: Any]], "sessionId": id])
        case _ where request.method == "DELETE" && parts.count == 2 && parts[0] == "session":
            let id = parts[1]
            _ = lock.withLock { validSessions.remove(id) }
            return .json(200, ["value": NSNull(), "sessionId": id])
        case "POST wda/homescreen":
            return .json(200, ["value": NSNull(), "sessionId": NSNull()])
        case "GET wda/activeAppInfo":
            return .json(200, ["value": ["bundleId": "com.apple.springboard", "pid": 50] as [String: Any]])
        case _ where parts.first == "session" && parts.count >= 3:
            let id = parts[1]
            guard lock.withLock({ validSessions.contains(id) }) else {
                return .json(404, ["value": ["error": "invalid session id",
                                             "message": "Session does not exist", "traceback": ""],
                                   "sessionId": id])
            }
            return sessionRoute(request.method + " " + parts.dropFirst(2).joined(separator: "/"), request, session: id)
        default:
            return .json(404, ["value": ["error": "unknown command", "message": "Unhandled endpoint"]])
        }
    }

    private func ok(_ value: Any, _ session: String) -> Reply {
        .json(200, ["value": value, "sessionId": session])
    }

    private func sessionRoute(_ route: String, _ request: Request, session: String) -> Reply {
        switch route {
        case "GET screenshot":
            return ok(Self.pngHeader(width: screenshotSize.width, height: screenshotSize.height).base64EncodedString(), session)
        case "GET source":
            return ok("<?xml version=\"1.0\"?><XCUIElementTypeApplication name=\"Settings\"><XCUIElementTypeButton name=\"General\"/></XCUIElementTypeApplication>", session)
        case "GET window/size":
            return ok(["width": 390, "height": 844], session)
        case "GET wda/screen":
            return ok(["scale": 3, "statusBarSize": ["width": 390, "height": 47]] as [String: Any], session)
        case "GET orientation":
            return ok("PORTRAIT", session)
        case "POST actions":
            let actions = request.json?["actions"] as? [Any] ?? []
            if actions.isEmpty {
                return .json(400, ["value": ["error": "invalid argument", "message": "Actions list cannot be empty"],
                                   "sessionId": session])
            }
            return ok(NSNull(), session)
        case "POST element":
            if (request.json?["value"] as? String) == "missing" {
                return .json(404, ["value": ["error": "no such element", "message": "unable to find element"],
                                   "sessionId": session])
            }
            return ok(["ELEMENT": "E1", "element-6066-11e4-a52e-4f735466cecf": "E1"], session)
        case _ where route.hasPrefix("POST element/") && (route.hasSuffix("/value") || route.hasSuffix("/click")),
             "POST wda/keys", "POST wda/apps/launch":
            return ok(NSNull(), session)
        default:
            return .json(404, ["value": ["error": "unknown command", "message": "Unhandled endpoint"],
                               "sessionId": session])
        }
    }

    static func pngHeader(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        for value in [width, height] {
            bytes += [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        bytes += [8, 6, 0, 0, 0, 0, 0, 0, 0]
        return Data(bytes)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fakes: [String: FakeWDA] = [:]

    static func register(_ fake: FakeWDA) { lock.withLock { fakes[fake.host] = fake } }
    static func unregister(_ host: String) { _ = lock.withLock { fakes.removeValue(forKey: host) } }
    private static func fake(for host: String?) -> FakeWDA? {
        guard let host else { return nil }
        return lock.withLock { fakes[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool { fake(for: request.url?.host) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fake = Self.fake(for: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var recorded = FakeWDA.Request(method: request.httpMethod ?? "GET", path: url.path, query: query,
                                       body: Self.body(of: request))
        recorded.timeout = request.timeoutInterval
        deliver(fake.handle(recorded))
    }

    private func deliver(_ reply: FakeWDA.Reply) {
        switch reply {
        case let .held(gate, inner):
            gate.hold { self.deliver(inner) }
        case let .delayed(seconds, inner):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.deliver(inner) }
        case let .json(status, object):
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            respond(status, data)
        case let .raw(status, data):
            respond(status, data)
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json;charset=UTF-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands protocols the body as a stream.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A deterministic response barrier; tests can prove a deadline expires
/// before session creation completes without depending on scheduler speed.
final class WDAReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var pending: [() -> Void] = []

    func hold(_ response: @escaping () -> Void) {
        let ready = lock.withLock {
            if released { return true }
            pending.append(response)
            return false
        }
        if ready { response() }
    }

    func release() {
        let responses = lock.withLock {
            released = true
            defer { pending.removeAll() }
            return pending
        }
        responses.forEach { $0() }
    }
}
