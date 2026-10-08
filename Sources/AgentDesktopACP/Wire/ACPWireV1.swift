import AgentDesktopProtocol
import Foundation

/// ACP protocol version 1 (stable schema v1.24.1, spec commit 1c2b84c7;
/// Tests/AgentDesktopACPTests/Fixtures/acp-schema). Only the stable surface:
/// no `schema.unstable.json` method or field is read or written.
public final class ACPWireV1: ACPWireAdapter, @unchecked Sendable {
    public let version: ACPVersion = .v1

    public enum Method {
        public static let initialize = "initialize"
        public static let sessionNew = "session/new"
        public static let sessionLoad = "session/load"
        public static let sessionResume = "session/resume"
        public static let sessionList = "session/list"
        public static let sessionClose = "session/close"
        public static let sessionPrompt = "session/prompt"
        public static let sessionCancel = "session/cancel"
        public static let sessionSetConfigOption = "session/set_config_option"
        public static let sessionUpdate = "session/update"
        public static let requestPermission = "session/request_permission"
        public static let elicitationCreate = "elicitation/create"
        public static let cancelRequest = "$/cancel_request"
    }

    /// Option ids we offer in `session/request_permission`.
    public static let allowOnceId = "allow_once"
    public static let rejectOnceId = "reject_once"
    /// The single field of the form we send in `elicitation/create`.
    public static let answerField = "answer"
    /// Image prompt blocks kept by the adapter (bytes never enter the model).
    public static let maxImagesKept = 64

    private let lock = NSLock()
    private var images: [String: (mimeType: String, base64: String)] = [:]
    private var imageOrder: [String] = []
    private var imageCounter = 0

    public init() {}

    /// The bytes of an image the editor attached, by the handle given in
    /// `ACPContentBlock.image`. Base64 as received.
    public func image(handle: String) -> (mimeType: String, base64: String)? {
        lock.lock(); defer { lock.unlock() }
        return images[handle]
    }

    // MARK: initialize

    public func decodeInitialize(params: JSONValue) -> (client: ACPImplementationInfo?, capabilities: ACPClientCapabilities) {
        var caps = ACPClientCapabilities()
        // Missing or ill-typed capabilities mean "unsupported" (spec:
        // omitted capabilities MUST be treated as unsupported).
        if let c = params["clientCapabilities"] {
            caps.readTextFile = c["fs"]?["readTextFile"]?.boolValue ?? false
            caps.writeTextFile = c["fs"]?["writeTextFile"]?.boolValue ?? false
            caps.terminal = c["terminal"]?.boolValue ?? false
            // Form support exists only when `form` is present and non-null.
            if let form = c["elicitation"]?["form"], form.objectMembers != nil { caps.elicitation = true }
        }
        var info: ACPImplementationInfo?
        if let ci = params["clientInfo"], let name = ci["name"]?.stringValue, let ver = ci["version"]?.stringValue {
            info = ACPImplementationInfo(name: name, version: ver)
        }
        return (info, caps)
    }

    func encodeInitialized(agent: ACPImplementationInfo, capabilities c: ACPAgentCapabilities) -> JSONValue {
        var session: [(String, JSONValue)] = []
        if c.listSessions { session.append(("list", .obj([]))) }
        if c.closeSessions { session.append(("close", .obj([]))) }
        // Both v1 ways back into a session: `session/load` (replays history)
        // and `session/resume` (no replay) map to `resumeSessions`.
        if c.resumeSessions { session.append(("resume", .obj([]))) }
        return .obj([
            ("protocolVersion", .int(1)),
            ("agentCapabilities", .obj([
                ("loadSession", .bool(c.resumeSessions)),
                ("promptCapabilities", .obj([
                    ("image", .bool(c.promptImages)),
                    ("audio", .bool(false)),
                    ("embeddedContext", .bool(c.promptEmbeddedContext)),
                ])),
                // We never connect to editor-provided MCP servers.
                ("mcpCapabilities", .obj([("http", .bool(false)), ("sse", .bool(false))])),
                ("sessionCapabilities", .obj(session)),
            ])),
            ("authMethods", .array([])),
            ("agentInfo", .obj([("name", .string(agent.name)), ("version", .string(agent.version))])),
        ])
    }

