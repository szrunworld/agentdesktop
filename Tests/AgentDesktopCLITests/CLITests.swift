import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopCLI

// CLI-001/002 (rpc and dry-run parts) and the exit-code table of §13.2.
// The friendly per-command aliases, --wait/--follow and credential stdin
// arrive with T11.

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String] = []
    private var err: [String] = []
    func o(_ s: String) { lock.lock(); out.append(s); lock.unlock() }
    func e(_ s: String) { lock.lock(); err.append(s); lock.unlock() }
    var stdout: [String] { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: [String] { lock.lock(); defer { lock.unlock() }; return err }
}

func cli(_ output: Output, files: [String: String] = [:],
         send: @escaping (Data, String) -> FrameReader.Result = { _, _ in .ioError(ECONNREFUSED) }) -> CLI {
    CLI(stdout: output.o, stderr: output.e,
        readFile: { path in
            guard let s = files[path] else { throw CocoaError(.fileNoSuchFile) }
            return Data(s.utf8)
        },
        environment: ["HOME": "/Users/test"], send: send)
}

let listRequest = #"{"schemaVersion":"agentdesktop.ai/1","requestId":"11111111-1111-4111-8111-111111111111","command":"ai.connections.list","params":{"limit":5}}"#
let createRequest = #"{"schemaVersion":"agentdesktop.ai/1","requestId":"22222222-2222-4222-8222-222222222222","command":"ai.connections.create","params":{"name":"Ark","protocol":"openai_chat","baseUrl":"https://ark.example.com/api/v3","timeoutMs":30000,"credential":{"apiKey":"sk-canary-cli"}},"context":{"idempotencyKey":"create-ark-1"}}"#

@Suite("CLI")
struct CLITests {
    @Test func defaultSocketIsTheProductEndpoint() {
        let c = CLI(environment: ["HOME": "/Users/x"])
        #expect(c.defaultSocket() == "/Users/x/Library/Application Support/AgentDesktop/control.sock")
        #expect(CLI(environment: ["HOME": "/Users/x", "SECONDSCREEN_SOCKET": "/tmp/a.sock"]).defaultSocket() == "/tmp/a.sock")
    }

    @Test func dryRunValidatesAndRedactsWithoutConnecting() {
        let out = Output()
        var connected = false
        let code = cli(out, files: ["req.json": createRequest], send: { _, _ in connected = true; return .ioError(0) })
            .run(["--json", "rpc", "--request-file", "req.json", "--dry-run"])
        #expect(code == .ok)
        #expect(!connected)
        #expect(out.stdout.count == 1)
        #expect(out.stdout[0].contains(#""dryRun":true"#))
        #expect(!out.stdout[0].contains("sk-canary-cli"))
        #expect(out.stdout[0].contains("[REDACTED]"))
    }

    @Test func localSchemaFailureExits2AndSendsNothing() {
        let out = Output()
        var sent = 0
        let bad = listRequest.replacingOccurrences(of: #""limit":5"#, with: #""limit":500"#)
        let code = cli(out, files: ["bad.json": bad], send: { _, _ in sent += 1; return .ioError(0) })
            .run(["rpc", "--request-file", "bad.json"])
        #expect(code == .localValidation)
        #expect(sent == 0)
        #expect(out.stdout.first?.contains("VALIDATION_ERROR") == true)
    }

    @Test func usageErrorsExit2() {
        let out = Output()
        #expect(cli(out).run([]) == .localValidation)
        #expect(cli(out).run(["rpc"]) == .localValidation)
        #expect(cli(out).run(["rpc", "--request-file", "-"]) == .localValidation)
        #expect(cli(out).run(["--bogus", "rpc"]) == .localValidation)
        #expect(cli(out).run(["rpc", "--request-file", "missing.json"]) == .localValidation)
        #expect(out.stdout.isEmpty, "usage errors print nothing on stdout")
    }

    @Test func unreachableRuntimeExits3() {
        let out = Output()
        #expect(cli(out, files: ["r.json": listRequest]).run(["rpc", "--request-file", "r.json"]) == .runtimeUnavailable)
        #expect(out.stdout.isEmpty)
    }

    @Test func responseMapping() {
        let ok = #"{"schemaVersion":"agentdesktop.ai/1","requestId":"11111111-1111-4111-8111-111111111111","ok":true,"result":{"items":[],"nextCursor":null}}"#
        let conflict = #"{"schemaVersion":"agentdesktop.ai/1","requestId":"11111111-1111-4111-8111-111111111111","ok":false,"error":{"code":"CONFIG_CONFLICT","message":"stale","retryable":false}}"#
        let unsupported = conflict.replacingOccurrences(of: "CONFIG_CONFLICT", with: "UNSUPPORTED_COMMAND")
        let otherId = ok.replacingOccurrences(of: "11111111-1111-4111-8111-111111111111", with: "33333333-3333-4333-8333-333333333333")
        let cases: [(FrameReader.Result, ExitCode)] = [
            (.frame(Data(ok.utf8)), .ok),
            (.frame(Data(conflict.utf8)), .rejected),
            (.frame(Data(unsupported.utf8)), .runtimeUnavailable),
            (.frame(Data(otherId.utf8)), .runtimeUnavailable),
            (.frame(Data("not json".utf8)), .runtimeUnavailable),
            (.frame(Data(#"{"ok":true}"#.utf8)), .runtimeUnavailable),
            (.truncated(Data()), .runtimeUnavailable),
            (.tooLarge, .runtimeUnavailable),
        ]
        for (reply, expected) in cases {
            let out = Output()
            let code = cli(out, files: ["r.json": listRequest], send: { _, _ in reply }).run(["rpc", "--request-file", "r.json"])
            #expect(code == expected, "\(reply)")
            #expect(out.stdout.count <= 1)
        }
    }

    // End to end over a real Unix socket against an RpcRouter.
    @Test func roundTripOverAUnixSocket() async throws {
        let path = "/tmp/adcli-\(getpid())-\(UInt32.random(in: 0...99999)).sock"
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let b = Array(path.utf8); buf.copyBytes(from: b); buf[b.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        defer { close(listener); unlink(path) }

        let router = RpcRouter(handlers: ["ai.connections.list": { _ in .obj([("items", .array([])), ("nextCursor", .null)]) }])
        let server = Task.detached {
            let client = accept(listener, nil, nil)
            defer { close(client) }
            let reply = await router.respond(to: FrameReader.read(fd: client))
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
        }
        let out = Output()
        let c = CLI(stdout: out.o, stderr: out.e, readFile: { _ in Data(listRequest.utf8) },
                    environment: ["HOME": "/Users/test"], send: SocketClient.exchange)
        let code = await Task.detached { c.run(["--socket", path, "rpc", "--request-file", "r.json"]) }.value
        await server.value
        #expect(code == .ok, "\(out.stderr)")
        #expect(out.stdout.count == 1)
        #expect(out.stdout.first?.contains(#""requestId":"11111111-1111-4111-8111-111111111111""#) == true)
    }
}
