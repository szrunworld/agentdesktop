import Foundation
import Testing
@testable import AgentDesktopAI
@testable import AgentDesktopContracts

// Test doubles for the model service. Nothing here touches a real network
// or a real key: the stub captures requests, the loopback server listens
// on 127.0.0.1 only, and every key is a synthetic canary.

let canaryKey = "sk-canary-7f3e9a1c-DO-NOT-LEAK"

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// Captures every request and answers from a handler.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> HTTPResult
    private let requests = Locked<[URLRequest]>([])
    private let handler: Locked<Handler>

    init(_ handler: @escaping Handler) { self.handler = Locked(handler) }

    convenience init(status: Int = 200, headers: [String: String] = ["Content-Type": "application/json"], body: String) {
        self.init { _, _ in HTTPResult(status: status, headers: headers, body: Data(body.utf8)) }
    }

    func setHandler(_ h: @escaping Handler) { handler.with { $0 = h } }
    var captured: [URLRequest] { requests.get() }
    var count: Int { requests.get().count }

    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        requests.with { $0.append(request) }
        let h = handler.get()
        let r = try await h(request, maxResponseBytes)
        if r.body.count > maxResponseBytes { throw HTTPTransportError.responseTooLarge }
        return r
    }
}

func okBody(text: String = #"click(start_box='(100,200)')"#, model: String = "doubao-ui-tars-actual",
            usage: String? = #"{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110}"#,
            id: String = "chatcmpl-upstream-1") -> String {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
    var s = #"{"id":"\#(id)","model":"\#(model)","choices":[{"index":0,"message":{"role":"assistant","content":\#(escaped)},"finish_reason":"stop"}]"#
    if let usage { s += #","usage":\#(usage)"# }
    return s + "}"
}

/// A clock that moves only when told to.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private struct Sleeper { let id: UUID; let target: UInt64; let cont: CheckedContinuation<Void, Error> }
    private let state = Locked<(now: UInt64, sleepers: [Sleeper])>((now: 1_000_000_000, sleepers: []))
    let wallStart = Date(timeIntervalSince1970: 1_791_000_000)

    func nowNanoseconds() -> UInt64 { state.get().now }
    func wallNow() -> Date { wallStart.addingTimeInterval(Double(state.get().now) / 1e9) }
    func ms(_ v: Int) -> UInt64 { nowNanoseconds() + UInt64(v) * 1_000_000 }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        if deadline <= nowNanoseconds() { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let resumeNow = state.with { s -> Bool in
                    if deadline <= s.now { return true }
                    s.sleepers.append(Sleeper(id: id, target: deadline, cont: c))
                    return false
                }
                if resumeNow { c.resume() }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let s = state.with { st -> Sleeper? in
            guard let i = st.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
            return st.sleepers.remove(at: i)
        }
        s?.cont.resume(throwing: CancellationError())
    }

    func advance(ms: Int) {
        let due = state.with { s -> [Sleeper] in
            s.now += UInt64(ms) * 1_000_000
            let now = s.now
            let due = s.sleepers.filter { $0.target <= now }
            s.sleepers.removeAll { $0.target <= now }
            return due
        }
        for d in due { d.cont.resume() }
    }

    func sleeperTargets() -> [UInt64] { state.get().sleepers.map(\.target) }

    /// Wait (in real time, briefly) until a sleeper with this target exists.
    func waitForSleeper(at target: UInt64) async {
        for _ in 0..<2000 {
            if sleeperTargets().contains(target) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("no sleeper registered for \(target)")
    }
}

struct TestCredentials: CredentialResolver {
    var keys: [ResourceID: String] = ["cred-1": canaryKey, "cred-2": canaryKey + "-fallback"]
    var revoked: Set<ResourceID> = []

    func resolveKey(credentialIdentity: ResourceID) async throws -> String {
        if revoked.contains(credentialIdentity) { throw ContractError(.credentialRevoked, "the credential was revoked") }
        guard let k = keys[credentialIdentity] else { throw ContractError(.credentialRequired, "no credential is stored") }
        return k
    }
}

final class TestAdmission: AiCallAdmission, @unchecked Sendable {
    let current = Locked(true)
    func admit(_ context: AiCallContext, target: AiResolvedModel) async throws {}
    func isStillCurrent(_ context: AiCallContext, target: AiResolvedModel) async -> Bool { current.get() }
}

func model(base: String = "https://ark.example.invalid/api/v3", modelId: String = "Doubao-Seed-UI-TARS",
           connectionId: String = "conn-1", credential: String = "cred-1",
           apiProtocol: AiProtocol = .openaiChat, options: ModelRequestOptions = ModelRequestOptions(),
           maxOutputTokens: Int = 1024, timeoutMs: Int = 30_000) -> AiResolvedModel {
    AiResolvedModel(
        connection: AiConnectionSnapshot(connectionId: connectionId, revision: 3, name: "Ark", apiProtocol: apiProtocol,
                                         baseUrl: URL(string: base)!, credentialIdentityRef: credential, timeoutMs: timeoutMs),
        model: AiModelSnapshot(modelProfileId: "mp-1", revision: 2, connectionId: connectionId, connectionRevision: 3,
                               modelId: modelId, requestOptions: options, maxOutputTokens: maxOutputTokens),
        authorizationScopeRef: "scope-owner", dataScopeRef: "data-local")
}

func context(clock: MonotonicClock, deadlineMs: Int = 120_000, attempt: String = UUID().uuidString,
             runId: String = "run-1", step: Int = 0) -> AiCallContext {
    AiCallContext(inferenceAttemptId: attempt,
                  purpose: .guiStep(GuiStepCallPurpose(runId: runId, stepIndex: step, snapshotId: "snap-1",
                                                       bindingEpoch: 1, currentGeneration: 1)),
                  callerScopeRef: "caller-owner", budgetScopeRef: runId,
                  deadlineMonotonicNanoseconds: clock.nowNanoseconds() + UInt64(deadlineMs) * 1_000_000)
}

let fixturePNG: Data = {
    // A real 1x1 PNG, so the payload is a genuine image.
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
}()

func screenshotRequest(image: Data = fixturePNG, maxOutputTokens: Int = 1024) -> AiInferenceRequest {
    AiInferenceRequest(messages: [
        .text(.system, "You are a GUI agent."),
        AiMessage(role: .user, content: [.text("Type Ada into Name, then Apply."),
                                         .image(AiImageContent(screenshotId: "shot-1", mimeType: "image/png", bytes: image))]),
    ], maxOutputTokens: maxOutputTokens)
}

func service(_ http: HTTPTransport, ledger: AiCallLedgerPort = InMemoryAiCallLedger(),
             credentials: CredentialResolver = TestCredentials(), admission: AiCallAdmission = AdmitAll(),
             clock: MonotonicClock = FakeClock(), prices: AiPriceTable? = nil) -> DefaultAiService {
    DefaultAiService(http: http, credentials: credentials, ledger: ledger, admission: admission, clock: clock, prices: prices)
}

func expectCode(_ code: ErrorCode, _ body: () async throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        try await body()
        Issue.record("expected \(code.rawValue), got success", sourceLocation: sourceLocation)
    } catch let e as ContractError {
        #expect(e.code == code, "\(e)", sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected \(code.rawValue), got \(error)", sourceLocation: sourceLocation)
    }
}