    // MARK: editor → agent

    private func invalidParams(_ m: String) -> ACPJsonRpcError {
        ACPJsonRpcError(code: ACPJsonRpcErrorCode.invalidParams, message: m)
    }
    private func notFound(_ method: String) -> ACPJsonRpcError {
        ACPJsonRpcError(code: ACPJsonRpcErrorCode.methodNotFound, message: "method not found: \(method)")
    }

    private func sessionId(_ p: JSONValue) -> String? {
        guard let s = p["sessionId"]?.stringValue, !s.isEmpty, s.utf8.count <= 512 else { return nil }
        return s
    }

    public func decodeRequest(method: String, params: JSONValue?,
                              advertised: ACPAgentCapabilities) -> Result<ACPIncoming, ACPJsonRpcError> {
        let known: Set<String> = [Method.sessionNew, Method.sessionLoad, Method.sessionResume, Method.sessionList,
                                  Method.sessionClose, Method.sessionPrompt, Method.sessionSetConfigOption]
        guard known.contains(method) else { return .failure(notFound(method)) }
        // Methods gated by a capability we did not advertise do not exist.
        if (method == Method.sessionLoad || method == Method.sessionResume) && !advertised.resumeSessions {
            return .failure(notFound(method))
        }
        if method == Method.sessionList && !advertised.listSessions { return .failure(notFound(method)) }
        if method == Method.sessionClose && !advertised.closeSessions { return .failure(notFound(method)) }

        let p = params ?? .obj([])
        guard p.objectMembers != nil else { return .failure(invalidParams("params must be an object")) }

        switch method {
        case Method.sessionNew:
            guard let cwd = p["cwd"]?.stringValue, cwd.hasPrefix("/") else {
                return .failure(invalidParams("session/new needs an absolute cwd"))
            }
            return .success(.newSession(cwd: cwd))
        case Method.sessionLoad, Method.sessionResume:
            // Both require sessionId and an absolute cwd in v1.
            guard let sid = sessionId(p) else { return .failure(invalidParams("\(method) needs sessionId")) }
            guard let cwd = p["cwd"]?.stringValue, cwd.hasPrefix("/") else {
                return .failure(invalidParams("\(method) needs an absolute cwd"))
            }
            return .success(.resumeSession(sessionId: sid, cwd: cwd, replay: method == Method.sessionLoad))
        case Method.sessionList:
            if let c = p["cursor"], !c.isNull {
                // We never hand out cursors, so any cursor is invalid.
                return .failure(invalidParams("unknown cursor"))
            }
            var cwd: String?
            if let c = p["cwd"], !c.isNull {
                guard let path = c.stringValue, path.hasPrefix("/") else {
                    return .failure(invalidParams("session/list cwd must be an absolute path"))
                }
                cwd = path
            }
            return .success(.listSessions(cwd: cwd))
        case Method.sessionClose:
            guard let sid = sessionId(p) else { return .failure(invalidParams("session/close needs sessionId")) }
            return .success(.closeSession(sessionId: sid))
        case Method.sessionPrompt:
            guard let sid = sessionId(p) else { return .failure(invalidParams("session/prompt needs sessionId")) }
            guard let blocks = p["prompt"]?.arrayValue else {
                return .failure(invalidParams("session/prompt needs a prompt array"))
            }
            var content: [ACPContentBlock] = []
            for (i, b) in blocks.enumerated() {
                switch decodeBlock(b, advertised: advertised) {
                case let .success(block): content.append(block)
                case let .failure(msg): return .failure(invalidParams("prompt[\(i)]: \(msg)"))
                }
            }
            return .success(.prompt(sessionId: sid, content: content))
        case Method.sessionSetConfigOption:
            guard let sid = sessionId(p) else {
                return .failure(invalidParams("session/set_config_option needs sessionId"))
            }
            guard let configId = p["configId"]?.stringValue else {
                return .failure(invalidParams("session/set_config_option needs configId"))
            }
            // Only select options exist here; boolean options are never offered.
            guard p["type"] == nil || p["type"]?.isNull == true, let value = p["value"]?.stringValue else {
                return .failure(invalidParams("only select config options are supported"))
            }
            return .success(.setConfigOption(sessionId: sid, optionId: configId, value: value))
        default:
            return .failure(notFound(method))
        }
    }

