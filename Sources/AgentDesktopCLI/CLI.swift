import AgentDesktopClient
import AgentDesktopMCP
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
    /// Tests replace the connection; by default it is a socket client with
    /// this CLI's own credential.
    var makeClient: ((Endpoint) -> RuntimeClient)?
    /// Where this CLI keeps the credentials it was issued (A4, S3): the
    /// keychain, or AGENTDESKTOP_KEYCHAIN's keychain file (test copies).
    /// Tests use a MemoryCredentialStore.
    var credentials: CredentialStore?

    /// The CLI is a paired client like any other (A4): it has no owner
    /// rights. Its credential is the one `agents pair` stored for this
    /// endpoint under AGENTDESKTOP_PROFILE (default "cli").
    var profile: String { environment["AGENTDESKTOP_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "cli" }

    func credentialStore() throws -> CredentialStore {
        if let credentials { return credentials }
        return try KeychainCredentialStore(keychainPath: environment["AGENTDESKTOP_KEYCHAIN"].flatMap { $0.isEmpty ? nil : $0 })
    }

    func credential(for endpoint: Endpoint, profile: String? = nil) -> ClientCredential? {
        (try? credentialStore().load(endpoint: endpoint.path, profile: profile ?? self.profile)) ?? nil
    }

    /// Trusted UI may wait 120 seconds for an answer before the Runtime
    /// replies. Keep a margin for dispatch and post-confirmation checks.
    // Keep the admin calls in sync with RuntimeService.confirmableMethods.
    private static let confirmedMethods: Set<String> = [
            "desktop.recoverBinding", "hub.windows.request", "hub.windows.revoke",
            "runtime.enableInput", "hub.clients.list", "hub.clients.show", "hub.clients.revoke",
            "hub.grants.list", "hub.grants.set", "hub.grants.revoke", "hub.connections.list",
    ]

    static func replyTimeout(for method: String) -> Double {
        return confirmedMethods.contains(method) || method.hasPrefix("ai.") ? 150 : 10
    }

    func client(_ endpoint: Endpoint, timeout: Double = 10) -> RuntimeClient {
        makeClient?(endpoint) ?? SocketRuntimeClient(endpoint: endpoint, info: CLI.clientInfo,
                                                    timeout: timeout, credential: credential(for: endpoint))
    }
    /// Current signer comparison is diagnostic evidence, not authentication.
    var peerSigner: (Data) -> EndpointInspector.Signer = EndpointInspector.signer(auditToken:)
    /// Ask the OS to start the product; returns an error message on failure.
    var launchProduct: (_ appPath: String?) -> String? = CLI.openProduct
    /// Note a write's requestId, method and endpoint before it is sent, so
    /// an interrupted run can be looked up later with request show.
    var recordRequest: (_ requestId: String, _ method: String, _ endpoint: String) -> Void = CLI.appendRequestLog
    /// Write a saved artifact (observe --image-output, artifact get), owner-only.
    var writeFile: (_ data: Data, _ to: String) throws -> Void = { data, to in
        let fm = FileManager.default
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        guard fm.createFile(atPath: to, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    /// Run session exec's child; its exit status (128+signal when killed).
    var spawnChild: (_ argv: [String], _ environment: [String: String]) -> Int32 = CLI.runChild
    /// Ctrl-C seen (main installs the handler).
    var interrupted: () -> Bool = { Interrupt.received }
    var readFile: (String) throws -> Data = { try Data(contentsOf: URL(fileURLWithPath: $0)) }
    var sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> Date = Date.init

    /// Runs the contract v1 groups (rpc, ai, gui).
    var runContract: (([String]) -> Int32)?

    func run(_ args: [String]) -> Int32 {
        if CommandRouter.isContractCommand(args) {
            // One endpoint (A2): the AI service answers through the Runtime.
            let contract = runContract ?? { a in
                let socket = a.firstIndex(of: "--socket").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } ?? ""
                return ContractCLI(credential: credential(for: Endpoint(path: socket, source: .option))).run(a).rawValue
            }
            guard !args.contains("--socket") else { return contract(args) }
            let runtime = EndpointResolver.resolve(option: nil, environment: environment).path
            return contract(["--socket", runtime] + args)
        }
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
        // Inside session exec, the context names the Runtime unless told otherwise.
        let context = try? ExecContext.load(environment: environment)
        var env = environment
        if let context, env[EndpointResolver.environmentKey] == nil { env[EndpointResolver.environmentKey] = context.endpoint }
        let endpoint = EndpointResolver.resolve(option: invocation.endpoint, environment: env)

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
        case var .call(call):
            if call.usesContext, call.context.sessionId == nil, call.context.desktopId == nil {
                // No explicit target: the session exec context supplies it.
                do {
                    guard let ctx = try ExecContext.load(environment: environment) else {
                        throw RuntimeError.invalidArgument("give the target with --session (or --desktop), or run inside session exec")
                    }
                    call.context = RequestContext(sessionId: ctx.sessionId, runId: call.method == .act ? ctx.runId : nil)
                    return perform(call, out, endpoint: endpoint, attach: ctx)
                } catch let e as RuntimeError {
                    out.failure(requestId: nil, e)
                    return ExitStatus.of(e)
                } catch {
                    return ExitStatus.unclassified
                }
            }
            if call.method == .act, call.context.runId == nil, let ctx = context, call.context.sessionId == ctx.sessionId {
                call.context.runId = ctx.runId
                return perform(call, out, endpoint: endpoint, attach: ctx)
            }
            return perform(call, out, endpoint: endpoint)
        case let .eventsWatch(runId, after):
            return eventsWatch(runId: runId, after: after, format: invocation.format, out, endpoint: endpoint)
        case let .runEvents(runId, after, follow):
            return runEvents(runId: runId, after: after, follow: follow, format: invocation.format, out, endpoint: endpoint)
        case let .runWait(runId, timeout):
            return runWait(runId: runId, timeout: timeout, out, endpoint: endpoint)
        case let .unitRun(params, requestId, timeout):
            return unitRun(params: params, requestId: requestId, timeout: timeout, out, endpoint: endpoint)
        case let .runCancel(runId, requestId, wait, timeout):
            return runCancel(runId: runId, requestId: requestId, wait: wait, timeout: timeout, out, endpoint: endpoint)
        case let .agentsPair(name, publisher, grant, profile, timeout):
            return agentsPair(name: name, publisher: publisher, grant: grant, profile: profile ?? self.profile, timeout: timeout,
                              out, endpoint: endpoint)
        case let .mcp(profile, desktopId):
            // An MCP host is an external agent: it acts as a paired app with
            // its own credential (profile "mcp" unless told otherwise), never
            // as the owner (A4). Without one it can only see that it must pair.
            let credential = self.credential(for: endpoint, profile: profile ?? "mcp")
            if credential == nil {
                stderr("agentdesktop mcp: not paired; run `agentdesktop agents pair --name <host> --profile \(profile ?? "mcp")` first")
            }
            // stdout carries only MCP messages; diagnostics go to stderr.
            // --desktop-id: every tool stays on that one Desktop (A7).
            let server = MCPServer(desktopScope: desktopId, makeClient: {
                SocketRuntimeClient(endpoint: endpoint, info: CLI.clientInfo, credential: credential)
            })
            server.serve(readLine: { Swift.readLine(strippingNewline: true) }, write: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            })
            return ExitStatus.ok
        case let .sessionExec(desktopId, sessionId, argv):
            return sessionExec(desktopId: desktopId, sessionId: sessionId, argv: argv, out, endpoint: endpoint)
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
    func withClient(_ out: ResultWriter, endpoint: Endpoint, timeout: Double = 10,
                    _ body: (RuntimeClient) throws -> Int32) -> Int32 {
        let client = client(endpoint, timeout: timeout)
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
