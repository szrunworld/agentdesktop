import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// T04: version negotiation.
@Suite struct ACPWireNegotiationTests {
    func negotiate(_ params: JSONValue?) -> Result<ACPWireNegotiation.Outcome, ACPJsonRpcError> {
        ACPWireNegotiation.negotiate(params: params)
    }

    @Test func onlyVersionOneIsSupported() {
        #expect(ACPWireNegotiation.supported == [.v1])
        #expect(ACPWire.adapter(for: .v2) == nil)
    }

    @Test func t04SameVersionIsAccepted() throws {
        let o = try negotiate(.obj([("protocolVersion", .int(1))])).get()
        #expect(o.version == .v1 && o.requested == 1)
    }

    @Test func t04NewerClientIsAnsweredWithOurLatest() throws {
        // Spec: answer the latest version we support; the client decides.
        let o = try negotiate(.obj([("protocolVersion", .int(2))])).get()
        #expect(o.version == .v1 && o.requested == 2)
        #expect(try negotiate(.obj([("protocolVersion", .int(65535))])).get().version == .v1)
    }

    @Test func t04OlderClientIsRefusedClearly() {
        guard case let .failure(e) = negotiate(.obj([("protocolVersion", .int(0))])) else {
            Issue.record("version 0 accepted"); return
        }
        #expect(e.code == ACPJsonRpcErrorCode.invalidRequest)
        #expect(e.message == "unsupported ACP protocol version 0; this agent speaks 1")
        #expect(e.data?["reason"] == .string("protocol_version_unsupported"))
    }

    @Test func t04MalformedVersionsAreInvalidParams() {
        for bad: JSONValue? in [nil, .obj([]), .obj([("protocolVersion", .string("1"))]),
                                .obj([("protocolVersion", .double(1.5))]), .obj([("protocolVersion", .int(-1))]),
                                .obj([("protocolVersion", .int(65536))]),
                                .obj([("protocolVersion", .number(raw: "1.0", value: 1))]),
                                .obj([("protocolVersion", .number(raw: "1e0", value: 1))])] {
            guard case let .failure(e) = negotiate(bad) else { Issue.record("accepted \(String(describing: bad))"); continue }
            #expect(e.code == ACPJsonRpcErrorCode.invalidParams)
        }
    }

    @Test func t04OverTheWire() async throws {
        let ed = TTestEditor()
        await ed.request(0, "initialize", .obj([("protocolVersion", .int(0))]))
        let refused = await ed.nextFrame()
        #expect(refused?["id"] == .int(0))
        #expect(refused?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidRequest))
        #expect(ed.connection.negotiatedVersion == nil)
        // A later valid initialize (a newer client) still works and gets 1.
        let result = await ed.initialize(protocolVersion: 2)
        #expect(result?["protocolVersion"] == .int(1))
        #expect(ed.connection.negotiatedVersion == .v1)
        #expect(ed.schemaProblems == [])
    }

    @Test func t04ServerCannotAnswerAnotherVersion() async throws {
        let ed = TTestEditor()
        await ed.request(0, "initialize", .obj([("protocolVersion", .int(1))]))
        guard case let .request(id, .initialize)? = await ed.nextEvent() else { Issue.record("init"); return }
        await ed.connection.reply(to: id, .initialized(version: .v2, agent: .init(name: "a", version: "1"),
                                                       capabilities: .init()))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.internalError))
        // Not initialized: session methods stay refused.
        await ed.request(1, "session/new", .obj([("cwd", .string("/")), ("mcpServers", .array([]))]))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidRequest))
    }
}