    private enum BlockResult { case success(ACPContentBlock), failure(String) }

    private func decodeBlock(_ b: JSONValue, advertised: ACPAgentCapabilities) -> BlockResult {
        guard let type = b["type"]?.stringValue else { return .failure("content block needs a type") }
        switch type {
        case "text":
            guard let t = b["text"]?.stringValue else { return .failure("text block needs text") }
            return .success(.text(t))
        case "resource_link":
            guard let uri = b["uri"]?.stringValue, b["name"]?.stringValue != nil else {
                return .failure("resource_link needs uri and name")
            }
            return .success(.resource(uri: uri, mimeType: b["mimeType"]?.stringValue, text: nil))
        case "image":
            guard advertised.promptImages else { return .failure("image content is not supported") }
            guard let data = b["data"]?.stringValue, let mime = b["mimeType"]?.stringValue else {
                return .failure("image block needs data and mimeType")
            }
            return .success(.image(mimeType: mime, handle: keepImage(mime: mime, base64: data)))
        case "resource":
            guard advertised.promptEmbeddedContext else { return .failure("embedded resources are not supported") }
            guard let r = b["resource"], let uri = r["uri"]?.stringValue else {
                return .failure("resource block needs resource.uri")
            }
            // Text contents are kept; blob contents are not passed on.
            return .success(.resource(uri: uri, mimeType: r["mimeType"]?.stringValue, text: r["text"]?.stringValue))
        default:
            return .failure("\(type) content is not supported")
        }
    }

    private func keepImage(mime: String, base64: String) -> String {
        lock.lock(); defer { lock.unlock() }
        imageCounter += 1
        let handle = "acp-image-\(imageCounter)"
        images[handle] = (mime, base64)
        imageOrder.append(handle)
        while imageOrder.count > Self.maxImagesKept {
            images[imageOrder.removeFirst()] = nil
        }
        return handle
    }


    public func decodeNotification(method: String, params: JSONValue?) -> ACPIncoming? {
        guard method == Method.sessionCancel, let p = params, let sid = sessionId(p) else { return nil }
        return .cancel(sessionId: sid)
    }

    public func didReply(_ reply: ACPReply, method: String, requestParams: JSONValue?) {
        // v1 keeps no per-connection wire facts: cwd comes from the model.
    }

    // MARK: agent → editor replies

    public func encodeReply(_ reply: ACPReply, method: String) -> Result<JSONValue, ACPJsonRpcError> {
        func mismatch() -> Result<JSONValue, ACPJsonRpcError> {
            .failure(ACPJsonRpcError(code: ACPJsonRpcErrorCode.internalError,
                                     message: "internal error: reply does not fit \(method)"))
        }
        switch (reply, method) {
        case let (.initialized(v, agent, caps), Method.initialize):
            guard v == .v1 else { return mismatch() }
            return .success(encodeInitialized(agent: agent, capabilities: caps))
        case let (.sessionCreated(sid, options), Method.sessionNew):
            return .success(.obj([("sessionId", .string(sid)), ("configOptions", encodeOptions(options))]))
        case let (.sessions(list), Method.sessionList):
            let items: [JSONValue] = list.map { s in
                .obj([("sessionId", .string(s.sessionId)),
                      ("cwd", .string(s.cwd)),
                      ("title", .string(s.title)),
                      ("updatedAt", .string(s.updatedAt))])
            }
            return .success(.obj([("sessions", .array(items))]))
        case let (.resumed(options), Method.sessionLoad), let (.resumed(options), Method.sessionResume):
            return .success(.obj([("configOptions", encodeOptions(options))]))
        case (.closed, Method.sessionClose):
            return .success(.obj([]))
        case let (.promptFinished(reason), Method.sessionPrompt):
            return .success(.obj([("stopReason", .string(reason.rawValue))]))
        case let (.configSet(options), Method.sessionSetConfigOption):
            return .success(.obj([("configOptions", encodeOptions(options))]))
        case let (.error(e), _):
            return .failure(ACPJsonRpcError(code: e.code, message: e.message,
                                            data: .obj([("reason", .string(e.reason))])))
        default:
            return mismatch()
        }
    }

