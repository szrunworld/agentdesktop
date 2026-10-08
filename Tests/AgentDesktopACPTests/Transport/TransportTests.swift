import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

@Suite struct ACPFrameSplitterTests {
    @Test func splitsLinesAcrossChunksAndSkipsBlankLines() {
        var s = ACPFrameSplitter(maxFrameBytes: 64)
        #expect(s.feed(Data("{\"a\":".utf8)) == [])
        #expect(s.feed(Data("1}\n\n  \r\n{\"b\":2}\r\n{\"c\"".utf8))
            == [.frame(Data("{\"a\":1}".utf8)), .frame(Data("{\"b\":2}".utf8))])
        #expect(s.pendingByteCount == 4)
        #expect(s.feed(Data(":3}\n".utf8)) == [.frame(Data("{\"c\":3}".utf8))])
        #expect(s.pendingByteCount == 0)
    }

    @Test func oversizedLineIsReportedOnceAndNeverBuffered() {
        var s = ACPFrameSplitter(maxFrameBytes: 8)
        let first = s.feed(Data(repeating: 0x61, count: 6))
        #expect(first == [])
        let crossed = s.feed(Data(repeating: 0x61, count: 100))
        #expect(crossed == [.oversized(bytesSeen: 106, head: Data(repeating: 0x61, count: 106))])
        #expect(s.pendingByteCount == 0)
        // The rest of the long line is dropped; the next line is intact.
        #expect(s.feed(Data(repeating: 0x61, count: 1000) + Data("\n{}\n".utf8)) == [.frame(Data("{}".utf8))])
    }

    @Test func requestIdIsReadFromTheHeadOfACutOffLine() {
        func peek(_ t: String) -> JSONValue? { ACPFrameSplitter.peekRequestId(Data(t.utf8)) }
        #expect(peek(#"{"jsonrpc":"2.0","id":"raw-big","method":"session/prompt","params":{"prompt":"aaaa"#) == .string("raw-big"))
        #expect(peek(#" { "jsonrpc" : "2.0" , "id" : 42 , "method":"x","params":{"t":"aaa"#) == .int(42))
        #expect(peek(#"{"params":{"id":7,"x":[1,{"id":8}]},"id":9,"method":"x","p":"#) == .int(9))
        #expect(peek(#"{"method":"x","params":{"text":"he said "id":3 }","id":5},"id":"s","q":"#) == .string("s"))
        // Not determinable: cut inside the id, no id yet, nested only, bad ids.
        #expect(peek(#"{"jsonrpc":"2.0","id":12"#) == nil)
        #expect(peek(#"{"jsonrpc":"2.0","id":"ab"#) == nil)
        #expect(peek(#"{"jsonrpc":"2.0","method":"x","params":{"id":1,"t":"aaaa"#) == nil)
        #expect(peek(#"{"id":1.5,"x":1}"#) == nil)
        #expect(peek(#"{"id":null,"x":1}"#) == nil)
        #expect(peek(#"{"id":{"a":1},"x":1}"#) == nil)
        #expect(peek("aaaaaaaa") == nil)
        #expect(peek(#"["id",1]"#) == nil)
    }

    @Test func lineOfExactlyTheLimitPasses() {
        var s = ACPFrameSplitter(maxFrameBytes: 4)
        #expect(s.feed(Data("abcd\r\nabcde\n".utf8)) == [.frame(Data("abcd".utf8)), .oversized(bytesSeen: 5, head: Data("abcde".utf8))])
    }
}

@Suite struct ACPJsonRpcCodecTests {
    func decode(_ s: String) -> Result<ACPJsonRpcMessage, ACPJsonRpcDecodeFailure> {
        ACPJsonRpcCodec.decode(Data(s.utf8))
    }

