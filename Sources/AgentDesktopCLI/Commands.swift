import AgentDesktopContracts
import Foundation

/// The friendly commands of spec §13.1, each a thin mapping onto one
/// contract command. Flags fill params; `--params-file` supplies the params
/// object (never a whole envelope); the same field from both is a local
/// conflict, never a silent override. Secrets come only from stdin.
struct CommandSpec {
    enum Value { case string, int, bool, list, nullableString }
    struct Flag {
        let name: String        // without "--"
        let param: String       // wire field
        let value: Value
    }
    enum Waits { case operation, run }

    let words: [String]
    let command: String
    var flags: [Flag] = []
    /// Fields that must end up in params, from a flag or the params file.
    var required: [String] = []
    /// Fixed params added by the CLI.
    var fixed: [(String, JSONValue)] = []
    var paramsFile: ParamsFile = .none
    var credentialStdin: Bool = false
    var waits: Waits?
    var follows = false

    enum ParamsFile { case none, whole, patch }
}

extension CommandSpec.Flag {
    static func s(_ n: String, _ p: String) -> Self { .init(name: n, param: p, value: .string) }
    static func i(_ n: String, _ p: String) -> Self { .init(name: n, param: p, value: .int) }
}

enum CommandTable {
    static func crud(_ noun: [String], _ base: String, idParam: String) -> [CommandSpec] {
        let id = CommandSpec.Flag.s("id", idParam)
        let rev = CommandSpec.Flag.i("expected-revision", "expectedRevision")
        return [
            CommandSpec(words: noun + ["list"], command: "\(base).list",
                        flags: [.i("limit", "limit"), .s("cursor", "cursor"),
                                .init(name: "include-disabled", param: "includeDisabled", value: .bool)]),
            CommandSpec(words: noun + ["get"], command: "\(base).get", flags: [id], required: [idParam]),
            CommandSpec(words: noun + ["create"], command: "\(base).create", paramsFile: .whole),
            CommandSpec(words: noun + ["update"], command: "\(base).update", flags: [id, rev],
                        required: [idParam, "expectedRevision"], paramsFile: .patch),
            CommandSpec(words: noun + ["disable"], command: "\(base).disable", flags: [id, rev],
                        required: [idParam, "expectedRevision"]),
            CommandSpec(words: noun + ["delete"], command: "\(base).delete", flags: [id, rev],
                        required: [idParam, "expectedRevision"]),
        ]
    }

    static let all: [CommandSpec] = {
        var t = crud(["ai", "connections"], "ai.connections", idParam: "connectionId")
        // create carries the first key, read once from stdin.
        if let i = t.firstIndex(where: { $0.command == "ai.connections.create" }) { t[i].credentialStdin = true }
        t += crud(["ai", "model-profiles"], "ai.modelProfiles", idParam: "modelProfileId")
        t += crud(["ai", "profiles"], "ai.profiles", idParam: "guiProfileId")
        t += [
            CommandSpec(words: ["ai", "capabilities"], command: "runtime.capabilities"),
            CommandSpec(words: ["ai", "credentials", "rotate"], command: "ai.credentials.rotate",
                        flags: [.s("connection-id", "connectionId"), .i("expected-revision", "expectedRevision")],
                        required: ["connectionId", "expectedRevision"], credentialStdin: true),
            CommandSpec(words: ["ai", "models", "list"], command: "ai.models.list",
                        flags: [.s("connection-id", "connectionId"), .i("limit", "limit"), .s("cursor", "cursor")],
                        required: ["connectionId"]),
            CommandSpec(words: ["ai", "models", "refresh"], command: "ai.models.refresh",
                        flags: [.s("connection-id", "connectionId"), .i("expected-revision", "expectedRevision")],
                        required: ["connectionId", "expectedRevision"], waits: .operation),
            CommandSpec(words: ["ai", "profiles", "default", "get"], command: "ai.profiles.default.get"),
            CommandSpec(words: ["ai", "profiles", "default", "set"], command: "ai.profiles.setDefault",
                        flags: [.init(name: "id", param: "guiProfileId", value: .nullableString),
                                .i("expected-default-revision", "expectedDefaultRevision"),
                                .i("expected-profile-revision", "expectedProfileRevision")],
                        required: ["guiProfileId", "expectedDefaultRevision"]),
            CommandSpec(words: ["ai", "tests", "start"], command: "ai.tests.start",
                        flags: [.s("profile-id", "guiProfileId"), .i("expected-revision", "expectedRevision")],
                        required: ["guiProfileId", "expectedRevision"],
                        fixed: [("fixtureId", .string("synthetic_gui_v1"))], waits: .operation),
            CommandSpec(words: ["ai", "operations", "get"], command: "ai.operations.get",
                        flags: [.s("id", "operationId")], required: ["operationId"]),
            CommandSpec(words: ["ai", "operations", "cancel"], command: "ai.operations.cancel",
                        flags: [.s("id", "operationId")], required: ["operationId"]),
            CommandSpec(words: ["ai", "usage"], command: "ai.usage.summary",
                        flags: [.s("from", "from"), .s("to", "to"), .s("connection-id", "connectionId")],
                        required: ["from", "to"]),
            CommandSpec(words: ["gui", "run"], command: "gui.runs.start",
                        flags: [.s("desktop", "desktopId"), .s("session", "sessionId"),
                                .s("profile-id", "guiProfileId"), .i("expected-profile-revision", "expectedProfileRevision"),
                                .init(name: "allowed-actions", param: "allowedActions", value: .list)],
                        required: ["desktopId", "goal", "verification", "allowedActions"], waits: .run),
            CommandSpec(words: ["gui", "status"], command: "gui.runs.get",
                        flags: [.s("run-id", "runId")], required: ["runId"]),
            CommandSpec(words: ["gui", "cancel"], command: "gui.runs.cancel",
                        flags: [.s("run-id", "runId")], required: ["runId"]),
            CommandSpec(words: ["gui", "events"], command: "gui.runs.events",
                        flags: [.s("run-id", "runId"), .i("after-sequence", "afterSequence"), .i("limit", "limit")],
                        required: ["runId", "afterSequence"], follows: true),
        ]
        return t
    }()

