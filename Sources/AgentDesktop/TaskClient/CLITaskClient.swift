import Foundation

/// The product's real client: the bundled command line (`bin/agentdesktop
/// task …`, contract §5), one JSON line per call. Until the runtime ships
/// `task view`, every call ends in `.capabilityMissing`; with no host
/// listening, in `.offline`.
final class CLITaskClient: TaskClient {
    let scope: ClientScope
    private let executable: URL
    private let environment: [String: String]

    init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
         scope: ClientScope = ClientScope(clientId: HostRole.bundleID, agentIds: nil)) {
        self.executable = executable
        self.environment = environment
        self.scope = scope
    }

    /// The command line of the app this process runs in, if it is bundled.
    static func bundled() -> URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/agentdesktop")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func service() async throws -> ServiceIdentity {
        try Self.validated(try await run(["task", "service"]), expecting: .service).service!
    }

    func views() async throws -> [TaskView] {
        try Self.validated(try await run(["task", "views"]), expecting: .views).tasks!
    }

    func view(_ taskId: String) async throws -> TaskView {
        try Self.validated(try await run(["task", "view", taskId]), expecting: .view).task!
    }

    func control(_ request: ControlRequest) async throws -> ControlReceipt {
        var words = ["task", "control", request.taskId, request.operation.rawValue, "--request-id", request.requestId]
        if let payload = request.payload, let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) {
            words += ["--payload", json]
        }
        return try Self.validated(try await run(words), expecting: .control).receipt!
    }

    enum Expecting { case service, views, view, control }

    /// A successful reply must carry the service, at this contract's version,
    /// and the field the call is for. Anything else is not a reply this
    /// client understands, never an empty result.
    static func validated(_ reply: Reply, expecting: Expecting) throws -> Reply {
        guard let service = reply.service else { throw TaskClientError.connectionFailed("the reply names no service") }
        try checkVersion(service)
        switch expecting {
        case .service: break
        case .views: guard reply.tasks != nil else { throw TaskClientError.connectionFailed("the reply to `task views` has no tasks field") }
        case .view: guard reply.task != nil else { throw TaskClientError.connectionFailed("the reply to `task view` has no task") }
        case .control: guard reply.receipt != nil else { throw TaskClientError.connectionFailed("the reply to `task control` has no receipt") }
        }
        return reply
    }

    // MARK: Replies

    struct Reply: Decodable {
        struct Failure: Decodable {
            var code: String
            var message: String
        }
        var ok: Bool
        var error: Failure?
        var service: ServiceIdentity?
        var task: TaskView?
        var tasks: [TaskView]?
        var inbox: [InboxItem]?
        var receipt: ControlReceipt?
    }

    static func checkVersion(_ service: ServiceIdentity) throws {
        guard service.task.protocolVersion == ServiceIdentity.supportedProtocolVersion else {
            throw TaskClientError.versionMismatch(found: service.task.protocolVersion, supported: ServiceIdentity.supportedProtocolVersion)
        }
    }

    /// One JSON line from the command line, or the client error it stands
    /// for. Structured first: a line that parses as a reply is read as one,
    /// whatever words it contains. Only output that is not JSON at all goes
    /// through the legacy prose check (the engine CLI's "is not running").
    static func parse(stdout: String, exitCode: Int32) throws -> Reply {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // The command line prints one JSON line; a pretty-printed document is read whole.
        let candidates = [text, text.split(separator: "\n").last.map(String.init) ?? ""]
        var decoded: Reply?
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data), json is [String: Any] else { continue }
            guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                throw TaskClientError.connectionFailed("the reply is JSON this contract does not describe: \(candidate.prefix(200))")
            }
            decoded = reply
            break
        }
        guard let reply = decoded else {
            if text.lowercased().contains("is not running") { throw TaskClientError.offline(text) }
            throw TaskClientError.connectionFailed(text.isEmpty ? "the command line answered nothing (exit \(exitCode))" : text)
        }
        if reply.ok { return reply }
        let failure = reply.error ?? .init(code: "unknown", message: "the command failed (exit \(exitCode))")
        // A runtime from before this contract knows no `view`: it says so as invalid input, and that is a missing capability here.
        if failure.code == "invalid_input", failure.message.localizedCaseInsensitiveContains("command") {
            throw TaskClientError.capabilityMissing(failure.message)
        }
        throw TaskClientError.fromCode(failure.code, failure.message)
    }

    private func run(_ words: [String]) async throws -> Reply {
        let process = Process()
        process.executableURL = executable
        process.arguments = words
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do {
            try process.run()
        } catch {
            throw TaskClientError.connectionFailed("could not start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try Self.parse(stdout: String(data: data, encoding: .utf8) ?? "", exitCode: process.terminationStatus)
    }
}