    @Test func decodesTheFourMessageKinds() throws {
        #expect(try decode(#"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/"}}"#).get()
            == .request(id: .int(1), method: "session/new", params: .obj([("cwd", .string("/"))])))
        #expect(try decode(#"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}"#).get()
            == .notification(method: "session/cancel", params: .obj([("sessionId", .string("s"))])))
        #expect(try decode(#"{"jsonrpc":"2.0","id":"x","result":{}}"#).get() == .response(id: .string("x"), result: .obj([])))
        #expect(try decode(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"no"}}"#).get()
            == .errorResponse(id: .int(3), error: .init(code: -32601, message: "no")))
    }

    @Test func refusesMalformedMessagesWithTheRightAnswer() {
        func failure(_ s: String) -> ACPJsonRpcDecodeFailure? {
            if case let .failure(f) = decode(s) { return f } else { return nil }
        }
        #expect(failure("{not json")?.error.code == ACPJsonRpcErrorCode.parseError)
        #expect(failure("{not json")?.replyId == .null)
        #expect(failure(#"{"jsonrpc":"2.0","id":1,"id":2,"method":"x"}"#)?.error.code == ACPJsonRpcErrorCode.parseError)
        #expect(failure(#"[{"jsonrpc":"2.0","id":1,"method":"x"}]"#)?.error.code == ACPJsonRpcErrorCode.invalidRequest)
        #expect(failure(#"{"jsonrpc":"1.0","id":7,"method":"x"}"#)?.replyId == .int(7))
        #expect(failure(#"{"jsonrpc":"2.0","id":1.5,"method":"x"}"#)?.replyId == .null)
        #expect(failure(#"{"jsonrpc":"2.0","id":null,"method":"x"}"#)?.error.code == ACPJsonRpcErrorCode.invalidRequest)
        #expect(failure(#"{"jsonrpc":"2.0","id":1,"method":"x","params":3}"#)?.error.code == ACPJsonRpcErrorCode.invalidRequest)
        #expect(failure(#"{"jsonrpc":"2.0","id":1,"method":""}"#)?.error.code == ACPJsonRpcErrorCode.invalidRequest)
        // A broken response is never answered (nil replyId).
        let r = failure(#"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"m"}}"#)
        #expect(r != nil && r?.replyId == nil)
        #expect(failure(String(repeating: "[", count: 200) + String(repeating: "]", count: 200))?.error.code
            == ACPJsonRpcErrorCode.parseError)
    }

    @Test func framesAreSingleLinesEvenWithLineSeparatorsInStrings() throws {
        let msg = ACPJsonRpcMessage.notification(method: "m", params: .obj([("t", .string("a\nb\r\u{2028}c"))]))
        let frame = ACPJsonRpcCodec.frame(msg)
        #expect(frame.last == 0x0A)
        #expect(frame.dropLast().contains(0x0A) == false)
        #expect(try ACPJsonRpcCodec.decode(Data(frame.dropLast())).get() == msg)
    }
}

/// T01–T03 over the in-memory pipe.
@Suite struct ACPStdioConnectionTests {
    // T01: valid requests reach the server in order and answers go back by id.
    @Test func t01ValidRequestsAreDeliveredAndAnswered() async throws {
        let ed = TTestEditor()
        let initResult = await ed.initialize()
        #expect(initResult?["protocolVersion"] == .int(1))

        await ed.request(1, "session/new", .obj([("cwd", .string("/tmp/w")), ("mcpServers", .array([]))]))
        await ed.request("two", "session/list", .obj([]))
        await ed.request(3, "session/prompt", .obj([("sessionId", .string("s1")),
                                                    ("prompt", .array([.obj([("type", .string("text")),
                                                                             ("text", .string("hi"))])]))]))
        await ed.notify("session/cancel", .obj([("sessionId", .string("s1"))]))

        guard case let .request(id1, .newSession(cwd))? = await ed.nextEvent() else { Issue.record("new"); return }
        #expect(cwd == "/tmp/w")
        guard case let .request(id2, .listSessions(cwd: nil))? = await ed.nextEvent() else { Issue.record("list"); return }
        #expect(id2 == ACPRequestId(.string("two")))
        guard case let .request(id3, .prompt(sid, content))? = await ed.nextEvent() else { Issue.record("prompt"); return }
        #expect(sid == "s1" && content == [.text("hi")])
        #expect(await ed.nextEvent() == .notification(.cancel(sessionId: "s1")))

        await ed.connection.reply(to: id1, .sessionCreated(sessionId: "s1", options: []))
        await ed.connection.send(sessionId: "s1", .agentMessage("hello"))
        await ed.connection.reply(to: id3, .promptFinished(.cancelled))
        await ed.connection.reply(to: id2, .sessions([.init(sessionId: "s1", title: "t", updatedAt: "2026-10-08T00:00:00Z", cwd: "/tmp/w")]))
        // Answering the same request twice sends nothing.
        await ed.connection.reply(to: id3, .promptFinished(.endTurn))

        let f1 = await ed.nextFrame()
        #expect(f1?["id"] == .int(1) && f1?["result"]?["sessionId"] == .string("s1"))
        let f2 = await ed.nextFrame()
        #expect(f2?["method"] == .string("session/update"))
        #expect(f2?["params"]?["update"]?["content"]?["text"] == .string("hello"))
        let f3 = await ed.nextFrame()
        #expect(f3?["id"] == .int(3) && f3?["result"]?["stopReason"] == .string("cancelled"))
        let f4 = await ed.nextFrame()
        #expect(f4?["id"] == .string("two"))
        #expect(f4?["result"]?["sessions"]?.arrayValue?.first?["cwd"] == .string("/tmp/w"))
        #expect(await ed.probeFrameIsNext())
        #expect(ed.schemaProblems == [])
    }