/// A one-thread HTTP/1.1 server on 127.0.0.1 for exercising the real
/// URLSession transport (redirects, size limits). Each connection gets one
/// response and is closed.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct Received { let method: String; let path: String; let headers: [String: String]; let body: Data }
    let port: UInt16
    private let fd: Int32
    private let received = Locked<[Received]>([])
    private let respond: @Sendable (Received) -> Data

    init(respond: @escaping @Sendable (Received) -> Data) throws {
        self.respond = respond
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(sock, 16) == 0 else { close(sock); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [self] in self.loop() }
        thread.start()
    }

    var base: String { "http://127.0.0.1:\(port)" }
    var requests: [Received] { received.get() }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }

    private func loop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { return }
            var nosig: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            var buf = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            var headerEnd: Range<Data.Index>?
            while headerEnd == nil {
                let n = read(c, &chunk, chunk.count)
                if n <= 0 { break }
                buf.append(contentsOf: chunk[0..<n])
                headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
            }
            guard let he = headerEnd else { close(c); continue }
            let head = String(decoding: buf[..<he.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let parts = head.first?.split(separator: " ") ?? []
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                if let i = line.firstIndex(of: ":") {
                    headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            var body = Data(buf[he.upperBound...])
            while body.count < length {
                let n = read(c, &chunk, chunk.count)
                if n <= 0 { break }
                body.append(contentsOf: chunk[0..<n])
            }
            let r = Received(method: parts.count > 0 ? String(parts[0]) : "", path: parts.count > 1 ? String(parts[1]) : "",
                             headers: headers, body: body)
            received.with { $0.append(r) }
            let out = respond(r)
            out.withUnsafeBytes { p in
                var off = 0
                while off < out.count {
                    let w = write(c, p.baseAddress! + off, out.count - off)
                    if w <= 0 { break }
                    off += w
                }
            }
            close(c)
        }
    }

    static func response(status: Int, reason: String = "OK", headers: [String: String] = [:], body: Data,
                         contentLength: Bool = true) -> Data {
        var s = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        if contentLength { s += "Content-Length: \(body.count)\r\n" }
        s += "\r\n"
        return Data(s.utf8) + body
    }
}