    func encodeOptions(_ options: [ACPConfigOption]) -> JSONValue {
        .array(options.map { o in
            var m: [(String, JSONValue)] = [("id", .string(o.id)), ("name", .string(o.name))]
            if o.id == "mode" { m.append(("category", .string("mode"))) }
            m.append(("type", .string("select")))
            m.append(("currentValue", .string(o.value)))
            m.append(("options", .array(o.choices.map { .obj([("value", .string($0)), ("name", .string($0))]) })))
            return .obj(m)
        })
    }

    // MARK: session/update

    public func encodeUpdate(sessionId: String, _ update: ACPSessionUpdate) -> (method: String, params: JSONValue)? {
        let body: JSONValue
        switch update {
        case let .userMessage(text):
            body = .obj([("sessionUpdate", .string("user_message_chunk")), ("content", textBlock(text))])
        case let .agentMessage(text):
            body = .obj([("sessionUpdate", .string("agent_message_chunk")), ("content", textBlock(text))])
        case let .agentThought(text):
            body = .obj([("sessionUpdate", .string("agent_thought_chunk")), ("content", textBlock(text))])
        case let .plan(entries):
            body = .obj([("sessionUpdate", .string("plan")),
                         ("entries", .array(entries.map {
                             // v1 requires a priority; the model has none.
                             .obj([("content", .string($0.content)), ("priority", .string("medium")),
                                   ("status", .string($0.status.rawValue))])
                         }))])
        case let .toolCall(call):
            body = encodeToolCall(call, tag: "tool_call")
        case let .toolCallUpdate(call):
            body = encodeToolCall(call, tag: "tool_call_update")
        case let .availableCommands(cmds):
            body = .obj([("sessionUpdate", .string("available_commands_update")),
                         ("availableCommands", .array(cmds.map { c in
                             var m: [(String, JSONValue)] = [("name", .string(c.name)),
                                                             ("description", .string(c.description))]
                             if let hint = c.inputHint { m.append(("input", .obj([("hint", .string(hint))]))) }
                             return .obj(m)
                         }))])
        case let .configOptions(options):
            body = .obj([("sessionUpdate", .string("config_option_update")), ("configOptions", encodeOptions(options))])
        case let .sessionInfo(title):
            body = .obj([("sessionUpdate", .string("session_info_update")), ("title", .string(title))])
        case .usage:
            // v1 `usage_update` is context-window occupancy (used/size), not
            // token counts per turn; nothing honest to send.
            return nil
        case .turnEnded:
            // v1 ends a turn with the `session/prompt` response.
            return nil
        }
        return (Method.sessionUpdate, .obj([("sessionId", .string(sessionId)), ("update", body)]))
    }

    private func textBlock(_ t: String) -> JSONValue { .obj([("type", .string("text")), ("text", .string(t))]) }

    static func levelName(_ l: ACPActionLevel) -> String {
        switch l {
        case .accepted: return "accepted"
        case .dispatched: return "dispatched"
        case .executed: return "executed"
        case .verified: return "verified"
        case .contradicted: return "contradicted"
        case .unknown: return "unknown"
        case let .refused(code): return "refused:\(code)"
        case let .failed(code): return "failed:\(code)"
        }
    }

    /// Wire status of an action whose Run ended with its outcome unknown
    /// (docs/acp/README.md §7, P2). ACP v1 has no neutral terminal status:
    /// `completed` means success and `failed` means an error. `failed` is
    /// chosen so nobody reads it as success; the title and `rawOutput` say
    /// "terminated, outcome unknown". Switch here to `.completed` if Kevin
    /// prefers; nothing else changes.
    public static let terminalUnknownStatus: ACPToolStatus = .failed

