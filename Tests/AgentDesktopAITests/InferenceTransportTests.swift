import Foundation
import Testing
@testable import AgentDesktopAI
@testable import AgentDesktopContracts

// Case IDs refer to docs/ai-gui/tests/cases.csv.

@Suite("openai_chat transport")
struct InferenceTransportTests {

    // TRN-001: the exact request, and every response field kept.
    @Test func trn001_multimodalRequestAndFullResponse() async throws {
        let stub = StubTransport(status: 200, headers: ["Content-Type": "application/json", "X-Request-Id": "up-req-42"],
                                 body: okBody())
        let clock = FakeClock()
        let m = model(options: ModelRequestOptions(temperature: 0, seed: 7), maxOutputTokens: 512)
        let result = try await service(stub, clock: clock).infer(screenshotRequest(), resolvedModel: m, context: context(clock: clock))

        #expect(stub.count == 1)
        let req = try #require(stub.captured.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://ark.example.invalid/api/v3/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(canaryKey)")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try StrictJSON.parse(try #require(req.httpBody))
        #expect(body["model"]?.stringValue == "Doubao-Seed-UI-TARS", "model id is sent exactly, case kept")
        #expect(body["stream"] == .bool(false))
        #expect(body["max_tokens"]?.intValue == 512)
        #expect(body["temperature"]?.doubleValue == 0)
        #expect(body["seed"]?.intValue == 7)
        #expect(body["thinking"] == nil && body["top_p"] == nil)
        #expect(Set(body.objectMembers!.map(\.key)) == ["model", "messages", "max_tokens", "stream", "temperature", "seed"])
        let messages = try #require(body["messages"]?.arrayValue)
        #expect(messages[0]["role"]?.stringValue == "system")
        #expect(messages[0]["content"]?.stringValue == "You are a GUI agent.")
        let parts = try #require(messages[1]["content"]?.arrayValue)
        #expect(parts[0]["type"]?.stringValue == "text")
        #expect(parts[1]["type"]?.stringValue == "image_url")
        #expect(parts[1]["image_url"]?["url"]?.stringValue == "data:image/png;base64," + fixturePNG.base64EncodedString())

        #expect(result.outputText == "click(start_box='(100,200)')")
        #expect(result.finishReason == "stop")
        #expect(result.record.requestedModelId == "Doubao-Seed-UI-TARS")
        #expect(result.record.actualModelId == "doubao-ui-tars-actual")
        #expect(result.record.upstreamRequestId == "up-req-42")
        #expect(result.record.usage == UsageTokens(inputTokens: 100, outputTokens: 10, totalTokens: 110))
        #expect(result.record.state == .succeeded)
        #expect(result.record.httpStatus == 200)
    }

    // TRN-002: one way to build the path; no other protocol is sent anywhere.
    @Test(arguments: [
        ("https://ark.example.invalid/api/v3", "https://ark.example.invalid/api/v3/chat/completions"),
        ("https://ark.example.invalid/api/v3/", "https://ark.example.invalid/api/v3/chat/completions"),
        ("https://api.example.invalid/v1", "https://api.example.invalid/v1/chat/completions"),
        ("https://api.example.invalid", "https://api.example.invalid/chat/completions"),
        ("http://127.0.0.1:8000/v1", "http://127.0.0.1:8000/v1/chat/completions"),
        ("http://[::1]:8000", "http://[::1]:8000/chat/completions"),
    ])
    func trn002_pathJoin(base: String, expected: String) throws {
        #expect(try EndpointRules.chatCompletionsURL(base: URL(string: base)!).absoluteString == expected)
    }

