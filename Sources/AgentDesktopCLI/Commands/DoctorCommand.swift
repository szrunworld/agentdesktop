import AgentDesktopClient
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

        // Read only: no lock taken, nothing repaired, removed or started,
        // no Run created (EndpointInspector). A connection that answers is
        // not trusted for that alone.
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let report = EndpointInspector.inspect(endpoint, home: home, makeClient: makeClient, signer: peerSigner)
        let place = ["product": "the installed product's endpoint", "side_instance": "a side instance's endpoint",
                     "custom": "a custom endpoint"][report.environment.rawValue]!
        checks.append(Check(id: "endpoint.environment", status: .ok,
                            message: "\(endpoint.path): \(place) [from \(endpoint.source.rawValue)]"))
        switch report.socket {
        case .ok:
            checks.append(Check(id: "endpoint.socket", status: .ok, message: "a socket of this user, mode \(Self.octal(report.socketMode))"))
        case .missing:
            checks.append(Check(id: "endpoint.socket", status: .fail, message: "nothing is listening: \(endpoint.path) does not exist",
                                code: "runtime_offline"))
        case .notSocket:
            checks.append(Check(id: "endpoint.socket", status: .fail, message: "\(endpoint.path) is not a socket", code: "runtime_offline"))
        case .otherOwner:
            checks.append(Check(id: "endpoint.socket", status: .fail, message: "\(endpoint.path) belongs to another user",
                                code: "permission_denied"))
        case .tooOpen:
            checks.append(Check(id: "endpoint.socket", status: .fail,
                                message: "\(endpoint.path) is open to other users (mode \(Self.octal(report.socketMode))); not connecting",
                                code: "permission_denied"))
        }
        if let mode = report.directoryMode, mode & 0o022 != 0 {
            // Others could put their own socket in its place.
            checks.append(Check(id: "endpoint.directory", status: .fail,
                                message: "others may write the endpoint's directory (mode \(Self.octal(mode))); nothing was sent to what listens there",
                                code: "permission_denied"))
        } else if let mode = report.directoryMode, mode & 0o055 != 0 {
            checks.append(Check(id: "endpoint.directory", status: .warn,
                                message: "others may read the endpoint's directory (mode \(Self.octal(mode)))"))
        }
        checks.append(Self.holderCheck(report))

        if report.socket == .ok {
            if let e = report.handshakeError {
                checks.append(Check(id: "handshake", status: .fail, message: e.message, code: e.code))
            } else if let connectError = report.connectError {
                checks.append(Check(id: "handshake", status: .fail, message: "cannot connect: \(connectError)", code: "runtime_offline"))
            } else if let id = report.handshake {
                identity = id
                checks.append(Check(id: "handshake", status: .ok,
                                    message: "\(id.product) \(id.productVersion) pid \(id.pid), \(id.apiVersion), build \(id.buildSource)"))
                checks.append(id.productVersion == RuntimeAPI.productVersion
                    ? Check(id: "version", status: .ok, message: "CLI and Runtime are both \(id.productVersion); contract \(id.apiVersion)")
                    : Check(id: "version", status: .warn,
                            message: "CLI \(RuntimeAPI.productVersion), Runtime \(id.productVersion); both speak \(id.apiVersion)"))
            }
            switch report.identity {
            case .verified:
                checks.append(Check(id: "identity", status: .ok,
                                    message: "verified: the socket's peer, the handshake and the lock file name the same process, signed as this product"))
            case .unverified:
                checks.append(Check(id: "identity", status: .warn,
                                    message: "unverified: " + report.identityNotes.joined(separator: "; ")))
            case .mismatch:
                checks.append(Check(id: "identity", status: .fail,
                                    message: "mismatch: " + report.identityNotes.joined(separator: "; "), code: "instance_mismatch"))
            }
            if identity != nil {
                checks.append(Check(id: "authentication", status: .skip,
                                    message: "this Runtime treats every connection of this user as the owner (by socket ownership); it does not report the caller's identity yet"))
                if report.runsAvailable == true {
                    checks.append(Check(id: "runs", status: .ok, message: "the Run service answers (run.list; nothing was created)"))
                } else if let e = report.runsError, e.code == "capability_missing" {
                    // A Runtime without a desktop platform offers no Runs: a fact, not a fault.
                    checks.append(Check(id: "runs", status: .warn, message: "this Runtime offers no Run service: \(e.message)"))
                } else if let e = report.runsError {
                    let kind = report.failures.contains(.authorization) ? "not authorised" : "not available"
                    checks.append(Check(id: "runs", status: .fail, message: "the Run service is \(kind): \(e.message)", code: e.code))
                }
            }
        }
        if let context = environment[ExecContext.environmentKey], !context.isEmpty {
            // Its token is never shown.
            checks.append(Check(id: "exec.context", status: .ok, message: "inside session exec; context file \(context)"))
        }

        // Permissions as the Runtime reports them, asked on the inspector's
        // own connection, and only of one whose identity is not contradicted.
        if let caps = report.capabilities {
            let p = caps["backend"]?["permissions"]
            let trusted = report.identity == .verified
            for (key, name) in [("screenRecording", "Screen Recording"), ("accessibility", "Accessibility")] {
                let state = p?[key]?.stringValue ?? "unknown"
                let said = trusted ? "" : " (as an unverified Runtime reports it)"
                checks.append(state == "granted"
                    ? Check(id: "permission.\(key)", status: trusted ? .ok : .warn, message: "\(name) granted to the Runtime" + said)
                    : Check(id: "permission.\(key)", status: .fail,
                            message: "\(name) is \(state) for the Runtime" + said + "; grant it to Agent Desktop in System Settings › Privacy & Security",
                            code: "permission_denied"))
            }
        } else {
            checks.append(Check(id: "permissions", status: .skip,
                                message: report.identity == .mismatch ? "not asked: the Runtime's identity is contradicted" : "needs a Runtime to ask"))
        }

        let firstFailure = checks.first { $0.status == .fail }
        var data: [(String, JSONValue)] = [
            ("healthy", .bool(firstFailure == nil)),
            ("endpoint", .obj([("path", .string(endpoint.path)), ("source", .string(endpoint.source.rawValue))])),
            ("checks", .array(checks.map(\.json))),
        ]
        if let identity { data.append(("identity", identity.json)) }
        var diagnosis: [(String, JSONValue)] = [
            ("environment", .string(report.environment.rawValue)), ("socket", .string(report.socket.rawValue)),
            ("holder", .string(report.holder.rawValue)), ("identity", .string(report.identity.rawValue)),
            ("identityNotes", .array(report.identityNotes.map(JSONValue.string))),
            ("failures", .array(report.failures.map { .string($0.rawValue) })),
        ]
        if let r = report.record { diagnosis.append(("record", r.json)) }
        if let p = report.peerPID { diagnosis.append(("peerPid", .int(Int(p)))) }
        if let a = report.runsAvailable { diagnosis.append(("runsAvailable", .bool(a))) }
        data.append(("diagnosis", .obj(diagnosis)))
        out.success(requestId: nil, data: .obj(data)) {
            checks.map { c in
                let mark = ["ok": "ok  ", "warn": "warn", "fail": "FAIL", "skip": "skip"][c.status.rawValue]!
                return "\(mark)  \(c.id.padding(toLength: max(28, c.id.count + 2), withPad: " ", startingAt: 0))\(c.message)"
            }.joined(separator: "\n")
        }
        guard let firstFailure else { return ExitStatus.ok }
        return ExitStatus.of(RuntimeError(firstFailure.code ?? "internal_error", firstFailure.message, phase: .local))
    }

    static func octal(_ mode: UInt16?) -> String { mode.map { String($0, radix: 8) } ?? "unknown" }

    /// The lock file's record, as a clue only.
    static func holderCheck(_ r: EndpointInspector.Report) -> Check {
        let lock = "\(r.path).lock"
        switch r.holder {
        case .none:
            return Check(id: "endpoint.owner", status: r.socket == .ok ? .warn : .skip, message: "no lock file at \(lock)")
        case .unknown:
            return Check(id: "endpoint.owner", status: .warn, message: "\(lock) holds no readable record")
        case .legacy:
            return Check(id: "endpoint.owner", status: .warn,
                         message: "\(lock) names only pid \(r.legacyPID ?? 0) (a Runtime from before ownership records)")
        case .alive:
            let rec = r.record!
            return Check(id: "endpoint.owner", status: .ok,
                         message: "recorded owner: \(rec.product) \(rec.productVersion) pid \(rec.pid) since \(rec.since)"
                             + (rec.listening ? ", listening" : ", not listening yet") + " (a record, not proof)")
        case .gone:
            return Check(id: "endpoint.owner", status: .warn,
                         message: "the recorded owner, pid \(r.record?.pid ?? r.legacyPID ?? 0), is gone: a leftover the next Runtime replaces when it starts (nothing changed here)")
        case .pidReused:
            return Check(id: "endpoint.owner", status: .warn,
                         message: "pid \(r.record?.pid ?? 0) now belongs to a process that started after the record: the recorded owner is gone")
        }
    }
}
