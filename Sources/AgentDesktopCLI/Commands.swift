import AgentDesktopProtocol
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
    enum Waits { case operation }

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
            case "idempotency-key": inv.idempotencyKey = try next(name)
            case "deadline-at": inv.deadlineAt = try next(name)
            case "dry-run": inv.dryRun = true
            case "wait" where spec.waits != nil: inv.wait = true
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
            if members.contains(where: { $0.key == "apiVersion" || $0.key == "method" }) {
                throw LocalFailure.usage("--params-file holds params only; a whole request goes to `rpc --request-file`")
            }
            if spec.paramsFile == .patch {
                try put("patch", value, from: "--params-file")
            } else {
                for m in members { try put(m.key, m.value, from: "--params-file") }
            }
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
        return inv
    }

    /// One runtime/1 request. A write's idempotency key is its requestId.
    func envelope(_ method: String, _ params: JSONValue, key: String?, deadlineAt: String? = nil) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("apiVersion", .string(RuntimeAPI.version)),
            ("requestId", .string(key ?? RuntimeRequest.newId())),
            ("method", .string(method)),
        ]
        if let deadlineAt { m.append(("deadline", .string(deadlineAt))) }
        m.append(("params", params))
        return .obj(m)
    }

    /// Run one friendly command. Returns nil when `args` names none.
    func runFriendly(_ args: [String], socket: String) -> ExitCode? {
        guard let (spec, rest) = CommandTable.match(args) else { return nil }
        let inv: Invocation
        do { inv = try buildInvocation(spec, rest) } catch let LocalFailure.usage(m) {
            return usageError(m)
        } catch { return usageError(nil) }
        // `ai capabilities` is the Runtime's own runtime.capabilities; the
        // GUI backend's part is its `gui` section.
        if spec.command == RuntimeMethod.capabilities.rawValue {
            return submit(envelope(spec.command, .obj([]), key: nil).encodedData(), socket: socket, dryRun: inv.dryRun)
        }
        guard let op = ContractBundle.shared.operation(spec.command) else { return usageError("unknown command") }
        if op.requiresIdempotencyKey && inv.idempotencyKey == nil {
            return usageError("\(spec.words.joined(separator: " ")) changes state: pass --idempotency-key, and reuse it when retrying")
        }
        let request = envelope(spec.command, .obj(inv.params), key: op.requiresIdempotencyKey ? inv.idempotencyKey : nil,
                               deadlineAt: inv.deadlineAt)
        if !inv.wait {
            return submit(request.encodedData(), socket: socket, dryRun: inv.dryRun)
        }
        return waitFor(request, spec: spec, socket: socket, inv: inv)
    }

    /// `--wait`: submit, then poll get until a terminal state; stdout is the
    /// last get envelope; the acceptance goes to stderr.
    func waitFor(_ request: JSONValue, spec: CommandSpec, socket: String, inv: Invocation) -> ExitCode {
        guard Self.problems(request) == nil else { return submit(request.encodedData(), socket: socket, dryRun: true) }
        let (accepted, code) = exchange(request, socket: socket)
        guard let accepted else { return code }
        guard code == .ok, let result = accepted["data"] else {
            stdout(accepted.encoded())
            return mapError(accepted)
        }
        let idField = "operationId"
        guard let id = result[idField]?.stringValue else {
            stdout(accepted.encoded())
            return .ok
        }
        stderr("agentdesktop: accepted \(idField) \(id)")
        let started = nowMs()
        var last = accepted
        while true {
            if interrupted() {
                stdout(last.encoded())
                return .interrupted
            }
            let get = envelope("ai.operations.get", .obj([(idField, .string(id))]), key: nil)
            let (reply, code) = exchange(get, socket: socket)
            guard let reply else { return code }
            last = reply
            guard code == .ok, let state = reply["data"]?["state"]?.stringValue else {
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

    func mapError(_ response: JSONValue) -> ExitCode { Self.exitCode(response) }
}
