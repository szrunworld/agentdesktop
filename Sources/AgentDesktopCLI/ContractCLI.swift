import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

/// Exit codes of the CLI contract (spec §13.2).
public enum ExitCode: Int32 {
    case ok = 0
    case localValidation = 2
    case runtimeUnavailable = 3
    case rejected = 4
    case cancelled = 5
    case waitTimedOut = 6
    case interrupted = 130
}

/// The `rpc`, `ai …` and `gui …` groups of `agentdesktop`: runtime/1
/// requests for the methods the AI service answers on the Runtime's single
/// endpoint. CommandRouter hands these words over unchanged; the exit codes
/// of these groups follow DEV-SPEC §13.2 until the two plans settle on one
/// table. Output is the runtime/1 response.
///
///     agentdesktop [--json] [--socket PATH] rpc --request-file FILE [--dry-run]
///     agentdesktop [--json] [--socket PATH] ai capabilities [--dry-run]
///
/// `rpc` sends a complete runtime/1 request after validating it locally.
public struct ContractCLI {
    public var stdout: (String) -> Void
    public var stderr: (String) -> Void
    public var readFile: (String) throws -> Data
    public var environment: [String: String]
    /// One runtime/1 request to the endpoint at the path, after a handshake
    /// on the same connection; the raw response, or why there is none.
    public var send: (JSONValue, String) -> TransportReply
    public var readStdin: () -> Data
    public var nowMs: () -> UInt64
    public var sleepMs: (Int) -> Void
    /// True once the user pressed Ctrl-C (main installs the handler).
    public var interrupted: () -> Bool

    public init(stdout: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
                environment: [String: String] = ProcessInfo.processInfo.environment,
                send: @escaping (JSONValue, String) -> TransportReply = RuntimeTransport.exchange,
                readStdin: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
                nowMs: @escaping () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000 },
                sleepMs: @escaping (Int) -> Void = { usleep(useconds_t($0 * 1000)) },
                interrupted: @escaping () -> Bool = { Interrupt.received }) {
        self.stdout = stdout
        self.stderr = stderr
        self.readFile = readFile
        self.environment = environment
        self.send = send
        self.readStdin = readStdin
        self.nowMs = nowMs
        self.sleepMs = sleepMs
        self.interrupted = interrupted
    }

    public static let usage = """
    usage: agentdesktop [--json] [--socket PATH] COMMAND [options]

      rpc --request-file FILE                      a complete runtime/1 request
      ai capabilities                               runtime.capabilities (the GUI part is `gui`)
      ai connections list|get|create|update|disable|delete
           create: --params-file F --credential-stdin; get/disable/delete: --id ID --expected-revision N;
           update: --id ID --expected-revision N --params-file PATCH
      ai credentials rotate --connection-id ID --expected-revision N --credential-stdin
      ai models list --connection-id ID | refresh --connection-id ID --expected-revision N [--wait]
      ai model-profiles list|get|create|update|disable|delete   (same flags as connections)
      ai profiles list|get|create|update|disable|delete         (GUI profiles)
      ai profiles default get | set (--id ID | --clear) --expected-default-revision N [--expected-profile-revision N]
      ai tests start --profile-id ID --expected-revision N [--wait]
      ai operations get|cancel --id ID
      ai usage --from TIME --to TIME [--connection-id ID]
      gui run --desktop ID [--session ID] [--profile-id ID --expected-profile-revision N]
              --goal-file F --verification-file F --allowed-actions click,type,key [--wait]
      gui status|cancel --run-id ID
      gui events --run-id ID --after-sequence N [--follow]

    Every command that changes state needs --idempotency-key K (8 to 128 characters; it is the requestId); reuse K when retrying.
    Common: --dry-run (validate only, nothing sent), --wait-timeout-ms N, --deadline-at TIME.
    Keys are read from stdin only; there is no --api-key.
    Exit: 0 ok, 2 local validation, 3 runtime unreachable/incompatible, 4 rejected or failed,
          5 cancelled, 6 stopped waiting, 130 interrupted.
    """

    /// The Runtime's single endpoint (A2): AGENTDESKTOP_ENDPOINT, else a
    /// side instance's `<socket>.runtime.sock` from AGENTDESKTOP_SOCKET,
    /// else the product's.
    public func defaultSocket() -> String {
        if let p = environment["AGENTDESKTOP_ENDPOINT"], !p.isEmpty { return p }
        if let p = environment["AGENTDESKTOP_SOCKET"], !p.isEmpty {
            return URL(fileURLWithPath: p).deletingPathExtension().appendingPathExtension("runtime.sock").path
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/AgentDesktop/runtime.sock"
    }

    public func run(_ args: [String]) -> ExitCode {
        var rest = args[...]
        var socket: String?
        while let a = rest.first, a.hasPrefix("--") {
            rest = rest.dropFirst()
            switch a {
            case "--json": continue
            case "--socket":
                guard let p = rest.first else { return usageError("--socket needs a path") }
                socket = p
                rest = rest.dropFirst()
            default:
                return usageError("unknown option \(a)")
            }
        }
        let words = Array(rest)
        let path = socket ?? defaultSocket()
        switch words.first {
        case "rpc":
            var file: String?
            var dryRun = false
            var i = 1
            while i < words.count {
                switch words[i] {
                case "--request-file":
                    guard i + 1 < words.count else { return usageError("--request-file needs a path") }
                    file = words[i + 1]; i += 2
                case "--dry-run": dryRun = true; i += 1
                default: return usageError("unknown argument \(words[i])")
                }
            }
            guard let file else { return usageError("rpc needs --request-file") }
            if file == "-" { return usageError("rpc reads its request from a file; stdin is kept for secrets") }
            let data: Data
            do { data = try readFile(file) } catch { return usageError("cannot read \(file)") }
            return submit(data, socket: path, dryRun: dryRun)
        default:
            return runFriendly(words, socket: path) ?? usageError(nil)
        }
    }

    func usageError(_ message: String?) -> ExitCode {
        if let message { stderr("agentdesktop: \(message)") }
        stderr(Self.usage)
        return .localValidation
    }

    func localFailure(_ message: String, violations: [String] = []) -> ExitCode {
        let details: JSONValue? = violations.isEmpty ? nil : .obj([("violations", .array(violations.prefix(20).map(JSONValue.string)))])
        stdout(RuntimeResponse.failure(nil, RuntimeError("invalid_argument", message, phase: .local, notSent: true,
                                                         details: details)).json.encoded())
        return .localValidation
    }

    /// Validate locally, then (unless dry-run) send and map the answer.
    func submit(_ data: Data, socket: String, dryRun: Bool) -> ExitCode {
        guard let request = try? StrictJSON.parse(data) else { return localFailure("the request file is not one strict JSON object") }
        if let problem = Self.problems(request) { return localFailure(problem.0, violations: problem.1) }
        if dryRun {
            stdout(JSONValue.obj([("dryRun", .bool(true)), ("valid", .bool(true)),
                                  ("request", Self.redacted(request))]).encoded())
            return .ok
        }
        let (response, code) = exchange(request, socket: socket)
        if let response { stdout(response.encoded()) }
        return code
    }

    /// Why a runtime/1 request would be refused before it is sent, if it
    /// would: the envelope, then a servedBy method's params.
    static func problems(_ request: JSONValue) -> (String, [String])? {
        let v = RuntimeContract.shared.validate(request, "Request")
        if !v.isEmpty { return ("the request does not match the runtime/1 envelope", v) }
        let method = request["method"]?.stringValue ?? ""
        if let op = ContractBundle.shared.operation(method) {
            let pv = (try? ContractBundle.shared.validate(request["params"] ?? .obj([]), "\(op.defPrefix)_params"))?.map(\.description) ?? []
            if !pv.isEmpty { return ("params do not match \(method)", pv) }
            if op.requiresIdempotencyKey, (request["requestId"]?.stringValue?.count ?? 0) < 8 {
                return ("\(method) changes state: its requestId is the idempotency key and needs 8 to 128 characters", [])
            }
        }
        return nil
    }

    /// Send one request; nil reply means the exit code says why.
    func exchange(_ request: JSONValue, socket: String) -> (JSONValue?, ExitCode) {
        switch send(request, socket) {
        case let .unreachable(why):
            stderr("agentdesktop: cannot reach the runtime at \(socket): \(why)")
            return (nil, .runtimeUnavailable)
        case let .reply(response):
            guard RuntimeContract.shared.validate(response, "Response").isEmpty else {
                stderr("agentdesktop: the runtime answered outside \(RuntimeAPI.version)")
                return (nil, .runtimeUnavailable)
            }
            guard response["requestId"] == request["requestId"] else {
                stderr("agentdesktop: the response does not belong to this request")
                return (nil, .runtimeUnavailable)
            }
            return (response, response["ok"]?.boolValue == true ? .ok : Self.exitCode(response))
        }
    }

    /// The groups' exit classes (§13.2) for a runtime/1 error.
    public static func exitCode(_ response: JSONValue) -> ExitCode {
        switch response["error"]?["code"]?.stringValue {
        case "capability_missing", "version_mismatch", "handshake_required", "runtime_offline": return .runtimeUnavailable
        default: return .rejected
        }
    }

    /// The request with every write-only secret replaced.
    static func redacted(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .object(members):
            return .object(members.map { m in
                m.key == "apiKey" ? (key: m.key, value: .string("[REDACTED]")) : (key: m.key, value: redacted(m.value))
            })
        case let .array(items):
            return .array(items.map(redacted))
        default:
            return v
        }
    }
}