    @Test func trn002_refusedEndpointsAndProtocols() async throws {
        for base in ["https://api.example.invalid/v1/chat/completions", "https://api.example.invalid/v1/chat/completions/",
                     "http://api.example.invalid/v1", "https://u:p@api.example.invalid/v1",
                     "https://api.example.invalid/v1?x=1", "https://api.example.invalid/v1#f", "file:///tmp/x"] {
            #expect(throws: ContractError.self, "\(base)") { try EndpointRules.chatCompletionsURL(base: URL(string: base)!) }
        }
        // localhost must resolve to loopback only.
        #expect(throws: ContractError.self) {
            try EndpointRules.chatCompletionsURL(base: URL(string: "http://localhost:9")!, resolve: { _ in ["127.0.0.1", "10.0.0.5"] })
        }
        #expect(try EndpointRules.chatCompletionsURL(base: URL(string: "http://localhost:9")!, resolve: { _ in ["::1", "127.0.0.1"] })
            .absoluteString == "http://localhost:9/chat/completions")

        let stub = StubTransport(body: okBody())
        let clock = FakeClock()
        for p in [AiProtocol.anthropicMessages, .openaiResponses, .geminiGenerateContent] {
            await expectCode(.unsupportedProtocol) {
                _ = try await service(stub, clock: clock).infer(screenshotRequest(), resolvedModel: model(apiProtocol: p), context: context(clock: clock))
            }
        }
        await expectCode(.validationError) {
            _ = try await service(stub, clock: clock).infer(screenshotRequest(),
                resolvedModel: model(base: "https://x.example.invalid/v1/chat/completions"), context: context(clock: clock))
        }
        #expect(stub.count == 0)
    }

    // TRN-003: status classes, retryability, and no upstream body in errors.
    @Test(arguments: [
        (401, ErrorCode.authFailed, false),
        (403, .authFailed, false),
        (404, .modelNotFound, false),
        (429, .rateLimited, true),
        (500, .upstreamUnavailable, true),
        (502, .upstreamUnavailable, true),
        (503, .upstreamUnavailable, true),
        (400, .upstreamProtocolError, false),
    ])
    func trn003_errorClasses(status: Int, code: ErrorCode, retryable: Bool) async throws {
        let echo = #"{"error":{"code":"model_not_found","message":"The model does not exist. You sent Bearer \#(canaryKey) and prompt: secret form data"}}"#
        let stub = StubTransport(status: status, headers: ["Retry-After": "2"], body: echo)
        let clock = FakeClock()
        let ledger = InMemoryAiCallLedger()
        do {
            _ = try await service(stub, ledger: ledger, clock: clock).infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
            Issue.record("expected failure")
        } catch let e as ContractError {
            #expect(e.code == code)
            #expect(e.retryable == retryable)
            #expect(!e.message.contains(canaryKey) && !e.message.contains("secret form data"))
            #expect(!(e.details?.encoded() ?? "").contains(canaryKey))
            if status == 429 { #expect(e.details?["retryAfterMs"]?.intValue == 2000) }
        }
        let rec = try #require(await ledger.records().first)
        #expect(rec.state == .failed)
        #expect(rec.httpStatus == status)
        #expect(!String(reflecting: rec).contains(canaryKey))
    }

    @Test func trn003_plain404IsNotModelNotFound() async throws {
        let stub = StubTransport(status: 404, body: "<html>not here</html>")
        let clock = FakeClock()
        await expectCode(.upstreamProtocolError) {
            _ = try await service(stub, clock: clock).infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
        }
    }

    // TRN-004: incomplete or invalid answers are refused; the next valid one works.
    @Test func trn004_badBodiesThenAGoodOne() async throws {
        let bad = [
            "not json",
            String(okBody().dropLast(5)),
            #"{"choices":[]}"#,
            #"{"choices":[{"message":{"content":42}}]}"#,
            #"{"choices":[{"message":{"content":"a"}}],"choices":[{"message":{"content":"b"}}]}"#,
            #"{"model":"x"}"#,
        ]
        let clock = FakeClock()
        let stub = StubTransport(body: "")
        let svc = service(stub, clock: clock)
        for b in bad {
            stub.setHandler { _, _ in HTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: Data(b.utf8)) }
            await expectCode(.upstreamProtocolError) {
                _ = try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
            }
        }
        stub.setHandler { _, _ in HTTPResult(status: 200, body: Data(okBody(text: "finished()").utf8)) }
        let ok = try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
        #expect(ok.outputText == "finished()")
        #expect(stub.count == bad.count + 1)
    }

    // TRN-006: only temperature and seed; nothing vendor-specific; caps hold.
    @Test func trn006_requestOptions() async throws {
        #expect(try ModelRequestOptions.parse(.obj([("temperature", .double(0.2)), ("seed", .int(3))]))
                == ModelRequestOptions(temperature: 0.2, seed: 3))
        for key in ["thinking", "top_p", "model", "stream", "max_tokens", "credential", "baseUrl", "x_vendor"] {
            #expect(throws: ContractError.self, "\(key)") {
                try ModelRequestOptions.parse(.obj([(key, .obj([("type", .string("disabled"))]))]))
            }
        }
        #expect(throws: ContractError.self) { try ModelRequestOptions.parse(.obj([("temperature", .double(3))])) }

        let stub = StubTransport(body: okBody())
        let clock = FakeClock()
        // The service never sends more than 1024, nor more than the profile allows.
        _ = try await service(stub, clock: clock).infer(screenshotRequest(maxOutputTokens: 1024),
                                                       resolvedModel: model(maxOutputTokens: 300), context: context(clock: clock))
        #expect(try StrictJSON.parse(stub.captured[0].httpBody!)["max_tokens"]?.intValue == 300)
        await expectCode(.limitExceeded) {
            _ = try await service(stub, clock: clock).infer(screenshotRequest(maxOutputTokens: 2000), resolvedModel: model(), context: context(clock: clock))
        }
        #expect(stub.count == 1)
    }

    // TRN-007: nothing is returned before the body is complete; streams and
    // truncated actions are refused.
    @Test func trn007_completeBodyOnly() async throws {
        let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
        let stub = StubTransport { _, _ in
            await withCheckedContinuation { c in gate.with { $0 = c } }
            return HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let clock = FakeClock()
        let done = Locked(false)
        let task = Task {
            let r = try await service(stub, clock: clock).infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
            done.with { $0 = true }
            return r
        }
        for _ in 0..<500 where gate.get() == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(done.get() == false, "no result while the body is still being read")
        gate.get()?.resume()
        let r = try await task.value
        #expect(r.outputText == "click(start_box='(100,200)')")

        for (headers, body) in [
            (["Content-Type": "text/event-stream"], "data: {\"choices\":[{\"delta\":{\"content\":\"cli\"}}]}\n\n"),
            (["Content-Type": "application/json"], "data: {\"choices\":[]}\n\n"),
            (["Content-Type": "application/json"], #"{"choices":[{"message":{"content":"click(start_box='(1"#),
        ] {
            let s = StubTransport(status: 200, headers: headers, body: body)
            await expectCode(.upstreamProtocolError) {
                _ = try await service(s, clock: clock).infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
            }
        }
    }

    @Test func retryAfterForms() {
        #expect(OpenAIChatTransport.retryAfterMs("2") == 2000)
        #expect(OpenAIChatTransport.retryAfterMs("0.5") == 500)
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(OpenAIChatTransport.retryAfterMs(f.string(from: now.addingTimeInterval(3)), now: now) == 3000)
        #expect(OpenAIChatTransport.retryAfterMs("soon") == nil)
    }

    @Test func usageReading() {
        #expect(OpenAIChatTransport.usage(nil) == nil)
        #expect(OpenAIChatTransport.usage(.obj([])) == nil)
        let u = OpenAIChatTransport.usage(.obj([("prompt_tokens", .int(200)), ("completion_tokens", .double(1.5))]))
        #expect(u == UsageTokens(inputTokens: 200, outputTokens: nil))
        #expect(OpenAIChatTransport.usage(.obj([("prompt_tokens", .int(-1))])) == nil)
    }
}

// The real URLSession transport against a loopback server.
@Suite("URLSession transport on loopback", .serialized)
struct InferenceLoopbackTests {
    func liveService(_ ledger: InMemoryAiCallLedger = InMemoryAiCallLedger()) -> DefaultAiService {
        DefaultAiService(http: URLSessionHTTPTransport(), credentials: TestCredentials(), ledger: ledger, clock: SystemMonotonicClock())
    }

    func liveContext() -> AiCallContext { context(clock: SystemMonotonicClock(), deadlineMs: 20_000) }

    // SEC-006: a redirect is not followed; the key never reaches B; the
    // upstream body is not echoed.
    @Test(arguments: [302, 307])
    func sec006_redirectIsNotFollowed(status: Int) async throws {
        let b = try LoopbackHTTPServer { _ in LoopbackHTTPServer.response(status: 200, body: Data(okBody().utf8)) }
        defer { b.stop() }
        let a = try LoopbackHTTPServer { _ in
            LoopbackHTTPServer.response(status: status, reason: "Moved",
                                        headers: ["Location": "\(b.base)/steal/chat/completions"],
                                        body: Data("echo \(canaryKey)".utf8))
        }
        defer { a.stop() }
        let ledger = InMemoryAiCallLedger()
        do {
            _ = try await liveService(ledger).infer(screenshotRequest(), resolvedModel: model(base: "\(a.base)/v1"), context: liveContext())
            Issue.record("expected UPSTREAM_PROTOCOL_ERROR")
        } catch let e as ContractError {
            #expect(e.code == .upstreamProtocolError)
            #expect(!"\(e) \(e.details?.encoded() ?? "")".contains(canaryKey))
        }
        #expect(b.requests.isEmpty, "the redirect target received nothing")
        #expect(a.requests.count == 1)
        #expect(a.requests.first?.path == "/v1/chat/completions")
        #expect(a.requests.first?.headers["authorization"] == "Bearer \(canaryKey)")
        let rec = try #require(await ledger.records().first)
        #expect(!String(reflecting: rec).contains(canaryKey))
    }

    @Test func liveSuccessAndExactLimit() async throws {
        // A body of exactly 2 MiB is accepted.
        var body = okBody()
        body.removeLast()
        body += String(repeating: " ", count: OpenAIChatTransport.maxResponseBytes - body.utf8.count - 1) + "}"
        let payload = Data(body.utf8)
        #expect(payload.count == OpenAIChatTransport.maxResponseBytes)
        let a = try LoopbackHTTPServer { _ in LoopbackHTTPServer.response(status: 200, headers: ["Content-Type": "application/json"], body: payload) }
        defer { a.stop() }
        let r = try await liveService().infer(screenshotRequest(), resolvedModel: model(base: a.base), context: liveContext())
        #expect(r.outputText == "click(start_box='(100,200)')")
        let sent = try StrictJSON.parse(try #require(a.requests.first?.body))
        #expect(sent["stream"] == .bool(false))
    }

    // Responses over 2 MiB stop being read: declared or not.
    @Test(arguments: [true, false])
    func responseLimit(declaredLength: Bool) async throws {
        let big = Data(repeating: UInt8(ascii: " "), count: OpenAIChatTransport.maxResponseBytes + 1)
        let a = try LoopbackHTTPServer { _ in
            LoopbackHTTPServer.response(status: 200, headers: ["Content-Type": "application/json"], body: big, contentLength: declaredLength)
        }
        defer { a.stop() }
        await expectCode(.upstreamProtocolError) {
            _ = try await liveService().infer(screenshotRequest(), resolvedModel: model(base: a.base), context: liveContext())
        }
    }

    @Test func connectionRefusedIsUnavailable() async throws {
        let a = try LoopbackHTTPServer { _ in Data() }
        let port = a.port
        a.stop()
        await expectCode(.upstreamUnavailable) {
            _ = try await liveService().infer(screenshotRequest(), resolvedModel: model(base: "http://127.0.0.1:\(port)"), context: liveContext())
        }
    }
}
