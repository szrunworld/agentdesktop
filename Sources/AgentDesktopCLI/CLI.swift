import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// The `agentdesktop` command. It parses, builds typed requests, calls the
/// Runtime through `RuntimeClient` and prints the outcome; it never runs an
/// executor of its own. Everything outside the process is injected so tests
/// can count connections and requests.
struct CLI {
    static let clientInfo = ClientInfo(name: "agentdesktop-cli", version: RuntimeAPI.productVersion)

    var stdout: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
    var stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    var environment: [String: String] = ProcessInfo.processInfo.environment
    /// Path of this executable, to find the app bundle it ships in.
    var executablePath: String = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
    var makeClient: (Endpoint) -> RuntimeClient = { SocketRuntimeClient(endpoint: $0, info: CLI.clientInfo) }
    /// Ask the OS to start the product; returns an error message on failure.
    var launchProduct: (_ appPath: String?) -> String? = CLI.openProduct
    /// Note a write's requestId, method and endpoint before it is sent, so
    /// an interrupted run can be looked up later with request show.
    var recordRequest: (_ requestId: String, _ method: String, _ endpoint: String) -> Void = CLI.appendRequestLog
    /// Copy a file (observe --image-output).
    var copyFile: (_ from: String, _ to: String) throws -> Void = { from, to in
        let fm = FileManager.default
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        try fm.copyItem(atPath: from, toPath: to)
    }
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = Date.init

    /// Runs the contract v1 groups (rpc, ai, gui).
    var runContract: ([String]) -> Int32 = { ContractCLI().run($0).rawValue }

    func run(_ args: [String]) -> Int32 {
        if CommandRouter.isContractCommand(args) { return runContract(args) }
        let invocation: RuntimeInvocation
        do {
            invocation = try CommandRouter.parse(args)
        } catch let e as RuntimeError {
            // Arguments are refused before any connection, in the format asked
            // for when that part could be read.
            ResultWriter(format: CommandRouter.requestedFormat(args), stdout: stdout, stderr: stderr).failure(requestId: nil, e)
            return ExitStatus.of(e)
        } catch {
            stderr("agentdesktop: \(error)")
            return ExitStatus.unclassified
        }
        let out = ResultWriter(format: invocation.format, stdout: stdout, stderr: stderr)
        let endpoint = EndpointResolver.resolve(option: invocation.endpoint, environment: environment)

        switch invocation.command {
        case let .help(topic):
            if args.isEmpty {
                stderr(CommandRouter.usage(topic: []))
                return 2
            }
            stdout(CommandRouter.usage(topic: topic))
            return ExitStatus.ok
        case .version:
            return version(out)
        case let .runtimeStart(waitTimeout):
            return runtimeStart(out, endpoint: endpoint, waitTimeout: waitTimeout)
        case .doctor:
            return doctor(out, endpoint: endpoint)
        case .runtimeStatus, .runtimeCapabilities, .desktopList, .desktopShow, .appList, .windowList:
            return query(invocation.command, out, endpoint: endpoint)
        case let .call(call):
            return perform(call, out, endpoint: endpoint)
        }
    }

    /// Contents/Resources of the app this CLI ships in, if it does.
    var bundleResources: URL? {
        // <App>.app/Contents/Resources/bin/agentdesktop
        let bin = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
        let resources = bin.deletingLastPathComponent()
        let app = resources.deletingLastPathComponent().deletingLastPathComponent()
        guard bin.lastPathComponent == "bin", resources.lastPathComponent == "Resources",
              app.pathExtension == "app" else { return nil }
        return resources
    }

    var appPath: String? {
        bundleResources?.deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Run one Runtime call, mapping a thrown error to output and exit code.
    func withClient(_ out: ResultWriter, endpoint: Endpoint,
                    _ body: (RuntimeClient) throws -> Int32) -> Int32 {
        let client = makeClient(endpoint)
        defer { client.close() }
        do {
            return try body(client)
        } catch let e as RuntimeError {
            out.failure(requestId: nil, e)
            return ExitStatus.of(e)
        } catch {
            let e = RuntimeError("internal_error", "\(error)", phase: .local)
            out.failure(requestId: nil, e)
            return ExitStatus.of(e)
        }
    }

    static func openProduct(_ appPath: String?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g: do not bring the app forward; the host is a menu bar app.
        p.arguments = appPath.map { ["-g", $0] } ?? ["-g", "-b", RuntimeAPI.bundleID]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return "cannot run open: \(error)" }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "open exited \(p.terminationStatus)" : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}
