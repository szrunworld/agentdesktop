import AgentDesktopClient
import AgentDesktopCLI
import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing
@testable import AgentDesktopService

// T11 against the composed service behind the Runtime's single endpoint
// (A2): CLI-001..004 and the exit codes of spec §13.2.

final class CLIRun: @unchecked Sendable {
    let out = LinesBox()
    let err = LinesBox()
    var files: [String: String] = [:]
    var stdin = ""
    var interruptAfterPolls: Int?
    private var polls = 0
    private var clockMs: UInt64 = 0

    func cli() -> ContractCLI {
        ContractCLI(stdout: out.add, stderr: err.add,
            readFile: { [files] p in guard let s = files[p] else { throw CocoaError(.fileNoSuchFile) }; return Data(s.utf8) },
            environment: ["HOME": NSHomeDirectory()],
            send: ownerSend,
            readStdin: { [stdin] in Data(stdin.utf8) },
            nowMs: { [self] in clockMs },
            sleepMs: { [self] ms in polls += 1; clockMs += UInt64(ms); usleep(20_000) },
            interrupted: { [self] in interruptAfterPolls.map { polls >= $0 } ?? false })
    }

    func json(_ i: Int = -1) throws -> JSONValue {
        let lines = out.lines
        return try StrictJSON.parse(lines[i < 0 ? lines.count + i : i])
    }
}

/// The CLI blocks on its socket: run it on a plain thread, never on the
/// cooperative pool the service's async handlers need.
func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread { c.resume(returning: body()) }.start() }
}

/// A Runtime that has no desktops: these tests need only its endpoint.
struct NoDesktopBackend: RuntimeBackend {
    var platform: AgentDesktopProtocol.Platform { .init(os: "macos", osVersion: "15", arch: "arm64") }
    func permissions() -> BackendPermissions { .init(screenRecording: .granted, accessibility: .granted) }
    func features() -> [String] { [] }
    func applications(includeBackground: Bool) -> [AppSummary] { [] }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] { [] }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: nil) }
    /// An executable in no app bundle: known not to be iPhone Mirroring (#139).
    func executablePath(_ pid: Int32) -> String? { "/test/bin/process" }
}

/// The composed service answering through a real Runtime endpoint, as the
/// host wires it.
/// The contract CLI under test speaks as the owner of its test Runtime: a
/// test seam; the product has no socket owner (A4 S1).
let serviceTestOwner = ClientCredential(clientId: "local:\(getuid())", token: "adt1_service-test-owner")
let ownerSend: @Sendable (JSONValue, String) -> TransportReply = { RuntimeTransport.exchange($0, path: $1, credential: serviceTestOwner) }

func runtimeEndpoint(for service: AgentDesktopService, at path: String) throws -> RuntimeServer {
    let runtime = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_svc", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: path, buildSource: "unknown"),
                                 backend: NoDesktopBackend(), testSocketOwnerToken: serviceTestOwner.token); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    let served = runtime.contract.methods.filter { $0.servedBy == "ai-service" }.map(\.method)
    runtime.registerExtensions(RuntimeBridge.handlers(service, methods: served))
    runtime.registerCapabilitySection("gui") { RuntimeBridge.guiCapabilities(service) }
    let server = RuntimeServer(path: path, service: runtime)
    try server.start()
    return server
}

final class Served: @unchecked Sendable {
    let slice: Slice
    let server: RuntimeServer
    let socket: String

    init(backend: Bool = true) async throws {
        slice = try await Slice(backend: backend)
        socket = slice.dir.appendingPathComponent("runtime.sock").path
        server = try runtimeEndpoint(for: slice.service, at: socket)
    }

    func run(_ r: CLIRun, _ args: [String]) async -> ExitCode {
        let cli = r.cli()
        let socket = socket
        return await onThread { cli.run(["--json", "--socket", socket] + args) }
    }
}