/// T05: we never claim a capability we do not implement, and unadvertised
/// methods do not exist.
@Suite struct ACPWireCapabilityTests {
    @Test func t05DefaultsAdvertiseNothingOptional() async throws {
        let ed = TTestEditor()
        let r = await ed.initialize(agentCaps: ACPAgentCapabilities())
        let caps = r?["agentCapabilities"]
        #expect(caps?["loadSession"] == .bool(false))
        #expect(caps?["promptCapabilities"] == .obj([("image", .bool(false)), ("audio", .bool(false)),
                                                    ("embeddedContext", .bool(false))]))
        #expect(caps?["mcpCapabilities"] == .obj([("http", .bool(false)), ("sse", .bool(false))]))
        #expect(caps?["sessionCapabilities"] == .obj([]))
        #expect(r?["authMethods"] == .array([]))
        #expect(ed.schemaProblems == [])

        // Every gated or never-implemented method is "method not found".
        let refused = ["session/load", "session/resume", "session/list", "session/close", "session/delete",
                       "session/set_mode", "session/fork", "authenticate", "logout", "providers/list",
                       "nes/start", "fs/read_text_file", "terminal/create", "_agentdesktop/anything"]
        for (i, m) in refused.enumerated() {
            await ed.request(100 + i, m, .obj([("sessionId", .string("s")), ("cwd", .string("/")),
                                               ("mcpServers", .array([]))]))
            let f = await ed.nextFrame()
            #expect(f?["error"]?["code"] == .int(ACPJsonRpcErrorCode.methodNotFound), "\(m)")
        }
        // Content types not advertised are refused.
        for block: JSONValue in [
            .obj([("type", .string("image")), ("data", .string("AA==")), ("mimeType", .string("image/png"))]),
            .obj([("type", .string("audio")), ("data", .string("AA==")), ("mimeType", .string("audio/wav"))]),
            .obj([("type", .string("resource")), ("resource", .obj([("uri", .string("file:///a")),
                                                                    ("text", .string("x"))]))]),
        ] {
            await ed.request(200, "session/prompt", .obj([("sessionId", .string("s")), ("prompt", .array([block]))]))
            #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidParams))
        }
        #expect(await ed.probeEventIsNext())
        #expect(ed.schemaProblems == [])
    }

    @Test func t05AdvertisedCapabilitiesMatchTheServerAndUnlockTheirMethods() async throws {
        var c = ACPAgentCapabilities()
        c.resumeSessions = true; c.listSessions = true; c.closeSessions = true
        c.promptImages = true; c.promptEmbeddedContext = true
        let ed = TTestEditor()
        let r = await ed.initialize(agentCaps: c)
        let caps = r?["agentCapabilities"]
        #expect(caps?["loadSession"] == .bool(true))
        // resumeSessions unlocks both v1 ways back: load (replay) and resume (no replay).
        #expect(caps?["sessionCapabilities"] == .obj([("list", .obj([])), ("close", .obj([])), ("resume", .obj([]))]))
        #expect(caps?["promptCapabilities"]?["image"] == .bool(true))
        #expect(caps?["promptCapabilities"]?["audio"] == .bool(false))

        await ed.request(1, "session/load", .obj([("sessionId", .string("s")), ("cwd", .string("/w")),
                                                  ("mcpServers", .array([]))]))
        guard case let .request(lid, .resumeSession(sessionId: "s", cwd: "/w", replay: true))? = await ed.nextEvent() else { Issue.record("load"); return }
        await ed.request(11, "session/resume", .obj([("sessionId", .string("s")), ("cwd", .string("/w2"))]))
        guard case let .request(rid, .resumeSession(sessionId: "s", cwd: "/w2", replay: false))? = await ed.nextEvent() else { Issue.record("resume"); return }
        await ed.request(12, "session/list", .obj([("cwd", .string("/w"))]))
        guard case let .request(listId, .listSessions(cwd: "/w"))? = await ed.nextEvent() else { Issue.record("list cwd"); return }
        // A relative cwd is refused before it reaches the server.
        await ed.request(13, "session/resume", .obj([("sessionId", .string("s")), ("cwd", .string("rel"))]))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidParams))
        await ed.request(14, "session/list", .obj([("cwd", .string("rel"))]))
        #expect(await ed.nextFrame()?["error"]?["code"] == .int(ACPJsonRpcErrorCode.invalidParams))
        await ed.connection.reply(to: rid, .resumed(options: []))
        #expect(await ed.nextFrame()?["id"] == .int(11))
        await ed.connection.reply(to: listId, .sessions([.init(sessionId: "s", title: "T", updatedAt: "2026-10-08T00:00:00Z", cwd: "/w")]))
        let listed = await ed.nextFrame()
        #expect(listed?["result"]?["sessions"]?.arrayValue?.first?["cwd"] == .string("/w"))
        await ed.request(2, "session/close", .obj([("sessionId", .string("s"))]))
        guard case let .request(cid, .closeSession("s"))? = await ed.nextEvent() else { Issue.record("close"); return }
        await ed.request(3, "session/prompt", .obj([("sessionId", .string("s")), ("prompt", .array([
            .obj([("type", .string("image")), ("data", .string("iVBORw0KGgo=")), ("mimeType", .string("image/png"))]),
            .obj([("type", .string("resource")), ("resource", .obj([("uri", .string("file:///a.txt")),
                                                                    ("mimeType", .string("text/plain")),
                                                                    ("text", .string("body"))]))]),
            .obj([("type", .string("resource_link")), ("uri", .string("file:///b")), ("name", .string("b"))]),
        ]))]))
        guard case let .request(pid, .prompt(_, content))? = await ed.nextEvent() else { Issue.record("prompt"); return }
        guard case let .image(mime, handle)? = content.first else { Issue.record("image"); return }
        #expect(mime == "image/png")
        #expect(ed.connection.image(handle: handle)?.base64 == "iVBORw0KGgo=")
        #expect(content.dropFirst().elementsEqual([.resource(uri: "file:///a.txt", mimeType: "text/plain", text: "body"),
                                                   .resource(uri: "file:///b", mimeType: nil, text: nil)]))
        await ed.connection.reply(to: lid, .resumed(options: []))
        await ed.connection.reply(to: cid, .closed)
        await ed.connection.reply(to: pid, .promptFinished(.endTurn))
        for _ in 0..<3 { #expect(await ed.nextFrame()?["result"] != nil) }
        #expect(ed.schemaProblems == [])
    }

    @Test func t05ElicitationNeedsAnExplicitFormCapability() async throws {
        for caps: JSONValue in [.obj([]), .obj([("elicitation", .obj([]))]),
                                .obj([("elicitation", .obj([("form", .null), ("url", .obj([]))]))])] {
            let ed = TTestEditor()
            await ed.initialize(clientCapabilities: caps)
            #expect(ed.connection.clientCapabilities.elicitation == false)
            // Never sent, never an answer.
            #expect(await ed.connection.ask(ACPQuestion(sessionId: "s", message: "?")) == .unavailable)
            #expect(await ed.probeFrameIsNext())
        }
    }

    @Test func clientCapabilitiesAreReadLeniently() {
        let w = ACPWireV1()
        let (info, caps) = w.decodeInitialize(params: .obj([
            ("protocolVersion", .int(1)),
            ("clientCapabilities", .obj([("fs", .obj([("readTextFile", .bool(true)), ("writeTextFile", .string("yes"))])),
                                         ("terminal", .bool(true))])),
            ("clientInfo", .obj([("name", .string("zed")), ("version", .string("1.23.2"))])),
        ]))
        #expect(info == ACPImplementationInfo(name: "zed", version: "1.23.2"))
        #expect(caps.readTextFile && !caps.writeTextFile && caps.terminal && !caps.elicitation)
    }
}