    /// The longest table entry whose words prefix `args`.
    static func match(_ args: [String]) -> (CommandSpec, [String])? {
        all.filter { args.starts(with: $0.words) }
            .max { $0.words.count < $1.words.count }
            .map { ($0, Array(args.dropFirst($0.words.count))) }
    }
}

/// Options parsed from a friendly command's arguments.
struct Invocation {
    var params: [(String, JSONValue)] = []
    var idempotencyKey: String?
    var deadlineAt: String?
    var dryRun = false
    var wait = false
    var follow = false
    var waitTimeoutMs = 600_000
    var pollMs = 500
}

enum LocalFailure: Error {
    case usage(String)
    case validation(String)
}

extension ContractCLI {
    func buildInvocation(_ spec: CommandSpec, _ args: [String]) throws -> Invocation {
        var inv = Invocation()
        var fields: [String: JSONValue] = [:]
        var order: [String] = []
        func put(_ key: String, _ value: JSONValue, from source: String) throws {
            if fields[key] != nil { throw LocalFailure.usage("\(key) is given twice (\(source)); refusing to override") }
            fields[key] = value
            order.append(key)
        }
        var paramsFile: String?
        var goalFile: String?
        var verificationFile: String?
        var credentialStdin = false
        var i = 0
        func next(_ flag: String) throws -> String {
            guard i + 1 < args.count else { throw LocalFailure.usage("--\(flag) needs a value") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { throw LocalFailure.usage("unexpected argument \(a)") }
            let name = String(a.dropFirst(2))
            switch name {
            case "api-key":
                throw LocalFailure.usage("--api-key is not supported: pass the key on stdin with --credential-stdin")
            case "credential-stdin":
                guard spec.credentialStdin else { throw LocalFailure.usage("\(spec.words.joined(separator: " ")) takes no credential") }
                credentialStdin = true
            case "params-file":
                guard spec.paramsFile != .none else { throw LocalFailure.usage("this command takes no --params-file") }
                paramsFile = try next(name)
            case "goal-file" where spec.command == "gui.runs.start": goalFile = try next(name)
            case "verification-file" where spec.command == "gui.runs.start": verificationFile = try next(name)
            case "idempotency-key": inv.idempotencyKey = try next(name)
            case "deadline-at": inv.deadlineAt = try next(name)
            case "dry-run": inv.dryRun = true
            case "wait" where spec.waits != nil: inv.wait = true
            case "follow" where spec.follows: inv.follow = true
            case "wait-timeout-ms":
                guard let v = Int(try next(name)), v > 0 else { throw LocalFailure.usage("--wait-timeout-ms needs a positive integer") }
                inv.waitTimeoutMs = v
            case "clear" where spec.command == "ai.profiles.setDefault":
                try put("guiProfileId", .null, from: "--clear")
            default:
                guard let flag = spec.flags.first(where: { $0.name == name }) else {
                    throw LocalFailure.usage("unknown option --\(name) for \(spec.words.joined(separator: " "))")
                }
                if flag.value == .bool { try put(flag.param, .bool(true), from: "--\(name)"); break }
                let raw = try next(name)
                switch flag.value {
                case .string, .nullableString: try put(flag.param, .string(raw), from: "--\(name)")
                case .int:
                    guard let v = Int(raw) else { throw LocalFailure.usage("--\(name) needs an integer") }
                    try put(flag.param, .int(v), from: "--\(name)")
                case .list:
                    try put(flag.param, .array(raw.split(separator: ",").map { .string(String($0)) }), from: "--\(name)")
                case .bool: break
                }
            }
            i += 1
        }

        if let paramsFile {
            if paramsFile == "-" && credentialStdin {
                throw LocalFailure.usage("stdin carries the credential; the params file must be a file")
            }
            let value: JSONValue
            do { value = try StrictJSON.parse(paramsFile == "-" ? readStdin() : readFile(paramsFile)) } catch {
                throw LocalFailure.usage("\(paramsFile) is not one JSON object")
            }
            guard let members = value.objectMembers else { throw LocalFailure.usage("\(paramsFile) must hold a JSON object") }
            if members.contains(where: { $0.key == "schemaVersion" || $0.key == "command" }) {
                throw LocalFailure.usage("--params-file holds params only; a whole envelope goes to `rpc --request-file`")
            }
            if spec.paramsFile == .patch {
                try put("patch", value, from: "--params-file")
            } else {
                for m in members { try put(m.key, m.value, from: "--params-file") }
            }
        }
        if let goalFile {
            guard let text = try? String(decoding: readFile(goalFile), as: UTF8.self) else {
                throw LocalFailure.usage("cannot read \(goalFile)")
            }
            try put("goal", .string(text.trimmingCharacters(in: .whitespacesAndNewlines)), from: "--goal-file")
        }
        if let verificationFile {
            guard let data = try? readFile(verificationFile), let v = try? StrictJSON.parse(data) else {
                throw LocalFailure.usage("\(verificationFile) is not one JSON object")
            }
            try put("verification", v, from: "--verification-file")
        }
        if spec.credentialStdin {
            guard credentialStdin else { throw LocalFailure.usage("pass the key on stdin with --credential-stdin") }
            var key = String(decoding: readStdin(), as: UTF8.self)
            while key.hasSuffix("\n") || key.hasSuffix("\r") { key.removeLast() }
            guard !key.isEmpty else { throw LocalFailure.usage("stdin held no key") }
            try put("credential", .obj([("apiKey", .string(key))]), from: "--credential-stdin")
        }
        for (k, v) in spec.fixed { try put(k, v, from: "the command") }
        let missing = spec.required.filter { fields[$0] == nil }
        if !missing.isEmpty { throw LocalFailure.usage("missing \(missing.joined(separator: ", "))") }
        inv.params = order.map { ($0, fields[$0]!) }
        inv.wait = inv.wait && !inv.dryRun
        inv.follow = inv.follow && !inv.dryRun
        return inv
    }

    func envelope(_ command: String, _ params: JSONValue, key: String?, deadlineAt: String? = nil) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("schemaVersion", .string(ContractBundle.schemaVersion)),
            ("requestId", .string(UUID().uuidString.lowercased())),
            ("command", .string(command)),
            ("params", params),
        ]
        var ctx: [(String, JSONValue)] = []
        if let deadlineAt { ctx.append(("deadlineAt", .string(deadlineAt))) }
        if let key { ctx.append(("idempotencyKey", .string(key))) }
        if !ctx.isEmpty { m.append(("context", .obj(ctx))) }
        return .obj(m)
    }

    /// Run one friendly command. Returns nil when `args` names none.
    func runFriendly(_ args: [String], socket: String) -> ExitCode? {
        guard let (spec, rest) = CommandTable.match(args) else { return nil }
        let inv: Invocation
        do { inv = try buildInvocation(spec, rest) } catch let LocalFailure.usage(m) {
            return usageError(m)
        } catch { return usageError(nil) }
        guard let op = ContractBundle.shared.operation(spec.command) else { return usageError("unknown command") }
        if op.requiresIdempotencyKey && inv.idempotencyKey == nil {
            return usageError("\(spec.words.joined(separator: " ")) changes state: pass --idempotency-key, and reuse it when retrying")
        }
        let request = envelope(spec.command, .obj(inv.params), key: op.requiresIdempotencyKey ? inv.idempotencyKey : nil,
                               deadlineAt: inv.deadlineAt)
        if !inv.wait && !inv.follow {
            return submit(request.encodedData(), socket: socket, dryRun: inv.dryRun)
        }
        if inv.follow { return follow(request, socket: socket, inv: inv) }
        return waitFor(request, spec: spec, socket: socket, inv: inv)
    }

    /// Send one request; nil reply means the exit code says why.
    func exchange(_ request: JSONValue, socket: String) -> (JSONValue?, ExitCode) {
        var frame = request.encodedData()
        frame.append(0x0A)
        guard case let .frame(body) = send(frame, socket),
              let response = try? StrictJSON.parse(body),
              (try? ContractBundle.shared.validateRpc(response, "Response"))?.isEmpty == true,
              response["requestId"] == request["requestId"] else {
            stderr("agentdesktop: no valid response from the runtime at \(socket)")
            return (nil, .runtimeUnavailable)
        }
        return (response, response["ok"]?.boolValue == true ? .ok : .rejected)
    }

    /// `--wait`: submit, then poll get until a terminal state; stdout is the
    /// last get envelope; the acceptance goes to stderr.
    func waitFor(_ request: JSONValue, spec: CommandSpec, socket: String, inv: Invocation) -> ExitCode {
        guard case .request = Envelope.decode(request.encodedData()) else {
            return submit(request.encodedData(), socket: socket, dryRun: true)
        }
        let (accepted, code) = exchange(request, socket: socket)
        guard let accepted else { return code }
        guard code == .ok, let result = accepted["result"] else {
            stdout(accepted.encoded())
            return mapError(accepted)
        }
        let isRun = spec.waits == .run
        let idField = isRun ? "runId" : "operationId"
        guard let id = result[idField]?.stringValue else {
            stdout(accepted.encoded())
            return .ok
        }
        stderr("agentdesktop: accepted \(idField) \(id)")
        let started = nowMs()
        var last = accepted
        while true {
            if interrupted() {
                if isRun, let key = inv.idempotencyKey {
                    let cancel = envelope("gui.runs.cancel", .obj([("runId", .string(id))]), key: "\(key)-cancel")
                    let (ack, _) = exchange(cancel, socket: socket)
                    if let ack { stderr("agentdesktop: cancel \(ack["ok"]?.boolValue == true ? "accepted" : "refused"): \(ack.encoded())") }
                }
                stdout(last.encoded())
                return .interrupted
            }
            let get = envelope(isRun ? "gui.runs.get" : "ai.operations.get", .obj([(idField, .string(id))]), key: nil)
            let (reply, code) = exchange(get, socket: socket)
            guard let reply else { return code }
            last = reply
            guard code == .ok, let state = reply["result"]?["state"]?.stringValue else {
                stdout(reply.encoded())
                return mapError(reply)
            }
            switch state {
            case "succeeded": stdout(reply.encoded()); return .ok
            case "failed": stdout(reply.encoded()); return .rejected
            case "cancelled": stdout(reply.encoded()); return .cancelled
            default: break
            }
            if nowMs() - started >= UInt64(inv.waitTimeoutMs) {
                stderr("agentdesktop: stopped waiting; \(idField) \(id) is \(state) and may still be running")
                stdout(reply.encoded())
                return .waitTimedOut
            }
            sleepMs(inv.pollMs)
        }
    }

    /// `gui events --follow`: one complete response per line (NDJSON) until
    /// the run is terminal and no events remain.
    func follow(_ request: JSONValue, socket: String, inv: Invocation) -> ExitCode {
        guard case let .request(req) = Envelope.decode(request.encodedData()) else {
            return submit(request.encodedData(), socket: socket, dryRun: true)
        }
        let runId = req.params["runId"]!.stringValue!
        var after = req.params["afterSequence"]?.intValue ?? 0
        let started = nowMs()
        while true {
            if interrupted() { return .interrupted }
            var params: [(String, JSONValue)] = [("runId", .string(runId)), ("afterSequence", .int(after))]
            if let limit = req.params["limit"] { params.append(("limit", limit)) }
            let (reply, code) = exchange(envelope("gui.runs.events", .obj(params), key: nil), socket: socket)
            guard let reply else { return code }
            stdout(reply.encoded())
            guard code == .ok, let result = reply["result"] else { return mapError(reply) }
            after = result["nextAfterSequence"]?.intValue ?? after
            if result["hasMore"]?.boolValue == true { continue }
            let (status, sc) = exchange(envelope("gui.runs.get", .obj([("runId", .string(runId))]), key: nil), socket: socket)
            guard let status else { return sc }
            let state = status["result"]?["state"]?.stringValue ?? ""
            if ["succeeded", "failed", "cancelled"].contains(state) {
                // One last read so events written with the terminal state are not lost.
                let (tail, _) = exchange(envelope("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(after))]), key: nil), socket: socket)
                if let tail, tail["result"]?["events"]?.arrayValue?.isEmpty == false { stdout(tail.encoded()) }
                return .ok
            }
            if nowMs() - started >= UInt64(inv.waitTimeoutMs) { return .waitTimedOut }
            sleepMs(inv.pollMs)
        }
    }

    func mapError(_ response: JSONValue) -> ExitCode {
        switch response["error"]?["code"]?.stringValue {
        case ErrorCode.unsupportedSchema.rawValue, ErrorCode.unsupportedCommand.rawValue: return .runtimeUnavailable
        default: return .rejected
        }
    }
}