    @Test func t01AgentToEditorRequestsCorrelateById() async throws {
        let ed = TTestEditor()
        await ed.initialize(clientCapabilities: .obj([("elicitation", .obj([("form", .obj([]))]))]))
        #expect(ed.connection.clientCapabilities.elicitation)

        let call = ACPToolCall(toolCallId: "t1", title: "Click Send", kind: .execute, status: .pending)
        let request = ACPPermissionRequest(sessionId: "s1", toolCall: call, summary: ["Sends one message"])
        async let permission = ed.connection.requestPermission(request)
        async let answer = ed.connection.ask(ACPQuestion(sessionId: "s1", message: "Which?", choices: ["a", "b"]))

        var permId: JSONValue?, askId: JSONValue?
        for _ in 0..<2 {
            let f = await ed.nextFrame()
            if f?["method"] == .string("session/request_permission") { permId = f?["id"] }
            if f?["method"] == .string("elicitation/create") { askId = f?["id"] }
        }
        guard let permId, let askId else { Issue.record("requests not sent"); return }
        #expect(permId != askId)
        // Answer out of order; each lands on its own request.
        await ed.respond(askId, .obj([("action", .string("accept")),
                                      ("content", .obj([("answer", .string("b"))]))]))
        await ed.respond(permId, .obj([("outcome", .obj([("outcome", .string("selected")),
                                                         ("optionId", .string("allow_once"))]))]))
        #expect(await permission == .selected(.allowOnce))
        #expect(await answer == .answered("b"))
        #expect(ed.schemaProblems == [])
    }

