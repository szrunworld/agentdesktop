import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

extension CLI {
    struct Check {
        enum Status: String { case ok, warn, fail, skip }
        let id: String
        let status: Status
        let message: String
        var code: String?

        var json: JSONValue {
            var m: [(String, JSONValue)] = [("id", .string(id)), ("status", .string(status.rawValue)),
                                            ("message", .string(message))]
            if let code { m.append(("code", .string(code))) }
            return .obj(m)
        }
    }

    /// Read-only diagnosis. Never starts anything. Exit 0 when every check
    /// passes (warnings allowed); otherwise the exit class of the first failure.
    func doctor(_ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        var checks: [Check] = []
        var identity: RuntimeIdentity?
        checks.append(Check(id: "cli", status: .ok,
                            message: "agentdesktop \(RuntimeAPI.productVersion) at \(executablePath)"
                                + (appPath.map { " (in \($0))" } ?? " (not inside an app bundle)")))

        if let refusal = EndpointResolver.inspect(endpoint.path) {
            checks.append(Check(id: "endpoint", status: .fail,
                                message: "\(refusal.message) [from \(endpoint.source.rawValue)]", code: refusal.code))
        } else {
            checks.append(Check(id: "endpoint", status: .ok,
                                message: "\(endpoint.path) is this user's socket [from \(endpoint.source.rawValue)]"))
        }

        let client = makeClient(endpoint)
        defer { client.close() }
        if checks.last?.status == .ok {
            do {
                let id = try client.handshake()
                identity = id
                checks.append(Check(id: "handshake", status: .ok,
                                    message: "\(id.product) \(id.productVersion) pid \(id.pid), \(id.apiVersion), build \(id.buildSource)"))
                checks.append(id.productVersion == RuntimeAPI.productVersion
                    ? Check(id: "version", status: .ok, message: "CLI and Runtime are both \(id.productVersion)")
                    : Check(id: "version", status: .warn,
                            message: "CLI \(RuntimeAPI.productVersion), Runtime \(id.productVersion); both speak \(id.apiVersion)"))
            } catch let e as RuntimeError {
                checks.append(Check(id: "handshake", status: .fail, message: e.message, code: e.code))
            } catch {
                checks.append(Check(id: "handshake", status: .fail, message: "\(error)", code: "internal_error"))
            }
        }

        if identity != nil {
            do {
                let caps = try client.call(RuntimeRequest(.capabilities))
                let p = caps["backend"]?["permissions"]
                for (key, name) in [("screenRecording", "Screen Recording"), ("accessibility", "Accessibility")] {
                    let state = p?[key]?.stringValue ?? "unknown"
                    checks.append(state == "granted"
                        ? Check(id: "permission.\(key)", status: .ok, message: "\(name) granted to the Runtime")
                        : Check(id: "permission.\(key)", status: .fail,
                                message: "\(name) is \(state) for the Runtime; grant it to Agent Desktop in System Settings › Privacy & Security",
                                code: "permission_denied"))
                }
            } catch let e as RuntimeError {
                checks.append(Check(id: "capabilities", status: .fail, message: e.message, code: e.code))
            } catch {}
        } else {
            checks.append(Check(id: "permissions", status: .skip, message: "needs a Runtime to ask"))
        }

        let firstFailure = checks.first { $0.status == .fail }
        var data: [(String, JSONValue)] = [
            ("healthy", .bool(firstFailure == nil)),
            ("endpoint", .obj([("path", .string(endpoint.path)), ("source", .string(endpoint.source.rawValue))])),
            ("checks", .array(checks.map(\.json))),
        ]
        if let identity { data.append(("identity", identity.json)) }
        out.success(requestId: nil, data: .obj(data)) {
            checks.map { c in
                let mark = ["ok": "ok  ", "warn": "warn", "fail": "FAIL", "skip": "skip"][c.status.rawValue]!
                return "\(mark)  \(c.id.padding(toLength: max(28, c.id.count + 2), withPad: " ", startingAt: 0))\(c.message)"
            }.joined(separator: "\n")
        }
        guard let firstFailure else { return ExitStatus.ok }
        return ExitStatus.of(RuntimeError(firstFailure.code ?? "internal_error", firstFailure.message, phase: .local))
    }
}
