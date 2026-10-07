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
        let reply = try await run(["task", "service"])
        guard let service = reply.service else { throw TaskClientError.connectionFailed("no service in the reply") }
        try Self.checkVersion(service)
        return service
    }

    func views() async throws -> [TaskView] {
        let reply = try await run(["task", "views"])
        if let service = reply.service { try Self.checkVersion(service) }
        return reply.tasks ?? []
    }

    func view(_ taskId: String) async throws -> TaskView {
        let reply = try await run(["task", "view", taskId])
        if let service = reply.service { try Self.checkVersion(service) }
        guard let task = reply.task else { throw TaskClientError.connectionFailed("no task in the reply") }
        return task
    }

    func control(_ request: ControlRequest) async throws -> ControlReceipt {
        var words = ["task", "control", request.taskId, request.operation.rawValue, "--request-id", request.requestId]
        if let payload = request.payload, let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) {
            words += ["--payload", json]
        }
        let reply = try await run(words)
        guard let receipt = reply.receipt else { throw TaskClientError.connectionFailed("no receipt in the reply") }
        return receipt
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
        var receipt: ControlReceipt?
    }

    static func checkVersion(_ service: ServiceIdentity) throws {
        guard service.protocolVersion == ServiceIdentity.supportedProtocolVersion else {
            throw TaskClientError.versionMismatch(found: service.protocolVersion, supported: ServiceIdentity.supportedProtocolVersion)
        }
    }

    /// One JSON line from the command line, or the client error it stands for.
    static func parse(stdout: String, exitCode: Int32) throws -> Reply {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // The engine CLI answers in prose when no host listens on the socket.
        if text.lowercased().contains("is not running") { throw TaskClientError.offline(text) }
        guard let line = text.split(separator: "\n").last, let data = line.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else {
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