/// What one request to the endpoint came back with.
public enum TransportReply: Sendable {
    case reply(JSONValue)
    case unreachable(String)
}

/// A runtime/1 exchange on a fresh connection: handshake, then the request.
public enum RuntimeTransport {
    public static func exchange(_ request: JSONValue, path: String) -> TransportReply {
        let transport: UnixSocketTransport
        do { transport = try UnixSocketTransport(path: path, timeout: 120) } catch let e as RuntimeError {
            return .unreachable(e.message)
        } catch { return .unreachable("\(error)") }
        defer { transport.close() }
        let hello = RuntimeRequest(.handshake, params: .obj([
            ("apiVersions", .array(RuntimeAPI.supportedVersions.map(JSONValue.string))),
            ("client", .obj([("name", .string("agentdesktop-cli")), ("version", .string(RuntimeAPI.productVersion))])),
        ]))
        do {
            let ack = try StrictJSON.parse(transport.exchange(hello.json.encodedData()))
            guard ack["ok"]?.boolValue == true else { return .reply(ack.setting("requestId", request["requestId"] ?? .null)) }
            return .reply(try StrictJSON.parse(transport.exchange(request.encodedData())))
        } catch let e as RuntimeError {
            return .unreachable(e.message)
        } catch {
            return .unreachable("the runtime answered with something that is not JSON")
        }
    }
}

/// Ctrl-C while waiting: remembered, so the wait loop can cancel the run
/// it started before exiting with 130.
public enum Interrupt {
    nonisolated(unsafe) private static var flag: sig_atomic_t = 0
    public static var received: Bool { flag != 0 }
    public static func install() {
        signal(SIGINT) { _ in Interrupt.flag = 1 }
    }
}
