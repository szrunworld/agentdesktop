import AgentDesktopClient
import AgentDesktopProtocol
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `agentdesktop mcp`: an MCP server on stdio (newline-delimited JSON-RPC).
///
/// It is an adapter, not a controller: every tool is one runtime/1
/// request through `RuntimeClient`. The MCP session holds one Runtime
/// connection; the short Runs its act tools start are owned by it, so
/// when the MCP client goes away, nothing it started can send more input.
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    /// Long side of images returned to the MCP client.
    public static let maxImageSide = 1280.0

    private let makeClient: () -> RuntimeClient
    private var client: RuntimeClient?
    /// Snapshot → factor from returned-image pixels to snapshot pixels.
    private var imageScale: [String: Double] = [:]
    /// `agentdesktop mcp --desktop-id`: the one Desktop this server may
    /// reach. Any other desktopId in a tool's arguments, and any session,
    /// Run or request of another Desktop, is refused before it is used.
    /// nil: no limit beyond the Runtime's own grant.
    public let desktopScope: String?
    /// Session → its Desktop, learned from session_open or session.show.
    private var sessionDesktop: [String: String] = [:]

    public init(desktopScope: String? = nil, makeClient: @escaping () -> RuntimeClient) {
        self.desktopScope = desktopScope
        self.makeClient = makeClient
    }

    var tools: [MCPTools.Tool] { desktopScope.map(MCPTools.scoped(to:)) ?? MCPTools.all }

    /// Serve until `readLine` returns nil (stdin closed).
    public func serve(readLine: () -> String?, write: (String) -> Void) {
        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line: line) { write(reply.encoded()) }
        }
        client?.close()
    }

    func handle(line: String) -> JSONValue? {
        guard let msg = try? StrictJSON.parse(line) else {
            return Self.error(id: .null, code: -32700, "parse error")
        }
        let id = msg["id"]
        guard let method = msg["method"]?.stringValue else {
            return id == nil ? nil : Self.error(id: id!, code: -32600, "invalid request")
        }
        // Notifications get no reply.
        guard let id else { return nil }
        let params = msg["params"] ?? .obj([])
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? Self.protocolVersion
            let version = Self.supportedVersions.contains(asked) ? asked : Self.protocolVersion
            return Self.result(id: id, .obj([
                ("protocolVersion", .string(version)),
                ("capabilities", .obj([("tools", .obj([("listChanged", .bool(false))]))])),
                ("serverInfo", .obj([("name", .string("agentdesktop")), ("version", .string(RuntimeAPI.productVersion))])),
                ("instructions", .string("""
                    AgentDesktop gives you private Desktops: virtual screens the user does not see, so apps you drive there \
                    never take the user's screen, pointer or focus. Typical flow: desktop_create → app_launch → window_bind → \
                    session_open → observe → act_* (with the snapshotId and element ids from observe) → observe again to check. \
                    Every act is checked against its snapshot and refused without input if the target changed; observe again then. \
                    After an unclear failure of a write, call request_show with its requestId instead of acting again.
                    """ + (desktopScope.map { d in
                        "\nThis server is limited to Desktop \(d): tools use it when desktopId is omitted, refuse any other desktopId, " +
                        "and observe and wait_for_element work on it without a session. It cannot create Desktops."
                    } ?? ""))),
            ]))
        case "ping":
            return Self.result(id: id, .obj([]))
        case "tools/list":
            return Self.result(id: id, .obj([("tools", .array(tools.map { t in
                .obj([("name", .string(t.name)), ("description", .string(t.description)), ("inputSchema", t.schema)])
            }))]))
        case "tools/call":
            // A tool the scoped list leaves out is still known: calling it is
            // a tool error that says why, not an unknown method.
            guard let name = params["name"]?.stringValue, let tool = MCPTools.byName[name] else {
                return Self.error(id: id, code: -32602, "unknown tool \(params["name"]?.stringValue ?? "")")
            }
            return Self.result(id: id, call(tool, params["arguments"] ?? .obj([])))
        default:
            return Self.error(id: id, code: -32601, "method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ r: JSONValue) -> JSONValue {
        .obj([("jsonrpc", .string("2.0")), ("id", id), ("result", r)])
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        .obj([("jsonrpc", .string("2.0")), ("id", id), ("error", .obj([("code", .int(code)), ("message", .string(message))]))])
    }

    static func toolError(_ e: RuntimeError) -> JSONValue {
        var text = "\(e.code): \(e.message)"
        if e.notSent == true { text += "\n(no input was sent)" }
        if let d = e.details { text += "\n" + d.encoded() }
        return .obj([("content", .array([.obj([("type", .string("text")), ("text", .string(text))])])), ("isError", .bool(true))])
    }

    /// One tool call: arguments → runtime/1 request → MCP content.
    func call(_ tool: MCPTools.Tool, _ args: JSONValue) -> JSONValue {
        do {
            var args = args
            if let scope = desktopScope { args = try Self.scoped(tool, args, to: scope) }
            let request = try Self.request(tool, args, imageScale: imageScale, desktopScope: desktopScope)
            let c = client ?? makeClient()
            client = c
            _ = try c.handshake()
            if let scope = desktopScope { try checkScope(tool, args, scope, using: c) }
            var data: JSONValue
            do {
                data = try c.call(request)
            } catch let e as RuntimeError where e.code == "connection_lost" {
                client?.close()
                client = nil
                if tool.mutation {
                    throw RuntimeError("request_acceptance_unknown",
                                       "\(e.message); check with request_show requestId=\(request.requestId) before acting again",
                                       phase: .transport, details: .obj([("requestId", .string(request.requestId))]))
                }
                throw e
            }
            if let scope = desktopScope {
                data = try Self.limit(tool, data, to: scope)
                if tool.name == "session_open", let sid = data["sessionId"]?.stringValue {
                    sessionDesktop[sid] = data["desktopId"]?.stringValue ?? scope
                }
            }
            var content: [JSONValue] = []
            var shown = data
            if tool.method == .observe {
                // The image, scaled down for the model; points in it map back.
                if args["includeImage"]?.boolValue ?? true, let image = data["image"], image["artifactId"]?.stringValue != nil,
                   let (bytes, factor) = Self.scaled(try readImage(image, using: c), maxSide: Self.maxImageSide),
                   let snap = data["snapshotId"]?.stringValue {
                    imageScale[snap] = factor
                    content.append(.obj([("type", .string("image")), ("data", .string(bytes.base64EncodedString())),
                                         ("mimeType", .string("image/png"))]))
                    shown = shown.setting("imageForYou", .obj([
                        ("note", .string("x,y for act tools are pixels of the returned image")),
                        ("scaleToSnapshot", .double(factor))]))
                }
            }
            if tool.mutation { shown = shown.setting("requestId", .string(request.requestId)) }
            content.insert(.obj([("type", .string("text")), ("text", .string(shown.encoded()))]), at: 0)
            return .obj([("content", .array(content)), ("isError", .bool(false))])
        } catch let e as RuntimeError {
            return Self.toolError(e)
        } catch {
            return Self.toolError(RuntimeError("internal_error", "\(error)", phase: .local))
        }
    }

    // MARK: One Desktop (--desktop-id)

    static func outOfScope(_ scope: String, _ what: String) -> RuntimeError {
        RuntimeError("permission_denied", "this MCP server is limited to desktop \(scope); \(what)", phase: .local, notSent: true,
                     details: .obj([("reason", .string("desktop_out_of_scope")), ("desktopId", .string(scope))]))
    }

    /// Before any connection: refuse a tool that makes another Desktop and
    /// any desktopId argument other than the scope; fill an omitted one.
    static func scoped(_ tool: MCPTools.Tool, _ a: JSONValue, to scope: String) throws -> JSONValue {
        if MCPTools.outsideScope.contains(tool.name) {
            throw outOfScope(scope, "\(tool.name) would reach another Desktop")
        }
        if let d = a["desktopId"] {
            guard d.stringValue == scope else {
                throw outOfScope(scope, "desktop \(d.stringValue ?? d.encoded()) is outside it")
            }
            return a
        }
        if tool.schema["properties"]?["desktopId"] != nil { return a.setting("desktopId", .string(scope)) }
        return a
    }

    /// After the handshake, before the request: the session, Run or
    /// request a tool names must be on the scope's Desktop. Looked up
    /// through the Runtime (fail closed: an error of the lookup is the
    /// tool's error).
    func checkScope(_ tool: MCPTools.Tool, _ a: JSONValue, _ scope: String, using c: RuntimeClient) throws {
        if let sid = a["sessionId"]?.stringValue {
            let desktop: String
            if let known = sessionDesktop[sid] {
                desktop = known
            } else {
                let s = try c.call(RuntimeRequest(.sessionShow, params: .obj([("sessionId", .string(sid))])))
                guard let d = s["desktopId"]?.stringValue else {
                    throw RuntimeError("invalid_response", "session.show named no desktop", phase: .local)
                }
                sessionDesktop[sid] = d
                desktop = d
            }
            guard desktop == scope else { throw Self.outOfScope(scope, "session \(sid) is on another Desktop") }
        }
        if let runId = a["runId"]?.stringValue {
            let r = try c.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))
            guard r["desktopId"]?.stringValue == scope else { throw Self.outOfScope(scope, "run \(runId) is on another Desktop") }
        }
    }

    /// What a read returns about other Desktops is left out (desktop_list)
    /// or refused (request_show of another Desktop's request).
    static func limit(_ tool: MCPTools.Tool, _ data: JSONValue, to scope: String) throws -> JSONValue {
        switch tool.name {
        case "desktop_list":
            let mine = (data["desktops"]?.arrayValue ?? []).filter { $0["desktopId"]?.stringValue == scope }
            return data.setting("desktops", .array(mine))
        case "request_show":
            if let d = data["desktopId"]?.stringValue, d != scope {
                throw outOfScope(scope, "request \(data["requestId"]?.stringValue ?? "") was made on another Desktop")
            }
            return data
        default:
            return data
        }
    }

    /// Retrieve screenshots through the authenticated Runtime connection.
    private func readImage(_ image: JSONValue, using client: RuntimeClient) throws -> Data {
        guard let id = image["artifactId"]?.stringValue,
              let size = image["byteSize"]?.intValue, size > 0, size <= 64 * 1024 * 1024 else {
            throw RuntimeError("invalid_response", "invalid screenshot artifact size", phase: .local)
        }
        var bytes = Data()
        while bytes.count < size {
            let chunk = try client.call(RuntimeRequest(.artifactRead, params: .obj([
                ("artifactId", .string(id)), ("offset", .int(bytes.count)),
                ("length", .int(min(524_288, size - bytes.count)))])))
            guard chunk["artifactId"]?.stringValue == id, chunk["offset"]?.intValue == bytes.count,
                  let encoded = chunk["dataBase64"]?.stringValue, let data = Data(base64Encoded: encoded),
                  !data.isEmpty, data.count <= size - bytes.count,
                  chunk["length"]?.intValue == data.count else {
                throw RuntimeError("invalid_response", "invalid screenshot artifact chunk", phase: .local)
            }
            bytes.append(data)
            if chunk["eof"]?.boolValue == true { break }
        }
        guard bytes.count == size else {
            throw RuntimeError("invalid_response", "incomplete screenshot artifact", phase: .local)
        }
        return bytes
    }

    static func request(_ tool: MCPTools.Tool, _ a: JSONValue, imageScale: [String: Double],
                        desktopScope: String? = nil) throws -> RuntimeRequest {
        func s(_ k: String) -> String? { a[k]?.stringValue }
        func need(_ k: String) throws -> String {
            guard let v = s(k), !v.isEmpty else { throw RuntimeError.invalidArgument("\(k) is required") }
            return v
        }
        let id = try s("requestId").map { v -> String in
            guard RuntimeContract.shared.validate(.string(v), "Id").isEmpty else { throw RuntimeError.invalidArgument("requestId has an invalid form") }
            return v
        } ?? RuntimeRequest.newId(prefix: "mcp")
        var r = RuntimeRequest(tool.method, requestId: id)
        var p: [(String, JSONValue)] = []
        func copy(_ keys: [String]) { for k in keys { if let v = a[k] { p.append((k, v)) } } }
        // The session; limited to one Desktop, also that Desktop (the Runtime
        // refuses a session of another), and observe and wait may name
        // the Desktop alone.
        func sessionContext() throws -> RequestContext {
            if let scope = desktopScope {
                return RequestContext(sessionId: s("sessionId").flatMap { $0.isEmpty ? nil : $0 }, desktopId: scope)
            }
            return RequestContext(sessionId: try need("sessionId"))
        }
        func target() throws -> JSONValue? {
            if let e = s("elementRef") { return .obj([("elementRef", .string(e))]) }
            guard let x = a["x"]?.doubleValue, let y = a["y"]?.doubleValue else { return nil }
            let snap = try need("snapshotId")
            let f = imageScale[snap] ?? 1
            return .obj([("imagePoint", .obj([("x", .double((x * f).rounded(.down))), ("y", .double((y * f).rounded(.down)))]))])
        }
        switch tool.name {
        case "desktop_create": copy(["name", "width", "height"])
        case "desktop_destroy", "window_unbind", "session_open": copy(["desktopId"])
        case "app_list": copy(["includeBackground"])
        case "app_launch": copy(["desktopId", "bundleId", "path", "newInstance"])
        case "window_list": copy(["pid", "bundleId", "includeOffscreen"])
        case "window_bind": copy(["desktopId", "pid", "windowId"])
        case "session_close": copy(["sessionId"])
        case "observe":
            r.context = try sessionContext()
            copy(["query", "elements"])
            if a["includeImage"]?.boolValue == false { p.append(("screenshot", .bool(false))) }
        case "act_click", "act_type", "act_key", "act_scroll", "act_press":
            r.context = RequestContext(sessionId: try need("sessionId"), desktopId: desktopScope)
            var action: [(String, JSONValue)] = []
            switch tool.name {
            case "act_click":
                guard let t = try target() else { throw RuntimeError.invalidArgument("give elementRef or x,y") }
                action = [("kind", .string("click")), ("target", t)]
                if let b = s("button") { action.append(("button", .string(b))) }
                if a["double"]?.boolValue == true { action.append(("count", .int(2))) }
            case "act_type":
                action = [("kind", .string("type")), ("text", .string(try need("text")))]
                if let t = try target() { action.append(("target", t)) }
            case "act_key":
                action = [("kind", .string("key")), ("key", .string(try need("key")))]
                if let m = a["modifiers"] { action.append(("modifiers", m)) }
            case "act_press":
                action = [("kind", .string("press")), ("target", .obj([("elementRef", .string(try need("elementRef")))]))]
            default:
                action = [("kind", .string("scroll")), ("direction", .string(try need("direction")))]
                if let t = try target() { action.append(("target", t)) }
                if let n = a["amount"] { action.append(("amount", n)) }
            }
            p = [("snapshotId", .string(try need("snapshotId"))), ("action", .obj(action))]
        case "wait_for_element":
            r.context = try sessionContext()
            var cond: [(String, JSONValue)] = [("kind", .string(a["present"]?.boolValue == false ? "elementAbsent" : "elementPresent"))]
            for k in ["role", "label", "labelContains"] { if let v = a[k] { cond.append((k, v)) } }
            p = [("condition", .obj(cond)), ("timeoutMs", a["timeoutMs"] ?? .int(5000))]
        case "run_show", "run_cancel": copy(["runId"])
        case "request_show": p = [("requestId", .string(try need("requestId")))]
        default: break
        }
        r.params = .obj(p)
        return r
    }

    /// PNG scaled so its long side ≤ maxSide; the factor back to the source.
    static func scaled(_ png: Data, maxSide: Double) -> (Data, Double)? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = Double(image.width), h = Double(image.height)
        let factor = max(w, h) > maxSide ? max(w, h) / maxSide : 1
        if factor == 1 { return (png, 1) }
        let nw = Int((w / factor).rounded()), nh = Int((h / factor).rounded())
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, w / Double(nw))
    }
}
