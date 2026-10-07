import AgentDesktopCLI
import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopService

// T11 against the composed service over a real socket: CLI-001..004 and the
// exit codes of spec §13.2.

final class CLIRun: @unchecked Sendable {
    let out = LinesBox()
    let err = LinesBox()
    var files: [String: String] = [:]
    var stdin = ""
    var interruptAfterPolls: Int?
    private var polls = 0
    private var clockMs: UInt64 = 0

    func cli() -> CLI {
        CLI(stdout: out.add, stderr: err.add,
            readFile: { [files] p in guard let s = files[p] else { throw CocoaError(.fileNoSuchFile) }; return Data(s.utf8) },
            environment: ["HOME": NSHomeDirectory()],
            send: SocketClient.exchange,
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

final class Served: @unchecked Sendable {
    let slice: Slice
    let server: RpcSocketServer
    let socket: String

    init(backend: Bool = true) async throws {
        slice = try await Slice(backend: backend)
        socket = slice.dir.appendingPathComponent("rpc.sock").path
        server = RpcSocketServer(path: socket, router: slice.router)
        try server.start()
    }

    func run(_ r: CLIRun, _ args: [String]) async -> ExitCode {
        let cli = r.cli()
        let socket = socket
        return await Task.detached { cli.run(["--json", "--socket", socket] + args) }.value
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
        let created = try r.json()["result"]!
        let id = created["connectionId"]!.stringValue!

        let r2 = CLIRun()
        #expect(await s.run(r2, ["ai", "connections", "get", "--id", id]) == .ok)
        #expect(try r2.json()["result"]?["revision"] == created["revision"])
        let r3 = CLIRun()
        #expect(await s.run(r3, ["ai", "connections", "list"]) == .ok)
        #expect(try r3.json()["result"]?["items"]?.arrayValue?.count == 1)
        for box in [r, r2, r3] {
            #expect(box.out.lines.count == 1, "stdout is exactly one JSON line")
            #expect(!(box.out.lines + box.err.lines).contains { $0.contains(canary) })
        }

        // Stale revision: business rejection, exit 4.
        let r4 = CLIRun()
        #expect(await s.run(r4, ["ai", "connections", "disable", "--id", id, "--expected-revision", "9",
                                 "--idempotency-key", "cli-disable-1"]) == .rejected)
        #expect(try r4.json()["error"]?["code"]?.stringValue == "CONFIG_CONFLICT")
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
        #expect(try list.json()["result"]?["items"]?.arrayValue?.isEmpty == true)
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

    // CLI-003: async run with --wait; same key, same run; events --follow.
    @Test func guiRunWaitFollowAndDuplicateKey() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        _ = try await s.slice.configure()
        func runArgs(_ key: String, wait: Bool) -> [String] {
            ["gui", "run", "--desktop", "desk-a", "--goal-file", "goal.txt", "--verification-file", "v.json",
             "--allowed-actions", "click,type,key", "--idempotency-key", key] + (wait ? ["--wait"] : [])
        }
        func files(_ r: CLIRun) {
            r.files["goal.txt"] = goal + "\n"
            r.files["v.json"] = #"{"kind":"element_text_equals","role":"static_text","text":"\#(expected)"}"#
        }
        let r = CLIRun(); files(r)
        #expect(await s.run(r, runArgs("cli-run-1", wait: true)) == .ok, "\(r.err.lines)")
        let final = try r.json()
        #expect(final["result"]?["state"]?.stringValue == "succeeded")
        #expect(r.err.lines.contains { $0.contains("accepted runId") }, "the acceptance goes to stderr")
        #expect(r.out.lines.count == 1)
        let runId = final["result"]!["runId"]!.stringValue!

        // Without --wait the id comes back at once; the same key gives the same run.
        let again = CLIRun(); files(again)
        #expect(await s.run(again, runArgs("cli-run-1", wait: false)) == .ok)
        #expect(try again.json()["result"]?["runId"]?.stringValue == runId)
        #expect(await s.slice.executor.executed.count == 3)

        let ev = CLIRun()
        #expect(await s.run(ev, ["gui", "events", "--run-id", runId, "--after-sequence", "0", "--follow"]) == .ok)
        var seq: [Int] = []
        for line in ev.out.lines {
            let v = try StrictJSON.parse(line)
            seq += v["result"]?["events"]?.arrayValue?.compactMap { $0["sequence"]?.intValue } ?? []
        }
        #expect(!seq.isEmpty && seq == Array(seq.sorted()) && Set(seq).count == seq.count)

        let after = CLIRun()
        #expect(await s.run(after, ["gui", "events", "--run-id", runId, "--after-sequence", String(seq.last!)]) == .ok)
        #expect(try after.json()["result"]?["events"]?.arrayValue?.isEmpty == true)
    }

    // CLI-004: dry-run validates and shows what would be sent, and sends nothing.
    @Test func dryRunSendsNothing() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        let r = CLIRun()
        r.files["goal.txt"] = goal
        r.files["v.json"] = #"{"kind":"element_text_equals","role":"static_text","text":"x"}"#
        let before = s.slice.upstream.requests.count
        #expect(await s.run(r, ["gui", "run", "--desktop", "desk-a", "--goal-file", "goal.txt", "--verification-file", "v.json",
                                "--allowed-actions", "click", "--idempotency-key", "dry-run-0001", "--dry-run", "--wait"]) == .ok)
        #expect(try r.json()["dryRun"]?.boolValue == true, "\(r.err.lines)")
        let bad = CLIRun()
        bad.files = r.files
        #expect(await s.run(bad, ["gui", "run", "--desktop", "desk-a", "--goal-file", "goal.txt", "--verification-file", "v.json",
                                  "--allowed-actions", "drag", "--idempotency-key", "dry-run-0002", "--dry-run"]) == .localValidation)
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
        #expect(try list.json()["result"]?["items"]?.arrayValue?.isEmpty == true, "dry-run created nothing")
    }

    // Exit 6: the client stops waiting; exit 130: Ctrl-C cancels the run first.
    @Test func waitTimeoutAndInterrupt() async throws {
        let s = try await Served()
        defer { s.server.stop() }
        _ = try await s.slice.configure()
        let r = CLIRun()
        r.files["goal.txt"] = goal
        r.files["v.json"] = #"{"kind":"element_text_equals","role":"static_text","text":"never shown"}"#
        // A 1 ms client wait: the CLI stops waiting (6) unless the run already
        // ended as failed (4); either way it never reports success.
        let timedOut = await s.run(r, ["gui", "run", "--desktop", "desk-a", "--goal-file", "goal.txt", "--verification-file", "v.json",
                                       "--allowed-actions", "click,type", "--idempotency-key", "slow-run-0001", "--wait", "--wait-timeout-ms", "1"])
        #expect([ExitCode.waitTimedOut, .rejected].contains(timedOut), "\(r.err.lines)")

        let c = CLIRun()
        c.files = r.files
        c.interruptAfterPolls = 0
        #expect(await s.run(c, ["gui", "run", "--desktop", "desk-a", "--goal-file", "goal.txt", "--verification-file", "v.json",
                                "--allowed-actions", "click,type", "--idempotency-key", "interrupt-0001", "--wait"]) == .interrupted)
        #expect(c.err.lines.contains { $0.contains("cancel accepted") }, "\(c.err.lines)")
    }
}
