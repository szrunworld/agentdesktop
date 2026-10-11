import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

extension CLI {
    /// Events after a cursor; with --follow, keep reading until the Run
    /// ends. Ctrl-C stops reading only; the Run is not touched.
    func runEvents(runId: String, after: Int, follow: Bool, format: OutputFormat, _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            var cursor = after
            var collected: [JSONValue] = []
            while true {
                let page = try client.call(RuntimeRequest(.runEvents, params: .obj([("runId", .string(runId)),
                                                                                    ("after", .int(cursor)), ("limit", .int(200))])))
                let events = page["events"]?.arrayValue ?? []
                for e in events {
                    switch format {
                    case .jsonl: stdout(e.encoded())
                    case .text:
                        stdout("\(e["sequence"]?.intValue ?? 0)  \(e["at"]?.stringValue ?? "")  \(e["type"]?.stringValue ?? "")  \(e["data"]?.encoded() ?? "")")
                    case .json: collected.append(e)
                    }
                }
                cursor = page["next"]?.intValue ?? cursor
                let ended = page["ended"]?.boolValue ?? true
                if !follow || (ended && events.isEmpty) { break }
                if interrupted() { return 130 }
                if events.isEmpty { sleep(0.3) }
            }
            if format == .json {
                out.success(requestId: nil, data: .obj([("events", .array(collected)), ("next", .int(cursor))])) { "" }
            }
            return ExitStatus.ok
        }
    }

    /// events.subscribe on a connection of its own: one line per pushed
    /// event (jsonl: the EventFrame with its cursor). A Run's stream ends
    /// when the Runtime closes it after the Run ended; Ctrl-C ends only the
    /// watch. Text and jsonl only: the stream has no single result.
    func eventsWatch(runId: String?, after: Int?, format: OutputFormat, _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        guard format != .json else {
            let e = RuntimeError.invalidArgument("events watch streams; use --format jsonl or text")
            out.failure(requestId: nil, e)
            return ExitStatus.of(e)
        }
        return withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            let reply = try client.subscribe(runId: runId, after: after)
            if format == .text { stderr("watching from cursor \(reply["next"]?.intValue ?? 0)") }
            while true {
                if interrupted() { return 130 }
                switch try client.nextEvent() {
                case .closed: return ExitStatus.ok
                case .idle: continue
                case let .frame(f):
                    switch format {
                    case .text:
                        let e = f["event"]
                        stdout("\(f["cursor"]?.intValue ?? 0)  \(e?["runId"]?.stringValue ?? "")  \(e?["sequence"]?.intValue ?? 0)  \(e?["at"]?.stringValue ?? "")  \(e?["type"]?.stringValue ?? "")  \(e?["data"]?.encoded() ?? "")")
                    default: stdout(f.encoded())
                    }
                }
            }
        }
    }

    /// Observe a Run until it ends; never cancels it. Timeout → 8 with the
    /// last state seen, and the Run goes on.
    func runWait(runId: String, timeout: Double, _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            let deadline = now().addingTimeInterval(timeout)
            while true {
                let left = max(0, deadline.timeIntervalSince(now()))
                let slice = min(left, 5)
                do {
                    let r = try client.call(RuntimeRequest(.runWait, params: .obj([
                        ("runId", .string(runId)), ("timeoutMs", .int(Int(slice * 1000)))])))
                    out.success(requestId: nil, data: r) { Self.runText(r) }
                    return ExitStatus.ok
                } catch let e as RuntimeError where e.code == "wait_timeout" {
                    if interrupted() { return 130 }
                    if now() >= deadline {
                        out.failure(requestId: nil, RuntimeError("wait_timeout", "\(e.message) after \(TextTable.duration(timeout)); the run continues",
                                                                 phase: .local, details: e.details))
                        return ExitStatus.of(e)
                    }
                }
            }
        }
    }

    /// Start a GUI unit Run and stay on its control connection until it
    /// ends: the Run is Delegated, so leaving earlier would stop it
    /// (owner_lost). Ctrl-C or the timeout cancels it and waits for the
    /// stop. Exit 0 only when its goal was verified.
    func unitRun(params: JSONValue, requestId: String?, timeout: Double, _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            let start = RuntimeRequest(.unitRun, requestId: requestId ?? RuntimeRequest.newId(prefix: "unit"), params: params)
            recordRequest(start.requestId, start.method, endpoint.path)
            let run = try client.call(start)
            let runId = run["runId"]?.stringValue ?? ""
            stderr("unit run \(runId) on desktop \(run["desktopId"]?.stringValue ?? "")")
            let deadline = now().addingTimeInterval(timeout)
            var final: JSONValue?
            var stopped = false
            while final == nil {
                if !stopped, interrupted() || now() >= deadline {
                    stderr(interrupted() ? "stopping unit run \(runId)" : "unit run \(runId) ran past the wait timeout; stopping it")
                    do {
                        _ = try client.call(RuntimeRequest(.runCancel, requestId: RuntimeRequest.newId(prefix: "unit-stop"),
                                                           params: .obj([("runId", .string(runId))])))
                        stopped = true
                    } catch let e as RuntimeError {
                        // Never wait on a stop that was not accepted (codex on
                        // ed056dc). Leaving closes this control connection, which
                        // ends the Delegated Run as owner_lost.
                        stderr("could not stop unit run \(runId) (\(e.code)); closing the connection ends it")
                        out.failure(requestId: start.requestId, e)
                        return interrupted() ? 130 : ExitStatus.of(e)
                    }
                }
                do {
                    final = try client.call(RuntimeRequest(.runWait, params: .obj([("runId", .string(runId)), ("timeoutMs", .int(2000))])))
                } catch let e as RuntimeError where e.code == "wait_timeout" {
                    continue
                }
            }
            let r = final!
            out.success(requestId: start.requestId, data: r) { Self.runText(r) }
            // 0 verified, 7 failed, 9 result unknown, 8 stopped at the wait
            // timeout, 130 stopped by Ctrl-C.
            switch r["outcome"]?.stringValue {
            case "success": return ExitStatus.ok
            case "unknown": return 9
            case "cancelled" where stopped: return interrupted() ? 130 : 8
            default: return 7
            }
        }
    }

    /// Accept the cancel; with --wait, observe until no input is possible.
    /// The same --request-id repeats the cancel without cancelling twice.
    func runCancel(runId: String, requestId: String?, wait: Bool, timeout: Double, _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            let request = RuntimeRequest(.runCancel, requestId: requestId ?? RuntimeRequest.newId(prefix: "cancel"),
                                         params: .obj([("runId", .string(runId))]))
            recordRequest(request.requestId, request.method, endpoint.path)
            var receipt: JSONValue
            do {
                receipt = try client.call(request)
            } catch var e as RuntimeError {
                if e.code == "connection_lost" {
                    e = RuntimeError("cancel_acceptance_unknown",
                                     "\(e.message); repeat with --request-id \(request.requestId) to learn whether it was accepted",
                                     phase: .transport, details: .obj([("requestId", .string(request.requestId))]))
                }
                out.failure(requestId: request.requestId, e)
                return ExitStatus.of(e)
            }
            if wait {
                // Current state, never the cached accept receipt.
                let deadline = now().addingTimeInterval(timeout)
                while true {
                    let left = max(0, deadline.timeIntervalSince(now()))
                    do {
                        let r = try client.call(RuntimeRequest(.runWait, params: .obj([
                            ("runId", .string(runId)), ("timeoutMs", .int(Int(min(left, 5) * 1000)))])))
                        receipt = receipt.setting("execution", .obj([("phase", r["phase"] ?? .null), ("quiescence", r["quiescence"] ?? .null),
                                                                     ("outcome", r["outcome"] ?? .null), ("revision", r["revision"] ?? .null)]))
                        break
                    } catch let e as RuntimeError where e.code == "wait_timeout" {
                        if now() >= deadline || interrupted() {
                            out.failure(requestId: request.requestId, RuntimeError(
                                "wait_timeout", "the cancel is accepted but input is not yet confirmed stopped; the run stays cancelling",
                                phase: .local, details: .obj([("cancelRequest", receipt["cancelRequest"] ?? .null), ("last", e.details ?? .null)])))
                            return interrupted() ? 130 : ExitStatus.of(e)
                        }
                    }
                }
            }
            let shown = receipt
            out.success(requestId: request.requestId, data: shown) {
                let ex = shown["execution"]
                return "stop accepted for \(runId)\(shown["alreadyTerminal"]?.boolValue == true ? " (already ended)" : "")"
                    + "  phase \(ex?["phase"]?.stringValue ?? "?")  quiescence \(ex?["quiescence"]?.stringValue ?? "?")"
                    + (ex?["outcome"]?.stringValue.map { "  outcome \($0)" } ?? "")
            }
            return ExitStatus.ok
        }
    }

    /// Own a Run while a child program acts in it. The child's agentdesktop
    /// commands find the Session and Run through AGENTDESKTOP_CONTEXT and
    /// join with its token. This process's connection is the owner: if it
    /// goes away, the Run takes no more input.
    func sessionExec(desktopId: String?, sessionId: String?, argv: [String], _ out: ResultWriter, endpoint: Endpoint) -> Int32 {
        withClient(out, endpoint: endpoint) { client in
            _ = try client.handshake()
            var session = sessionId ?? ""
            var opened = false
            if session.isEmpty, let desktopId {
                let s = try client.call(RuntimeRequest(.sessionOpen, requestId: RuntimeRequest.newId(prefix: "exec-open"),
                                                       params: .obj([("desktopId", .string(desktopId))])))
                session = s["sessionId"]?.stringValue ?? ""
                opened = true
            }
            defer {
                if opened {
                    _ = try? client.call(RuntimeRequest(.sessionClose, requestId: RuntimeRequest.newId(prefix: "exec-close"),
                                                        params: .obj([("sessionId", .string(session))])))
                }
            }
            var start = RuntimeRequest(.runStart)
            start.context = RequestContext(sessionId: session)
            let started = try client.call(start)
            let run = started["run"] ?? .obj([])
            let runId = run["runId"]?.stringValue ?? ""
            let ctx = ExecContext(endpoint: endpoint.path, desktopId: run["desktopId"]?.stringValue ?? "",
                                  sessionId: session, runId: runId, token: started["attachToken"]?.stringValue ?? "")
            let file = try ctx.write(directory: NSTemporaryDirectory().hasSuffix("/") ? String(NSTemporaryDirectory().dropLast()) : NSTemporaryDirectory())
            defer { unlink(file) }
            stderr("run \(runId) on desktop \(ctx.desktopId), session \(session)")

            var env = environment
            env[ExecContext.environmentKey] = file
            env[EndpointResolver.environmentKey] = endpoint.path
            let status = spawnChild(argv, env)

            let wasInterrupted = interrupted()
            let final: JSONValue
            if wasInterrupted {
                _ = try? client.call(RuntimeRequest(.runCancel, params: .obj([("runId", .string(runId))])))
                final = (try? client.call(RuntimeRequest(.runWait, params: .obj([("runId", .string(runId)), ("timeoutMs", .int(10000))])))) ?? run
            } else {
                do {
                    final = try client.call(RuntimeRequest(.runFinish, requestId: RuntimeRequest.newId(prefix: "exec-finish"),
                                                           params: .obj([("runId", .string(runId)), ("exitCode", .int(Int(status)))])))
                } catch let e as RuntimeError where Self.accessLost.contains(e.code) {
                    // The owner revoked or narrowed this app meanwhile: the
                    // Runtime stopped the Run; say so instead of a stale state.
                    stderr("run \(runId) was stopped by the Runtime: \(e.code); child exit \(status)")
                    out.failure(requestId: nil, e)
                    return ExitStatus.of(e)
                } catch {
                    final = run
                }
            }
            out.success(requestId: nil, data: .obj([("run", final), ("exitCode", .int(Int(status)))])) {
                Self.runText(final) + "\nchild exit \(status)"
            }
            return wasInterrupted ? 130 : status
        }
    }

    /// Errors meaning this caller lost its access (A4).
    static let accessLost: Set<String> = ["client_revoked", "grant_expired", "grant_missing", "pairing_required", "permission_denied"]

    static func runChild(_ argv: [String], _ environment: [String: String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.environment = environment
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    }
}