@Suite("CLI friendly commands", .serialized)
struct CLIFriendlyTests {
    // CLI-001 / CLI-002: create with the key on stdin, read it back.
    @Test func connectionLifecycleWithTheKeyOnStdin() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        let r = CLIRun()
        r.files["conn.json"] = #"{"name":"Ark","protocol":"openai_chat","baseUrl":"https://ark.example.com/api/v3","timeoutMs":30000}"#
        r.stdin = canary + "\n"
        #expect(await s.run(r, ["ai", "connections", "create", "--params-file", "conn.json", "--credential-stdin",
                                "--idempotency-key", "cli-conn-1"]) == .ok)
        let created = try r.json()["data"]!
        let id = created["connectionId"]!.stringValue!

        let r2 = CLIRun()
        #expect(await s.run(r2, ["ai", "connections", "get", "--id", id]) == .ok)
        #expect(try r2.json()["data"]?["revision"] == created["revision"])
        let r3 = CLIRun()
        #expect(await s.run(r3, ["ai", "connections", "list"]) == .ok)
        #expect(try r3.json()["data"]?["items"]?.arrayValue?.count == 1)
        for box in [r, r2, r3] {
            #expect(box.out.lines.count == 1, "stdout is exactly one JSON line")
            #expect(!(box.out.lines + box.err.lines).contains { $0.contains(canary) })
        }

        // Stale revision: business rejection, exit 4.
        let r4 = CLIRun()
        #expect(await s.run(r4, ["ai", "connections", "disable", "--id", id, "--expected-revision", "9",
                                 "--idempotency-key", "cli-disable-1"]) == .rejected)
        #expect(try r4.json()["error"]?["code"]?.stringValue == "conflict")
        #expect(try r4.json()["error"]?["details"]?["serviceCode"]?.stringValue == "CONFIG_CONFLICT")
    }

    // CLI-002: no plaintext key in argv, ever.
    @Test func plaintextKeyFlagIsRefused() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        let r = CLIRun()
        r.files["conn.json"] = #"{"name":"Ark","protocol":"openai_chat","baseUrl":"https://ark.example.com/api/v3","timeoutMs":30000}"#
        #expect(await s.run(r, ["ai", "connections", "create", "--params-file", "conn.json", "--api-key", canary,
                                "--idempotency-key", "cli-conn-2"]) == .localValidation)
        #expect(r.out.lines.isEmpty)
        #expect(!r.err.lines.contains { $0.contains(canary) })
        // A create without --credential-stdin is refused locally too.
        let r2 = CLIRun()
        r2.files = r.files
        #expect(await s.run(r2, ["ai", "connections", "create", "--params-file", "conn.json",
                                 "--idempotency-key", "cli-conn-3"]) == .localValidation)
        let list = CLIRun()
        #expect(await s.run(list, ["ai", "connections", "list"]) == .ok)
        #expect(try list.json()["data"]?["items"]?.arrayValue?.isEmpty == true)
    }

    @Test func localRulesExit2WithoutSending() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        let calls = s.slice.upstream.chatRequests
        // Mutation without an idempotency key.
        #expect(await s.run(CLIRun(), ["ai", "connections", "disable", "--id", "c1", "--expected-revision", "1"]) == .localValidation)
        // A field from both a flag and the params file.
        let r = CLIRun()
        r.files["p.json"] = #"{"connectionId":"c1"}"#
        #expect(await s.run(r, ["ai", "models", "list", "--connection-id", "c1", "--params-file", "p.json"]) == .localValidation)
        // A whole envelope where params belong.
        let r2 = CLIRun()
        r2.files["env.json"] = #"{"schemaVersion":"agentdesktop.ai/1","command":"ai.connections.create","params":{}}"#
        #expect(await s.run(r2, ["ai", "connections", "create", "--params-file", "env.json", "--credential-stdin",
                                 "--idempotency-key", "k-12345678"]) == .localValidation)
        // Unknown option and unknown command.
        #expect(await s.run(CLIRun(), ["ai", "connections", "list", "--bogus"]) == .localValidation)
        #expect(await s.run(CLIRun(), ["gui", "resume", "--run-id", "x"]) == .localValidation)
        #expect(s.slice.upstream.chatRequests == calls)
    }

    // CLI-004: dry-run validates and shows what would be sent, and sends nothing.
    @Test func dryRunSendsNothing() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        let r = CLIRun()
        let before = s.slice.upstream.requests.count
        #expect(await s.run(r, ["ai", "tests", "start", "--profile-id", "gp-1", "--expected-revision", "1",
                                "--idempotency-key", "dry-run-0001", "--dry-run", "--wait"]) == .ok)
        #expect(try r.json()["dryRun"]?.boolValue == true, "\(r.err.lines)")
        let bad = CLIRun()
        #expect(await s.run(bad, ["ai", "tests", "start", "--profile-id", "gp-1", "--expected-revision", "one",
                                  "--idempotency-key", "dry-run-0002", "--dry-run"]) == .localValidation)
        let key = CLIRun()
        key.files["conn.json"] = #"{"name":"Ark","protocol":"openai_chat","baseUrl":"https://ark.example.com/api/v3","timeoutMs":30000}"#
        key.stdin = canary
        #expect(await s.run(key, ["ai", "connections", "create", "--params-file", "conn.json", "--credential-stdin",
                                  "--idempotency-key", "dry-run-0003", "--dry-run"]) == .ok)
        #expect(!key.out.lines.joined().contains(canary))
        #expect(s.slice.upstream.requests.count == before)
        #expect(await s.slice.executor.executed.isEmpty)
        let list = CLIRun()
        #expect(await s.run(list, ["ai", "connections", "list"]) == .ok)
        #expect(try list.json()["data"]?["items"]?.arrayValue?.isEmpty == true, "dry-run created nothing")
    }
}