    // T01: JSON-RPC pipelining. initialize, session/new, session/list and a
    // notification in one write: nothing is refused, the server sees them in
    // order, and only after the initialize answer is out.
    @Test func t01PipelinedRequestsWaitForTheInitializeAnswer() async throws {
        let ed = TTestEditor()
        let lines = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/p","mcpServers":[]}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"session/list","params":{"cwd":"/p"}}"#,
            #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}}"#,
        ]
        await ed.sendPipelined(lines)
        guard case let .request(initId, .initialize)? = await ed.nextEvent() else { Issue.record("init"); return }
        await ed.connection.reply(to: initId, .initialized(version: .v1, agent: .init(name: "a", version: "1"),
                                                           capabilities: TTestEditor.defaultCaps))
        // The first frame out is the initialize answer, not a refusal.
        let first = await ed.nextFrame()
        #expect(first?["id"] == .int(0) && first?["result"]?["protocolVersion"] == .int(1))
        guard case let .request(newId, .newSession("/p"))? = await ed.nextEvent() else { Issue.record("new"); return }
        guard case let .request(listId, .listSessions(cwd: "/p"))? = await ed.nextEvent() else { Issue.record("list"); return }
        #expect(await ed.nextEvent() == .notification(.cancel(sessionId: "s1")))
        await ed.connection.reply(to: newId, .sessionCreated(sessionId: "s1", options: []))
        await ed.connection.reply(to: listId, .sessions([]))
        #expect(await ed.nextFrame()?["id"] == .int(1))
        #expect(await ed.nextFrame()?["id"] == .int(2))
        #expect(await ed.probeFrameIsNext())
        #expect(ed.schemaProblems == [])
    }

    @Test func t01PipelinedRequestsAfterARefusedInitializeAreRefusedInOrder() async throws {
        let ed = TTestEditor()
        let lines = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/p","mcpServers":[]}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"session/list","params":{}}"#,
        ]
        await ed.sendPipelined(lines)
        guard case let .request(initId, .initialize)? = await ed.nextEvent() else { Issue.record("init"); return }
        await ed.connection.reply(to: initId, .error(ACPError(code: -32000, reason: "auth_required", message: "no")))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(-32000))
        for id in [1, 2] {
            let f = await ed.nextFrame()
            #expect(f?["id"] == .int(id))
            #expect(f?["error"]?["message"] == .string("connection not initialized: send initialize first"))
        }
        // Not ready, so a fresh initialize is accepted again.
        #expect(await ed.initialize() != nil)
    }

    // T02: malformed frames are answered safely; the connection keeps going.
    @Test func t02MalformedFramesAreRefusedSafely() async throws {
        let ed = TTestEditor()
        await ed.initialize()
        await ed.sendRaw("this is not json\n")
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.parseError))
        await ed.sendRaw(#"{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"s"}}"# + "\n")
        let bad = await ed.nextFrame()
        #expect(bad?["id"] == .int(5) && bad?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidParams))
        await ed.request(6, "no/such_method", .obj([]))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.methodNotFound))
        await ed.request(7, "session/new", .obj([("cwd", .string("relative/path")), ("mcpServers", .array([]))]))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidParams))
        // A response to an id we never used is ignored.
        await ed.respond(.int(999), .obj([]))
        // Unknown notifications get no answer.
        await ed.notify("$/cancel_request", .obj([("requestId", .int(1))]))
        #expect(await ed.probeFrameIsNext())
        // None of the refused frames reached the server, and it is still alive.
        #expect(await ed.probeEventIsNext())
        #expect(ed.schemaProblems == [])
    }

    @Test func t02RequestsBeforeInitializeAreRefused() async throws {
        let ed = TTestEditor()
        await ed.request(1, "session/new", .obj([("cwd", .string("/x")), ("mcpServers", .array([]))]))
        let f = await ed.nextFrame()
        #expect(f?["id"] == .int(1) && f?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidRequest))
        // The refused request never reached the server: the next event is initialize.
        #expect(await ed.initialize() != nil)
        await ed.request(2, "initialize", .obj([("protocolVersion", .int(1))]))
        #expect(await ed.nextFrame()?["error"]?["message"] == .string("connection already initialized"))
    }

    // README §6: an oversized frame is refused (id null) and skipped; the
    // connection, and the Runs it controls, stay up.
    @Test func t02OversizedFrameIsRefusedAndSkipped() async throws {
        var opts = ACPStdioConnectionOptions()
        opts.maxFrameBytes = 1024
        opts.maxMalformedFrames = 1
        let ed = TTestEditor(options: opts)
        await ed.initialize()
        // A huge line arriving in pieces, then a valid request on the next line.
        await ed.sendRaw("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/new\",\"params\":{\"cwd\":\""
                         + String(repeating: "a", count: 4096))
        await ed.sendRaw(String(repeating: "b", count: 64 * 1024))
        // Answered under its own id (read from the line's head), so the editor
        // is not left waiting; the error is the frame-level one.
        let f = await ed.nextFrame()
        #expect(f?["id"] == .int(1) && f?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidRequest))
        await ed.sendRaw("\"}}\n")  // end of the oversized line: dropped, not parsed
        // Several oversized frames do not count as malformed (limit is 1 here).
        for _ in 0..<3 { await ed.sendRaw(String(repeating: "c", count: 2048) + "\n") }
        for _ in 0..<3 { #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidRequest)) }
        // Still alive, nothing reached the server, next line is processed.
        #expect(await ed.probeEventIsNext())
        #expect(await ed.probeFrameIsNext())
        #expect(ed.schemaProblems == [])
    }

    // README §6: updates and a later reply reach stdout in call order
    // (session/load replays history before it answers).
    @Test func t01UpdatesThenReplyKeepCallOrder() async throws {
        let ed = TTestEditor()
        var caps = TTestEditor.defaultCaps
        caps.resumeSessions = true
        await ed.initialize(agentCaps: caps)
        await ed.request(1, "session/load", .obj([("sessionId", .string("s")), ("cwd", .string("/w")),
                                                  ("mcpServers", .array([]))]))
        guard case let .request(id, .resumeSession(sessionId: "s", cwd: "/w", replay: true))? = await ed.nextEvent()
        else { Issue.record("load"); return }
        for i in 0..<200 { await ed.connection.send(sessionId: "s", .agentMessage("history \(i)")) }
        await ed.connection.reply(to: id, .resumed(options: []))
        for i in 0..<200 {
            let f = await ed.nextFrame()
            #expect(f?["params"]?["update"]?["content"]?["text"] == .string("history \(i)"))
        }
        #expect(await ed.nextFrame()?["id"] == .int(1))
        #expect(await ed.probeFrameIsNext())
        #expect(ed.schemaProblems == [])
    }

    @Test func t02TooManyMalformedFramesClose() async throws {
        var opts = ACPStdioConnectionOptions()
        opts.maxMalformedFrames = 3
        let ed = TTestEditor(options: opts)
        for _ in 0..<4 { await ed.sendRaw("}\n") }
        #expect(await ed.nextEvent() == .closed(reason: "too_many_malformed_frames"))
    }

    // T03: abrupt close never crashes, pending requests become .unavailable,
    // and nothing is delivered after `.closed`.
    @Test func t03AbruptCloseResolvesPendingAsUnavailable() async throws {
        let ed = TTestEditor()
        await ed.initialize(clientCapabilities: .obj([("elicitation", .obj([("form", .obj([]))]))]))
        await ed.request(1, "session/prompt", .obj([("sessionId", .string("s")), ("prompt", .array([]))]))
        guard case let .request(promptId, .prompt)? = await ed.nextEvent() else { Issue.record("prompt"); return }

        let call = ACPToolCall(toolCallId: "t", title: "x", kind: .other, status: .pending)
        async let permission = ed.connection.requestPermission(ACPPermissionRequest(sessionId: "s", toolCall: call, summary: []))
        async let answer = ed.connection.ask(ACPQuestion(sessionId: "s", message: "?"))
        _ = await ed.nextFrame(); _ = await ed.nextFrame()
        await ed.sendRaw(#"{"jsonrpc":"2.0","id":2,"method":"session/pro"#)  // half a frame, then EOF
        ed.close()

        #expect(await permission == .unavailable)
        #expect(await answer == .unavailable)
        #expect(await ed.nextEvent() == .closed(reason: "input_closed_mid_frame"))
        #expect(await ed.nextEvent() == nil)  // the stream ended
        // After close every peer call is a safe no-op or .unavailable.
        await ed.connection.reply(to: promptId, .promptFinished(.endTurn))
        await ed.connection.send(sessionId: "s", .agentMessage("late"))
        #expect(await ed.connection.requestPermission(ACPPermissionRequest(sessionId: "s", toolCall: call, summary: []))
            == .unavailable)
    }

    @Test func t03CleanEofIsReportedOnce() async throws {
        let ed = TTestEditor()
        ed.editorSide.closeWriteSide()
        #expect(await ed.nextEvent() == .closed(reason: "input_closed"))
        #expect(await ed.nextEvent() == nil)  // the stream ended
    }

    @Test func t03EditorThatStopsReadingMakesWritesFailNotCrash() async throws {
        let ed = TTestEditor()
        await ed.initialize()
        ed.editorSide.close()
        await ed.connection.send(sessionId: "s", .agentMessage("nobody listens"))
        let e = await ed.nextEvent()
        #expect(e == .closed(reason: "input_closed") || e == .closed(reason: "output_closed"))
    }

    @Test func t03ProcessPipesEndCleanly() async throws {
        // The FileHandle transport over real OS pipes.
        let toAgent = Pipe(), fromAgent = Pipe()
        let transport = ACPStdioFileTransport(input: toAgent.fileHandleForReading, output: fromAgent.fileHandleForWriting)
        let conn = ACPStdioConnection(transport: transport)
        conn.start()
        let events = TTestInbox<ACPConnectionEvent>()
        Task { for await e in conn.events { await events.put(e) }; await events.finish() }
        toAgent.fileHandleForWriting.write(Data(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}"#.utf8 + [0x0A]))
        guard case let .request(id, .initialize(_, _, requested))? = await events.next() else { Issue.record("init"); return }
        #expect(requested == "1")
        await conn.reply(to: id, .initialized(version: .v1, agent: .init(name: "a", version: "1"), capabilities: .init()))
        let line = fromAgent.fileHandleForReading.availableData
        let v = try StrictJSON.parse(Data(line.dropLast()))
        #expect(v["result"]?["protocolVersion"] == .int(1))
        #expect(TTestSchema.check(v, answering: "initialize") == [])
        // Broken output pipe: no SIGPIPE, the connection just closes.
        try fromAgent.fileHandleForReading.close()
        await conn.send(sessionId: "s", .agentMessage("x"))
        #expect(await events.next() == .closed(reason: "output_closed"))
        try toAgent.fileHandleForWriting.close()
    }
}

extension TTestEditor {
    func request(_ id: String, _ method: String, _ params: JSONValue) async {
        await send(.obj([("jsonrpc", .string("2.0")), ("id", .string(id)), ("method", .string(method)),
                         ("params", params)]))
    }
}
