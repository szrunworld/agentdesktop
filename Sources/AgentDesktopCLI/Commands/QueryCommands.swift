import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

extension CLI {
    /// Read-only commands: one handshake, one request, never a start.
    func query(_ command: RuntimeInvocation.Command, _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        withClient(out, endpoint: endpoint) { client in
            let identity = try client.handshake()
            let request: RuntimeRequest
            switch command {
            case .runtimeStatus: request = RuntimeRequest(.status)
            case .runtimeCapabilities: request = RuntimeRequest(.capabilities)
            case .desktopList: request = RuntimeRequest(.desktopList)
            case let .desktopShow(id): request = RuntimeRequest(.desktopShow, params: .obj([("desktopId", .string(id))]))
            case let .appList(all):
                request = RuntimeRequest(.appList, params: all ? .obj([("includeBackground", .bool(true))]) : .obj([]))
            case let .windowList(pid, bundleId, all):
                var p: [(String, JSONValue)] = []
                if let pid { p.append(("pid", .int(Int(pid)))) }
                if let bundleId { p.append(("bundleId", .string(bundleId))) }
                if all { p.append(("includeOffscreen", .bool(true))) }
                request = RuntimeRequest(.windowList, params: .obj(p))
            default:
                preconditionFailure("not a query: \(command)")
            }
            let data: JSONValue
            do {
                data = try client.call(request)
            } catch let e as RuntimeError {
                out.failure(requestId: request.requestId, e)
                return ExitStatus.of(e)
            }
            if case .runtimeStatus = command {
                // Status with the identity that answered it.
                out.success(requestId: request.requestId, data: .obj([("identity", identity.json), ("status", data)])) {
                    Self.statusText(identity, data)
                }
            } else {
                out.success(requestId: request.requestId, data: data) { Self.text(command, data) }
            }
            return ExitStatus.ok
        }
    }

    static func statusText(_ id: RuntimeIdentity, _ s: JSONValue) -> String {
        func n(_ k: String) -> String { s[k]?.intValue.map(String.init) ?? "?" }
        return [
            "\(id.product) \(id.productVersion)  \(s["state"]?.stringValue ?? "?")  pid \(id.pid)  instance \(id.instanceId)",
            "endpoint     \(id.endpoint)",
            "api          \(id.apiVersion)",
            "build        \(id.buildSource)",
            "uptime       \(TextTable.duration(s["uptimeSeconds"]?.doubleValue ?? 0))",
            "connections  \(n("connections"))   desktops \(n("desktops"))   sessions \(n("sessions"))   runs \(n("runs"))",
        ].joined(separator: "\n")
    }

    static func text(_ command: RuntimeInvocation.Command, _ d: JSONValue) -> String {
        func str(_ v: JSONValue?) -> String { v?.stringValue ?? "-" }
        switch command {
        case .runtimeCapabilities:
            let methods = d["interface"]?["methods"]?.arrayValue ?? []
            let b = d["backend"]
            return ([
                "api          \(str(d["apiVersion"]))",
                "platform     \(str(b?["platform"]?["os"])) \(str(b?["platform"]?["osVersion"])) \(str(b?["platform"]?["arch"]))",
                "permissions  screen recording \(str(b?["permissions"]?["screenRecording"])), accessibility \(str(b?["permissions"]?["accessibility"]))",
                "features     \((b?["features"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))",
                "methods",
            ] + methods.map { m in
                "  \(str(m["method"]))  \(str(m["stage"]))\(m["mutation"]?.boolValue == true ? "  writes" : "")"
            }).joined(separator: "\n")
        case .desktopList:
            let rows = (d["desktops"]?.arrayValue ?? []).map { [str($0["desktopId"]), str($0["name"]), str($0["state"]), str($0["createdAt"])] }
            return rows.isEmpty ? "no desktops" : TextTable.render(["DESKTOP", "NAME", "STATE", "CREATED"], rows)
        case .desktopShow:
            return "\(str(d["desktopId"]))  \(str(d["name"]))  \(str(d["state"]))  created \(str(d["createdAt"]))"
        case .appList:
            let rows = (d["apps"]?.arrayValue ?? []).map { a -> [String] in
                var flags: [String] = []
                if a["active"]?.boolValue == true { flags.append("active") }
                if a["hidden"]?.boolValue == true { flags.append("hidden") }
                return [a["process"]?["pid"]?.intValue.map(String.init) ?? "-", str(a["name"]),
                        a["bundleId"]?.stringValue ?? "-", flags.joined(separator: ",")]
            }
            return rows.isEmpty ? "no apps" : TextTable.render(["PID", "NAME", "BUNDLE", "STATE"], rows)
        case .windowList:
            let rows = (d["windows"]?.arrayValue ?? []).map { w -> [String] in
                let f = w["frame"]
                func i(_ k: String) -> String { f?[k]?.doubleValue.map { String(Int($0)) } ?? "?" }
                return [w["windowId"]?.intValue.map(String.init) ?? "-",
                        w["process"]?["pid"]?.intValue.map(String.init) ?? "-",
                        str(w["appName"]),
                        "\(i("x")),\(i("y")) \(i("width"))x\(i("height"))\(w["onScreen"]?.boolValue == true ? "" : " (off)")",
                        w["title"]?.stringValue ?? "(title withheld)"]
            }
            return rows.isEmpty ? "no windows" : TextTable.render(["WINDOW", "PID", "APP", "FRAME", "TITLE"], rows)
        default:
            return d.encoded()
        }
    }
}