/// Every message shape the v1 encoder can emit validates against the
/// vendored official schema.
@Suite struct ACPWireV1SchemaTests {
    let w = ACPWireV1()

    @Test func schemaFixtureLoadsAndCatchesBadShapes() {
        #expect(TTestSchema.violations(.obj([("stopReason", .string("end_turn"))]), def: "PromptResponse") == [])
        #expect(!TTestSchema.violations(.obj([("stopReason", .string("done"))]), def: "PromptResponse").isEmpty)
        #expect(!TTestSchema.violations(.obj([("sessionId", .string("s")),
                                              ("update", .obj([("sessionUpdate", .string("nope"))]))]),
                                        def: "SessionNotification").isEmpty)
        // A v1 plan entry needs a priority; a missing required field is caught.
        let plan = JSONValue.obj([("sessionId", .string("s")), ("update", .obj([
            ("sessionUpdate", .string("plan")),
            ("entries", .array([.obj([("content", .string("a")), ("status", .string("pending"))])])),
        ]))])
        #expect(!TTestSchema.violations(plan, def: "SessionNotification").isEmpty)
        // The whole-message root check rejects a frame without jsonrpc.
        #expect(!TTestSchema.rootViolations(.obj([("id", .int(1)), ("result", .obj([]))])).isEmpty)
    }

    func frame(_ m: ACPJsonRpcMessage) -> JSONValue { ACPJsonRpcCodec.encode(m) }

    @Test func everyUpdateValidates() {
        let call = ACPToolCall(toolCallId: "t1", title: "Open window", kind: .execute, status: .inProgress,
                               level: .refused(code: "policy_denied"), detail: ["line 1", "line 2"])
        let updates: [ACPSessionUpdate] = [
            .agentMessage("hi"), .agentThought("thinking"),
            .plan([.init(content: "a", status: .pending), .init(content: "b", status: .inProgress),
                   .init(content: "c", status: .completed)]),
            .toolCall(call), .toolCallUpdate(ACPToolCall(toolCallId: "t1", title: "x", kind: .read, status: .completed)),
            .toolCall(ACPToolCall(toolCallId: "t2", title: "y", kind: .think, status: .failed, level: .unknown)),
            .availableCommands([.init(name: "run", description: "Run a task", inputHint: "task name"),
                                .init(name: "list", description: "List")]),
            .configOptions([.init(id: "mode", name: "Mode", value: "ask", choices: ["ask", "auto"])]),
            .sessionInfo(title: "Title"),
        ]
        for u in updates {
            guard let (method, params) = w.encodeUpdate(sessionId: "s1", u) else { Issue.record("\(u) dropped"); continue }
            let problems = TTestSchema.check(frame(.notification(method: method, params: params)))
            #expect(problems == [], "\(u)")
        }
        for kind in [ACPToolKind.read, .execute, .other, .think, .fetch, .search] {
            for status in [ACPToolStatus.pending, .inProgress, .completed, .failed] {
                let p = w.encodeUpdate(sessionId: "s", .toolCall(.init(toolCallId: "t", title: "t", kind: kind, status: status)))!
                #expect(TTestSchema.check(frame(.notification(method: p.method, params: p.params))) == [])
            }
        }
    }

    // README §7 P2: an unknown outcome is a terminal state, never success.
    @Test func unknownOutcomeIsTerminatedNotSucceeded() {
        #expect(ACPWireV1.terminalUnknownStatus == .failed)
        let title = "结果未知 · 需要核实"
        for status in [ACPToolStatus.failed, .completed] {
            let call = ACPToolCall(toolCallId: "t", title: title, kind: .execute, status: status, level: .unknown)
            for u in [ACPSessionUpdate.toolCall(call), .toolCallUpdate(call)] {
                let p = w.encodeUpdate(sessionId: "s", u)!
                let body = p.params["update"]
                #expect(body?["status"] == .string("failed"))
                #expect(body?["title"] == .string(title))
                #expect(body?["rawOutput"] == .obj([("execution", .string("terminated")), ("outcome", .string("unknown"))]))
                #expect(body?["_meta"]?["agentdesktop"]?["actionLevel"] == .string("unknown"))
                #expect(TTestSchema.check(frame(.notification(method: p.method, params: p.params))) == [])
            }
        }
        for status in [ACPToolStatus.pending, .inProgress] {
            let call = ACPToolCall(toolCallId: "t", title: "x", kind: .execute, status: status, level: .unknown)
            let p = w.encodeUpdate(sessionId: "s", .toolCallUpdate(call))!
            #expect(p.params["update"]?["status"] == .string(status.rawValue))
            #expect(p.params["update"]?["rawOutput"] == .obj([("outcome", .string("unknown"))]))
            #expect(TTestSchema.check(frame(.notification(method: p.method, params: p.params))) == [])
        }
        // Permission requests carry the same mapping; other levels have no rawOutput.
        let perm = w.encodePermissionRequest(ACPPermissionRequest(
            sessionId: "s", toolCall: ACPToolCall(toolCallId: "t", title: "x", kind: .execute, status: .failed, level: .unknown),
            summary: []))
        #expect(perm.params["toolCall"]?["rawOutput"]?["execution"] == .string("terminated"))
        #expect(TTestSchema.check(frame(.request(id: .int(0), method: perm.method, params: perm.params))) == [])
        for level in [ACPActionLevel.accepted, .dispatched, .executed, .verified, .contradicted, .refused(code: "x")] {
            let p = w.encodeUpdate(sessionId: "s", .toolCallUpdate(ACPToolCall(toolCallId: "t", title: "x", kind: .other,
                                                                               status: .failed, level: level)))!
            #expect(p.params["update"]?["rawOutput"] == nil)
            #expect(p.params["update"]?["status"] == .string("failed"))
        }
    }

    @Test func updatesV1CannotExpressAreDroppedNotFaked() {
        #expect(w.encodeUpdate(sessionId: "s", .usage(inputTokens: 1, outputTokens: 2)) == nil)
        #expect(w.encodeUpdate(sessionId: "s", .turnEnded(.endTurn)) == nil)
    }

    @Test func everyReplyValidates() throws {
        var all = ACPAgentCapabilities()
        all.resumeSessions = true; all.listSessions = true; all.closeSessions = true
        all.promptImages = true; all.promptEmbeddedContext = true
        let opts = [ACPConfigOption(id: "mode", name: "Mode", value: "auto", choices: ["ask", "auto"]),
                    ACPConfigOption(id: "desktop", name: "Desktop", value: "d1", choices: ["d1"])]
        let cases: [(ACPReply, String)] = [
            (.initialized(version: .v1, agent: .init(name: "agentdesktop", version: "1"), capabilities: .init()), "initialize"),
            (.initialized(version: .v1, agent: .init(name: "agentdesktop", version: "1"), capabilities: all), "initialize"),
            (.sessionCreated(sessionId: "s", options: opts), "session/new"),
            (.sessionCreated(sessionId: "s", options: []), "session/new"),
            (.sessions([]), "session/list"),
            (.sessions([.init(sessionId: "s", title: "T", updatedAt: "2026-10-08T01:02:03Z", cwd: "/w")]), "session/list"),
            (.resumed(options: opts), "session/resume"),
            (.resumed(options: opts), "session/load"),
            (.closed, "session/close"),
            (.promptFinished(.endTurn), "session/prompt"), (.promptFinished(.cancelled), "session/prompt"),
            (.promptFinished(.refusal), "session/prompt"), (.promptFinished(.maxTurnRequests), "session/prompt"),
            (.configSet(options: opts), "session/set_config_option"),
        ]
        for (reply, method) in cases {
            let result = try w.encodeReply(reply, method: method).get()
            #expect(TTestSchema.check(frame(.response(id: .int(1), result: result)), answering: method) == [], "\(reply)")
        }
        guard case let .failure(e) = w.encodeReply(.error(ACPError(code: -32002, reason: "session_not_found",
                                                                   message: "no such session")), method: "session/load")
        else { Issue.record("error encoded as result"); return }
        #expect(TTestSchema.check(frame(.errorResponse(id: .string("x"), error: e))) == [])
        #expect(e.data?["reason"] == .string("session_not_found"))
    }

    @Test func repliesThatDoNotFitTheMethodAreInternalErrors() {
        for (reply, method) in [(ACPReply.closed, "session/prompt"), (.promptFinished(.endTurn), "session/new"),
                                (.sessions([]), "session/close"),
                                (.initialized(version: .v2, agent: .init(name: "a", version: "1"), capabilities: .init()), "initialize")] {
            guard case let .failure(e) = w.encodeReply(reply, method: method) else { Issue.record("\(reply)"); continue }
            #expect(e.code == ACPJsonRpcErrorCode.internalError)
        }
    }

    @Test func agentRequestsValidate() {
        let call = ACPToolCall(toolCallId: "t", title: "Send", kind: .execute, status: .pending, detail: ["d"])
        let p = w.encodePermissionRequest(ACPPermissionRequest(sessionId: "s", toolCall: call, summary: ["Sends 1 message"]))
        #expect(TTestSchema.check(frame(.request(id: .int(0), method: p.method, params: p.params))) == [])
        #expect(p.params["options"]?.arrayValue?.compactMap { $0["kind"]?.stringValue } == ["allow_once", "reject_once"])
        for q in [ACPQuestion(sessionId: "s", message: "Name?"), ACPQuestion(sessionId: "s", message: "Pick", choices: ["a", "b"])] {
            let e = w.encodeQuestion(q)
            #expect(TTestSchema.check(frame(.request(id: .int(1), method: e.method, params: e.params))) == [])
        }
    }

    @Test func permissionAnswersNeverWidenToAllow() {
        let call = ACPToolCall(toolCallId: "t", title: "x", kind: .other, status: .pending)
        let both = ACPPermissionRequest(sessionId: "s", toolCall: call, summary: [])
        let rejectOnly = ACPPermissionRequest(sessionId: "s", toolCall: call, summary: [], options: [.rejectOnce])
        func sel(_ id: String) -> JSONValue {
            .obj([("outcome", .obj([("outcome", .string("selected")), ("optionId", .string(id))]))])
        }
        #expect(w.decodePermissionResult(sel("allow_once"), request: both) == .selected(.allowOnce))
        #expect(w.decodePermissionResult(sel("reject_once"), request: both) == .selected(.rejectOnce))
        #expect(w.decodePermissionResult(sel("allow_once"), request: rejectOnly) == .unavailable)
        #expect(w.decodePermissionResult(sel("allow_always"), request: both) == .unavailable)
        #expect(w.decodePermissionResult(.obj([("outcome", .obj([("outcome", .string("cancelled"))]))]), request: both) == .cancelled)
        #expect(w.decodePermissionResult(.obj([]), request: both) == .unavailable)
    }

    @Test func elicitationAnswers() {
        let q = ACPQuestion(sessionId: "s", message: "?", choices: ["a"])
        #expect(w.decodeAnswer(.obj([("action", .string("accept")), ("content", .obj([("answer", .string("a"))]))]), question: q) == .answered("a"))
        #expect(w.decodeAnswer(.obj([("action", .string("accept")), ("content", .obj([("answer", .string("z"))]))]), question: q) == .unavailable)
        #expect(w.decodeAnswer(.obj([("action", .string("decline"))]), question: q) == .declined)
        #expect(w.decodeAnswer(.obj([("action", .string("cancel"))]), question: q) == .declined)
        #expect(w.decodeAnswer(.obj([("action", .string("accept"))]), question: q) == .unavailable)
        #expect(w.decodeAnswer(.obj([]), question: q) == .unavailable)
    }
}
