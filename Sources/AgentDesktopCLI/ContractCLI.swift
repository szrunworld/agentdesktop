import AgentDesktopContracts
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

/// The `rpc`, `ai …` and `gui …` groups of `agentdesktop`, which speak the
/// AI/GUI contract v1 (agentdesktop.ai/1, DEV-SPEC §13) to its own service.
/// CommandRouter hands these words over unchanged; the exit codes of these
/// groups follow DEV-SPEC §13.2 until the two plans settle on one table.
///
/// The part of the product CLI that speaks contract v1 directly:
///
///     agentdesktop [--json] [--socket PATH] rpc --request-file FILE [--dry-run]
///     agentdesktop [--json] [--socket PATH] ai capabilities [--dry-run]
///
/// `rpc` sends a complete versioned envelope after validating it locally,
/// so all 32 operations are reachable before their friendly aliases exist.
public struct ContractCLI {
    public var stdout: (String) -> Void
    public var stderr: (String) -> Void
    public var readFile: (String) throws -> Data
    public var environment: [String: String]
    public var send: (Data, String) -> FrameReader.Result
    public var readStdin: () -> Data
    public var nowMs: () -> UInt64
    public var sleepMs: (Int) -> Void
    /// True once the user pressed Ctrl-C (main installs the handler).
    public var interrupted: () -> Bool

    public init(stdout: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
                readFile: @escaping (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) },
                environment: [String: String] = ProcessInfo.processInfo.environment,
                send: @escaping (Data, String) -> FrameReader.Result = ContractOverRuntime.exchange,
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

      rpc --request-file FILE                      a complete versioned envelope
      ai capabilities                               contract v1 runtime.capabilities
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

    Every command that changes state needs --idempotency-key K; reuse K when retrying.
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

    func localFailure(_ error: ContractError) -> ExitCode {
        stdout(Envelope.failure(requestId: nil, error: error).encoded())
        return .localValidation
    }

    /// Validate locally, then (unless dry-run) send and map the answer.
    func submit(_ data: Data, socket: String, dryRun: Bool) -> ExitCode {
        let request: RpcRequest
        switch Envelope.decode(data) {
        case let .request(r): request = r
        case let .rejected(_, error): return localFailure(error)
        case .legacy: return localFailure(ContractError(.validationError, "the request file must be a versioned envelope"))
        }
        if dryRun {
            stdout(JSONValue.obj([("dryRun", .bool(true)), ("valid", .bool(true)),
                                  ("request", Self.redacted(request.raw))]).encoded())
            return .ok
        }
        var frame = request.raw.encodedData()
        frame.append(0x0A)
        let reply: Data
        switch send(frame, socket) {
        case let .frame(body): reply = body
        case .tooLarge:
            stderr("agentdesktop: the runtime answered with an oversized frame")
            return .runtimeUnavailable
        case let .ioError(code):
            stderr("agentdesktop: cannot reach the runtime at \(socket): \(String(cString: strerror(code)))")
            return .runtimeUnavailable
        case .truncated, .trailingData:
            stderr("agentdesktop: the runtime closed without one complete response line")
            return .runtimeUnavailable
        }
        guard let response = try? StrictJSON.parse(reply),
              (try? ContractBundle.shared.validateRpc(response, "Response"))?.isEmpty == true else {
            stderr("agentdesktop: the runtime answered outside contract \(ContractBundle.schemaVersion)")
            return .runtimeUnavailable
        }
        guard response["requestId"]?.stringValue == request.requestId else {
            stderr("agentdesktop: the response does not belong to this request")
            return .runtimeUnavailable
        }
        stdout(response.encoded())
        if response["ok"]?.boolValue == true { return .ok }
        switch response["error"]?["code"]?.stringValue {
        case ErrorCode.unsupportedSchema.rawValue, ErrorCode.unsupportedCommand.rawValue:
            return .runtimeUnavailable
        default:
            return .rejected
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

/// One request per connection over a Unix socket (spec §05.1).
public enum SocketClient {
    public static func exchange(_ frame: Data, path: String) -> FrameReader.Result {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .ioError(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return .ioError(errno)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return .ioError(ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return .ioError(errno) }
        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes { write(fd, $0.baseAddress! + sent, frame.count - sent) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return .ioError(errno) }
            sent += n
        }
        return FrameReader.read(fd: fd)
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