    /// `rawOutput` for an unknown outcome: terminated when the action is
    /// over, otherwise only the outcome. Nil for every other level.
    static func unknownOutcome(_ call: ACPToolCall) -> (status: ACPToolStatus, rawOutput: JSONValue)? {
        guard call.level == .unknown else { return nil }
        switch call.status {
        case .failed, .completed:
            return (terminalUnknownStatus,
                    .obj([("execution", .string("terminated")), ("outcome", .string("unknown"))]))
        case .pending, .inProgress:
            return (call.status, .obj([("outcome", .string("unknown"))]))
        }
    }

    private func toolCallFields(_ call: ACPToolCall, lines: [String]) -> [(String, JSONValue)] {
        let unknown = Self.unknownOutcome(call)
        var m: [(String, JSONValue)] = [
            ("toolCallId", .string(call.toolCallId)),
            ("title", .string(call.title)),
            ("kind", .string(call.kind.rawValue)),
            ("status", .string((unknown?.status ?? call.status).rawValue)),
            ("content", .array(lines.map { .obj([("type", .string("content")), ("content", textBlock($0))]) })),
        ]
        if let raw = unknown?.rawOutput { m.append(("rawOutput", raw)) }
        if let level = call.level {
            m.append(("_meta", .obj([("agentdesktop", .obj([("actionLevel", .string(Self.levelName(level)))]))])))
        }
        return m
    }

    private func encodeToolCall(_ call: ACPToolCall, tag: String) -> JSONValue {
        .obj([("sessionUpdate", .string(tag))] + toolCallFields(call, lines: call.detail))
    }

    // MARK: session/request_permission

    public func encodePermissionRequest(_ r: ACPPermissionRequest) -> (method: String, params: JSONValue) {
        let lines = r.summary.isEmpty ? r.toolCall.detail : r.summary
        let options: [JSONValue] = r.options.map { kind in
            switch kind {
            case .allowOnce:
                return .obj([("optionId", .string(Self.allowOnceId)), ("name", .string("Allow once")),
                             ("kind", .string("allow_once"))])
            case .rejectOnce:
                return .obj([("optionId", .string(Self.rejectOnceId)), ("name", .string("Reject")),
                             ("kind", .string("reject_once"))])
            }
        }
        return (Method.requestPermission, .obj([
            ("sessionId", .string(r.sessionId)),
            ("toolCall", .obj(toolCallFields(r.toolCall, lines: lines))),
            ("options", .array(options)),
        ]))
    }

    public func decodePermissionResult(_ result: JSONValue, request: ACPPermissionRequest) -> ACPPermissionOutcome {
        guard let o = result["outcome"], let tag = o["outcome"]?.stringValue else { return .unavailable }
        switch tag {
        case "cancelled":
            return .cancelled
        case "selected":
            // Only an option we offered counts; anything else is never an allow.
            switch o["optionId"]?.stringValue {
            case Self.allowOnceId? where request.options.contains(.allowOnce): return .selected(.allowOnce)
            case Self.rejectOnceId? where request.options.contains(.rejectOnce): return .selected(.rejectOnce)
            default: return .unavailable
            }
        default:
            return .unavailable
        }
    }

    // MARK: elicitation/create (form mode)

    public func encodeQuestion(_ q: ACPQuestion) -> (method: String, params: JSONValue) {
        var field: [(String, JSONValue)] = [("type", .string("string")), ("title", .string("Answer"))]
        if !q.choices.isEmpty {
            field.append(("oneOf", .array(q.choices.map { .obj([("const", .string($0)), ("title", .string($0))]) })))
        }
        return (Method.elicitationCreate, .obj([
            ("sessionId", .string(q.sessionId)),
            ("mode", .string("form")),
            ("message", .string(q.message)),
            ("requestedSchema", .obj([
                ("type", .string("object")),
                ("properties", .obj([(Self.answerField, .obj(field))])),
                ("required", .array([.string(Self.answerField)])),
            ])),
        ]))
    }

    public func decodeAnswer(_ result: JSONValue, question: ACPQuestion) -> ACPAnswer {
        switch result["action"]?.stringValue {
        case "accept"?:
            guard let text = result["content"]?[Self.answerField]?.stringValue else { return .unavailable }
            if !question.choices.isEmpty && !question.choices.contains(text) { return .unavailable }
            return .answered(text)
        case "decline"?, "cancel"?:
            return .declined
        default:
            return .unavailable
        }
    }
}
